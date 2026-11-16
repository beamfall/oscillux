// SPDX-License-Identifier: AGPL-3.0-only
// Switch-transition check (conformance/switch-transition/README.md): compiles the switch pass
// (tools/shader/switch.mjs over shaders/switch/switch.glsl) for WebGL2 and, on macOS, Metal,
// then draws every golden case of conformance/switch-transition/vectors.json under real WebGL2
// (SwiftShader via Playwright Chromium, as render.mjs does) and through the Metal device
// (switch-metal.swift), and compares each channel with the expected value within the file's
// tolerance. Exits 2 on any compile failure or mismatch.
//
//   node tools/shader/switch-transition-check.mjs [--strip out.png] [--perf] [--perf-json out.json]
//
// --strip writes a contact strip (one row per style, one column per p in vectors.json and 0.06, linear
// output through the ACES fitted tone map and sRGB encode) drawn by WebGL2 with hardware
// sampling. --perf times each style at 1920x1080 on the Metal device (median, p95 and min
// milliseconds per draw from command-buffer GPU times; see switch-metal.swift).
//
// The MSL is compared by its output, not its bytes, so any SPIRV-Cross on PATH serves (verify.mjs
// holds the pinned one). The Metal compile is the device's runtime compiler in switch-metal.swift;
// the offline AIR compile (xcrun metal) runs too when the Metal Toolchain is installed and is
// reported SKIPPED, never passed, when it is not.
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { withTempDir } from './glsl2msl.mjs';
import { SWITCH_FUNCTION, SWITCH_STYLES, switchBlock, switchGLSL300, switchMSL } from './switch.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const { values: opts } = parseArgs({
  options: {
    strip: { type: 'string', default: '' },
    perf: { type: 'boolean', default: false },
    'perf-json': { type: 'string', default: '' },
  },
});
const V = JSON.parse(readFileSync(join(ROOT, 'conformance', 'switch-transition', 'vectors.json'), 'utf8'));
const N = V.size;
const CACHE = join(ROOT, 'out', 'cache', 'metal-module-cache');
const METAL = process.platform === 'darwin';
const problems = [];

if (JSON.stringify(V.styles) !== JSON.stringify(SWITCH_STYLES)) problems.push('vectors.json styles differ from switch.mjs');
const blocks = V.cases.map(c => switchBlock({ ...c, style: c.styleId, width: N, height: N }));
const flat = img => new Float32Array(img.flatMap(([r, g, b]) => [r, g, b, 1]));

// Offline compiles: ES 3.00 through glslangValidator for both samplings; on macOS GLSL 450 to
// SPIR-V, SPIRV-Cross to MSL with the ABI checked, and the Metal compiler to AIR when present.
const msl = {};
withTempDir('switch-check', dir => {
  for (const sampling of ['fetch', 'linear']) {
    const es = join(dir, `switch-${sampling}.frag`);
    writeFileSync(es, switchGLSL300({ sampling }));
    try { execFileSync('glslangValidator', ['-S', 'frag', es], { stdio: 'pipe' }); }
    catch (e) { problems.push(`GLSL ES 3.00 (${sampling}): ${(e.stdout || e.message).toString().slice(0, 800)}`); }
  }
  console.log('compiled: GLSL ES 3.00 (glslangValidator), fetch and linear sampling');
  if (!METAL) { console.log('Metal legs skipped: requires macOS'); return; }
  for (const sampling of ['fetch', 'linear']) {
    try { msl[sampling] = switchMSL({ sampling }); }
    catch (e) { problems.push(`GLSL 450 -> MSL (${sampling}): ${(e.stderr || e.message).toString().slice(0, 800)}`); }
  }
  console.log('compiled: GLSL 450 -> SPIR-V -> MSL (glslangValidator + SPIRV-Cross), ABI checked');
  for (const [sampling, src] of Object.entries(msl)) {
    const file = join(dir, `switch-${sampling}.metal`);
    writeFileSync(file, src);
    try {
      execFileSync('xcrun', ['metal', `-fmodules-cache-path=${CACHE}`, '-c', file, '-o', join(dir, `switch-${sampling}.air`)], { stdio: 'pipe' });
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
      if (!(d <= worst)) { worst = d; at = `${c.style} p=${c.p} motion=${c.motion} px=${i % N},${Math.floor(i / N)} ch=${ch}`; }
    }
  });
  console.log(`${label}: ${V.cases.length} cases x ${N}x${N}, max |diff| ${worst.toExponential(3)} (tolerance ${V.tolerance})` +
    `${bad ? `, ${bad} channel(s) out of tolerance, worst at ${at}` : ''}`);
  if (bad) problems.push(`${label}: ${bad} channel(s) out of tolerance, worst ${worst} at ${at}`);
  return worst;
}

