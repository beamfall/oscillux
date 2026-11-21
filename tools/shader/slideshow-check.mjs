// SPDX-License-Identifier: AGPL-3.0-only
// Photo slideshow check (conformance/slideshow/README.md): compiles the slideshow pass
// (tools/shader/slideshow.mjs over shaders/slideshow/slideshow.glsl) for WebGL2 and, on macOS,
// Metal, then
//   1. draws every golden case of conformance/slideshow/vectors.json under real WebGL2
//      (SwiftShader via Playwright Chromium) and through the Metal device (slideshow-metal.swift)
//      and compares each channel with the expected value within the file's tolerance;
//   2. draws every amplitude-0 case again with loud and with silent beat inputs, on both GPUs
//      (and at 320x180 with hardware sampling on WebGL2), and requires identical output;
//   3. plays a worst-case sequence (black, white, a checker, saturated red stripes, every
//      transition and layout, tempo coupling at amplitude 1 at 180 BPM, slides at the shortest
//      5 s interval) at 60 fps, 160x90, through the ACES fitted tone map and sRGB encode, and
//      runs the bytes through the limiter model (limiter-model.mjs) and the independent flash
//      audit (limiter-audit.mjs): the limiter's output makes at most 6 large-area luminance and
//      1 red transition in any second, and the input must make some (the content rendered).
// Exits 2 on any compile failure, mismatch or failed bound.
//
//   node tools/shader/slideshow-check.mjs [--frames out.png] [--perf] [--perf-json out.json]
//
// --frames writes a contact sheet of the loud-audio review sequence (photo-like inputs, every
// layout and transition, tone mapped as above) drawn by WebGL2 with hardware sampling and mips.
// --perf times each style over each layout at 1920x1080 on the Metal device from 2048x2048
// mipmapped rgba16Float photos (median, p95 and min ms per draw).
//
// The MSL is compared by its output, not its bytes, so any SPIRV-Cross on PATH serves (verify.mjs
// holds the pinned one). The offline AIR compile (xcrun metal) runs when the Metal Toolchain is
// installed and is reported SKIPPED, never passed, when it is not.
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { withTempDir } from './glsl2msl.mjs';
import { createAuditor } from './limiter-audit.mjs';
import { createLimiter } from './limiter-model.mjs';
import {
  SLIDESHOW_FUNCTION, SLIDESHOW_LAYOUTS, SLIDESHOW_STYLES, slideshowBlock, slideshowGLSL300, slideshowMSL,
} from './slideshow.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const { values: opts } = parseArgs({
  options: {
    frames: { type: 'string', default: '' },
    perf: { type: 'boolean', default: false },
    'perf-json': { type: 'string', default: '' },
  },
});
const V = JSON.parse(readFileSync(join(ROOT, 'conformance', 'slideshow', 'vectors.json'), 'utf8'));
const N = V.size;
const CACHE = join(ROOT, 'out', 'cache', 'metal-module-cache');
const METAL = process.platform === 'darwin';
const problems = [];

if (JSON.stringify(V.styles) !== JSON.stringify(SLIDESHOW_STYLES)) problems.push('vectors.json styles differ from slideshow.mjs');
if (JSON.stringify(V.layouts) !== JSON.stringify(SLIDESHOW_LAYOUTS)) problems.push('vectors.json layouts differ from slideshow.mjs');
const caseBlock = (c, extra = {}) => slideshowBlock({ ...c, style: c.styleId, width: N, height: N, ...extra });
const blocks = V.cases.map(c => caseBlock(c));
// Amplitude-0 cases with loud beat inputs and with silent ones, which must draw the same.
const LOUD = { beatPhase: 0.25, beatsPerSlide: 2 }, SILENT = { beatPhase: 0, beatsPerSlide: 1 };
const calm = V.cases.filter(c => c.amplitude === 0);
const identity = calm.flatMap(c => [caseBlock(c, LOUD), caseBlock(c, SILENT)]);
const flat = img => new Float32Array(img.flatMap(([r, g, b]) => [r, g, b, 1]));
const hex = b => Buffer.from(b.buffer).toString('hex');

