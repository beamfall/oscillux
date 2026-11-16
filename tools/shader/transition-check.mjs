// SPDX-License-Identifier: AGPL-3.0-only
// Checks the switch transitions and the web host's switch scheduling.
//
//   node tools/shader/transition-check.mjs [manifest.json] [--only id,..] [--json FILE]
//   node tools/shader/transition-check.mjs --host [--only id,..] [--json FILE] [--beat-trace FILE]
//
// Shader mode (WebGL2 on SwiftShader, as render.mjs) renders every transition
// of the manifest (default shaders/originals/manifest.json) at 160x80 into
// RGBA16F, as the hosts do, for three FROM/TO pairs: two live visual pairs
// (both visuals keep running, the outgoing one warmed for 1.5 s and the
// incoming one for the 0.5 s pre-roll) and a static per-pixel noise pair. Each
// pair runs at seeds 0 and 0.618034 and detail reduction 0 and 1, under the
// synthetic music without its beat (steady) and, for the live pairs at
// reduction 0, with it (music). A difference is the mean over pixels of
// (|dR| + |dG| + |dB|) / 3 in linear light, unclamped, summed on the GPU in
// float32. It checks:
//   endpoints: the output at p = 0 against FROM and at p = 1 against TO, each
//     <= 0.03 (the p = 95/96 residual of the old 96-step hosts is reported);
//   pops: the 60 Hz sequence FROM alone, p = 0, 1/96, ..., 1, TO alone, whose
//     largest frame-to-frame difference must be <= 3x its median, on the
//     live pairs under steady music. With the beat the visuals' own flashes
//     (as large with no switch) set the largest step, and on static noise a
//     transition that is still near its ends has a median near 0, so those
//     ratios are reported, not judged.
//
// Host mode serves hosts/web (out/hosts/visuals.json from make host-bundle)
// with requestAnimationFrame driven at 30, 60 and 120 Hz in presentation time,
// switches with the page's trace, and checks the switch timing (same wall time
// at every rate, last blended frame p = 1 exactly, then the incoming visual
// alone), the quantised start against the visible visual's beat and bar, the
// incoming visual's own time when it first shows (>= 0.5 s), and for the
// --only transitions (default portal, ink-bleed, raindrop) the frame-to-frame
// change of the canvas across a 60 Hz switch under the steady music, as in
// shader mode, including the step after it ends (<= 3x its median). It then
// traces the beat clock per frame on the synthetic source and reports its
// alignment with the true beats against the OSC-REACT-SYNC bars (hostBeat).
// Exits 1 when a check fails.
import { chromium } from 'playwright';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { loadManifest } from './manifest.mjs';
import { audioAt } from './synthetic-audio.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    only: { type: 'string', default: '' },
    json: { type: 'string', default: '' },
    host: { type: 'boolean', default: false },
    'beat-trace': { type: 'string', default: '' },
  },
});
const ENDPOINT_LIMIT = 0.03;
const POP_RATIO_LIMIT = 3;
const ONLY = opts.only.split(',').filter(Boolean);

const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader'] });
let failed = false;
try {
  const report = opts.host ? await hostMode() : await shaderMode();
  if (opts.json) writeFileSync(opts.json, JSON.stringify(report, null, 1) + '\n');
} finally {
  await browser.close();
}
process.exit(failed ? 1 : 0);

function fail(message) {
  failed = true;
  console.log(`FAIL ${message}`);
}

