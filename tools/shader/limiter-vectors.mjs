// SPDX-License-Identifier: AGPL-3.0-only
// Frame flash limiter vectors (conformance/limiter/frame/README.md): each case's signal
// (limiter-signals.mjs) through the reference model (limiter-model.mjs) at a fixed 1/60 s step.
// Per frame the vector keeps the hold mask (run lengths over the 64 x 36 sub-blocks in row order,
// starting with a run of not-held; "=" when unchanged from the previous frame), the four grant
// state words as grant.glsl writes them, the FNV-1a digest of the output bytes, and
// the FNV-1a digest of the packed tracker state (RGBA32UI per pixel, little-endian bytes).
// A case with `reset: { at, seed }` starts a new limiter at frame `at`, as a host restarts one after
// a Frame change: trackers cleared to the seed (limiter-model.mjs startTexel), the grant fully
// spent, the clock restarted (shaders/limiter/README.md, "Ping-pong and reset"). An auditor reading
// the case is told of it with restart(seed) (limiter-audit.mjs).
//
//   node tools/shader/limiter-vectors.mjs --write | --check
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cellWindow, windowOf } from './limiter-geometry.mjs';
import { createLimiter, MODEL } from './limiter-model.mjs';
import { renderSignal } from './limiter-signals.mjs';

export const VECTORS_PATH = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'conformance', 'limiter', 'frame', 'vectors.json');
export const DT = 1 / 60;
const W = [255, 255, 255], K = [0, 0, 0], G = [128, 128, 128], RED = [255, 0, 0];
const ORANGE = [110, 64, 0], FAINT_RED = [5, 0, 0], NEAR_RED = [1, 0, 0], DIM_RED = [60, 0, 0], RED_90 = [90, 0, 0];

// red-stagger: A (60, 0, 18) saturated, B (35, 0, 32) 0.165 from A, C (0, 0, 60) 0.397 from A, at
// 2.5 Hz. Each 16-column stripe puts 1280 pixels in a 140 x 80 limiter window (limit 1605); the
// two put 1920 in a 107 x 60 field.
const UV_A = [60, 0, 18], UV_B = [35, 0, 32], UV_C = [0, 0, 60];
export const STAGGER = { kind: 'bands', period: 24, bg: K, bands: [
  { rect: [0.4, 0, 0.45, 1], keys: [[0, UV_A], [1, UV_B], [8, UV_C], [9, UV_B], [16, UV_A]] },
  { rect: [0.45, 0, 0.5, 1], keys: [[0, UV_A], [7, UV_B], [8, UV_C], [9, UV_B], [10, UV_A]] }] };
// red-extremum and red-early-band: A (60, 0, 0), S (60, 25, 0) saturated and 0.094 from C
// (60, 50, 0), C 0.226 from A; M (61, 42, 0) 0.1996 from A, its codes over the down step. Two
// adjoining 8 x 5 patches (40 pixels each, limit 63) in one 21 x 12 field, a 34-frame cycle.
const UV_S = [60, 25, 0], UV_M = [61, 42, 0], UV_CC = [60, 50, 0];
export const extremum = out => ({ kind: 'bands', period: 34, bg: K, bands: [
  { rect: [0.3125, 0.25, 0.4375, 0.4], keys: [[0, DIM_RED], [1, out], [17, UV_CC], [33, UV_S]] },
  { rect: [0.4375, 0.25, 0.5625, 0.4], keys: [[0, DIM_RED], [16, out], [17, UV_CC], [18, UV_S]] }] });

