// SPDX-License-Identifier: AGPL-3.0-only
// Overlay regions for the web host (OSC-OVERLAY): which parts of the page carry UI over the
// visuals, and the OverlayUniforms block the shared present pass reads for them.
//
// packOverlay is a port of oscillux_overlay_pack (crates/oscillux-core/src/overlay.rs) for a
// page that does not load the wasm package; tools/shader/overlay-check.mjs checks it byte for
// byte against conformance/packing/overlay-uniforms.json. trackOverlay reads the regions from
// the elements marked data-overlay, in viewport fractions from getBoundingClientRect, again
// whenever their layout changes, and the prefers-reduced-motion media query.
//
// Marking an element: data-overlay="light-text desaturate blur damp-motion damp-flash" (any
// of the mode names), and optionally data-overlay-strength (default 1), data-overlay-radius
// and data-overlay-feather in CSS pixels (default the element's border radius, and 0).

export const OVERLAY_UNIFORMS_SIZE = 320;
export const MAX_OVERLAY_REGIONS = 8;
export const MODE = { 'light-text': 1, 'dark-text': 2, desaturate: 4, blur: 8, 'damp-motion': 16, 'damp-flash': 32 };
const MODE_MASK = 63;
const CONTRAST_MARGIN = 1e-4;
const REFERENCE_FRAME_MS = 1000 / 60;
const REGION_TEMPORAL_KEEP = 0.9;
const REGION_MAX_LUMINANCE_STEP = 0.01;
const REDUCED_MOTION_TEMPORAL_KEEP = 0.6;
const REDUCED_MOTION_MAX_LUMINANCE_STEP = 0.04;
const REDUCED_MOTION_INTENSITY = 0.5;
const BLUR_RADIUS = 0.012;

export const DEFAULT_CONFIG = Object.freeze({
  viewport_width: 1920, viewport_height: 1080, contrast_ratio: 4.5, intensity: 1,
  frame_interval_ms: REFERENCE_FRAME_MS, alpha: 1, output_levels: 255,
  reduced_motion: false, premultiplied_alpha: false,
});

/** An overlay input the core would refuse; `kind` is the core's OverlayError name. */
export class OverlayError extends Error {
  constructor(kind) { super(`invalid overlay input: ${kind}`); this.kind = kind; }
}

const unit = v => v >= 0 && v <= 1;
const positive = v => Number.isFinite(v) && v > 0;

function validateConfig(c) {
  if (!positive(c.viewport_width) || !positive(c.viewport_height)) throw new OverlayError('Viewport');
  if (!(c.contrast_ratio >= 1 && c.contrast_ratio <= 21)) throw new OverlayError('ContrastRatio');
  if (!unit(c.intensity)) throw new OverlayError('Intensity');
  if (!(positive(c.frame_interval_ms) && c.frame_interval_ms <= 1000)) throw new OverlayError('FrameInterval');
  if (!unit(c.alpha)) throw new OverlayError('Alpha');
  if (c.output_levels === 1 || c.output_levels > 65535) throw new OverlayError('OutputLevels');
}

function validateRegion(r) {
  if (![r.x, r.y, r.width, r.height].every(Number.isFinite) || r.width < 0 || r.height < 0) {
    throw new OverlayError('RegionRect');
  }
  if (!unit(r.corner_radius) || !unit(r.feather)) throw new OverlayError('RegionShape');
  if (!unit(r.strength)) throw new OverlayError('RegionStrength');
  if ((r.mode & ~MODE_MASK) !== 0 || (r.mode & 3) === 3 || (r.reserved ?? 0) !== 0) throw new OverlayError('RegionMode');
}

/**
 * Packs config and regions into the 320-byte OverlayUniforms block at the start of out (a new
 * buffer by default), as the core does; refuses invalid input before writing.
 */
