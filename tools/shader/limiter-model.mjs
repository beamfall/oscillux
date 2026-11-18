// SPDX-License-Identifier: AGPL-3.0-only
// Reference model of the frame flash limiter (shaders/limiter/, conformance/limiter/frame/).
// Every decision is integer arithmetic on 16-bit codes, so the GLSL passes reproduce it bit for
// bit. Per frame:
//   1. Box reduction: the frame is partitioned into 64 x 36 sub-blocks (x in
//      [floor(i W / 64), floor((i + 1) W / 64)), likewise y), so every pixel counts once. A
//      sub-block's luma code is the rounded mean of LUMA_LUT[r][0] + LUMA_LUT[g][1] + LUMA_LUT[b][2];
//      its red code the rounded mean of R - G - B over the saturated-red pixels, 5 R >= 4 (R + G + B),
//      where R, G, B are the linear channel codes LUMA_LUT[k][3] = round(65535 linear(k / 255)).
//      Both tests are on linear light, as WCAG 2.x defines them (relative luminance; red
//      saturation R / (R + G + B) >= 0.8 and the red change 320 max(0, R - G - B)).
//      Not modelled: WCAG 2.2's alternative red test (one state saturated red and the two states
//      more than 0.2 apart in CIE 1976 u'v'). It compares each pixel's own two states through a
//      nonlinear division and a 2-D distance, which the integer sums cannot carry bit for bit
//      (GLSL ES 3.00 has no 64-bit integers and no correctly rounded float division).
//   2. Requests: each sub-block tracks luma and red (the WCAG audit counter's step) and requests
//      a transition when the frame would make one: luma 6554 codes (0.1) with the darker side below
//      52428 (0.8); red 512 codes (2.5 on the 320 * (R - G - B) scale, an eighth of the auditor's
//      per-pixel step of 20, because a block mean dilutes red that covers part of the block:
//      CORE-1616, openspec/changes/limiter-red-dilution/).
//   3. Cell counts: per 16 x 9 cell and direction, the sub-blocks requesting now or having made
//      that transition within the coverage interval (1000/15 ms).
//   4. Area gate: a direction is over when some window of cols x rows cells (the 10° field for
//      the viewing geometry, limiter-geometry.mjs) holds more than `limit` such sub-blocks.
//   5. Grant: luminance over the limit is rationed by a token budget refilled by
//      floor(clamp(2 maxFlashHz dt, 0, 1) * 65025) a frame; red over the limit by its own budget
//      refilled by an eighth of that (integer), so no 1 s window holds two large-area red
//      transitions (no red flash) and held red catches up instead of freezing (CORE-2382).
//   6. Hold: a sub-block requesting a transition that is not admitted shows the previous output
//      frame, and its trackers do not advance; every other sub-block shows the input.
//   7. Blend: a hold has no hard edge. The hold field at each sub-block centre, 0..64, is the
//      largest over the held sub-blocks within four of it on each axis of clamp(72 - 4 d2, 0, 64),
//      d2 the squared distance in sub-blocks: 64 at a held sub-block and its eight neighbours,
//      0 a little past four away. A pixel of a sub-block that is not held takes the field
//      bilinearly between the four sub-block centres around it: with centre(k) = floor(k S / n) +
//      floor((k + 1) S / n) in half pixels on each axis, l the sub-block whose centre is at or
//      before the pixel's 2 p + 1 and f = floor(64 (2 p + 1 - centre(l)) / (centre(l + 1) -
//      centre(l))), t is the sum of the four field values weighted (64 - fx or fx) (64 - fy or
//      fy), shifted right by 6, in 0..4096; outside the first and last centres the pixel takes
//      its own sub-block on that axis. The weight is eased, w = ((t^2 >> 12) (12288 - 2 t)) >> 12,
//      and the pixel shows (input (4096 - w) + history w + 2048) >> 12 per 8-bit channel. The
//      field is continuous across sub-block boundaries, reaches 1 before the hold begins and
//      falls off round, so the output steps nowhere the input and the history do not. Red is
//      blended too, unless the blend moves the pixel's red code (R - G - B on linear codes when
//      saturated red, as the reduction sums it) further from its history's than the input does;
//      then the pixel shows the input, so the blend never adds red change the red token did not
//      grant (CORE-2231, CORE-2328, CORE-2413, openspec/changes/limiter-red-feather/).
//
// createLimiter({ width, height, geometry, maxFlashHz }).step(rgba8, dt) returns
//   { out, held, holdMask, grant, deficit, redDeficit, stats: { requests, over, admitted, fired } }.
// `out` is reused every other frame.
import { GRID_X, GRID_Y, SUB, windowOf } from './limiter-geometry.mjs';

