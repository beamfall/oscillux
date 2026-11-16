// SPDX-License-Identifier: AGPL-3.0-only
// Beat-response lint: renders each bundled visual under real WebGL2 (SwiftShader via Playwright
// Chromium, as render.mjs) on a deterministic beat clock, and checks that its frames respond to
// the beat pulse. Per frame it reads the tonemapped image's mean luma and its motion energy (the
// mean absolute luma change from the previous frame). Each signal is detrended (its centred
// one-beat moving average subtracted, which removes the slow camera flight and 32-beat speed
// profile but keeps anything locked to the beat); for it the lint finds the lag, within half a
// beat either way, at which the Pearson correlation with the beat pulse peaks, and the
// beat-locked swing of the signal folded over the beat.
//
//   node tools/shader/beat-lint.mjs [manifest.json ...] [--only id1,id2] [--bpm 120]
//        [--beats 12] [--jobs 6] [--out out/beat-lint]
//
// The manifests default to the host bundle's (originals first, merged as bundle-hosts.mjs does).
// A visual passes when one signal has |r| >= R_MIN at a peak lag of at most one frame and a
// swing of at least its SWING_MIN, and it never flashes more than three times in a second
// (WCAG 2.2 general flash: a pair of opposing changes of 0.1 or more in mean relative luminance
// where the darker state is below 0.8; the frame mean is more lenient than WCAG's area rule).
// Visuals listed as ambient in conformance/shaders/beat-lint.json, each with a reason, are
// measured and reported but cannot fail the response check. Exits 2 on a failure.
//
// The clock has the reaction sampler's shape (crates/oscillux-core/src/reaction.rs, defaults):
// a beat pulse that rises over 30 ms before each beat and decays over 1000/9 ms after it, the
// downbeat pulse of every fourth beat, beatPhase, barPhase and beatCount, and the values a kick
// on each beat gives through the mapper: onset and flux released over 60 ms, bassImpact over
// 150 ms, bass, amplitude and the low spectrum bins raised by the kick. mid, treble and level
// stay constant, so any response the lint sees is to the beat.

import { chromium } from 'playwright';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { loadManifest, mergeVisualSets } from './manifest.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const EXEMPTIONS = join(ROOT, 'conformance', 'shaders', 'beat-lint.json');
const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    out: { type: 'string', default: '' },
    only: { type: 'string', default: '' },
    bpm: { type: 'string', default: '120' },
    beats: { type: 'string', default: '12' },
    jobs: { type: 'string', default: '6' },
  },
});

const W = 160, H = 90;
const FPS = 60;
const WARM_BEATS = 2;
export const R_MIN = 0.35;
export const MAX_LAG = 1;            // frames
const SWING_MIN = { luma: 0.004, motion: 0.0015 };
export const FLASH_STEP = 0.10;      // relative luminance
export const FLASH_MAX = 3;          // flashes in any one second

const BPM = Number(opts.bpm), BEATS = parseInt(opts.beats, 10);
if (!(BPM >= 60 && BPM <= 200) || !(BEATS >= 4)) {
  console.error('beat-lint: --bpm must be in 60..200 and --beats at least 4');
  process.exit(64);
}
const PER_BEAT = FPS * 60 / BPM;
const WARM = Math.round(WARM_BEATS * PER_BEAT);
const FRAMES = WARM + Math.round(BEATS * PER_BEAT);
const OUT = opts.out ? resolve(opts.out) : join(ROOT, 'out', 'beat-lint');
const ONLY = opts.only.split(',').filter(Boolean);
const manifestPaths = positionals.length
  ? positionals
  : ['shaders/originals/manifest.json', 'shaders/manifest.json'].map(p => join(ROOT, p));

// The lint's audio at frame `fr` on a `bpm` clock that starts on a downbeat. Integer frame
// arithmetic keeps every beat on its exact frame.
export function lintAudioAt(fr, bpm) {
  const beats = fr * bpm / 3600;
  const beatCount = Math.floor(beats);
  const beatPhase = beats - beatCount;
  const ms = 60000 / bpm, after = beatPhase * ms, before = (1 - beatPhase) * ms;
  const fired = Math.exp(-after / (1000 / 9));
  const rise = Math.exp(-((before / 30) ** 2));
  const inBar = beatCount % 4;
  const beat = Math.max(fired, rise);
  const downbeat = Math.max(inBar === 0 ? fired : 0, inBar === 3 ? rise : 0);
  const kick = Math.exp(-after / 120);
  const onset = Math.exp(-after / 60);
  const bass = 0.3 + 0.45 * kick;
  const spectrum = [];
  for (let i = 0; i < 64; i++) {
    spectrum[i] = Math.min(1, 0.32 * (1 - 0.4 * i / 63) + 0.6 * kick * Math.exp(-i / 6));
  }
  return {
    amplitude: Math.min(1, 0.35 + 0.35 * kick), level: 0.6, bass, mid: 0.35, treble: 0.3,
    onset, bassImpact: Math.exp(-after / 150), flux: 0.8 * onset, spectralCentroid: 0.4 - 0.1 * kick,
    beat, downbeat, beatPhase, barPhase: (inBar + beatPhase) / 4, beatCount, spectrum,
  };
}

