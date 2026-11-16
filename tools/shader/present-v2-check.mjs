// SPDX-License-Identifier: AGPL-3.0-only
// GPU leg of the present pass v2 checks (CORE-0108). Renders the saturated-colour ramp and the
// dark gradient of present-model.mjs through the real present pass, v1 (the 532a4f4
// shaders/present/present.glsl, kept as conformance/present/present-v1.glsl) and v2 (the working
// tree), on Metal
// (present-v2-metal.swift), and measures:
//
//   hue      the max hue error on 8-bit codes over the ramp, v1 and v2 (no dither)
//   banding  the dark gradient's longest single-code run and visible step, v1 and v2 (dither 1)
//   ends     black and white inputs stay codes 0 and 255 under the dither
//   model    agreement of every rendered code with the model (inputs rounded to half, as the
//            RGBA16F upload stores them): at most one code apart
//   timing   with --timing, the GPU time of one command buffer at 1920x1080: the v1 pass, the v2
//            pass with post effects off, and the bloom chain plus the v2 pass with bloom,
//            aberration, grain and dither on (median and p95 of --iterations after 20 warm-up)
//
// and fails on present-model.mjs's LIMITS (chainMs only with --timing). --evidence DIR writes
// the before/after contact sheet and crops of a synthetic HDR scene there. Off macOS it prints the
// skip and exits 0. On macOS the Metal leg is required: a missing swift or Metal device fails.
//
//   node tools/shader/present-v2-check.mjs [--timing] [--iterations N] [--evidence DIR]
//                                          [--v1 FILE] [--json FILE]
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { deflateSync, crc32 } from 'node:zlib';
import { DEFAULT_CONFIG, packOverlay } from '../../hosts/web/overlay.js';
import { withTempDir } from './glsl2msl.mjs';
import {
  GRADIENT, LIMITS, banding, gradientValue, hueError, hueRamp, presentPixel, roundHalf, srgbEncode, tonemapV2,
} from './present-model.mjs';
import {
  BLOOM_BLOCK_SIZE, BLOOM_LEVELS, PRESENT_BLOOM_DEFAULTS, PRESENT_FUNCTION, PRESENT_HEAD, PRESENT_POST_OFFSET,
  bloomFunction, bloomLevelSize, bloomMSL, presentBlockSize, presentMSL, presentPost,
} from './present.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const { values: opts } = parseArgs({
  options: {
    timing: { type: 'boolean', default: false },
    iterations: { type: 'string', default: '200' },
    evidence: { type: 'string' },
    v1: { type: 'string', default: 'conformance/present/present-v1.glsl' },
    json: { type: 'string' },
  },
});
const ITERATIONS = Number(opts.iterations);
const WARMUP = 20;
// The post settings of the timed chain and the "after" scene: a visible but modest look.
const POST_ON = { bloom: 0.12, aberration: 0.004, grain: 0.06, dither: 1, frame: 7 };

// ---------- Inputs ----------

const BLOCK = 4; // each ramp entry fills a BLOCK x BLOCK square, read at an interior pixel
const ramp = hueRamp();
const RAMP_COLS = 48, RAMP_ROWS = Math.ceil(ramp.length / RAMP_COLS);
const RW = RAMP_COLS * BLOCK, RH = RAMP_ROWS * BLOCK;
const { width: GW, rows: GH } = GRADIENT;
const SW = 1920, SH = 1080;
const EW = 256, EH = 64; // black left half, white (64, past the tone map's clip) right half

function rgbaImage(w, h, at) {
  const f = new Float32Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const c = at(x, y), o = (y * w + x) * 4;
      f[o] = c[0]; f[o + 1] = c[1]; f[o + 2] = c[2]; f[o + 3] = 1;
    }
  }
  return f;
}

const rampImage = () => rgbaImage(RW, RH, (x, y) => {
  const i = Math.floor(y / BLOCK) * RAMP_COLS + Math.floor(x / BLOCK);
  return i < ramp.length ? ramp[i].x : [0, 0, 0];
});
const endsImage = () => rgbaImage(EW, EH, x => (x < EW / 2 ? [0, 0, 0] : [64, 64, 64]));
const gradientImage = () => rgbaImage(GW, GH, x => { const v = gradientValue(x); return [v, v, v]; });