export const MODEL = 'subblock-10deg';
export const BLOCKS_X = GRID_X * SUB, BLOCKS_Y = GRID_Y * SUB;
const BLOCKS = BLOCKS_X * BLOCKS_Y;
const CELLS = GRID_X * GRID_Y;
export const LUMA_STEP = 6554, LUMA_DARK = 52428, RED_STEP = 512, NO_DARK = 65536;
export const TOKEN = 65025;
export const COVERAGE_MS = 1000 / 15;
export const TICK_MS = COVERAGE_MS / 64;

/** Per 8-bit display value k: round(65535 * weight * linear(k / 255)) for the Rec. 709 weights
 * (R, G, B), then the unweighted linear code round(65535 * linear(k / 255)). */
export const LUMA_LUT = Array.from({ length: 256 }, (_, k) => {
  const c = k / 255;
  const lin = c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  return [Math.round(65535 * 0.2126 * lin), Math.round(65535 * 0.7152 * lin), Math.round(65535 * 0.0722 * lin),
    Math.round(65535 * lin)];
});
const LR = Int32Array.from(LUMA_LUT, v => v[0]);
const LG = Int32Array.from(LUMA_LUT, v => v[1]);
const LB = Int32Array.from(LUMA_LUT, v => v[2]);
const LIN = Int32Array.from(LUMA_LUT, v => v[3]);

/** The host clock: tick in [0, 255), the frame interval in ms, and the token refill. */
export function createClock(maxFlashHz = 3) {
  let ms = 0;
  return dt => {
    ms += dt * 1000;
    return { tick: Math.floor(ms / TICK_MS) % 255, deltaMs: Math.fround(dt * 1000),
      refill: Math.floor(Math.min(1, Math.max(0, 2 * maxFlashHz * dt)) * TOKEN) };
  };
}

// The audit counter's step on a tracker {lo, hi, dir}: 1 rising, -1 falling, 0 none.
export function trackStep(t, v, step, dark) {
  t.lo = Math.min(t.lo, v);
  t.hi = Math.max(t.hi, v);
  const up = t.dir <= 0 && v - t.lo >= step && t.lo < dark;
  const down = t.dir >= 0 && t.hi - v >= step && v < dark;
  if (up) { t.dir = 1; t.lo = v; t.hi = v; return 1; }
  if (down) { t.dir = -1; t.lo = v; t.hi = v; return -1; }
  return 0;
}

/** A recency stamp (event tick + 1, 0 absent) that is still inside the coverage interval. */
export function recent(r, tick, deltaMs) {
  const elapsed = (tick - (r - 1) + 255) % 255;
  return r > 0 && deltaMs <= Math.fround(COVERAGE_MS) && elapsed <= 64 ? r : 0;
}

/** Sub-block of pixel x in a frame of size n along an axis with `blocks` sub-blocks. */
export const blockOf = (x, n, blocks) => Math.floor((blocks * (x + 1) - 1) / n);

/** Sub-block means of luma (L) and red (R) codes. With the previous output `hist`, also P: per
 * sub-block, 3 (luma up and down) when at least 7/16 of its pixels rose by a luma step
 * against it and at least 7/16 fell (the darker side below LUMA_DARK), else 0. A sub-block
 * mean cancels such opposing changes (a fine pattern reversing), so the pixel counts catch them
 * (CORE-2515); a change in one direction moves the mean and the trackers catch it. */
