// SPDX-License-Identifier: AGPL-3.0-only
// Model tests for the frame flash limiter (tools/shader/limiter-model.mjs): synthetic signals
// through the model, its output audited pixel by pixel (limiter-audit.mjs). --model <path> runs
// the same cases against another model file, for parent-commit failure proofs.
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createAuditor } from './limiter-audit.mjs';
import { GEOMETRY } from './limiter-geometry.mjs';
import { renderSignal } from './limiter-signals.mjs';

const at = process.argv.indexOf('--model');
const modelPath = at > 0 ? resolve(process.argv[at + 1]) : new URL('./limiter-model.mjs', import.meta.url);
const model = await import(at > 0 ? pathToFileURL(modelPath).href : modelPath.href);

const W = 320, H = 180, DT = 1 / 60;
const WHITE = [255, 255, 255], BLACK = [0, 0, 0], GREY = [128, 128, 128];

/** Runs a signal through the model; returns the auditor and per-frame hold counts. */
function run(spec, { frames, width = W, height = H, field, limiter = {}, onFrame } = {}) {
  const lim = model.createLimiter({ width, height, ...limiter });
  const audit = createAuditor({ width, height, field });
  const px = new Uint8Array(width * height * 4);
  const held = [];
  for (let t = 0; t < frames; t++) {
    renderSignal(spec, t, width, height, px);
    const r = lim.step(px, DT);
    audit.push(r.out, DT);
    held.push(r.held);
    onFrame?.(t, px, r);
  }
  return { audit, held };
}

const cases = [];
const test = (name, fn) => cases.push({ name, fn });

test('steady frame is never held', () => {
  const { held } = run({ kind: 'gradient' }, {
    frames: 60,
    onFrame: (t, px, r) => assert.deepEqual(r.out, px, `frame ${t} differs from its input`),
  });
  assert.equal(held.reduce((a, b) => a + b, 0), 0);
});

test('full-frame luma 3 Hz is admitted at <= 6 transitions a second', () => {
  const { audit } = run({ kind: 'square', hz: 3, on: WHITE, off: BLACK }, { frames: 300 });
  assert.ok(audit.maxPerWindow('luma') <= 6, `luma ${audit.maxPerWindow('luma')} per 1 s`);
});

test('full-frame luma 10 Hz is limited to <= 6 transitions a second', () => {
  const { audit, held } = run({ kind: 'square', hz: 10, on: WHITE, off: BLACK }, { frames: 300 });
  assert.ok(audit.maxPerWindow('luma') <= 6, `luma ${audit.maxPerWindow('luma')} per 1 s`);
  assert.ok(held.some(h => h > 0), 'nothing was held');
});

// CORE-1623: sustained flashing faster than the coverage interval. Each pixel changes the same
// way again within 1000/15 ms, so the over-area condition never clears; an auditor that counted
// only its rising edge saw 2 transitions in a 30 Hz full-frame strobe, fewer than the limiter's
// output, as if the limiter added transitions. The auditor counts every fresh large-area change.
for (const hz of [15, 30]) {
  test(`full-frame luma ${hz} Hz: the auditor counts it and the limiter output has no more`, () => {
    const input = createAuditor({ width: W, height: H });
    const { audit } = run({ kind: 'square', hz, on: WHITE, off: BLACK }, { frames: 300, onFrame: (t, px) => input.push(px, DT) });
    const lumaIn = input.maxPerWindow('luma'), lumaOut = audit.maxPerWindow('luma');
    assert.equal(lumaIn, 2 * hz, `the auditor sees ${lumaIn} luma transitions per 1 s in a ${hz} Hz input`);
    assert.ok(lumaOut <= 6, `luma ${lumaOut} per 1 s after the limiter`);
    assert.ok(lumaOut <= lumaIn, `limited luma ${lumaOut}/s exceeds the input's ${lumaIn}/s`);
  });
}

test('small-area 10 Hz below the area limit passes unchanged', () => {
  const spec = { kind: 'square', hz: 10, on: WHITE, off: BLACK, rect: [0.5, 0.5, 0.5625, 0.6111111111111112], bg: GREY };
  const { held } = run(spec, { frames: 120, onFrame: (t, px, r) => assert.deepEqual(r.out, px, `frame ${t} held`) });
  assert.equal(held.reduce((a, b) => a + b, 0), 0);
});