// The synthetic HDR scene: 24 hue bars over exposures 2^-4 to 2^4 (top half), the dark gradient
// at full width, and bright spots and one-pixel lines on black (bottom).
const SCENE_BARS = 540, SCENE_GRADIENT_END = 810;
function sceneImage() {
  const spots = [];
  for (let i = 0; i < 9; i++) spots.push([100 + i * 210, 900 + (i % 3) * 50, 8 + i * 4, 6 + (i % 4) * 3]);
  return rgbaImage(SW, SH, (x, y) => {
    if (y < SCENE_BARS) {
      const h = Math.floor(x / (SW / 24)) * 15;
      const k = 2 ** (-4 + (8 * y) / (SCENE_BARS - 1));
      const s = (h / 15) % 2 ? 0.75 : 1;
      const f = t => { const u = (t + h / 60) % 6; return 1 - s * Math.max(0, Math.min(u, 4 - u, 1)); };
      return [f(5) * k, f(3) * k, f(1) * k];
    }
    if (y < SCENE_GRADIENT_END) { const v = (0.032 * (x + 0.5)) / SW; return [v, v, v]; }
    let c = 0;
    for (const [sx, sy, peak, r] of spots) c += peak * Math.exp(-((x - sx) ** 2 + (y - sy) ** 2) / (2 * r * r));
    if (x % 240 === 120 && y > 830) c += 4;
    if (y === 1060) c += 2;
    return [c, c * 0.8, c * 0.6];
  });
}

function presentBlock(width, height, post) {
  const f = new Float32Array(presentBlockSize() / 4);
  f.set([1, 1, 1, 0]); // saturation 1, switch done, tone mapped, no vibrance: no grade
  const config = { ...DEFAULT_CONFIG, viewport_width: width, viewport_height: height };
  packOverlay(config, [], new Uint8Array(f.buffer, PRESENT_HEAD, PRESENT_POST_OFFSET - PRESENT_HEAD));
  f.set(presentPost(post), PRESENT_POST_OFFSET / 4);
  return f;
}
const hex = f => Buffer.from(f.buffer, f.byteOffset, f.byteLength).toString('hex');

function bloomBlock(srcW, srcH) {
  const { threshold, knee, radius } = PRESENT_BLOOM_DEFAULTS;
  return new Float32Array([1 / srcW, 1 / srcH, threshold, knee, 1, radius, 0, 0]);
}
if (bloomBlock(1, 1).byteLength !== BLOOM_BLOCK_SIZE) throw new Error('bloom block size');

// ---------- Config ----------

function presentPass(program, size, a, post, bloom) {
  return {
    program, targets: [`out${size}`, `hist${size}`],
    textures: { 0: a, 1: a, 2: `zero${size}`, ...(program === 'v2' ? { 4: bloom ?? a } : {}) },
    bytes: { 0: hex(presentBlock(...SIZES[size], post)) },
  };
}
const SIZES = { R: [RW, RH], G: [GW, GH], E: [EW, EH], S: [SW, SH] };

function chainPasses() {
  const passes = [];
  const lv = k => bloomLevelSize(SW, SH, k);
  passes.push({ program: 'prefilter', targets: ['L0'], textures: { 0: 'scene', 1: 'scene' }, bytes: { 0: hex(bloomBlock(SW, SH)) } });
  for (let k = 1; k < BLOOM_LEVELS; k++) {
    passes.push({ program: 'down', targets: [`L${k}`], textures: { 0: `L${k - 1}` }, bytes: { 0: hex(bloomBlock(...lv(k - 1))) } });
  }
  for (let k = BLOOM_LEVELS - 2; k >= 0; k--) {
    passes.push({ program: 'up', targets: [`L${k}`], load: true, textures: { 0: `L${k + 1}` }, bytes: { 0: hex(bloomBlock(...lv(k + 1))) } });
  }
  passes.push(presentPass('v2', 'S', 'scene', POST_ON, 'L0'));
  return passes;
}