function loadExemptions() {
  const doc = JSON.parse(readFileSync(EXEMPTIONS, 'utf8'));
  const ambient = new Map();
  for (const [i, e] of (doc.ambient ?? []).entries()) {
    if (typeof e.id !== 'string' || typeof e.reason !== 'string' || e.reason.trim().length < 12) {
      throw new Error(`${EXEMPTIONS}: ambient[${i}] needs an id and a reason`);
    }
    if (ambient.has(e.id)) throw new Error(`${EXEMPTIONS}: ${e.id} is listed twice`);
    ambient.set(e.id, e.reason);
  }
  return ambient;
}

// Pearson correlation of x[t] with p[t - lag] over the frames where both exist.
function corr(x, p, lag) {
  let n = 0, sx = 0, sp = 0;
  const from = Math.max(0, lag), to = Math.min(x.length, p.length + lag);
  for (let t = from; t < to; t++) { sx += x[t]; sp += p[t - lag]; n++; }
  const mx = sx / n, mp = sp / n;
  let cxp = 0, cxx = 0, cpp = 0;
  for (let t = from; t < to; t++) {
    const a = x[t] - mx, b = p[t - lag] - mp;
    cxp += a * b; cxx += a * a; cpp += b * b;
  }
  return cxx > 0 && cpp > 0 ? cxp / Math.sqrt(cxx * cpp) : 0;
}

// x less its centred one-beat moving average: changes slower than a beat (the flight's 32-beat
// speed profile, camera drift) are neither response nor noise. A beat pulse and any response
// locked to it pass with only their mean removed, so the correlation sees the beat-locked part.
export function detrend(x, perBeat) {
  const w = Math.max(1, Math.round(perBeat)), lo = Math.floor(w / 2), out = new Array(x.length);
  for (let t = 0; t < x.length; t++) {
    const a = Math.max(0, t - lo), b = Math.min(x.length, t - lo + w);
    let s = 0;
    for (let i = a; i < b; i++) s += x[i];
    out[t] = x[t] - s / (b - a);
  }
  return out;
}

// Peak lag, its correlation (of the detrended signal), and the beat-folded swing of one signal
// measured from WARM on. Luma may answer the beat by brightening or darkening; motion energy
// must rise.
function analyse(x, pulse, signed) {
  const half = Math.floor(PER_BEAT / 2), xd = detrend(x, PER_BEAT);
  let best = { lag: 0, r: 0 };
  for (let lag = -half; lag < PER_BEAT - half; lag++) {
    const r = corr(xd, pulse, lag);
    if ((signed ? Math.abs(r) : r) > (signed ? Math.abs(best.r) : best.r)) best = { lag, r };
  }
  const bins = Math.round(PER_BEAT), fold = new Array(bins).fill(0), count = new Array(bins).fill(0);
  for (let t = 0; t < x.length; t++) { const k = t % bins; fold[k] += x[t]; count[k]++; }
  for (let k = 0; k < bins; k++) fold[k] /= count[k];
  const swing = Math.max(...fold) - Math.min(...fold);
  return { lag: best.lag, r: +best.r.toFixed(3), swing: +swing.toFixed(5), fold: fold.map(v => +v.toFixed(4)) };
}

// The most flashes in any one-second window of mean relative luminance `y`.
export function maxFlashesPerSecond(y, fps) {
  const changes = [];  // frames where an opposing change of FLASH_STEP or more completes
  let dir = 0, hi = y[0], lo = y[0], ext = y[0];
  for (let t = 1; t < y.length; t++) {
    const v = y[t];
    if (dir === 0) {
      hi = Math.max(hi, v); lo = Math.min(lo, v);
      if (hi - lo >= FLASH_STEP) {
        dir = v === hi ? 1 : -1; ext = v;
        if (lo < 0.8) changes.push(t);
      }
    } else if (dir * (v - ext) > 0) {
      ext = v;
    } else if (dir * (ext - v) >= FLASH_STEP) {
      if (Math.min(ext, v) < 0.8) changes.push(t);
      dir = -dir; ext = v;
    }
  }
  let most = 0;
  for (let i = 0, j = 0; j < changes.length; j++) {
    while (changes[j] - changes[i] >= fps) i++;
    most = Math.max(most, Math.floor((j - i + 1) / 2));
  }
  return most;
}