// Offline compiles: ES 3.00 through glslangValidator for both samplings; on macOS GLSL 450 to
// SPIR-V, SPIRV-Cross to MSL with the ABI checked, and the Metal compiler to AIR when present.
const msl = {};
withTempDir('slideshow-check', dir => {
  for (const sampling of ['fetch', 'linear']) {
    const es = join(dir, `slideshow-${sampling}.frag`);
    writeFileSync(es, slideshowGLSL300({ sampling }));
    try { execFileSync('glslangValidator', ['-S', 'frag', es], { stdio: 'pipe' }); }
    catch (e) { problems.push(`GLSL ES 3.00 (${sampling}): ${(e.stdout || e.message).toString().slice(0, 800)}`); }
  }
  console.log('compiled: GLSL ES 3.00 (glslangValidator), fetch and linear sampling');
  if (!METAL) { console.log('Metal legs skipped: requires macOS'); return; }
  for (const sampling of ['fetch', 'linear']) {
    try { msl[sampling] = slideshowMSL({ sampling }); }
    catch (e) { problems.push(`GLSL 450 -> MSL (${sampling}): ${(e.stderr || e.message).toString().slice(0, 800)}`); }
  }
  console.log('compiled: GLSL 450 -> SPIR-V -> MSL (glslangValidator + SPIRV-Cross), ABI checked');
  for (const [sampling, src] of Object.entries(msl)) {
    const file = join(dir, `slideshow-${sampling}.metal`);
    writeFileSync(file, src);
    try {
      execFileSync('xcrun', ['metal', `-fmodules-cache-path=${CACHE}`, '-c', file, '-o', join(dir, `slideshow-${sampling}.air`)], { stdio: 'pipe' });
      console.log(`compiled: MSL -> AIR (xcrun metal, ${sampling})`);
    } catch (e) {
      const text = (e.stderr || e.message).toString();
      if (/missing Metal Toolchain/.test(text)) { console.log('xcrun metal: SKIPPED (Metal Toolchain not installed); the device compile below covers MSL'); break; }
      problems.push(`xcrun metal (${sampling}): ${text.slice(0, 800)}`);
    }
  }
});

function compare(label, got) {
  let worst = 0, at = '', bad = 0;
  V.cases.forEach((c, k) => {
    for (let i = 0; i < N * N; i++) for (let ch = 0; ch < 3; ch++) {
      const e = c.expected[i][ch];
      const d = Math.abs(got[k * N * N * 4 + i * 4 + ch] - e);
      if (!(d <= V.tolerance)) bad++;
      if (!(d <= worst)) { worst = d; at = `${c.style} p=${c.p} ${c.a.layout}->${c.b.layout} px=${i % N},${Math.floor(i / N)} ch=${ch}`; }
    }
  });
  console.log(`${label}: ${V.cases.length} cases x ${N}x${N}, max |diff| ${worst.toExponential(3)} (tolerance ${V.tolerance})` +
    `${bad ? `, ${bad} channel(s) out of tolerance, worst at ${at}` : ''}`);
  if (bad) problems.push(`${label}: ${bad} channel(s) out of tolerance, worst ${worst} at ${at}`);
}

// Pairs of draws (loud, silent) must be bit-identical.
function sameOutput(label, got, pairs, size) {
  let differ = 0;
  for (let k = 0; k < pairs; k++) {
    const a = got.subarray ? got.subarray((2 * k) * size, (2 * k + 1) * size) : got.slice((2 * k) * size, (2 * k + 1) * size);
    const b = got.subarray ? got.subarray((2 * k + 1) * size, (2 * k + 2) * size) : got.slice((2 * k + 1) * size, (2 * k + 2) * size);
    for (let i = 0; i < size; i++) if (!Object.is(a[i], b[i])) { differ++; break; }
  }
  console.log(`${label}: ${pairs} amplitude-0 draw(s) with loud and silent beat inputs, ${differ ? `${differ} differ` : 'identical'}`);
  if (differ) problems.push(`${label}: ${differ} amplitude-0 draw(s) depend on the beat inputs`);
}

