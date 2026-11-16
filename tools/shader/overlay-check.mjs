// SPDX-License-Identifier: AGPL-3.0-only
// Overlay check (OSC-OVERLAY): measures the shared present pass (shaders/present/present.glsl)
// as the reference hosts draw it, over every bundled visual.
//
//   node tools/shader/overlay-check.mjs [--bundle out/hosts/visuals.json] [--frames 96]
//        [--only id1,id2] [--out out/overlay-check] [--evidence DIR] [--parity N] [--preset NAME]
//
// 1. Packs every case of conformance/packing/overlay-uniforms.json with hosts/web/overlay.js
//    packOverlay and compares the bytes (or the refusal) with the vectors.
// 2. Renders each bundled visual, and a synthetic strobe of full-frame HDR white and saturated
//    red flashes, for --frames frames at 480x270 under WebGL2 (SwiftShader via Playwright
//    Chromium) with the synthetic audio and a fixed 1/60 s step, and presents every frame three
//    ways: with a fixed region set (a light-text caption, a dark-text badge and a light-text
//    menu bar), with no regions, and with no regions under reduced motion. Each run keeps its
//    own history, as a host does. On the 8-bit output it measures, per visual:
//      - the highest relative luminance of any pixel inside a light-text region and the lowest
//        inside a dark-text region, against the packed ceiling and floor;
//      - the standard deviation of frame-to-frame luminance change inside the regions and
//        outside them (pixels clear of every region's feather);
//      - motion (the same measure over the frame) and flash intensity (the largest frame-mean
//        absolute luminance change) with and without reduced motion.
// 3. Presents a ramp of every half-float input from 0 to 16 with no regions and compares the
//    8-bit output with the exact piecewise sRGB encode of the tone-mapped input, computed here
//    in double precision.
// 5. The optional host layer hook: builds the pass with a stub layer that composites an opaque
//    white layer texture, and presents a black scene with it on, on, then off (WebGL2, and Metal
//    on macOS). The layer must show outside the regions, the light-text ceiling must hold over it,
//    and with the layer off the output must equal the pass without a layer, so the layer never
//    entered the history.
// 4. On macOS, presents the ramp and the last two frames of --parity visuals (evenly spaced,
//    plus the strobe) through the bundle's Metal present pass (present-metal.swift) with the
//    same inputs and block, and diffs the outputs as render.mjs diffs its Metal frames.
//
// Writes OUT/overlay-check.json and PNGs of each visual's last frame with and without the
// regions; --evidence also copies a few of them there. Each visual draws with the tunable uniforms
// of its default preset (preset.mjs), or with --preset, of the accepted case NAME of
// conformance/presets/adversarial.json resolved for that visual. Exits 2 when a bound, a vector, the
// sRGB error or the Metal diff fails.
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { DEFAULT_CONFIG, MODE, OverlayError, packOverlay, safeRect } from '../../hosts/web/overlay.js';
import { withTempDir } from './glsl2msl.mjs';
import { VIVID_SATURATION, VIVID_VIBRANCE } from './palette-tour.mjs';
import { tonemapV2 } from './present-model.mjs';
import {
  PRESENT_FUNCTION, PRESENT_HEAD, PRESENT_LAYER_BLOCK_SIZE, PRESENT_POST_OFFSET, presentBlockSize, presentGLSL300, presentMSL,
  presentPost,
} from './present.mjs';
import { audioAt } from './synthetic-audio.mjs';
import { defaultPreset, presetUniforms, resolvePreset } from './preset.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const { values: opts } = parseArgs({
  options: {
    bundle: { type: 'string', default: join(ROOT, 'out', 'hosts', 'visuals.json') },
    frames: { type: 'string', default: '96' },
    only: { type: 'string', default: '' },
    out: { type: 'string', default: join(ROOT, 'out', 'overlay-check') },
    evidence: { type: 'string', default: '' },
    parity: { type: 'string', default: '12' },
    preset: { type: 'string', default: '' },
  },
});
const W = 480, H = 270;
const FRAMES = parseInt(opts.frames, 10);
const OUT = resolve(opts.out);
// The bars, from the ticket: in-region change std at most a quarter of the outside value, an
// sRGB error of at most one output step, and render.mjs's Metal tolerance.
const CHANGE_RATIO_LIMIT = 0.25;
const SRGB_ERROR_LIMIT = 1 / 255;
const MSL_PIXEL_DIFF_LIMIT = 0.40;
// A visual whose outside barely changes has no motion to compare against; it is listed, not
// scored, for the change ratio.
const MIN_OUTSIDE_STD = 1e-3;
// In-region change at or below this is about one 8-bit output step at the dark end of a text
// region: quantisation the damping cannot remove and no reader sees, so a nearly still visual
// passes whatever its ratio (its ratio is still reported).
const IN_STD_FLOOR = 1e-3;
// Whole-frame change at or below this is a few pixels flipping one 8-bit step: a visual this
// still cannot be said to move or flash more under reduced motion, whichever run is larger.
const STILL_FLOOR = 1e-4;
const STROBE = 'strobe';

const LIGHT = MODE['light-text'], DARK = MODE['dark-text'];
const READABLE = MODE.desaturate | MODE['damp-motion'] | MODE['damp-flash'];
// The fixed region set, in viewport fractions; radius and feather in viewport heights.
const REGIONS = [
  { name: 'caption', x: 0.03, y: 0.05, width: 0.42, height: 0.14, corner_radius: 6 / H, feather: 12 / H,
    strength: 1, mode: LIGHT | READABLE, reserved: 0 },
  { name: 'badge', x: 0.66, y: 0.05, width: 0.31, height: 0.09, corner_radius: 12 / H, feather: 0,
    strength: 1, mode: DARK | MODE['damp-flash'], reserved: 0 },
  { name: 'menu', x: 0.05, y: 0.78, width: 0.90, height: 0.16, corner_radius: 8 / H, feather: 0,
    strength: 1, mode: LIGHT | READABLE | MODE.blur, reserved: 0 },
];
const CONFIG = { ...DEFAULT_CONFIG, viewport_width: W, viewport_height: H };

