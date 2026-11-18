// SPDX-License-Identifier: AGPL-3.0-only
// Headless render harness: compiles every "web" visual of a manifest under real
// WebGL2 (SwiftShader via Playwright Chromium) and renders N frames with
// synthetic audio and feedback ping-pong, writing per-visual PNGs and stats.
// On macOS it also compiles every "msl" visual and, with --frames 1, renders it
// through Metal (metal-smoke.swift) and diffs it against the WebGL frame.
//
//   node tools/shader/render.mjs <manifest.json> [--out out/shader-renders]
//        [--frames 96] [--only id1,id2] [--img artwork.png] [--size 480x270]
//
// --size renders at another frame size, for example a portrait phone's 390x844
// to check how a visual fits a narrow frame.
//
// Exits 2 when any visual fails to compile, renders blank, whites out, or
// (macOS) drifts from its WebGL reference. An "msl" visual without a "web"
// target is compiled but not diffed. Under CI, a diff skipped for lack of a
// Metal device fails, as does a --frames 1 run where no diff could run.
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { mslEntryPoint, withTempDir } from './glsl2msl.mjs';
import { loadManifest } from './manifest.mjs';
import { audioAt } from './synthetic-audio.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    out: { type: 'string', default: '' },
    frames: { type: 'string', default: '96' },
    only: { type: 'string', default: '' },
    img: { type: 'string', default: '' },
    size: { type: 'string', default: '480x270' },
  },
});
if (positionals.length !== 1) {
  console.error('usage: render.mjs <manifest.json> [--out DIR] [--frames N] [--only id1,id2] [--img PNG] [--size WxH]');
  process.exit(64);
}
const manifest = loadManifest(positionals[0]);
const ROOT = join(HERE, '..', '..');
const OUT = opts.out ? resolve(opts.out) : join(ROOT, 'out', 'shader-renders');
const CACHE = join(ROOT, 'out', 'cache', 'metal-module-cache');
const FRAMES = parseInt(opts.frames, 10);
const ONLY = opts.only.split(',').filter(Boolean);
const SIZE = /^(\d+)x(\d+)$/.exec(opts.size);
if (!SIZE) { console.error('render.mjs: --size must be WxH, for example 390x844'); process.exit(64); }
const W = Number(SIZE[1]), H = Number(SIZE[2]);
const MSL_PIXEL_DIFF_LIMIT = 0.40;
const CLIP_BLOB_LIMIT = 0.0025;
const CLIP_BLOB_RADIUS = 2;

mkdirSync(OUT, { recursive: true });

const unknownIds = ONLY.filter(id => !manifest.byId.has(id));
if (unknownIds.length) throw new Error(`unknown --only visual id(s): ${unknownIds.join(', ')}`);
const pick = list => list.filter(v => !ONLY.length || ONLY.includes(v.id));

const visuals = Object.fromEntries(pick(manifest.byTarget.web).map(v => [v.id, {
  fragment: manifest.wrapper.wrapGLSL300(v.body, v.imageInput),
  palette: v.palette,
  params: v.params,
  trailDecay: v.trailDecay,
}]));

const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader'] });
const page = await browser.newPage();
page.on('console', m => { if (m.type() === 'error') console.error('[page]', m.text().slice(0, 400)); });

// Optional real artwork: --img path.png replaces the gradient stand-in.
const imgDataUrl = opts.img
  ? 'data:image/png;base64,' + readFileSync(opts.img).toString('base64')
  : null;