// The worst-case sequence and the review sequence: slides shown for INTERVAL seconds, each
// transition taking its style's suggested duration; k runs over a slide's whole time on screen,
// from the start of its entry to the end of its exit (the next slide's transition). The sequence
// ends a second after the last transition completes.
const INTERVAL = 5, BPS = 3;
const DURATION = { dissolve: 1.5, lightSweep: 1.8, iris: 1.6 };
const smooth = x => { const s = Math.min(Math.max(x, 0), 1); return s * s * (3 - 2 * s); };
function sequence(slides, W, H, fps, amplitude) {
  const last = slides.length - 1;
  const total = last * INTERVAL + DURATION[slides[last].style] + 1;
  const life = j => INTERVAL + DURATION[slides[Math.min(j + 1, last)].style];
  const frames = [];
  for (let f = 0; f < total * fps; f++) {
    const t = f / fps;
    const i = Math.min(Math.floor(t / INTERVAL), slides.length - 1);
    const tau = t - i * INTERVAL;
    const D = DURATION[slides[i].style];
    const slide = (j, k) => ({ ...slides[j].slide, k });
    const inTransition = i > 0 && tau < D;
    const b = slide(i, tau / life(i));
    const a = inTransition ? slide(i - 1, (t - (i - 1) * INTERVAL) / life(i - 1)) : b;
    frames.push({
      t, photos: inTransition ? [...slides[i - 1].photos, ...slides[i].photos] : [...slides[i].photos, ...slides[i].photos],
      block: Array.from(slideshowBlock({
        p: inTransition ? smooth(tau / D) : 0, style: slides[i].style, aspect: W / H, motion: 1,
        amplitude, beatPhase: (t * BPS) % 1, beatsPerSlide: BPS * life(i), width: W, height: H, a, b,
      })),
    });
  }
  return frames;
}

const FLASH = [
  { photos: ['checker', 'checker'], style: 'dissolve', slide: { layout: 'cover', aspect0: 1.5, rect0: [0.4, 0.3, 0.6, 0.6] } },
  { photos: ['black', 'black'], style: 'dissolve', slide: { layout: 'cover', aspect0: 1.5 } },
  { photos: ['white', 'white'], style: 'iris', slide: { layout: 'cover', aspect0: 1.5, rect0: [0.6, 0.2, 0.8, 0.4] } },
  { photos: ['red', 'red'], style: 'lightSweep', slide: { layout: 'fill', aspect0: 0.75, rect0: [0.3, 0.2, 0.7, 0.5] } },
  { photos: ['white', 'checker'], style: 'dissolve', slide: { layout: 'pair', aspect0: 0.75, aspect1: 0.75, direction: 1 } },
  { photos: ['black', 'black'], style: 'lightSweep', slide: { layout: 'cover', aspect0: 1.5 } },
];
const REVIEW = [
  { photos: ['landscape', 'landscape'], style: 'dissolve', slide: { layout: 'cover', aspect0: 1.5, rect0: [0.62, 0.18, 0.82, 0.42] } },
  { photos: ['portrait', 'portrait'], style: 'lightSweep', slide: { layout: 'fill', aspect0: 0.75, rect0: [0.3, 0.18, 0.7, 0.55] } },
  { photos: ['portrait', 'portrait2'], style: 'iris', slide: { layout: 'pair', aspect0: 0.75, aspect1: 0.66, rect0: [0.3, 0.18, 0.7, 0.55], rect1: [0.25, 0.2, 0.65, 0.5] } },
  { photos: ['city', 'city'], style: 'lightSweep', slide: { layout: 'cover', aspect0: 1.78, direction: 1, rect0: [0.1, 0.4, 0.3, 0.7] } },
  { photos: ['landscape', 'landscape'], style: 'iris', slide: { layout: 'cover', aspect0: 1.5, rect0: [0.62, 0.18, 0.82, 0.42] } },
];