const fail = [];
mkdirSync(OUT, { recursive: true });

// 1. The JS packer against the vectors.
const vectors = JSON.parse(readFileSync(join(ROOT, 'conformance', 'packing', 'overlay-uniforms.json'), 'utf8'));
let packed = 0;
for (const c of vectors.pack) {
  let got;
  try {
    got = Buffer.from(packOverlay(c.config, c.regions)).toString('hex');
  } catch (e) {
    if (!(e instanceof OverlayError)) throw e;
    got = `refused ${e.kind}`;
  }
  const want = c.refused ? `refused ${c.refused}` : c.bytes;
  if (got === want) packed++;
  else fail.push(`pack ${c.name}: got ${got.slice(0, 40)}, want ${want.slice(0, 40)}`);
}
console.log(`packOverlay: ${packed}/${vectors.pack.length} vector cases match`);

// 2. The bundle, which must carry the current present pass.
if (!existsSync(opts.bundle)) {
  console.error(`overlay-check: no ${opts.bundle}; run make host-bundle`);
  process.exit(64);
}
const bundle = JSON.parse(readFileSync(opts.bundle, 'utf8'));
if (bundle.present?.web !== presentGLSL300()) {
  console.error('overlay-check: the bundle\'s present pass is stale; run make host-bundle');
  process.exit(64);
}
const ONLY = opts.only.split(',').filter(Boolean);
const visuals = bundle.visuals.filter(v => !ONLY.length || ONLY.includes(v.id));
const unknown = ONLY.filter(id => id !== STROBE && !bundle.visuals.some(v => v.id === id));
if (unknown.length) throw new Error(`unknown --only visual id(s): ${unknown.join(', ')}`);
const adversarial = opts.preset && JSON.parse(readFileSync(join(ROOT, 'conformance', 'presets', 'adversarial.json'), 'utf8'))
  .cases.find(c => c.name === opts.preset && c.expect === 'accept' && c.input);
if (opts.preset && !adversarial) throw new Error(`--preset ${opts.preset}: no accepted input case of that name in adversarial.json`);
const catalog = new Map(bundle.visuals.map(v => [v.id, v]));
const tuning = new Map(visuals.map(v => {
  if (!adversarial) return [v.id, presetUniforms(defaultPreset(v), v)];
  const { $params: n, ...input } = JSON.parse(JSON.stringify(adversarial.input).replaceAll('$visual', v.id));
  if (n !== undefined) input.params = Object.fromEntries(v.controls.map(c => [c.id, n]));
  const r = resolvePreset(input, catalog);
  if (!r.ok) throw new Error(`--preset ${opts.preset} for ${v.id}: ${r.error.message}`);
  return [v.id, presetUniforms(r.preset, v)];
}));

// present0, the overlay block and the post block: one code of dither on a fixed seed, as a host
// dithers a still frame; bloom, aberration and grain off.
const block = (config, regions, head) => {
  const f = new Float32Array(presentBlockSize() / 4);
  f.set(head);
  packOverlay(config, regions, new Uint8Array(f.buffer, PRESENT_HEAD, PRESENT_POST_OFFSET - PRESENT_HEAD));
  f.set(presentPost({ dither: 1 }), PRESENT_POST_OFFSET / 4);
  return f;
};
const HEAD = [VIVID_SATURATION, 1, 1, VIVID_VIBRANCE];
const blocks = {
  overlay: block(CONFIG, REGIONS, HEAD),
  plain: block(CONFIG, [], HEAD),
  reduced: block({ ...CONFIG, reduced_motion: true }, [], HEAD),
};
const ceiling = blocks.overlay[PRESENT_HEAD / 4 + 1], floor = blocks.overlay[PRESENT_HEAD / 4 + 2];

// The stub host layer: pl.layer[0].x scales the layer texture's alpha.
const LAYER_STUB = `vec3 oscillux_present_layer(vec2 uv, vec3 c) {
    vec4 t = PRESENT_LAYER_TEX(uv);
    return mix(c, t.rgb, t.a * pl.layer[0].x);
}`;
const layerBlock = on => { const f = new Float32Array(PRESENT_LAYER_BLOCK_SIZE / 4); f[0] = on; return f; };
const LAYER_FRAMES = [1, 1, 0];

// Exact sRGB decode of every 8-bit code.
const decode = v => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
const LUT = Array.from({ length: 256 }, (_, i) => decode(i / 255));

const parityCount = Math.max(0, parseInt(opts.parity, 10));
const parityIds = new Set([STROBE]);
for (let i = 0; i < parityCount && visuals.length; i++) {
  parityIds.add(visuals[Math.floor(i * visuals.length / parityCount)].id);
}
const shotIds = [...parityIds].slice(0, 4);

// Region membership per pixel, in readPixels order (rows bottom-up): the index of the region
// whose rounded rectangle holds the pixel centre, -1 for none, and whether the pixel is clear of
// every region's feather and the pass's dilation. The distance is presentRegionDistance's.
function regionMasks(W, H, regions) {
  const aspect = W / H, dilate = 0.75 / H, clear = 2 / H;
  const inside = new Int8Array(W * H).fill(-1), outside = new Uint8Array(W * H);
  for (let r = 0; r < H; r++) {
    for (let x = 0; x < W; x++) {
      const px = ((x + 0.5) / W) * aspect, py = 1 - (r + 0.5) / H, i = r * W + x;
      let out = 1;
      regions.forEach((g, k) => {
        const hx = 0.5 * g.width * aspect, hy = 0.5 * g.height;
        const radius = Math.min(g.corner_radius, hx, hy);
        const qx = Math.abs(px - (g.x * aspect + hx)) - hx + radius;
        const qy = Math.abs(py - (g.y + hy)) - hy + radius;
        const d = Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - radius;
        if (d <= 0 && inside[i] < 0) inside[i] = k;
        if (d <= g.feather + dilate + clear) out = 0;
      });
      outside[i] = out;
    }
  }
  return { inside, outside };
}

