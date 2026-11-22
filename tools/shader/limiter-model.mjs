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
//      Red chromaticity (WCAG 2.1 and 2.2: one state saturated red and the two states more than
//      0.2 apart in CIE 1976 u'v') is measured on integer u'v' codes (uvCode, within 2.5e-4) and
//      two boxes per pixel (uvStep; openspec/changes/limiter-red-uv-chromaticity/design.md).
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
//   4. Area gate: every direction is over when some window of bcols x brows sub-blocks holds more
//      than `limit` such pixels (cols x rows cells for a host that passes no sub-block window,
//      CORE-3238). The window is the fewest whole sub-blocks (or cells) that contain the field (the 10°
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
// Tracker state is packed as the GPU stores it, one RGBA32UI texel per pixel. The low 16 bits:
//   x  luma extreme (15-bit) | RED_MEM_HI;
//   y  luma distance (12 bits) | LUMA_UP | UNTRACKED | RED_MEM_LO (the red memory: 0 0 unknown,
//      0 1 counted, 1 1 not counted, 1 0 counted with a saturated state seen, since the red
//      tracker's latest change); z  red extreme | distance << 8 | RED_UP | UV_SBK | UV_FBK; w  stamps,
//      4 bits each (luma up, luma down << 4, red up << 8, red down << 12), 0 absent, else the
//      event's unit (tick >> 4) + 1.
// The high 16 bits hold the chromaticity boxes (uvStep): x SB u min | FB u min << 9, y SB u max |
// FB u max << 9, z SB v min | FB v min << 8 | UV_MARKER, w SB v max | FB v max << 8.
// Each tracker has a direction (the way it last fired), its extreme since (peak or trough) and its
// reference (the level at its last transition), stored as the distance from the extreme, which
// stays under the step (trackStep). The zero texel is tracked black: falling at 0, red memory and
// chromaticity unknown. UNTRACKED, exactly (0, UNTRACKED, 0, 0), marks a pixel with no state yet,
// which takes its first value without firing, as a fall to it. Every write sets UV_MARKER; any
// other texel without it was not stored at 32 bits and fires every direction on a new colour.
// createLimiter({ width, height, geometry, maxFlashHz, start }).step(rgba8, dt) returns
//   { out, held (pixels), holdMask (sub-blocks with a held pixel), grant, deficit, redDeficit, state (the four grant words), track, stats: { requests, asked (direction bits asked of the grant, recent channels included), over, admitted, fired } }.
// `out` is reused every other frame; `track` is the packed tracker state after the frame.
import { GRID_X, GRID_Y, SUB, cellWindow, windowOf } from './limiter-geometry.mjs';

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
// z bits 13 and 14: the saturated and far boxes are known (uvStep); z bit 31: written at 32 bits.
export const UV_SBK = 8192, UV_FBK = 16384, UV_MARKER = 0x80000000;
// z bit 15 and w bit 31: the saturated and far boxes are uncertain (uvStep, design.md section 13);
// UV_SBU is a z low-half bit, UV_FBU a w high-half bit. UV_ZBITS are the box bits of z's low half.
export const UV_SBU = 32768, UV_FBU = 32768, UV_ZBITS = UV_SBK | UV_FBK | UV_SBU;
export const TOKEN = 65025;
// A host that has presented exact (0, 0, 0) black for this long before a restart may start the
// trackers at BLACK_TEXEL, and the auditor, told of that restart, reseeds every pixel black that
// long (limiter-audit.mjs `restart`). It is longer than WCAG's one-second window, with 250 ms
// spare. Nothing expires during playback (openspec/changes/limiter-red-expire-black/).
export const RED_EXPIRE_MS = 1250;
/** "Black, nothing owed": luma falling at 0, red at 0, red memory counted (RED_MEM_LO), both
 * chromaticity boxes known empty, written at 32 bits: (0, 32768, 2147508224, 0). */
export const BLACK_TEXEL = [0, RED_MEM_LO, (UV_MARKER | UV_SBK | UV_FBK) >>> 0, 0];
/** The one black threshold host and auditor share. The microsecond absorbs float accumulation
 * (75 frames of 1000/60 ms sum to 1249.9999999999995 ms) and nothing else. */
export const blackLongEnough = ms => ms >= RED_EXPIRE_MS - 1e-3;
/** The host's test before seeding BLACK_TEXEL: `ms` is the exact black it credited one presented
 * frame at a time, each interval capped at 100 ms, and `longestMs` the longest interval credited.
 * Subtracting it covers a credit that leads the display by one frame: at 60 Hz the host needs 76
 * intervals where the auditor needs 75. */