// WebGL2 (SwiftShader).
const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader'] });
const page = await browser.newPage();
page.on('console', m => { if (m.type() === 'error') console.error('[page]', m.text().slice(0, 400)); });
await page.addScriptTag({ content: [harness, makePhoto, toBytes].map(f => f.toString()).join('\n') });
const textures = V.photos.map(img => ({ w: N, h: N, data: Array.from(flat(img)) }));
const web = await page.evaluate(drawVectors, {
  fs: slideshowGLSL300({ sampling: 'fetch' }), n: N, textures,
  blocks: [...blocks, ...identity].map(b => Array.from(b)),
});
if (web.fatal) { console.error(web.fatal); process.exit(1); }
console.log(`WebGL2 renderer: ${web.renderer}`);
compare('WebGL2 vs vectors.json', web.pixels.slice(0, blocks.length * N * N * 4));
sameOutput('WebGL2 audio identity (fetch, 8x8)', web.pixels.slice(blocks.length * N * N * 4), calm.length, N * N * 4);

// Amplitude-0 identity with hardware sampling and mips at 320x180 over the flash sequence's frames.
{
  const W = 320, H = 180;
  const frames = sequence(FLASH, W, H, 4, 0);
  const pairs = frames.flatMap(f => {
    const loud = Float32Array.from(f.block), silent = Float32Array.from(f.block);
    loud[5] = 0.25; loud[6] = 7; silent[5] = 0; silent[6] = 1;
    return [{ photos: f.photos, block: Array.from(loud) }, { photos: f.photos, block: Array.from(silent) }];
  });
  const r = await page.evaluate(drawIdentity, { fs: slideshowGLSL300({ sampling: 'linear' }), W, H, pairs });
  if (r.fatal) { console.error(r.fatal); process.exit(1); }
  console.log(`WebGL2 audio identity (linear, ${W}x${H}): ${r.pairs} amplitude-0 frame(s) with loud and silent beat inputs, ${r.differ ? `${r.differ} differ` : 'identical'}`);
  if (r.differ) problems.push(`WebGL2 audio identity (linear): ${r.differ} frame(s) depend on the beat inputs`);
}

// The worst-case loud-audio sequence through the limiter model and the flash audit. The audit
// counts every 0.1 step of a pixel's luminance, so a large brightness change made over many frames
// (a dissolve from black to white, a soft wipe) counts several transitions and the limiter paces
// it: its output must stay within the audit's bounds. With no transition on screen the input
// itself must make none: the move and its tempo coupling never flash.
{
  const W = 160, H = 90, FPS = 60;
  await page.evaluate(startSequence, { fs: slideshowGLSL300({ sampling: 'linear' }), W, H });
  const play = async (frames, each) => {
    for (let s = 0; s < frames.length; s += 60) {
      const batch = await page.evaluate(drawSequence, frames.slice(s, s + 60).map(f => ({ photos: f.photos, block: f.block })));
      if (batch.fatal) { console.error(batch.fatal); process.exit(1); }
      for (const b64 of batch.frames) each(new Uint8Array(Buffer.from(b64, 'base64')));
    }
  };
  const lim = createLimiter({ width: W, height: H });
  const inA = createAuditor({ width: W, height: H }), outA = createAuditor({ width: W, height: H });
  let held = 0;
  await play(sequence(FLASH, W, H, FPS, 1), px => {
    const r = lim.step(px, 1 / FPS);
    inA.push(px, 1 / FPS);
    outA.push(r.out, 1 / FPS);
    held += r.held;
  });
  const lumaIn = inA.maxPerWindow('luma', 1), lumaOut = outA.maxPerWindow('luma', 1);
  const redIn = inA.maxPerWindow('red', 1), redOut = outA.maxPerWindow('red', 1);
  console.log(`flash sequence: ${FLASH.length} slides every ${INTERVAL} s at ${FPS} fps, ${W}x${H}, amplitude 1 at ${BPS * 60} BPM; ` +
    `large-area transitions per second in / limiter out: luma ${lumaIn} / ${lumaOut}, red ${redIn} / ${redOut}; limiter held ${held} pixel-frame(s)`);
  if (lumaOut > 6) problems.push(`flash sequence: the limiter output makes ${lumaOut} large-area luma transitions in one second`);
  if (redOut > 1) problems.push(`flash sequence: the limiter output makes ${redOut} large-area red transitions in one second`);
  // The stress content must reach the audit: a pass that drew nothing would pass the bounds.
  if (!lumaIn || !redIn) problems.push(`flash sequence: the input makes no large-area ${lumaIn ? 'red' : 'luma'} transition, so the stress content did not render`);
  // Each slide alone, from 1 s after its start to 1 s before its successor's (no transition on
  // screen), with and without tempo coupling, reported for review only. The audit counts every
  // 0.1 step of a pixel, so a moving soft edge (a minified checker, stripes) counts many and the
  // numbers follow the sampling more than the risk; the bound is the limiter output above.
  const holds = [];
  for (const sl of FLASH) {
    const count = async amplitude => {
      const audit = createAuditor({ width: W, height: H });
      await play(sequence([sl, sl], W, H, FPS, amplitude).slice(FPS, (INTERVAL - 1) * FPS), px => audit.push(px, 1 / FPS));
      return audit.maxPerWindow('luma', 1) + audit.maxPerWindow('red', 1);
    };
    holds.push(`${await count(0)}/${await count(1)}`);
  }
  console.log(`flash holds (input, informational): large-area transitions per second without / with tempo coupling: ${holds.join(' ')}`);
}