test('a strobe that stops settles to its input', () => {
  const spec = { kind: 'square', hz: 10, on: WHITE, off: BLACK, until: 60, after: 'on' };
  let settled = -1;
  run(spec, {
    frames: 120,
    onFrame: (t, px, r) => {
      const same = r.out.every((v, i) => v === px[i]);
      if (t >= 60 && same && settled < 0) settled = t;
      if (settled >= 0) assert.ok(same, `frame ${t} differs after settling at ${settled}`);
    },
  });
  assert.ok(settled >= 0 && settled <= 75, `settled at frame ${settled}`);
});

// CORE-0125, CORE-2382: a full-frame saturated-red/black square wave, 5 s at 60 Hz. The red token
// admits a large-area red transition (stats.over red and fired) at most once in any 60 frames, so
// the auditor sees at most one red transition, never a red flash, in every 1 s window.
/** Frames at which the model admitted a large-area red transition are at least 1 s apart. */
function assertRedRationed(admitted) {
  for (let i = 1; i < admitted.length; i++)
    assert.ok(admitted[i] - admitted[i - 1] >= 60, `large-area red admitted at frames ${admitted[i - 1]} and ${admitted[i]}`);
}
for (const hz of [3, 10]) {
  test(`full-frame red ${hz} Hz admits <= 1 red transition in every 1 s window`, () => {
    const admitted = [];
    const { audit } = run({ kind: 'square', hz, on: [255, 0, 0], off: BLACK }, {
      frames: 300,
      onFrame: (t, px, r) => {
        const s = r.stats;
        if ((s.over[2] && s.fired[2]) || (s.over[3] && s.fired[3])) admitted.push(t);
      },
    });
    assert.ok(admitted.length >= 2, `red admitted only at frames ${admitted}: held red never catches up`);
    assertRedRationed(admitted);
    assert.ok(audit.maxPerWindow('red') <= 1, `auditor counts ${audit.maxPerWindow('red')} red per 1 s`);
  });
}

// CORE-2382: a lasting full-frame red change. Until the red token, a held sub-block requested the
// same red transition on every later frame and was never admitted, so the output kept the old
// frame for as long as the input stayed changed (petals after a palette change on the web).
test('a lasting full-frame red-to-cyan change reaches the output within 1.5 s', () => {
  const lim = model.createLimiter({ width: W, height: H });
  const px = new Uint8Array(W * H * 4);
  const fill = rgb => { for (let i = 0; i < px.length; i += 4) px.set([...rgb, 255], i); };
  let caught = -1;
  for (let t = 0; t < 180; t++) {
    fill(t < 60 ? [255, 0, 0] : [0, 255, 255]);
    const r = lim.step(px, DT);
    if (t >= 60 && caught < 0 && r.held === 0 && r.out[0] === 0 && r.out[1] === 255) caught = t;
  }
  assert.ok(caught >= 60 && caught - 60 <= 90, `cyan reached the output at frame ${caught} (change at 60)`);
});

// CORE-1616: red that covers part of every sub-block. One pixel column in three switches between
// [110, 0, 0] and black: each pixel's red change is 50 on the auditor's scale (step 20) and the
// stripes cover a third of every 10° window, but a sub-block's mean red moves by a third of that,
// under the v0.1.0 step of 4096 codes: that model holds nothing and the auditor counts 20 red
// transitions a second on its output.
test('red stripes over a third of every sub-block admit <= 1 red transition a second', () => {
  const spec = { kind: 'stripes', hz: 10, every: 3, width: 1, on: [110, 0, 0], off: BLACK, bg: BLACK };
  const input = createAuditor({ width: W, height: H });
  const { audit, held } = run(spec, { frames: 300, onFrame: (t, px) => input.push(px, DT) });
  assert.ok(input.maxPerWindow('red') >= 6, `the auditor sees ${input.maxPerWindow('red')} red per 1 s in the input`);
  assert.ok(held.some(h => h > 0), 'nothing was held');
  assert.ok(audit.maxPerWindow('red') <= 1, `auditor counts ${audit.maxPerWindow('red')} red per 1 s`);
});

