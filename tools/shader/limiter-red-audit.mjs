// SPDX-License-Identifier: AGPL-3.0-only
// Red audit of the visual catalog through the frame flash limiter (CORE-0125). Renders each
// bundled visual with beat-lint.mjs's renderer and beat clock (WebGL2 under Playwright Chromium on
// the hardware GPU where there is one, else SwiftShader; 480 x 270, 60 fps, the visual's default palette and params, tonemapped RGBA8).
// Each frame goes through the reference model (limiter-model.mjs, WCAG geometry, bit-identical to
// the GPU passes by conformance/limiter/frame/) and the independent pixel auditor
// (limiter-audit.mjs, WCAG field) runs on both the input and the limiter's output. Per visual it
// reports the most large-area red and luma transitions in any 1 s window, input and output (exit
// 2 when the output exceeds 1 red or 6 luma transitions a second);
// the frames where the model found red over the area limit, on the input and (a second model
// instance) on the limiter's output; the output auditor's red transition frames; and the mean
// and largest held fraction.
//
// --audio loud replaces beat-lint's clock values with a loud, full-band mix on the same beat:
// spectrum 0.9 falling to 0.68 across the bins plus the kick, bass, mid and treble near full
// scale, as a live rock master drives the mapper. --max-held F fails (exit 3) any visual whose
// largest held fraction of pixels in a frame exceeds F; held pixels show the input dimmed (the
// previous frame until v0.2.9), so a large held fraction shows as flattened regions and ghosts
// (CORE-2409). --max-luma N fails (exit 4) any visual
// whose own output, before the limiter, makes more than N large-area luma transitions in a second
// or any large-area red transition: a visual should keep within the general flash limit itself
// (WCAG: 3 flashes, so 6 transitions, a second) rather than lean on the limiter, whose holds show
// as flattened regions. The full audit is optional, not part of gate; `make limiter-hold-check` is, and
// `make visual-flash-check` runs the source flash budget.
//
// --release audits the release legs' visual set (manifest.mjs releaseSet) instead of manifests.
// With it, --check-safety fails (exit 5) any visual whose measured photosensitivity data exceeds
// the safety block shaders/manifest.json declares for it (manifest.mjs; CORE-3417), or whose
// declared text-safe band is not measured dark and steady, and --write-safety writes the measured
// values into that block (maxFlashHz and maxLuminanceDelta rounded up; textSafeZone the band
// measured dark and steady), for review in the diff. Both render through the shipped present
// pass's tone map, and both fail when any selected visual was not measured over every frame.
//
//   node tools/shader/limiter-red-audit.mjs [manifest.json ... | --release] [--only id1,id2] [--beats 12]
//        [--jobs 6] [--audio lint|loud] [--max-held F] [--max-luma N] [--out out/limiter-red-audit]
import { chromium } from 'playwright';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { lintAudioAt, renderOne, setUp } from './beat-lint.mjs';
import { loadManifest, loadReleaseSet, mergeVisualSets, safetyFields } from './manifest.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    out: { type: 'string', default: '' },
    only: { type: 'string', default: '' },
    bpm: { type: 'string', default: '120' },
    beats: { type: 'string', default: '12' },
    jobs: { type: 'string', default: '6' },
    audio: { type: 'string', default: 'lint' },
    'max-held': { type: 'string', default: '' },
    'max-luma': { type: 'string', default: '' },
    release: { type: 'boolean', default: false },
    'check-safety': { type: 'boolean', default: false },
    'write-safety': { type: 'boolean', default: false },
  },
});
const W = 480, H = 270, FPS = 60, BPM = Number(opts.bpm);
const FRAMES = Math.round(parseInt(opts.beats, 10) * FPS * 60 / BPM);
const OUT = opts.out ? resolve(opts.out) : join(ROOT, 'out', 'limiter-red-audit');
const ONLY = opts.only.split(',').filter(Boolean);
const MAX_HELD = opts['max-held'] === '' ? Infinity : Number(opts['max-held']);
const MAX_LUMA = opts['max-luma'] === '' ? Infinity : Number(opts['max-luma']);
const SAFETY = opts['check-safety'] || opts['write-safety'];
if (SAFETY && !(FRAMES >= FPS)) {
  console.error('limiter-red-audit: safety data needs at least a second of frames (--beats)');
  process.exit(64);
}
if (!['lint', 'loud'].includes(opts.audio) || !(MAX_HELD >= 0) || !(MAX_LUMA >= 0)) {
  console.error('limiter-red-audit: --audio must be lint or loud, --max-held a fraction and --max-luma a count');
  process.exit(64);
}
const manifests = positionals.length
  ? positionals
  : ['shaders/originals/manifest.json', 'shaders/manifest.json'].map(p => join(ROOT, p));
