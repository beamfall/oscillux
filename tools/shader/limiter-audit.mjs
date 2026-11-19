// SPDX-License-Identifier: AGPL-3.0-only
// Independent flash auditor for the frame flash limiter's output. It knows nothing of cells or
// sub-blocks: every pixel has its own transition tracker (WCAG 2.x general flash: a change of at
// least 0.1 relative luminance whose darker side is below 0.8; red flash: a change of at least 20
// in 320 * max(0, R - G - B) on pixels with R / (R + G + B) >= 0.8, where R, G, B are the
// linearised channels, as in WCAG's relative-luminance definition). It does not apply WCAG 2.2's
// working chromaticity rule (a CIE 1976 u'v' change of more than 0.2 from a saturated-red state).
// A direction makes a large-area transition at a frame where some placement of the field window
// holds more than `fraction` of the window's pixels that made that transition within the coverage
// interval (1000/15 ms, as the limiter) and after the direction's previous large-area transition.
// Pixels flash together whichever way they change, so a channel also makes one where the window
// holds more than `fraction` of pixels that made either of its transitions (WCAG's combined area),
// though neither direction alone does.
// A pixel therefore counts towards one large-area transition per change it makes, and sustained
// flashing counts every time a fresh large area changes. (Until CORE-1623 a transition was the
// rising edge of the over-area condition, which stays true while flashing is sustained, so a
// 30 Hz full-frame strobe counted 2 transitions in total and the limiter, by breaking such runs
// up, appeared to add transitions.)
// The field window is fw x fh of the frame (default the WCAG reference: a third by a third).

import { LUMA_DARK, LUMA_STEP, RED_STEP, lumaCode, redCode, redSat } from './limiter-model.mjs';

