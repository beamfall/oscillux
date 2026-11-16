// SPDX-License-Identifier: AGPL-3.0-only
// Pure-node checks for present pass v2 (CORE-0108): the hue error on a saturated-colour ramp and
// the banding of a dark gradient, v1 against v2, through the colour-path model
// (present-model.mjs); that shaders/present/present.glsl carries the model's tone map, hash and
// dither; the post block and reduced-motion policy; and the bloom pass graph. The GPU leg,
// tools/shader/present-v2-check.mjs, renders the same inputs through the real pass and compares
// them with the model.
//
//   node tools/shader/test-present-v2.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import {
  LIMITS, banding, gradientModel, hue, hueError, hueRamp, presentHash, presentNoise, presentPixel, srgbEncode, tonemapV1,
  tonemapV2,
} from './present-model.mjs';
import {
  BLOOM_PATH, BLOOM_STAGES, PRESENT_BLOOM_GRAPH, PRESENT_PATH, PRESENT_POST_OFFSET, bloomGLSL300, bloomLevelSize,
  presentBlockSize, presentGLSL300, presentPost, presentTrailDecay,
} from './present.mjs';

const { hueFloat: HUE_LIMIT_FLOAT, hueCodes: HUE_LIMIT_CODES, bandStep: BAND_STEP_LIMIT, bandRun: BAND_RUN_LIMIT } = LIMITS;

const ramp = hueRamp();
const rampOut = (version, levels) => ramp.map(r => presentPixel(r.x, { version, levels }));

test('v2 keeps the hue of saturated colours; v1 does not', () => {
  const v1 = hueError(ramp, rampOut(1, 0));
  const v2 = hueError(ramp, rampOut(2, 0));
  const v2codes = hueError(ramp, rampOut(2, 255), { levels: 255 });
  assert.ok(v1.max > 20, `the metric no longer sees v1's shift (${v1.max} degrees)`);
  assert.ok(v2.max <= HUE_LIMIT_FLOAT, `v2 hue error ${v2.max} degrees`);
  assert.ok(v2codes.max <= HUE_LIMIT_CODES, `v2 hue error on codes ${v2codes.max} degrees`);
  assert.ok(v2.counted > ramp.length * 0.8 && v2codes.counted > ramp.length * 0.6, 'too few ramp entries counted');
});

test('v2 maps greys as v1 did and keeps luminance where it does not clip', () => {
  for (let v = 0; v <= 16; v += 1 / 64) assert.ok(Math.abs(tonemapV2([v, v, v])[0] - tonemapV1([v, v, v])[0]) < 1e-12, `grey ${v}`);
  const x = [0.3, 0.12, 0.05];
  const lum = c => 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  assert.ok(Math.abs(lum(tonemapV2(x)) - tonemapV1([lum(x), 0, 0])[0]) < 1e-12);
  // A clipping colour moves toward its grey: in range, same hue.
  const z = [4, 0.5, 0], y = tonemapV2(z);
  assert.ok(Math.max(...y) === 1 && y[2] > 0 && Math.abs(hue(y) - hue(z)) < 1e-9, `${y}`);
});

test('the triangular dither removes the dark gradient\'s bands', () => {
  const v1 = gradientModel({ version: 1 });
  const v2 = gradientModel({ version: 2, dither: 1 });
  const b1 = banding(v1.rows, v1.ideal), b2 = banding(v2.rows, v2.ideal);
  assert.ok(b1.localStep > 0.3 && b1.maxRun > 2 * BAND_RUN_LIMIT, `the metric no longer sees v1's bands (${JSON.stringify(b1)})`);
  assert.ok(b2.localStep <= BAND_STEP_LIMIT, `dithered step ${b2.localStep} codes`);
  assert.ok(b2.maxRun <= BAND_RUN_LIMIT, `dithered run ${b2.maxRun} px`);
});

test('the dither keeps black and white exact and is unbiased', () => {
  for (let y = 0; y < 64; y++) {
    for (let x = 0; x < 64; x++) {
      assert.equal(presentPixel([0, 0, 0], { dither: 1, px: x, py: y })[0], 0);
      assert.equal(presentPixel([64, 64, 64], { dither: 1, px: x, py: y })[0], 255);
    }
  }
  for (const v of [0.0005, 0.004, 0.02, 0.2, 0.9]) {
    const ideal = srgbEncode(tonemapV2([v, v, v])[0]) * 255;
    let sum = 0;
    for (let i = 0; i < 4096; i++) sum += presentPixel([v, v, v], { dither: 1, px: i & 63, py: i >> 6, frame: 3 })[0];
    assert.ok(Math.abs(sum / 4096 - ideal) < 0.03, `mean ${sum / 4096} against ${ideal}`);
  }
});