const ORIGIN = 'http://limiter-audit.test';
const MODULES = ['limiter-model.mjs', 'limiter-geometry.mjs', 'limiter-audit.mjs'];

// In the page: the model and both auditors on every rendered frame.
async function attach({ W, H }) {
  const { createLimiter } = await import('/limiter-model.mjs');
  const { createAuditor } = await import('/limiter-audit.mjs');
  // Over is one flag for every direction: a frame is red-over only where red pixels fire in it too,
  // so luma-only activity is not labelled red (Codex round 14).
  // Red is asked of the grant when it fires now or, with something else firing, changed recently.
  const redOver = st => st.over[2] && (st.asked & 12) !== 0;
  // Safety measures (CORE-3417): the largest change in mean relative luminance of a WCAG field
  // window (a third by a third, at every pixel origin) against each of the frames within the
  // coverage interval before it, and each band's mean relative luminance and frame-to-frame
  // change. Rows come bottom-up from readPixels: the upper band is the last third of the rows.
  const lin = Float64Array.from({ length: 256 }, (_, k) => { const c = k / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; });
  const SPAN = 4, fw = Math.round(W / 3), fh = Math.round(H / 3), R = W + 1;
  // The largest |mean(a) - mean(b)| over every field-sized window, from two summed-area tables.
  function fieldDeltaMax(a, b) {
    let m = 0;
    for (let y = 0; y + fh <= H; y++) {
      for (let x = 0; x + fw <= W; x++) {
        const i0 = y * R + x, i1 = y * R + x + fw, i2 = (y + fh) * R + x, i3 = (y + fh) * R + x + fw;
        const d = Math.abs((a[i3] - a[i1] - a[i2] + a[i0]) - (b[i3] - b[i1] - b[i2] + b[i0]));
        if (d > m) m = d;
      }
    }
    return m / (fw * fh);
  }
  function luminance(px, Y, sum) {
    for (let j = 0, i = 0; j < W * H; j++, i += 4) Y[j] = 0.2126 * lin[px[i]] + 0.7152 * lin[px[i + 1]] + 0.0722 * lin[px[i + 2]];
    for (let y = 0; y < H; y++) {
      let run = 0;
      for (let x = 0; x < W; x++) { run += Y[y * W + x]; sum[(y + 1) * (W + 1) + x + 1] = sum[y * (W + 1) + x + 1] + run; }
    }
    const box = (x, y, w, h) => (sum[(y + h) * (W + 1) + x + w] - sum[y * (W + 1) + x + w] - sum[(y + h) * (W + 1) + x] + sum[y * (W + 1) + x]) / (w * h);
    return { sum, lower: box(0, 0, W, fh), center: box(0, fh, W, fh), upper: box(0, H - fh, W, fh) };
  }
  window.audit = {
    start() {
      const s = { lim: createLimiter({ width: W, height: H }), inA: createAuditor({ width: W, height: H }),
        outA: createAuditor({ width: W, height: H }), outLim: createLimiter({ width: W, height: H }),
        redOver: 0, redOverOut: 0, held: 0, heldMax: 0, heldMaxPx: 0, pixels: W * H, frames: 0,
        Y: new Float64Array(W * H), spare: [], recent: [], prev: null,
        lumaDeltaMax: 0, band: { upper: [0, 0], center: [0, 0], lower: [0, 0] } };
      window.lint.onFrame = px => {
        const r = s.lim.step(px, 1 / 60);
        s.inA.push(px, 1 / 60);
        s.outA.push(r.out, 1 / 60);
        if (redOver(r.stats)) s.redOver++;
        const o = s.outLim.step(r.out, 1 / 60).stats;
        if (redOver(o)) s.redOverOut++;
        s.held += r.held / (W * H);
        s.heldMax = Math.max(s.heldMax, r.held / (W * H));
        s.heldMaxPx = Math.max(s.heldMaxPx, r.held);
        const m = luminance(px, s.Y, s.spare.pop() ?? new Float64Array((W + 1) * (H + 1)));
        for (const p of s.recent) s.lumaDeltaMax = Math.max(s.lumaDeltaMax, fieldDeltaMax(m.sum, p.sum));
        s.recent.push(m); if (s.recent.length > SPAN) s.spare.push(s.recent.shift().sum);
        for (const b of ['upper', 'center', 'lower']) {
          s.band[b][0] += m[b];
          if (s.prev) s.band[b][1] += Math.abs(m[b] - s.prev[b]);
        }
        s.prev = m;
        s.frames++;
      };
      window.audit.state = s;
    },
    finish() {
      const s = window.audit.state;
      window.lint.onFrame = null;
      return {
        redIn: s.inA.maxPerWindow('red'), redOut: s.outA.maxPerWindow('red'),
        lumaIn: s.inA.maxPerWindow('luma'), lumaOut: s.outA.maxPerWindow('luma'),
        redOverFrames: s.redOver, redOverOutFrames: s.redOverOut,
        redOutAt: [...s.outA.transitions[2], ...s.outA.transitions[3], ...s.outA.transitions[5]].sort((a, b) => a - b), heldMean: +(s.held / s.frames).toFixed(4),
        heldMax: +s.heldMax.toFixed(4), heldMaxPx: s.heldMaxPx, pixels: s.pixels, frames: s.frames,
        lumaDeltaMax: s.lumaDeltaMax,
        bands: Object.fromEntries(Object.entries(s.band).map(([b, [l, d]]) => [b, { mean: l / s.frames, change: d / Math.max(1, s.frames - 1) }])),
      };
    },
  };
}

