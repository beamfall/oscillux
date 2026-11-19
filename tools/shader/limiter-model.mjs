// SPDX-License-Identifier: AGPL-3.0-only
// Reference model of the frame flash limiter (shaders/limiter/, conformance/limiter/frame/).
// Every decision is integer arithmetic on 16-bit codes, so the GLSL passes reproduce it bit for
// bit. Per frame:
//   1. Measures: each pixel's luma code is min(65535, LUMA_LUT[r][0] + LUMA_LUT[g][1] +
//      LUMA_LUT[b][2]) >> 1 (32767 relative luminance), its red code (R - G - B) >> 8 where
//      R > G + B, else 0, and whether it is saturated red, R + 4 >= 4 (G + B), where R, G, B are the
//      linear channel codes LUMA_LUT[k][3] = round(65535 linear(k / 255)) (256 red codes are
//      1.25 on WCAG's 320 max(0, R - G - B) scale). Both are linear light, as WCAG 2.x defines
//      them. The auditor (limiter-audit.mjs) measures with the same codes.
//      Not modelled: WCAG 2.2's alternative red test (one state saturated red and the two states
//      more than 0.2 apart in CIE 1976 u'v'). It compares each pixel's own two states through a
//      nonlinear division and a 2-D distance, which integer codes cannot carry bit for bit
//      (GLSL ES 3.00 has no 64-bit integers and no correctly rounded float division).
//   2. Trackers: every pixel has the auditor's transition tracker on each measure (lo, hi,
//      direction; luma step 3275 codes, 0.1, with the darker side below 26215, 0.8; red step 15
//      codes, 20 on the 320 scale; each widened by the codes' measured error over every 8-bit
//      colour so a change at a WCAG threshold always fires). Every change moves a tracker; a red
//      change counts as a transition when a saturated state is seen with it (redStep) and four recency stamps (luma up, luma down, red up, red down)
//      kept while inside the coverage interval (1000/15 ms). A pixel requests a direction when
//      the frame would fire its tracker in it. Until v0.2.9 the trackers ran on 64 x 36 sub-block
//      means and missed changes that build up over frames or cover part of a sub-block, which the
//      auditor counts (Codex review round 7, CORE-2543).
//   3. Area: the frame is partitioned into 64 x 36 sub-blocks (x in [floor(i W / 64),
//      floor((i + 1) W / 64)), likewise y) and 16 x 9 cells of 4 x 4 sub-blocks. Per cell, the
//      count of pixels firing now or with a recent stamp in any direction: pixels changing in
//      either channel and direction at once flash together (Codex rounds 12, 13).
//   4. Area gate: every direction is over when some window of cols x rows cells holds more than
//      `limit` such pixels. The window is the fewest whole cells that contain the field (the 10°
//      field for the viewing geometry, fwPx x fhPx pixels: limiter-geometry.mjs) wherever it is
//      placed, and the limit a quarter of the field's pixels, so every field the auditor finds
//      over makes some window over.
//   5. Grant: luminance over the limit is rationed by a token budget refilled by
//      floor(clamp(2 maxFlashHz dt, 0, 1) * 65025) a frame; red over the limit by its own budget
//      refilled by an eighth of that (integer), so no 1 s window holds two large-area red
//      transitions (no red flash) and held red catches up instead of freezing (CORE-2382). Both
//      red directions asked admit one, alternating; a frame asking both channels is admitted only
//      when both are ready, since a pixel changing in both shows only if both are admitted.
//   6. Hold: a pixel that would fire in a direction that is not admitted shows the previous
//      output frame; every other pixel shows the input exactly (no tiles: until v0.2.9 a whole
//      sub-block held, CORE-2492). The trackers then step
//      on the output, so they hold exactly the auditor's state: a held pixel shows the value its
//      tracker last took and does not move it. (Until v0.2.9 the pixels around a hold blended
//      toward the previous output; a blended change appeared after the token it spent had
//      refilled: CORE-2543, CORE-2541, openspec/changes/limiter-exact-output/.)
//
// Tracker state is packed as the GPU stores it, one RGBA16UI texel per pixel:
//   x, y  luma lo, hi (15-bit; bit 15 of x: the red tracker's latest change was counted; bit 15
//         of y: a saturated red state since that change); z  red lo | hi << 8; w  stamps, 4 bits
//         each (luma up, luma down << 4, red up << 8, red down << 12), 0 absent, else the event's
//         unit (tick >> 4) + 1.
// The direction is in the order of lo and hi: lo <= hi is none; after a rise lo is the maximum
// code (32767, red 255) and hi the reference; after a fall hi is 0 and lo the reference, or
// (2, 1) for a reference of 0 (fall()). (32767, 0) in luma marks a pixel with no state yet, which
// takes its first value without firing. A rise to the maximum reads back as no direction, which
// fires exactly as the direction would (nothing is above the maximum).
//
// createLimiter({ width, height, geometry, maxFlashHz }).step(rgba8, dt) returns
//   { out, held (pixels), holdMask (sub-blocks with a held pixel), grant, deficit, redDeficit, track, stats: { requests, asked (direction bits asked of the grant, recent channels included), over, admitted, fired } }.
// `out` is reused every other frame; `track` is the packed tracker state after the frame.
import { GRID_X, GRID_Y, SUB, windowOf } from './limiter-geometry.mjs';

