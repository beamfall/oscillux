// SPDX-License-Identifier: AGPL-3.0-only
// Model tests for the frame flash limiter (tools/shader/limiter-model.mjs): synthetic signals
// through the model, its output audited pixel by pixel (limiter-audit.mjs). --model <path> runs
// the same cases against another model file, for parent-commit failure proofs; --grep <text> runs
// only the cases whose names contain it.
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createAuditor } from './limiter-audit.mjs';
import { GEOMETRY } from './limiter-geometry.mjs';
import { renderSignal } from './limiter-signals.mjs';
import { CASES as VECTOR_CASES } from './limiter-vectors.mjs';

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

// Codex round 20: the red release bound at a mixed cadence. A frame's refill is capped at one
// refill period, so a long frame earns less than its length. A full-frame red rise spends the
// token; the fall to black is held until the intervals of the frames after the spend, each
// counted up to one refill period, add up to (65025 / 65024) 8 periods (Codex round 21).
test('a held red fall is admitted within the capped-interval bound at a mixed cadence (Codex round 20)', () => {
  const lim = model.createLimiter({ width: W, height: H });
  const px = new Uint8Array(W * H * 4);
  const fill = rgb => { for (let i = 0; i < px.length; i += 4) px.set([...rgb, 255], i); };
  const period = 1 / (2 * 3);
  const need = (model.TOKEN / (model.TOKEN - 1)) * 8 * period;
  fill(BLACK); lim.step(px, DT);
  fill([255, 0, 0]);
  assert.equal(lim.step(px, DT).redDeficit, model.TOKEN, 'the red rise spends the red token');
  fill(BLACK);
  let counted = 0, bound = -1, released = -1;
  for (let t = 0; t < 40; t++) {
    const dt = t % 2 ? 0.010 : 0.250;
    counted += Math.min(dt, period);
    if (bound < 0 && counted >= need) bound = t;
    const r = lim.step(px, dt);
    if (released < 0 && r.held === 0 && r.out[0] === 0) released = t;
  }
  assert.ok(bound > 9, `the cadence is mixed enough to exceed nine frames (bound at frame ${bound})`);
  assert.equal(released, bound, `released at frame ${released}, bound frame ${bound}`);
});