if (opts.frames) {
  const W = 320, H = 180;
  const frames = sequence(REVIEW, W, H, 60, 1);
  // Each transition at p of about 0.3 and 0.6, and each slide mid-hold.
  const pick = [];
  REVIEW.forEach((sl, i) => {
    const t0 = i * INTERVAL, D = DURATION[sl.style];
    if (i > 0) pick.push(t0 + 0.38 * D, t0 + 0.55 * D);
    pick.push(t0 + 3);
  });
  const chosen = pick.map(t => frames[Math.round(t * 60)]).filter(Boolean);
  const sheet = await page.evaluate(drawSheet, { fs: slideshowGLSL300({ sampling: 'linear' }), W, H, frames: chosen.map(f => ({ ...f, label: `t=${f.t.toFixed(2)} p=${f.block[0].toFixed(2)} ${SLIDESHOW_STYLES[f.block[1]]}` })) });
  if (sheet.fatal) { console.error(sheet.fatal); process.exit(1); }
  writeFileSync(resolve(opts.frames), Buffer.from(sheet.png.split(',')[1], 'base64'));
  console.log(`contact frames: ${resolve(opts.frames)} (amplitude 1 at ${BPS * 60} BPM, motion 1)`);
}
await browser.close();

// Metal device: the golden cases and the audio identity pairs through the fetch pass, and the
// optional 1080p timings.
if (METAL && msl.fetch && msl.linear) {
  withTempDir('slideshow-metal', dir => {
    const paths = V.photos.map((img, i) => {
      const p = join(dir, `photo${i}.f32`);
      writeFileSync(p, Buffer.from(flat(img).buffer));
      return p;
    });
    writeFileSync(join(dir, 'fetch.metal'), msl.fetch);
    const cfg = join(dir, 'vectors.json');
    const out = join(dir, 'out.f32');
    writeFileSync(cfg, JSON.stringify({
      metal: join(dir, 'fetch.metal'), function: SLIDESHOW_FUNCTION,
      vectors: { size: N, inputs: paths, blocks: [...blocks, ...identity].map(hex), out },
    }));
    let reply;
    try { reply = JSON.parse(execFileSync('swift', [join(HERE, 'slideshow-metal.swift'), cfg], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })); }
    catch (e) { problems.push(`Metal device compile/draw: ${(e.stderr || e.message).toString().slice(0, 800)}`); return; }
    // On macOS the Metal leg is required (as in limiter-check.mjs): no device fails the check.
    if (reply.skipped) { problems.push(`Metal device: unavailable on macOS (${reply.skipped})`); return; }
    console.log(`Metal device: ${reply.device} (runtime MSL compile ok)`);
    const buf = readFileSync(out);
    const got = new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
    compare('Metal vs vectors.json', got.subarray(0, blocks.length * N * N * 4));
    sameOutput('Metal audio identity (fetch, 8x8)', got.subarray(blocks.length * N * N * 4), calm.length, N * N * 4);

    if (!opts.perf) return;
    writeFileSync(join(dir, 'linear.metal'), msl.linear);
    const W = 1920, H = 1080;
    const combos = SLIDESHOW_LAYOUTS.flatMap(layout => SLIDESHOW_STYLES.map(style => ({ layout, style })));
    const slide = layout => ({ layout, k: 0.5, aspect0: layout === 'cover' ? 1.5 : 0.75, aspect1: 0.66, rect0: [0.3, 0.2, 0.7, 0.6] });
    writeFileSync(cfg, JSON.stringify({
      metal: join(dir, 'linear.metal'), function: SLIDESHOW_FUNCTION,
      perf: {
        width: W, height: H, photo: 2048, draws: 20, samples: 40, warmup: 5,
        blocks: [
          hex(slideshowBlock({ p: 0, aspect: W / H, width: W, height: H, a: slide('cover') })),
          ...combos.map(({ layout, style }) => hex(slideshowBlock({
            p: 0.5, style, aspect: W / H, amplitude: 1, beatPhase: 0.25, beatsPerSlide: 40, width: W, height: H,
            a: slide(layout), b: slide(layout),
          }))),
        ],
      },
    }));
    const perf = JSON.parse(execFileSync('swift', [join(HERE, 'slideshow-metal.swift'), cfg], { encoding: 'utf8' }));
    console.log(`perf: ${perf.device}, ${W}x${H} rgba16Float target, four 2048x2048 mipmapped rgba16Float photos, ` +
      'ms per draw over 40 command buffers of 20 draws (GPU start/end times)');
    const labels = ['cover hold (p=0)', ...combos.map(c => `${c.layout} ${c.style} p=0.5`)];
    perf.perf.forEach((r, i) => console.log(`  ${labels[i].padEnd(26)} median ${r.median.toFixed(4)}  p95 ${r.p95.toFixed(4)}  min ${r.min.toFixed(4)}`));
    if (opts['perf-json']) writeFileSync(resolve(opts['perf-json']), JSON.stringify({ device: perf.device, width: W, height: H, labels, perf: perf.perf }, null, 2) + '\n');
  });
} else if (METAL) {
  problems.push('Metal device check not run: MSL did not compile');
}

