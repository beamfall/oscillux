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
//   2. Trackers: every pixel has the auditor's transition tracker on each measure (direction,
//      extreme and reference: trackStep; luma step 3275 codes, 0.1, with the darker side below 26215, 0.8; red step 15
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
//      clamp(2 maxFlashHz dt, 0, 1) * 65024 a frame, carrying the fraction (none on the first
//      frame after the budget is written); red over the limit by its own budget refilled by an
//      eighth of that, carrying the remainder, so no 1 s window holds two large-area red
//      transitions (no red flash) and held red catches up instead of freezing (CORE-2382). Both
//      red directions asked admit one, alternating; a frame asking both channels is admitted only
//      when both are ready, since a pixel changing in both shows only if both are admitted.
//   6. Hold: a pixel that would fire in a direction that is not admitted is held; every other
//      pixel shows the input exactly (no tiles: until v0.2.9 a whole sub-block held, CORE-2492).
//      A held pixel shows the input dimmed (dim): its luma moved the least distance into the
//      band its tracker does not fire in, scaled toward black to lower it or mixed with the
//      least of the previous output that raises it there; if a tracker still fires outside what
//      the input fires and the grant admitted, the furthest safe step from the grey of that luma
//      toward it, or else from the previous output (which fires nothing) toward the input. So a
//      held region shows the current frame at reduced contrast (a denied rise at most a step
//      above the pixel's low, a denied fall a step below its peak) and fires nothing the grant
//      did not admit. (v0.2.9 showed the previous output, which froze moving content in place
//      pixel by pixel: openspec/changes/limiter-dim-hold/.) The trackers then step on the
//      output, so they hold exactly the auditor's state. (Until v0.2.9 the pixels around a hold
//      blended toward the previous output; a blended change appeared after the token it spent
//      had refilled: CORE-2543, CORE-2541, openspec/changes/limiter-exact-output/.)
//
// Tracker state is packed as the GPU stores it, one RGBA16UI texel per pixel:
//   x  luma extreme (15-bit) | RED_MEM_HI;
//   y  luma distance (12 bits) | LUMA_UP | UNTRACKED | RED_MEM_LO (the red memory: 0 0 unknown,
//      0 1 counted, 1 1 not counted, 1 0 counted with a saturated state seen, since the red
//      tracker's latest change); z  red extreme | distance << 8 | RED_UP; w  stamps, 4 bits each
//      (luma up, luma down << 4, red up << 8, red down << 12), 0 absent, else the event's unit
//      (tick >> 4) + 1.
// Each tracker has a direction (the way it last fired), its extreme since (peak or trough) and its
// reference (the level at its last transition), stored as the distance from the extreme, which
// stays under the step (trackStep). The zero texel is tracked black: falling at 0, red memory
// unknown. UNTRACKED marks a pixel with no state yet, which takes its first value without firing,
// as a fall to it.
//
// createLimiter({ width, height, geometry, maxFlashHz }).step(rgba8, dt) returns
//   { out, held (pixels), holdMask (sub-blocks with a held pixel), grant, deficit, redDeficit, state (the four grant words), track, stats: { requests, asked (direction bits asked of the grant, recent channels included), over, admitted, fired } }.
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
// Tracker words (shaders/limiter/common.glsl): x the luma extreme (15-bit codes, 32767 relative
// luminance) | RED_MEM_HI; y the luma distance (12 bits) | LUMA_UP | UNTRACKED | RED_MEM_LO; z the
// red extreme | distance << 8 | RED_UP. The zero texel is tracked black.
export const LUMA_MAX = 32767, RED_MAX = 255, RED_MEM_HI = 32768, LUMA_UP = 4096, UNTRACKED = 8192,
  RED_MEM_LO = 32768, RED_UP = 4096;
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
 * (Codex round 15). It earns TOKEN - 1 units a refill period, so the carried fraction (at most one
 * unit) never completes a token before a full period has passed since the grant that spent it
 * (Codex round 16). */
export function createClock(maxFlashHz = 3) {
  let ms = 0, carry = 0, fresh = true; // the budget starts spent and written (Codex round 17)
  const clock = dt => {
    ms += dt * 1000;
    const earned = fresh ? 0 : carry + Math.min(1, Math.max(0, 2 * maxFlashHz * dt)) * (TOKEN - 1);
    const refill = Math.min(TOKEN, Math.floor(earned));
    carry = Math.min(1, earned - refill);
    fresh = false;
    return { tick: Math.floor(ms / TICK_MS) % TICKS, deltaMs: Math.fround(dt * 1000), refill };
  };
  // After the host writes the budget, the next frame refills nothing and the carry restarts: time
  // before the write does not repay it (README.md, Codex round 16).
  clock.written = () => { carry = 0; fresh = true; };
  return clock;
}