async function shaderMode() {
  const manifest = loadManifest(positionals[0] ?? join(ROOT, 'shaders/originals/manifest.json'));
  const pick = ONLY.length ? manifest.transitions.filter(t => ONLY.includes(t.id)) : manifest.transitions;
  if (ONLY.length && pick.length !== ONLY.length) throw new Error(`unknown --only transition among ${ONLY}`);
  const visual = id => {
    const v = manifest.byId.get(id);
    if (!v) throw new Error(`visual ${id} is not in the manifest`);
    return { fragment: manifest.wrapper.wrapGLSL300(v.body, v.imageInput), palette: v.palette, params: v.params, trailDecay: v.trailDecay };
  };
  const pairs = [['aurora', 'reactor'], ['starfield', 'plasma']];
  const visuals = Object.fromEntries([...new Set(pairs.flat())].map(id => [id, visual(id)]));
  const transitions = pick.map(t => ({ id: t.id, fragment: manifest.wrapper.wrapGLSL300(t.body, false, true) }));
  const page = await browser.newPage();
  page.on('console', m => { if (m.type() === 'error') console.error('[page]', m.text().slice(0, 400)); });
  await page.addScriptTag({
    content: `window.__music = ${audioAt.toString()};\nwindow.__steady = ${steadyAudio(audioAt.toString())};`,
  });
  const t0 = Date.now();
  const result = await page.evaluate(renderTransitions, {
    visuals, transitions, pairs, vertex: manifest.wrapper.VERTEX_300,
  });
  if (result.fatal) throw new Error(result.fatal);
  const rows = [];
  const where = r => `${r.pair} ${r.audio} seed ${r.seed} reduce ${r.reduce}`;
  for (const t of result.transitions) {
    if (t.error) { fail(`${t.id}: ${t.error}`); continue; }
    const worst = (key, runs = t.runs) => runs.reduce((a, r) => (r[key] > a[key] ? r : a));
    // pops are judged on the live pairs under steady music; with the beat the
    // visuals' own flashes (as large without a switch) and on static noise a
    // median near 0 (a transition that is still at the ends) are reported only
    const gated = t.runs.filter(r => r.pair !== 'noise' && r.audio === 'steady');
    const row = {
      id: t.id, p0: worst('p0'), p1: worst('p1'), p95: worst('p95'), p95Max: worst('p95Max'), pop: worst('popRatio', gated),
      music: worst('popRatio', t.runs.filter(r => r.audio === 'music')), noise: worst('popRatio', t.runs.filter(r => r.pair === 'noise')),
    };
    rows.push(row);
    if (!(row.p0.p0 <= ENDPOINT_LIMIT)) fail(`${t.id}: p=0 differs from FROM by ${row.p0.p0.toFixed(4)} (${where(row.p0)})`);
    if (!(row.p1.p1 <= ENDPOINT_LIMIT)) fail(`${t.id}: p=1 differs from TO by ${row.p1.p1.toFixed(4)} (${where(row.p1)})`);
    if (!(row.pop.popRatio <= POP_RATIO_LIMIT)) {
      fail(`${t.id}: largest step ${row.pop.popMax.toFixed(4)} at ${row.pop.popAt} is ${row.pop.popRatio.toFixed(2)}x the median ${row.pop.popMedian.toFixed(4)} (${where(row.pop)})`);
    }
  }
  console.log('transition          p=0     p=1     p=95/96 (pixel max)   pop: steady (step, pair)        music  noise');
  for (const r of rows) {
    console.log(`${r.id.padEnd(18)} ${r.p0.p0.toFixed(4)}  ${r.p1.p1.toFixed(4)}  ${r.p95.p95.toFixed(4)} (${r.p95Max.p95Max.toFixed(3)})`
      + `       ${r.pop.popRatio.toFixed(2).padStart(5)} (${String(r.pop.popAt).padStart(2)}, ${r.pop.pair.padEnd(16)})`
      + `  ${r.music.popRatio.toFixed(2).padStart(5)}  ${r.noise.popRatio.toFixed(2).padStart(9)}`);
  }
  for (const audio of ['steady', 'music']) {
    const worst = {};
    for (const a of result.alone.filter(x => x.audio === audio)) {
      if (!worst[a.visual] || a.ratio > worst[a.visual].ratio) worst[a.visual] = a;
    }
    console.log(`control, each visual alone (no switch), ${audio === 'music' ? 'music with its beat' : 'steady music'}: `
      + Object.values(worst).map(a => `${a.visual} ${a.ratio.toFixed(2)}x (step ${a.at})`).join(', '));
  }
  const maxOf = (key, field = key) => Math.max(...rows.map(r => r[key][field]));
  console.log(`transition-check: ${rows.length} transitions x ${result.transitions[0]?.runs.length ?? 0} runs in ${((Date.now() - t0) / 1000).toFixed(1)} s;`
    + ` worst p=0 ${maxOf('p0').toFixed(4)}, p=1 ${maxOf('p1').toFixed(4)}, pop ratio ${maxOf('pop', 'popRatio').toFixed(2)}`
    + ` (limits ${ENDPOINT_LIMIT}, ${POP_RATIO_LIMIT}x)${failed ? ' FAILED' : ''}`);
  return { mode: 'shader', limits: { endpoint: ENDPOINT_LIMIT, popRatio: POP_RATIO_LIMIT }, alone: result.alone, transitions: result.transitions };
}

// Runs in the page. Returns per transition the runs over pairs, seeds and
// detail reductions, each with its endpoint differences and its sequence.
// The synthetic music's source without its beat: the levels and spectrum
// still move, but nothing pulses, so the visuals' own beat flashes do not mask
// a pop. Used by shader mode and by the host's live pop runs.
function steadyAudio(src) {
  const STEADY = [['const beatCount = Math.floor(beats);', 'const beatCount = 0;'], ['const beatPhase = beats - beatCount;', 'const beatPhase = 0.5;'],
    ['const beat = Math.exp(-beatT * 9);', 'const beat = 0;'], ['const onset = Math.exp(-((tm % (beatIvl / 2))) * 16);', 'const onset = 0;'],
    ['const bassImpact = Math.exp(-beatT * 6);', 'const bassImpact = 0;']];
  for (const [a, b] of STEADY) {
    if (!src.includes(a)) throw new Error(`synthetic-audio.mjs no longer has \`${a}\``);
    src = src.replace(a, b);
  }
  return src;
}

// The whole synthetic-audio module without its beat, for the host: the host
// analyses syntheticPcm through the DSP rather than reading audioAt, so the
// loop drops its kick, hat and off-beat bass and keeps the pad.
function steadyModule(src) {
  const STEADY = [['let s = (b % 4 === 0 ? 0.9 : 0.6) * kick[j];', 'let s = 0;'],
    ['if (j >= HALF) s = s + (bar >= 4 ? 0.2 : 0.12) * hat[j - HALF] + 0.3 * bass[bar & 1][j - HALF];', '']];
  src = steadyAudio(src);
  for (const [a, b] of STEADY) {
    if (!src.includes(a)) throw new Error(`synthetic-audio.mjs no longer has \`${a}\``);
    src = src.replace(a, b);
  }
  return src;
}