export const hostBlackLongEnough = (ms, longestMs) => blackLongEnough(ms - longestMs);
export const COVERAGE_MS = 1000 / 15;
export const TICK_MS = COVERAGE_MS / 64;
// The clock counts ticks modulo 240, 15 units of 16 ticks. A stamp is recent while the current
// unit is at most 5 units after it (modulo 15): every event at most 64 ticks (the coverage
// interval) old, since 64 ticks reach into a sixth unit, and some up to 95. Stale stamps are cleared every frame and a frame interval
// over the coverage interval voids them all, so no stamp lives long enough to alias.
export const TICKS = 240, UNIT_TICKS = 16, UNITS = 15, RECENT_UNITS = 5;

/** The sRGB transfer: linear light of 8-bit display value k. */
const linear = k => {
  const c = k / 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
};
/** Per 8-bit display value k: round(65535 * weight * linear(k / 255)) for the Rec. 709 weights
 * (R, G, B), then the unweighted linear code round(65535 * linear(k / 255)). */
export const LUMA_LUT = Array.from({ length: 256 }, (_, k) => {
  const lin = linear(k);
  return [Math.round(65535 * 0.2126 * lin), Math.round(65535 * 0.7152 * lin), Math.round(65535 * 0.0722 * lin),
    Math.round(65535 * lin)];
});
/** Per 8-bit display value k: round(2^24 linear(k / 255)), the chromaticity codes' input (uvCode). */
export const LIN24_LUT = Int32Array.from({ length: 256 }, (_, k) => Math.round(16777216 * linear(k)));
const LR = Int32Array.from(LUMA_LUT, v => v[0]);
const LG = Int32Array.from(LUMA_LUT, v => v[1]);
const LB = Int32Array.from(LUMA_LUT, v => v[2]);
const LIN = Int32Array.from(LUMA_LUT, v => v[3]);
const L24 = LIN24_LUT;

// Red chromaticity (openspec/changes/limiter-red-uv-chromaticity/design.md): CIE 1976 u'v' codes in
// 2^-14 units, every intermediate under 2^32 so the GLSL legs compute them in uint.
// UV_X, UV_Y: the IEC 61966-2-1 X and Y rows times 2^14; UV_D: (X + 15 Y + 3 Z) per channel times 2^14.
export const UV_X = [6757, 5859, 2957], UV_Y = [3483, 11718, 1183], UV_D = [59954, 187485, 67420];
// The codes of the saturated-red triangle's vertices: (1, 0, 0), (0.8, 0.2, 0), (0.8, 0, 0.2).
export const UV_VERTS = [[7386, 8567], [5044, 8852], [6396, 7255]];
// Squared code distances: a step (0.2 less twice the codes' error, so codes over it may be more
// than 0.2 apart), a definite step (0.2 plus twice the error, so codes over it are), far (some
// saturated code may be more than a step away) and very far (every saturated code is definitely
// more than 0.2 away). limiter-uv-check.mjs derives and verifies them over every 8-bit colour.
export const UV_T = 10683798, UV_TH = 10791225, UV_TF = 10634475, UV_TVF = 12233465;
// The definite step's distance in codes (UV_TH is its square): codes further apart on either axis
// are more than 0.2 apart.
export const UV_R = 3285;
// The boxes (uvStep): SB holds saturated codes in 8-code cells from (UV_SU0, UV_SV0), 9 bits of u
// cell and 8 of v; FB far codes in 64-code cells from (UV_FU0, UV_FV0), 7 bits each. A min is
// stored as N - cell and a max as cell + 1, so the empty box is 0 and a union is the max.
export const UV_SU0 = 5044, UV_SV0 = 7254, UV_FU0 = 2048, UV_FV0 = 2587, UV_SNU = 511, UV_SNV = 255, UV_FN = 127;
/** A non-black colour's u'v' code, (u << 14) | v; -1 for black. */
export function uvCode(r, g, b) {
  const s = L24[r] + L24[g] + L24[b];
  if (s === 0) return -1;
  let k = 0;
  while ((s >> k) >= 262144) k++;
  const cr = L24[r] >> k, cg = L24[g] >> k, cb = L24[b] >> k, s2 = cr + cg + cb;
  const nr = Math.floor(cr * 16384 / s2), ng = Math.floor(cg * 16384 / s2), nb = Math.floor(cb * 16384 / s2);
  const X = UV_X[0] * nr + UV_X[1] * ng + UV_X[2] * nb, Y = UV_Y[0] * nr + UV_Y[1] * ng + UV_Y[2] * nb;
  const q = Math.floor((UV_D[0] * nr + UV_D[1] * ng + UV_D[2] * nb) / 16384);
  return (Math.floor(4 * X / q) << 14) | Math.floor(9 * Y / q);
}
/** Squared distance between two codes. */
export const uvDist2 = (a, b) => ((a >> 14) - (b >> 14)) ** 2 + ((a & 16383) - (b & 16383)) ** 2;
const vertCodes = UV_VERTS.map(([u, v]) => (u << 14) | v);
/** Whether code c may be more than a down step from some saturated code. */
export const uvFar = c => vertCodes.some(w => uvDist2(c, w) > UV_TF);
/** Whether code c is more than a down step from every saturated code. */
export const uvVeryFar = c => vertCodes.every(w => uvDist2(c, w) > UV_TVF);
/** Saturated red for the chromaticity rule: linear R / (R + G + B) >= 0.8, exact over every 8-bit
 * colour (never below 0.8 - 1e-12). */
