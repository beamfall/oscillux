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
// Pixels flash together whichever way and in whichever channel they change, so a channel also
// makes one where the window holds more than `fraction` of pixels that made either of its
// transitions, and the frame makes one where it holds more than `fraction` of pixels that made any
// transition (WCAG's combined area), though no narrower count does; a combined transition is
// charged to the channels that made one of its pixel transitions.
// A pixel therefore counts towards one large-area transition per change it makes, and sustained
// flashing counts every time a fresh large area changes. (Until CORE-1623 a transition was the
// rising edge of the over-area condition, which stays true while flashing is sustained, so a
// 30 Hz full-frame strobe counted 2 transitions in total and the limiter, by breaking such runs
// up, appeared to add transitions.)
// The field window is fw x fh of the frame (default the WCAG reference: a third by a third);
// setGeometry(field) changes it on a live display, and each transition is judged in the field
// shown when it happened.

import { LUMA_DARK, LUMA_STEP, RED_STEP, lumaCode, redCode, redSat } from './limiter-model.mjs';

export const AUDIT_COVERAGE_MS = 1000 / 15;
// The measures are the limiter's codes (limiter-model.mjs: lumaCode, redCode, redSat), and the
// codes are the measure: luma steps of 3275 15-bit codes (0.1 relative luminance) with the darker
// side below 26215 (0.8); red steps of 15 codes (20 of WCAG's 320 scale) of (R - G - B) >> 8
// wherever R > G + B, each the WCAG threshold less the codes' error. Every red step moves the
// pixel's red tracker; it counts as a red transition when the new state or one since the previous
// step is saturated red, or, when it did not, at the first saturated state before the next step: a
// superset of WCAG's saturated-red transitions. Until v0.2.9 the auditor measured in floating
// point, so a change within a rounding of a threshold could fire one tracker and not the other.
export function createAuditor({ width: W, height: H, field = { fw: 1 / 3, fh: 1 / 3 }, fraction = 0.25 }) {
  const N = W * H;
  let fwPx, fhPx, limit;
  const shape = f => {
    fwPx = Math.max(1, Math.min(W, Math.round(f.fw * W)));
    fhPx = Math.max(1, Math.min(H, Math.round(f.fh * H)));
    limit = fraction * fwPx * fhPx;
  };
  shape(field);
  // Per pixel and channel (0 luma, 1 red): the direction of the last transition (1 up, -1 down;
  // a pixel starts as if it fell to its first value), the extreme since it and the level at it.
  const ext = [new Float64Array(N), new Float64Array(N)], ref = [new Float64Array(N), new Float64Array(N)];
  const dir = [new Int8Array(N), new Int8Array(N)];
  // Per pixel: whether the red tracker's latest step counted, and whether a saturated red state
  // was seen since it.
  const redCounted = new Uint8Array(N), anySat = new Uint8Array(N);
  const last = [new Float64Array(N).fill(-Infinity), new Float64Array(N).fill(-Infinity),
    new Float64Array(N).fill(-Infinity), new Float64Array(N).fill(-Infinity)]; // luma up, down, red up, down
  const integral = new Int32Array((W + 1) * (H + 1));
  const mask = new Uint8Array(N);
  // A charge consumes only the evidence inside the placements over the limit: a pixel's change is
  // forgotten once it has counted towards one, and kept everywhere else, so a charge in one field
  // or direction cannot erase another's pending area (Codex rounds 16, 17).
  const diff = new Int32Array((W + 1) * (H + 1));
  const firedNow = [false, false];

  let live = false, clock = 0;
  // Frame indices and times: luma up, luma down, red up, red down, then combined-only luma and red.
  const transitions = [[], [], [], [], [], []];
  const times = [[], [], [], [], [], []];
  let frame = -1;

  const fresh = t => clock - t <= AUDIT_COVERAGE_MS;
  // The pixels inside some field placement over the limit of the integral `sum` and passing
  // `keep(x, y)`, or null when there is none.
  function cover(sum, keep = () => true) {
    diff.fill(0);
    let any = false;
    for (let y = 0; y + fhPx <= H; y++) {
      for (let x = 0; x + fwPx <= W; x++) {
        if (box(sum, x, y) <= limit || !keep(x, y)) continue;
        any = true;
        diff[y * (W + 1) + x]++; diff[y * (W + 1) + x + fwPx]--;
        diff[(y + fhPx) * (W + 1) + x]--; diff[(y + fhPx) * (W + 1) + x + fwPx]++;
      }
    }
    if (!any) return null;
    const out = new Uint8Array(N), row = new Int32Array(W + 1);
    for (let y = 0; y < H; y++) {
      let run = 0;
      for (let x = 0; x < W; x++) {
        run += diff[y * (W + 1) + x];
        row[x] += run;
        out[y * W + x] = row[x] > 0 ? 1 : 0;
      }
    }
    return out;
  }
  // The pixels inside some field placement holding more than the limit of pixels fresh in a
  // direction of `dirs`, or null.
  function large(dirs) {
    fill(integral, j => dirs.some(d => fresh(last[d][j])));
    return cover(integral);
  }

  const sums = [new Int32Array((W + 1) * (H + 1)), new Int32Array((W + 1) * (H + 1))];
  const freshIn = c => j => fresh(last[2 * c][j]) || fresh(last[2 * c + 1][j]);
  function fill(sum, test) {
    for (let y = 0; y < H; y++) {
      let run = 0;
      for (let x = 0; x < W; x++) {
        run += test(y * W + x) ? 1 : 0;
        sum[(y + 1) * (W + 1) + x + 1] = sum[y * (W + 1) + x + 1] + run;
      }
    }
  }
  const box = (sum, x, y) => sum[(y + fhPx) * (W + 1) + x + fwPx] - sum[y * (W + 1) + x + fwPx]
    - sum[(y + fhPx) * (W + 1) + x] + sum[y * (W + 1) + x];
  // The channels with a fresh pixel inside some field placement whose fresh pixels, in any channel
  // and direction, are over the limit: the combined area is charged to them, whatever happens
  // elsewhere in the frame (Codex round 15).
  function combined() {
    const lumaFresh = freshIn(0), redFresh = freshIn(1);
    fill(integral, j => lumaFresh(j) || redFresh(j));
    fill(sums[0], lumaFresh);
    fill(sums[1], redFresh);
    return [0, 1].map(c => cover(integral, (x, y) => box(sums[c], x, y) > 0));
  }
  // Forgets the changes in directions `dirs` inside `area`: they have counted.
  function consume(area, dirs) {
    if (area) for (let j = 0; j < N; j++) if (area[j]) for (const d of dirs) last[d][j] = -Infinity;
  }

  function record(k) { transitions[k].push(frame); times[k].push(clock); }

  // One tracker step; returns 1 rising, -1 falling, 0 none. A step of the threshold is a transition
  // against the last one's direction (from the extreme since it) or onward from the level at it,
  // or the furthest the value has gone back since: a rise, a pause and a further rise of a step
  // are two (Codex round 16), and so are a dip short of a step and a step up from it (round 17).
  function track(c, j, v) {
    const step = c === 0 ? LUMA_STEP : RED_STEP, dark = c === 0 ? LUMA_DARK : Infinity;
    const e = ext[c], r = ref[c], d = dir[c];
    if (d[j] > 0) {
      if (e[j] - v >= step && v < dark) { d[j] = -1; e[j] = r[j] = v; return -1; }
      r[j] = Math.min(r[j], v);
      e[j] = Math.max(e[j], v);
      if (e[j] - r[j] < step) return 0;
      const darker = r[j];
      r[j] = e[j];
      return darker < dark ? 1 : 0;
    }
    if (v - e[j] >= step && e[j] < dark) { d[j] = 1; e[j] = r[j] = v; return 1; }
    r[j] = Math.max(r[j], v);
    e[j] = Math.min(e[j], v);
    if (r[j] - e[j] < step) return 0;
    r[j] = e[j];
    return e[j] < dark ? -1 : 0;
  }

  function push(px, dt) {
    frame++;
    clock += dt * 1000;
    firedNow[0] = firedNow[1] = false;
    for (let j = 0, i = 0; j < N; j++, i += 4) {
      const r = px[i], g = px[i + 1], b = px[i + 2];
      const v = lumaCode(r, g, b), rv = redCode(r, g, b), sat = redSat(r, g, b);
      if (!live) {
        ext[0][j] = ref[0][j] = v; ext[1][j] = ref[1][j] = rv; dir[0][j] = dir[1][j] = -1;
        redCounted[j] = 1; anySat[j] = sat ? 1 : 0;
        continue;
      }
      const fl = track(0, j, v);
      if (fl !== 0) { last[fl > 0 ? 0 : 1][j] = clock; firedNow[0] = true; }
      const fr = track(1, j, rv);
      let count = 0;
      if (fr !== 0) {
        redCounted[j] = sat || anySat[j] ? 1 : 0;
        if (redCounted[j]) count = fr;
        anySat[j] = sat ? 1 : 0;
      } else {
        if (!redCounted[j] && sat) { count = dir[1][j]; redCounted[j] = 1; }
        if (sat) anySat[j] = 1;
      }
      if (count !== 0) { last[count > 0 ? 2 : 3][j] = clock; firedNow[1] = true; }
    }
    live = true;
    // Every test reads the counts as they stood before this frame's charges, so a large area in one
    // field cannot hide another field's narrower or combined area (Codex round 15).
    const now = [large([0]), large([1]), large([2]), large([3])];
    const channel = [large([0, 1]), large([2, 3])];
    // The combined area, only on a frame where something changed: it is charged to every channel
    // with a fresh pixel in an over placement, so staggering red a frame behind luma charges both
    // (Codex round 14).
    const more = firedNow[0] || firedNow[1] ? combined() : [null, null];
    const both = [false, false];
    for (let d = 0; d < 4; d++) if (now[d]) record(d);
    for (let c = 0; c < 2; c++) {
      both[c] = !now[2 * c] && !now[2 * c + 1] && Boolean(channel[c] || more[c]);
      if (both[c]) record(4 + c);
    }
    for (let d = 0; d < 4; d++) consume(now[d], [d]);
    // A combined charge consumes only the channels it was charged to: the others' pixels have not
    // been counted (Codex round 16).
    for (let c = 0; c < 2; c++) {
      if (both[c]) consume(channel[c], [2 * c, 2 * c + 1]);
      consume(more[c], [2 * c, 2 * c + 1]);
    }
    return now.map(Boolean);
  }

  /** Most large-area transitions of a channel ('luma' or 'red') in any `seconds` window. */
  function maxPerWindow(channel, seconds = 1) {
    const ks = channel === 'luma' ? [0, 1, 4] : [2, 3, 5];
    const all = ks.flatMap(k => times[k]).sort((a, b) => a - b);
    let best = 0;
    for (let i = 0, j = 0; i < all.length; i++) {
      while (all[i] - all[j] >= 1000 * seconds - 1e-6) j++;
      best = Math.max(best, i - j + 1);
    }
    return best;
  }

  /** A new viewing field on a live display: transitions from before it were judged in the old one. */
  function setGeometry(f) {
    shape(f);
    for (const l of last) l.fill(-Infinity);
  }

  return { push, maxPerWindow, setGeometry, transitions, get window() { return { fwPx, fhPx, limit }; } };
}