/** The largest frame side the passes support (shaders/limiter/README.md, "Frame size"). */
export const MAX_SIDE = 8192;
export const MODEL = 'pixel-10deg';
export const BLOCKS_X = GRID_X * SUB, BLOCKS_Y = GRID_Y * SUB;
const BLOCKS = BLOCKS_X * BLOCKS_Y;
const CELLS = GRID_X * GRID_Y;
// The codes are the measure (shaders/limiter/common.glsl): 0.1 and 0.8 relative luminance,
// and 20 of WCAG's 320 red scale in 256ths.
export const LUMA_STEP = 3275, LUMA_DARK = 26215, RED_STEP = 15, NO_DARK = 256;
// Luma codes are 15-bit (32767 relative luminance) so bit 15 of the luma-hi word can carry the
// red tracker's saturated bit (SAT_BIT): whether a saturated red state was seen since it last fired.
export const LUMA_MAX = 32767, RED_MAX = 255, SAT_BIT = 32768, COUNT_BIT = 32768;
export const TOKEN = 65025;
export const COVERAGE_MS = 1000 / 15;
export const TICK_MS = COVERAGE_MS / 64;
// The clock counts ticks modulo 240, 15 units of 16 ticks. A stamp is recent while the current
// unit is at most 5 units after it (modulo 15): every event at most 64 ticks (the coverage
// interval) old, since 64 ticks reach into a sixth unit, and some up to 95. Stale stamps are cleared every frame and a frame interval
// over the coverage interval voids them all, so no stamp lives long enough to alias.
export const TICKS = 240, UNIT_TICKS = 16, UNITS = 15, RECENT_UNITS = 5;

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

/** A pixel's luma code: the 16-bit relative luminance halved to 15 bits. */
export const lumaCode = (r, g, b) => Math.min(65535, LR[r] + LG[g] + LB[b]) >> 1;
/** Whether a pixel is saturated red, R / (R + G + B) >= 0.8 on the linear codes, widened by their
 * rounding (R + 4 >= 4 (G + B)) so every saturated colour passes. */
export function redSat(r, g, b) {
  const R = LIN[r], G = LIN[g], B = LIN[b];
  return R > G + B && R + 4 >= 4 * (G + B);
}
/** A pixel's red code: (R - G - B) >> 8 when R > G + B, else 0. A red change fires its tracker
 * only when the new state or one since the tracker last fired is saturated (redSat), so every
 * WCAG transition between a saturated and any other state counts and orange to orange never does. */
export function redCode(r, g, b) {
  const R = LIN[r], G = LIN[g], B = LIN[b];
  return R > G + B ? (R - G - B) >> 8 : 0;
}

/** The host clock: tick in [0, 240), the frame interval in ms, and the token refill. The refill
 * carries its fraction to the next frame, so a small maxFlashHz at a high frame rate still refills
 * (Codex round 15). */
export function createClock(maxFlashHz = 3) {
  let ms = 0, carry = 0;
  return dt => {
    ms += dt * 1000;
    const earned = carry + Math.min(1, Math.max(0, 2 * maxFlashHz * dt)) * TOKEN;
    const refill = Math.min(TOKEN, Math.floor(earned));
    carry = Math.min(1, earned - refill);
    return { tick: Math.floor(ms / TICK_MS) % TICKS, deltaMs: Math.fround(dt * 1000), refill };
  };
}

/** A fall's packed (lo, hi): the trough in lo and 0 in hi, or (2, 1) for a trough of 0, which
 * (0, 0) would read back as no direction (Codex round 13). */