const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader'] });
const page = await browser.newPage();
page.on('console', m => { if (m.type() === 'error') console.error('[page]', m.text().slice(0, 400)); });
const started = Date.now();
const result = await page.evaluate(async args => {
  const { visuals, vertex, presentSrc, audioSrc, masksSrc, W, H, FRAMES, regions, lut, parityIds, shotIds, STROBE, safe } = args;
  const blocks = Object.fromEntries(Object.entries(args.blocks).map(([k, f]) => [k, new Float32Array(f)]));
  const audioAt = new Function(`return ${audioSrc}`)();
  const regionMasks = new Function(`return ${masksSrc}`)();
  const parity = new Set(parityIds), shots = new Set(shotIds);
  const canvas = document.createElement('canvas');
  canvas.width = W; canvas.height = H;
  const gl = canvas.getContext('webgl2', { antialias: false });
  if (!gl) return { fatal: 'no webgl2' };
  if (!gl.getExtension('EXT_color_buffer_float')) return { fatal: 'no EXT_color_buffer_float' };
  const quad = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quad);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const link = (v, fsrc) => {
    const p = gl.createProgram();
    gl.attachShader(p, v); gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fsrc));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    return p;
  };
  const vs = compile(gl.VERTEX_SHADER, vertex);
  // Scene targets store rows in vUV order, as the hosts and render.mjs do.
  const vsFbo = compile(gl.VERTEX_SHADER, vertex.replace('gl_Position = vec4(aPos, 0.0, 1.0);',
    'gl_Position = vec4(aPos.x, -aPos.y, 0.0, 1.0);'));
  const drawQuad = () => {
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  };
  const texture = (internal, w, h, format, type, filter, data = null) => {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, internal, w, h, 0, format, type, data);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return t;
  };
  const sceneTarget = () => {
    const t = texture(gl.RGBA16F, W, H, gl.RGBA, gl.HALF_FLOAT, gl.LINEAR);
    const f = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, f);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
    gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
    return { t, f };
  };
  const ipix = new Uint8Array(64 * 64 * 4);
  for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) {
    const i = (y * 64 + x) * 4;
    ipix[i] = 40 + x * 2.5; ipix[i + 1] = 30 + y * 1.8; ipix[i + 2] = 120 + ((x + y) & 15) * 6; ipix[i + 3] = 255;
  }
  const imgTex = texture(gl.RGBA8, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, gl.LINEAR, ipix);

  // The present pass, drawn as the web host draws it on screen: an RGBA8 colour target and a
  // pair of RGBA16F history targets, the one read and the one written.
  const present = link(vs, presentSrc);
  gl.uniformBlockBinding(present, gl.getUniformBlockIndex(present, 'PresentBlock'), 0);
  gl.useProgram(present);
  ['uA', 'uB', 'uH'].forEach((n, i) => gl.uniform1i(gl.getUniformLocation(present, n), i));
  gl.uniform1i(gl.getUniformLocation(present, 'uBloom'), 4);
  const ubo = gl.createBuffer();
  gl.bindBuffer(gl.UNIFORM_BUFFER, ubo);
  gl.bufferData(gl.UNIFORM_BUFFER, args.presentBlockSize, gl.DYNAMIC_DRAW);
  const presentTargets = (w, h) => {
    const color = texture(gl.RGBA8, w, h, gl.RGBA, gl.UNSIGNED_BYTE, gl.NEAREST);
    const hist = [0, 1].map(() => texture(gl.RGBA16F, w, h, gl.RGBA, gl.HALF_FLOAT, gl.NEAREST));
    const fbos = hist.map(ht => {
      const f = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, f);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color, 0);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT1, gl.TEXTURE_2D, ht, 0);
      gl.drawBuffers([gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1]);
      gl.clearBufferfv(gl.COLOR, 1, [0, 0, 0, 0]);
      return f;
    });
    return { w, h, color, hist, fbos, cur: 0, px: new Uint8Array(w * h * 4) };
  };
  const resetTargets = pt => {
    for (const f of pt.fbos) { gl.bindFramebuffer(gl.FRAMEBUFFER, f); gl.clearBufferfv(gl.COLOR, 1, [0, 0, 0, 0]); }
    pt.cur = 0;
  };
  const presentFrame = (pt, sceneTex, blk) => {
    gl.useProgram(present);
    gl.bindBuffer(gl.UNIFORM_BUFFER, ubo);
    gl.bufferSubData(gl.UNIFORM_BUFFER, 0, blk);
    gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, ubo);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, sceneTex);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, sceneTex);
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, pt.hist[pt.cur]);
    gl.bindFramebuffer(gl.FRAMEBUFFER, pt.fbos[pt.cur ^ 1]);
    gl.viewport(0, 0, pt.w, pt.h);
    drawQuad();
    pt.cur ^= 1;
    gl.readBuffer(gl.COLOR_ATTACHMENT0);
    gl.readPixels(0, 0, pt.w, pt.h, gl.RGBA, gl.UNSIGNED_BYTE, pt.px);
    return pt.px;
  };
  const b64 = u8 => {
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const png = px => {
    const c = document.createElement('canvas');
    c.width = W; c.height = H;
    const ctx = c.getContext('2d'), img = ctx.createImageData(W, H);
    for (let r = 0; r < H; r++) img.data.set(px.subarray(r * W * 4, (r + 1) * W * 4), (H - 1 - r) * W * 4);
    ctx.putImageData(img, 0, 0);
    return c.toDataURL('image/png');
  };
  const readScene = f => {
    const out = new Float32Array(W * H * 4);
    gl.bindFramebuffer(gl.FRAMEBUFFER, f);
    gl.readBuffer(gl.COLOR_ATTACHMENT0);
    gl.readPixels(0, 0, W, H, gl.RGBA, gl.FLOAT, out);
    return b64(new Uint8Array(out.buffer));
  };

  const { inside, outside } = regionMasks(W, H, regions);
  const isLight = regions.map(g => (g.mode & 1) !== 0), isDark = regions.map(g => (g.mode & 2) !== 0);
  const N = W * H;
  const luminance = (px, Y) => {
    for (let i = 0, j = 0; j < N; i += 4, j++) Y[j] = 0.2126 * lut[px[i]] + 0.7152 * lut[px[i + 1]] + 0.0722 * lut[px[i + 2]];
  };
  const acc = () => ({ n: 0, s: 0, ss: 0 });
  const add = (a, d) => { a.n++; a.s += d; a.ss += d * d; };
  const std = a => (a.n ? Math.sqrt(Math.max(a.ss / a.n - (a.s / a.n) ** 2, 0)) : 0);
  const runs = ['overlay', 'plain', 'reduced'].map(name => ({ name, blk: blocks[name], pt: presentTargets(W, H),
    Y: new Float32Array(N), prev: new Float32Array(N) }));
  const parityTargets = presentTargets(W, H);

  const strobeSrc = `#version 300 es
precision highp float;
uniform float uFrame;
in vec2 vUV;
out vec4 oColor;
void main() {
    // Frames cycle black, HDR white, black, saturated red and blue stripes.
    float phase = mod(uFrame, 4.0);
    vec3 c = phase == 1.0 ? vec3(24.0) : phase == 3.0 ? (mod(floor(vUV.x * 12.0), 2.0) < 1.0 ? vec3(24.0, 0.0, 0.0) : vec3(0.0, 0.0, 24.0)) : vec3(0.0);
    oColor = vec4(c, 1.0);
}`;
  const list = [...visuals, { id: STROBE, web: strobeSrc, tuning: { sensitivity: 1, param0: 0.5, param1: 0.5, param2: 0.5,
    accent: [0.15, 0.9, 0.72, 1], motion: [0, 0, 0, 0], palette: [0, 0, 0, 0], trailDecay: 0.82 } }];
  const results = [], pngs = {}, parityData = {};
  for (const v of list) {
    const entry = { id: v.id, ok: false };
    let prog;
    try { prog = link(vsFbo, v.web); } catch (e) { entry.error = String(e.message || e).slice(0, 400); results.push(entry); continue; }
    const U = n => gl.getUniformLocation(prog, n);
    gl.useProgram(prog);
    gl.uniform2f(U('u.resolution'), W, H);
    const t = v.tuning;
    gl.uniform1f(U('u.sensitivity'), t.sensitivity);
    gl.uniform1f(U('u.param0'), t.param0); gl.uniform1f(U('u.param1'), t.param1); gl.uniform1f(U('u.param2'), t.param2);
    gl.uniform1f(U('u.trailDecay'), t.trailDecay);
    gl.uniform4f(U('u.accent'), ...t.accent);
    gl.uniform4f(U('u.motion'), ...t.motion);
    gl.uniform4f(U('u.palette'), ...t.palette);
    gl.uniform4f(U('u.presentation0'), 0, 1, 0, 0);
    gl.uniform4f(U('u.presentation1'), 1, 0, 0, 0);
    gl.uniform4f(U('u.safeRect'), ...safe);
    gl.uniform1i(U('uImage'), 0);
    gl.uniform1i(U('uPrev'), 1);
    let a = sceneTarget(), b = sceneTarget();
    for (const run of runs) resetTargets(run.pt);
    const st = {
      maxLight: 0, minDark: 1, maxLightPlain: 0, minDarkPlain: 1,
      inChange: regions.map(acc), inChangeAll: acc(), outChange: acc(), inChangePlain: acc(),
      motion: { plain: acc(), reduced: acc() }, flash: { plain: 0, reduced: 0 },
    };
    for (let fr = 0; fr < FRAMES; fr++) {
      const tm = fr / 60, au = audioAt(tm);
      gl.useProgram(prog);
      gl.uniform1f(U('u.time'), tm); gl.uniform1f(U('u.dt'), 1 / 60);
      gl.uniform1f(U('uFrame'), fr);
      for (const k of ['amplitude', 'bass', 'mid', 'treble', 'beat', 'beatPhase', 'onset', 'bassImpact', 'level', 'spectralCentroid', 'flux', 'beatCount']) {
        gl.uniform1f(U('u.' + k), au[k]);
      }
      gl.uniform4fv(U('u.spectrum[0]'), new Float32Array(au.spectrum));
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, imgTex);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, a.t);
      gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, b.f);
      gl.viewport(0, 0, W, H);
      drawQuad();
      [a, b] = [b, a];
      for (const run of runs) {
        const px = presentFrame(run.pt, a.t, run.blk);
        luminance(px, run.Y);
        const Y = run.Y, P = run.prev, has = fr > 0;
        if (run.name === 'overlay') {
          for (let j = 0; j < N; j++) {
            const k = inside[j];
            if (k >= 0) {
              if (isLight[k]) st.maxLight = Math.max(st.maxLight, Y[j]);
              if (isDark[k]) st.minDark = Math.min(st.minDark, Y[j]);
              if (has) { add(st.inChange[k], Y[j] - P[j]); add(st.inChangeAll, Y[j] - P[j]); }
            } else if (has && outside[j]) add(st.outChange, Y[j] - P[j]);
          }
          if (fr === FRAMES - 1 && shots.has(v.id)) pngs[`${v.id}-overlay`] = png(px);
          if (v.id === STROBE && fr === FRAMES - 3) pngs[`${v.id}-flash-overlay`] = png(px);
        } else {
          let mean = 0;
          for (let j = 0; j < N; j++) {
            const k = inside[j];
            if (run.name === 'plain' && k >= 0) {
              if (isLight[k]) st.maxLightPlain = Math.max(st.maxLightPlain, Y[j]);
              if (isDark[k]) st.minDarkPlain = Math.min(st.minDarkPlain, Y[j]);
              if (has) add(st.inChangePlain, Y[j] - P[j]);
            }
            if (has) { add(st.motion[run.name], Y[j] - P[j]); mean += Math.abs(Y[j] - P[j]); }
          }
          if (has) st.flash[run.name] = Math.max(st.flash[run.name], mean / N);
          if (run.name === 'plain' && fr === FRAMES - 1 && shots.has(v.id)) pngs[`${v.id}-plain`] = png(px);
          if (run.name === 'plain' && v.id === STROBE && fr === FRAMES - 3) pngs[`${v.id}-flash-plain`] = png(px);
        }
        run.prev = Y; run.Y = P;
      }
    }
    if (parity.has(v.id)) {
      // The last two scene frames, presented from an empty history with the region block.
      resetTargets(parityTargets);
      presentFrame(parityTargets, b.t, blocks.overlay);
      const out = presentFrame(parityTargets, a.t, blocks.overlay);
      parityData[v.id] = { scenes: [readScene(b.f), readScene(a.f)], web: b64(out) };
    }
    Object.assign(entry, {
      ok: true, maxLight: st.maxLight, minDark: st.minDark, maxLightPlain: st.maxLightPlain, minDarkPlain: st.minDarkPlain,
      inStd: std(st.inChangeAll), inStdByRegion: st.inChange.map(std), outStd: std(st.outChange), inStdPlain: std(st.inChangePlain),
      motionPlain: std(st.motion.plain), motionReduced: std(st.motion.reduced), flashPlain: st.flash.plain, flashReduced: st.flash.reduced,
    });
    results.push(entry);
    gl.deleteProgram(prog);
    for (const t of [a, b]) { gl.deleteTexture(t.t); gl.deleteFramebuffer(t.f); }
  }

  // The ramp: every half-float from 0 to 16 (0x0000 to 0x4c00), one per channel at different
  // offsets, presented with no regions and no history.
  const RW = 256, count = 0x4c01, RH = Math.ceil(count / RW);
  const half = h => { const e = (h >> 10) & 31, f = h & 1023; return e === 0 ? f * 2 ** -24 : (1 + f / 1024) * 2 ** (e - 15); };
  const ramp = new Float32Array(RW * RH * 4);
  for (let t = 0; t < RW * RH; t++) {
    const i = t % count;
    ramp.set([half(i), half(count - 1 - i), half((i * 7) % count), 1], t * 4);
  }
  const rampTex = texture(gl.RGBA16F, RW, RH, gl.RGBA, gl.FLOAT, gl.NEAREST, ramp);
  const rampTargets = presentTargets(RW, RH);
  const rampBlock = new Float32Array(blocks.plain);
  rampBlock.set([1, 1, 1, 0]);
  rampBlock[args.postOffset / 4 + 3] = 0; // no dither: the ramp checks the colour path to one code
  const rampOut = presentFrame(rampTargets, rampTex, rampBlock);

  // The layer hook: a black scene, the stub layer on, on and off, against the pass without it.
  const layered = link(vs, args.layerSrc);
  gl.uniformBlockBinding(layered, gl.getUniformBlockIndex(layered, 'PresentBlock'), 0);
  gl.uniformBlockBinding(layered, gl.getUniformBlockIndex(layered, 'PresentLayerBlock'), 1);
  gl.useProgram(layered);
  ['uA', 'uB', 'uH', 'uL'].forEach((n, i) => gl.uniform1i(gl.getUniformLocation(layered, n), i));
  gl.uniform1i(gl.getUniformLocation(layered, 'uBloom'), 4);
  const layerUbo = gl.createBuffer();
  gl.bindBuffer(gl.UNIFORM_BUFFER, layerUbo);
  gl.bufferData(gl.UNIFORM_BUFFER, args.layerBlockSize, gl.DYNAMIC_DRAW);
  const white = texture(gl.RGBA8, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, gl.NEAREST, new Uint8Array([255, 255, 255, 255]));
  const black = texture(gl.RGBA16F, W, H, gl.RGBA, gl.FLOAT, gl.NEAREST,
    new Float32Array(W * H * 4).map((_, i) => (i % 4 === 3 ? 1 : 0)));
  const withLayer = presentTargets(W, H), without = presentTargets(W, H);
  const layerOut = [];
  for (const on of args.layerFrames) {
    gl.bindBuffer(gl.UNIFORM_BUFFER, layerUbo);
    gl.bufferSubData(gl.UNIFORM_BUFFER, 0, new Float32Array(args.layerBlockSize / 4).fill(on, 0, 1));
    gl.bindBufferBase(gl.UNIFORM_BUFFER, 1, layerUbo);
    gl.activeTexture(gl.TEXTURE3); gl.bindTexture(gl.TEXTURE_2D, white);
    gl.useProgram(layered);
    gl.bindBuffer(gl.UNIFORM_BUFFER, ubo);
    gl.bufferSubData(gl.UNIFORM_BUFFER, 0, blocks.overlay);
    gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, ubo);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, black);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, black);
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, withLayer.hist[withLayer.cur]);
    gl.bindFramebuffer(gl.FRAMEBUFFER, withLayer.fbos[withLayer.cur ^ 1]);
    gl.viewport(0, 0, W, H);
    drawQuad();
    withLayer.cur ^= 1;
    gl.readBuffer(gl.COLOR_ATTACHMENT0);
    gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, withLayer.px);
    layerOut.push(b64(withLayer.px));
  }
  let plainOut;
  for (let i = 0; i < args.layerFrames.length; i++) plainOut = b64(presentFrame(without, black, blocks.overlay));
  return { results, pngs, parityData, ramp: { width: RW, height: RH, count, input: b64(new Uint8Array(ramp.buffer)),
    web: b64(rampOut), block: Array.from(rampBlock) }, layer: { web: layerOut, plain: plainOut } };
}, {
  layerSrc: presentGLSL300({ layer: LAYER_STUB }), layerBlockSize: PRESENT_LAYER_BLOCK_SIZE,
  presentBlockSize: presentBlockSize(), postOffset: PRESENT_POST_OFFSET, layerFrames: LAYER_FRAMES,
  visuals: visuals.map(v => ({ id: v.id, web: v.web, tuning: tuning.get(v.id) })),
  vertex: bundle.vertex, presentSrc: bundle.present.web, audioSrc: audioAt.toString(), masksSrc: regionMasks.toString(),
  W, H, FRAMES, blocks: Object.fromEntries(Object.entries(blocks).map(([k, f]) => [k, Array.from(f)])),
  regions: REGIONS, lut: LUT, parityIds: [...parityIds], shotIds, STROBE, safe: safeRect(REGIONS),
});
await browser.close();
if (result.fatal) { console.error(result.fatal); process.exit(1); }
const renderSeconds = (Date.now() - started) / 1000;
for (const [name, url] of Object.entries(result.pngs)) writeFileSync(join(OUT, `${name}.png`), Buffer.from(url.split(',')[1], 'base64'));