async function renderTransitions({ visuals, transitions, pairs, vertex }) {
  const music = window.__music, steady = window.__steady;
  let audioAt = music;
  const W = 160, H = 80, DT = 1 / 60, STEPS = 96, BLOCK = 16;
  const OUT_WARM = 90, IN_WARM = 30, SEQ = STEPS + 2;
  const canvas = document.createElement('canvas');
  const gl = canvas.getContext('webgl2', { antialias: false });
  if (!gl || !gl.getExtension('EXT_color_buffer_float')) return { fatal: 'WebGL2 with EXT_color_buffer_float is required' };
  const quad = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quad);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const vsFbo = compile(gl.VERTEX_SHADER, vertex.replace('gl_Position = vec4(aPos, 0.0, 1.0);', 'gl_Position = vec4(aPos.x, -aPos.y, 0.0, 1.0);'));
  const link = fs => {
    const p = gl.createProgram();
    gl.attachShader(p, vsFbo); gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fs));
    gl.bindAttribLocation(p, 0, 'aPos');
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    return p;
  };
  const target = (w, h, internal = gl.RGBA16F, type = gl.HALF_FLOAT, data = null) => {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, internal, w, h, 0, gl.RGBA, type, data);
    const filter = internal === gl.RGBA32F ? gl.NEAREST : gl.LINEAR;
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const f = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, f);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
    gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
    return { t, f, w, h };
  };
  // The difference of two W x H textures: each texel of a (W/16) x (H/16)
  // float32 target sums a 16 x 16 block, read back and summed here.
  const diffProg = link(`#version 300 es
precision highp float; uniform sampler2D uA, uB; out vec4 o;
void main(){ ivec2 b = ivec2(gl_FragCoord.xy) * ${BLOCK}; float s = 0.0, m = 0.0;
  for (int y = 0; y < ${BLOCK}; y++) for (int x = 0; x < ${BLOCK}; x++) {
    vec3 d = abs(texelFetch(uA, b + ivec2(x, y), 0).rgb - texelFetch(uB, b + ivec2(x, y), 0).rgb);
    float e = (d.r + d.g + d.b) / 3.0; s += e; m = max(m, e); }
  o = vec4(s, m, 0.0, 1.0); }`);
  const sums = target(W / BLOCK, H / BLOCK, gl.RGBA32F, gl.FLOAT);
  const sumPx = new Float32Array((W / BLOCK) * (H / BLOCK) * 4);
  function diff(a, b) {
    gl.useProgram(diffProg);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, a.t);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, b.t);
    gl.uniform1i(gl.getUniformLocation(diffProg, 'uA'), 0);
    gl.uniform1i(gl.getUniformLocation(diffProg, 'uB'), 1);
    gl.bindFramebuffer(gl.FRAMEBUFFER, sums.f);
    gl.viewport(0, 0, sums.w, sums.h);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.readPixels(0, 0, sums.w, sums.h, gl.RGBA, gl.FLOAT, sumPx);
    let s = 0;
    diff.max = 0;
    for (let i = 0; i < sumPx.length; i += 4) { s += sumPx[i]; diff.max = Math.max(diff.max, sumPx[i + 1]); }
    return s / (W * H);
  }
  const image = gl.createTexture();
  {
    const px = new Uint8Array(64 * 64 * 4);
    for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) {
      const i = (y * 64 + x) * 4;
      px[i] = 40 + x * 2.5; px[i + 1] = 30 + y * 1.8; px[i + 2] = 120 + ((x + y) & 15) * 6; px[i + 3] = 255;
    }
    gl.bindTexture(gl.TEXTURE_2D, image);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 64, 64, 0, gl.RGBA, gl.UNSIGNED_BYTE, px);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  }
  const KEYS = ['amplitude', 'bass', 'mid', 'treble', 'beat', 'beatPhase', 'onset', 'bassImpact', 'level', 'spectralCentroid', 'flux', 'beatCount'];
  // The hosts' uniforms (hosts/web/host.js) for a pass at time tm.
  function uniforms(p, v, tm, p0, reduce) {
    const U = n => gl.getUniformLocation(p, n), au = audioAt(tm);
    gl.uniform2f(U('u.resolution'), W, H);
    gl.uniform1f(U('u.time'), tm);
    gl.uniform1f(U('u.dt'), DT);
    gl.uniform1f(U('u.sensitivity'), 1);
    gl.uniform1f(U('u.param0'), v.params[0]); gl.uniform1f(U('u.param1'), v.params[1]); gl.uniform1f(U('u.param2'), v.params[2]);
    gl.uniform1f(U('u.trailDecay'), v.trailDecay);
    gl.uniform4f(U('u.accent'), 0.15, 0.9, 0.72, 1);
    gl.uniform4f(U('u.motion'), 0, 0, 0, 0);
    gl.uniform4f(U('u.palette'), ...v.palette);
    gl.uniform4f(U('u.presentation0'), ...p0);
    gl.uniform4f(U('u.presentation1'), 1, reduce, 0, 0);
    gl.uniform4f(U('u.safeRect'), 0.05, 0.05, 0.05, 0.05);
    for (const k of KEYS) gl.uniform1f(U('u.' + k), au[k]);
    gl.uniform4fv(U('u.spectrum[0]'), new Float32Array(au.spectrum));
    gl.uniform1i(U('uImage'), 0);
    gl.uniform1i(U('uPrev'), 1);
  }
  function pass(p, v, tm, p0, reduce, tex0, tex1, dst) {
    gl.useProgram(p);
    uniforms(p, v, tm, p0, reduce);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, tex0);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, tex1);
    gl.bindFramebuffer(gl.FRAMEBUFFER, dst.f);
    gl.viewport(0, 0, W, H);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
  // A visual's frames from..from+count-1 with live feedback, one target each,
  // at detail reduction `reduce`.
  function frames(v, from, count, reduce) {
    const p = link(v.fragment);
    const kept = [];
    let prev = target(W, H);
    for (let f = 0; f < from + count; f++) {
      const next = target(W, H);
      pass(p, v, f * DT, [0, 1, 0, 0], reduce, image, prev.t, next);
      if (f < from || f === from) free(prev);
      if (f >= from) kept.push(next);
      prev = next;
    }
    gl.deleteProgram(p);
    return kept;
  }
  function free(t) { gl.deleteTexture(t.t); gl.deleteFramebuffer(t.f); }
  function noise(seed) {
    let s = seed >>> 0;
    const px = new Float32Array(W * H * 4);
    for (let i = 0; i < px.length; i++) {
      s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
      px[i] = (i & 3) === 3 ? 1 : s / 4294967296;
    }
    return target(W, H, gl.RGBA16F, gl.FLOAT, px);
  }
  // One source at a time (its frames are freed after it): FROM[k] and TO[k]
  // for k = 0..SEQ-1, the incoming visual and the time of TO[k] (the
  // incoming visual's uniforms drive the transition, as in the hosts).
  const specs = [];
  for (const reduce of [0, 1]) {
    for (const [a, b] of pairs) {
      specs.push({ pair: `${a}->${b}`, audio: 'steady', reduce, a, b });
      if (reduce === 0) specs.push({ pair: `${a}->${b}`, audio: 'music', reduce, a, b });
    }
    specs.push({ pair: 'noise', audio: 'steady', reduce, b: pairs[0][1] });
  }
  const mixes = [target(W, H), target(W, H)];
  const out = transitions.map(t => ({ id: t.id, error: null, runs: [] }));
  // the same pop measure on each visual alone, with no switch: a control
  const alone = [];
  const ratioOf = steps => {
    const sorted = [...steps].sort((x, y) => x - y), median = sorted[sorted.length >> 1], max = sorted.at(-1);
    return { median, max, at: steps.indexOf(max), ratio: median > 0 ? max / median : (max > 0 ? Infinity : 0) };
  };
  const progs = transitions.map((t, i) => {
    try { return link(t.fragment); } catch (e) { out[i].error = String(e.message || e).slice(0, 600); return null; }
  });
  for (const spec of specs) {
    audioAt = spec.audio === 'music' ? music : steady;
    const from = spec.a ? frames(visuals[spec.a], OUT_WARM, SEQ, spec.reduce) : Array(SEQ).fill(noise(1));
    const to = spec.a ? frames(visuals[spec.b], IN_WARM, SEQ, spec.reduce) : Array(SEQ).fill(noise(2));
    const v = visuals[spec.b], toTime = k => (IN_WARM + k) * DT;
    if (spec.a) {
      for (const [visual, seq] of [[spec.a, from], [spec.b, to]]) {
        const steps = seq.slice(1).map((f, k) => diff(f, seq[k]));
        alone.push({ visual, audio: spec.audio, reduce: spec.reduce, ...ratioOf(steps) });
      }
    }
    transitions.forEach((t, i) => {
      const p = progs[i];
      if (!p) return;
      for (const seed of [0, 0.618034]) {
        const run = { pair: spec.pair, audio: spec.audio, seed, reduce: spec.reduce, p0: 0, p1: 0, p95: 0, p95Max: 0, steps: [] };
        // sequence: FROM[0] alone, then blends k = 0..96 at p = k / 96 on
        // FROM[k + 1], TO[k + 1], then TO[97] alone
        let prev = from[0];
        for (let k = 0; k <= STEPS; k++) {
          const dst = mixes[k & 1];
          pass(p, v, toTime(k + 1), [k / STEPS, seed, 0, 0], spec.reduce, from[k + 1].t, to[k + 1].t, dst);
          if (k === 0) run.p0 = diff(dst, from[k + 1]);
          if (k === STEPS - 1) { run.p95 = diff(dst, to[k + 1]); run.p95Max = diff.max; }
          if (k === STEPS) run.p1 = diff(dst, to[k + 1]);
          run.steps.push(diff(dst, prev));
          prev = dst;
        }
        run.steps.push(diff(to[STEPS + 1], prev));
        const sorted = [...run.steps].sort((x, y) => x - y);
        run.popMedian = sorted[sorted.length >> 1];
        run.popMax = sorted[sorted.length - 1];
        run.popAt = run.steps.indexOf(run.popMax);
        run.popRatio = run.popMedian > 0 ? run.popMax / run.popMedian : (run.popMax > 0 ? Infinity : 0);
        out[i].runs.push(run);
      }
    });
    for (const f of new Set([...from, ...to])) free(f);
  }
  return { transitions: out, alone };
}

