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
//      frame, and its trackers do not advance; every other pixel shows the input exactly, so
//      the output makes only the transitions the trackers counted. (Until v0.2.9 the pixels
//      around a hold blended toward the previous output; a blended change appeared after the
//      token it spent had refilled, so the output could make seven luma transitions in 1 s:
//      CORE-2543, CORE-2541, openspec/changes/limiter-exact-output/.)
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
 * sub-block, luma up (1) when at least a quarter of its pixels rose by a luma step against it,
 * and luma down (2) likewise (the darker side below LUMA_DARK). The mean misses a change over
 * part of a sub-block and cancels a fine pattern reversing (CORE-2515), while the pixel auditor
 * counts a field once a quarter of its pixels changed, so the pixel counts catch both
 * (CORE-2543: a hard-edged hold split one such change into two). */
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
      if (P) P[k] = (4 * up >= n ? 1 : 0) | (4 * down >= n ? 2 : 0);
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
  let credit = 0;
  let redDeficit = 0;
  const bufs = [new Uint8Array(W * H * 4), new Uint8Array(W * H * 4)];
  let flip = 0;
  const colBlock = Int32Array.from({ length: W }, (_, x) => blockOf(x, W, BLOCKS_X));
  const rowBlock = Int32Array.from({ length: H }, (_, y) => blockOf(y, H, BLOCKS_Y));
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
    // others fall). That spends two tokens: the pair waits until the budget has also stood
    // unspent for one refill period (credit, at most one token) and leaves two tokens of deficit,
    // so no 1 s window holds more transitions than singles allow (CORE-2515). A single grant
    // forfeits the credit.
    credit = Math.min(TOKEN, credit + Math.max(0, refill - deficit));
    deficit = Math.max(0, deficit - refill);
    const askUp = over[0] && requests[0] > 0, askDown = over[1] && requests[1] > 0;
    const pair = askUp && askDown;
    const grantUp = askUp && deficit <= 0 && (!pair || credit >= TOKEN);
    const grantDown = askDown && deficit <= 0 && (!pair || credit >= TOKEN);
    if (grantUp || grantDown) { deficit = grantUp && grantDown ? 2 * TOKEN : TOKEN; credit = 0; }
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
    for (let y = 0; y < H; y++) {
      const by = rowBlock[y];
      for (let x = 0, i = y * W * 4; x < W; x++, i += 4) {
        const src = holdMask[by * BLOCKS_X + colBlock[x]] ? history : px;
        out[i] = src[i]; out[i + 1] = src[i + 1]; out[i + 2] = src[i + 2]; out[i + 3] = 255;
      }
    }
    return { out, held, holdMask, grant, deficit, redDeficit, stats: { requests, over, admitted, fired } };
  }

  return { step, window: win };
}