export const uvSat = (r, g, b) => (r | g | b) !== 0 && L24[r] + 1 >= 4 * (L24[g] + L24[b]);

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
/** Whether a code (u, v) is more than a step from some point of the box [ulo, uhi] x [vlo, vhi]:
 * from its furthest corner. */
const uvBoxFar = (u, v, ulo, uhi, vlo, vhi) => Math.max(u - ulo, uhi - u) ** 2 + Math.max(v - vlo, vhi - v) ** 2 > UV_T;
/** Whether a code (u, v) is more than a definite step from every point of one of the box's edge
 * strips, k codes wide (its cell): each strip holds a code the box was built from, so that code
 * and (u, v) are more than 0.2 apart. */
function uvBoxDefinite(u, v, ulo, uhi, vlo, vhi, k) {
  const d = (lo, hi, p) => Math.max(0, lo - p, p - hi);
  const over = (u0, u1, v0, v1) => d(u0, u1, u) ** 2 + d(v0, v1, v) ** 2 > UV_TH;
  return over(ulo, ulo + k - 1, vlo, vhi) || over(uhi - k + 1, uhi, vlo, vhi) ||
    over(ulo, uhi, vlo, vlo + k - 1) || over(ulo, uhi, vhi - k + 1, vhi);
}
/** Clips one axis of a box to the codes within R of p: cells [lo, hi] from base, `shift` the cell
 * width's log2; returns hi < lo when nothing is left. */
function uvClipAxis(lo, hi, p, base, shift, out, k) {
  const a = p - UV_R - base, b = p + UV_R - base;
  out[k] = Math.max(lo, Math.max(a, 0) >> shift);
  out[k + 1] = b < 0 ? -1 : Math.min(hi, b >> shift);
}
const clip = [0, 0, 0, 0];
/** The chromaticity step for colour (r, g, b) after the previous output (pr, pg, pb), on the
 * texel's high halves (xh, yh, zh, wh) and z's box bits kb (z & UV_ZBITS): writes the new halves
 * (zh with UV_MARKER, wh with UV_FBU) to out[0..3] and z's box bits to out[4], and returns 1 up,
 * -1 down, 0 none. SB is the box of the saturated codes shown since the last red fall, FB of the
 * far codes since the last red rise; each is known (its bit set: it holds every such code) or
 * unknown (a zero seed: earlier ones were lost), and certain (every code it was built from is
 * still a reference) or uncertain (UV_SBU, UV_FBU: a fire that may not have been a transition
 * kept codes that may be spent). Only a colour other than the previous output fires. A saturated
 * colour fires up when FB is unknown or has a point more than a step from it; another non-black
 * colour fires down when SB is known and has such a point, or is unknown and the colour far. A
 * fire empties the box and makes it known and certain when it is surely a transition from every
 * code the box may hold: the box is certain and one of its edge strips is more than 0.2 away, or,
 * for SB, the colour is very far. Any other fire keeps only the box's cells within a definite step
 * of the colour, the codes it may not have spent, and makes the box uncertain unless that is
 * nothing. Then the colour joins SB if saturated and FB if far. Black changes nothing (design.md,
 * sections 4 and 13). */