// WebGL2 (SwiftShader): the golden cases, then the optional contact strip.
const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader'] });
const page = await browser.newPage();
page.on('console', m => { if (m.type() === 'error') console.error('[page]', m.text().slice(0, 400)); });
await page.addScriptTag({ content: harness.toString() });
const web = await page.evaluate(drawVectors, {
  fs: switchGLSL300({ sampling: 'fetch' }), n: N,
  textures: ['from', 'to', 'photo'].map(k => Array.from(flat(V[k]))), blocks: blocks.map(b => Array.from(b)),
});
if (web.fatal) { console.error(web.fatal); process.exit(1); }
console.log(`WebGL2 renderer: ${web.renderer}`);
compare('WebGL2 vs vectors.json', web.pixels);

if (opts.strip) {
  const W = 240, H = 135;
  const params = V.cases[0];
  // The vectors' p values plus 0.06, where the light leak peaks.
  const progress = [0, 0.06, ...V.progress.slice(1)];
  const strip = await page.evaluate(drawStrip, {
    fs: switchGLSL300({ sampling: 'linear' }), W, H, styles: SWITCH_STYLES, progress,
    blocks: SWITCH_STYLES.flatMap((style, s) => progress.map(p => Array.from(switchBlock({
      ...params, p, style: s, aspect: W / H, width: W, height: H,
    })))),
  });
  if (strip.fatal) { console.error(strip.fatal); process.exit(1); }
  writeFileSync(resolve(opts.strip), Buffer.from(strip.png.split(',')[1], 'base64'));
  console.log(`contact strip: ${resolve(opts.strip)} (motion ${params.motion}, energy ${params.energy}, focus ${params.focus}, beatPhase ${params.beatPhase})`);
}
await browser.close();

// Metal device: the golden cases through the fetch pass, and the optional 1080p timings.
if (METAL && msl.fetch && msl.linear) {
  withTempDir('switch-metal', dir => {
    const paths = ['from', 'to', 'photo'].map(k => {
      const p = join(dir, `${k}.f32`);
      writeFileSync(p, Buffer.from(flat(V[k]).buffer));
      return p;
    });
    writeFileSync(join(dir, 'fetch.metal'), msl.fetch);
    const hex = b => Buffer.from(b.buffer).toString('hex');
    const cfg = join(dir, 'vectors.json');
    const out = join(dir, 'out.f32');
    writeFileSync(cfg, JSON.stringify({
      metal: join(dir, 'fetch.metal'), function: SWITCH_FUNCTION,
      vectors: { size: N, from: paths[0], to: paths[1], photo: paths[2], blocks: blocks.map(hex), out },
    }));
    let reply;
    try { reply = JSON.parse(execFileSync('swift', [join(HERE, 'switch-metal.swift'), cfg], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })); }
    catch (e) { problems.push(`Metal device compile/draw: ${(e.stderr || e.message).toString().slice(0, 800)}`); return; }
    if (reply.skipped) { console.log(`Metal device: SKIPPED (${reply.skipped})`); return; }
    console.log(`Metal device: ${reply.device} (runtime MSL compile ok)`);
    const buf = readFileSync(out);
    compare('Metal vs vectors.json', new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4));

    if (!opts.perf) return;
    writeFileSync(join(dir, 'linear.metal'), msl.linear);
    const W = 1920, H = 1080;
    const params = V.cases[0];
    writeFileSync(cfg, JSON.stringify({
      metal: join(dir, 'linear.metal'), function: SWITCH_FUNCTION,
      perf: {
        width: W, height: H, draws: 20, samples: 40, warmup: 5,
        blocks: SWITCH_STYLES.map((style, s) => hex(switchBlock({ ...params, p: 0.5, style: s, aspect: W / H, width: W, height: H }))),
      },
    }));
    const perf = JSON.parse(execFileSync('swift', [join(HERE, 'switch-metal.swift'), cfg], { encoding: 'utf8' }));
    console.log(`perf: ${perf.device}, ${W}x${H} rgba16Float target, three rgba16Float inputs, linear sampler, p=0.5, ` +
      'motion 1; ms per draw over 40 command buffers of 20 draws (GPU start/end times)');
    perf.perf.forEach((r, s) => console.log(`  ${SWITCH_STYLES[s].padEnd(22)} median ${r.median.toFixed(4)}  p95 ${r.p95.toFixed(4)}  min ${r.min.toFixed(4)}`));
    if (opts['perf-json']) writeFileSync(resolve(opts['perf-json']), JSON.stringify({ device: perf.device, width: W, height: H, styles: SWITCH_STYLES, perf: perf.perf }, null, 2) + '\n');
  });
} else if (METAL) {
  problems.push('Metal device check not run: MSL did not compile');
}