export function reduce(px, W, H, L, R, hist, P) {
  for (let j = 0; j < BLOCKS_Y; j++) {
    const y0 = Math.floor((j * H) / BLOCKS_Y), y1 = Math.floor(((j + 1) * H) / BLOCKS_Y);
    for (let i = 0; i < BLOCKS_X; i++) {
      const x0 = Math.floor((i * W) / BLOCKS_X), x1 = Math.floor(((i + 1) * W) / BLOCKS_X);
      let sy = 0, sr = 0, up = 0, down = 0;
      for (let y = y0; y < y1; y++) {
        for (let x = x0, p = (y * W + x0) * 4; x < x1; x++, p += 4) {
          const r = px[p], g = px[p + 1], b = px[p + 2];
          const v = LR[r] + LG[g] + LB[b];
          sy += v;
          if (hist) {
            const h = LR[hist[p]] + LG[hist[p + 1]] + LB[hist[p + 2]];
            if (v - h >= LUMA_STEP && h < LUMA_DARK) up++;
            if (h - v >= LUMA_STEP && v < LUMA_DARK) down++;
          }
          const R = LIN[r], G = LIN[g], B = LIN[b], s = R + G + B;
          if (s > 0 && 5 * R >= 4 * s && R > G + B) sr += R - G - B;
        }
      }
      const n = (x1 - x0) * (y1 - y0);
      const k = j * BLOCKS_X + i;
      L[k] = Math.min(65535, Math.floor((sy + (n >> 1)) / n));
      R[k] = Math.min(65535, Math.floor((sr + (n >> 1)) / n));
      if (P) P[k] = 16 * up >= 7 * n && 16 * down >= 7 * n ? 3 : 0;
    }
  }
}