export function uvStep(xh, yh, zh, wh, kb, r, g, b, pr, pg, pb, out) {
  let su0 = xh & 511, su1 = yh & 511, sv0 = zh & 255, sv1 = wh & 255;
  let fu0 = xh >>> 9, fu1 = yh >>> 9, fv0 = (zh >>> 8) & 127, fv1 = (wh >>> 8) & 127;
  let sbk = (kb & UV_SBK) !== 0, fbk = (kb & UV_FBK) !== 0, dir = 0;
  let sbu = (kb & UV_SBU) !== 0, fbu = (wh & UV_FBU) !== 0;
  if ((r | g | b) !== 0) {
    const c = uvCode(r, g, b), u = c >> 14, v = c & 16383, sat = uvSat(r, g, b);
    if (r !== pr || g !== pg || b !== pb) {
      if (sat) {
        const ulo = UV_FU0 + 64 * (UV_FN - fu0), uhi = UV_FU0 + 64 * fu1 - 1;
        const vlo = UV_FV0 + 64 * (UV_FN - fv0), vhi = UV_FV0 + 64 * fv1 - 1;
        if (!fbk || (fu1 > 0 && uvBoxFar(u, v, ulo, uhi, vlo, vhi))) {
          dir = 1;
          if (fu1 > 0 && !fbu && uvBoxDefinite(u, v, ulo, uhi, vlo, vhi, 64)) {
            fu0 = fu1 = fv0 = fv1 = 0; fbk = true;
          } else if (fu1 > 0) {
            uvClipAxis(UV_FN - fu0, fu1 - 1, u, UV_FU0, 6, clip, 0);
            uvClipAxis(UV_FN - fv0, fv1 - 1, v, UV_FV0, 6, clip, 2);
            if (clip[1] < clip[0] || clip[3] < clip[2]) fu0 = fu1 = fv0 = fv1 = 0;
            else { fu0 = UV_FN - clip[0]; fu1 = clip[1] + 1; fv0 = UV_FN - clip[2]; fv1 = clip[3] + 1; }
          }
          fbu = fu1 > 0;
        }
      } else {
        const ulo = UV_SU0 + 8 * (UV_SNU - su0), uhi = UV_SU0 + 8 * su1 - 1;
        const vlo = UV_SV0 + 8 * (UV_SNV - sv0), vhi = UV_SV0 + 8 * sv1 - 1;
        if (sbk ? su1 > 0 && uvBoxFar(u, v, ulo, uhi, vlo, vhi) : uvFar(c)) {
          dir = -1;
          if (uvVeryFar(c) || (su1 > 0 && !sbu && uvBoxDefinite(u, v, ulo, uhi, vlo, vhi, 8))) {
            su0 = su1 = sv0 = sv1 = 0; sbk = true;
          } else if (su1 > 0) {
            uvClipAxis(UV_SNU - su0, su1 - 1, u, UV_SU0, 3, clip, 0);
            uvClipAxis(UV_SNV - sv0, sv1 - 1, v, UV_SV0, 3, clip, 2);
            if (clip[1] < clip[0] || clip[3] < clip[2]) su0 = su1 = sv0 = sv1 = 0;
            else { su0 = UV_SNU - clip[0]; su1 = clip[1] + 1; sv0 = UV_SNV - clip[2]; sv1 = clip[3] + 1; }
          }
          sbu = su1 > 0;
        }
      }
    }
    if (sat) {
      const iu = (u - UV_SU0) >> 3, iv = (v - UV_SV0) >> 3;
      su0 = Math.max(su0, UV_SNU - iu); su1 = Math.max(su1, iu + 1);
      sv0 = Math.max(sv0, UV_SNV - iv); sv1 = Math.max(sv1, iv + 1);
    }
    if (uvFar(c)) {
      const iu = (u - UV_FU0) >> 6, iv = (v - UV_FV0) >> 6;
      fu0 = Math.max(fu0, UV_FN - iu); fu1 = Math.max(fu1, iu + 1);
      fv0 = Math.max(fv0, UV_FN - iv); fv1 = Math.max(fv1, iv + 1);
    }
  }
  out[0] = su0 | (fu0 << 9); out[1] = su1 | (fu1 << 9); out[2] = sv0 | (fv0 << 8) | 32768;
  out[3] = sv1 | (fv1 << 8) | (fbu ? UV_FBU : 0);
  out[4] = (sbk ? UV_SBK : 0) | (fbk ? UV_FBK : 0) | (sbu ? UV_SBU : 0);
  return dir;
}
/** A pixel's first chromaticity state from colour (r, g, b): both boxes known, holding the colour
 * where it is saturated or far. Writes as uvStep does. */