// --release: the web visuals the release legs ship (manifest.mjs releaseSet).
function releaseVisuals() {
  return loadReleaseSet(ROOT).visuals.filter(v => v.targets.includes('web')).map(v => ({
    id: v.id, fragment: v.wrapper.wrapGLSL300(v.body, v.imageInput), vertex: v.wrapper.VERTEX_300,
    palette: v.palette, params: v.params, trailDecay: v.trailDecay, overrides: false,
  }));
}

// beat-lint's clock with the levels of a loud master: the same beat, kick, onset and bassImpact,
// every band near full scale.
export function loudAudioAt(fr, bpm) {
  const a = lintAudioAt(fr, bpm);
  const kick = Math.exp(-a.beatPhase * (60000 / bpm) / 120);
  return {
    ...a, amplitude: Math.min(1, 0.85 + 0.2 * kick), level: 0.85, bass: Math.min(1, 0.68 + 0.3 * kick),
    mid: 0.68, treble: 0.6, spectrum: a.spectrum.map((_, i) => Math.min(1, 0.85 * (1 - 0.25 * i / 63) + 0.4 * kick * Math.exp(-i / 10))),
  };
}

// The safety block a visual's measures support (manifest.mjs): flashes are half the luma
// transitions in a second; text sits in the darkest steady band of center and upper, or nowhere.
const TEXT_MEAN = 0.18, TEXT_CHANGE = 0.004;
const steadyBand = (r, b) => r.bands[b].mean <= TEXT_MEAN && r.bands[b].change <= TEXT_CHANGE;
export function measuredSafety(r) {
  const steady = b => steadyBand(r, b);
  const zone = ['center', 'upper'].filter(steady).sort((a, b) => r.bands[a].mean - r.bands[b].mean)[0] ?? 'none';
  return { maxFlashHz: Math.ceil(r.lumaIn / 2), maxRedFlashHz: Math.ceil(r.redIn / 2), maxLuminanceDelta: Math.ceil(r.lumaDeltaMax * 100) / 100, textSafeZone: zone };
}

