// SPDX-License-Identifier: AGPL-3.0-only
// CD+G composite check (OSC-CDG): compiles shaders/cdg/cdg-composite.glsl for WebGL2 and (on
// macOS) Metal, then renders every bundled "web" visual for N frames under real WebGL2
// (SwiftShader via Playwright Chromium, as render.mjs does) and composites the oracle's lyric
// screen over each frame. On the 8-bit composited output it measures the WCAG contrast of every
// opaque lyric pixel against each keyed (alpha 0) pixel it touches, 8-neighbourhood, in doubles.
//
//   node tools/shader/cdg-check.mjs [manifest.json ...] [--out out/cdg-check] [--frames 96]
//        [--only id1,id2] [--target 4.5]
//
// Placements (contain 3:2, contain 4:3, cover 4:3, stretch, integer contain) and lyric screens
// cycle per frame. The screens come from `tools/cdg-vectors.py --window NAME KEY` and must match
// their conformance/cdg vectors: the lyrics stream under its transparent-colour table, and the two
// downloaded-karaoke screens (OSC-CDG-DOWNLOADS) under the mask the hosts' auto key picks for
// them, each mid-wipe (white or blue lyrics with a dark outline, partly sung in a wipe colour) on a
// blue or tiled background. A synthetic flash-stress visual (full white, yellow, cyan, HDR white,
// black, saturated blue and per-pixel noise, a new one each frame) runs with the bundled ones.
// Each visual's last frame is also composited, per screen, without the halo (to show the halo is
// what meets the bar) and with an all-transparent window, which must equal the plain tone-mapped
// visual exactly. Exits 2 on any compile failure, missed contrast or keyed-pixel mismatch.
import { chromium } from 'playwright';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { assertShaderToolchain, withTempDir } from './glsl2msl.mjs';
import { loadManifest } from './manifest.mjs';
import { audioAt } from './synthetic-audio.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    out: { type: 'string', default: '' },
    frames: { type: 'string', default: '96' },
    only: { type: 'string', default: '' },
    target: { type: 'string', default: '4.5' },
  },
});
const MANIFESTS = positionals.length
  ? positionals
  : [join(ROOT, 'shaders', 'originals', 'manifest.json'), join(ROOT, 'shaders', 'manifest.json')];
const OUT = opts.out ? resolve(opts.out) : join(ROOT, 'out', 'cdg-check');
const CACHE = join(ROOT, 'out', 'cache', 'metal-module-cache');
const FRAMES = parseInt(opts.frames, 10);
const ONLY = opts.only.split(',').filter(Boolean);
const TARGET = Number(opts.target);
const W = 480, H = 270;
const WIN_W = 288, WIN_H = 192;
const FEATHER = 3;
const PLACEMENTS = [
  { name: 'contain 3:2', place: [0, 1.5, 0, 0] },
  { name: 'contain 4:3', place: [0, 4 / 3, 0, 0] },
  { name: 'cover 4:3', place: [1, 4 / 3, 0, 0] },
  { name: 'stretch', place: [2, 1.5, 0, 0] },
  { name: 'contain 3:2 integer', place: [0, 1.5, 1, 0] },
];
const COMPOSITE = readFileSync(join(ROOT, 'shaders', 'cdg', 'cdg-composite.glsl'), 'utf8');

mkdirSync(OUT, { recursive: true });
const problems = [];

// The oracle's final window of each stream under its key, checked against the committed vector so
// the screen measured here is the specified one.
const SCREENS = [
  { name: 'lyrics', key: 'table' },
  { name: 'karaoke-blue', key: 'mask:0002' },
  { name: 'karaoke-tiles', key: 'mask:0006' },
].map(({ name, key }) => {
  const bytes = execFileSync('python3', ['-I', join(ROOT, 'tools', 'cdg-vectors.py'), '--window', name, key],
    { maxBuffer: 1 << 22 });
  const expected = readFileSync(join(ROOT, 'conformance', 'cdg', `${name}.expect`), 'utf8')
    .split('\n').filter(l => l.startsWith('rgba ') && l.split(' ')[2] === key).at(-1)?.split(' ')[3];
  const digest = createHash('sha256').update(bytes).digest('hex');
  if (bytes.length !== WIN_W * WIN_H * 4 || digest !== expected) {
    console.error(`${name} ${key} window ${bytes.length} bytes sha256 ${digest} does not match ${name}.expect ${expected}`);
    process.exit(2);
  }
  return { label: `${name} ${key}`, bytes: bytes.toString('base64') };
});