// Contrast and change, per visual.
const rows = result.results;
const fmt = (x, n = 4) => (x === undefined ? '-' : x.toFixed(n));
let worstLight = 0, worstDark = 1, worstRatio = 0, scored = 0;
const unscored = [], atFloor = [], ratioFails = [], motionUp = [], flashUp = [];
for (const r of rows) {
  if (!r.ok) { fail.push(`${r.id}: compile ${r.error}`); continue; }
  worstLight = Math.max(worstLight, r.maxLight);
  worstDark = Math.min(worstDark, r.minDark);
  if (r.maxLight > ceiling) fail.push(`${r.id}: light-text luminance ${r.maxLight} > ${ceiling}`);
  if (r.minDark < floor) fail.push(`${r.id}: dark-text luminance ${r.minDark} < ${floor}`);
  r.ratio = r.outStd >= MIN_OUTSIDE_STD ? r.inStd / r.outStd : undefined;
  if (r.ratio === undefined) unscored.push(r.id);
  else {
    scored++;
    if (r.ratio > CHANGE_RATIO_LIMIT && r.inStd <= IN_STD_FLOOR) atFloor.push(r.id);
    else {
      worstRatio = Math.max(worstRatio, r.ratio);
      if (r.ratio > CHANGE_RATIO_LIMIT) { ratioFails.push(r.id); fail.push(`${r.id}: in/out change ratio ${r.ratio.toFixed(3)}`); }
    }
  }
  if (r.motionReduced > r.motionPlain && r.motionReduced > STILL_FLOOR) motionUp.push(r.id);
  if (r.flashReduced > r.flashPlain && r.flashReduced > STILL_FLOOR) flashUp.push(r.id);
  console.log(`${r.id.padEnd(24)} light=${fmt(r.maxLight)} (plain ${fmt(r.maxLightPlain)}) dark=${fmt(r.minDark)} (plain ${fmt(r.minDarkPlain)}) `
    + `in/out=${fmt(r.inStd)}/${fmt(r.outStd)}=${r.ratio === undefined ? 'n/a' : r.ratio.toFixed(3)} `
    + `motion=${fmt(r.motionPlain)}->${fmt(r.motionReduced)} flash=${fmt(r.flashPlain)}->${fmt(r.flashReduced)}`);
}
const sum = (k) => rows.filter(r => r.ok).reduce((s, r) => s + r[k], 0);
const motionRatio = sum('motionReduced') / sum('motionPlain');
const flashRatio = sum('flashReduced') / sum('flashPlain');
if (!(motionRatio < 1)) fail.push(`reduced motion: mean motion ratio ${motionRatio}`);
if (!(flashRatio < 1)) fail.push(`reduced motion: mean flash ratio ${flashRatio}`);
if (motionUp.length) fail.push(`reduced motion raised motion for ${motionUp.join(', ')}`);
if (flashUp.length) fail.push(`reduced motion raised flash intensity for ${flashUp.join(', ')}`);