function verdict(m, ambient) {
  const passes = ['luma', 'motion'].filter(k =>
    Math.abs(m[k].r) >= R_MIN && Math.abs(m[k].lag) <= MAX_LAG && m[k].swing >= SWING_MIN[k]);
  const flash = m.flashes > FLASH_MAX;
  if (flash) return { ok: false, flag: 'FLASH', passes };
  if (passes.length) return { ok: true, flag: ambient ? 'ok (ambient)' : 'ok', passes };
  return ambient ? { ok: true, flag: 'ambient', passes } : { ok: false, flag: 'NO-BEAT', passes };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) await main();

async function main() {
  const ambient = loadExemptions();
  const sets = manifestPaths.map(path => {
    const m = loadManifest(path);
    return m.visuals.filter(v => v.targets.includes('web')).map(v => ({
      id: v.id,
      fragment: m.wrapper.wrapGLSL300(v.body, v.imageInput),
      vertex: m.wrapper.VERTEX_300,
      palette: v.palette, params: v.params, trailDecay: v.trailDecay, overrides: v.overrides,
    }));
  });
  const all = mergeVisualSets(sets);
  const unknown = [...ONLY, ...ambient.keys()].filter(id => !all.some(v => v.id === id));
  if (unknown.length) {
    console.error(`beat-lint: unknown visual id(s): ${unknown.join(', ')}`);
    process.exit(2);
  }
  const visuals = all.filter(v => !ONLY.length || ONLY.includes(v.id));
  const audio = Array.from({ length: FRAMES }, (_, fr) => lintAudioAt(fr, BPM));
  const pulse = audio.slice(WARM).map(a => a.beat);
  const measure = (v, got, ms) => {
    if (got.error) return { id: v.id, ok: false, flag: 'COMPILE-FAIL', error: got.error };
    const cut = s => s.slice(WARM);
    const m = {
      luma: analyse(cut(got.luma), pulse, true),
      motion: analyse(cut(got.motion), pulse, false),
      lumSwing: analyse(cut(got.rel), pulse, true).swing,
      flashes: maxFlashesPerSecond(got.rel, FPS),
      meanLuma: +(cut(got.luma).reduce((a, b) => a + b, 0) / (FRAMES - WARM)).toFixed(4),
      series: { luma: got.luma.map(v => +v.toFixed(5)), motion: got.motion.map(v => +v.toFixed(5)) },
    };
    const reason = ambient.get(v.id);
    return { id: v.id, ...verdict(m, reason !== undefined), ...m, renderMs: ms, ...(reason ? { ambient: reason } : {}) };
  };
  mkdirSync(OUT, { recursive: true });

  // SwiftShader renders a page on about one core, so each job is its own browser.
  const results = new Array(visuals.length);
  let next = 0;
  const job = async () => {
    const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader'] });
    const page = await browser.newPage();
    page.on('console', m => { if (m.type() === 'error') console.error('[page]', m.text().slice(0, 400)); });
    await page.evaluate(setUp, { W, H });
    while (next < visuals.length) {
      const i = next++, v = visuals[i];
      const t0 = Date.now();
      const got = await page.evaluate(renderOne, { v, audio, W, H, FPS });
      results[i] = measure(v, got, Date.now() - t0);
    }
    await browser.close();
  };
  const jobs = Math.max(1, Math.min(parseInt(opts.jobs, 10) || 1, visuals.length));
  await Promise.all(Array.from({ length: jobs }, job));

  writeFileSync(join(OUT, 'report.json'), JSON.stringify({ bpm: BPM, beats: BEATS, width: W, height: H, results }, null, 2));
  let fail = 0;
  const fmt = s => `r=${String(s.r).padStart(6)} lag=${String(s.lag).padStart(3)} swing=${s.swing.toFixed(4)}`;
  for (const r of results) {
    if (!r.ok) fail++;
    if (r.error) { console.log(`${r.id.padEnd(20)} ${r.flag}\n  ${r.error.split('\n')[0]}`); continue; }
    console.log(`${r.id.padEnd(20)} ${r.flag.padEnd(13)} luma ${fmt(r.luma)}  motion ${fmt(r.motion)}  Y-swing=${r.lumSwing.toFixed(3)} flashes/s=${r.flashes}`);
  }
  console.log(`\n${results.length} visuals at ${BPM} BPM over ${BEATS} beats: ${fail} failure(s), ` +
    `${results.filter(r => r.flag === 'ambient').length} ambient. Report in ${join(OUT, 'report.json')}`);
  process.exit(fail ? 2 : 0);
}