export const CASES = [
  { name: 'steady-gradient', frames: 60, signal: { kind: 'gradient' } },
  { name: 'luma-3hz', frames: 120, signal: { kind: 'square', hz: 3, on: W, off: K } },
  { name: 'luma-10hz', frames: 120, signal: { kind: 'square', hz: 10, on: W, off: K } },
  { name: 'luma-10hz-small', frames: 90, signal: { kind: 'square', hz: 10, on: W, off: K, rect: [0.5, 0.5, 0.5625, 0.6111111111111112], bg: G } },
  // limiter-block-windows: two 15 x 60 px patches 125 px apart, 1800 px against a 1605 px limit.
  // No window of whole sub-blocks (115 px wide) holds both, so nothing is held; a window of whole
  // cells (140 px) does, so a host that passes no sub-block window holds them.
  { name: 'two-patches-10hz', frames: 90, signal: { kind: 'square', hz: 10, on: W, off: K, rects: [[0, 0, 0.046875, 1 / 3], [0.390625, 0, 0.4375, 1 / 3]], bg: G } },
  { name: 'two-patches-10hz-cells', frames: 90, cellWindows: true, signal: { kind: 'square', hz: 10, on: W, off: K, rects: [[0, 0, 0.046875, 1 / 3], [0.390625, 0, 0.4375, 1 / 3]], bg: G } },
  { name: 'luma-settle', frames: 120, signal: { kind: 'square', hz: 10, on: W, off: K, until: 60, after: 'on' } },
  { name: 'red-3hz', frames: 120, signal: { kind: 'square', hz: 3, on: RED, off: K } },
  { name: 'red-10hz', frames: 120, signal: { kind: 'square', hz: 10, on: RED, off: K } },
  // Saturated red only in linear light: [120, 50, 0] has R / (R + G + B) 0.855 linear but 0.706 on
  // the encoded bytes (review 2026-11-13, OSC-0032).
  { name: 'red-linear-saturation-10hz', frames: 120, signal: { kind: 'square', hz: 10, on: [120, 50, 0], off: [0, 50, 120] } },
  // Red over a third of every sub-block: diluted in the block mean (CORE-1616).
  { name: 'red-stripes-10hz', frames: 90, signal: { kind: 'stripes', hz: 10, every: 3, width: 1, on: [110, 0, 0], off: K, bg: K } },
  { name: 'red-dark-10hz-half', frames: 90, signal: { kind: 'square', hz: 10, on: [200, 0, 0], off: [90, 0, 0], rect: [0, 0, 0.5, 1], bg: K } },
  { name: 'tv-half-field-10hz', frames: 120, geometry: 'tv', signal: { kind: 'square', hz: 10, on: W, off: K, rect: [0.25, 1 / 3, 0.6875, 13 / 18], bg: K } },
  // CORE-2413, CORE-2543: an orange background drifting beside a held strobe shows the input.
  { name: 'tv-half-field-10hz-orange-drift', frames: 120, geometry: 'tv', signal: { kind: 'square', hz: 10, on: W, off: K, rect: [0.25, 1 / 3, 0.6875, 13 / 18], bg: [200, 20, 0], bgStep: [0, 1, 0] } },
  { name: 'desktop-field-10hz', frames: 90, geometry: 'desktop', signal: { kind: 'square', hz: 10, on: W, off: K, rect: [0.375, 1 / 3, 0.5625, 2 / 3], bg: G } },
  { name: 'phone-field-10hz', frames: 90, geometry: 'phone', signal: { kind: 'square', hz: 10, on: W, off: K, rect: [0.25, 0.25, 0.5, 0.75], bg: K } },
  { name: 'checker-half-cell-10hz', frames: 120, signal: { kind: 'checker', hz: 10, size: [1 / 32, 1 / 18], on: W, off: K } },
  { name: 'odd-size-checker-10hz', frames: 90, width: 331, height: 193, signal: { kind: 'checker', hz: 10, size: [0.05, 0.07], on: W, off: G } },
  { name: 'fine-checker-10hz', frames: 90, width: 640, height: 360, signal: { kind: 'checker', hz: 10, size: [4 / 640, 4 / 360], on: W, off: K } },
  // limiter-dim-hold: a held pixel shows the input dimmed. Colours with no grey in them, over a
  // drifting background, so the legs agree on the scaled and mixed colours (a denied rise here
  // mixes from a lit previous output).
  { name: 'colour-10hz-dim', frames: 120, signal: { kind: 'square', hz: 10, on: [120, 200, 255], off: [40, 10, 70], rect: [0.125, 0.125, 0.75, 0.875], bg: [30, 60, 20], bgStep: [1, 0, 1] } },
  { name: 'colour-checker-15hz-dim', frames: 90, signal: { kind: 'checker', hz: 15, size: [0.11, 0.17], on: [255, 140, 0], off: [20, 40, 160] } },
  // limiter-dim-hold (Codex review): rounded mixes cross a threshold more than once. A denied
  // fall one step of the previous output raises into the band, a denied rise whose furthest mix
  // under the limit lies past three over it, and a red change with a safe mix twelve steps from
  // the input past unsafe ones (test-limiter.mjs asserts the colours).
  { name: 'dim-fall-first-step', frames: 40, signal: { kind: 'steps', colors: [K, [240, 123, 247], [31, 167, 125]] } },
  { name: 'dim-rise-past-a-gap', frames: 40, signal: { kind: 'steps', colors: [K, [23, 189, 209], [12, 250, 58]] } },
  { name: 'dim-red-near-input', frames: 40, signal: { kind: 'steps', colors: [K, [154, 194, 79], [251, 130, 9]] } },
  // limiter-red-expire-black (CORE-2869): a restart after orange falls to black. After 8 frames of
  // black, short of 1250 ms, the host clears to zero and both the faint red at 308 and the full red
  // at 309 count, so the spent grant holds them (Codex's repro). After 90 frames the host seeds
  // "black, nothing owed" and only the full red counts; after exactly 75 frames (1250 ms, the
  // auditor's threshold) likewise. A real red strobe after a black start is still held. Then the
  // design round 3 repros after one black start: a saturated (60, 0, 0) under an orange rise, and a
  // faint or near-black saturated red before it.
  { name: 'reset-short-black', frames: 330, width: 64, height: 36, reset: { at: 208, seed: 'zero' }, signal: { kind: 'runs', runs: [[100, K], [100, ORANGE], [108, K], [1, FAINT_RED], [1, RED]] } },
  { name: 'reset-long-black', frames: 420, width: 64, height: 36, reset: { at: 290, seed: 'black' }, signal: { kind: 'runs', runs: [[100, K], [100, ORANGE], [190, K], [1, FAINT_RED], [1, RED]] } },
  { name: 'reset-black-at-expiry', frames: 300, width: 64, height: 36, reset: { at: 275, seed: 'black' }, signal: { kind: 'runs', runs: [[100, K], [100, ORANGE], [75, K], [1, FAINT_RED], [1, RED]] } },
  { name: 'black-start-red-10hz', frames: 320, width: 64, height: 36, reset: { at: 80, seed: 'black' }, signal: { kind: 'runs', runs: [[80, K], ...Array.from({ length: 80 }, (_, i) => [3, i % 2 ? K : RED])] } },
  { name: 'black-start-sat-orange', frames: 540, width: 64, height: 36, reset: { at: 76, seed: 'black' }, signal: { kind: 'runs', runs: [[176, K], [100, DIM_RED], [100, K], [100, ORANGE], [1, RED_90], [1, K]] } },
  { name: 'black-start-faint-red', frames: 400, width: 64, height: 36, reset: { at: 100, seed: 'black' }, signal: { kind: 'runs', runs: [[100, K], [100, FAINT_RED], [100, ORANGE], [1, DIM_RED]] } },
  { name: 'black-start-near-black-red', frames: 400, width: 64, height: 36, reset: { at: 100, seed: 'black' }, signal: { kind: 'runs', runs: [[100, K], [100, NEAR_RED], [100, ORANGE], [1, DIM_RED]] } },
  // limiter-red-uv-chromaticity (CORE-2935): red transitions by the WCAG 2.1/2.2 u'v' rule. The
  // repro, dim red and green, which neither luma nor the 320 rule counts; a full red flash; a 320
  // rise that is a u'v' fall (the merged direction); dim red on black, which no rule counts; a real
  // red flash over half the frame. Then Codex's design repros: two stripes, each under the limiter
  // window's limit, crossing 0.2 from A together after an intermediate B at different frames
  // (round 1 P1-a); two patches tracing A, S, C and back, S saturated and near C (P1-1); the same
  // with the outward S an early-band colour (P1-2); a zero start under a constant (1, 0, 0) (P1-b),
  // and after an orange and blue history (P2-1).
  { name: 'red-green-dim-10hz', frames: 120, signal: { kind: 'square', hz: 10, on: DIM_RED, off: [0, 60, 0] } },
  { name: 'red-blue-10hz', frames: 120, signal: { kind: 'square', hz: 10, on: RED, off: [0, 0, 255] } },
  { name: 'red-mask-10hz', frames: 120, signal: { kind: 'square', hz: 10, on: FAINT_RED, off: [255, 0, 230] } },
  { name: 'red-black-dim-10hz', frames: 120, signal: { kind: 'square', hz: 10, on: DIM_RED, off: K } },
  { name: 'red-flash-5hz-half', frames: 120, signal: { kind: 'square', hz: 5, on: [180, 0, 0], off: [90, 90, 90], rect: [0, 0, 0.5, 1], bg: K } },
  { name: 'red-stagger', frames: 120, signal: STAGGER },
  { name: 'red-extremum', frames: 136, width: 64, height: 36, signal: extremum(UV_S) },
  { name: 'red-early-band', frames: 136, width: 64, height: 36, signal: extremum(UV_M) },
  { name: 'red-zero-constant', frames: 120, width: 64, height: 36, reset: { at: 10, seed: 'zero' }, signal: { kind: 'runs', runs: [[20, K], [1, NEAR_RED]] } },
  { name: 'red-zero-mixed', frames: 260, width: 64, height: 36, reset: { at: 128, seed: 'zero' }, signal: { kind: 'bands', period: 1000, bg: K, bands: [
    { rect: [0, 0, 0.5, 1], keys: [[0, K], [100, ORANGE], [120, K], [128, NEAR_RED]] },
    { rect: [0.5, 0, 1, 1], keys: [[0, K], [100, [0, 0, 60]], [120, K], [128, NEAR_RED]] }] } },
  // Codex design round 2 (widened memory): two adjacent 8 x 5 patches, each under the window's
  // limit, whose falls at frame 6 and rises at frame 16 come after a fire that may not have been a
  // transition (the left patch's (12, 12, 24), the right's (18, 0, 3)) left a spent code in the box
  // beside a live one (P1-A, section 13); and a zero restart after an orange and magenta history,
  // then a saturated and a non-saturated red 0.183 apart alternating (P1-B).
  { name: 'red-uncertain-box', frames: 120, width: 64, height: 36, signal: { kind: 'bands', period: 15, bg: K, bands: [
    { rect: [0.3125, 0.25, 0.4375, 0.3888888888888889], keys: [[0, [51, 18, 0]], [1, [12, 12, 24]], [2, [60, 6, 21]], [3, [36, 6, 42]], [7, [0, 0, 60]]] },
    { rect: [0.4375, 0.25, 0.5625, 0.3888888888888889], keys: [[0, [45, 15, 3]], [2, [60, 6, 18]], [5, [48, 9, 57]], [6, [18, 0, 3]], [7, [33, 60, 57]], [8, [45, 15, 3]]] }] } },
  { name: 'red-zero-retained', frames: 400, width: 64, height: 36, reset: { at: 10, seed: 'zero' }, signal: { kind: 'runs', runs: [[1, K], [1, [42, 12, 36]], [98, K], [90, [57, 42, 12]], [90, [48, 0, 3]], [31, [57, 21, 3]],
    ...Array.from({ length: 30 }, (_, i) => [3, i % 2 ? [48, 0, 3] : [27, 0, 21]])] } },
];