console.log(`${problems.length} problem(s)`);
for (const p of problems.slice(0, 20)) console.error(`  ${p}`);
process.exit(problems.length ? 2 : 0);

// Runs in the page: the WebGL2 harness. upload(textures, mips) binds photos 0..3, each
// { w, h, data } float RGBA; mips selects hardware filtering with a mip chain (a host's path)
// over nearest filtering at one level (the fetch path's inputs).
function harness(fs, W, H) {
  const canvas = document.createElement('canvas');
  canvas.width = W; canvas.height = H;
  const gl = canvas.getContext('webgl2', { antialias: false });
  if (!gl) return { fatal: 'no webgl2' };
  if (!gl.getExtension('EXT_color_buffer_float')) return { fatal: 'no EXT_color_buffer_float' };
  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl.VERTEX_SHADER, `#version 300 es
in vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }`));
  gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, fs));
  gl.bindAttribLocation(prog, 0, 'aPos');
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
  gl.useProgram(prog);
  ['uPhoto0', 'uPhoto1', 'uPhoto2', 'uPhoto3'].forEach((n, i) => gl.uniform1i(gl.getUniformLocation(prog, n), i));
  gl.uniformBlockBinding(prog, gl.getUniformBlockIndex(prog, 'SlideshowBlock'), 0);
  const ubo = gl.createBuffer();
  gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, ubo);
  const quad = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quad);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  const make = (img, mips) => {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, mips ? gl.RGBA16F : gl.RGBA32F, img.w, img.h, 0, gl.RGBA, gl.FLOAT, new Float32Array(img.data));
    if (mips) gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, mips ? gl.LINEAR_MIPMAP_LINEAR : gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, mips ? gl.LINEAR : gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return t;
  };
  const bind = ts => ts.forEach((t, i) => { gl.activeTexture(gl.TEXTURE0 + i); gl.bindTexture(gl.TEXTURE_2D, t); });
  const target = gl.createTexture();
  gl.activeTexture(gl.TEXTURE4);
  gl.bindTexture(gl.TEXTURE_2D, target);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, W, H, 0, gl.RGBA, gl.FLOAT, null);
  const fbo = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, target, 0);
  gl.viewport(0, 0, W, H);
  // Memory row j of the target is v = (j + 0.5) / H, as in the inputs: no flip anywhere.
  const draw = block => {
    gl.bufferData(gl.UNIFORM_BUFFER, new Float32Array(block), gl.DYNAMIC_DRAW);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    const px = new Float32Array(W * H * 4);
    gl.readPixels(0, 0, W, H, gl.RGBA, gl.FLOAT, px);
    return px;
  };
  // Named photo-like inputs, made once and cached, with mips.
  const named = {};
  const photo = name => (named[name] ??= make(makePhoto(name), true));
  const info = gl.getExtension('WEBGL_debug_renderer_info');
  return { gl, make, bind, draw, photo, renderer: info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER) };
}