// Seven states a frame, so every state meets every screen and placement: the brightest, most
// saturated and darkest backgrounds a visual can put behind the lyrics, then noise.
const FLASH_STRESS = `vec3 visual(vec2 uv, VisualUniforms u) {
  int state = int(floor(u.time * 60.0 + 0.5)) % 7;
  if (state == 0) return vec3(1.0);
  if (state == 1) return vec3(1.0, 1.0, 0.0);
  if (state == 2) return vec3(0.0, 1.0, 1.0);
  if (state == 3) return vec3(16.0);
  if (state == 4) return vec3(0.0);
  if (state == 5) return vec3(0.0, 0.0, 1.0);
  uvec2 cell = uvec2(uv * u.resolution) + uint(state) * floatBitsToUint(u.time);
  uint h = cell.x ^ (cell.y * 0xa7d471dbu);
  h ^= h >> 16u; h *= 0xa7d471dbu; h ^= h >> 14u; h *= 0x76a997d3u; h ^= h >> 16u;
  return vec3(float(h >> 31u));
}
`;

// The present-pass stand-ins. ES 3.00 for WebGL2; GLSL 450 with explicit bindings for SPIR-V,
// spirv-cross and the Metal compiler.
const ES_PASS = `#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
uniform sampler2D uVisual;
uniform sampler2D uCdg;
uniform vec4 uPlace;
uniform vec4 uHalo;
uniform vec2 uSize;
in vec2 vUV;
out vec4 o;
#define OSC_CDG_FETCH(cell) texelFetch(uCdg, cell, 0)
vec3 tm2(vec3 x){x=(x*(2.51*x+.03))/(x*(2.43*x+.59)+.14);return pow(clamp(x,0.,1.),vec3(1./2.2));}
${COMPOSITE}
void main() {
  vec2 frag = vec2(gl_FragCoord.x, uSize.y - gl_FragCoord.y);
  o = oscCdgComposite(tm2(texture(uVisual, vUV).rgb), frag, uSize, uPlace, uHalo);
}
`;
const VK_PASS = `#version 450
layout(binding = 0) uniform sampler2D uVisual;
layout(binding = 1) uniform sampler2D uCdg;
layout(std140, binding = 2) uniform CdgPresent { vec4 place; vec4 halo; vec4 size; } P;
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 o;
#define OSC_CDG_FETCH(cell) texelFetch(uCdg, cell, 0)
${COMPOSITE}
void main() {
  o = oscCdgComposite(texture(uVisual, vUV).rgb, gl_FragCoord.xy, P.size.xy, P.place, P.halo);
}
`;
offlineCompile();

const sets = MANIFESTS.map(path => {
  const manifest = loadManifest(path);
  const visuals = manifest.byTarget.web.filter(v => !ONLY.length || ONLY.includes(v.id)).map(v => ({
    id: v.id,
    fragment: manifest.wrapper.wrapGLSL300(v.body, v.imageInput),
    palette: v.palette,
    params: v.params,
    trailDecay: v.trailDecay,
  }));
  return { path, vertex: manifest.wrapper.VERTEX_300, visuals, wrapper: manifest.wrapper };
});
if (!ONLY.length || ONLY.includes('flash-stress')) {
  sets[0].visuals.push({
    id: 'flash-stress', fragment: sets[0].wrapper.wrapGLSL300(FLASH_STRESS, true),
    palette: [0, 0, 0, 0], params: [0, 0, 0], trailDecay: 0,
  });
}
for (const set of sets) delete set.wrapper;
const known = new Set(['flash-stress', ...sets.flatMap(s => s.visuals.map(v => v.id))]);
const unknown = ONLY.filter(id => !known.has(id));
if (unknown.length) throw new Error(`unknown --only visual id(s): ${unknown.join(', ')}`);