function safety(results) {
  if (!opts.release) { console.error('limiter-red-audit: --check-safety and --write-safety need --release'); process.exit(64); }
  // Every selected visual measured over every frame, or no safety verdict at all.
  const unmeasured = results.filter(r => r.error || r.frames !== FRAMES);
  for (const r of unmeasured) console.log(`SAFETY ${r.id}: not measured (${r.error ?? `${r.frames} of ${FRAMES} frames`})`);
  if (unmeasured.length) process.exit(5);
  const path = join(ROOT, 'shaders', 'manifest.json');
  const doc = JSON.parse(readFileSync(path, 'utf8'));
  const byId = new Map(results.map(r => [r.id, r]));
  if (opts['write-safety']) {
    const blocks = new Map();
    for (const [id, r] of byId) {
      const block = measuredSafety(r);
      try { safetyFields(block, `${id}.safety`); } catch (e) { console.log(`SAFETY ${e.message}: measured ${JSON.stringify(block)}`); process.exit(5); }
      blocks.set(id, block);
    }
    for (const v of doc.visuals) if (blocks.has(v.id)) v.safety = blocks.get(v.id);
    writeFileSync(path, JSON.stringify(doc, null, 2) + '\n');
    console.log(`wrote measured safety for ${byId.size} visuals to ${path}`);
    return;
  }
  const over = [];
  for (const v of doc.visuals) {
    const r = byId.get(v.id), d = v.safety;
    if (!r) continue;
    const m = measuredSafety(r);
    const zoneOk = d && (d.textSafeZone === 'none' || ((d.textSafeZone === 'upper' || d.textSafeZone === 'center') && steadyBand(r, d.textSafeZone)));
    if (!d || !zoneOk || m.maxFlashHz > d.maxFlashHz || m.maxRedFlashHz > d.maxRedFlashHz || m.maxLuminanceDelta > d.maxLuminanceDelta) over.push(`${v.id}: measured ${JSON.stringify(m)}, declared ${JSON.stringify(d)}`);
  }
  for (const o of over) console.log(`SAFETY ${o}`);
  if (over.length) process.exit(5);
  console.log(`safety: ${byId.size} visuals within their declared photosensitivity data`);
}