export function fnv1a(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) h = Math.imul(h ^ bytes[i], 0x01000193) >>> 0;
  return h.toString(16).padStart(8, '0');
}

export function runLengths(mask) {
  const runs = [];
  let want = 0, n = 0;
  for (let i = 0; i < mask.length; i++) {
    if ((mask[i] ? 1 : 0) === want) { n++; continue; }
    runs.push(n);
    want ^= 1;
    n = 1;
  }
  runs.push(n);
  return runs.join(',');
}

/** The FNV-1a digest of packed tracker state (32-bit values) as little-endian bytes. */
export function trackDigest(track) {
  let h = 0x811c9dc5;
  for (let i = 0; i < track.length; i++) {
    for (let b = 0; b < 32; b += 8) h = Math.imul(h ^ ((track[i] >>> b) & 255), 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

/** The frame records of one case: [hold, grant x, y, z, w, digest, track digest]. */
export function modelFrames(c) {
  const width = c.width || 320, height = c.height || 180;
  const geometry = c.geometry || 'wcag';
  let lim = createLimiter({ width, height, geometry, cellWindows: !!c.cellWindows });
  const px = new Uint8Array(width * height * 4);
  const frames = [];
  let last = '';
  for (let t = 0; t < c.frames; t++) {
    if (t === c.reset?.at) {
      lim = createLimiter({ width, height, geometry, start: c.reset.seed, cellWindows: !!c.cellWindows });
    }
    renderSignal(c.signal, t, width, height, px);
    const r = lim.step(px, DT);
    const hold = runLengths(r.holdMask);
    frames.push([hold === last ? '=' : hold, ...r.state, fnv1a(r.out), trackDigest(r.track)]);
    last = hold;
  }
  return frames;
}

export function buildVectors() {
  return {
    model: MODEL,
    dt: DT,
    cases: CASES.map(c => ({
      ...c,
      width: c.width || 320,
      height: c.height || 180,
      geometry: c.geometry || 'wcag',
      window: (c.cellWindows ? cellWindow : w => w)(windowOf(c.geometry || 'wcag', c.width || 320, c.height || 180)),
      frameRecords: modelFrames(c),
    })),
  };
}

const serialize = v => JSON.stringify(v, (k, x) => (k === 'frameRecords' ? x.map(f => JSON.stringify(f)) : x), 1)
  .replace(/"(\[\\"[^\n]*?\])"/g, (_, s) => s.replace(/\\"/g, '"')) + '\n';

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const text = serialize(buildVectors());
  if (process.argv.includes('--write')) {
    writeFileSync(VECTORS_PATH, text);
    console.log(`wrote ${VECTORS_PATH}`);
  } else if (process.argv.includes('--check')) {
    let have = '';
    try { have = readFileSync(VECTORS_PATH, 'utf8'); } catch { /* reported below */ }
    if (have !== text) {
      console.error('conformance/limiter/frame/vectors.json differs from the reference model; run node tools/shader/limiter-vectors.mjs --write');
      process.exit(1);
    }
    console.log(`ok   limiter vectors: ${CASES.length} cases match the reference model (${MODEL})`);
  } else {
    console.error('usage: limiter-vectors.mjs --write | --check');
    process.exit(2);
  }
}