const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader', '--mute-audio'] });
const page = await browser.newPage();
page.on('console', m => { if (m.type() === 'error') console.error('[page]', m.text().slice(0, 400)); });
await page.addScriptTag({ content: `window.__audioAt = ${audioAt.toString()};` });

const results = [];
for (const set of sets) {
  const r = await page.evaluate(run, {
    set, W, H, FRAMES, TARGET, FEATHER, WIN_W, WIN_H,
    placements: PLACEMENTS.map(p => p.place), esPass: ES_PASS, screens: SCREENS.map(s => s.bytes),
  });
  if (r.fatal) { console.error(r.fatal); process.exit(1); }
  for (const [id, dataUrl] of Object.entries(r.shots)) {
    writeFileSync(join(OUT, `${id}.png`), Buffer.from(dataUrl.split(',')[1], 'base64'));
  }
  results.push(...r.results);
}
await browser.close();
writeFileSync(join(OUT, 'stats.json'), JSON.stringify(results, null, 2));

let edges = 0, lyricPixels = 0, interior = 0, worst = Infinity, worstAt = '';
let unhaloFails = 0, unhaloWorst = Infinity;
const perScreen = SCREENS.map(s => ({ label: s.label, min: Infinity, at: '', edges: 0, fails: 0, unhaloMin: Infinity, unhaloFails: 0 }));
for (const r of results) {
  if (r.error) {
    problems.push(`${r.id}: ${r.error.split('\n')[0]}`);
    console.log(`${r.id.padEnd(24)} COMPILE-FAIL ${r.error.split('\n')[0]}`);
    continue;
  }
  edges += r.edges; lyricPixels += r.lyricPixels; interior += r.interior;
  unhaloFails += r.unhalo.fails; unhaloWorst = Math.min(unhaloWorst, r.unhalo.min);
  const at = fr => `${r.id} frame ${fr} (${PLACEMENTS[fr % PLACEMENTS.length].name}, ${SCREENS[fr % SCREENS.length].label})`;
  if (r.min < worst) { worst = r.min; worstAt = at(r.minFrame); }
  r.screens.forEach((m, k) => {
    const s = perScreen[k];
    s.edges += m.edges; s.fails += m.fails;
    s.unhaloMin = Math.min(s.unhaloMin, m.unhalo.min); s.unhaloFails += m.unhalo.fails;
    if (m.min < s.min) { s.min = m.min; s.at = at(m.minFrame); }
  });
  const flag = r.fails ? 'CONTRAST-FAIL' : r.keyedMismatch ? 'KEY-MISMATCH' : r.edges === 0 ? 'NO-EDGES' : 'ok';
  if (flag !== 'ok') problems.push(`${r.id}: ${flag} fails=${r.fails} keyed=${r.keyedMismatch}`);
  console.log(`${r.id.padEnd(24)} ${flag.padEnd(13)} min=${r.min.toFixed(3)} edges=${r.edges} fails=${r.fails} ` +
    `unhaloed min=${r.unhalo.min.toFixed(3)} fails=${r.unhalo.fails}`);
}
console.log(`\n${results.length} visuals x ${FRAMES} frames at ${W}x${H}, target ${TARGET}:1`);
console.log(`  lyric pixels ${lyricPixels}, measured edge pixels ${edges}, interior (no keyed neighbour) ${interior}`);
console.log(`  minimum contrast ${worst.toFixed(4)}:1 at ${worstAt}`);
console.log(`  last frames without the halo: minimum ${unhaloWorst.toFixed(4)}:1, ${unhaloFails} edge pixels below target`);
for (const s of perScreen) {
  console.log(`  ${s.label.padEnd(24)} min ${s.min.toFixed(4)}:1 at ${s.at}; edges ${s.edges}, fails ${s.fails}; ` +
    `without the halo min ${s.unhaloMin.toFixed(4)}:1, ${s.unhaloFails} below`);
}
console.log(`${problems.length} problem(s). PNGs and stats.json in ${OUT}`);
for (const p of problems.slice(0, 20)) console.error(`  ${p}`);
process.exit(problems.length ? 2 : 0);