function render(dir) {
  const v1Source = readFileSync(resolve(ROOT, opts.v1), 'utf8');
  const file = (name, text) => { const p = join(dir, name); writeFileSync(p, text); return p; };
  const programs = [
    { name: 'v1', metal: file('v1.metal', presentMSL({ source: v1Source })), function: PRESENT_FUNCTION, formats: ['rgba8Unorm', 'rgba16Float'], blend: 'replace' },
    { name: 'v2', metal: file('v2.metal', presentMSL()), function: PRESENT_FUNCTION, formats: ['rgba8Unorm', 'rgba16Float'], blend: 'replace' },
    ...['prefilter', 'down', 'up'].map(s => ({ name: s, metal: file(`${s}.metal`, bloomMSL(s)), function: bloomFunction(s), formats: ['rgba16Float'], blend: s === 'up' ? 'add' : 'replace' })),
  ];
  const data = (name, f) => { const p = join(dir, name); writeFileSync(p, Buffer.from(f.buffer)); return p; };
  const textures = [
    { name: 'ramp', width: RW, height: RH, format: 'rgba16Float', data: data('ramp.f32', rampImage()) },
    { name: 'gradient', width: GW, height: GH, format: 'rgba16Float', data: data('gradient.f32', gradientImage()) },
    { name: 'ends', width: EW, height: EH, format: 'rgba16Float', data: data('ends.f32', endsImage()) },
  ];
  for (const [k, [w, h]] of Object.entries(SIZES)) {
    textures.push({ name: `out${k}`, width: w, height: h, format: 'rgba8Unorm' });
    textures.push({ name: `hist${k}`, width: w, height: h, format: 'rgba16Float' });
    textures.push({ name: `zero${k}`, width: w, height: h, format: 'rgba16Float' });
  }
  const scene = opts.timing || opts.evidence;
  if (scene) {
    textures.push({ name: 'scene', width: SW, height: SH, format: 'rgba16Float', data: data('scene.f32', sceneImage()) });
    for (let k = 0; k < BLOOM_LEVELS; k++) textures.push({ name: `L${k}`, width: bloomLevelSize(SW, SH, k)[0], height: bloomLevelSize(SW, SH, k)[1], format: 'rgba16Float' });
  }
  const out = name => join(dir, `${name}.out`);
  const once = (name, passes, read) => ({ name, warmup: 0, iterations: 1, passes, read: read.map(([texture, o]) => ({ texture, out: out(o) })) });
  const timed = (name, passes, read) => ({ ...once(name, passes, read), warmup: opts.timing ? WARMUP : 0, iterations: opts.timing ? ITERATIONS : 1 });
  const runs = [
    once('ramp-v1', [presentPass('v1', 'R', 'ramp', {})], [['outR', 'ramp-v1']]),
    once('ramp-v2', [presentPass('v2', 'R', 'ramp', {})], [['outR', 'ramp-v2']]),
    once('gradient-v1', [presentPass('v1', 'G', 'gradient', {})], [['outG', 'gradient-v1']]),
    once('gradient-v2', [presentPass('v2', 'G', 'gradient', { dither: 1 })], [['outG', 'gradient-v2']]),
    once('ends-v2', [presentPass('v2', 'E', 'ends', { dither: 1, frame: 5 })], [['outE', 'ends-v2']]),
  ];
  if (scene) {
    runs.push(timed('scene-v1', [presentPass('v1', 'S', 'scene', {})], [['outS', 'scene-v1']]));
    runs.push(timed('scene-v2', [presentPass('v2', 'S', 'scene', { dither: 1, frame: 7 })], [['outS', 'scene-v2']]));
    runs.push(timed('scene-v2-chain', chainPasses(), [['outS', 'scene-v2-chain']]));
  }
  const cfg = file('config.json', JSON.stringify({ programs, textures, runs }));
  const reply = JSON.parse(execFileSync('swift', [join(HERE, 'present-v2-metal.swift'), cfg], { encoding: 'utf8', maxBuffer: 1 << 26 }));
  if (reply.skipped) return reply;
  const read = name => new Uint8Array(readFileSync(out(name)));
  const images = {};
  for (const r of runs) for (const x of r.read) images[x.out.slice(dir.length + 1, -4)] = read(x.out.slice(dir.length + 1, -4));
  return { ...reply, images };
}

// ---------- Metrics ----------

const codesAt = (img, w, x, y) => { const o = (y * w + x) * 4; return [img[o], img[o + 1], img[o + 2]]; };
const rampCodes = img => ramp.map((_, i) => codesAt(img, RW, (i % RAMP_COLS) * BLOCK + 1, Math.floor(i / RAMP_COLS) * BLOCK + 1));
const gradientRows = img => Array.from({ length: GH }, (_, y) => Array.from({ length: GW }, (_, x) => img[(y * GW + x) * 4]));
const ideal = Array.from({ length: GW }, (_, i) => { const v = gradientValue(i); return srgbEncode(tonemapV2([v, v, v])[0]); });