const mslIds = manifest.byTarget.msl.map(v => v.id);
const result = await page.evaluate(async ({ visuals, audioSrc, vertex, W, H, FRAMES, imgDataUrl, mslIds, clipBlobRadius }) => {
  const audioAt = new Function(`return ${audioSrc}`)();
  const mslSet = new Set(mslIds);
  const canvas = document.createElement('canvas');
  canvas.width = W; canvas.height = H;
  const gl = canvas.getContext('webgl2', { preserveDrawingBuffer: true, antialias: false });
  if (!gl) return { fatal: 'no webgl2' };
  gl.getExtension('EXT_color_buffer_float');

  const quad = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quad);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);

  function compile(type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }
  const vs = compile(gl.VERTEX_SHADER, vertex);
  // Offscreen (ping-pong FBO) passes must store the image in the same
  // orientation that vUV addresses, or every PREV() read is vertically
  // mirrored (phantom flipped trail ghosts). Negate clip-space y so texel
  // row v==vUV.y; the final canvas blit uses the unmodified vertex shader,
  // which flips it back to top-left-origin for the PNG.
  const vsFbo = compile(gl.VERTEX_SHADER,
    vertex.replace('gl_Position = vec4(aPos, 0.0, 1.0);',
                   'gl_Position = vec4(aPos.x, -aPos.y, 0.0, 1.0);'));

  // artwork input: real image via --img, else gradient stand-in
  const imgTex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, imgTex);
  if (imgDataUrl) {
    const img = new Image();
    await new Promise((res, rej) => { img.onload = res; img.onerror = rej; img.src = imgDataUrl; });
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
  } else {
    const ipix = new Uint8Array(64 * 64 * 4);
    for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) {
      const i = (y * 64 + x) * 4;
      ipix[i] = 40 + x * 2.5; ipix[i+1] = 30 + y * 1.8; ipix[i+2] = 120 + ((x+y)&15)*6; ipix[i+3] = 255;
    }
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 64, 64, 0, gl.RGBA, gl.UNSIGNED_BYTE, ipix);
  }
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

  function mkTarget() {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, W, H, 0, gl.RGBA, gl.HALF_FLOAT, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const f = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, f);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
    return { t, f };
  }

  function lumaGrid(px, w, h) {
    const gw = 8, gh = 8, out = [];
    for (let gy = 0; gy < gh; gy++) for (let gx = 0; gx < gw; gx++) {
      let sum = 0, count = 0;
      const x0 = Math.floor(gx * w / gw), x1 = Math.floor((gx + 1) * w / gw);
      const y0 = Math.floor(gy * h / gh), y1 = Math.floor((gy + 1) * h / gh);
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
        const i = (y * w + x) * 4;
        sum += (0.299 * px[i] + 0.587 * px[i+1] + 0.114 * px[i+2]) / 255;
        count++;
      }
      out.push(+(sum / count).toFixed(6));
    }
    return out;
  }
  // Share of the frame that is a SOLID clipped-white blob: the hard-clipped mask
  // eroded by clipBlobRadius. Deliberate thin white line-art and peak-kick
  // highlights erode to nothing; a subject that has melted into white survives.
  // Raw clipped share cannot tell those apart. Separable min-filter: rows
  // first, then columns.
  function clippedBlobShare(px, w, h, r) {
    const mask = new Uint8Array(w * h);
    for (let i = 0, j = 0; i < px.length; i += 4, j++) {
      mask[j] = px[i] >= 250 && px[i + 1] >= 250 && px[i + 2] >= 250 ? 1 : 0;
    }
    const rows = new Uint8Array(w * h);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      let keep = x >= r && x < w - r ? 1 : 0;
      for (let k = -r; keep && k <= r; k++) keep = mask[y * w + x + k];
      rows[y * w + x] = keep;
    }
    let solid = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      let keep = y >= r && y < h - r ? 1 : 0;
      for (let k = -r; keep && k <= r; k++) keep = rows[(y + k) * w + x];
      solid += keep;
    }
    return solid / (w * h);
  }

  function lumaPixels(px) {
    const out = new Array(px.length / 4);
    for (let i = 0, j = 0; i < px.length; i += 4, j++) {
      out[j] = Math.round(0.299 * px[i] + 0.587 * px[i+1] + 0.114 * px[i+2]);
    }
    return out;
  }

  const results = [];
  const shots = {};
  for (const [id, v] of Object.entries(visuals)) {
    const entry = { id, ok: false, error: null, coverage: 0, clipShare: 0, clipBlobShare: 0, meanLuma: 0, compileMs: 0 };
    let prog;
    try {
      const t0 = performance.now();
      const fs = compile(gl.FRAGMENT_SHADER, v.fragment);
      prog = gl.createProgram();
      gl.attachShader(prog, vsFbo); gl.attachShader(prog, fs);
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
      entry.compileMs = Math.round(performance.now() - t0);
    } catch (e) {
      entry.error = String(e.message || e).slice(0, 600);
      results.push(entry); continue;
    }
    gl.useProgram(prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
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

    let a = mkTarget(), b = mkTarget();
    for (const rt of [a, b]) { gl.bindFramebuffer(gl.FRAMEBUFFER, rt.f); gl.clearColor(0,0,0,1); gl.clear(gl.COLOR_BUFFER_BIT); }

    const dt = 1 / 60;
    for (let fr = 0; fr < FRAMES; fr++) {
      const tm = fr * dt;
      const au = audioAt(tm);
      gl.uniform1f(U('u.time'), tm); gl.uniform1f(U('u.dt'), dt);
      for (const k of ['amplitude','bass','mid','treble','beat','beatPhase','onset','bassImpact','level','spectralCentroid','flux','beatCount'])
        gl.uniform1f(U('u.' + k), au[k]);
      gl.uniform4fv(U('u.spectrum[0]'), new Float32Array(au.spectrum));
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, imgTex);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, a.t);
      gl.bindFramebuffer(gl.FRAMEBUFFER, b.f);
      gl.viewport(0, 0, W, H);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      [a, b] = [b, a];
    }
    // tonemapped readback: draw last HDR frame to canvas via simple blit shader
    const blitFS = `#version 300 es
precision highp float; uniform sampler2D uT; in vec2 vUV; out vec4 o;
vec3 tm2(vec3 x){x=(x*(2.51*x+.03))/(x*(2.43*x+.59)+.14);return pow(clamp(x,0.,1.),vec3(1./2.2));}
void main(){ o=vec4(tm2(texture(uT,vUV).rgb),1.); }`;
    const bprog = gl.createProgram();
    gl.attachShader(bprog, vs); gl.attachShader(bprog, compile(gl.FRAGMENT_SHADER, blitFS));
    gl.linkProgram(bprog); gl.useProgram(bprog);
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, a.t);
    gl.uniform1i(gl.getUniformLocation(bprog, 'uT'), 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, W, H);
    gl.drawArrays(gl.TRIANGLES, 0, 3);

    const px = new Uint8Array(W * H * 4);
    gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, px);
    let lit = 0, luma = 0, clipped = 0;
    for (let i = 0; i < px.length; i += 4) {
      const l = 0.299 * px[i] + 0.587 * px[i+1] + 0.114 * px[i+2];
      luma += l;
      if (l > 10) lit++;
      if (px[i] >= 250 && px[i+1] >= 250 && px[i+2] >= 250) clipped++;
    }
    entry.coverage = +(lit / (W * H)).toFixed(3);
    entry.clipShare = +(clipped / (W * H)).toFixed(4);
    entry.clipBlobShare = +clippedBlobShare(px, W, H, clipBlobRadius).toFixed(4);
    entry.meanLuma = +(luma / (W * H) / 255).toFixed(3);
    entry.grid = lumaGrid(px, W, H);
    if (mslSet.has(id)) entry.pixelLuma = lumaPixels(px);
    entry.ok = true;
    shots[id] = canvas.toDataURL('image/png');
    results.push(entry);
    gl.deleteProgram(prog); gl.deleteProgram(bprog);
    gl.deleteTexture(a.t); gl.deleteTexture(b.t);
    gl.deleteFramebuffer(a.f); gl.deleteFramebuffer(b.f);
  }
  return { results, shots };
}, { visuals, audioSrc: audioAt.toString(), clipBlobRadius: CLIP_BLOB_RADIUS, vertex: manifest.wrapper.VERTEX_300, W, H, FRAMES, imgDataUrl, mslIds });