// Codex round 21: at a steady 250 ms cadence a held red fall is released on the ninth frame after
// the spend. setGeometry writes the red token spent and its first frame earns nothing, so a red
// rise held from that frame is admitted on the tenth.
test('a held red change is released on the ninth frame after a grant, the tenth after setGeometry (Codex round 21)', () => {
  const px = new Uint8Array(W * H * 4);
  const fill = rgb => { for (let i = 0; i < px.length; i += 4) px.set([...rgb, 255], i); };
  const admitted = (lim, rgb) => {
    fill(rgb);
    for (let t = 1; t < 40; t++) {
      const r = lim.step(px, 0.25);
      if (r.held === 0 && r.out[0] === rgb[0]) return t;
    }
    return -1;
  };
  const lim = model.createLimiter({ width: W, height: H });
  fill(BLACK); lim.step(px, 0.25);
  fill([255, 0, 0]);
  assert.equal(lim.step(px, 0.25).redDeficit, model.TOKEN, 'the red rise spends the red token');
  assert.equal(admitted(lim, BLACK), 9);
  lim.setGeometry('wcag');
  assert.equal(admitted(lim, [255, 0, 0]), 10);
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

// The codes never under-measure WCAG's linear-light thresholds (Codex rounds 11 to 13): over every
// 8-bit colour, the 15-bit luma code is within 1.25 of 32767.5 Y and R - G - B of the linear codes
// within 1.5 of 65535 (R - G - B), so the luma step and darker side are WCAG's 0.1 and 0.8 at the
// nearest code, a red change of 20 on the 320 scale (4096 linear codes) moves the red code by at
// least 15 (RED_STEP), and every saturated colour (R >= 4 (G + B)) passes the saturation test.
test('the codes track WCAG linear light and take its thresholds', () => {
  const lin = k => { const c = k / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  const L = Float64Array.from({ length: 256 }, (_, k) => lin(k));
  const C = Int32Array.from(model.LUMA_LUT, v => v[3]);
  let lumaErr = 0, lumaUp = 0, lumaDown = 0, redErr = 0, redMiss = 0, satMiss = 0;
  for (let r = 0; r < 256; r++) {
    for (let g = 0; g < 256; g++) {
      for (let b = 0; b < 256; b++) {
        const y = 32767.5 * (0.2126 * L[r] + 0.7152 * L[g] + 0.0722 * L[b]);
        const e = model.lumaCode(r, g, b) - y;
        lumaErr = Math.max(lumaErr, Math.abs(e));
        lumaUp = Math.max(lumaUp, e);
        lumaDown = Math.max(lumaDown, -e);
        const d = 65535 * (L[r] - L[g] - L[b]);
        redErr = Math.max(redErr, Math.abs(C[r] - C[g] - C[b] - d));
        if (d >= 258 && model.redCode(r, g, b) === 0) redMiss++;
        if (L[r] > 0 && L[r] >= 4 * (L[g] + L[b]) && !model.redSat(r, g, b)) satMiss++;
      }
    }
  }
  assert.ok(lumaErr <= 1.25, `luma code off by ${lumaErr}`);
  assert.ok(redErr <= 1.5, `red difference off by ${redErr}`);
  assert.equal(redMiss, 0, `${redMiss} red colours (saturated or not) measure no red`);
  assert.equal(satMiss, 0, `${satMiss} saturated red colours fail the saturation test`);
  assert.equal(model.LUMA_MAX, 32767);
  // The steps are the thresholds less the codes' worst error either way (Codex round 13): a luma
  // change of 0.1 moves the integer code by at least ceil(3276.75 - up - down), a red change of
  // 20/320 moves the red code (a >> 8 of the difference) by at least floor((4096 - 3) / 256) = 15,
  // and a darker side below 0.8 has a code below 26214 + up.
  assert.ok(model.LUMA_STEP <= Math.ceil(0.1 * 32767.5 - lumaUp - lumaDown), `luma step ${model.LUMA_STEP} (${lumaUp}, ${lumaDown})`);
  assert.equal(model.LUMA_STEP, 3275);
  assert.ok(model.LUMA_DARK >= 0.8 * 32767.5 + lumaUp, `luma dark ${model.LUMA_DARK}`);
  assert.equal(model.LUMA_DARK, 26215);
  assert.equal(model.RED_STEP, Math.floor((4096 - 2 * redErr) / 256));
  assert.equal(model.RED_STEP, 15);
});

// Codex round 12: WCAG counts a transition between saturated red and an unsaturated state, so a
// strobe between dark saturated red and a brighter purple-red (red fraction 0.76) is a red flash.
test('a strobe between saturated and unsaturated red is limited', () => {
  const spec = { kind: 'square', hz: 10, on: [155, 0, 90], off: [48, 0, 0] };
  const input = createAuditor({ width: W, height: H });
  const { audit } = run(spec, { frames: 300, onFrame: (t, px) => input.push(px, DT) });
  assert.ok(input.maxPerWindow('red') >= 18, `the input shows ${input.maxPerWindow('red')} red per 1 s`);
  assert.ok(audit.maxPerWindow('red') <= 1, `the output shows ${audit.maxPerWindow('red')} red per 1 s`);
});

// Neither state saturated (red fractions 0.74 and 0.75): a change between two oranges is no red
// transition, so a 3 Hz orange strobe passes as luma only.
test('a change between two oranges is not a red transition', () => {
  const spec = { kind: 'square', hz: 3, on: [255, 160, 0], off: [180, 110, 0] };
  const input = createAuditor({ width: W, height: H });
  const { audit } = run(spec, { frames: 300, onFrame: (t, px) => input.push(px, DT) });
  assert.equal(input.maxPerWindow('red'), 0, `the input shows ${input.maxPerWindow('red')} red per 1 s`);
  assert.equal(audit.maxPerWindow('red'), 0);
  assert.equal(audit.maxPerWindow('luma'), input.maxPerWindow('luma'));
});

// Codex round 11's two strobes just over a threshold: red 28 on the 320 scale at a red fraction
// of 0.8000025, and a luma excursion of 6553 16-bit codes (0.09999 relative luminance). Both read as
// flashing in the input and are limited in the output.
test('10 Hz strobes just over the red and luma thresholds are limited', () => {
  for (const [spec, channel, budget] of [
    [{ kind: 'square', hz: 10, on: [96, 40, 22], off: [0, 0, 0] }, 'red', 1],
    [{ kind: 'square', hz: 10, on: [65, 77, 193], off: [20, 5, 11] }, 'luma', 6],
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
// requests in each direction; red requests never differ. Holds are pixels, so they are compared as
// a share of the frame: the bar's anti-aliased edges fire at slightly different columns, so the
// shares may differ by two 1080p columns.
test('a one-cell-wide moving bar counts the same at 1080p and 4K', () => {
  const hd = barCounts(1920, 1080), uhd = barCounts(3840, 2160);
  const req = v => v.split(',').slice(0, 4).join(',');
  const differ = hd.map((v, t) => (req(v) === req(uhd[t]) ? -1 : t)).filter(t => t >= 0);
  assert.ok(differ.length <= 3, `requests differ at frames ${differ.slice(0, 5)}: 1080p ${hd[differ[0]]} vs 4K ${uhd[differ[0]]}`);
  for (const t of differ) {
    const a = hd[t].split(',').map(Number), b = uhd[t].split(',').map(Number);
    const tie = Math.abs(a[0] - b[0]) <= model.BLOCKS_Y && Math.abs(a[1] - b[1]) <= model.BLOCKS_Y;
    assert.ok(tie && a[2] === b[2] && a[3] === b[3], `frame ${t}: 1080p ${hd[t]} vs 4K ${uhd[t]}`);
  }
  for (let t = 0; t < hd.length; t++) {
    const a = Number(hd[t].split(',')[4]) / (1920 * 1080), b = Number(uhd[t].split(',')[4]) / (3840 * 2160);
    assert.ok((a > 0) === (b > 0) && Math.abs(a - b) <= 2 / 1920 + 1e-9, `frame ${t}: held 1080p ${hd[t]} vs 4K ${uhd[t]}`);
  }
  assert.ok(hd.some(v => !v.startsWith('0,0,')), 'the bar made no requests');
});

// The output is exact where nothing is held: a pixel that is not held shows the input, so the
// output makes only the transitions the trackers counted. A 10 Hz strobe over half a TV 10° field
// is held while the background drifts below a step. The strobe's edges fall inside sub-blocks, so
// background pixels share sub-blocks with held ones and must still show their input (per-pixel
// holds, Codex round 11). (Until v0.2.9 the pixels around a hold blended toward history, which
// delayed admitted changes: CORE-2541, CORE-2543.) The held strobe pixels change alike, so they
// show one colour, a grey (white scaled down, or black mixed with the grey shown before:
// limiter-dim-hold).
function exactness(bg) {
  const lim = model.createLimiter({ width: W, height: H, geometry: 'tv' });
  const px = new Uint8Array(W * H * 4);
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
    let grey = -1;
    for (let y = 0; y < H; y++) {
      for (let x = 0, i = y * W * 4; x < W; x++, i += 4) {
        const inRect = x >= W / 4 + 2 && x < W * 11 / 16 + 3 && y >= H / 3 + 1 && y < H * 13 / 18 + 2;
        if (inRect && r.held > 0) {
          held++;
          if (grey < 0) grey = r.out[i];
          for (let ch = 0; ch < 3; ch++) assert.equal(r.out[i + ch], grey, `frame ${t}: held pixel ${x},${y} is not the strobe's one grey`);
        } else {
          for (let ch = 0; ch < 3; ch++) assert.equal(r.out[i + ch], px[i + ch], `frame ${t}: pixel ${x},${y} does not show the input`);
        }
      }
    }
  }
  return held;
}
test('a pixel that is not held shows the input, and a held strobe one grey', () => {
  assert.ok(exactness(t => { const v = 60 + (t % 8); return [v, v, v]; }) > 0, 'nothing was held');
  assert.ok(exactness(t => [255, 150 + (t % 8), 0]) > 0, 'nothing was held');
  assert.ok(exactness(t => [200, 20 + (t % 8), 0]) > 0, 'nothing was held');
});

// limiter-dim-hold. The directions a packed tracker (four words at q) fires in on a colour, as the
// model's output pass computes them.
function firesOn(track, q, r, g, b, hist) {
  return model.texelFires(track[q], track[q + 1], track[q + 2], track[q + 3], r, g, b, hist[q], hist[q + 1], hist[q + 2]);
}

// The bound, per pixel and by construction: on every frame a pixel's trackers fire on the output
// only in directions they fire on the input and the grant admitted (what v0.2.9 guaranteed by
// showing the previous output). Signals that hold luma, red and both, with colour.
for (const [name, spec] of [
  ['a 10 Hz white strobe', { kind: 'square', hz: 10, on: WHITE, off: BLACK }],
  ['a 10 Hz saturated-red strobe', { kind: 'square', hz: 10, on: [230, 0, 0], off: BLACK }],
  ['a 12 Hz red and cyan strobe over a drifting background', { kind: 'square', hz: 12, on: [255, 20, 0], off: [0, 220, 255], rect: [0.1, 0.1, 0.8, 0.9], bg: [40, 30, 90], bgStep: [1, 0, 1] }],
  ['a 15 Hz orange and blue checkerboard', { kind: 'checker', hz: 15, size: [0.11, 0.17], on: [255, 140, 0], off: [20, 40, 160] }],
]) {
  test(`a held pixel fires only what the input fires and the grant admitted: ${name}`, () => {
    const lim = model.createLimiter({ width: W, height: H });
    const px = new Uint8Array(W * H * 4), before = new Uint32Array(W * H * 4), prev = new Uint8Array(W * H * 4);
    let held = 0, moved = 0;
    for (let t = 0; t < 150; t++) {
      renderSignal(spec, t, W, H, px);
      const r = lim.step(px, DT);
      if (t > 0) {
        for (let q = 0; q < W * H * 4; q += 4) {
          const asked = firesOn(before, q, px[q], px[q + 1], px[q + 2], prev);
          const shown = firesOn(before, q, r.out[q], r.out[q + 1], r.out[q + 2], prev);
          assert.equal(shown & ~(asked & r.grant), 0, `frame ${t}: pixel ${q / 4} fires ${shown}, input ${asked}, grant ${r.grant & 15}`);
          if (asked & ~r.grant & 15) held++;
          else for (let ch = 0; ch < 3; ch++) assert.equal(r.out[q + ch], px[q + ch], `frame ${t}: pixel ${q / 4} is not held and does not show the input`);
        }
        moved += r.held;
      }
      before.set(r.track);
      prev.set(r.out);
    }
    assert.ok(held > 0, 'nothing was held');
    assert.equal(held, moved, 'the held count is the pixels that would fire outside the grant');
  });
}

// A held pixel follows the input. A blue-white bar (no red) steps across black faster than the
// grants admit. A pixel denied a rise shows the previous output mixed toward the bar as far as its
// tracker's band allows, then an eighth of the way toward the bar scaled toward black to the top
// of the band: over black, the bar dimmed (not the black of the previous output). A pixel denied
// a fall shows black mixed with the least of the previous output that reaches the bottom of its
// band, less than a step below the luma it had.
test('a denied rise shows the input dimmed and a denied fall dims to a step below its peak', () => {
  const lim = model.createLimiter({ width: W, height: H });
  const audit = createAuditor({ width: W, height: H });
  const px = new Uint8Array(W * H * 4), before = new Uint32Array(W * H * 4), prev = new Uint8Array(W * H * 4);
  const BAR = [120, 200, 255];
  const scale = (c, k) => Math.floor((c * k + 127) / 255);
  const mix = (a, b, k) => (a * (256 - k) + b * k + 128) >> 8;
  const band = q => {
    const ext = before[q] & model.LUMA_MAX, dist = before[q + 1] & 4095, up = (before[q + 1] & model.LUMA_UP) !== 0;
    return { high: up ? ext : ext + dist, low: up ? ext - dist : ext };
  };
  let rises = 0, falls = 0, fresh = 0, dimmed = 0;
  for (let t = 0; t < 180; t++) {
    const x0 = (t * 40) % W;
    for (let y = 0, i = 0; y < H; y++) {
      for (let x = 0; x < W; x++, i += 4) {
        const c = (x - x0 + W) % W < 120 ? BAR : BLACK;
        px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
      }
    }
    const r = lim.step(px, DT);
    audit.push(r.out, DT);
    if (t > 0) {
      for (let q = 0; q < W * H * 4; q += 4) {
        const asked = firesOn(before, q, px[q], px[q + 1], px[q + 2], prev);
        const denied = asked & ~r.grant & 15;
        if (!denied) continue;
        const o = [r.out[q], r.out[q + 1], r.out[q + 2]];
        const v = model.lumaCode(o[0], o[1], o[2]);
        const { high, low } = band(q);
        if (denied & 1) {
          rises++;
          const ceil = low + model.LUMA_STEP - 1;
          const h = [prev[q], prev[q + 1], prev[q + 2]];
          const was = model.lumaCode(h[0], h[1], h[2]), bar = model.lumaCode(BAR[0], BAR[1], BAR[2]);
          const top = was < ceil ? ceil - (((ceil - was) * Math.floor(Math.min(256, Math.floor(768 * was / ceil)) * (bar - ceil) / bar)) >> 8) : ceil;
          const under = c => model.lumaCode(c[0], c[1], c[2]) <= top;
          let k = 254, m = 255;
          while (!under(BAR.map(c => scale(c, k)))) k--;
          while (m > 0 && !under(BAR.map((c, ch) => mix(h[ch], c, m)))) m--;
          const d = BAR.map(c => scale(c, k));
          const e = BAR.map((c, ch) => mix(mix(h[ch], c, m), d[ch], 32));
          assert.deepEqual(o, under(e) ? e : d, `frame ${t}: pixel ${q / 4} shows ${o} over the previous ${h}`);
          assert.ok(v <= ceil, `frame ${t}: pixel ${q / 4} luma ${v} is over its band ${ceil}`);
          assert.ok(v > top - (model.LUMA_STEP >> 3), `frame ${t}: pixel ${q / 4} luma ${v} is dimmer than its limit ${top} needs`);
          if (was === 0) assert.equal(top, ceil, `frame ${t}: pixel ${q / 4} was black and its limit ${top} is not its band ${ceil}`);
          if (low === 0) {
            assert.ok(v > 0, `frame ${t}: pixel ${q / 4} stays black under the bar`);
            if (h[0] === 0 && h[1] === 0 && h[2] === 0) {
              fresh++;
              assert.ok(o[0] < o[1] && o[1] < o[2], `frame ${t}: pixel ${q / 4} shows ${o}, not the bar's colour`);
            }
          }
        } else {
          falls++;
          const floor = Math.min(high - model.LUMA_STEP + 1, model.LUMA_DARK);
          const h = [prev[q], prev[q + 1], prev[q + 2]];
          const k = Array.from({ length: 257 }, (_, n) => n).find(n => h.every((c, ch) => mix(0, c, n) === o[ch]));
          assert.ok(k !== undefined, `frame ${t}: pixel ${q / 4} shows ${o}, not black mixed with the previous ${h}`);
          assert.ok(v >= floor, `frame ${t}: pixel ${q / 4} luma ${v} is under its band ${floor}`);
          assert.ok(k === 0 || model.lumaCode(mix(0, h[0], k - 1), mix(0, h[1], k - 1), mix(0, h[2], k - 1)) < floor, `frame ${t}: pixel ${q / 4} is brighter than its band needs`);
          if (model.lumaCode(h[0], h[1], h[2]) > floor + 64) dimmed++;
        }
      }
    }
    before.set(r.track);
    prev.set(r.out);
  }
  assert.ok(rises > 0 && falls > 0, `denied rises ${rises}, falls ${falls}`);
  assert.ok(fresh > 0, 'no black pixel showed the bar dimmed');
  assert.ok(dimmed > 0, 'no pixel denied a fall showed less than the previous output');
  assert.ok(audit.maxPerWindow('luma') <= 6, `luma ${audit.maxPerWindow('luma')} per 1 s`);
});

// The grey edges on laser-tunnel (limiter-dim-hold): a near-white line steps across a dim teal
// glow faster than the grants admit. A pixel denied the rise showed the line scaled toward black,
// which is a grey at the top of the band beside the teal. It keeps the hue it showed instead: its
// luma less than a step above the tracker's low, and more than half the spread between its
// channels that the glow had. The band cannot show a line that bright, so the pixel also stays
// nearer the glow's luma than the top of its band, and the line leaves little trace where it is.
test('a denied rise over a lit background keeps the background hue and stays near it', () => {
  const lim = model.createLimiter({ width: W, height: H });
  const px = new Uint8Array(W * H * 4), before = new Uint32Array(W * H * 4), prev = new Uint8Array(W * H * 4);
  const GLOW = [34, 84, 86], LINE = [235, 240, 238];
  const spread = c => Math.max(c[0], c[1], c[2]) - Math.min(c[0], c[1], c[2]);
  let kept = 0;
  for (let t = 0; t < 180; t++) {
    const x0 = (t * 40) % W;
    for (let y = 0, i = 0; y < H; y++) {
      for (let x = 0; x < W; x++, i += 4) {
        const c = t >= 30 && (x - x0 + W) % W < 24 ? LINE : GLOW;
        px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
      }
    }
    const r = lim.step(px, DT);
    if (t > 0) {
      for (let q = 0; q < W * H * 4; q += 4) {
        if (!(firesOn(before, q, px[q], px[q + 1], px[q + 2], prev) & ~r.grant & 1)) continue;
        if (prev[q] !== GLOW[0] || prev[q + 1] !== GLOW[1] || prev[q + 2] !== GLOW[2]) continue;
        const o = [r.out[q], r.out[q + 1], r.out[q + 2]];
        const ext = before[q] & model.LUMA_MAX, dist = before[q + 1] & 4095, up = (before[q + 1] & model.LUMA_UP) !== 0;
        const ceil = (up ? ext - dist : ext) + model.LUMA_STEP - 1;
        const v = model.lumaCode(o[0], o[1], o[2]);
        assert.ok(v <= ceil, `frame ${t}: pixel ${q / 4} luma ${v} is over its band ${ceil}`);
        assert.ok(v > model.lumaCode(GLOW[0], GLOW[1], GLOW[2]), `frame ${t}: pixel ${q / 4} shows ${o}, no brighter than the glow`);
        assert.ok(2 * spread(o) > spread(GLOW), `frame ${t}: pixel ${q / 4} shows ${o}, a grey beside the glow ${GLOW}`);
        const glow = model.lumaCode(GLOW[0], GLOW[1], GLOW[2]);
        assert.ok(3 * glow > ceil, `frame ${t}: the glow ${glow} is not over a third of the band ${ceil}`);
        assert.ok(2 * v < glow + ceil, `frame ${t}: pixel ${q / 4} luma ${v} is nearer its band ${ceil} than the glow ${glow}`);
        kept++;
      }
    }
    before.set(r.track);
    prev.set(r.out);
  }
  assert.ok(kept > 0, 'no pixel showing the glow was denied a rise');
});

// Codex review of limiter-dim-hold: the luma and the trackers of rounded mixes cross a threshold
// more than once, and a bisection along the mix stopped at the wrong crossing. Uniform frames:
// black, a colour, then one whose change is denied. A denied fall needs one step (of 256) of the
// previous output to reach its floor, though the next valid mix is 140 steps away. A denied rise
// has its furthest mix under the limit at step 90, past three steps over it; an eighth from there
// toward the scaled input is over the limit, so the pixel shows the scaled input. A red change
// has a safe mix from the grey 12 steps from the dimmed input, past unsafe steps on both sides.
for (const [name, from, to, want] of [
  ['a denied fall takes one step of the previous output', [240, 123, 247], [31, 167, 125], [32, 167, 125]],
  ['a denied rise finds the furthest mix under its limit', [23, 189, 209], [12, 250, 58], [10, 214, 50]],
  ['a denied red change finds the safe mix beside the input', [154, 194, 79], [251, 130, 9], [247, 132, 16]],
]) {
  test(`a held pixel's search does not stop at the first crossing: ${name}`, () => {
    const width = 64, height = 36;
    const lim = model.createLimiter({ width, height });
    const px = new Uint8Array(width * height * 4), before = new Uint32Array(width * height * 4);
    let r, prev = new Uint8Array(width * height * 4);
    for (const c of [BLACK, from, to]) {
      if (r) { before.set(r.track); prev = r.out.slice(); }
      renderSignal({ kind: 'solid', color: c }, 0, width, height, px);
      r = lim.step(px, DT);
    }
    assert.equal(r.held, width * height, 'the frame is not held');
    const asked = firesOn(before, 0, to[0], to[1], to[2], prev), shown = firesOn(before, 0, r.out[0], r.out[1], r.out[2], prev);
    assert.equal(shown & ~(asked & r.grant), 0, `the output fires ${shown}, input ${asked}, grant ${r.grant & 15}`);
    assert.deepEqual([r.out[0], r.out[1], r.out[2]], want);
  });
}

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

// Codex round 12: two adjacent 50 x 60 patches inside one 107 x 60 field toggle two rows of
// every five between black and white at 5 Hz in opposite phases. Each direction changes 1200
// pixels, under the 1605-pixel limit, but 2400 flash together.
test('opposite-phase patches count as one combined area (Codex round 12)', () => {
  const lim = model.createLimiter({ width: W, height: H });
  const input = createAuditor({ width: W, height: H }), audit = createAuditor({ width: W, height: H });
  const px = new Uint8Array(W * H * 4);
  for (let t = 0; t < 300; t++) {
    const on = Math.floor(t / 6) % 2 === 0;
    for (let y = 0, i = 0; y < H; y++) {
      for (let x = 0; x < W; x++, i += 4) {
        let v = 0;
        if (y >= 60 && y < 120 && y % 5 < 2 && x >= 100 && x < 200) v = (x < 150) === on ? 255 : 0;
        px[i] = px[i + 1] = px[i + 2] = v; px[i + 3] = 255;
      }
    }
    input.push(px, DT);
    audit.push(lim.step(px, DT).out, DT);
  }
  assert.ok(input.maxPerWindow('luma') >= 9, `the input shows ${input.maxPerWindow('luma')} luma per 1 s`);
  assert.ok(audit.maxPerWindow('luma') <= 6, `the output shows ${audit.maxPerWindow('luma')} luma per 1 s`);
});

// Codex round 12: a 7 x 7 red fall passes under the wcag limit (63 at 64 x 36); the geometry then
// changes to desktop (limit 42), so the still-recent fall is a large area no grant paid for. It is
// charged, and a rise of the same patch right after is held.
test('a geometry change that puts recent pixels over the limit spends the budget (Codex round 12)', () => {
  const w = 64, h = 36;
  const lim = model.createLimiter({ width: w, height: h });
  const audit = createAuditor({ width: w, height: h, field: GEOMETRY.desktop });
  const px = new Uint8Array(w * h * 4);
  let rise = null;
  for (let t = 0; t < 150; t++) {
    const patch = t === 100 || t === 101;
    for (let y = 0, i = 0; y < h; y++) {
      for (let x = 0; x < w; x++, i += 4) {
        const red = t > 0 && !(patch && x < 7 && y < 7);
        px[i] = red ? 160 : 0; px[i + 1] = px[i + 2] = 0; px[i + 3] = 255;
      }
    }
    if (t === 101) lim.setGeometry('desktop');
    const r = lim.step(px, DT);
    if (t === 102) rise = r;
    audit.push(r.out, DT);
  }
  assert.equal(rise.stats.admitted[2], false, 'the rise after the change is admitted');
  assert.ok(audit.maxPerWindow('red') <= 1, `red ${audit.maxPerWindow('red')} per 1 s`);
});

/**
 * Runs a scene of `colour(t, x, y)` through the model at w x h; returns the auditors of the input
 * and output and the last output frame. `dt(t)` gives each frame's interval in seconds.
 */
function scene(w, h, frames, colour, { dt = () => DT, field, before, maxFlashHz } = {}) {
  const lim = model.createLimiter({ width: w, height: h, maxFlashHz });
  const input = createAuditor({ width: w, height: h, field }), audit = createAuditor({ width: w, height: h, field });
  const px = new Uint8Array(w * h * 4);
  let out = null;
  for (let t = 0; t < frames; t++) {
    for (let y = 0, i = 0; y < h; y++) {
      for (let x = 0; x < w; x++, i += 4) {
        const c = colour(t, x, y);
        px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
      }
    }
    before?.(t, lim, input, audit);
    input.push(px, dt(t));
    out = lim.step(px, dt(t)).out;
    audit.push(out, dt(t));
  }
  return { input, audit, out };
}
const phase = (keys, t) => keys.findLast(([from]) => t >= from)[1];

// Codex round 13: a fall to a red code of 0 kept its direction only in the auditor; the packed
// tracker read (0, 0) back as no direction and missed the rise and fall after it.
test('a fall to red code 0 keeps its direction (Codex round 13)', () => {
  const seq = [[0, [0, 0, 0]], [1, [80, 0, 0]], [91, [0, 0, 0]], [181, [110, 60, 0]], [182, [45, 0, 0]],
    [183, [110, 0, 0]], [184, [0, 0, 0]]];
  const { input, audit } = scene(64, 36, 260, t => phase(seq, t));
  assert.ok(input.maxPerWindow('red') >= 2, `the input shows ${input.maxPerWindow('red')} red per 1 s`);
  assert.ok(audit.maxPerWindow('red') <= 1, `the output shows ${audit.maxPerWindow('red')} red per 1 s`);
});

// Codex round 13: an unsaturated rise left the gated tracker falling, so the saturated fall after
// it was skipped by both the auditor and the limiter.
test('an unsaturated reversal does not hide the red flash after it (Codex round 13)', () => {
  const seq = [[0, [110, 0, 0]], [1, [65, 40, 0]], [91, [110, 60, 0]], [92, [45, 0, 0]], [93, [110, 60, 0]]];
  const { input, audit } = scene(64, 36, 180, t => phase(seq, t));
  assert.ok(input.maxPerWindow('red') >= 2, `the input shows ${input.maxPerWindow('red')} red per 1 s`);
  assert.ok(audit.maxPerWindow('red') <= 1, `the output shows ${audit.maxPerWindow('red')} red per 1 s`);
});

// Codex round 13: adjacent 5 x 8 luma and red patches in one 21 x 12 field (limit 63) flash 80
// pixels together, each channel under the limit.
test('adjacent luma and red patches count as one combined area (Codex round 13)', () => {
  const { input, audit } = scene(64, 36, 180, (t, x, y) => {
    const on = Math.floor(t / 3) % 2 === 1;
    if (!on || y < 10 || y >= 18 || x < 20 || x >= 30) return [0, 0, 0];
    return x < 25 ? [180, 180, 180] : [100, 0, 0];
  });
  assert.ok(input.maxPerWindow('red') >= 2, `the input shows ${input.maxPerWindow('red')} red per 1 s`);
  assert.ok(audit.maxPerWindow('luma') <= 6, `the output shows ${audit.maxPerWindow('luma')} luma per 1 s`);
  assert.ok(audit.maxPerWindow('red') <= 1, `the output shows ${audit.maxPerWindow('red')} red per 1 s`);
});

// Codex round 13: colour pairs just over WCAG's thresholds whose rounded codes differ by exactly
// the old steps.
for (const [name, a, b, channel, most] of [
  ['luma 0.100001', [40, 18, 42], [68, 76, 210], 'luma', 6],
  ['red 20.006', [63, 37, 46], [78, 4, 23], 'red', 1],
]) {
  test(`a full-frame 10 Hz strobe just over the ${name} threshold is limited (Codex round 13)`, () => {
    const { input, audit } = scene(64, 36, 180, t => (Math.floor(t / 3) % 2 ? b : a));
    assert.ok(input.maxPerWindow(channel) > most, `the input shows ${input.maxPerWindow(channel)} ${channel} per 1 s`);
    assert.ok(audit.maxPerWindow(channel) <= most, `the output shows ${audit.maxPerWindow(channel)} ${channel} per 1 s`);
  });
}

// Codex round 13: at 120 Hz a pixel that needs both budgets froze while luma and red grants never
// coincided; the joint grant admits both together.
test('a change needing both budgets reaches the output (Codex round 13)', () => {
  const seq = [[0, [0, 0, 0]], [1, [100, 0, 0]], [2, [255, 0, 0]], [3, [0, 0, 0]]];
  const { audit, out } = scene(64, 36, 480, t => phase(seq, t), { dt: () => 1 / 120 });
  assert.ok(out.every((v, i) => i % 4 === 3 || v === 0), 'the output never reached black in 4 s');
  assert.ok(audit.maxPerWindow('red') <= 1, `the output shows ${audit.maxPerWindow('red')} red per 1 s`);
});

// Codex round 13: the auditor's window is measured in time, so two red transitions 700 ms apart
// at a variable cadence are in one second.
test('the auditor counts its window in time, not frames (Codex round 13)', () => {
  const seq = [[0, [0, 0, 0]], [1, [160, 0, 0]], [62, [0, 0, 0]]];
  const { input } = scene(64, 36, 80, t => phase(seq, t), { dt: t => (t === 30 ? 0.2 : 1 / 120) });
  assert.equal(input.maxPerWindow('red'), 2);
});

// Codex round 13: a 7 x 7 fall shown 0.5 s after a full-frame rise, under the wcag limit; the
// geometry then changes to desktop. The fall was judged in the field shown when it happened, and
// the limiter holds what follows.
test('a geometry change after a small fall stays within the red budget (Codex round 13)', () => {
  const { audit } = scene(64, 36, 150, (t, x, y) => {
    const red = t > 0 && !((t === 30 || t === 31) && x < 7 && y < 7);
    return red ? [160, 0, 0] : [0, 0, 0];
  }, { before: (t, lim, input, out) => { if (t === 31) { lim.setGeometry('desktop'); input.setGeometry(GEOMETRY.desktop); out.setGeometry(GEOMETRY.desktop); } } });
  assert.ok(audit.maxPerWindow('red') <= 1, `red ${audit.maxPerWindow('red')} per 1 s`);
});

// Codex round 14: red stripes and luma stripes a frame apart, each under the area limit and over
// it together. Red changing alone is under the limit and passes; the luma frame after was over and
// asked only luma, so the combined flash never spent the red budget.
test('red a frame ahead of luma is charged to the red budget (Codex round 14)', () => {
  // Each channel alone covers an eighth of the field, under the limit; together a quarter, over it.
  const { input, audit } = scene(64, 36, 240, (t, x, y) => {
    const red = Math.floor(t / 6) % 2 === 1, luma = Math.floor((t - 1) / 6) % 2 === 1;
    const k = (x + 2 * y) % 8;
    if (k === 4) return luma ? [180, 180, 180] : [0, 0, 0];
    if (k === 0) return red ? [160, 0, 0] : [0, 0, 0];
    return [0, 0, 0];
  });
  assert.ok(input.maxPerWindow('red') >= 2, `the input shows ${input.maxPerWindow('red')} red per 1 s`);
  assert.ok(audit.maxPerWindow('red') <= 1, `the output shows ${audit.maxPerWindow('red')} red per 1 s`);
  assert.ok(audit.maxPerWindow('luma') <= 6, `the output shows ${audit.maxPerWindow('luma')} luma per 1 s`);
});

// Codex round 14: a rise, a plateau, a further rise and a fall still flash at most once a second
// through the red budget (each step of the threshold is a transition since Codex round 16).
test('a red staircase rise and fall is rationed through the red budget (Codex rounds 14, 15)', () => {
  const seq = [[0, [0, 0, 0]], [1, [110, 0, 0]], [9, [220, 0, 0]], [17, [0, 0, 0]]];
  const { input, audit } = scene(64, 36, 240, t => phase(seq, t % 24));
  assert.ok(input.maxPerWindow('red') >= 6, `the input shows ${input.maxPerWindow('red')} red per 1 s`);
  assert.ok(audit.maxPerWindow('red') <= 1, `the output shows ${audit.maxPerWindow('red')} red per 1 s`);
});

// Codex round 14: the auditor's combined area recorded a transition on a frame where nothing
// changed. One combined change counts once per channel.
test('one combined change counts once per channel (Codex round 14)', () => {
  const { input } = scene(64, 36, 30, (t, x) => {
    if (t < 1) return [0, 0, 0];
    return x % 5 === 0 ? [180, 180, 180] : x % 5 === 2 ? [160, 0, 0] : [0, 0, 0];
  });
  assert.equal(input.transitions.reduce((n, k) => n + k.length, 0), 2);
  assert.equal(input.maxPerWindow('luma'), 1);
  assert.equal(input.maxPerWindow('red'), 1);
});

// Codex round 15: a large luma rise in one field hid a combined red-and-luma area in another.
test('a large area elsewhere does not hide a combined area (Codex round 15)', () => {
  const auditor = createAuditor({ width: 64, height: 36 });
  const px = new Uint8Array(64 * 36 * 4);
  const paint = on => {
    for (let y = 0, i = 0; y < 36; y++) {
      for (let x = 0; x < 64; x++, i += 4) {
        const c = !on ? [0, 0, 0] : y < 8 && x < 5 ? [160, 0, 0] : y < 8 && x < 10 ? [180, 180, 180]
          : x >= 40 ? [180, 180, 180] : [0, 0, 0];
        px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
      }
    }
  };
  paint(false); auditor.push(px, DT);
  paint(true); auditor.push(px, DT);
  assert.equal(auditor.maxPerWindow('red'), 1);
  assert.equal(auditor.maxPerWindow('luma'), 1);
});

// Codex round 14: at a tiny maxFlashHz the luma refill was under 8 and the red refill floored to 0,
// so red froze forever after one grant.
test('red refills at a tiny maxFlashHz (Codex round 14)', () => {
  const lim = model.createLimiter({ width: 64, height: 36, maxFlashHz: 0.003 });
  const px = new Uint8Array(64 * 36 * 4);
  lim.step(px, DT);
  for (let i = 0; i < px.length; i += 4) { px[i] = 160; px[i + 3] = 255; }
  const granted = lim.step(px, DT);
  assert.equal(granted.redDeficit, model.TOKEN, 'the first red change spends the red budget');
  assert.ok(lim.step(px, DT).redDeficit < model.TOKEN, 'the red budget never refills');
});

// Codex round 15: at 480 Hz the same rate earns under one unit a frame, and flooring each frame
// discarded it; the clock carries the fraction.
test('the refill carries its fraction at a high frame rate (Codex round 15)', () => {
  const lim = model.createLimiter({ width: 64, height: 36, maxFlashHz: 0.003 });
  const px = new Uint8Array(64 * 36 * 4), dt = 1 / 480;
  lim.step(px, dt);
  for (let i = 0; i < px.length; i += 4) { px[i] = 160; px[i + 3] = 255; }
  assert.equal(lim.step(px, dt).redDeficit, model.TOKEN, 'the first red change spends the red budget');
  // Under one luma unit a step, so red (an eighth of the rate) carries its remainder for ~10 steps.
  let deficit = model.TOKEN;
  for (let f = 0; f < 40; f++) deficit = lim.step(px, dt).redDeficit;
  assert.ok(deficit < model.TOKEN, 'the red budget never refills at 480 Hz');
});

// Codex round 16: adjacent 4 x 10 patches A and B (80 pixels, over the 63-pixel limit together,
// 40 each) step up a frame apart and then rise and fall together. Trackers that counted one
// transition per direction fired on the staggered half-patches and let the joint 100-170 rise and
// 140-0 fall through. An onward step of the threshold from the last transition counts again.
for (const [name, paint] of [['grey', v => [v, v, v]], ['red', v => [v, 0, 0]]]) {
  test(`staggered ${name} patches rising and falling together are limited (Codex round 16)`, () => {
    const level = (t, b) => {
      if (t === 0) return 0;
      const k = ((t - 1) % 16) + 1;
      if (k === 16) return 0;
      if (b) return k < 7 ? 0 : k < 8 ? 100 : k < 9 ? 170 : 140;
      return k < 8 ? 100 : k < 15 ? 170 : 140;
    };
    const { input, audit } = scene(64, 36, 240, (t, x, y) => {
      if (y < 10 || y >= 20 || x < 20 || x >= 28) return [0, 0, 0];
      return paint(level(t, x >= 24));
    });
    const channel = name === 'red' ? 'red' : 'luma', most = name === 'red' ? 1 : 6;
    assert.ok(input.maxPerWindow(channel) > most, `the input shows ${input.maxPerWindow(channel)} ${channel} per 1 s`);
    assert.ok(audit.maxPerWindow(channel) <= most, `the output shows ${audit.maxPerWindow(channel)} ${channel} per 1 s`);
  });
}

// Codex round 16: a luma charge in the right-hand field cleared the red evidence of every field,
// so 40 + 40 red rises a frame apart in the left field (80, over its limit of 63) went uncounted.
test('a luma charge elsewhere keeps pending red evidence (Codex round 16)', () => {
  const { input } = scene(64, 36, 30, (t, x, y) => {
    if (y >= 10) return [0, 0, 0];
    const red1 = t >= 1 && t < 11, red2 = t >= 2 && t < 12, white = t >= 1 && t < 11;
    if (x < 4) return red1 ? [160, 0, 0] : [0, 0, 0];
    if (x < 8) return red2 ? [160, 0, 0] : [0, 0, 0];
    if (x >= 56) return white ? [255, 255, 255] : [0, 0, 0];
    return [0, 0, 0];
  });
  assert.equal(input.maxPerWindow('red'), 2);
});

// Codex round 16: half a refill unit carried from a 1/60 s first step rounded every later refill up
// to a token, admitting seven full-frame luma transitions in 999.9991 ms. The clock earns
// TOKEN - 1 units a token period, so a carry of under one unit cannot finish a token early.
test('the carried fraction cannot finish a token early (Codex round 16)', () => {
  const gap = 1 / 6 - 0.00000015;
  const { audit } = scene(64, 36, 16, t => (t % 2 === 1 ? WHITE : BLACK), { dt: t => (t < 2 ? 1 / 60 : gap) });
  assert.ok(audit.maxPerWindow('luma') <= 6, `the output shows ${audit.maxPerWindow('luma')} luma per 1 s`);
});

// Codex round 16: at 10 us a step the red refill rounded up to one unit a step and the red token
// returned in 650 ms. Red now carries its remainder exactly.
test('red refills at an eighth of the rate at a tiny frame interval (Codex round 16)', () => {
  const lim = model.createLimiter({ width: 64, height: 36 });
  const px = new Uint8Array(64 * 36 * 4), dt = 0.00001;
  lim.step(px, dt);
  for (let i = 0; i < px.length; i += 4) { px[i] = 160; px[i + 3] = 255; }
  assert.equal(lim.step(px, dt).redDeficit, model.TOKEN, 'the red change spends the red budget');
  // 0.33 s earns about 0.33 of a red token; rounding each step up had returned half of it.
  let deficit = 0;
  for (let f = 0; f < 33000; f++) deficit = lim.step(px, dt).redDeficit;
  assert.ok(deficit > 0.6 * model.TOKEN, `the red budget refilled to ${deficit} in 0.33 s`);
});

// Codex round 17: after 100 frames of red byte 138 (code 65), a dip to 127 (code 54, under a step)
// and a rise to 146 (code 73) left the reference at 65, so the rise and the fall after it both
// passed. The reference now follows a dip short of a step.
test('a rise from a dip short of a step is a transition (Codex round 17)', () => {
  const seq = [[0, [0, 0, 0]], [1, [138, 0, 0]], [101, [127, 0, 0]], [102, [146, 0, 0]], [103, [127, 0, 0]]];
  const { input, audit } = scene(64, 36, 200, t => phase(seq, t));
  assert.ok(input.maxPerWindow('red') >= 2, `the input shows ${input.maxPerWindow('red')} red per 1 s`);
  assert.ok(audit.maxPerWindow('red') <= 1, `the output shows ${audit.maxPerWindow('red')} red per 1 s`);
});

// Codex round 17: an 80-pixel red rise on the right cleared every red timestamp, so 40 falls on the
// left and 40 more a frame later (80 in one field, over its limit of 63) went uncounted.
test('a charge in one field keeps the other field\'s evidence (Codex round 17)', () => {
  const { input } = scene(64, 36, 30, (t, x, y) => {
    if (y >= 8) return [0, 0, 0];
    if (x >= 50 && x < 60) return t >= 1 ? [160, 0, 0] : [0, 0, 0];
    if (x < 5) return t < 1 ? [160, 0, 0] : [0, 0, 0];
    if (x < 10) return t < 2 ? [160, 0, 0] : [0, 0, 0];
    return [0, 0, 0];
  });
  assert.equal(input.transitions[2].length, 1, 'the rise');
  assert.equal(input.transitions[3].length, 1, 'the fall');
});

// Codex round 18: a fall from grey 255 to 240 stayed above 0.8, and the tracker dropped its high
// side, so 255 -> 240 -> 255 -> 229 (a fall of 0.22 ending below 0.8) went uncounted.
test('a fall that ends below 0.8 after one above it is a transition (Codex round 18)', () => {
  const seq = [[0, [255, 255, 255]], [1, [240, 240, 240]], [2, [255, 255, 255]], [3, [229, 229, 229]]];
  const { input } = scene(64, 36, 10, t => phase(seq, t));
  assert.equal(input.transitions[1].length, 1, 'the fall to 229');
});

// Codex round 18: a recorded red rise consumed the combined cover in both directions, erasing 40
// pending falls in the same field, so 40 more a frame later (80, over 63) went uncounted.
test('a directional charge keeps the opposite direction\'s evidence in its field (Codex round 18)', () => {
  const { input } = scene(64, 36, 30, (t, x, y) => {
    if (y >= 8) return [0, 0, 0];
    if (x < 10) return t >= 1 ? [160, 0, 0] : [0, 0, 0];
    if (x < 15) return t < 1 ? [160, 0, 0] : [0, 0, 0];
    if (x < 20) return t < 2 ? [160, 0, 0] : [0, 0, 0];
    return [0, 0, 0];
  });
  assert.equal(input.transitions[2].length, 1, 'the rise');
  assert.equal(input.transitions[3].length, 1, 'the fall');
});

// Codex round 18: after a display-scale reset (trackers zeroed, G spent) the viewer still remembered
// a saturated (60, 0, 0) under the black, so an unsaturated (110, 64, 0) rise and the fall to
// (60, 0, 0) were two red transitions while the zero tracker charged only the fall. The zero texel
// has now seen a saturated state.
test('after a reset the next red change counts (Codex round 18)', () => {
  const W = 64, H = 36, frames = 420;
  const lim = model.createLimiter({ width: W, height: H });
  const audit = createAuditor({ width: W, height: H });
  const px = new Uint8Array(W * H * 4);
  let r = null;
  for (let t = 0; t < frames; t++) {
    const c = t < 60 ? [60, 0, 0] : t < 300 ? [0, 0, 0] : t === 300 ? [110, 64, 0] : [60, 0, 0];
    for (let i = 0; i < px.length; i += 4) { px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255; }
    if (t === 120) { r.track.fill(0); lim.setGeometry(GEOMETRY.wcag); }
    r = lim.step(px, DT);
    audit.push(r.out, DT);
  }
  assert.ok(audit.maxPerWindow('red') <= 1, `the output shows ${audit.maxPerWindow('red')} red per 1 s`);
});

// Codex round 19: from the zero tracker, an unsaturated (110, 64, 0) rise spent the red token and
// the tracker forgot it had not seen saturation, so a later (90, 0, 0) on the same red code (the
// auditor's rise) and the fall to black came 16.7 ms apart. The zero texel's red memory is unknown:
// the change counts at once and again at the first saturated state.
test('a red rise from the zero tracker counts again when it saturates (Codex round 19)', () => {
  const W = 64, H = 36, frames = 300;
  const lim = model.createLimiter({ width: W, height: H });
  const audit = createAuditor({ width: W, height: H });
  const px = new Uint8Array(W * H * 4);
  for (let t = 0; t < frames; t++) {
    const c = t < 1 ? [0, 0, 0] : t < 101 ? [110, 64, 0] : t === 101 ? [90, 0, 0] : [0, 0, 0];
    for (let i = 0; i < px.length; i += 4) { px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255; }
    const r = lim.step(px, DT);
    if (t === 0) r.track.fill(0); // the host's start: every pixel tracked black
    audit.push(r.out, DT);
  }
  assert.ok(audit.maxPerWindow('red') <= 1, `the output shows ${audit.maxPerWindow('red')} red per 1 s`);
});

// Codex round 19: a recorded directional red rise left another field's combined area (40 falls
// and 40 rises) unconsumed, and the auditor charged it again on the next, unchanged frame.
test('an unchanged frame makes no transition (Codex round 19)', () => {
  const { input } = scene(64, 36, 30, (t, x, y) => {
    if (x < 8 && y < 8) return t >= 2 ? [160, 0, 0] : [0, 0, 0];
    if (x >= 50 && x < 60 && y < 4) return t < 1 ? [160, 0, 0] : [0, 0, 0];
    if (x >= 50 && x < 60 && y < 8) return t >= 2 ? [160, 0, 0] : [0, 0, 0];
    return [0, 0, 0];
  });
  const red = input.transitions[2].length + input.transitions[3].length + input.transitions[5].length;
  assert.equal(red, 1, `the auditor records ${red} red transitions`);
});

// Codex round 20: a frame shown no time after the last fires nothing in the red area its
// predecessor raised; a grey pixel far away must not make that area fire again by sharing its stamp.
test('a zero-interval frame does not refire the last frame\'s area (Codex round 20)', () => {
  const { input } = scene(64, 36, 4, (t, x, y) => {
    if (t === 3 && x === 0 && y === 35) return [128, 128, 128];
    if (x < 8 && y < 8) return t >= 2 ? [160, 0, 0] : [0, 0, 0];
    if (x >= 50 && x < 60 && y < 4) return t < 1 ? [160, 0, 0] : [0, 0, 0];
    if (x >= 50 && x < 60 && y < 8) return t >= 2 ? [160, 0, 0] : [0, 0, 0];
    return [0, 0, 0];
  }, { dt: t => (t === 3 ? 0 : DT) });
  const red = input.transitions[2].length + input.transitions[3].length + input.transitions[5].length;
  assert.equal(red, 1, `the auditor records ${red} red transitions`);
});

// Codex round 19: a tracker started at grey 255 falls to 240 and on to 229, a fall of 7093 codes
// from the peak ending below 0.8.
test('a bright fall that goes on below 0.8 fires (Codex round 19)', () => {
  const { input } = scene(64, 36, 4, t => { const g = [255, 240, 229, 229][t]; return [g, g, g]; });
  assert.equal(input.transitions[1].length, 1, 'the fall');
});

// limiter-red-expire-black (CORE-2869): owed red changes expire only at a host restart after
// 1250 ms of exact black. The host seeds "black, nothing owed" when hostBlackLongEnough holds and
// zero otherwise, and tells the auditor which seed it wrote; nothing expires during playback. The
// cases are the conformance vectors' (limiter-vectors.mjs); `seed`, `runs` and `at` override them.
// One input and one output auditor watch across the restart, as a viewer does; `restart: false`
// keeps them from being told, the never-restarted auditor of the design's section 6.
function runReset(name, { seed, runs, at, restart = true } = {}) {
  const c = VECTOR_CASES.find(k => k.name === name);
  const signal = runs ? { kind: 'runs', runs } : c.signal;
  const reset = { at: at ?? c.reset.at, seed: seed ?? c.reset.seed };
  const { width: w, height: h } = c;
  let lim = model.createLimiter({ width: w, height: h });
  const input = createAuditor({ width: w, height: h }), output = createAuditor({ width: w, height: h });
  const px = new Uint8Array(w * h * 4), held = [];
  for (let t = 0; t < c.frames; t++) {
    if (t === reset.at) {
      lim = model.createLimiter({ width: w, height: h, start: reset.seed });
      if (restart) { input.restart(reset.seed); output.restart(reset.seed); }
    }
    renderSignal(signal, t, w, h, px);
    const r = lim.step(px, DT);
    held.push(r.held);
    input.push(px, DT);
    output.push(r.out, DT);
  }
  return { input, output, held, n: w * h };
}
const redCount = a => a.transitions[2].length + a.transitions[3].length + a.transitions[5].length;
const ORANGE = [110, 64, 0], FAINT_RED = [5, 0, 0], NEAR_RED = [1, 0, 0], RED = [255, 0, 0];
/** An auditor alone over full frames of `runs` ([n, colour] pairs), told of a restart at `at`. */
function auditRuns(runs, { at, seed = 'black', restart = true, w = 64, h = 36 } = {}) {
  const a = createAuditor({ width: w, height: h });
  const px = new Uint8Array(w * h * 4), signal = { kind: 'runs', runs };
  const frames = runs.reduce((n, [k]) => n + k, 0);
  for (let t = 0; t < frames; t++) {
    if (restart && t === at) a.restart(seed);
    renderSignal(signal, t, w, h, px);
    a.push(px, DT);
  }
  return a;
}

test('the start texels and the shared black thresholds (CORE-2869)', () => {
  assert.deepEqual(model.startTexel('untracked'), [0, 8192, 0, 0]);
  assert.deepEqual(model.startTexel('zero'), [0, 0, 0, 0]);
  assert.deepEqual(model.startTexel('black'), [0, 32768, 2147508224, 0]);
  assert.deepEqual(model.BLACK_TEXEL, [0, 32768, 2147508224, 0]);
  assert.equal(model.RED_EXPIRE_MS, 1250);
  assert.throws(() => model.startTexel('grey'));
  // The auditor's clock: 75 intervals of 1000/60 ms accumulated from 1234 ms are 1250 ms.
  const from = 1234, clock = k => { let c = from; for (let i = 0; i < k; i++) c += 1000 / 60; return c; };
  assert.equal(model.blackLongEnough(clock(75) - from), true, '75 intervals');
  assert.equal(model.blackLongEnough(clock(74) - from), false, '74 intervals');
  // The host's credit gives up one frame: 76 intervals, not 75.
  const credit = k => { let c = 0; for (let i = 0; i < k; i++) c += Math.min(1000 / 60, 100); return c; };
  assert.equal(model.hostBlackLongEnough(credit(75), 1000 / 60), false, '75 credited intervals');
  assert.equal(model.hostBlackLongEnough(credit(76), 1000 / 60), true, '76 credited intervals');
  assert.throws(() => createAuditor({ width: 8, height: 8 }).restart('grey'));
});

test('a restart after a short black starts at zero and holds the red after it (CORE-2869, Codex repro)', () => {
  const { input, output, held, n } = runReset('reset-short-black');
  assert.ok(held[309] > 0, 'the full red at 309 was admitted');
  assert.ok(output.maxPerWindow('red') <= 1, `red ${output.maxPerWindow('red')} per 1 s`);
  assert.equal(input.maxPerWindow('red'), 2, 'the input makes two red transitions a second');
  assert.deepEqual(output.lastRestart, { seed: 'zero', reseeded: 0, kept: n });
});

// Codex code round 1 P1: the constructor itself writes G fully spent for a host seed, as
// setGeometry does. Full red, black requested until the output is exact black, eight more black
// frames, a restart and full red: an unspent grant admitted the red, a fall and a rise in 150 ms.
test('a host start writes the grant fully spent, so a red after a short black is held (CORE-2869)', () => {
  const w = 64, h = 36, n = w * h;
  const solid = c => { const px = new Uint8Array(n * 4); renderSignal({ kind: 'runs', runs: [[1, c]] }, 0, w, h, px); return px; };
  const isBlack = px => px.every((v, i) => i % 4 === 3 || v === 0);
  const red = solid(RED), black = solid(BLACK), spent = model.createLimiter({ width: w, height: h });
  spent.setGeometry('wcag');
  const spentState = spent.step(black, DT).state;
  for (const seed of ['zero', 'black']) {
    assert.deepEqual(model.createLimiter({ width: w, height: h, start: seed }).step(black, DT).state, spentState, `${seed} start state`);
    let lim = model.createLimiter({ width: w, height: h });
    const output = createAuditor({ width: w, height: h });
    const show = (px, held) => { const r = lim.step(px, DT); output.push(r.out, DT); if (held) held.push(r.held); return r; };
    for (let t = 0; t < 120; t++) show(red);
    let fade = 0;
    while (!isBlack(show(black).out)) if (++fade > 600) assert.fail('the output never reached black');
    for (let t = 0; t < 8; t++) show(black);
    lim = model.createLimiter({ width: w, height: h, start: seed });
    output.restart(seed);
    const held = [];
    for (let t = 0; t < 120; t++) show(red, held);
    assert.ok(held[0] > 0, `${seed}: the full red after the restart was admitted at once`);
    assert.ok(output.maxPerWindow('red') <= 1, `${seed}: red ${output.maxPerWindow('red')} per 1 s`);
    assert.equal(output.lastRestart.reseeded, 0, `${seed}: a short black reseeds nothing`);
  }
});

test('a black restart after 90 frames of black admits one red at once (CORE-2869)', () => {
  const { output, held, n } = runReset('reset-long-black');
  assert.equal(held.filter(x => x > 0).length, 0, 'held frames');
  assert.equal(redCount(output), 1, 'red transitions');
  assert.deepEqual(output.lastRestart, { seed: 'black', reseeded: n, kept: 0 });
  // Started at zero the faint red counts and the full red after it is held: the trickle.
  assert.ok(runReset('reset-long-black', { seed: 'zero' }).held[391] > 0, 'a zero start admitted the full red');
  // The never-restarted auditor charges the pair that straddles the black hold (section 6).
  assert.equal(redCount(runReset('reset-long-black', { restart: false }).output), 2, 'never restarted');
});

test('a black restart reseeds at 75 frames of black and not at 74 (CORE-2869)', () => {
  const at75 = runReset('reset-black-at-expiry');
  assert.deepEqual(at75.input.lastRestart, { seed: 'black', reseeded: at75.n, kept: 0 });
  assert.equal(redCount(at75.input), 1, 'red transitions in the input after 75 frames');
  assert.ok(at75.output.maxPerWindow('red') <= 1, `red ${at75.output.maxPerWindow('red')} per 1 s`);
  // Black 200..273, 1233 ms. A host keeping the contract starts at zero, and the red is held.
  const short = [[100, BLACK], [100, ORANGE], [74, BLACK], [1, FAINT_RED], [1, RED]];
  const zero = runReset('reset-black-at-expiry', { runs: short, at: 274, seed: 'zero' });
  assert.equal(zero.input.maxPerWindow('red'), 2, 'red a second in the input a frame short');
  assert.ok(zero.output.maxPerWindow('red') <= 1, `red ${zero.output.maxPerWindow('red')} per 1 s at zero`);
  assert.ok(zero.held[275] > 0, 'the full red at 275 was admitted at zero');
  // A host that seeds black a frame short breaks the contract: the auditor keeps every pixel's
  // history and reports it, and still counts the fall at (5, 0, 0). G, written fully spent at
  // every start, holds the full red after it.
  const broken = runReset('reset-black-at-expiry', { runs: short, at: 274, seed: 'black' });
  assert.deepEqual(broken.input.lastRestart, { seed: 'black', reseeded: 0, kept: broken.n });
  assert.equal(broken.input.maxPerWindow('red'), 2, 'the auditor charges the input of the broken host');
  assert.ok(broken.held[275] > 0, 'the spent grant held the full red');
  assert.ok(broken.output.maxPerWindow('red') <= 1, `red ${broken.output.maxPerWindow('red')} per 1 s, broken host`);
});

test('the restart report follows the latest restart, of either seed (CORE-2869)', () => {
  const a = createAuditor({ width: 1, height: 1 });
  const black = new Uint8Array(4);
  for (let t = 0; t < 90; t++) a.push(black, DT);
  a.restart('black');
  assert.deepEqual(a.lastRestart, { seed: 'black', reseeded: 0, kept: 0 }, 'before its first frame');
  a.push(black, DT);
  assert.deepEqual(a.lastRestart, { seed: 'black', reseeded: 1, kept: 0 });
  for (let t = 0; t < 120; t++) a.push(black, DT);
  a.restart('zero');
  a.push(black, DT);
  assert.deepEqual(a.lastRestart, { seed: 'zero', reseeded: 0, kept: 1 });
  // A zero restart after 2 s of black reseeds nothing: a red transition still counts at (5, 0, 0).
  // The zero seed's unknown chromaticity boxes make it a rise (the merged direction), as the limiter
  // fires from the zero texel (CORE-2935).
  const z = auditRuns([[1, BLACK], [100, ORANGE], [120, BLACK], [1, FAINT_RED]], { at: 221, seed: 'zero' });
  assert.deepEqual([z.transitions[2], z.transitions[3]], [[221], []], 'the red transition counted at (5, 0, 0)');
  assert.equal(model.texelFires(0, 0, 0, 0, ...FAINT_RED, 0, 0, 0), 4, 'the limiter rises there from the zero texel');
});

test('nothing expires during playback (CORE-2869)', () => {
  const a = auditRuns([[1, BLACK], [100, ORANGE], [120, BLACK], [1, FAINT_RED]], { restart: false });
  assert.equal(a.transitions[3].length, 1, 'the fall counted at (5, 0, 0) after 2 s of black');
});

test('(1, 0, 0) and (5, 0, 0) end a black run (CORE-2869)', () => {
  for (const c of [NEAR_RED, FAINT_RED]) {
    const a = auditRuns([[100, BLACK], [1, c], [74, BLACK], [1, BLACK]], { at: 175 });
    assert.deepEqual(a.lastRestart, { seed: 'black', reseeded: 0, kept: 64 * 36 }, `after ${c}`);
    const b = auditRuns([[100, BLACK], [1, c], [75, BLACK], [1, BLACK]], { at: 176 });
    assert.equal(b.lastRestart.reseeded, 64 * 36, `75 frames after ${c}`);
  }
});

test('a red strobe after a black start is still limited (CORE-2869)', () => {
  const { output, held } = runReset('black-start-red-10hz');
  assert.ok(held.some(x => x > 0), 'nothing was held');
  assert.ok(output.maxPerWindow('red') <= 1, `red ${output.maxPerWindow('red')} per 1 s`);
});

// Design round 3 P1 #1 and #2 after one black start, with no later restart: a saturated (60, 0, 0)
// under an orange rise, and a faint or near-black saturated red before one. Everything before the
// restart is black, so the auditor told of it decides as one that is not.
for (const name of ['black-start-sat-orange', 'black-start-faint-red', 'black-start-near-black-red']) {
  test(`${name}: at most 1 red transition a second after a black start (CORE-2869)`, () => {
    const told = runReset(name), not = runReset(name, { restart: false });
    assert.ok(told.output.maxPerWindow('red') <= 1, `red ${told.output.maxPerWindow('red')} per 1 s`);
    assert.deepEqual(told.output.lastRestart, { seed: 'black', reseeded: told.n, kept: 0 });
    assert.deepEqual(told.input.transitions, not.input.transitions, 'the input audited with and without the restart');
    assert.deepEqual(told.output.transitions, not.output.transitions, 'the output audited with and without the restart');
    // The saturated witness stays counted: the input's red rise and fall (Codex code round 1 P2).
    const witness = { 'black-start-sat-orange': [[376], [477]], 'black-start-faint-red': [[200], [300]], 'black-start-near-black-red': [[200], [300]] }[name];
    assert.deepEqual([told.input.transitions[2], told.input.transitions[3]], witness, 'the input red rise and fall');
  });
}

// Section 6: the reseed drops only (step, saturated-state) pairs that straddle the hold.
test('the Codex design round 1 and 2 sequences drop only a straddling pair (CORE-2869)', () => {
  // Round 1: the uncounted orange fall before the hold, its witness (5, 0, 0) after it.
  const r1 = [[1, BLACK], [1, ORANGE], [75, BLACK], [100, BLACK], [1, FAINT_RED], [1, [128, 0, 0]]];
  // Restarted: the rise at 178 alone, the straddling fall at 177 dropped. Never restarted: both
  // (Codex code round 1 P1: frames and directions, not only the count).
  const red = a => [a.transitions[2], a.transitions[3], a.transitions[5]];
  assert.deepEqual(red(auditRuns(r1, { at: 77 })), [[178], [], []], 'round 1, restarted');
  assert.deepEqual(red(auditRuns(r1, { restart: false })), [[178], [177], []], 'round 1, never restarted');
  // Round 2: the witness (5, 0, 0) before the hold, the orange rise after it.
  const r2 = [[1, BLACK], [1, FAINT_RED], [75, BLACK], [1, BLACK], [1, ORANGE]];
  assert.deepEqual(red(auditRuns(r2, { at: 77 })), [[], [], []], 'round 2, restarted');
  assert.deepEqual(red(auditRuns(r2, { restart: false })), [[78], [], []], 'round 2, never restarted');
});

// limiter-red-uv-chromaticity (CORE-2935): red transitions by the WCAG 2.1/2.2 u'v' rule.
/** One vector case through the model, with input and output auditors told of its restart; `signal`
 * replaces the case's (one stripe alone); `track` keeps every frame's tracker and output. */
function runCase(name, { signal, keep } = {}) {
  const c = VECTOR_CASES.find(k => k.name === name);
  const w = c.width || W, h = c.height || H;
  let lim = model.createLimiter({ width: w, height: h });
  const input = createAuditor({ width: w, height: h }), output = createAuditor({ width: w, height: h });
  const px = new Uint8Array(w * h * 4), held = [], frames = [];
  for (let t = 0; t < c.frames; t++) {
    if (t === c.reset?.at) {
      lim = model.createLimiter({ width: w, height: h, start: c.reset.seed });
      input.restart(c.reset.seed); output.restart(c.reset.seed);
    }
    renderSignal(signal || c.signal, t, w, h, px);
    const r = lim.step(px, DT);
    held.push(r.held);
    input.push(px, DT);
    output.push(r.out, DT);
    if (keep) frames.push({ px: px.slice(), out: r.out.slice(), track: r.track.slice() });
  }
  return { input, output, held, frames, w, h, n: w * h };
}
const redIn = a => a.maxPerWindow('red');

for (const [name, least] of [['red-green-dim-10hz', 18], ['red-blue-10hz', 18], ['red-mask-10hz', 18], ['red-flash-5hz-half', 9], ['red-extremum', 3], ['red-early-band', 3], ['red-stagger', 2]]) {
  test(`u'v': ${name} shows >= ${least} red transitions a second in the input and <= 1 in the output`, () => {
    const { input, output } = runCase(name);
    assert.ok(redIn(input) >= least, `the input shows ${redIn(input)} red per 1 s`);
    assert.ok(redIn(output) <= 1, `the output shows ${redIn(output)} red per 1 s`);
  });
}

test(`u'v': dim red on black is no red transition and is never held`, () => {
  const { input, output, held } = runCase('red-black-dim-10hz');
  assert.equal(redCount(input) + redCount(output), 0);
  assert.equal(held.reduce((a, b) => a + b, 0), 0);
});

// Codex design round 1 (widened memory) P2-2: each stripe or patch alone is under the limiter
// window's limit, so only the two together hold; both stripes ask red down at frame 8 and not at
// the intermediate frames 1 and 7 (P1-a), both patches at frame 17 (P1-1, P1-2).
for (const [name, at, quiet] of [['red-stagger', 8, [1, 7]], ['red-extremum', 17, [1, 16]], ['red-early-band', 17, []]]) {
  test(`u'v': ${name} holds only both patches together, which ask red down at frame ${at}`, () => {
    const c = VECTOR_CASES.find(k => k.name === name);
    for (const band of c.signal.bands) {
      const { held } = runCase(name, { signal: { ...c.signal, bands: [band] } });
      assert.equal(held.reduce((a, b) => a + b, 0), 0, `one patch alone is held`);
    }
    const { frames, w, h } = runCase(name, { keep: true });
    const downs = t => {
      const { track } = frames[t - 1], hist = frames[t - 1].out, { px } = frames[t];
      const per = c.signal.bands.map(() => 0);
      for (let q = 0; q < w * h * 4; q += 4) {
        if (!(firesOn(track, q, px[q], px[q + 1], px[q + 2], hist) & 8)) continue;
        const x = (q / 4) % w, y = Math.floor(q / 4 / w);
        c.signal.bands.forEach((b, k) => { if (x >= Math.floor(b.rect[0] * w) && x < Math.floor(b.rect[2] * w) && y >= Math.floor(b.rect[1] * h) && y < Math.floor(b.rect[3] * h)) per[k]++; });
      }
      return per;
    };
    const area = c.signal.bands.map(b => (Math.floor(b.rect[2] * w) - Math.floor(b.rect[0] * w)) * (Math.floor(b.rect[3] * h) - Math.floor(b.rect[1] * h)));
    assert.deepEqual(downs(at), area, `frame ${at}: the patches' red-down pixels`);
    for (const t of quiet) assert.deepEqual(downs(t), area.map(() => 0), `frame ${t}: an intermediate state asks red down`);
  });
}

test(`u'v': a constant (1, 0, 0) after a zero start shows from the first red grant on (P1-b)`, () => {
  const { frames, held } = runCase('red-zero-constant', { keep: true });
  const first = held.findIndex((n, t) => t > 20 && n === 0);
  assert.ok(first > 20 && first < 120, `held until ${first}`);
  for (let t = first; t < frames.length; t++) {
    assert.equal(held[t], 0, `frame ${t} is held`);
    assert.ok(frames[t].out.every((v, i) => v === frames[t].px[i]), `frame ${t} is not the input`);
  }
});

test(`u'v': one red grant after a mixed history and a zero restart counts once (P2-1)`, () => {
  const { output } = runCase('red-zero-mixed');
  assert.ok(redIn(output) <= 1, `the output shows ${redIn(output)} red per 1 s`);
});

test(`u'v': saturated (60, 25, 0) and (60, 50, 0), 0.094 apart, are never held (P2-3)`, () => {
  const S1 = [60, 25, 0], C1 = [60, 50, 0];
  const runs = [[1, BLACK], [120, S1], ...Array.from({ length: 40 }, (_, i) => [3, i % 2 ? S1 : C1])];
  let lim = model.createLimiter({ width: 64, height: 36, start: 'black' });
  const px = new Uint8Array(64 * 36 * 4);
  let held = 0;
  for (let t = 0; t < 241; t++) {
    renderSignal({ kind: 'runs', runs }, t, 64, 36, px);
    held += lim.step(px, DT).held;
  }
  assert.equal(held, 0);
});

test(`u'v': black keeps the chromaticity memory`, () => {
  const a = auditRuns([[1, RED], [90, BLACK], [1, [0, 255, 0]]], { restart: false });
  assert.deepEqual([a.transitions[2], a.transitions[3]], [[], [1, 91]]);
});

// An independent float reference for Codex design round 2 (design.md, section 13): per pixel, the
// exact saturated and non-saturated colours since the last fire in each direction; a colour fires
// up (+1) when saturated and over 0.2 in IEC 61966-2-1 u'v' from a stored non-saturated colour,
// down (-1) the other way, and a fire clears the colours it crossed from.
const uvLin = k => { const c = k / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
function uvFloat(rgb) {
  const [r, g, b] = rgb.map(uvLin), X = 0.4124 * r + 0.3576 * g + 0.1805 * b, Y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  const D = X + 15 * Y + 3 * (0.0193 * r + 0.1192 * g + 0.9505 * b);
  return [4 * X / D, 9 * Y / D];
}
function exactUv() {
  const sat = [], far = [];
  let prev = '0,0,0';
  return rgb => {
    const key = rgb.join(), was = prev;
    prev = key;
    if (key === was || key === '0,0,0') return 0;
    const [r, g, b] = rgb.map(uvLin), s = r >= 4 * (g + b), p = uvFloat(rgb), from = s ? far : sat;
    const fire = from.some(q => Math.hypot(q[0] - p[0], q[1] - p[1]) > 0.2);
    if (fire) from.length = 0;
    (s ? sat : far).push(p);
    return fire ? (s ? 1 : -1) : 0;
  };
}
// The reference's saturation test is inclusive: (4, 1, 0) has linear r = 4g exactly, which a ratio
// rounds below 0.8 (Codex design round 3), and agrees with the model's uvSat on every colour.
test(`u'v': the float reference counts the inclusive saturation boundary`, () => {
  const ref = exactUv();
  assert.deepEqual([ref([0, 0, 1]), ref([4, 1, 0])], [0, 1]);
  assert.ok(model.uvSat(4, 1, 0));
});

/** The most frames in any `perSecond` frames at which both patches' exact references fire the same
 * way within `within` frames of each other: their union is over the field's limit. */
function bothPatches(fires, within, perSecond) {
  const both = fires[0].filter(([t, f]) => fires[1].some(([u, g]) => g === f && Math.abs(u - t) < within)).map(([t]) => t);
  return Math.max(0, ...both.map(t => both.filter(u => u >= t && u < t + perSecond).length));
}

// Codex design round 2 P1-A: two adjacent 8 x 5 patches at 240 Hz whose earlier fires may not have
// been transitions; a clearing fire from a spent code dropped a live one, and both patches flashed
// four times in 0.967 s with nothing held. The fix keeps the box, clipped and uncertain.
test(`u'v': two patches after uncertain fires show at most one exact red flash a second (P1-A)`, () => {
  const w = 64, h = 36, dt = 1 / 240, lim = model.createLimiter({ width: w, height: h, start: 'black' });
  const output = createAuditor({ width: w, height: h });
  const keys = [[[0, [51, 18, 0]], [1, [12, 12, 24]], [2, [60, 6, 21]], [3, [36, 6, 42]], [31, [0, 0, 60]]],
    [[2, [60, 6, 18]], [29, [48, 9, 57]], [30, [18, 0, 3]], [31, [33, 60, 57]], [32, [45, 15, 3]]]];
  const cur = [BLACK, BLACK], refs = [exactUv(), exactUv()], fires = [[], []];
  const px = new Uint8Array(w * h * 4);
  for (let t = 0; t < 290; t++) {
    keys.forEach((k, i) => { for (const [o, c] of k) if (o === t % 58) cur[i] = c; });
    for (let y = 9; y < 14; y++) for (let x = 20; x < 36; x++) px.set([...cur[x < 28 ? 0 : 1], 255], 4 * (w * y + x));
    const r = lim.step(px, dt);
    output.push(r.out, dt);
    for (let i = 0; i < 2; i++) {
      const q = 4 * (9 * w + 20 + 8 * i), f = refs[i](Array.from(r.out.slice(q, q + 3)));
      if (f) fires[i].push([t, f]);
    }
  }
  assert.ok(bothPatches(fires, 16, 240) <= 2, `both patches cross together ${bothPatches(fires, 16, 240)} times in 1 s`);
  assert.ok(redIn(output) <= 1, `the output shows ${redIn(output)} red per 1 s`);
});

// The stored red-uncertain-box vector is the 60 Hz regression check for P1-A: the round 2 model
// differs from it at frame 1 in the trackers and frame 7 in the output (Codex design round 3). This
// test bounds the exact flashes of the output the model now makes.
test(`u'v': red-uncertain-box, P1-A at 60 Hz, shows at most one exact red flash a second`, () => {
  const { frames, output, w } = runCase('red-uncertain-box', { keep: true });
  const refs = [exactUv(), exactUv()], fires = [[], []];
  frames.forEach(({ out }, t) => [20, 28].forEach((x, i) => {
    const q = 4 * (9 * w + x), f = refs[i](Array.from(out.slice(q, q + 3)));
    if (f) fires[i].push([t, f]);
  }));
  assert.ok(bothPatches(fires, 4, 60) <= 2, `both patches cross together ${bothPatches(fires, 4, 60)} times in 1 s`);
  assert.ok(redIn(output) <= 1, `the output shows ${redIn(output)} red per 1 s`);
});

// Codex design round 2 P1-B: a zero restart that kept the auditor's boxes let them fire where the
// limiter's unknown boxes did not (20 auditor red transitions a second); now both start unknown.
test(`u'v': a zero restart after an orange and magenta history counts as the limiter does (P1-B)`, () => {
  const { output } = runCase('red-zero-retained');
  assert.ok(redIn(output) <= 1, `the output shows ${redIn(output)} red per 1 s`);
});

// Codex design round 3 P2: a zero restart before the auditor's first frame was overwritten by the
// first frame's known boxes, so the limiter's red fall from its unknown seed went uncounted.
test(`u'v': a zero restart before the first frame seeds the auditor's boxes unknown`, () => {
  const w = 64, h = 36, lim = model.createLimiter({ width: w, height: h, start: 'zero' });
  const a = createAuditor({ width: w, height: h }), px = new Uint8Array(w * h * 4);
  a.restart('zero');
  let fell = 0;
  for (let t = 0; t < 125; t++) {
    const c = t < 124 ? BLACK : [0, 0, 1];
    for (let j = 0; j < w * h; j++) px.set([...c, 255], 4 * j);
    const r = lim.step(px, DT);
    fell += r.stats.fired[3];
    a.push(r.out, DT);
  }
  assert.equal(fell, w * h, 'the limiter fell on every pixel at (0, 0, 1)');
  assert.deepEqual(a.transitions[3], [124], 'the auditor counts the fall on frame 124');
});

test(`u'v': a zero restart before a non-black first frame counts the limiter's fall there`, () => {
  const w = 64, h = 36, lim = model.createLimiter({ width: w, height: h, start: 'zero' });
  const a = createAuditor({ width: w, height: h }), px = new Uint8Array(w * h * 4);
  for (let j = 0; j < w * h; j++) px.set([0, 0, 1, 255], 4 * j);
  // The limiter asks for a red fall at every pixel from the zero texel; an output that showed this
  // frame must count that fall in the auditor too.
  assert.equal(lim.step(px, DT).stats.requests[3], w * h, 'the limiter asks to fall on every pixel');
  a.restart('zero');
  a.push(px, DT);
  assert.deepEqual(a.transitions[3], [0], 'the auditor counts the fall on frame 0');
});

test(`u'v': the 32-bit marker and the RGBA16UI clamp (P1-3)`, () => {
  const [x, y, z, w] = model.BLACK_TEXEL;
  assert.ok(model.texelValid(x, y, z, w) && model.texelValid(0, 0, 0, 0));
  // A clamped RGBA16UI write: every word 65535 or its low half.
  assert.ok(!model.texelValid(65535, 65535, 65535, 65535));
  assert.ok(!model.untracked(0, 65535, 0, 0), 'a clamped y reads as UNTRACKED');
  assert.equal(model.texelFires(65535, 65535, 65535, 65535, 255, 0, 0, 5, 0, 0), 15);
  assert.equal(model.texelFires(65535, 65535, 65535, 65535, 5, 0, 0, 5, 0, 0), 0);
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

// --grep <text> runs only the cases whose names contain it.
const grep = process.argv.indexOf('--grep');
const chosen = grep > 0 ? cases.filter(c => c.name.includes(process.argv[grep + 1])) : cases;
let failed = 0;
for (const c of chosen) {
  try {
    c.fn();
    console.log(`ok   ${c.name}`);
  } catch (e) {
    failed++;
    console.log(`FAIL ${c.name}: ${e.message.split('\n')[0]}`);
  }
}
console.log(`limiter model (${model.MODEL}): ${chosen.length - failed}/${chosen.length} cases pass`);
process.exit(failed ? 1 : 0);