// ---- host mode -------------------------------------------------------------

async function hostPage(params, steady = false) {
  // here, not at module level: the run at the top of the file starts before
  // a module-level const below it is initialised
  const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json' };
  const page = await browser.newPage({ viewport: { width: 320, height: 180 } });
  page.on('console', m => { if (m.type() === 'error') console.error('[page]', m.text().slice(0, 400)); });
  page.on('pageerror', e => console.error('[page]', String(e).slice(0, 400)));
  await page.route('http://oscillux.test/**', route => {
    const path = join(ROOT, decodeURIComponent(new URL(route.request().url()).pathname));
    if (!path.startsWith(ROOT + '/')) return route.fulfill({ status: 403 });
    try {
      let body = readFileSync(path);
      if (steady && path === join(ROOT, 'tools/shader/synthetic-audio.mjs')) body = steadyModule(body.toString());
      return route.fulfill({ status: 200, contentType: TYPES[extname(path)] ?? 'application/octet-stream', body });
    } catch {
      return route.fulfill({ status: 404 });
    }
  });
  // requestAnimationFrame at a fixed rate in presentation time; __tick(n, hz)
  // runs n display frames and returns, per frame, its time and the mean
  // linear-light change of the canvas from the frame before (8-bit sRGB
  // decoded with the 2.2 power of the present pass).
  await page.addInitScript(() => {
    const queue = [];
    let now = 1000, last = null;
    window.requestAnimationFrame = cb => queue.push(cb);
    const lin = new Float32Array(256).map((_, i) => (i / 255) ** 2.2);
    window.__tick = (n, hz, grab) => {
      const rows = [];
      const gl = grab && document.getElementById('c').getContext('webgl2');
      for (let i = 0; i < n; i++) {
        now += 1000 / hz;
        for (const cb of queue.splice(0)) cb(now);
        if (!gl) continue;
        const w = gl.drawingBufferWidth, h = gl.drawingBufferHeight, px = new Uint8Array(w * h * 4);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
        let d = 0;
        if (last && last.length === px.length) {
          for (let j = 0; j < px.length; j += 4) {
            d += (Math.abs(lin[px[j]] - lin[last[j]]) + Math.abs(lin[px[j + 1]] - lin[last[j + 1]]) + Math.abs(lin[px[j + 2]] - lin[last[j + 2]])) / 3;
          }
          d /= w * h;
        }
        last = px;
        rows.push([now, d]);
      }
      return rows;
    };
  });
  await page.goto(`http://oscillux.test/hosts/web/index.html?${new URLSearchParams(params)}`);
  await page.waitForFunction(() => window.__oscilluxTrace && typeof window.__tick === 'function', null, { timeout: 120000, polling: 100 });
  return page;
}