// Red saturation and red change are measured on linear light. [120, 50, 0] is saturated red
// there (R / (R + G + B) = 0.855, 320 (R - G - B) = 50) but not on the encoded bytes (0.706), so a
// byte-domain test sees no red flash at all (review 2026-11-13, OSC-0032).
test('full-frame [120,50,0]/[0,50,120] 10 Hz is red in linear light and admits <= 1 red transition a second', () => {
  const spec = { kind: 'square', hz: 10, on: [120, 50, 0], off: [0, 50, 120] };
  const input = createAuditor({ width: W, height: H });
  const admitted = [];
  const { audit, held } = run(spec, {
    frames: 300,
    onFrame: (t, px, r) => {
      input.push(px, DT);
      const s = r.stats;
      if ((s.over[2] && s.fired[2]) || (s.over[3] && s.fired[3])) admitted.push(t);
    },
  });
  assert.ok(input.maxPerWindow('red') >= 6, `the auditor sees ${input.maxPerWindow('red')} red per 1 s in the input`);
  assert.ok(held.some(h => h > 0), 'nothing was held');
  assertRedRationed(admitted);
  assert.ok(audit.maxPerWindow('red') <= 1, `auditor counts ${audit.maxPerWindow('red')} red per 1 s`);
});

// The codes never under-measure WCAG's linear-light thresholds (Codex round 11): over every 8-bit
// colour, the luma code is within 1.5 of 65535 Y and R - G - B of the linear codes within 1.5 of
// 65535 (R - G - B), so a luma change of 0.1 (6553.5) moves the code by at least 6550 (LUMA_STEP),
// a darker side under 0.8 (52428) reads under 52430 (LUMA_DARK), a red change of 20 on the 320
// scale (4096 linear codes) moves the red code by at least 15 (RED_STEP), and every saturated
// colour (R >= 4 (G + B)) passes the code's saturation test.
test('the 16-bit codes are conservative against WCAG linear-light thresholds', () => {
  const lin = k => { const c = k / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  const L = Float64Array.from({ length: 256 }, (_, k) => lin(k));
  const C = Int32Array.from(model.LUMA_LUT, v => v[3]);
  let lumaErr = 0, redErr = 0, satMiss = 0;
  for (let r = 0; r < 256; r++) {
    for (let g = 0; g < 256; g++) {
      for (let b = 0; b < 256; b++) {
        const y = 65535 * (0.2126 * L[r] + 0.7152 * L[g] + 0.0722 * L[b]);
        lumaErr = Math.max(lumaErr, Math.abs(model.lumaCode(r, g, b) - y));
        const d = 65535 * (L[r] - L[g] - L[b]);
        redErr = Math.max(redErr, Math.abs(C[r] - C[g] - C[b] - d));
        if (L[r] >= 4 * (L[g] + L[b]) && d >= 256 && model.redCode(r, g, b) === 0) satMiss++;
      }
    }
  }
  assert.ok(lumaErr <= 1.5, `luma code off by ${lumaErr}`);
  assert.ok(redErr <= 1.5, `red difference off by ${redErr}`);
  assert.equal(satMiss, 0, `${satMiss} saturated-red colours fail the code's saturation test`);
  assert.ok(model.LUMA_STEP <= Math.floor(6553.5 - 2 * lumaErr), `LUMA_STEP ${model.LUMA_STEP}`);
  assert.ok(model.LUMA_DARK > Math.floor(52428 + lumaErr), `LUMA_DARK ${model.LUMA_DARK}`);
  assert.ok(model.RED_STEP <= Math.ceil((4096 - 2 * redErr) / 256) - 1, `RED_STEP ${model.RED_STEP}`);
});

// Codex round 11's two strobes just over a threshold: red 28 on the 320 scale at a red fraction
// of 0.8000025, and a luma excursion of 0.1000026. Both read as flashing in the input and are
// limited in the output.
test('10 Hz strobes just over the red and luma thresholds are limited', () => {
  for (const [spec, channel, budget] of [
    [{ kind: 'square', hz: 10, on: [96, 40, 22], off: [0, 0, 0] }, 'red', 1],
    [{ kind: 'square', hz: 10, on: [65, 77, 193], off: [22, 4, 11] }, 'luma', 6],
  ]) {
    const input = createAuditor({ width: W, height: H });
    const { audit } = run(spec, { frames: 300, onFrame: (t, px) => input.push(px, DT) });
    assert.ok(input.maxPerWindow(channel) >= 18, `${spec.on}: the input shows ${input.maxPerWindow(channel)} ${channel} per 1 s`);
    assert.ok(audit.maxPerWindow(channel) <= budget, `${spec.on}: the output shows ${audit.maxPerWindow(channel)} ${channel} per 1 s`);
  }
});

test('full-frame luma-only 3 Hz still admits <= 3 flashes in every 1 s window', () => {
  const { audit } = run({ kind: 'square', hz: 3, on: WHITE, off: BLACK }, { frames: 300 });
  assert.equal(audit.maxPerWindow('luma'), 6, `luma ${audit.maxPerWindow('luma')} transitions per 1 s`);
  assert.equal(audit.maxPerWindow('red'), 0);
});

// CORE-0121: the area is the 10° field of the viewing geometry, and every pixel counts.
// A 10 Hz strobe over half of one 10° field at TV geometry (7 x 3.5 cells, 17% of the frame:
// under the old 20%-of-frame gate, but twice the 25%-of-field limit).
test('10 Hz strobe over half a 10° field at TV geometry is limited', () => {
  const spec = { kind: 'square', hz: 10, on: WHITE, off: BLACK, rect: [0.25, 1 / 3, 0.6875, 13 / 18], bg: BLACK };
  const { audit, held } = run(spec, { frames: 300, field: GEOMETRY.tv, limiter: { geometry: 'tv' } });
  assert.ok(audit.maxPerWindow('luma') <= 6, `luma ${audit.maxPerWindow('luma')} per 1 s in a TV 10° field`);
  assert.ok(held.some(h => h > 0), 'nothing was held');
});

// A full-frame 10 Hz checkerboard of half-cell squares: every cell holds both phases, so its
// mean never changes; only the sub-block reduction sees the reversal.
test('10 Hz half-cell checkerboard is limited', () => {
  const spec = { kind: 'checker', hz: 10, size: [1 / 32, 1 / 18], on: WHITE, off: BLACK };
  const { audit, held } = run(spec, { frames: 300 });
  assert.ok(audit.maxPerWindow('luma') <= 6, `luma ${audit.maxPerWindow('luma')} per 1 s`);
  assert.ok(held.some(h => h > 0), 'nothing was held');
});

// A full-frame 10 Hz checkerboard of 4 px squares: every sub-block holds both phases, so its mean
// never changes; only the per-pixel up and down counts against the previous output see the
// reversal (CORE-2515).
test('10 Hz fine (4 px) checkerboard is limited', () => {
  const spec = { kind: 'checker', hz: 10, size: [4 / W, 4 / H], on: WHITE, off: BLACK };
  const input = createAuditor({ width: W, height: H });
  const { audit, held } = run(spec, { frames: 300, onFrame: (t, px) => input.push(px, DT) });
  assert.ok(input.maxPerWindow('luma') >= 10, `input luma ${input.maxPerWindow('luma')} per 1 s`);
  assert.ok(audit.maxPerWindow('luma') <= 6, `luma ${audit.maxPerWindow('luma')} per 1 s`);
  assert.ok(held.some(h => h > 0), 'nothing was held');
});

// Codex review of CORE-2515: a full-frame step spends the luma token; a pair of grants for a fine
// pattern must still wait as long as two singles would, so no 1 s window holds more than 6.
test('a full-frame step before a fine checkerboard stays within 6 transitions a second', () => {
  const checker = { kind: 'checker', hz: 10, size: [4 / W, 4 / H], on: WHITE, off: BLACK };
  for (let start = 30; start <= 36; start += 2) {
    const lim = model.createLimiter({ width: W, height: H });
    const audit = createAuditor({ width: W, height: H });
    const px = new Uint8Array(W * H * 4);
    for (let t = 0; t < start + 120; t++) {
      if (t > start) renderSignal(checker, t, W, H, px);
      else px.fill(t < start ? 0 : 255).forEach((_, i) => { if (i % 4 === 3) px[i] = 255; });
      audit.push(lim.step(px, DT).out, DT);
    }
    assert.ok(audit.maxPerWindow('luma') <= 6, `step at ${start}: luma ${audit.maxPerWindow('luma')} per 1 s`);
  }
});

// Codex review of CORE-2515: a pair that falls once the token is full must still count as two
// grants, or full-frame flashes every 11 frames after it fit a seventh transition in 1 s.
test('a fine-pattern pair before full-frame flashes stays within 6 transitions a second', () => {
  const lims = [30, 31, 32, 33].map(at => {
    const lim = model.createLimiter({ width: W, height: H });
    const audit = createAuditor({ width: W, height: H });
    const px = new Uint8Array(W * H * 4);
    for (let t = 0; t < at + 140; t++) {
      for (let y = 0, i = 0; y < H; y++) {
        for (let x = 0; x < W; x++, i += 4) {
          const check = (Math.floor(x / 4) + Math.floor(y / 4) + (t >= at ? 1 : 0)) % 2;
          const v = t > at + 10 ? (Math.floor((t - at - 11) / 11) % 2 ? 0 : 255) : check ? 255 : 0;
          px[i] = px[i + 1] = px[i + 2] = v; px[i + 3] = 255;
        }
      }
      audit.push(lim.step(px, DT).out, DT);
    }
    return [at, audit.maxPerWindow('luma')];
  });
  lims.forEach(([at, n]) => assert.ok(n <= 6, `pair at ${at}: luma ${n} per 1 s`));
});

// Codex review of CORE-2413: a checkerboard of black and red sub-blocks inverts once, so red rises
// in some sub-blocks while it falls, held, in their neighbours. The feather must not hide the
// admitted rise and release it later beside the fall: at most one red transition a second.
test('an admitted red rise beside a held red fall is not hidden (CORE-2413)', () => {
  const lim = model.createLimiter({ width: W, height: H });
  const audit = createAuditor({ width: W, height: H });
  const px = new Uint8Array(W * H * 4);
  const bw = W / model.BLOCKS_X, bh = H / model.BLOCKS_Y;
  for (let t = 0; t < 150; t++) {
    for (let y = 0, i = 0; y < H; y++) {
      for (let x = 0; x < W; x++, i += 4) {
        const red = (Math.floor(x / bw) + Math.floor(y / bh) + (t >= 30 ? 1 : 0)) % 2;
        px[i] = red ? 160 : 0; px[i + 1] = px[i + 2] = 0; px[i + 3] = 255;
      }
    }
    audit.push(lim.step(px, DT).out, DT);
  }
  assert.ok(audit.maxPerWindow('red') <= 1, `red ${audit.maxPerWindow('red')} per 1 s`);
});

// Codex review (CORE-2541): a small red step beside luma holds must not be delayed. Blending it
// delayed the step 30 frames, so it completed a red transition after the red token refilled, and
// the fall to black 74 frames later made two red transitions within 1 s.
test('a small red step beside luma holds is not delayed (CORE-2541)', () => {
  const w = 128, h = 72;
  const lim = model.createLimiter({ width: w, height: h });
  const audit = createAuditor({ width: w, height: h });
  const px = new Uint8Array(w * h * 4);
  const shade = (cat, t) => {
    if (cat === 0) return t === 0 || t > 84 ? [0, 0, 0] : t <= 10 ? [69, 0, 0] : [72, 0, 0];
    const white = t >= 2 && t <= 10;
    const v = (cat === 1) === white ? 255 : 0;
    return [v, v, v];
  };
  for (let t = 0; t < 160; t++) {
    for (let y = 0, i = 0; y < h; y++) {
      for (let x = 0; x < w; x++, i += 4) {
        const [r, g, b] = shade((Math.floor(x / 2) + Math.floor(y / 2)) % 3, t);
        px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255;
      }
    }
    audit.push(lim.step(px, DT).out, DT);
  }
  assert.ok(audit.maxPerWindow('red') <= 1, `red ${audit.maxPerWindow('red')} per 1 s`);
});

// A grey bar one cell wide (W / 16, 35% linear white) on black, moving 0.0071 W a frame,
// area-antialiased in linear light: each pixel's byte is the one whose linear value is nearest its
// coverage. At 4K every 1080p pixel is exactly four pixels, so the same scene must make the same
// requests in every frame. (The speed and level were picked from six tried; the old point-tap
// model's totals match at both sizes in all six, but its per-frame requests differ in this one.)
const LINEAR = Float64Array.from({ length: 256 }, (_, k) => {
  const c = k / 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
});
const TO_BYTE = c => {
  let best = 0;
  for (let b = 1; b < 256; b++) if (Math.abs(LINEAR[b] - c) < Math.abs(LINEAR[best] - c)) best = b;
  return best;
};
export function renderBar(t, W, H, out) {
  const x0 = (0.1 + 0.0071 * t) * W, x1 = x0 + W / 16;
  const row = new Uint8Array(W);
  for (let x = 0; x < W; x++) row[x] = TO_BYTE(0.35 * Math.max(0, Math.min(x + 1, x1) - Math.max(x, x0)));
  for (let y = 0; y < H; y++) {
    for (let x = 0, i = y * W * 4; x < W; x++, i += 4) { out[i] = out[i + 1] = out[i + 2] = row[x]; out[i + 3] = 255; }
  }
  return out;
}
/** Per-frame request counts (luma up, luma down, red up, red down) and holds of the bar scene. */
export function barCounts(width, height, frames = 60) {
  const lim = model.createLimiter({ width, height });
  const px = new Uint8Array(width * height * 4);
  const perFrame = [];
  for (let t = 0; t < frames; t++) {
    const r = lim.step(renderBar(t, width, height, px), DT);
    perFrame.push([...r.stats.requests, r.held].join(','));
  }
  return perFrame;
}
// The pixel counts (a quarter of a sub-block's pixels) are whole pixels, so where the bar's edge
// crosses exactly a quarter of a sub-block the 4K count can tie the threshold where the 1080p one
// falls a fraction of a pixel short (CORE-2543). Such a frame may differ by one column of luma
// requests in each direction; red requests and holds never differ.
test('a one-cell-wide moving bar counts the same at 1080p and 4K', () => {
  const hd = barCounts(1920, 1080), uhd = barCounts(3840, 2160);
  const differ = hd.map((v, t) => (v === uhd[t] ? -1 : t)).filter(t => t >= 0);
  assert.ok(differ.length <= 3, `requests differ at frames ${differ.slice(0, 5)}: 1080p ${hd[differ[0]]} vs 4K ${uhd[differ[0]]}`);
  for (const t of differ) {
    const a = hd[t].split(',').map(Number), b = uhd[t].split(',').map(Number);
    const tie = Math.abs(a[0] - b[0]) <= model.BLOCKS_Y && Math.abs(a[1] - b[1]) <= model.BLOCKS_Y;
    assert.ok(tie && a[2] === b[2] && a[3] === b[3] && a[4] === b[4], `frame ${t}: 1080p ${hd[t]} vs 4K ${uhd[t]}`);
  }
  assert.ok(hd.some(v => !v.startsWith('0,0,')), 'the bar made no requests');
});

// The output is exact: a held pixel shows history and every other pixel shows the input, so the
// output makes only the transitions the trackers counted. A 10 Hz strobe over half a TV 10° field
// is held while the background drifts below a step. The strobe's edges fall inside sub-blocks, so
// background pixels share sub-blocks with held ones and must still show their input (per-pixel
// holds, Codex round 11). (Until v0.2.9 the pixels around a hold blended toward history, which
// delayed admitted changes: CORE-2541, CORE-2543.)
function exactness(bg) {
  const lim = model.createLimiter({ width: W, height: H, geometry: 'tv' });
  const px = new Uint8Array(W * H * 4), prev = new Uint8Array(W * H * 4);
  let held = 0;
  for (let t = 0; t < 120; t++) {
    const on = Math.floor(t / 3) % 2 === 1, c = bg(t);
    for (let y = 0; y < H; y++) {
      for (let x = 0, i = y * W * 4; x < W; x++, i += 4) {
        const inRect = x >= W / 4 + 2 && x < W * 11 / 16 + 3 && y >= H / 3 + 1 && y < H * 13 / 18 + 2;
        const v = inRect ? (on ? WHITE : BLACK) : c;
        px[i] = v[0]; px[i + 1] = v[1]; px[i + 2] = v[2]; px[i + 3] = 255;
      }
    }
    const r = lim.step(px, DT);
    // Every strobe pixel changes alike, so they hold together; the background never fires.
    for (let y = 0; y < H; y++) {
      for (let x = 0, i = y * W * 4; x < W; x++, i += 4) {
        const inRect = x >= W / 4 + 2 && x < W * 11 / 16 + 3 && y >= H / 3 + 1 && y < H * 13 / 18 + 2;
        const h = inRect && r.held > 0 ? 1 : 0;
        held += h;
        const src = h ? prev : px;
        for (let ch = 0; ch < 3; ch++) {
          assert.equal(r.out[i + ch], src[i + ch], `frame ${t}: pixel ${x},${y} shows neither ${h ? 'history' : 'the input'}`);
        }
      }
    }
    prev.set(r.out);
  }
  return held;
}
test('a held pixel shows history and every other pixel the input', () => {
  assert.ok(exactness(t => { const v = 60 + (t % 8); return [v, v, v]; }) > 0, 'nothing was held');
  assert.ok(exactness(t => [255, 150 + (t % 8), 0]) > 0, 'nothing was held');
  assert.ok(exactness(t => [200, 20 + (t % 8), 0]) > 0, 'nothing was held');
});

// Codex review (CORE-2543): beside a red region held by the red budget, a luma rise admitted at
// frame 10 was blended toward history until the hold released at frame 82, after the luma token it
// spent had refilled, and the black/colour alternation from frame 84 then made seven luma
// transitions within 0.95 s. The rise must show when it is admitted, whatever its colour.
for (const rise of [[180, 110, 0], [140, 140, 140], [90, 140, 200]]) {
  test(`an admitted luma rise beside a red hold is not delayed: ${rise} (CORE-2543)`, () => {
    const w = 128, h = 72;
    const lim = model.createLimiter({ width: w, height: h });
    const audit = createAuditor({ width: w, height: h });
    const px = new Uint8Array(w * h * 4);
    const shade = (cat, t) => {
      if (cat === 0) return t === 1 ? [0, 0, 0] : [160, 0, 0];
      if (t < 10) return [0, 0, 0];
      if (t < 84) return rise;
      return Math.floor((t - 84) / 11) % 2 === 0 ? [0, 0, 0] : rise;
    };
    for (let t = 0; t < 145; t++) {
      for (let y = 0, i = 0; y < h; y++) {
        for (let x = 0; x < w; x++, i += 4) {
          const [r, g, b] = shade((Math.floor(x / 2) + Math.floor(y / 2)) % 3, t);
          px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255;
        }
      }
      audit.push(lim.step(px, DT).out, DT);
    }
    assert.ok(audit.maxPerWindow('luma') <= 6, `luma ${audit.maxPerWindow('luma')} per 1 s`);
    assert.ok(audit.maxPerWindow('red') <= 1, `red ${audit.maxPerWindow('red')} per 1 s`);
  });
}

// CORE-2543: a change over part of each sub-block. The top 2 of every 5 rows toggle between grey
// 124 and 153 at 10 Hz: 40% of the frame's pixels change by more than a luma step, which the
// pixel auditor counts, while each sub-block's mean moves less than half a step, which the
// trackers miss. The pixel counts request it once a quarter of a sub-block's pixels change.
test('a 10 Hz change over 2/5 of every sub-block is limited (CORE-2543)', () => {
  const input = createAuditor({ width: W, height: H });
  const lim = model.createLimiter({ width: W, height: H });
  const audit = createAuditor({ width: W, height: H });
  const px = new Uint8Array(W * H * 4);
  for (let t = 0; t < 300; t++) {
    const top = Math.floor(t / 3) % 2 === 0 ? 124 : 153;
    for (let y = 0, i = 0; y < H; y++) {
      const v = y % 5 < 2 ? top : 124;
      for (let x = 0; x < W; x++, i += 4) { px[i] = px[i + 1] = px[i + 2] = v; px[i + 3] = 255; }
    }
    input.push(px, DT);
    audit.push(lim.step(px, DT).out, DT);
  }
  assert.ok(input.maxPerWindow('luma') > 6, `the input makes only ${input.maxPerWindow('luma')} luma transitions per 1 s`);
  assert.ok(audit.maxPerWindow('luma') <= 6, `luma ${audit.maxPerWindow('luma')} per 1 s`);
});

// Codex review round 7 (CORE-2543): the auditor tracks every pixel, so a change it counts can
// build up over several frames (a grey cycling 124, 140, 153, 140: no single frame moves a luma
// step) or cover under a quarter of each sub-block. Beside red holds, both made 20 to 30 luma
// transitions a second through the sub-block trackers. Per-pixel trackers count what the auditor
// counts.
function categoryScene(w, h, side, frames, shade) {
  const lim = model.createLimiter({ width: w, height: h });
  const audit = createAuditor({ width: w, height: h });
  const px = new Uint8Array(w * h * 4);
  for (let t = 0; t < frames; t++) {
    for (let y = 0, i = 0; y < h; y++) {
      for (let x = 0; x < w; x++, i += 4) {
        const [r, g, b] = shade(Math.floor(x / side) + Math.floor(y / side), y % side, y, t);
        px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255;
      }
    }
    audit.push(lim.step(px, DT).out, DT);
  }
  assert.ok(audit.maxPerWindow('luma') <= 6, `luma ${audit.maxPerWindow('luma')} per 1 s`);
  assert.ok(audit.maxPerWindow('red') <= 1, `red ${audit.maxPerWindow('red')} per 1 s`);
}
const RED_HOLD = t => (t === 1 ? [0, 0, 0] : [160, 0, 0]);
test('a grey cycle under a luma step a frame is limited (Codex round 7)', () => {
  const cycle = [124, 140, 153, 140];
  categoryScene(128, 72, 2, 80, (k, row, y, t) => {
    if (k % 3 === 0) return RED_HOLD(t);
    const v = y % 2 === 0 ? cycle[t % 4] : 124;
    return [v, v, v];
  });
});
test('changes over a fifth of some sub-blocks count towards the area (Codex round 7)', () => {
  categoryScene(320, 180, 5, 80, (k, row, y, t) => {
    const cat = k % 6;
    if (cat < 2) return RED_HOLD(t);
    const v = Math.floor(t / 3) % 2 === 0 ? 124 : 153;
    if (cat === 2 || row === 0) return [v, v, v];
    return [124, 124, 124];
  });
});

// --luma-digest: one FNV-1a digest per luminance-only signal over every output byte and hold
// count, to show a model change leaves luminance behaviour byte-identical.
if (process.argv.includes('--luma-digest')) {
  const signals = {
    'luma-3hz': { kind: 'square', hz: 3, on: WHITE, off: BLACK },
    'luma-10hz': { kind: 'square', hz: 10, on: WHITE, off: BLACK },
    'luma-10hz-grey': { kind: 'square', hz: 10, on: WHITE, off: GREY },
    'luma-10hz-small': { kind: 'square', hz: 10, on: WHITE, off: BLACK, rect: [0.25, 0.25, 0.5, 0.5], bg: GREY },
    'luma-settle': { kind: 'square', hz: 10, on: WHITE, off: BLACK, until: 60, after: 'on' },
    'luma-checker': { kind: 'checker', hz: 10, size: [1 / 32, 1 / 18], on: WHITE, off: BLACK },
  };
  for (const [name, spec] of Object.entries(signals)) {
    let h = 0x811c9dc5;
    const mix = v => { h = Math.imul(h ^ v, 0x01000193) >>> 0; };
    const { held } = run(spec, { frames: 300, onFrame: (t, px, r) => r.out.forEach(mix) });
    held.forEach(mix);
    console.log(`${name} ${h.toString(16).padStart(8, '0')} held-frames=${held.filter(x => x > 0).length}`);
  }
  process.exit(0);
}

let failed = 0;
for (const c of cases) {
  try {
    c.fn();
    console.log(`ok   ${c.name}`);
  } catch (e) {
    failed++;
    console.log(`FAIL ${c.name}: ${e.message.split('\n')[0]}`);
  }
}
console.log(`limiter model (${model.MODEL}): ${cases.length - failed}/${cases.length} cases pass`);
process.exit(failed ? 1 : 0);