// Compiles both passes offline: ES 3.00 through glslangValidator, and on macOS GLSL 450 to SPIR-V,
// spirv-cross to MSL and the Metal compiler to AIR. The MSL is kept in OUT for inspection.
function offlineCompile() {
  const metal = process.platform === 'darwin';
  if (metal) assertShaderToolchain();
  withTempDir('cdg', dir => {
    const step = (label, cmd, args) => {
      try { execFileSync(cmd, args, { stdio: 'pipe' }); }
      catch (e) {
        problems.push(`${label}: ${(e.stdout || '').toString()}${(e.stderr || e.message).toString()}`.slice(0, 800));
        return false;
      }
      return true;
    };
    const es = join(dir, 'cdg-present.frag');
    writeFileSync(es, ES_PASS);
    if (step('GLSL ES 3.00', 'glslangValidator', ['-S', 'frag', es])) console.log('compiled: GLSL ES 3.00 (glslangValidator)');
    if (!metal) { console.log('Metal compile skipped: requires macOS'); return; }
    const vk = join(dir, 'cdg-present.vk.frag');
    const spv = join(dir, 'cdg-present.spv');
    const msl = join(OUT, 'cdg-present.metal');
    writeFileSync(vk, VK_PASS);
    mkdirSync(CACHE, { recursive: true });
    if (step('GLSL 450', 'glslangValidator', ['-V', '--target-env', 'vulkan1.0', '-S', 'frag', '-e', 'main', vk, '-o', spv])
      && step('spirv-cross', 'spirv-cross', ['--msl', '--msl-decoration-binding', '--rename-entry-point', 'main', 'oscCdgPresent', 'frag', spv, '--output', msl])
      && step('xcrun metal', 'xcrun', ['metal', `-fmodules-cache-path=${CACHE}`, '-c', msl, '-o', join(dir, 'cdg-present.air')])) {
      console.log(`compiled: GLSL 450 -> SPIR-V -> MSL -> AIR (${msl})`);
    }
  });
}