// 3. sRGB against the double-precision reference: the hue-preserving tone map on each RGB triple
// (present-model.mjs), then the exact encode.
const srgb = c => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);
const R = result.ramp;
const rampIn = new Float32Array(Buffer.from(R.input, 'base64').buffer.slice(0));
const rampWeb = Buffer.from(R.web, 'base64');
function rampError(out, rowsTopDown) {
  let max = 0, maxGamma = 0;
  for (let t = 0; t < R.count; t++) {
    const tr = Math.floor(t / R.width), x = t % R.width;
    const row = rowsTopDown ? tr : R.height - 1 - tr;
    const mapped = tonemapV2([rampIn[t * 4], rampIn[t * 4 + 1], rampIn[t * 4 + 2]]);
    for (let c = 0; c < 3; c++) {
      const c0 = mapped[c];
      const got = out[(row * R.width + x) * 4 + c] / 255;
      max = Math.max(max, Math.abs(got - srgb(c0)));
      maxGamma = Math.max(maxGamma, Math.abs(got - c0 ** (1 / 2.2)));
    }
  }
  return { max, maxGamma };
}
const srgbWeb = rampError(rampWeb, false);
if (srgbWeb.max > SRGB_ERROR_LIMIT) fail.push(`sRGB: WebGL2 max error ${srgbWeb.max * 255} steps`);
console.log(`sRGB (WebGL2): ${R.count} half-float inputs x 3 channels, max error ${(srgbWeb.max * 255).toFixed(3)}/255 `
  + `(limit 1/255); against pow(1/2.2) ${(srgbWeb.maxGamma * 255).toFixed(1)}/255`);