// Runs in the page: named linear photos. Worst cases (black, white, a 16-texel checker, saturated
// red stripes) for the flash sequence; photo-like scenes for the review frames.
function makePhoto(name) {
  const dims = { portrait: [384, 512], portrait2: [338, 512], red: [384, 512], city: [640, 360] }[name] ?? [576, 384];
  const [w, h] = dims;
  const data = new Float32Array(w * h * 4);
  const lin = c => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const u = (x + 0.5) / w, v = (y + 0.5) / h, a = w / h;
    let c;
    if (name === 'black') c = [0, 0, 0];
    else if (name === 'white') c = [1, 1, 1];
    else if (name === 'checker') c = Array(3).fill(((x >> 4) + (y >> 4)) & 1);
    else if (name === 'red') c = ((y >> 4) & 1) ? [1, 0, 0] : [0.02, 0, 0];
    else if (name === 'landscape') {
      const hill = 0.62 + 0.06 * Math.sin(u * 7.0) + 0.03 * Math.sin(u * 23.0);
      const sun = Math.exp(-(((u - 0.72) * a) ** 2 + (v - 0.3) ** 2) / 0.003);
      if (v < hill) c = [lin(0.35 + 0.5 * v) + 2.5 * sun, lin(0.5 + 0.35 * v) + 2.2 * sun, lin(0.85 - 0.2 * v) + 1.6 * sun];
      else { const g = 0.5 + 0.5 * Math.sin(u * 140 + v * 30); c = [lin(0.18 + 0.05 * g), lin(0.32 + 0.08 * g), lin(0.12)]; }
    } else if (name === 'portrait' || name === 'portrait2') {
      const warm = name === 'portrait';
      const bg = warm ? [0.55, 0.45, 0.4] : [0.25, 0.35, 0.45];
      const face = Math.exp(-(((u - 0.5) * a / 0.75) ** 2 + ((v - 0.36) / 1.15) ** 2) / 0.03);
      const t = Math.min(Math.max((v - 0.6) / 0.25, 0), 1);
      const body = Math.exp(-(((u - 0.5) * a) ** 2) / 0.12) * t * t * (3 - 2 * t);
      const eye = Math.exp(-((((Math.abs(u - 0.5) - 0.09) * a) ** 2) + (v - 0.33) ** 2) / 0.0004);
      const skin = warm ? [0.92, 0.72, 0.6] : [0.75, 0.58, 0.48];
      const shirt = warm ? [0.2, 0.3, 0.6] : [0.7, 0.2, 0.25];
      c = [0, 1, 2].map(n => lin(Math.max(0, bg[n] * (1 - Math.max(face, body)) + skin[n] * face + shirt[n] * body * (1 - face) - 0.6 * eye)));
    } else {
      const col = Math.floor(u * 9), top = 0.25 + 0.45 * ((col * 7919) % 11) / 11;
      const win = (x % 12 < 6) && (y % 14 < 7) && ((x * 31 + y * 17) % 5 !== 0);
      c = v < top ? [lin(0.95), lin(0.6), lin(0.4)].map(k => k * (1 - v)) : (win ? [1.4, 1.1, 0.6] : [0.02, 0.025, 0.04]);
    }
    data.set([c[0], c[1], c[2], 1], (y * w + x) * 4);
  }
  return { w, h, data };
}

