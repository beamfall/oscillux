// SPDX-License-Identifier: AGPL-3.0-only
// Frame flash limiter vectors (conformance/limiter/frame/README.md): each case's signal
// (limiter-signals.mjs) through the reference model (limiter-model.mjs) at a fixed 1/60 s step.
// Per frame the vector keeps the hold mask (run lengths over the 64 x 36 sub-blocks in row order,
// starting with a run of not-held; "=" when unchanged from the previous frame), the four grant
// state words as grant.glsl writes them, the FNV-1a digest of the output bytes, and
// the FNV-1a digest of the packed tracker state (RGBA16UI per pixel, little-endian bytes).
// A case with `reset: { at, seed }` starts a new limiter at frame `at`, as a host restarts one after
// a Frame change: trackers cleared to the seed (limiter-model.mjs startTexel), the grant fully
// spent, the clock restarted (shaders/limiter/README.md, "Ping-pong and reset"). An auditor reading
// the case is told of it with restart(seed) (limiter-audit.mjs).
//
//   node tools/shader/limiter-vectors.mjs --write | --check
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { windowOf } from './limiter-geometry.mjs';
import { createLimiter, MODEL } from './limiter-model.mjs';
import { renderSignal } from './limiter-signals.mjs';

export const VECTORS_PATH = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'conformance', 'limiter', 'frame', 'vectors.json');
export const DT = 1 / 60;
const W = [255, 255, 255], K = [0, 0, 0], G = [128, 128, 128], RED = [255, 0, 0];
const ORANGE = [110, 64, 0], FAINT_RED = [5, 0, 0], NEAR_RED = [1, 0, 0], DIM_RED = [60, 0, 0], RED_90 = [90, 0, 0];

export const CASES = [
  { name: 'steady-gradient', frames: 60, signal: { kind: 'gradient' } },
  { name: 'luma-3hz', frames: 120, signal: { kind: 'square', hz: 3, on: W, off: K } },
  { name: 'luma-10hz', frames: 120, signal: { kind: 'square', hz: 10, on: W, off: K } },
  { name: 'luma-10hz-small', frames: 90, signal: { kind: 'square', hz: 10, on: W, off: K, rect: [0.5, 0.5, 0.5625, 0.6111111111111112], bg: G } },
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

/** The FNV-1a digest of packed tracker state (16-bit values) as little-endian bytes. */
export function trackDigest(track) {
  let h = 0x811c9dc5;
  for (let i = 0; i < track.length; i++) {
    h = Math.imul(h ^ (track[i] & 255), 0x01000193) >>> 0;
    h = Math.imul(h ^ (track[i] >>> 8), 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

/** The frame records of one case: [hold, grant x, y, z, w, digest, track digest]. */
export function modelFrames(c) {
  const width = c.width || 320, height = c.height || 180;
  const geometry = c.geometry || 'wcag';
  let lim = createLimiter({ width, height, geometry });
  const px = new Uint8Array(width * height * 4);
  const frames = [];
  let last = '';
  for (let t = 0; t < c.frames; t++) {
    if (t === c.reset?.at) {
      lim = createLimiter({ width, height, geometry, start: c.reset.seed });
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
      window: windowOf(c.geometry || 'wcag', c.width || 320, c.height || 180),
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