// 5. The layer hook. Rows are bottom-up (readPixels), as the masks are.
const masksAll = regionMasks(W, H, REGIONS);
function layerCheck(on, off, plain, rowsTopDown) {
  let shown = 0, outside = 0, maxLight = 0, maxCode = 0;
  for (let r = 0; r < H; r++) {
    for (let x = 0; x < W; x++) {
      const i = ((rowsTopDown ? H - 1 - r : r) * W + x) * 4, j = (r * W + x) * 4, m = r * W + x;
      const k = masksAll.inside[m];
      if (masksAll.outside[m]) { outside++; if (on[i] === 255 && on[i + 1] === 255 && on[i + 2] === 255) shown++; }
      if (k >= 0 && (REGIONS[k].mode & LIGHT)) maxLight = Math.max(maxLight, 0.2126 * LUT[on[i]] + 0.7152 * LUT[on[i + 1]] + 0.0722 * LUT[on[i + 2]]);
      for (let c = 0; c < 3; c++) maxCode = Math.max(maxCode, Math.abs(off[i + c] - plain[j + c]));
    }
  }
  return { shownOutside: shown / outside, maxLight, offVsNoLayerMaxCode: maxCode };
}
function layerFail(name, l, codeLimit) {
  if (l.shownOutside !== 1) fail.push(`layer (${name}): shown on ${(l.shownOutside * 100).toFixed(2)}% of the outside`);
  if (l.maxLight > ceiling) fail.push(`layer (${name}): light-text luminance ${l.maxLight} over the layer`);
  if (!(l.maxLight > ceiling - 0.01)) fail.push(`layer (${name}): light-text regions ${l.maxLight}, the layer did not reach them`);
  if (l.offVsNoLayerMaxCode > codeLimit) fail.push(`layer (${name}): off differs from no layer by ${l.offVsNoLayerMaxCode} codes`);
}
const layerPlain = Buffer.from(result.layer.plain, 'base64');
const layerWeb = layerCheck(Buffer.from(result.layer.web[1], 'base64'), Buffer.from(result.layer.web[2], 'base64'), layerPlain, false);
layerFail('WebGL2', layerWeb, 0);
console.log(`Layer hook (WebGL2): layer shown on ${(layerWeb.shownOutside * 100).toFixed(1)}% of the outside, light-text max `
  + `${layerWeb.maxLight.toFixed(6)} (ceiling ${ceiling.toFixed(6)}), layer off vs no layer: max ${layerWeb.offVsNoLayerMaxCode} codes`);