await browser.close();

if (result.fatal) { console.error(result.fatal); process.exit(1); }
for (const [id, dataUrl] of Object.entries(result.shots || {}))
  writeFileSync(join(OUT, id + '.png'), Buffer.from(dataUrl.split(',')[1], 'base64'));
const statsResults = result.results.map(({ pixelLuma, ...entry }) => entry);
writeFileSync(join(OUT, 'stats.json'), JSON.stringify(statsResults, null, 2));

let mslFail = 0;
if (process.platform === 'darwin') {
  mslFail = verifyMSL(result.results);
} else {
  console.log('MSL compile/render validation skipped: requires macOS');
}

let fail = 0;
for (const r of result.results) {
  // Exposure guard: a solid clipped-white area (not thin white line-art) covering
  // more than CLIP_BLOB_LIMIT of the frame is a whiteout regression.
  const flag = !r.ok ? 'COMPILE-FAIL' : r.coverage < 0.01 ? 'BLANK?' : r.clipBlobShare > CLIP_BLOB_LIMIT ? 'WHITEOUT?' : 'ok';
  if (flag !== 'ok') fail++;
  console.log(`${r.id.padEnd(22)} ${flag.padEnd(13)} coverage=${r.coverage} clip=${r.clipShare} blob=${r.clipBlobShare} luma=${r.meanLuma} ${r.error ? '\n  ' + r.error.split('\n')[0] : ''}`);
}
console.log(`\n${result.results.length} visuals, ${fail + mslFail} problem(s). PNGs in ${OUT}`);
process.exit(fail + mslFail ? 2 : 0);