// One switch from `from` to the next visual at `hz`. Returns the trace of the
// switch, its frames and, with grab, the canvas changes per display frame.
async function hostSwitch({ hz, quantise, transition, grab, steady, from = 'aurora', warmSeconds = 1.5 }) {
  const params = { visual: from, size: '160x90', quality: '3', trace: '', quantise, colour: 'manifest' };
  if (transition) params.transition = transition;
  const page = await hostPage(params, steady);
  try {
    // run until the first visual draws, then let the next transition compile
    for (let i = 0; i < 200; i++) {
      await page.evaluate(([n, hz]) => window.__tick(n, hz, false), [5, hz]);
      if (await page.evaluate(() => /frame \d+/.test(document.getElementById('status').textContent))) break;
      await page.waitForTimeout(20);
    }
    await page.evaluate(([n, hz]) => window.__tick(n, hz, false), [Math.round(warmSeconds * hz), hz]);
    await page.waitForTimeout(400);
    // the next visual's program, then the switch
    await page.evaluate(() => document.getElementById('next').click());
    let rows = [];
    for (let i = 0; i < 400; i++) {
      rows = rows.concat(await page.evaluate(([n, hz, grab]) => window.__tick(n, hz, grab), [Math.max(1, Math.round(hz / 20)), hz, grab]));
      const s = await page.evaluate(() => window.__oscilluxTrace.switches.at(-1));
      if (s && s.doneSeconds !== null) break;
      await page.waitForTimeout(5);
    }
    rows = rows.concat(await page.evaluate(([n, hz, grab]) => window.__tick(n, hz, grab), [Math.round(hz / 4), hz, grab]));
    const trace = await page.evaluate(() => window.__oscilluxTrace);
    return { trace, rows };
  } finally {
    await page.close();
  }
}