// 4. Metal parity.
const summary = {
  frames: FRAMES, size: [W, H], visuals: rows.length, preset: opts.preset || 'default', renderSeconds, ceiling, floor, regions: REGIONS,
  pack: { matched: packed, cases: vectors.pack.length },
  contrast: { worstLight, worstDark },
  change: { limit: CHANGE_RATIO_LIMIT, minOutsideStd: MIN_OUTSIDE_STD, inStdFloor: IN_STD_FLOOR, scored, unscored, atFloor, worstRatio, fails: ratioFails },
  reducedMotion: { motionRatio, flashRatio, stillFloor: STILL_FLOOR, motionUp, flashUp },
  srgb: { web: srgbWeb },
  layer: { web: layerWeb },
  results: rows,
};
if (process.platform === 'darwin') summary.metal = metalParity();
else console.log('Metal parity skipped: requires macOS');
writeFileSync(join(OUT, 'overlay-check.json'), JSON.stringify(summary, null, 1));
if (opts.evidence) {
  const dir = resolve(opts.evidence);
  mkdirSync(dir, { recursive: true });
  for (const name of Object.keys(result.pngs)) copyFileSync(join(OUT, `${name}.png`), join(dir, `check-${name}.png`));
}
console.log(`\n${rows.length} visuals x ${FRAMES} frames in ${renderSeconds.toFixed(0)} s. Worst light-text luminance ${worstLight.toFixed(6)} `
  + `(ceiling ${ceiling.toFixed(6)}), worst dark-text ${worstDark.toFixed(6)} (floor ${floor.toFixed(6)}); worst in/out change ratio `
  + `${worstRatio.toFixed(3)} over ${scored} visuals (${unscored.length} with a still outside: ${unscored.join(', ') || 'none'}; `
  + `${atFloor.length} over the ratio with in-region change at the ${IN_STD_FLOOR} floor: ${atFloor.join(', ') || 'none'}); `
  + `reduced motion: motion x${motionRatio.toFixed(3)}, flash x${flashRatio.toFixed(3)}.`);
for (const f of fail) console.error(`FAIL ${f}`);
console.log(fail.length ? `${fail.length} problem(s)` : 'overlay-check: ok');
process.exit(fail.length ? 2 : 0);