function verifyMSL(webResults) {
  const refs = new Map(webResults.map(r => [r.id, r]));
  const list = pick(manifest.byTarget.msl);
  mkdirSync(CACHE, { recursive: true });
  let failures = 0, rendered = 0, compiled = 0;
  for (const v of list) {
    try {
      withTempDir(`msl-${v.id}`, dir => {
        const metal = join(dir, `${v.id}.metal`);
        writeFileSync(metal, manifest.wrapper.wrapMSL(v.id, v.body, v.header, v.imageInput));
        execFileSync('xcrun', ['metal', `-fmodules-cache-path=${CACHE}`, '-c', metal, '-o', join(dir, `${v.id}.air`)], { stdio: 'pipe' });
        compiled++;
        if (FRAMES !== 1) return;
        const ref = refs.get(v.id);
        if (!ref) {
          console.log(`${v.id.padEnd(22)} MSL render-diff skipped: no "web" target to compare against`);
          return;
        }
        const cfg = join(dir, 'render.json');
        writeFileSync(cfg, JSON.stringify({
          metal,
          function: mslEntryPoint(v.id),
          width: W,
          height: H,
          palette: v.palette,
          params: v.params,
          trailDecay: v.trailDecay,
          audio: audioAt(0),
        }));
        const out = execFileSync('swift', [join(HERE, 'metal-smoke.swift'), cfg], { encoding: 'utf8' });
        const metalResult = JSON.parse(out);
        if (metalResult.skipped) {
          const msg = `MSL render-diff skipped: ${metalResult.skipped}; required on Metal CI lane`;
          if (process.env.CI) {
            failures++;
            console.error(msg);
          } else {
            console.log(msg);
          }
          return;
        }
        rendered++;
        const diff = normalizedPixelDiff(ref.pixelLuma, metalResult.pixelLuma);
        if (diff > MSL_PIXEL_DIFF_LIMIT || metalResult.coverage < 0.01) {
          failures++;
          console.error(`${v.id.padEnd(22)} MSL-DIFF-FAIL diff=${diff.toFixed(3)} coverage=${metalResult.coverage.toFixed(3)}`);
        }
      });
    } catch (e) {
      failures++;
      console.error(`${v.id.padEnd(22)} MSL-FAIL ${(e.stderr || e.stdout || e.message).toString().split('\n')[0]}`);
    }
  }
  if (process.env.CI && FRAMES === 1 && list.some(v => refs.has(v.id)) && rendered === 0) {
    failures++;
    console.error('MSL render-diff required on CI but no Metal render-diff ran');
  }
  console.log(`MSL validation: ${compiled} compile(s), ${rendered} render-diff(s), ${failures} problem(s)`);
  return failures;
}

function normalizedPixelDiff(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== W * H || b.length !== W * H) return 1;
  // `a` comes from gl.readPixels (rows bottom-up, WebGL window origin is
  // bottom-left); `b` comes from Metal getBytes (rows top-down). Compare with
  // a row flip, or every pixel is diffed against its vertical mirror.
  let sum = 0;
  for (let y = 0; y < H; y++) {
    const ra = (H - 1 - y) * W;
    const rb = y * W;
    for (let x = 0; x < W; x++) sum += Math.abs(a[ra + x] - b[rb + x]);
  }
  return sum / (W * H) / 255;
}