export function packOverlay(config, regions, out = new Uint8Array(OVERLAY_UNIFORMS_SIZE)) {
  validateConfig(config);
  if (regions.length > MAX_OVERLAY_REGIONS) throw new OverlayError('RegionCount');
  for (const r of regions) validateRegion(r);
  out.fill(0, 0, OVERLAY_UNIFORMS_SIZE);
  const view = new DataView(out.buffer, out.byteOffset, OVERLAY_UNIFORMS_SIZE);
  const put = (offset, values) => values.forEach((v, i) => view.setFloat32(offset + 4 * i, v, true));
  const frames = Math.min(config.frame_interval_ms / REFERENCE_FRAME_MS, 1);
  const keep = k => 1 - (1 - k) * frames;
  const rm = config.reduced_motion;
  put(0, [regions.length, 1.05 / config.contrast_ratio - 0.05 - CONTRAST_MARGIN,
    0.05 * config.contrast_ratio - 0.05 + CONTRAST_MARGIN, config.output_levels]);
  put(16, [rm ? config.intensity * REDUCED_MOTION_INTENSITY : config.intensity,
    rm ? keep(REDUCED_MOTION_TEMPORAL_KEEP) : 0, rm ? REDUCED_MOTION_MAX_LUMINANCE_STEP * frames : 1,
    config.premultiplied_alpha ? 1 : 0]);
  put(32, [keep(REGION_TEMPORAL_KEEP), REGION_MAX_LUMINANCE_STEP * frames, BLUR_RADIUS,
    config.viewport_width / config.viewport_height]);
  put(48, [config.alpha, config.viewport_height, rm ? 1 : 0, 0]);
  regions.forEach((r, i) => {
    put(64 + 16 * i, [r.x, r.y, r.width, r.height]);
    put(192 + 16 * i, [r.corner_radius, r.feather, r.strength, r.mode]);
  });
  return out;
}

function modeOf(el) {
  let mode = 0;
  for (const name of (el.dataset.overlay ?? '').split(/\s+/).filter(Boolean)) {
    if (!(name in MODE)) throw new Error(`data-overlay: unknown mode ${name}`);
    mode |= MODE[name];
  }
  return mode;
}

const clamp01 = v => Math.min(Math.max(v, 0), 1);

/**
 * Tracks the marked elements under root. Returns { regions, reducedMotion, safeRect } with
 * regions in viewport fractions, refreshed on layout and preference changes; onChange runs
 * after each refresh.
 */
export function trackOverlay(root = document, onChange = () => {}) {
  const state = { regions: [], reducedMotion: false, safeRect: [0.05, 0.05, 0.95, 0.95] };
  const media = matchMedia('(prefers-reduced-motion: reduce)');
  const refresh = () => {
    const W = innerWidth, H = innerHeight;
    const regions = [];
    for (const el of root.querySelectorAll('[data-overlay]')) {
      // Observing an element again would re-deliver its first size notification.
      if (!observed.has(el)) { observed.add(el); observer.observe(el); }
      const b = el.getBoundingClientRect();
      if (b.width <= 0 || b.height <= 0 || getComputedStyle(el).visibility === 'hidden') continue;
      if (regions.length === MAX_OVERLAY_REGIONS) break;
      const px = parseFloat(el.dataset.overlayRadius ?? getComputedStyle(el).borderTopLeftRadius) || 0;
      regions.push({
        x: b.left / W, y: b.top / H, width: b.width / W, height: b.height / H,
        corner_radius: clamp01(px / H), feather: clamp01((parseFloat(el.dataset.overlayFeather) || 0) / H),
        strength: clamp01(parseFloat(el.dataset.overlayStrength ?? '1')), mode: modeOf(el), reserved: 0,
      });
    }
    state.regions = regions;
    state.reducedMotion = media.matches;
    state.safeRect = safeRect(regions);
    onChange(state);
  };
  const observer = new ResizeObserver(refresh), observed = new WeakSet();
  // A text change inside a marked element (a status line, say) moves no region; a resize it
  // causes reaches the ResizeObserver.
  const moved = records => records.some(r => r.type === 'attributes'
    || [...r.addedNodes, ...r.removedNodes].some(n => n.nodeType === 1));
  new MutationObserver(records => { if (moved(records)) refresh(); }).observe(root.body ?? root, { subtree: true, childList: true, attributes: true,
    attributeFilter: ['data-overlay', 'data-overlay-strength', 'data-overlay-radius', 'data-overlay-feather', 'hidden', 'style', 'class'] });
  addEventListener('resize', refresh);
  media.addEventListener('change', refresh);
  refresh();
  return state;
}

/**
 * The visuals' safe rectangle for safeRect: (left, top, right, bottom) corners in viewport
 * fractions, as shaders/library.glsl safeRectMask reads it. The 5% margin, with each region
 * moved out of it across the viewport edge that costs the least depth, keeping the centre
 * inside.
 */
export function safeRect(regions) {
  const s = [0.05, 0.05, 0.95, 0.95];
  for (const r of regions) {
    const gaps = [r.x, r.y, 1 - r.x - r.width, 1 - r.y - r.height];
    const depths = gaps.map((g, edge) => (edge % 2 === 0 ? r.width : r.height) + Math.max(g, 0));
    const edge = depths.indexOf(Math.min(...depths));
    const depth = Math.min(depths[edge], 0.5);
    if (edge < 2) s[edge] = Math.max(s[edge], depth);
    else s[edge] = Math.min(s[edge], 1 - depth);
  }
  return s;
}