/** One step of a tracker (extreme, distance of the reference from it, rising) on value v: writes
 * extreme', distance', rising' to out[0..2] and returns 1 rising, -1 falling, 0 none. A change of
 * at least `step` whose darker side is below `dark` is a transition: against the direction from the
 * extreme (a reversal), or onward from the reference, the level at the previous transition, so
 * steps of a threshold in one direction are a transition each: a large area can reach a step in one
 * frame after its pixels started rising at different times (Codex round 16). */
export function trackStep(ext, dist, up, v, step, dark, out) {
  if (up) {
    if (ext - v >= step && v < dark) { out[0] = v; out[1] = 0; out[2] = 0; return -1; }
    const ref = Math.min(ext - dist, v);
    ext = Math.max(ext, v);
    out[0] = ext; out[2] = 1;
    if (ext - ref < step) { out[1] = ext - ref; return 0; }
    out[1] = 0;
    return ref < dark ? 1 : 0;
  }
  if (v - ext >= step && ext < dark) { out[0] = v; out[1] = 0; out[2] = 1; return 1; }
  const ref = Math.max(ext + dist, v);
  ext = Math.min(ext, v);
  out[0] = ext; out[2] = 0;
  if (ref - ext < step) { out[1] = ref - ext; return 0; }
  // A fall of a step above dark keeps its high side, a code under a step (Codex round 18).
  if (ext >= dark) { out[1] = step - 1; return 0; }
  out[1] = 0;
  return -1;
}

/** The luma tracker's step on tracker words (x, y) for luma code v. */
export const lumaStep = (x, y, v, out) => trackStep(x & LUMA_MAX, y & 4095, (y & LUMA_UP) !== 0, v, LUMA_STEP, LUMA_DARK, out);

/** The red tracker's step on tracker words (x, y, z) for red code rv and saturation sat: writes z'
 * to out[0] and returns count (1 rising, -1 falling, 0 none) | memory high bit << 2 | memory low
 * bit << 3. A change counts when the new state or one since the previous change is saturated; one
 * that did not count then counts at the first saturated state before the next change. With the
 * memory unknown (a reset) a change counts at once and, unless it ends saturated, again at the
 * first saturated state (Codex round 19). Direction changes never wait for saturation (Codex
 * round 13). */
export function redStep(x, y, z, rv, sat, out) {
  const c = trackStep(z & 255, (z >> 8) & 15, (z & RED_UP) !== 0, rv, RED_STEP, NO_DARK, out);
  const up = out[2];
  out[0] = out[0] | (out[1] << 8) | (up ? RED_UP : 0);
  const hi = (x & RED_MEM_HI) !== 0, lo = (y & RED_MEM_LO) !== 0;
  let unknown = !hi && !lo, counted = !(hi && lo), seen = hi && !lo, count = 0;
  if (c !== 0) {
    count = sat || seen || unknown ? c : 0;
    counted = sat || seen;
    seen = sat;
    unknown = false;
  } else if (sat) {
    if (!counted || unknown) count = up ? 1 : -1;
    counted = seen = true;
    unknown = false;
  }
  const mhi = unknown ? 0 : !counted || seen ? 1 : 0, mlo = unknown ? 0 : seen ? 0 : 1;
  return (count & 3) | (mhi << 2) | (mlo << 3);
}
const redCount = r => ((r & 3) === 3 ? -1 : r & 3);

/** Whether stamp s (4 bits) is recent at unit u. */
export function recent(s, u, deltaMs) {
  return s > 0 && deltaMs <= Math.fround(COVERAGE_MS) && (u - (s - 1) + UNITS) % UNITS <= RECENT_UNITS;
}


/** Display byte c scaled by k / 255, and a mixed k / 256 of the way to b: the steps a held pixel's
 * colour is searched along (createLimiter, dim). */