export function createLimiter({ width: W, height: H, geometry = 'wcag', maxFlashHz = 3 }) {
  if (W < BLOCKS_X || H < BLOCKS_Y) throw new Error(`limiter: frame ${W}x${H} is under ${BLOCKS_X}x${BLOCKS_Y}`);
  const win = windowOf(geometry);
  const clock = createClock(maxFlashHz);
  const L = new Int32Array(BLOCKS), R = new Int32Array(BLOCKS), P = new Uint8Array(BLOCKS);
  // Tracker state: luma lo/hi/dir, red lo/hi/dir, live, recency stamps (4 per sub-block).
  const lumaT = Array.from({ length: BLOCKS }, () => ({ lo: 0, hi: 0, dir: 0 }));
  const redT = Array.from({ length: BLOCKS }, () => ({ lo: 0, hi: 0, dir: 0 }));
  const live = new Uint8Array(BLOCKS);
  const rec = new Uint8Array(BLOCKS * 4);
  const req = new Uint8Array(BLOCKS);
  const holdMask = new Uint8Array(BLOCKS);
  const cnt = new Int32Array(CELLS * 4);
  const scratch = { lo: 0, hi: 0, dir: 0 };
  let deficit = 0;
  let owed = 0;
  let redDeficit = 0;
  const bufs = [new Uint8Array(W * H * 4), new Uint8Array(W * H * 4)];
  let flip = 0;
  const colBlock = Int32Array.from({ length: W }, (_, x) => blockOf(x, W, BLOCKS_X));
  const rowBlock = Int32Array.from({ length: H }, (_, y) => blockOf(y, H, BLOCKS_Y));
  // Per pixel on one axis: the first of the two sub-blocks whose centres it lies between (the
  // second is the next one) and the second's weight in sixty-fourths. Before the first centre and
  // after the last the pixel takes its own sub-block alone.
  const span = (p, size, n) => {
    const b = blockOf(p, size, n), at = 2 * p + 1;
    const centre = k => Math.floor(k * size / n) + Math.floor((k + 1) * size / n);
    const l = at < centre(b) ? b - 1 : b;
    if (l < 0 || l + 1 >= n) return [b, 0];
    return [l, Math.floor(64 * (at - centre(l)) / (centre(l + 1) - centre(l)))];
  };
  const cols = Array.from({ length: W }, (_, x) => span(x, W, BLOCKS_X));
  const rows = Array.from({ length: H }, (_, y) => span(y, H, BLOCKS_Y));
  const colL = Int32Array.from(cols, c => c[0]), colF = Int32Array.from(cols, c => c[1]);
  const rowL = Int32Array.from(rows, c => c[0]), rowF = Int32Array.from(rows, c => c[1]);
  // The hold field at each sub-block centre, 0..64: the largest over the held sub-blocks within
  // four of it on each axis of clamp(72 - 4 d2, 0, 64), d2 the squared distance in sub-blocks. It
  // is 64 at a held sub-block and its eight neighbours and falls to 0 a little past four away.
  const field = new Uint8Array(BLOCKS);
  const fieldAt = (bx, by) => (bx >= BLOCKS_X || by >= BLOCKS_Y ? 0 : field[by * BLOCKS_X + bx]);
  const FIELD_REACH = 4;
  // A pixel's red code, as the reduction sums it: R - G - B on linear codes when saturated red.
  const redOf = (a, i) => {
    const R = LIN[a[i]], G = LIN[a[i + 1]], B = LIN[a[i + 2]], s = R + G + B;
    return s > 0 && 5 * R >= 4 * s && R > G + B ? R - G - B : 0;
  };

  const fires = (t, v, step, dark) => {
    scratch.lo = t.lo; scratch.hi = t.hi; scratch.dir = t.dir;
    return trackStep(scratch, v, step, dark);
  };

  function step(px, dt) {
    const { tick, deltaMs, refill } = clock(dt);
    reduce(px, W, H, L, R, bufs[flip], P);
    const requests = [0, 0, 0, 0];
    cnt.fill(0);
    for (let k = 0; k < BLOCKS; k++) {
      let bits = 0;
      if (live[k]) {
        const fl = fires(lumaT[k], L[k], LUMA_STEP, LUMA_DARK);
        const fr = fires(redT[k], R[k], RED_STEP, NO_DARK);
        bits = (fl > 0 ? 1 : 0) | (fl < 0 ? 2 : 0) | (fr > 0 ? 4 : 0) | (fr < 0 ? 8 : 0) | P[k];
      }
      req[k] = bits;
      const cell = Math.floor(Math.floor(k / BLOCKS_X) / SUB) * GRID_X + Math.floor((k % BLOCKS_X) / SUB);
      for (let d = 0; d < 4; d++) {
        const q = (bits >> d) & 1;
        requests[d] += q;
        if (q || recent(rec[4 * k + d], tick, deltaMs)) cnt[4 * cell + d]++;
      }
    }
    // Worst window per direction.
    const over = [false, false, false, false];
    for (let y0 = 0; y0 + win.rows <= GRID_Y; y0++) {
      for (let x0 = 0; x0 + win.cols <= GRID_X; x0++) {
        for (let d = 0; d < 4; d++) {
          let s = 0;
          for (let y = y0; y < y0 + win.rows; y++) for (let x = x0; x < x0 + win.cols; x++) s += cnt[4 * (y * GRID_X + x) + d];
          if (s > win.limit) over[d] = true;
        }
      }
    }
    // Luminance shares one token budget; red has its own, refilled at an eighth of the luma rate,
    // so it never takes or waits for the luminance token and no 1 s window holds two large-area
    // red transitions: no saturated-red flash (ITU-R BT.1702, ADR-0232 R5), and a held red change
    // is admitted within 8 / (2 maxFlashHz) s instead of freezing (R7, CORE-2382).
    // Both luma directions may be admitted in one frame (a pattern reversing: some pixels rise,
    // others fall); that costs two tokens, the second owed and taken when the first has refilled.
    deficit = Math.max(0, deficit - refill);
    if (deficit <= 0 && owed) { deficit = TOKEN; owed = 0; }
    const grantUp = over[0] && requests[0] > 0 && deficit <= 0;
    const grantDown = over[1] && requests[1] > 0 && deficit <= 0;
    if (grantUp || grantDown) deficit = TOKEN;
    if (grantUp && grantDown) owed = 1;
    redDeficit = Math.max(0, redDeficit - Math.floor(refill / 8));
    const grantRedUp = over[2] && requests[2] > 0 && redDeficit <= 0;
    if (grantRedUp) redDeficit = TOKEN;
    const grantRedDown = over[3] && requests[3] > 0 && redDeficit <= 0;
    if (grantRedDown) redDeficit = TOKEN;
    const admitted = [!over[0] || grantUp, !over[1] || grantDown, !over[2] || grantRedUp, !over[3] || grantRedDown];
    let grant = 0;
    for (let d = 0; d < 4; d++) grant |= (admitted[d] ? 1 << d : 0) | (over[d] ? 16 << d : 0);

    let held = 0;
    const fired = [0, 0, 0, 0];
    for (let k = 0; k < BLOCKS; k++) {
      const h = req[k] & ~grant & 15 ? 1 : 0;
      holdMask[k] = h;
      held += h;
      if (!live[k]) {
        live[k] = 1;
        lumaT[k].lo = lumaT[k].hi = L[k]; lumaT[k].dir = 0;
        redT[k].lo = redT[k].hi = R[k]; redT[k].dir = 0;
        rec.fill(0, 4 * k, 4 * k + 4);
        continue;
      }
      if (h) {
        for (let d = 0; d < 4; d++) rec[4 * k + d] = recent(rec[4 * k + d], tick, deltaMs);
        continue;
      }
      trackStep(lumaT[k], L[k], LUMA_STEP, LUMA_DARK);
      trackStep(redT[k], R[k], RED_STEP, NO_DARK);
      // An admitted sub-block makes the transitions it requested: the trackers' and the pixel counts'.
      const f = [0, 1, 2, 3].map(d => ((req[k] >> d) & 1) === 1);
      for (let d = 0; d < 4; d++) {
        rec[4 * k + d] = f[d] ? tick + 1 : recent(rec[4 * k + d], tick, deltaMs);
        fired[d] += f[d] ? 1 : 0;
      }
    }

    const history = bufs[flip];
    flip ^= 1;
    const out = bufs[flip];
    field.fill(0);
    for (let k = 0; k < BLOCKS; k++) {
      if (!holdMask[k]) continue;
      const bx = k % BLOCKS_X, by = (k - bx) / BLOCKS_X;
      for (let j = Math.max(0, by - FIELD_REACH); j <= Math.min(BLOCKS_Y - 1, by + FIELD_REACH); j++) {
        for (let i = Math.max(0, bx - FIELD_REACH); i <= Math.min(BLOCKS_X - 1, bx + FIELD_REACH); i++) {
          const v = Math.min(64, Math.max(0, 72 - 4 * ((i - bx) * (i - bx) + (j - by) * (j - by))));
          if (v > field[j * BLOCKS_X + i]) field[j * BLOCKS_X + i] = v;
        }
      }
    }
    for (let y = 0; y < H; y++) {
      const by = rowBlock[y], t = rowL[y], fy = rowF[y];
      for (let x = 0, i = y * W * 4; x < W; x++, i += 4) {
        let src = px;
        if (holdMask[by * BLOCKS_X + colBlock[x]]) src = history;
        else {
          const l = colL[x], fx = colF[x];
          const lin = (fieldAt(l, t) * (64 - fx) + fieldAt(l + 1, t) * fx) * (64 - fy)
            + (fieldAt(l, t + 1) * (64 - fx) + fieldAt(l + 1, t + 1) * fx) * fy;
          if (lin > 63) {
            const u = lin >> 6;
            const w = (((u * u) >> 12) * (12288 - 2 * u)) >> 12;
            for (let c = 0; c < 3; c++) out[i + c] = (px[i + c] * (4096 - w) + history[i + c] * w + 2048) >> 12;
            out[i + 3] = 255;
            const mh = redOf(history, i);
            if (Math.abs(redOf(out, i) - mh) <= Math.abs(redOf(px, i) - mh)) continue;
          }
        }
        out[i] = src[i]; out[i + 1] = src[i + 1]; out[i + 2] = src[i + 2]; out[i + 3] = 255;
      }
    }
    return { out, held, holdMask, grant, deficit, redDeficit, stats: { requests, over, admitted, fired } };
  }

  return { step, window: win };
}