export function uvFirst(r, g, b, out) {
  uvStep(0, 0, 0, 0, UV_SBK | UV_FBK, r, g, b, r, g, b, out);
}
/** Whether a texel is the UNTRACKED seed, and whether it was written at 32 bits (UV_MARKER) or is
 * the zero texel. */
export const untracked = (x, y, z, w) => x === 0 && y === UNTRACKED && z === 0 && w === 0;
export const texelValid = (x, y, z, w) => (z & UV_MARKER) !== 0 || (x | y | z | w) === 0;
/** The tracker texel a limiter start clears every pixel to. */
export function startTexel(start) {
  if (start === 'untracked') return [0, UNTRACKED, 0, 0];
  if (start === 'zero') return [0, 0, 0, 0];
  if (start === 'black') return BLACK_TEXEL;
  throw new Error(`limiter: unknown start ${start}`);
}
const redCount = r => ((r & 3) === 3 ? -1 : r & 3);
const ftmp = [0, 0, 0], fuv = [0, 0, 0, 0, 0];
/** Directions (bit d) a tracker texel (x, y, z, w) fires in on colour (r, g, b) after the previous
 * output (pr, pg, pb): 0 for a pixel with no state, and every direction on a colour other than the
 * previous output for a texel not written at 32 bits. The red direction is the chromaticity
 * step's when it fires, else the 320 rule's. */
export function texelFires(x, y, z, w, r, g, b, pr, pg, pb) {
  if (untracked(x, y, z, w)) return 0;
  if (!texelValid(x, y, z, w)) return r !== pr || g !== pg || b !== pb ? 15 : 0;
  const fl = lumaStep(x, y, lumaCode(r, g, b), ftmp);
  const fu = uvStep(x >>> 16, y >>> 16, z >>> 16, w >>> 16, z & UV_ZBITS, r, g, b, pr, pg, pb, fuv);
  const fr = fu || redCount(redStep(x, y, z, redCode(r, g, b), redSat(r, g, b), ftmp));
  return (fl > 0 ? 1 : 0) | (fl < 0 ? 2 : 0) | (fr > 0 ? 4 : 0) | (fr < 0 ? 8 : 0);
}

/** Whether stamp s (4 bits) is recent at unit u. */
export function recent(s, u, deltaMs) {
  return s > 0 && deltaMs <= Math.fround(COVERAGE_MS) && (u - (s - 1) + UNITS) % UNITS <= RECENT_UNITS;
}


/** Display byte c scaled by k / 255, and a mixed k / 256 of the way to b: the steps a held pixel's
 * colour is searched along (createLimiter, dim). */
const scale = (c, k) => Math.floor((c * k + 127) / 255);
const mix = (a, b, k) => (a * (256 - k) + b * k + 128) >> 8;
/** How far (of 256) a pixel denied a rise moves each frame from the previous output's hue toward
 * the input's (createLimiter, dim). */
const CHROMA_K = 32;
/** The steps a held pixel's searches try along a mix, counted from the input (1 is one step from
 * it, 256 the other end): the 16 nearest, then every 16th (n from 1 to NEAR_STEPS), then the
 * NEAR_FILL between the first of those that qualifies and the one tried before it. No order is
 * assumed along the mix: the luma and the trackers of rounded mixes cross a threshold more than
 * once (Codex review of limiter-dim-hold). */
const NEAR_STEPS = 30, NEAR_FILL = 15;
const nearStep = n => (n <= 16 ? n : 16 * (n - 15));

/** Sub-block of pixel x in a frame of size n along an axis with `blocks` sub-blocks. */
export const blockOf = (x, n, blocks) => Math.floor((blocks * (x + 1) - 1) / n);

/** start sets every pixel's tracker texel: 'untracked' (the default) no state yet, which the
 * conformance vectors start from; 'zero' tracked black with the red memory unknown, a host's
 * start when hostBlackLongEnough does not hold; 'black' BLACK_TEXEL, a host's start when it does
 * (shaders/limiter/README.md, "Ping-pong and reset"). */