const scale = (c, k) => Math.floor((c * k + 127) / 255);
const mix = (a, b, k) => (a * (256 - k) + b * k + 128) >> 8;

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
  for (let p = 0; p < N; p++) track[4 * p + 1] = UNTRACKED;
  const req = new Uint8Array(BLOCKS);
  const holdMask = new Uint8Array(BLOCKS);
  // Per cell: pixels changing in any channel and direction, now or recently.
  const area = new Int32Array(CELLS);
  let lastRedDown = false;
  const tmp = [0, 0, 0];
  const shown = [0, 0, 0];
  let deficit = 0;
  let credit = 0;
  let redDeficit = 0;
  let redCarry = 0;
  const bufs = [new Uint8Array(N * 4), new Uint8Array(N * 4)];
  let flip = 0;
  const colBlock = Int32Array.from({ length: W }, (_, x) => blockOf(x, W, BLOCKS_X));
  const rowBlock = Int32Array.from({ length: H }, (_, y) => blockOf(y, H, BLOCKS_Y));

  // Directions (bit d) the pixel's trackers fire in on value (v, rv, sat); 0 for a pixel with no state.
  function fires(q, v, rv, sat) {
    if (track[q + 1] & UNTRACKED) return 0;
    const fl = lumaStep(track[q], track[q + 1], v, tmp);
    const fr = redCount(redStep(track[q], track[q + 1], track[q + 2], rv, sat, tmp));
    return (fl > 0 ? 1 : 0) | (fl < 0 ? 2 : 0) | (fr > 0 ? 4 : 0) | (fr < 0 ? 8 : 0);
  }

  // Whether the pixel's trackers fire on (r, g, b) in no direction outside `allowed`.
  const safe = (q, allowed, r, g, b) => !(fires(q, lumaCode(r, g, b), redCode(r, g, b), redSat(r, g, b)) & ~allowed & 15);

  // The furthest of 256 steps from colour a toward colour b (three bytes each) found by bisection
  // at which the pixel is safe, into shown. a is safe (step 0), so the result always is.
  function toward(q, allowed, a0, a1, a2, b0, b1, b2) {
    let lo = 0, hi = 256;
    for (let n = 0; n < 8; n++) {
      const mid = (lo + hi) >> 1;
      if (safe(q, allowed, mix(a0, b0, mid), mix(a1, b1, mid), mix(a2, b2, mid))) lo = mid; else hi = mid;
    }
    shown[0] = mix(a0, b0, lo); shown[1] = mix(a1, b1, lo); shown[2] = mix(a2, b2, lo);
  }

  // The colour a held pixel shows, into shown: the input with its luma moved into the band its
  // luma tracker does not fire in (scaled toward black to lower it; to raise it, mixed with the
  // least of the previous output that reaches the band, since the light a pixel may not yet lose
  // is the light it showed), then, if a tracker would still fire outside `allowed` (the
  // directions the input fires and the grant admitted), the furthest safe step from the grey of
  // that luma toward it, or else from the previous output (which fires nothing) toward the input. The band, from trackStep: a fall fires from a step
  // below the tracker's high (its peak when rising, its reference when falling) if that is below
  // the dark threshold, and a rise from a step above its low unless the low is at or above it.
  function dim(q, allowed, px, history) {
    const r = px[q], g = px[q + 1], b = px[q + 2];
    const ext = track[q] & LUMA_MAX, dist = track[q + 1] & 4095, up = (track[q + 1] & LUMA_UP) !== 0;
    const high = up ? ext : ext + dist, low = up ? ext - dist : ext;
    const floor = allowed & 2 ? 0 : Math.min(high - LUMA_STEP + 1, LUMA_DARK);
    const ceil = allowed & 1 || low >= LUMA_DARK ? LUMA_MAX : low + LUMA_STEP - 1;
    const v = lumaCode(r, g, b);
    let d0 = r, d1 = g, d2 = b;
    if (v > ceil) {
      let lo = 0, hi = 255;
      for (let n = 0; n < 8; n++) {
        const mid = (lo + hi) >> 1;
        if (lumaCode(scale(r, mid), scale(g, mid), scale(b, mid)) <= ceil) lo = mid; else hi = mid;
      }
      d0 = scale(r, lo); d1 = scale(g, lo); d2 = scale(b, lo);
    } else if (v < floor) {
      const h0 = history[q], h1 = history[q + 1], h2 = history[q + 2];
      let lo = 0, hi = 256;
      for (let n = 0; n < 8; n++) {
        const mid = (lo + hi) >> 1;
        if (lumaCode(mix(r, h0, mid), mix(g, h1, mid), mix(b, h2, mid)) >= floor) hi = mid; else lo = mid;
      }
      d0 = mix(r, h0, hi); d1 = mix(g, h1, hi); d2 = mix(b, h2, hi);
    }
    if (safe(q, allowed, d0, d1, d2)) { shown[0] = d0; shown[1] = d1; shown[2] = d2; return; }
    const w = lumaCode(d0, d1, d2);
    let lo = 0, hi = 256;
    for (let n = 0; n < 8; n++) {
      const mid = (lo + hi) >> 1;
      if (lumaCode(mid, mid, mid) <= w) lo = mid; else hi = mid;
    }
    if (lumaCode(lo, lo, lo) < floor) lo++;
    if (safe(q, allowed, lo, lo, lo)) toward(q, allowed, lo, lo, lo, d0, d1, d2);
    else toward(q, allowed, history[q], history[q + 1], history[q + 2], r, g, b);
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
    // BT.1702, ADR-0232 R5), and a held red change is admitted instead of freezing (R7,
    // CORE-2382): the red token is back by the first frame at which the frames after it was last
    // spent, each counted up to one refill period of 1 / (2 maxFlashHz) s, have earned
    // (65025 / 65024) · 8 periods. The bound is per grant and in periods the frames earn, not on
    // the wall clock (README.md, Codex round 24), and it is the token's: a frame that asks luma
    // too also waits for the luma token (below; Codex round 25). Both red directions asked admit
    // one, the other than last time.
    // Both luma directions may be admitted in one frame (a pattern reversing: some pixels rise,
    // others fall). That spends two tokens: the pair waits until the budget has also stood
    // unspent for one refill period (credit, at most one token) and leaves two tokens of deficit,
    // so no 1 s window holds more transitions than singles allow (CORE-2515). A single grant
    // forfeits the credit. A frame asking both channels is admitted only when both are ready: a
    // pixel changing in both shows only if both are admitted (Codex round 13).
    credit = Math.min(TOKEN, credit + Math.max(0, refill - deficit));
    deficit = Math.max(0, deficit - refill);
    // An eighth of the luma refill with its remainder carried (grant x bits 10 to 12): exact at any
    // frame interval (Codex rounds 14, 16).
    const redEarned = redCarry + refill;
    redCarry = redEarned % 8;
    redDeficit = Math.max(0, redDeficit - Math.floor(redEarned / 8));
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
    for (let d = 0; d < 4; d++) grant |= admitted[d] ? 1 << d : 0;
    // Bits 4 to 7: the directions some pixel fires in and the grant did not admit, which hold
    // pixels; a host may stop drawing a paused frame only when they are clear (Codex round 18).
    grant |= (askNow & ~grant & 15) << 4;

    // A sub-block holds where one of its pixels does (the same as req & ~grant & 15).
    for (let k = 0; k < BLOCKS; k++) holdMask[k] = req[k] & 15 & ~grant ? 1 : 0;
    let held = 0;

    // Output, then the trackers step on it. A pixel that would fire in a direction the grant did
    // not admit is held and dimmed (dim): it fires only what the input fires and the grant admitted.
    const fired = [0, 0, 0, 0];
    const history = bufs[flip];
    flip ^= 1;
    const out = bufs[flip];
    for (let y = 0; y < H; y++) {
      const by = rowBlock[y];
      for (let x = 0, p = y * W; x < W; x++, p++) {
        const i = 4 * p;
        let r = px[i], g = px[i + 1], b = px[i + 2];
        const now = holdMask[by * BLOCKS_X + colBlock[x]] ? fires(i, lumaCode(r, g, b), redCode(r, g, b), redSat(r, g, b)) : 0;
        if (now & ~grant & 15) {
          held++;
          dim(i, now & grant, px, history);
          r = shown[0]; g = shown[1]; b = shown[2];
        }
        out[i] = r; out[i + 1] = g; out[i + 2] = b; out[i + 3] = 255;
        const v = lumaCode(r, g, b), rv = redCode(r, g, b), sat = redSat(r, g, b);
        const x0 = track[i], y0 = track[i + 1];
        const st = track[i + 3];
        if (y0 & UNTRACKED) {
          track[i] = v | (sat ? RED_MEM_HI : 0); track[i + 1] = sat ? 0 : RED_MEM_LO; track[i + 2] = rv; track[i + 3] = 0;
          continue;
        }
        const r3 = redStep(x0, y0, track[i + 2], rv, sat, tmp);
        const fr = redCount(r3);
        track[i + 2] = tmp[0];
        const fl = lumaStep(x0, y0, v, tmp);
        track[i] = tmp[0] | (r3 & 4 ? RED_MEM_HI : 0);
        track[i + 1] = tmp[1] | (tmp[2] ? LUMA_UP : 0) | (r3 & 8 ? RED_MEM_LO : 0);
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
    // The grant state as the grant pass writes it (grant.glsl): every word is in the vectors, so a
    // GPU leg that drops the red remainder, the red deficit or the credit fails (Codex round 17).
    const high = deficit > TOKEN ? 1 : 0;
    const state = [grant | (high << 8) | (lastRedDown ? 512 : 0) | (redCarry << 10), deficit - high * TOKEN, redDeficit, credit];
    return { out, held, holdMask, grant, deficit, redDeficit, state, track, stats: { requests, asked, over, admitted, fired } };
  }

  // The viewing geometry may change on a live display. The trackers are kept, and the grant
  // state is written fully spent (as on a resize): a smaller window can put pixels that fired
  // recently, each admitted while under the old limit, over the new one with no grant paying.
  const setGeometry = g => {
    win = windowOf(g, W, H);
    deficit = 2 * TOKEN;
    credit = 0;
    redDeficit = TOKEN;
    redCarry = 0;
    lastRedDown = false;
    clock.written();
  };
  return { step, setGeometry, get window() { return win; } };
}