async function main() {
  const sets = opts.release ? [releaseVisuals()] : manifests.map(path => {
    const m = loadManifest(path);
    return m.visuals.filter(v => v.targets.includes('web')).map(v => ({
      id: v.id, fragment: m.wrapper.wrapGLSL300(v.body, v.imageInput), vertex: m.wrapper.VERTEX_300,
      palette: v.palette, params: v.params, trailDecay: v.trailDecay, overrides: v.overrides,
    }));
  });
  const visuals = mergeVisualSets(sets).filter(v => !ONLY.length || ONLY.includes(v.id));
  const audio = Array.from({ length: FRAMES }, (_, fr) => (opts.audio === 'loud' ? loudAudioAt : lintAudioAt)(fr, BPM));
  const results = new Array(visuals.length);
  let next = 0, renderer = '';
  const job = async () => {
    const browser = await chromium.launch({ args: ['--use-angle=metal', '--enable-gpu', '--ignore-gpu-blocklist', '--enable-unsafe-swiftshader', '--mute-audio'] });
    const page = await browser.newPage();
    await page.route(`${ORIGIN}/**`, route => {
      const name = new URL(route.request().url()).pathname.slice(1);
      if (MODULES.includes(name)) {
        return route.fulfill({ contentType: 'text/javascript', body: readFileSync(join(HERE, name), 'utf8') });
      }
      return route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>audit</title>' });
    });
    await page.goto(`${ORIGIN}/`);
    await page.evaluate(setUp, { W, H });
    await page.evaluate(attach, { W, H });
    renderer ||= await page.evaluate(() => {
      const gl = window.lint.gl, ext = gl.getExtension('WEBGL_debug_renderer_info');
      return ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    });
    while (next < visuals.length) {
      const i = next++, v = visuals[i];
      await page.evaluate(() => window.audit.start());
      const got = await page.evaluate(renderOne, { v, audio, W, H, FPS, tonemap: SAFETY ? 'present' : 'lint' });
      const r = await page.evaluate(() => window.audit.finish());
      results[i] = got.error ? { id: v.id, error: got.error.split('\n')[0] } : { id: v.id, ...r };
    }
    await browser.close();
  };
  await Promise.all(Array.from({ length: Math.max(1, Math.min(parseInt(opts.jobs, 10) || 1, visuals.length)) }, job));

  mkdirSync(OUT, { recursive: true });
  writeFileSync(join(OUT, 'report.json'), JSON.stringify({ renderer, width: W, height: H, bpm: BPM, audio: opts.audio, frames: FRAMES, results }, null, 2));
  const ok = results.filter(r => !r.error);
  for (const r of results) {
    if (r.error) { console.log(`${r.id.padEnd(22)} COMPILE-FAIL ${r.error}`); continue; }
    if (r.redIn || r.redOut || r.redOverFrames) {
      console.log(`${r.id.padEnd(22)} red/s in ${r.redIn} out ${r.redOut}  red-over frames in ${r.redOverFrames} out ${r.redOverOutFrames}  ` +
        `luma/s in ${r.lumaIn} out ${r.lumaOut}  held ${r.heldMean}`);
    }
  }
  if (SAFETY) safety(results);
  const count = f => ok.filter(f).length;
  console.log(`\nrenderer: ${renderer}`);
  console.log(`${results.length} visuals, ${FRAMES} frames each at ${W} x ${H}: ` +
    `${count(r => r.redIn > 0)} show large-area red transitions unlimited (max ${Math.max(0, ...ok.map(r => r.redIn))}/s), ` +
    `${count(r => r.redOut > 0)} after the limiter; ${count(r => r.redOverFrames > 0)} trip the red area gate (${count(r => r.redOverOutFrames > 0)} with the limiter's output); ` +
    `luma over 6 transitions/s: ${count(r => r.lumaIn > 6)} in, ${count(r => r.lumaOut > 6)} out; ` +
    `${results.length - ok.length} compile failures. Report in ${join(OUT, 'report.json')}`);
  // Raw counts against the budget: a rounded fraction could pass a few pixels over it.
  const overHeld = ok.filter(r => r.heldMaxPx > MAX_HELD * r.pixels);
  for (const r of overHeld) console.log(`${r.id.padEnd(22)} HELD ${r.heldMax} of the pixels in one frame, over --max-held ${MAX_HELD}`);
  if (Number.isFinite(MAX_HELD)) {
    console.log(`${opts.audio} audio: largest held fraction ${Math.max(0, ...ok.map(r => r.heldMax))}, budget ${MAX_HELD}`);
  }
  const flashing = Number.isFinite(MAX_LUMA) ? ok.filter(r => r.lumaIn > MAX_LUMA || r.redIn > 0) : [];
  for (const r of flashing) console.log(`${r.id.padEnd(22)} FLASHES luma/s ${r.lumaIn} red/s ${r.redIn} before the limiter, over --max-luma ${MAX_LUMA} or any red`);
  // The limiter's output keeps WCAG's budgets: 1 red and 6 luma transitions a second (exit 2),
  // separately from the stricter source budget of --max-luma (Codex round 16). It is judged
  // before a compile failure's exit, which would hide it (Codex round 17).
  const overBudget = ok.filter(r => r.redOut > 1 || r.lumaOut > 6);
  for (const r of overBudget) console.log(`${r.id.padEnd(22)} OUTPUT red/s ${r.redOut} luma/s ${r.lumaOut}, over 1 red or 6 luma a second`);
  if (overBudget.length) process.exit(2);
  if (results.length > ok.length && (Number.isFinite(MAX_HELD) || Number.isFinite(MAX_LUMA))) process.exit(3);
  process.exit(overBudget.length ? 2 : overHeld.length ? 3 : flashing.length ? 4 : 0);
}

await main();