function agreement(got, want) {
  let max = 0, off = 0;
  got.forEach((g, i) => g.forEach((v, c) => { const d = Math.abs(v - want[i][c]); if (d > max) max = d; if (d) off++; }));
  return { maxCodes: max, differing: off, of: got.length * 3 };
}

const stats = ms => {
  const s = [...ms].sort((a, b) => a - b);
  const q = p => s[Math.min(s.length - 1, Math.floor(p * s.length))];
  return { median: q(0.5), p95: q(0.95), min: s[0], n: s.length };
};

// ---------- PNG ----------

function png(path, w, h, rgb) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w * 3; x++) raw[y * (w * 3 + 1) + 1 + x] = rgb[y * w * 3 + x];
  }
  const chunk = (type, body) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(body.length);
    const tb = Buffer.concat([Buffer.from(type, 'ascii'), body]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(tb) >>> 0);
    return Buffer.concat([len, tb, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  writeFileSync(path, Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0)),
  ]));
}

// A w x h tile of an RGBA8 image: (x0, y0) top-left, step source pixels per tile pixel (point
// sampled), codes times gain.
function tile(img, iw, x0, y0, w, h, step = 1, gain = 1) {
  const t = new Uint8Array(w * h * 3);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const o = ((y0 + y * step) * iw + x0 + x * step) * 4;
      for (let c = 0; c < 3; c++) t[(y * w + x) * 3 + c] = Math.min(255, img[o + c] * gain);
    }
  }
  return t;
}

function sheet(tiles, cols, w, h, gap = 8) {
  const rows = Math.ceil(tiles.length / cols);
  const W = cols * w + (cols + 1) * gap, H = rows * h + (rows + 1) * gap;
  const s = new Uint8Array(W * H * 3).fill(48);
  tiles.forEach((t, i) => {
    const ox = gap + (i % cols) * (w + gap), oy = gap + Math.floor(i / cols) * (h + gap);
    for (let y = 0; y < h; y++) s.set(t.subarray(y * w * 3, (y + 1) * w * 3), ((oy + y) * W + ox) * 3);
  });
  return { W, H, s };
}

function writeEvidence(dir, images) {
  mkdirSync(dir, { recursive: true });
  const names = ['scene-v1', 'scene-v2', 'scene-v2-chain'];
  for (const n of names) png(join(dir, `${n}-half.png`), SW / 2, SH / 2, tile(images[n], SW, 0, 0, SW / 2, SH / 2, 2));
  // Contact sheet, columns v1 | v2 (post off, dither 1) | v2 chain (bloom, aberration, grain):
  // the scene at quarter size; the dark gradient at full size, codes x8; the hue bars' bright
  // end at full size.
  const tiles = [];
  for (const n of names) tiles.push(tile(images[n], SW, 0, 0, 480, 270, 4));
  for (const n of names) tiles.push(tile(images[n], SW, 0, SCENE_BARS, 480, 270, 1, 8));
  for (const n of names) tiles.push(tile(images[n], SW, 720, SCENE_BARS - 270, 480, 270));
  const { W, H, s } = sheet(tiles, 3, 480, 270);
  png(join(dir, 'contact.png'), W, H, s);
}

// ---------- Main ----------

// Off macOS the Metal leg cannot run, so it is skipped. On macOS (the gate host) it is required.
if (process.platform !== 'darwin') {
  console.log(`present-v2-check: Metal skipped (${process.platform} host, Metal is macOS only)`);
  process.exit(0);
}
if (spawnSync('swift', ['--version'], { stdio: 'ignore' }).error) {
  console.error('present-v2-check: FAIL swift not on PATH; the Metal leg is required on macOS');
  process.exit(1);
}
const result = withTempDir('present-v2-check', render);
if (result.skipped) {
  console.error(`present-v2-check: FAIL Metal leg did not run (${result.skipped}); it is required on macOS`);
  process.exit(1);
}
const { images } = result;
const fail = [];
const report = { device: result.device, v1: opts.v1, limits: LIMITS };

const r1 = rampCodes(images['ramp-v1']), r2 = rampCodes(images['ramp-v2']);
const rampIn = ramp.map(r => r.x.map(roundHalf));
report.hue = {
  v1: hueError(ramp, r1, { levels: 255 }),
  v2: hueError(ramp, r2, { levels: 255 }),
};
report.model = {
  rampV1: agreement(r1, rampIn.map(x => presentPixel(x, { version: 1 }))),
  rampV2: agreement(r2, rampIn.map(x => presentPixel(x, { version: 2 }))),
};
for (const v of ['v1', 'v2']) delete report.hue[v].worst;