function metalParity() {
  const masks = regionMasks(W, H, REGIONS);
  return withTempDir('overlay-metal', dir => {
    const metal = join(dir, 'present.metal');
    writeFileSync(metal, bundle.present.metal);
    const hex = f => Buffer.from(new Float32Array(f).buffer).toString('hex');
    const cases = [{ name: 'ramp', width: R.width, height: R.height, block: hex(R.block), frames: [join(dir, 'ramp.f32')], out: join(dir, 'ramp.out') }];
    writeFileSync(cases[0].frames[0], Buffer.from(R.input, 'base64'));
    for (const [id, d] of Object.entries(result.parityData)) {
      const frames = d.scenes.map((s, i) => { const p = join(dir, `${id}-${i}.f32`); writeFileSync(p, Buffer.from(s, 'base64')); return p; });
      cases.push({ name: id, width: W, height: H, block: hex(blocks.overlay), frames, out: join(dir, `${id}.out`) });
    }
    const cfg = join(dir, 'cases.json');
    writeFileSync(cfg, JSON.stringify({ metal, function: bundle.present.metalFunction, cases }));
    const reply = JSON.parse(execFileSync('swift', [join(HERE, 'present-metal.swift'), cfg], { encoding: 'utf8' }));
    if (reply.skipped) {
      console.log(`Metal parity skipped: ${reply.skipped}`);
      if (process.env.CI) fail.push('Metal parity required on CI');
      return { skipped: reply.skipped };
    }
    const report = { limit: MSL_PIXEL_DIFF_LIMIT, cases: [] };
    const srgbMetal = rampError(readFileSync(cases[0].out), true);
    if (srgbMetal.max > SRGB_ERROR_LIMIT) fail.push(`sRGB: Metal max error ${srgbMetal.max * 255} steps`);
    report.srgb = srgbMetal;
    console.log(`sRGB (Metal): max error ${(srgbMetal.max * 255).toFixed(3)}/255`);
    for (const c of cases) {
      const metalOut = readFileSync(c.out);
      const web = c.name === 'ramp' ? rampWeb : Buffer.from(result.parityData[c.name].web, 'base64');
      let maxCode = 0, sumAbs = 0, lumaDiff = 0, over1 = 0, maxLight = 0, minDark = 1;
      for (let r = 0; r < c.height; r++) {
        for (let x = 0; x < c.width; x++) {
          const iw = (r * c.width + x) * 4, im = ((c.height - 1 - r) * c.width + x) * 4;
          let worst = 0;
          for (let k = 0; k < 3; k++) {
            const d = Math.abs(web[iw + k] - metalOut[im + k]);
            worst = Math.max(worst, d); sumAbs += d;
          }
          maxCode = Math.max(maxCode, worst);
          if (worst > 1) over1++;
          const luma = p => Math.round(0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]);
          lumaDiff += Math.abs(luma(web.subarray(iw, iw + 3)) - luma(metalOut.subarray(im, im + 3)));
          if (c.name !== 'ramp') {
            const k = masks.inside[r * c.width + x];
            if (k >= 0) {
              const Y = 0.2126 * LUT[metalOut[im]] + 0.7152 * LUT[metalOut[im + 1]] + 0.0722 * LUT[metalOut[im + 2]];
              if (REGIONS[k].mode & LIGHT) maxLight = Math.max(maxLight, Y);
              if (REGIONS[k].mode & DARK) minDark = Math.min(minDark, Y);
            }
          }
        }
      }
      const n = c.width * c.height;
      const row = { name: c.name, normalizedDiff: lumaDiff / n / 255, maxCode, meanCode: sumAbs / n / 3, pixelsOver1: over1 / n };
      if (c.name !== 'ramp') {
        Object.assign(row, { maxLight, minDark });
        if (maxLight > ceiling) fail.push(`Metal ${c.name}: light-text luminance ${maxLight}`);
        if (minDark < floor) fail.push(`Metal ${c.name}: dark-text luminance ${minDark}`);
      }
      if (row.normalizedDiff > MSL_PIXEL_DIFF_LIMIT) fail.push(`Metal ${c.name}: diff ${row.normalizedDiff}`);
      report.cases.push(row);
      console.log(`Metal ${c.name.padEnd(22)} diff=${row.normalizedDiff.toFixed(5)} maxCode=${maxCode} mean=${row.meanCode.toFixed(4)} `
        + `>1 code: ${(row.pixelsOver1 * 100).toFixed(3)}%${c.name !== 'ramp' ? ` light=${maxLight.toFixed(6)} dark=${minDark.toFixed(6)}` : ''}`);
    }
    report.layer = metalLayer(dir, hex);
    return report;
  });
}

// The layer hook on Metal: the stub layer on, on (out) and on, on, off (outOff), against the
// WebGL2 pass without a layer.
function metalLayer(dir, hex) {
  const metal = join(dir, 'present-layer.metal');
  writeFileSync(metal, presentMSL({ layer: LAYER_STUB }));
  const scene = join(dir, 'black.f32');
  writeFileSync(scene, Buffer.from(new Float32Array(W * H * 4).map((_, i) => (i % 4 === 3 ? 1 : 0)).buffer));
  const base = { width: W, height: H, block: hex(blocks.overlay), layerTexture: 'ffffffff', layerWidth: 1, layerHeight: 1 };
  const cases = [
    { ...base, name: 'layer-on', frames: [scene, scene], layerBlocks: [1, 1].map(v => hex(layerBlock(v))), out: join(dir, 'layer-on.out') },
    { ...base, name: 'layer-off', frames: LAYER_FRAMES.map(() => scene), layerBlocks: LAYER_FRAMES.map(v => hex(layerBlock(v))), out: join(dir, 'layer-off.out') },
  ];
  const cfg = join(dir, 'layer-cases.json');
  writeFileSync(cfg, JSON.stringify({ metal, function: PRESENT_FUNCTION, cases }));
  execFileSync('swift', [join(HERE, 'present-metal.swift'), cfg], { encoding: 'utf8' });
  const l = layerCheck(readFileSync(cases[0].out), readFileSync(cases[1].out), layerPlain, true);
  layerFail('Metal', l, 1);
  console.log(`Layer hook (Metal): layer shown on ${(l.shownOutside * 100).toFixed(1)}% of the outside, light-text max `
    + `${l.maxLight.toFixed(6)}, layer off vs WebGL2 no layer: max ${l.offVsNoLayerMaxCode} codes`);
  return l;
}