const fall = (trough, out) => { out[0] = trough > 0 ? trough : 2; out[1] = trough > 0 ? 0 : 1; };

/** One step of a packed tracker (lo, hi as stored, max the code's maximum) on value v: writes
 * the new lo, hi to out[0], out[1] and returns 1 rising, -1 falling, 0 none. Steps in one
 * direction are one transition however long they pause between them (a flash is a pair of
 * opposing changes, ITU-R BT.1702, WCAG 2.x). */
export function trackStep(lo, hi, v, step, dark, max, out) {
  let dir = 0;
  if (lo > hi) {
    if (lo === max) { dir = 1; lo = hi; } else { dir = -1; lo = hi === 0 ? lo : 0; hi = lo; }
  }
  lo = Math.min(lo, v);
  hi = Math.max(hi, v);
  if (dir <= 0 && v - lo >= step && lo < dark) { out[0] = max; out[1] = v; return 1; }
  if (dir >= 0 && hi - v >= step && v < dark) { fall(v, out); return -1; }
  if (dir > 0) { out[0] = max; out[1] = hi; } else if (dir < 0) fall(lo, out); else { out[0] = lo; out[1] = hi; }
  return 0;
}

/** The red tracker's step on packed tracker words (x, y, z) for red code rv and saturation sat:
 * writes z' to out[0] and returns count (1 rising, -1 falling, 0 none) | counted' << 2 | seen' << 3.
 * A change counts when the new state or one since the previous change is saturated; one that did
 * not count then counts at the first saturated state before the next change. Direction changes
 * never wait for saturation (Codex round 13). */
export function redStep(x, y, z, rv, sat, out) {
  const c = trackStep(z & 255, z >> 8, rv, RED_STEP, NO_DARK, RED_MAX, out);
  out[0] |= out[1] << 8;
  let counted = x >= COUNT_BIT, seen = y >= SAT_BIT, count = 0;
  if (c !== 0) {
    counted = sat || seen;
    count = counted ? c : 0;
    seen = sat;
  } else {
    const lo = out[0] & 255, hi = out[0] >> 8;
    const dir = lo > hi ? (lo === RED_MAX ? 1 : -1) : 0;
    if (dir !== 0 && !counted && sat) { count = dir; counted = true; }
    seen = seen || sat;
  }
  return (count & 3) | (counted ? 4 : 0) | (seen ? 8 : 0);
}
const redCount = r => ((r & 3) === 3 ? -1 : r & 3);

/** Whether stamp s (4 bits) is recent at unit u. */
export function recent(s, u, deltaMs) {
  return s > 0 && deltaMs <= Math.fround(COVERAGE_MS) && (u - (s - 1) + UNITS) % UNITS <= RECENT_UNITS;
}


/** Sub-block of pixel x in a frame of size n along an axis with `blocks` sub-blocks. */
export const blockOf = (x, n, blocks) => Math.floor((blocks * (x + 1) - 1) / n);