// Runs in the page: renders one manifest's visuals, composites, measures.
async function run({ set, W, H, FRAMES, TARGET, FEATHER, WIN_W, WIN_H, placements, esPass, screens }) {
  const audioAt = window.__audioAt;
  const canvas = document.createElement('canvas');
  canvas.width = W; canvas.height = H;
  const gl = canvas.getContext('webgl2', { antialias: false });
  if (!gl) return { fatal: 'no webgl2' };
  if (!gl.getExtension('EXT_color_buffer_float')) return { fatal: 'no EXT_color_buffer_float' };

  const quad = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quad);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  function compile(type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }
  function link(vs, fsSrc) {
    const p = gl.createProgram();
    gl.attachShader(p, vs); gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fsSrc));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    return p;
  }
  function draw(prog, fbo) {
    gl.useProgram(prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.viewport(0, 0, W, H);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
  const vs = compile(gl.VERTEX_SHADER, set.vertex);
  // As in render.mjs: offscreen visual passes store texel row v == vUV.y.
  const vsFbo = compile(gl.VERTEX_SHADER,
    set.vertex.replace('gl_Position = vec4(aPos, 0.0, 1.0);', 'gl_Position = vec4(aPos.x, -aPos.y, 0.0, 1.0);'));

  function texture(internal, w, h, format, type, data, filter) {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, internal, w, h, 0, format, type, data);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return t;
  }
  function target(internal, type) {
    const t = texture(internal, W, H, gl.RGBA, type, null, gl.LINEAR);
    const f = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, f);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
    return { t, f };
  }
  // The render harness's gradient artwork stand-in.
  const ipix = new Uint8Array(64 * 64 * 4);
  for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) {
    const i = (y * 64 + x) * 4;
    ipix[i] = 40 + x * 2.5; ipix[i + 1] = 30 + y * 1.8; ipix[i + 2] = 120 + ((x + y) & 15) * 6; ipix[i + 3] = 255;
  }
  const imgTex = texture(gl.RGBA, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, ipix, gl.LINEAR);
  const screenTex = screens.map(b64 => texture(gl.RGBA8, WIN_W, WIN_H, gl.RGBA, gl.UNSIGNED_BYTE,
    Uint8Array.from(atob(b64), c => c.charCodeAt(0)), gl.NEAREST));
  const clearTex = texture(gl.RGBA8, WIN_W, WIN_H, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(WIN_W * WIN_H * 4), gl.NEAREST);
  const out8 = target(gl.RGBA8, gl.UNSIGNED_BYTE);
  const plain8 = target(gl.RGBA8, gl.UNSIGNED_BYTE);

  const comp = link(vs, esPass);
  const CU = n => gl.getUniformLocation(comp, n);
  gl.useProgram(comp);
  gl.uniform1i(CU('uVisual'), 0); gl.uniform1i(CU('uCdg'), 1); gl.uniform2f(CU('uSize'), W, H);
  const blit = link(vs, `#version 300 es
precision highp float; uniform sampler2D uT; in vec2 vUV; out vec4 o;
vec3 tm2(vec3 x){x=(x*(2.51*x+.03))/(x*(2.43*x+.59)+.14);return pow(clamp(x,0.,1.),vec3(1./2.2));}
void main(){ o=vec4(tm2(texture(uT,vUV).rgb),1.); }`);
  gl.useProgram(blit);
  gl.uniform1i(gl.getUniformLocation(blit, 'uT'), 0);

  const px = new Uint8Array(W * H * 4);
  function composite(visual, cdg, place, haloOn) {
    gl.useProgram(comp);
    gl.uniform4f(CU('uPlace'), ...place);
    gl.uniform4f(CU('uHalo'), TARGET, FEATHER, haloOn ? 1 : 0, 0);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, visual);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, cdg);
    draw(comp, out8.f);
    gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, px);
    return px;
  }

  // WCAG relative luminance of 8-bit sRGB, per code value.
  const lin = new Float64Array(256);
  for (let c = 0; c < 256; c++) { const s = c / 255; lin[c] = s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4; }
  const lum = (p, i) => 0.2126 * lin[p[i]] + 0.7152 * lin[p[i + 1]] + 0.0722 * lin[p[i + 2]];
  // Every opaque lyric pixel against every keyed pixel among its 8 neighbours.
  function measure(p) {
    const m = { min: Infinity, edges: 0, fails: 0, lyricPixels: 0, interior: 0 };
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      if (p[i + 3] !== 255) continue;
      m.lyricPixels++;
      const l = lum(p, i);
      let worst = Infinity;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const nx = x + dx, ny = y + dy;
        if ((dx | dy) === 0 || nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
        const j = (ny * W + nx) * 4;
        if (p[j + 3] !== 0) continue;
        const b = lum(p, j);
        worst = Math.min(worst, (Math.max(l, b) + 0.05) / (Math.min(l, b) + 0.05));
      }
      if (worst === Infinity) { m.interior++; continue; }
      m.edges++;
      if (worst < TARGET) m.fails++;
      m.min = Math.min(m.min, worst);
    }
    return m;
  }

  const results = [];
  const shots = {};
  for (const v of set.visuals) {
    const entry = { id: v.id, error: null, min: Infinity, minFrame: -1, edges: 0, fails: 0, lyricPixels: 0, interior: 0,
      screens: screens.map(() => ({ min: Infinity, minFrame: -1, edges: 0, fails: 0 })) };
    let prog;
    try { prog = link(vsFbo, v.fragment); }
    catch (e) { entry.error = String(e.message || e).slice(0, 600); results.push(entry); continue; }
    gl.useProgram(prog);
    const U = n => gl.getUniformLocation(prog, n);
    gl.uniform2f(U('u.resolution'), W, H);
    gl.uniform1f(U('u.sensitivity'), 1);
    gl.uniform1f(U('u.param0'), v.params[0]); gl.uniform1f(U('u.param1'), v.params[1]); gl.uniform1f(U('u.param2'), v.params[2]);
    gl.uniform1f(U('u.trailDecay'), v.trailDecay);
    gl.uniform4f(U('u.accent'), 0.15, 0.9, 0.72, 1);
    gl.uniform4f(U('u.motion'), 0, 0, 0, 0);
    gl.uniform4f(U('u.palette'), ...v.palette);
    gl.uniform4f(U('u.presentation0'), 0, 1, 0, 0);
    gl.uniform4f(U('u.presentation1'), 1, 0, 0, 0);
    gl.uniform4f(U('u.safeRect'), 0.05, 0.05, 0.05, 0.05);
    gl.uniform1i(U('uImage'), 0);
    gl.uniform1i(U('uPrev'), 1);
    let a = target(gl.RGBA16F, gl.HALF_FLOAT), b = target(gl.RGBA16F, gl.HALF_FLOAT);
    for (const rt of [a, b]) { gl.bindFramebuffer(gl.FRAMEBUFFER, rt.f); gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT); }
    const dt = 1 / 60;
    for (let fr = 0; fr < FRAMES; fr++) {
      const tm = fr * dt;
      const au = audioAt(tm);
      gl.useProgram(prog);
      gl.uniform1f(U('u.time'), tm); gl.uniform1f(U('u.dt'), dt);
      for (const k of ['amplitude', 'bass', 'mid', 'treble', 'beat', 'beatPhase', 'onset', 'bassImpact', 'level', 'spectralCentroid', 'flux', 'beatCount'])
        gl.uniform1f(U('u.' + k), au[k]);
      gl.uniform4fv(U('u.spectrum[0]'), new Float32Array(au.spectrum));
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, imgTex);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, a.t);
      draw(prog, b.f);
      [a, b] = [b, a];

      const k = fr % screens.length;
      const m = measure(composite(a.t, screenTex[k], placements[fr % placements.length], true));
      entry.edges += m.edges; entry.fails += m.fails; entry.lyricPixels += m.lyricPixels; entry.interior += m.interior;
      if (m.min < entry.min) { entry.min = m.min; entry.minFrame = fr; }
      const sm = entry.screens[k];
      sm.edges += m.edges; sm.fails += m.fails;
      if (m.min < sm.min) { sm.min = m.min; sm.minFrame = fr; }
    }
    // Last frame: each screen without the halo, and nothing to show (all keyed).
    const last = placements[(FRAMES - 1) % placements.length];
    const shot = new Uint8ClampedArray(composite(a.t, screenTex[(FRAMES - 1) % screens.length], last, true));
    entry.unhalo = { min: Infinity, fails: 0, edges: 0 };
    screenTex.forEach((t, k) => {
      const um = measure(composite(a.t, t, last, false));
      entry.screens[k].unhalo = { min: um.min, fails: um.fails };
      entry.unhalo.min = Math.min(entry.unhalo.min, um.min); entry.unhalo.fails += um.fails; entry.unhalo.edges += um.edges;
    });
    const keyed = new Uint8Array(composite(a.t, clearTex, last, true));
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, a.t);
    draw(blit, plain8.f);
    const plain = new Uint8Array(W * H * 4);
    gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, plain);
    entry.keyedMismatch = 0;
    for (let i = 0; i < plain.length; i += 4) {
      if (keyed[i] !== plain[i] || keyed[i + 1] !== plain[i + 1] || keyed[i + 2] !== plain[i + 2] || keyed[i + 3] !== 0) entry.keyedMismatch++;
    }
    // Contrast is measured on bytes, so the PNG is the measured image (rows flipped to top-down).
    const img = new ImageData(W, H);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const s = ((H - 1 - y) * W + x) * 4, d = (y * W + x) * 4;
      img.data[d] = shot[s]; img.data[d + 1] = shot[s + 1]; img.data[d + 2] = shot[s + 2]; img.data[d + 3] = 255;
    }
    const c2 = document.createElement('canvas');
    c2.width = W; c2.height = H;
    c2.getContext('2d').putImageData(img, 0, 0);
    shots[v.id] = c2.toDataURL('image/png');
    results.push(entry);
    gl.deleteProgram(prog);
    for (const rt of [a, b]) { gl.deleteTexture(rt.t); gl.deleteFramebuffer(rt.f); }
  }
  return { results, shots };
}