const g1 = gradientRows(images['gradient-v1']), g2 = gradientRows(images['gradient-v2']);
report.banding = { v1: banding(g1, ideal), v2: banding(g2, ideal) };
const gWant = (version, dither) => g1.map((row, y) => row.map((_, x) => {
  const v = roundHalf(gradientValue(x));
  return presentPixel([v, v, v], { version, dither, px: x, py: y })[0];
}));
const flat = rows => rows.flat().map(v => [v]);
report.model.gradientV1 = agreement(flat(g1), flat(gWant(1, 0)));
report.model.gradientV2 = agreement(flat(g2), flat(gWant(2, 1)));

let endsOff = 0;
const ends = images['ends-v2'];
for (let i = 0; i < EW * EH; i++) {
  const want = i % EW < EW / 2 ? 0 : 255;
  for (let c = 0; c < 3; c++) if (ends[i * 4 + c] !== want) endsOff++;
}
report.ends = { differing: endsOff, of: EW * EH * 3 };
if (endsOff) fail.push(`${endsOff} black or white channel(s) off 0 or 255 under the dither`);

const h2 = report.hue.v2, b2 = report.banding.v2;
if (!(report.hue.v1.max > 20)) fail.push(`the hue metric no longer sees v1's shift (${report.hue.v1.max})`);
if (h2.max > LIMITS.hueCodes) fail.push(`v2 hue error on codes ${h2.max.toFixed(3)} > ${LIMITS.hueCodes} degrees`);
if (h2.counted < ramp.length * 0.6) fail.push(`only ${h2.counted} ramp entries counted`);
if (b2.localStep > LIMITS.bandStep) fail.push(`v2 dithered step ${b2.localStep.toFixed(3)} > ${LIMITS.bandStep} codes`);
if (b2.maxRun > LIMITS.bandRun) fail.push(`v2 dithered run ${b2.maxRun} > ${LIMITS.bandRun} px`);
for (const [k, a] of Object.entries(report.model)) if (a.maxCodes > 1) fail.push(`${k}: GPU and model ${a.maxCodes} codes apart`);

if (opts.timing) {
  report.timing = {
    what: `GPU time of one command buffer (gpuEndTime - gpuStartTime), ${SW}x${SH}, ${WARMUP} warm-up then ${ITERATIONS} iterations, on ${result.device}`,
    runs: Object.fromEntries(result.runs.filter(r => r.name.startsWith('scene')).map(r => [r.name, stats(r.gpuMs)])),
  };
  const chain = report.timing.runs['scene-v2-chain'];
  if (chain.median > LIMITS.chainMs) fail.push(`chain median ${chain.median.toFixed(3)} ms > ${LIMITS.chainMs} ms`);
}
if (opts.evidence) writeEvidence(resolve(opts.evidence), images);
if (opts.json) writeFileSync(opts.json, `${JSON.stringify(report, null, 2)}\n`);

const f = (v, d = 3) => v.toFixed(d);
console.log(`present-v2-check on ${result.device}`);
console.log(`  hue error on codes (max/mean, degrees): v1 ${f(report.hue.v1.max)}/${f(report.hue.v1.mean)}  v2 ${f(h2.max)}/${f(h2.mean)}  (${h2.counted}/${ramp.length} counted)`);
console.log(`  banding (max run px, step codes): v1 ${report.banding.v1.maxRun}, ${f(report.banding.v1.localStep)}  v2 ${b2.maxRun}, ${f(b2.localStep)}`);
console.log(`  ends: ${report.ends.differing}/${report.ends.of} black/white channels off`);
for (const [k, a] of Object.entries(report.model)) console.log(`  model ${k}: max ${a.maxCodes} code(s), ${a.differing}/${a.of} differ`);
if (report.timing) for (const [k, t] of Object.entries(report.timing.runs)) console.log(`  ${k}: median ${f(t.median)} ms, p95 ${f(t.p95)} ms, min ${f(t.min)} ms (n ${t.n})`);
if (fail.length) {
  for (const m of fail) console.error(`FAIL ${m}`);
  process.exit(1);
}
console.log('present-v2-check: ok');