export function createLimiter({ width: W, height: H, geometry = 'wcag', maxFlashHz = 3 }) {
  if (W < BLOCKS_X || H < BLOCKS_Y) throw new Error(`limiter: frame ${W}x${H} is under ${BLOCKS_X}x${BLOCKS_Y}`);
  // The passes' 32-bit counts and the float limit hold any frame up to 8192 x 8192
  // (shaders/limiter/README.md, "Frame size").
  if (W > MAX_SIDE || H > MAX_SIDE) throw new Error(`limiter: frame ${W}x${H} is over ${MAX_SIDE}x${MAX_SIDE}`);
  const N = W * H;
  let win = windowOf(geometry, W, H);
  const clock = createClock(maxFlashHz);
  // Packed tracker state per pixel (RGBA16UI), cleared to "no state yet".
  const track = new Uint16Array(N * 4);
  for (let p = 0; p < N; p++) { track[4 * p] = LUMA_MAX; track[4 * p + 2] = RED_MAX; }
  const req = new Uint8Array(BLOCKS);
  const holdMask = new Uint8Array(BLOCKS);
  // Per cell: pixels changing in any channel and direction, now or recently.
  const area = new Int32Array(CELLS);
  let lastRedDown = false;
  const tmp = [0, 0];
  let deficit = 0;
  let credit = 0;
  let redDeficit = 0;
  const bufs = [new Uint8Array(N * 4), new Uint8Array(N * 4)];
  let flip = 0;
  const colBlock = Int32Array.from({ length: W }, (_, x) => blockOf(x, W, BLOCKS_X));
  const rowBlock = Int32Array.from({ length: H }, (_, y) => blockOf(y, H, BLOCKS_Y));

  // Directions (bit d) the pixel's trackers fire in on value (v, rv, sat); 0 for a pixel with no state.
  function fires(q, v, rv, sat) {
    const lo = track[q] & LUMA_MAX, hi = track[q + 1] & LUMA_MAX;
    if (lo === LUMA_MAX && hi === 0) return 0;
    const fl = trackStep(lo, hi, v, LUMA_STEP, LUMA_DARK, LUMA_MAX, tmp);
    const fr = redCount(redStep(track[q], track[q + 1], track[q + 2], rv, sat, tmp));
    return (fl > 0 ? 1 : 0) | (fl < 0 ? 2 : 0) | (fr > 0 ? 4 : 0) | (fr < 0 ? 8 : 0);
  }

  function step(px, dt) {
    const { tick, deltaMs, refill } = clock(dt);
    const unit = tick >> 4;
    const requests = [0, 0, 0, 0];
    req.fill(0);
    area.fill(0);
    for (let y = 0; y < H; y++) {
      const by = rowBlock[y];
      for (let x = 0, p = y * W; x < W; x++, p++) {
        const i = 4 * p, k = by * BLOCKS_X + colBlock[x];
        const now = fires(i, lumaCode(px[i], px[i + 1], px[i + 2]), redCode(px[i], px[i + 1], px[i + 2]), redSat(px[i], px[i + 1], px[i + 2]));
        const st = track[i + 3];
        let rec = 0;
        for (let d = 0; d < 4; d++) rec |= recent((st >> (4 * d)) & 15, unit, deltaMs) ? 1 << d : 0;
        req[k] |= now | rec << 4;
        if (now || rec) area[(by >> 2) * GRID_X + (colBlock[x] >> 2)]++;
      }
    }
    // Directions firing now, and the channels changed recently: when something fires now, a channel
    // firing nowhere but recent in the area is asked in one direction (up when it rose), so its own
    // budget pays for the frame (Codex round 14).
    let askNow = 0, askRecent = 0;
    for (let k = 0; k < BLOCKS; k++) {
      for (let d = 0; d < 4; d++) requests[d] += (req[k] >> d) & 1;
      askNow |= req[k] & 15; askRecent |= req[k] >> 4;
    }
    let asked = askNow;
    if (askNow) {
      if (!(askNow & 3) && askRecent & 3) asked |= askRecent & 1 ? 1 : 2;
      if (!(askNow & 12) && askRecent & 12) asked |= askRecent & 4 ? 4 : 8;
    }
    // Worst window: over it, every direction is over.
    let isOver = false;
    for (let y0 = 0; y0 + win.rows <= GRID_Y && !isOver; y0++) {
      for (let x0 = 0; x0 + win.cols <= GRID_X && !isOver; x0++) {
        let s = 0;
        for (let y = y0; y < y0 + win.rows; y++) for (let x = x0; x < x0 + win.cols; x++) s += area[y * GRID_X + x];
        if (s > win.limit) isOver = true;
      }
    }
    const over = [isOver, isOver, isOver, isOver];
    // Luminance shares one token budget; red has its own, refilled at an eighth of the luma rate,
    // so no 1 s window holds two large-area red transitions: no saturated-red flash (ITU-R
    // BT.1702, ADR-0232 R5), and a held red change is admitted within 8 / (2 maxFlashHz) s instead
    // of freezing (R7, CORE-2382). Both red directions asked admit one, the other than last time.
    // Both luma directions may be admitted in one frame (a pattern reversing: some pixels rise,
    // others fall). That spends two tokens: the pair waits until the budget has also stood
    // unspent for one refill period (credit, at most one token) and leaves two tokens of deficit,
    // so no 1 s window holds more transitions than singles allow (CORE-2515). A single grant
    // forfeits the credit. A frame asking both channels is admitted only when both are ready: a
    // pixel changing in both shows only if both are admitted (Codex round 13).
    credit = Math.min(TOKEN, credit + Math.max(0, refill - deficit));
    deficit = Math.max(0, deficit - refill);
    redDeficit = Math.max(0, redDeficit - (refill === 0 ? 0 : Math.max(1, Math.floor(refill / 8))));
    const askUp = isOver && !!(asked & 1), askDown = isOver && !!(asked & 2);
    const askRedUp = isOver && !!(asked & 4), askRedDown = isOver && !!(asked & 8);
    const lumaReady = deficit <= 0 && (!(askUp && askDown) || credit >= TOKEN);
    const go = (!(askUp || askDown) || lumaReady) && (!(askRedUp || askRedDown) || redDeficit <= 0);
    const grantUp = askUp && go, grantDown = askDown && go;
    if (grantUp || grantDown) { deficit = grantUp && grantDown ? 2 * TOKEN : TOKEN; credit = 0; }
    const grantRedUp = askRedUp && go && (!askRedDown || lastRedDown);
    const grantRedDown = askRedDown && go && !grantRedUp;
    if (grantRedUp || grantRedDown) { redDeficit = TOKEN; lastRedDown = grantRedDown; }
    const admitted = [!over[0] || grantUp, !over[1] || grantDown, !over[2] || grantRedUp, !over[3] || grantRedDown];
    let grant = 0;
    for (let d = 0; d < 4; d++) grant |= (admitted[d] ? 1 << d : 0) | (over[d] ? 16 << d : 0);

    // A sub-block holds where one of its pixels does (the same as req & ~grant & 15).
    for (let k = 0; k < BLOCKS; k++) holdMask[k] = req[k] & 15 & ~grant ? 1 : 0;
    let held = 0;

    // Output, then the trackers step on it: a held pixel shows the value its tracker last took.
    const fired = [0, 0, 0, 0];
    const history = bufs[flip];
    flip ^= 1;
    const out = bufs[flip];
    for (let y = 0; y < H; y++) {
      const by = rowBlock[y];
      for (let x = 0, p = y * W; x < W; x++, p++) {
        const i = 4 * p;
        // Held: the pixel would fire in a direction the grant did not admit.
        const hold = holdMask[by * BLOCKS_X + colBlock[x]]
          && fires(i, lumaCode(px[i], px[i + 1], px[i + 2]), redCode(px[i], px[i + 1], px[i + 2]), redSat(px[i], px[i + 1], px[i + 2])) & ~grant & 15;
        if (hold) held++;
        const src = hold ? history : px;
        const r = src[i], g = src[i + 1], b = src[i + 2];
        out[i] = r; out[i + 1] = g; out[i + 2] = b; out[i + 3] = 255;
        const v = lumaCode(r, g, b), rv = redCode(r, g, b), sat = redSat(r, g, b);
        const x0 = track[i], y0 = track[i + 1], lo = x0 & LUMA_MAX, hi = y0 & LUMA_MAX;
        const st = track[i + 3];
        if (lo === LUMA_MAX && hi === 0) {
          track[i] = v; track[i + 1] = v | (sat ? SAT_BIT : 0); track[i + 2] = rv | (rv << 8); track[i + 3] = 0;
          continue;
        }
        const r3 = redStep(x0, y0, track[i + 2], rv, sat, tmp);
        const fr = redCount(r3);
        track[i + 2] = tmp[0];
        const fl = trackStep(lo, hi, v, LUMA_STEP, LUMA_DARK, LUMA_MAX, tmp);
        track[i] = tmp[0] | (r3 & 4 ? COUNT_BIT : 0);
        track[i + 1] = tmp[1] | (r3 & 8 ? SAT_BIT : 0);
        const f = (fl > 0 ? 1 : 0) | (fl < 0 ? 2 : 0) | (fr > 0 ? 4 : 0) | (fr < 0 ? 8 : 0);
        let ns = 0;
        for (let d = 0; d < 4; d++) {
          const sd = (st >> (4 * d)) & 15;
          const keep = (f >> d) & 1 ? unit + 1 : recent(sd, unit, deltaMs) ? sd : 0;
          ns |= keep << (4 * d);
          fired[d] += (f >> d) & 1;
        }
        track[i + 3] = ns;
      }
    }
    return { out, held, holdMask, grant, deficit, redDeficit, track, stats: { requests, asked, over, admitted, fired } };
  }

  // The viewing geometry may change on a live display. The trackers are kept, and the grant
  // state is written fully spent (as on a resize): a smaller window can put pixels that fired
  // recently, each admitted while under the old limit, over the new one with no grant paying.
  const setGeometry = g => {
    win = windowOf(g, W, H);
    deficit = 2 * TOKEN;
    credit = 0;
    redDeficit = TOKEN;
    lastRedDown = false;
  };
  return { step, setGeometry, get window() { return win; } };
}