console.log(`${problems.length} problem(s)`);
for (const p of problems.slice(0, 20)) console.error(`  ${p}`);
process.exit(problems.length ? 2 : 0);

// Runs in the page: the WebGL2 harness shared by drawVectors and drawStrip.
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
  ['uFrom', 'uTo', 'uPhoto'].forEach((n, i) => gl.uniform1i(gl.getUniformLocation(prog, n), i));
  gl.uniformBlockBinding(prog, gl.getUniformBlockIndex(prog, 'SwitchBlock'), 0);
  const ubo = gl.createBuffer();
  gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, ubo);
  const quad = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quad);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  const inputs = (images, filter) => images.forEach((data, i) => {
    const t = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0 + i);
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, filter === gl.LINEAR ? gl.RGBA16F : gl.RGBA32F, W, H, 0, gl.RGBA, gl.FLOAT, new Float32Array(data));
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  });
  const target = gl.createTexture();
  gl.activeTexture(gl.TEXTURE3);
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
  const info = gl.getExtension('WEBGL_debug_renderer_info');
  return { gl, inputs, draw, renderer: info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER) };
}

function drawVectors({ fs, n, textures, blocks }) {
  const h = harness(fs, n, n);
  if (h.fatal) return h;
  h.inputs(textures, h.gl.NEAREST);
  const pixels = [];
  for (const b of blocks) pixels.push(...h.draw(b));
  return { pixels, renderer: h.renderer };
}

function drawStrip({ fs, W, H, styles, progress, blocks }) {
  // Strip inputs, linear HDR: a warm ringed outgoing visual with a hot sun, a cool banded incoming
  // visual with a highlight, and a soft portrait-like photo.
  const from = [], to = [], photo = [];
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const u = x / W, v = y / H, a = W / H;
    const r = Math.hypot((u - 0.35) * a, v - 0.55);
    const ring = 0.5 + 0.5 * Math.cos(r * 38);
    const sun = Math.exp(-(((u - 0.3) * a) ** 2 + (v - 0.35) ** 2) / 0.004) * 3;
    from.push(0.55 * ring + 0.05 + sun, 0.18 * ring + 0.03 + sun * 0.8, 0.22 * (1 - ring) + 0.02 + sun * 0.5, 1);
    const band = 0.5 + 0.5 * Math.sin((u * a + v) * 22);
    const hi = Math.exp(-(((u - 0.72) * a) ** 2 + (v - 0.3) ** 2) / 0.006) * 4;
    to.push(0.02 + 0.06 * band + hi, 0.12 + 0.3 * band * v + hi, 0.35 + 0.4 * band + hi, 1);
    const face = Math.exp(-(((u - 0.5) * a / 0.8) ** 2 + ((v - 0.45) / 1.1) ** 2) / 0.05);
    const t = Math.min(Math.max((v - 0.62) / 0.3, 0), 1);
    const shoulders = Math.exp(-(((u - 0.5) * a) ** 2) / 0.25) * 0.5 * t * t * (3 - 2 * t);
    const lum = Math.max(face, shoulders) * 0.9;
    photo.push(lum, lum * 0.78, lum * 0.66, 1);
  }
  const h = harness(fs, W, H);
  if (h.fatal) return h;
  h.inputs([from, to, photo], h.gl.LINEAR);
  const LABEL = 150, TOP = 22;
  const out = document.createElement('canvas');
  out.width = LABEL + progress.length * (W + 4); out.height = TOP + styles.length * (H + 4);
  const ctx = out.getContext('2d');
  ctx.fillStyle = '#111'; ctx.fillRect(0, 0, out.width, out.height);
  ctx.fillStyle = '#ddd'; ctx.font = '13px sans-serif';
  progress.forEach((p, i) => ctx.fillText(`p = ${p}`, LABEL + i * (W + 4) + 4, 15));
  const aces = x => Math.min(Math.max((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0), 1);
  const srgb = c => Math.round(255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055));
  styles.forEach((style, s) => {
    ctx.fillStyle = '#ddd';
    ctx.fillText(style, 6, TOP + s * (H + 4) + H / 2);
    progress.forEach((p, i) => {
      const px = h.draw(blocks[s * progress.length + i]);
      const img = new ImageData(W, H);
      for (let k = 0; k < W * H; k++) {
        for (let c = 0; c < 3; c++) img.data[k * 4 + c] = srgb(aces(Math.max(px[k * 4 + c], 0)));
        img.data[k * 4 + 3] = 255;
      }
      ctx.putImageData(img, LABEL + i * (W + 4), TOP + s * (H + 4));
    });
  });
  return { png: out.toDataURL('image/png') };
}