// Runs in the page: linear HDR to display bytes (ACES fitted tone map, sRGB encode).
function toBytes(px, W, H) {
  const aces = x => Math.min(Math.max((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0), 1);
  const srgb = c => Math.round(255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055));
  const out = new Uint8ClampedArray(W * H * 4);
  for (let k = 0; k < W * H; k++) {
    for (let c = 0; c < 3; c++) out[k * 4 + c] = srgb(aces(Math.max(px[k * 4 + c], 0)));
    out[k * 4 + 3] = 255;
  }
  return out;
}

function drawVectors({ fs, n, textures, blocks }) {
  const h = harness(fs, n, n);
  if (h.fatal) return h;
  h.bind(textures.map(t => h.make(t, false)));
  const pixels = [];
  for (const b of blocks) pixels.push(...h.draw(b));
  return { pixels, renderer: h.renderer };
}

function drawIdentity({ fs, W, H, pairs }) {
  const h = harness(fs, W, H);
  if (h.fatal) return h;
  let differ = 0;
  for (let k = 0; k < pairs.length; k += 2) {
    h.bind(pairs[k].photos.map(h.photo));
    const a = h.draw(pairs[k].block), b = h.draw(pairs[k + 1].block);
    for (let i = 0; i < a.length; i++) if (!Object.is(a[i], b[i])) { differ++; break; }
  }
  return { pairs: pairs.length / 2, differ };
}

function startSequence({ fs, W, H }) {
  window.seq = harness(fs, W, H);
  window.seqSize = [W, H];
  return window.seq.fatal ? { fatal: window.seq.fatal } : {};
}

function drawSequence(frames) {
  const h = window.seq, [W, H] = window.seqSize;
  if (h.fatal) return h;
  const out = [];
  for (const f of frames) {
    h.bind(f.photos.map(h.photo));
    const bytes = toBytes(h.draw(f.block), W, H);
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    out.push(btoa(s));
  }
  return { frames: out };
}

function drawSheet({ fs, W, H, frames }) {
  const h = harness(fs, W, H);
  if (h.fatal) return h;
  const COLS = 3, TOP = 18;
  const out = document.createElement('canvas');
  out.width = COLS * (W + 4); out.height = Math.ceil(frames.length / COLS) * (H + TOP + 4);
  const ctx = out.getContext('2d');
  ctx.fillStyle = '#111'; ctx.fillRect(0, 0, out.width, out.height);
  ctx.font = '12px sans-serif';
  frames.forEach((f, i) => {
    h.bind(f.photos.map(h.photo));
    const bytes = toBytes(h.draw(f.block), W, H);
    const x = (i % COLS) * (W + 4), y = Math.floor(i / COLS) * (H + TOP + 4);
    ctx.fillStyle = '#ddd'; ctx.fillText(f.label, x + 4, y + 13);
    // Row 0 of the target is the top of the picture.
    ctx.putImageData(new ImageData(bytes, W, H), x, y + TOP);
  });
  return { png: out.toDataURL('image/png') };
}