async function hostMode() {
  const report = { mode: 'host', runs: [], pops: [] };
  const wall = {};
  for (const quantise of ['none', 'bar', 'beat']) {
    for (const hz of [30, 60, 120]) {
      const { trace } = await hostSwitch({ hz, quantise, transition: 'dissolve' });
      const s = trace.switches.at(-1);
      const frames = trace.frames.filter(f => f[6] === trace.switches.length);
      if (!s || s.doneSeconds === null) { fail(`${quantise} ${hz} Hz: the switch did not finish`); continue; }
      const frame = 1 / hz;
      const blended = frames.filter(f => f[3] > 0);
      const first = blended[0], last = blended.at(-1);
      const run = {
        quantise, hz, requestSeconds: s.requestSeconds, startSeconds: s.startSeconds, endSeconds: s.endSeconds,
        applied: s.quantise, firstBlended: first[1], done: last[1], lastP: last[3], lastState: last[2],
        ownSecondsShown: s.ownSecondsShown, blendedFrames: blended.length,
        monotonic: blended.every((f, i) => i === 0 || f[3] >= blended[i - 1][3]),
        onlyLastIsOne: blended.slice(0, -1).every(f => f[3] < 1),
        framesAfterDone: frames.filter(f => f[1] > last[1]).length,
      };
      run.wallSeconds = run.done - run.requestSeconds;
      run.blendSeconds = run.done - run.firstBlended;
      // progress is linear in presentation time, so a line through the frames
      // strictly inside the blend gives its start and length free of where
      // the frames fall
      const inner = blended.filter(f => f[3] < 1);
      if (inner.length >= 2) {
        const n = inner.length, mT = inner.reduce((a, f) => a + f[1], 0) / n, mP = inner.reduce((a, f) => a + f[3], 0) / n;
        const slope = inner.reduce((a, f) => a + (f[1] - mT) * (f[3] - mP), 0) / inner.reduce((a, f) => a + (f[1] - mT) ** 2, 0);
        run.fitStartSeconds = mT - mP / slope;
        run.fitSeconds = 1 / slope;
      }
      // the beat clock the visuals react to, traced per frame (beat count plus
      // phase, and bar phase), gives the presentation time of the first beat
      // or bar boundary after the pre-roll, interpolated between the frames
      // either side of it; its slope over the frames before the blend gives
      // the beat period
      if (quantise !== 'none') {
        const pre = frames.filter(f => f[3] === 0);
        const n = pre.length, bt = pre.map(f => f[7]), tt = pre.map(f => f[1]);
        const mT = tt.reduce((a, b) => a + b) / n, mB = bt.reduce((a, b) => a + b) / n;
        const slope = tt.reduce((a, t, i) => a + (t - mT) * (bt[i] - mB), 0) / tt.reduce((a, t) => a + (t - mT) ** 2, 0);
        const earliest = s.requestSeconds + 0.5;
        let boundary = null;
        for (let i = 1; i < frames.length && boundary === null; i++) {
          const a = frames[i - 1], b = frames[i];
          let x = null;
          if (quantise === 'beat' && Math.floor(b[7]) > Math.floor(a[7])) x = (Math.floor(b[7]) - a[7]) / (b[7] - a[7]);
          if (quantise === 'bar' && b[8] < a[8]) x = (1 - a[8]) / (b[8] + 1 - a[8]);
          const at = x === null ? null : a[1] + x * (b[1] - a[1]);
          if (at !== null && at >= earliest - 1e-9) boundary = at;
        }
        run.beatsPerSecond = slope;
        run.boundarySeconds = boundary;
        run.waitSeconds = s.startSeconds - earliest;
        if (boundary === null) { fail(`${quantise} ${hz} Hz: no traced ${quantise} boundary after the pre-roll`); continue; }
        run.startOffsetFrames = (first[1] - boundary) / frame;
        if (!(Math.abs(run.startOffsetFrames) <= 1)) fail(`${quantise} ${hz} Hz: blend starts ${run.startOffsetFrames.toFixed(2)} frames from the visible ${quantise}`);
        if (!(run.waitSeconds <= 4 / slope + frame)) fail(`${quantise} ${hz} Hz: waited ${run.waitSeconds.toFixed(3)} s after the pre-roll`);
      } else {
        run.startOffsetFrames = (first[1] - (s.requestSeconds + 0.5)) / frame;
        if (!(run.startOffsetFrames >= 0 && run.startOffsetFrames <= 1)) fail(`none ${hz} Hz: blend starts ${run.startOffsetFrames.toFixed(2)} frames after the pre-roll`);
      }
      if (run.lastP !== 1 || !run.onlyLastIsOne || !run.monotonic) fail(`${quantise} ${hz} Hz: last blended p ${run.lastP}, monotonic ${run.monotonic}`);
      if (run.lastState !== 4 || run.framesAfterDone !== 0) fail(`${quantise} ${hz} Hz: the switch did not end on its p = 1 frame`);
      if (!(run.ownSecondsShown >= 0.5)) fail(`${quantise} ${hz} Hz: incoming visual had run ${run.ownSecondsShown} s when it showed`);
      (wall[quantise] ??= []).push(run);
      report.runs.push(run);
      console.log(`${quantise.padEnd(4)} ${String(hz).padStart(3)} Hz: request ${run.requestSeconds.toFixed(3)} start ${run.startSeconds.toFixed(3)}`
        + ` (offset ${run.startOffsetFrames.toFixed(2)} frames) first blended ${run.firstBlended.toFixed(3)} done ${run.done.toFixed(3)}`
        + ` blend ${run.blendSeconds.toFixed(3)} s, ${run.blendedFrames} frames, last p ${run.lastP}, own time shown ${run.ownSecondsShown.toFixed(3)} s`);
    }
  }
  // the same switch at every rate: the blend follows its schedule in
  // presentation time (the fitted line within 1 ms, the first blended and the
  // p = 1 frames each within one frame after the scheduled start and end), and
  // the schedule is the 60 Hz one within 1 ms wherever the music runs at the
  // same speed: a beat-length blend comes from the tracked tempo, which settles
  // slightly differently at each rate. The synthetic music runs with the
  // visuals, at half speed at 30 Hz, so its beat (and a beat-length blend) is
  // longer there.
  for (const [q, runs] of Object.entries(wall)) {
    const ref = runs.find(r => r.hz === 60);
    for (const r of runs) {
      const frame = 1 / r.hz, sched = r.endSeconds - r.startSeconds;
      r.fitStartErrorMs = (r.fitStartSeconds - r.startSeconds) * 1000;
      r.fitLengthErrorMs = (r.fitSeconds - sched) * 1000;
      r.firstAfterStartFrames = (r.firstBlended - r.startSeconds) / frame;
      r.doneAfterEndFrames = (r.done - r.endSeconds) / frame;
      if (!(Math.abs(r.fitStartErrorMs) <= 1 && Math.abs(r.fitLengthErrorMs) <= 1)) fail(`${q} ${r.hz} Hz: progress starts ${r.fitStartErrorMs.toFixed(2)} ms and runs ${r.fitLengthErrorMs.toFixed(2)} ms off its ${sched.toFixed(3)} s schedule`);
      if (!(r.firstAfterStartFrames >= -1e-6 && r.firstAfterStartFrames <= 1 + 1e-6 && r.doneAfterEndFrames >= -1e-6 && r.doneAfterEndFrames <= 1 + 1e-6)) {
        fail(`${q} ${r.hz} Hz: first blended ${r.firstAfterStartFrames.toFixed(2)} frames after the start, p = 1 ${r.doneAfterEndFrames.toFixed(2)} after the end`);
      }
      const halfSpeed = q !== 'none' && r.hz < 60;
      r.scheduleDeltaMs = (sched - (ref.endSeconds - ref.startSeconds)) * 1000;
      if (!halfSpeed && !(Math.abs(r.scheduleDeltaMs) <= 1)) fail(`${q} ${r.hz} Hz: ${sched.toFixed(3)} s schedule, ${r.scheduleDeltaMs.toFixed(3)} ms off the 60 Hz one`);
      console.log(`${q.padEnd(4)} ${String(r.hz).padStart(3)} Hz: schedule ${sched.toFixed(3)} s (${r.scheduleDeltaMs.toFixed(3)} ms off 60 Hz), fitted start ${r.fitStartErrorMs.toFixed(3)} ms, length ${r.fitLengthErrorMs.toFixed(3)} ms off;`
        + ` first blended ${r.firstAfterStartFrames.toFixed(2)}, p = 1 ${r.doneAfterEndFrames.toFixed(2)} frames after`);
    }
  }
  // live switches at 60 Hz under the steady music: the canvas change per
  // frame across the switch, the step after the last blended frame included
  for (const transition of ONLY.length ? ONLY : ['portal', 'ink-bleed', 'raindrop']) {
    const { trace, rows } = await hostSwitch({ hz: 60, quantise: 'none', transition, grab: true, steady: true });
    const s = trace.switches.at(-1);
    const inSwitch = rows.filter(r => r[0] >= trace.frames.find(f => f[3] > 0)[0] && r[0] <= trace.frames.find(f => f[2] === 4)[0] + 1000 / 60 + 1e-6);
    const d = inSwitch.map(r => r[1]);
    const sorted = [...d].sort((a, b) => a - b), median = sorted[sorted.length >> 1], max = sorted.at(-1);
    const endStep = d.at(-1);
    const pop = { transition: s.transition, frames: d.length, median, max, ratio: max / median, endStep, endRatio: endStep / median };
    report.pops.push(pop);
    console.log(`live ${transition}: ${d.length} frames, median change ${median.toFixed(5)}, largest ${max.toFixed(5)} (${pop.ratio.toFixed(2)}x),`
      + ` step after the last blended frame ${endStep.toFixed(5)} (${pop.endRatio.toFixed(2)}x)`);
    if (s.transition !== transition) fail(`live ${transition}: switch used ${s.transition}`);
    if (!(pop.ratio <= POP_RATIO_LIMIT)) fail(`live ${transition}: largest change ${pop.ratio.toFixed(2)}x the median`);
  }
  report.beat = await hostBeat();
  return report;
}