export function createLimiter({ width: W, height: H, geometry = 'wcag', maxFlashHz = 3, start = 'untracked', cellWindows = false }) {
  if (W < BLOCKS_X || H < BLOCKS_Y) throw new Error(`limiter: frame ${W}x${H} is under ${BLOCKS_X}x${BLOCKS_Y}`);
  // The passes' 32-bit counts and the float limit hold any frame up to 8192 x 8192
  // (shaders/limiter/README.md, "Frame size").
  if (W > MAX_SIDE || H > MAX_SIDE) throw new Error(`limiter: frame ${W}x${H} is over ${MAX_SIDE}x${MAX_SIDE}`);
  const N = W * H;
  const windowFor = g => (cellWindows ? cellWindow : w => w)(windowOf(g, W, H));
  let win = windowFor(geometry);
  const clock = createClock(maxFlashHz);
  // Packed tracker state per pixel (RGBA32UI), cleared to the start texel.
  const track = new Uint32Array(N * 4);
  const seed = startTexel(start);
  for (let p = 0; p < N; p++) track.set(seed, 4 * p);
  const req = new Uint8Array(BLOCKS);
  const holdMask = new Uint8Array(BLOCKS);
  // Per cell and per sub-block: pixels changing in any channel and direction, now or recently.
  const area = new Int32Array(CELLS);
  const barea = new Int32Array(BLOCKS);
  // Summed-area table of barea, (BLOCKS_X + 1) x (BLOCKS_Y + 1).
  const bsum = new Int32Array((BLOCKS_X + 1) * (BLOCKS_Y + 1));
  let lastRedDown = false;
  const tmp = [0, 0, 0];
  const uv = [0, 0, 0, 0, 0];
  const shown = [0, 0, 0];
  // A host writes the grant state fully spent at every start (shaders/limiter/README.md, "Ping-pong
  // and reset"), so a reseed after a short black cannot pay a red change at once (Codex code
  // round 1). The conformance vectors' untracked start keeps it unspent.
  let deficit = start === 'untracked' ? 0 : 2 * TOKEN;
  let credit = 0;
  let redDeficit = start === 'untracked' ? 0 : TOKEN;
  let redCarry = 0;
  const bufs = [new Uint8Array(N * 4), new Uint8Array(N * 4)];
  let flip = 0;
  // The previous output, which a chromaticity direction needs a colour other than to fire.
  let hist = bufs[0];
  const colBlock = Int32Array.from({ length: W }, (_, x) => blockOf(x, W, BLOCKS_X));
  const rowBlock = Int32Array.from({ length: H }, (_, y) => blockOf(y, H, BLOCKS_Y));

  // Directions (bit d) the pixel's trackers fire in on colour (r, g, b) (texelFires).
  const fires = (q, r, g, b) => texelFires(track[q], track[q + 1], track[q + 2], track[q + 3], r, g, b, hist[q], hist[q + 1], hist[q + 2]);

  // Whether the pixel's trackers fire on (r, g, b) in no direction outside `allowed`.
  const safe = (q, allowed, r, g, b) => !(fires(q, r, g, b) & ~allowed & 15);

  // The step nearest colour b (three bytes each), of those searched (nearStep) along the mix from
  // colour a, at which the pixel is safe, into shown. a is safe (step 0), so the result always is.
  function toward(q, allowed, a0, a1, a2, b0, b1, b2) {
    const ok = s => safe(q, allowed, mix(a0, b0, 256 - s), mix(a1, b1, 256 - s), mix(a2, b2, 256 - s));
    let at = 256;
    for (let n = 1; n <= NEAR_STEPS; n++) {
      if (ok(nearStep(n))) { at = nearStep(n); break; }
    }
    const far = at;
    for (let n = NEAR_FILL; n >= 1; n--) {
      if (far > 16 && ok(far - n)) { at = far - n; break; }
    }
    shown[0] = mix(a0, b0, 256 - at); shown[1] = mix(a1, b1, 256 - at); shown[2] = mix(a2, b2, 256 - at);
  }

  // How many steps from colour b the nearest mix from colour a is, of those searched (nearStep),
  // whose luma is at most lim (atMost) or at least lim; 256, colour a, when none is.
  function lumaToward(a0, a1, a2, b0, b1, b2, lim, atMost) {
    const ok = s => {
      const v = lumaCode(mix(a0, b0, 256 - s), mix(a1, b1, 256 - s), mix(a2, b2, 256 - s));
      return atMost ? v <= lim : v >= lim;
    };
    let at = 256;
    for (let n = 1; n <= NEAR_STEPS; n++) {
      if (ok(nearStep(n))) { at = nearStep(n); break; }
    }
    const far = at;
    for (let n = NEAR_FILL; n >= 1; n--) {
      if (far > 16 && ok(far - n)) { at = far - n; break; }
    }
    return at;
  }

  // The colour a held pixel shows, into shown: the input with its luma moved into the band its
  // luma tracker does not fire in, then, if a tracker would still fire outside `allowed` (the
  // directions the input fires and the grant admitted), the furthest safe step from the grey of
  // that luma toward it, or else from the previous output (which fires nothing) toward the input.
  // To raise the luma the input is mixed with the least of the previous output that reaches the
  // band, since the light a pixel may not yet lose is the light it showed. To lower it the
  // previous output is mixed toward the input as far as the band allows, then CHROMA_K / 256 of
  // the way toward the input scaled toward black to the band's top (that scaled input alone if
  // the mix is over the band): over black this is the input dimmed, and over lit content the
  // pixel keeps its hue on the first frame and takes the input's over the next few, so a white
  // line crossing a coloured glow does not show as a grey one beside it. Both stop at `top`, the
  // band's ceiling less the room above what the pixel showed times (input - ceiling) / input and
  // three times the shown luma over the ceiling (at most one): a lit pixel whose input is far
  // over the band stays near what it showed, so a bright ring crossing a lit fill leaves no
  // second ring where it now is, and a pixel that was black still goes to the ceiling. The band, from
  // trackStep: a fall fires from a step below the tracker's high (its peak when rising, its
  // reference when falling) if that is below the dark threshold, and a rise from a step above its
  // low unless the low is at or above it.
  function dim(q, allowed, px, history) {
    const r = px[q], g = px[q + 1], b = px[q + 2];
    const ext = track[q] & LUMA_MAX, dist = track[q + 1] & 4095, up = (track[q + 1] & LUMA_UP) !== 0;
    const high = up ? ext : ext + dist, low = up ? ext - dist : ext;
    const floor = allowed & 2 ? 0 : Math.min(high - LUMA_STEP + 1, LUMA_DARK);
    const ceil = allowed & 1 || low >= LUMA_DARK ? LUMA_MAX : low + LUMA_STEP - 1;
    const v = lumaCode(r, g, b);
    let d0 = r, d1 = g, d2 = b;
    if (v > ceil) {
      const h0 = history[q], h1 = history[q + 1], h2 = history[q + 2], was = lumaCode(h0, h1, h2);
      const top = was < ceil ? ceil - (((ceil - was) * Math.floor(Math.min(256, Math.floor(768 * was / ceil)) * (v - ceil) / v)) >> 8) : ceil;
      let lo = 0, hi = 255;
      for (let n = 0; n < 8; n++) {
        const mid = (lo + hi) >> 1;
        if (lumaCode(scale(r, mid), scale(g, mid), scale(b, mid)) <= top) lo = mid; else hi = mid;
      }
      d0 = scale(r, lo); d1 = scale(g, lo); d2 = scale(b, lo);
      const k = 256 - lumaToward(h0, h1, h2, r, g, b, top, true);
      const e0 = mix(mix(h0, r, k), d0, CHROMA_K), e1 = mix(mix(h1, g, k), d1, CHROMA_K), e2 = mix(mix(h2, b, k), d2, CHROMA_K);
      if (lumaCode(e0, e1, e2) <= top) { d0 = e0; d1 = e1; d2 = e2; }
    } else if (v < floor) {
      const h0 = history[q], h1 = history[q + 1], h2 = history[q + 2];
      const k = 256 - lumaToward(h0, h1, h2, r, g, b, floor, false);
      d0 = mix(h0, r, k); d1 = mix(h1, g, k); d2 = mix(h2, b, k);
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
    hist = bufs[flip];
    req.fill(0);
    area.fill(0);
    barea.fill(0);
    for (let y = 0; y < H; y++) {
      const by = rowBlock[y];
      for (let x = 0, p = y * W; x < W; x++, p++) {
        const i = 4 * p, k = by * BLOCKS_X + colBlock[x];
        const now = fires(i, px[i], px[i + 1], px[i + 2]);
        const st = track[i + 3];
        let rec = 0;
        for (let d = 0; d < 4; d++) rec |= recent((st >> (4 * d)) & 15, unit, deltaMs) ? 1 << d : 0;
        req[k] |= now | rec << 4;
        if (now || rec) {
          area[(by >> 2) * GRID_X + (colBlock[x] >> 2)]++;
          barea[k]++;
        }
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
    // Worst window: over it, every direction is over. Windows are whole sub-blocks when the host
    // passes their size, else whole cells.
    let isOver = false;
    if (win.bcols > 0 && win.brows > 0) {
      const SX = BLOCKS_X + 1;
      for (let y = 0; y < BLOCKS_Y; y++) {
        for (let x = 0, row = 0; x < BLOCKS_X; x++) {
          row += barea[y * BLOCKS_X + x];
          bsum[(y + 1) * SX + x + 1] = bsum[y * SX + x + 1] + row;
        }
      }
      for (let y0 = 0; y0 + win.brows <= BLOCKS_Y && !isOver; y0++) {
        for (let x0 = 0; x0 + win.bcols <= BLOCKS_X && !isOver; x0++) {
          const x1 = x0 + win.bcols, y1 = y0 + win.brows;
          const s = bsum[y1 * SX + x1] - bsum[y0 * SX + x1] - bsum[y1 * SX + x0] + bsum[y0 * SX + x0];
          if (s > win.limit) isOver = true;
        }
      }
    } else {
      for (let y0 = 0; y0 + win.rows <= GRID_Y && !isOver; y0++) {
        for (let x0 = 0; x0 + win.cols <= GRID_X && !isOver; x0++) {
          let s = 0;
          for (let y = y0; y < y0 + win.rows; y++) for (let x = x0; x < x0 + win.cols; x++) s += area[y * GRID_X + x];
          if (s > win.limit) isOver = true;
        }
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
        const now = holdMask[by * BLOCKS_X + colBlock[x]] ? fires(i, r, g, b) : 0;
        if (now & ~grant & 15) {
          held++;
          dim(i, now & grant, px, history);
          r = shown[0]; g = shown[1]; b = shown[2];
        }
        out[i] = r; out[i + 1] = g; out[i + 2] = b; out[i + 3] = 255;
        const v = lumaCode(r, g, b), rv = redCode(r, g, b), sat = redSat(r, g, b);
        let x0 = track[i], y0 = track[i + 1], z0 = track[i + 2], w0 = track[i + 3];
        if (untracked(x0, y0, z0, w0)) {
          // The first value: both boxes known, holding it where it is saturated or far.
          uvFirst(r, g, b, uv);
          track[i] = (v | (sat ? RED_MEM_HI : 0) | (uv[0] << 16)) >>> 0;
          track[i + 1] = ((sat ? 0 : RED_MEM_LO) | (uv[1] << 16)) >>> 0;
          track[i + 2] = (rv | uv[4] | (uv[2] << 16)) >>> 0; track[i + 3] = (uv[3] << 16) >>> 0;
          continue;
        }
        // A texel not written at 32 bits steps as the zero texel.
        if (!texelValid(x0, y0, z0, w0)) x0 = y0 = z0 = w0 = 0;
        const st = w0 & 65535;
        const fu = uvStep(x0 >>> 16, y0 >>> 16, z0 >>> 16, w0 >>> 16, z0 & UV_ZBITS, r, g, b,
          history[i], history[i + 1], history[i + 2], uv);
        const r3 = redStep(x0, y0, z0, rv, sat, tmp);
        const fr = fu || redCount(r3);
        track[i + 2] = (tmp[0] | uv[4] | (uv[2] << 16)) >>> 0;
        const fl = lumaStep(x0, y0, v, tmp);
        track[i] = (tmp[0] | (r3 & 4 ? RED_MEM_HI : 0) | (uv[0] << 16)) >>> 0;
        track[i + 1] = (tmp[1] | (tmp[2] ? LUMA_UP : 0) | (r3 & 8 ? RED_MEM_LO : 0) | (uv[1] << 16)) >>> 0;
        const f = (fl > 0 ? 1 : 0) | (fl < 0 ? 2 : 0) | (fr > 0 ? 4 : 0) | (fr < 0 ? 8 : 0);
        let ns = 0;
        for (let d = 0; d < 4; d++) {
          const sd = (st >> (4 * d)) & 15;
          const keep = (f >> d) & 1 ? unit + 1 : recent(sd, unit, deltaMs) ? sd : 0;
          ns |= keep << (4 * d);
          fired[d] += (f >> d) & 1;
        }
        track[i + 3] = (ns | (uv[3] << 16)) >>> 0;
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
    win = windowFor(g);
    deficit = 2 * TOKEN;
    credit = 0;
    redDeficit = TOKEN;
    redCarry = 0;
    lastRedDown = false;
    clock.written();
  };
  return { step, setGeometry, get window() { return win; } };
}