export const AUDIT_COVERAGE_MS = 1000 / 15;
// The measures are the limiter's codes (limiter-model.mjs: lumaCode, redCode, redSat), and the
// codes are the measure: luma steps of 3276 15-bit codes (0.1 relative luminance) with the darker
// side below 26215 (0.8); red steps of 16 codes (20 of WCAG's 320 scale) of (R - G - B) >> 8
// wherever R > G + B, firing only when the new state or one since the last red fire is saturated
// red, a superset of WCAG's saturated-red transitions. Until
// v0.2.9 the auditor measured in floating point, so a change within a rounding of a threshold
// could fire one tracker and not the other.
export function createAuditor({ width: W, height: H, field = { fw: 1 / 3, fh: 1 / 3 }, fraction = 0.25 }) {
  const N = W * H;
  const fwPx = Math.max(1, Math.min(W, Math.round(field.fw * W)));
  const fhPx = Math.max(1, Math.min(H, Math.round(field.fh * H)));
  const limit = fraction * fwPx * fhPx;
  // Per pixel and channel (0 luma, 1 red): lo, hi, dir, and the time of the last up/down fire.
  const lo = [new Float64Array(N), new Float64Array(N)], hi = [new Float64Array(N), new Float64Array(N)];
  const dir = [new Int8Array(N), new Int8Array(N)];
  // Per pixel: whether a saturated red state was seen since its red tracker last fired.
  const anySat = new Uint8Array(N);
  const lastUp = [new Float64Array(N).fill(-Infinity), new Float64Array(N).fill(-Infinity)];
  const lastDown = [new Float64Array(N).fill(-Infinity), new Float64Array(N).fill(-Infinity)];
  const sat = new Int32Array((W + 1) * (H + 1));
  const mask = new Uint8Array(N);
  // Per direction (luma up, luma down, red up, red down): the time of its last large-area
  // transition. Pixels that changed at or before it have been counted.
  const counted = [-Infinity, -Infinity, -Infinity, -Infinity];
  const countedAny = [-Infinity, -Infinity]; // per channel, the combined area's

  let live = false, clock = 0;
  // Frame indices: luma up, luma down, red up, red down, then combined-only luma and red.
  const transitions = [[], [], [], [], [], []];
  let frame = -1;

  const fresh = (t, since) => t > since && clock - t <= AUDIT_COVERAGE_MS;
  // up: true, false, or null for either direction (the channel's combined area).
  function large(c, up) {
    if (up === null) {
      const su = countedAny[c], u = lastUp[c], d = lastDown[c];
      for (let j = 0; j < N; j++) mask[j] = fresh(u[j], su) || fresh(d[j], su) ? 1 : 0;
    } else {
      const last = up ? lastUp[c] : lastDown[c], since = counted[2 * c + (up ? 0 : 1)];
      for (let j = 0; j < N; j++) mask[j] = fresh(last[j], since) ? 1 : 0;
    }
    for (let y = 0; y < H; y++) {
      let run = 0;
      for (let x = 0; x < W; x++) {
        run += mask[y * W + x];
        sat[(y + 1) * (W + 1) + x + 1] = sat[y * (W + 1) + x + 1] + run;
      }
    }
    for (let y = 0; y + fhPx <= H; y++) {
      for (let x = 0; x + fwPx <= W; x++) {
        const s = sat[(y + fhPx) * (W + 1) + x + fwPx] - sat[y * (W + 1) + x + fwPx]
          - sat[(y + fhPx) * (W + 1) + x] + sat[y * (W + 1) + x];
        if (s > limit) return true;
      }
    }
    return false;
  }

  function push(px, dt) {
    frame++;
    clock += dt * 1000;
    for (let j = 0, i = 0; j < N; j++, i += 4) {
      const r = px[i], g = px[i + 1], b = px[i + 2];
      const v = [lumaCode(r, g, b), redCode(r, g, b)], sat = redSat(r, g, b) ? 1 : 0;
      if (!live) anySat[j] = sat;
      for (let c = 0; c < 2; c++) {
        if (!live) { lo[c][j] = hi[c][j] = v[c]; continue; }
        const step = c === 0 ? LUMA_STEP : RED_STEP, dark = c === 0 ? LUMA_DARK : Infinity;
        const gate = c === 0 || sat || anySat[j];
        lo[c][j] = Math.min(lo[c][j], v[c]);
        hi[c][j] = Math.max(hi[c][j], v[c]);
        let fired = true;
        if (gate && dir[c][j] <= 0 && v[c] - lo[c][j] >= step && lo[c][j] < dark) {
          dir[c][j] = 1; lo[c][j] = hi[c][j] = v[c]; lastUp[c][j] = clock;
        } else if (gate && dir[c][j] >= 0 && hi[c][j] - v[c] >= step && v[c] < dark) {
          dir[c][j] = -1; lo[c][j] = hi[c][j] = v[c]; lastDown[c][j] = clock;
        } else fired = false;
        if (c === 1) anySat[j] = fired ? sat : anySat[j] | sat;
      }
    }
    live = true;
    const now = [large(0, true), large(0, false), large(1, true), large(1, false)];
    for (let d = 0; d < 4; d++) {
      if (!now[d]) continue;
      transitions[d].push(frame);
      counted[d] = clock;
      countedAny[d >> 1] = clock;
    }
    for (let c = 0; c < 2; c++) {
      if (now[2 * c] || now[2 * c + 1] || !large(c, null)) continue;
      transitions[4 + c].push(frame);
      counted[2 * c] = counted[2 * c + 1] = countedAny[c] = clock;
    }
    return now;
  }

  /** Most large-area transitions of a channel ('luma' or 'red') in any `seconds` window at fps. */
  function maxPerWindow(channel, fps = 60, seconds = 1) {
    const all = channel === 'luma' ? [...transitions[0], ...transitions[1], ...transitions[4]]
      : [...transitions[2], ...transitions[3], ...transitions[5]];
    all.sort((a, b) => a - b);
    let best = 0;
    for (let i = 0, j = 0; i < all.length; i++) {
      while (all[i] - all[j] >= fps * seconds) j++;
      best = Math.max(best, i - j + 1);
    }
    return best;
  }

  return { push, maxPerWindow, transitions, window: { fwPx, fhPx, limit } };
}