test('the hash matches its vectors and the noise is in range', () => {
  assert.deepEqual(presentHash(0, 0, 0), [2813634668, 1314218842, 2614921617]);
  assert.deepEqual(presentHash(1919, 1079, 123456), [2468651880, 416649370, 3557656586]);
  for (let i = 0; i < 1000; i++) {
    const n = presentNoise(i, i * 7, i * 13);
    assert.ok(n.dither > -1 && n.dither < 1 && n.grain > -1 && n.grain < 1 && n.rect >= -0.5 && n.rect < 0.5);
  }
});

test('present.glsl carries the model\'s tone map, hash, dither and grain', () => {
  const src = readFileSync(PRESENT_PATH, 'utf8').replace(/\s+/g, ' ');
  for (const s of [
    'float presentAces(float v) { return clamp((v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14), 0.0, 1.0); }',
    'if (l <= 1e-6) return x * (0.03 / 0.14);',
    'if (m > 1.0) c = vec3(t) + (c - vec3(t)) * ((1.0 - t) / (m - t));',
    'h ^= h >> 16u; h *= 0xa7d471dbu; h ^= h >> 14u; h *= 0x76a997d3u; h ^= h >> 16u;',
    'uint k = presentMix(presentMix(presentMix(v.x ^ 0xed81fd3au) ^ v.y) ^ v.z);',
    'return uvec3(presentMix(k ^ 0x6294a626u), presentMix(k ^ 0xbe633942u), presentMix(k ^ 0xa97a7369u));',
    '0x9e3779b9u',
    'float(h >> 8u) * (1.0 / 16777216.0)',
    'q < 1.0 || q > levels - 1.0',
    'if (q < 1.0 / 1024.0 || q > levels - 1.0 / 1024.0) return q < 1.0 ? 0.0 : 1.0;',
    'floor(q + 0.5 + pu.post0.w * r)',
    'pu.post0.z * (1.0 - pu.overlay3.z)',
  ]) assert.ok(src.includes(s), `present.glsl lacks: ${s}`);
  assert.ok(!/\bsin\s*\(/.test(src), 'present.glsl uses sin');
  assert.ok(!/2\.51 \* x\b/.test(src), 'present.glsl still maps each channel with ACES');
});

test('post block, reduced motion and wrappers', () => {
  assert.equal(PRESENT_POST_OFFSET, 336);
  assert.equal(presentBlockSize(), 368);
  assert.deepEqual([...presentPost({ bloom: 0.5, aberration: 0.25, grain: 0.125, dither: 1, frame: 16777217 })], [0.5, 0.25, 0.125, 1, 1, 0, 0, 0]);
  assert.equal(presentPost({ grain: 0.1, reducedMotion: true })[2], 0);
  assert.equal(presentTrailDecay(0.8, true), 0);
  assert.equal(presentTrailDecay(0.8, false), 0.8);
  const web = presentGLSL300();
  assert.ok(web.includes('uniform sampler2D uA, uB, uH, uBloom;') && web.includes('vec4 post0;') && web.includes('vec4 post1;'));
});

test('bloom pass graph: five levels, down then additive up, sizes from the output', () => {
  const g = PRESENT_BLOOM_GRAPH;
  assert.deepEqual(g.targets.map(t => [t.id, t.scale, t.format]), [0, 1, 2, 3, 4].map(k => [`L${k}`, 1 / 2 ** (k + 1), 'rgba16f']));
  assert.deepEqual([0, 1, 2, 3, 4].map(k => bloomLevelSize(1920, 1080, k)), [[960, 540], [480, 270], [240, 135], [120, 68], [60, 34]]);
  assert.deepEqual(g.passes.map(p => `${p.stage}:${Object.values(p.inputs).join('+')}>${p.output}:${p.blend}`), [
    'prefilter:incoming+outgoing>L0:replace',
    'down:L0>L1:replace', 'down:L1>L2:replace', 'down:L2>L3:replace', 'down:L3>L4:replace',
    'up:L4>L3:add', 'up:L3>L2:add', 'up:L2>L1:add', 'up:L1>L0:add',
    'present:incoming+outgoing+history+L0>screen:replace',
  ]);
  for (const [i, stage] of BLOOM_STAGES.entries()) {
    const src = bloomGLSL300(stage);
    assert.ok(src.includes(`#define BLOOM_STAGE ${i}\n`) && src.includes('uniform BloomBlock'), stage);
    assert.equal(src.includes('uSrcB'), stage === 'prefilter', stage);
  }
  assert.ok(!/\bsin\s*\(/.test(readFileSync(BLOOM_PATH, 'utf8')));
});