// In the page: one WebGL2 context, a fullscreen triangle, the artwork stand-in and the blit.
export function setUp({ W, H }) {
  const canvas = document.createElement('canvas');
  canvas.width = W; canvas.height = H;
  const gl = canvas.getContext('webgl2', { preserveDrawingBuffer: true, antialias: false });
  if (!gl) throw new Error('no webgl2');
  gl.getExtension('EXT_color_buffer_float');
  const quad = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quad);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const img = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, img);
  const ipix = new Uint8Array(64 * 64 * 4);
  for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) {
    const i = (y * 64 + x) * 4;
    ipix[i] = 40 + x * 2.5; ipix[i + 1] = 30 + y * 1.8; ipix[i + 2] = 120 + ((x + y) & 15) * 6; ipix[i + 3] = 255;
  }
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 64, 64, 0, gl.RGBA, gl.UNSIGNED_BYTE, ipix);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  window.lint = { gl, quad, img, W, H };
}

// In the page: renders one visual for every frame of `audio` with feedback ping-pong, as
// render.mjs does, and returns per-frame mean luma, relative luminance and motion energy of the
// tonemapped image.
export function renderOne({ v, audio, W, H, FPS }) {
  const { gl, quad, img } = window.lint;
  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const link = (vs, fs) => {
    const p = gl.createProgram();
    gl.attachShader(p, vs); gl.attachShader(p, fs); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    return p;
  };
  let prog, blit;
  try {
    // offscreen passes flip y so PREV() reads line up with vUV (see render.mjs)
    const vsFbo = compile(gl.VERTEX_SHADER, v.vertex.replace('gl_Position = vec4(aPos, 0.0, 1.0);',
      'gl_Position = vec4(aPos.x, -aPos.y, 0.0, 1.0);'));
    prog = link(vsFbo, compile(gl.FRAGMENT_SHADER, v.fragment));
    blit = link(compile(gl.VERTEX_SHADER, v.vertex), compile(gl.FRAGMENT_SHADER, `#version 300 es
precision highp float; uniform sampler2D uT; in vec2 vUV; out vec4 o;
vec3 tm2(vec3 x){x=(x*(2.51*x+.03))/(x*(2.43*x+.59)+.14);return pow(clamp(x,0.,1.),vec3(1./2.2));}
void main(){ o=vec4(tm2(texture(uT,vUV).rgb),1.); }`));
  } catch (e) {
    return { error: String(e.message || e).slice(0, 600) };
  }
  const target = () => {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, W, H, 0, gl.RGBA, gl.HALF_FLOAT, null);
    for (const [k, val] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR],
      [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, k, val);
    const f = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, f);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
    gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
    return { t, f };
  };
  const bind = p => {
    gl.useProgram(p);
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  };
  bind(prog);
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
  const names = ['amplitude', 'bass', 'mid', 'treble', 'beat', 'beatPhase', 'onset', 'bassImpact', 'level',
    'spectralCentroid', 'flux', 'beatCount', 'barPhase', 'downbeat'];
  const loc = Object.fromEntries(names.map(k => [k, U('u.' + k)]));
  const locTime = U('u.time'), locDt = U('u.dt'), locSpec = U('u.spectrum[0]');
  const locT = gl.getUniformLocation(blit, 'uT');

  let a = target(), b = target();
  const px = new Uint8Array(W * H * 4), prev = new Float32Array(W * H);
  const lin = new Float32Array(256);
  for (let i = 0; i < 256; i++) { const c = i / 255; lin[i] = c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; }
  const luma = [], rel = [], motion = [];
  for (let fr = 0; fr < audio.length; fr++) {
    const au = audio[fr];
    bind(prog);
    gl.uniform1f(locTime, fr / FPS); gl.uniform1f(locDt, 1 / FPS);
    for (const k of names) gl.uniform1f(loc[k], au[k]);
    gl.uniform4fv(locSpec, new Float32Array(au.spectrum));
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, img);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, a.t);
    gl.bindFramebuffer(gl.FRAMEBUFFER, b.f);
    gl.viewport(0, 0, W, H);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    [a, b] = [b, a];
    bind(blit);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, a.t);
    gl.uniform1i(locT, 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, W, H);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, px);
    if (window.lint.onFrame) window.lint.onFrame(px, fr);  // limiter-red-audit.mjs
    let l = 0, y = 0, m = 0;
    for (let i = 0, j = 0; i < px.length; i += 4, j++) {
      const g = (0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2]) / 255;
      l += g;
      y += 0.2126 * lin[px[i]] + 0.7152 * lin[px[i + 1]] + 0.0722 * lin[px[i + 2]];
      m += Math.abs(g - prev[j]);
      prev[j] = g;
    }
    luma.push(l / (W * H)); rel.push(y / (W * H)); motion.push(fr ? m / (W * H) : 0);
  }
  gl.deleteProgram(prog); gl.deleteProgram(blit);
  for (const t of [a, b]) { gl.deleteTexture(t.t); gl.deleteFramebuffer(t.f); }
  return { luma, rel, motion };
}