// The beat clock the visuals react to on the synthetic source (a kick on every
// beat at 125 BPM from media time 0, analysed with no latency, so photon time
// is media time), traced per stepped frame at 30, 60 and 120 Hz: the same per
// step at every rate, since the source runs on the step clock. After an 8 s
// lock-in, as in make reaction-photon, the beat pulse's peak frames and the
// sub-frame times at which the locked beat position crosses an integer are
// measured against the nearest true beat, and reported against the
// OSC-REACT-SYNC bars (every peak within one frame, mean |offset| <= 8 ms,
// crossing jitter <= 4 ms). A missed beat, a rate whose trace differs, or a
// peak more than one frame off fails. --beat-trace FILE writes the 60 Hz
// trace in the format of the Apple host's -beat-trace, one row per line.
async function hostBeat() {
  const BEAT_MS = 60000 / 125, STEP_MS = 1000 / 60, WARMUP_MS = 8000, SECONDS = 40;
  const traces = {};
  for (const hz of [30, 60, 120]) {
    const page = await hostPage({ visual: 'aurora', size: '160x90', quality: '3', trace: '', colour: 'manifest' });
    try {
      for (let i = 0; i < 2000; i++) {
        await page.evaluate(([n, hz]) => window.__tick(n, hz, false), [hz, hz]);
        if (await page.evaluate(() => window.__oscilluxTrace.beats.length) >= SECONDS * 60) break;
      }
      traces[hz] = (await page.evaluate(() => window.__oscilluxTrace.beats)).slice(0, SECONDS * 60);
    } finally {
      await page.close();
    }
  }
  const ref = traces[60];
  if (opts['beat-trace']) writeFileSync(opts['beat-trace'], ref.map(r => [r[0], r[1], r[2], r[3] ? 1 : 0, r[4]].join(' ')).join('\n') + '\n');
  const same = [30, 120].every(hz => JSON.stringify(traces[hz]) === JSON.stringify(ref));
  if (!same) fail('beat: the 30 or 120 Hz trace differs from the 60 Hz one');
  // row: [steps after the frame, beat position, pulse, locked, tempo]; the
  // frame sampled media time (steps - 1) / 60 s
  const at = r => (r[0] - 1) * STEP_MS;
  const nearest = t => t - Math.round(t / BEAT_MS) * BEAT_MS;
  const peaks = [], crossings = [];
  for (let i = 1; i < ref.length - 1; i++) {
    const [a, b, c] = [ref[i - 1], ref[i], ref[i + 1]];
    if (b[2] > 0.5 && b[2] > a[2] && b[2] >= c[2]) peaks.push(at(b));
    if (a[3] && b[3] && Math.floor(b[1]) > Math.floor(a[1]) && b[2] > 0.5) {
      crossings.push(at(a) + (Math.floor(b[1]) - a[1]) / (b[1] - a[1]) * STEP_MS);
    }
  }
  const stats = v => {
    const n = v.length, mean = v.reduce((x, y) => x + y, 0) / n;
    return { n, mean, meanAbs: v.reduce((x, y) => x + Math.abs(y), 0) / n,
      sd: Math.sqrt(v.reduce((x, y) => x + (y - mean) ** 2, 0) / n), min: Math.min(...v), max: Math.max(...v) };
  };
  const late = peaks.filter(t => t >= WARMUP_MS);
  const peak = stats(late.map(nearest)), crossing = stats(crossings.filter(t => t >= WARMUP_MS).map(nearest));
  const first = Math.ceil(WARMUP_MS / BEAT_MS), beats = Math.floor(at(ref.at(-1)) / BEAT_MS) - first + 1;
  const missed = Array.from({ length: beats }, (_, k) => (first + k) * BEAT_MS)
    .filter(b => !late.some(t => Math.abs(t - b) < BEAT_MS / 4)).length;
  const last = ref.at(-1), withinFrame = peak.min >= -STEP_MS - 1e-9 && peak.max <= STEP_MS + 1e-9;
  const out = { seconds: SECONDS, sameAtEveryRate: same, tempo: last[4], locked: !!last[3], beats, missed, peak, crossing,
    meetsReactSync: withinFrame && peak.meanAbs <= 8 && crossing.sd <= 4 && missed === 0 };
  const show = x => `n ${x.n} mean ${x.mean.toFixed(3)} mean|.| ${x.meanAbs.toFixed(3)} sd ${x.sd.toFixed(3)} min ${x.min.toFixed(3)} max ${x.max.toFixed(3)} ms`;
  console.log(`beat: ${SECONDS} s, same trace at 30/60/120 Hz ${same}, tempo ${last[4].toFixed(2)} BPM, locked ${out.locked}, ${missed} of ${beats} beats missed`);
  console.log(`beat: pulse peak frames ${show(peak)}`);
  console.log(`beat: beat-position crossings ${show(crossing)}`);
  console.log(`beat: OSC-REACT-SYNC bars (peaks within 1 frame, mean|.| <= 8 ms, jitter <= 4 ms) ${out.meetsReactSync ? 'met' : 'not met'}`);
  if (missed || !withinFrame) fail('beat: a beat was missed or a pulse peak is more than one frame off');
  return out;
}
