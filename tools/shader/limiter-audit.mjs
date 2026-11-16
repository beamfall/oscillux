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
// A pixel therefore counts towards one large-area transition per change it makes, and sustained
// flashing counts every time a fresh large area changes. (Until CORE-1623 a transition was the
// rising edge of the over-area condition, which stays true while flashing is sustained, so a
// 30 Hz full-frame strobe counted 2 transitions in total and the limiter, by breaking such runs
// up, appeared to add transitions.)
// The field window is fw x fh of the frame (default the WCAG reference: a third by a third).

export const AUDIT_COVERAGE_MS = 1000 / 15;
const LUMA_STEP = 0.1, LUMA_DARK = 0.8, RED_STEP = 20, RED_SCALE = 320;

const LINEAR = Float64Array.from({ length: 256 }, (_, k) => {
  const c = k / 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
});

export function createAuditor({ width: W, height: H, field = { fw: 1 / 3, fh: 1 / 3 }, fraction = 0.25 }) {
  const N = W * H;
  const fwPx = Math.max(1, Math.min(W, Math.round(field.fw * W)));
  const fhPx = Math.max(1, Math.min(H, Math.round(field.fh * H)));
  const limit = fraction * fwPx * fhPx;
  // Per pixel and channel (0 luma, 1 red): lo, hi, dir, and the time of the last up/down fire.
  const lo = [new Float64Array(N), new Float64Array(N)], hi = [new Float64Array(N), new Float64Array(N)];
  const dir = [new Int8Array(N), new Int8Array(N)];
  const lastUp = [new Float64Array(N).fill(-Infinity), new Float64Array(N).fill(-Infinity)];
  const lastDown = [new Float64Array(N).fill(-Infinity), new Float64Array(N).fill(-Infinity)];
  const sat = new Int32Array((W + 1) * (H + 1));
  const mask = new Uint8Array(N);
  // Per direction (luma up, luma down, red up, red down): the time of its last large-area
  // transition. Pixels that changed at or before it have been counted.
  const counted = [-Infinity, -Infinity, -Infinity, -Infinity];
  let live = false, clock = 0;
  const transitions = [[], [], [], []]; // frame indices: luma up, luma down, red up, red down
  let frame = -1;

  function large(c, up) {
    const last = up ? lastUp[c] : lastDown[c], since = counted[2 * c + (up ? 0 : 1)];
    for (let j = 0; j < N; j++) mask[j] = last[j] > since && clock - last[j] <= AUDIT_COVERAGE_MS ? 1 : 0;
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
      const R = LINEAR[r], G = LINEAR[g], B = LINEAR[b], sum = R + G + B;
      const v = [0.2126 * R + 0.7152 * G + 0.0722 * B,
        sum > 0 && R / sum >= 0.8 ? RED_SCALE * Math.max(0, R - G - B) : 0];
      for (let c = 0; c < 2; c++) {
        if (!live) { lo[c][j] = hi[c][j] = v[c]; continue; }
        const step = c === 0 ? LUMA_STEP : RED_STEP, dark = c === 0 ? LUMA_DARK : Infinity;
        lo[c][j] = Math.min(lo[c][j], v[c]);
        hi[c][j] = Math.max(hi[c][j], v[c]);
        if (dir[c][j] <= 0 && v[c] - lo[c][j] >= step && lo[c][j] < dark) {
          dir[c][j] = 1; lo[c][j] = hi[c][j] = v[c]; lastUp[c][j] = clock;
        } else if (dir[c][j] >= 0 && hi[c][j] - v[c] >= step && v[c] < dark) {
          dir[c][j] = -1; lo[c][j] = hi[c][j] = v[c]; lastDown[c][j] = clock;
        }
      }
    }
    live = true;
    const now = [large(0, true), large(0, false), large(1, true), large(1, false)];
    for (let d = 0; d < 4; d++) {
      if (!now[d]) continue;
      transitions[d].push(frame);
      counted[d] = clock;
    }
    return now;
  }

  /** Most large-area transitions of a channel ('luma' or 'red') in any `seconds` window at fps. */
  function maxPerWindow(channel, fps = 60, seconds = 1) {
    const all = channel === 'luma' ? [...transitions[0], ...transitions[1]] : [...transitions[2], ...transitions[3]];
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
