// SPDX-License-Identifier: AGPL-3.0-only
// GPU check of the frame flash limiter passes (shaders/limiter/) against the vectors
// (conformance/limiter/frame/vectors.json) under WebGL2 in the pinned Playwright Chromium.
// Every case's signal is drawn in the page by limiter-signals.mjs's own source, run through the
// seven GLSL ES 3.00 passes (limiter.mjs) with the host clock the model uses, and each frame's
// hold mask, grant word, deficit and output digest must equal the vector's.
//
//   node tools/shader/limiter-check.mjs [--gpu] [--metal] [--time 1920x1080] [--frames 240]
//
// By default Chromium renders with SwiftShader (--enable-unsafe-swiftshader), so the check runs
// on any machine. --gpu asks for the hardware backend (ANGLE on Metal on macOS) instead. --metal
// also runs the generated Metal passes (limiter.mjs, pinned toolchain on PATH) natively through
// limiter-metal.swift against the same vectors. On macOS the Metal leg is required: a missing
// swiftc or Metal device fails the check. Elsewhere it is skipped before swiftc is invoked (no
// Metal framework). The last line names the legs that ran.
// The vectors must hold exactly the generator's cases (limiter-vectors.mjs CASES), with unique
// names and each case's frame count, and every leg must return every case with every frame.
// --time also times the seven passes on a 10 Hz half-cell checkerboard at that size: WebGL2 wall
// time per frame (readback-synchronised) and timer-query GPU time when
// EXT_disjoint_timer_query_webgl2 is offered; Metal command-buffer GPU time per frame and per
// pass. SwiftShader timings are CPU emulation and say nothing about GPU cost.
import { chromium } from 'playwright';
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClock } from './limiter-model.mjs';
import { LIMITER_PASSES, limiterFunction, limiterGLSL300, limiterMSL } from './limiter.mjs';
import { renderSignal } from './limiter-signals.mjs';
import { CASES, DT, fnv1a, runLengths, VECTORS_PATH } from './limiter-vectors.mjs';

const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : fallback;
};
const gpu = process.argv.includes('--gpu');
const metal = process.argv.includes('--metal');
const timeSize = arg('--time');
const timeFrames = Number(arg('--frames', 240));

const vectors = JSON.parse(readFileSync(VECTORS_PATH, 'utf8'));
// The vectors must be complete before anything is compared against them.
function vectorProblems() {
  const problems = [];
  const names = (vectors.cases || []).map(c => c.name);
  const want = CASES.map(c => c.name);
  if (!want.length) problems.push('the generator defines no cases');
  if (new Set(names).size !== names.length) problems.push(`duplicate case names: ${names.filter((n, i) => names.indexOf(n) !== i).join(', ')}`);
  if (names.join('\n') !== want.join('\n')) problems.push(`case set ${JSON.stringify(names)} != generator ${JSON.stringify(want)}`);
  for (const c of vectors.cases || []) {
    const spec = CASES.find(k => k.name === c.name);
    const n = Array.isArray(c.frameRecords) ? c.frameRecords.length : -1;
    if (!(n > 0) || n !== c.frames || (spec && spec.frames !== n)) problems.push(`${c.name}: ${n} frame records for ${c.frames} frames (generator ${spec?.frames})`);
  }
  return problems;
}
const problems = vectorProblems();
if (problems.length) {
  for (const p of problems) console.log(`FAIL vectors: ${p}`);
  process.exit(1);
}
const clockFrames = n => {
  const clock = createClock(3);
  return Array.from({ length: n }, () => clock(DT));
};

// Runs in the page. Builds the passes once and runs `cases` through them.
async function pageMain({ passes, cases, helpers, time }) {
  const helper = s => new Function(`return (${s})`)();
  const renderSignal = helper(helpers.renderSignal), runLengths = helper(helpers.runLengths), fnv1a = helper(helpers.fnv1a);
  const canvas = document.createElement('canvas');
  const gl = canvas.getContext('webgl2', { antialias: false });
  const info = gl.getExtension('WEBGL_debug_renderer_info');
  const renderer = info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
  const VS = '#version 300 es\nvoid main() { vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0); gl_Position = vec4(p, 0.0, 1.0); }';
  const shader = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const programs = passes.map(p => {
    const prog = gl.createProgram();
    gl.attachShader(prog, shader(gl.VERTEX_SHADER, VS));
    gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, p.glsl));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(`${p.name}: ${gl.getProgramInfoLog(prog)}`);
    gl.useProgram(prog);
    const block = gl.getUniformBlockIndex(prog, 'LimiterBlock');
    if (block !== gl.INVALID_INDEX) gl.uniformBlockBinding(prog, block, 0);
    p.textures.forEach(([name], i) => gl.uniform1i(gl.getUniformLocation(prog, name), i));
    return prog;
  });
  const ubo = gl.createBuffer();
  gl.bindBuffer(gl.UNIFORM_BUFFER, ubo);
  gl.bufferData(gl.UNIFORM_BUFFER, 32, gl.DYNAMIC_DRAW);
  gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, ubo);
  const tex = (w, h, uint) => {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texStorage2D(gl.TEXTURE_2D, 1, uint === 32 ? gl.RGBA32UI : uint ? gl.RGBA16UI : gl.RGBA8, w, h);
    for (const k of [gl.TEXTURE_MIN_FILTER, gl.TEXTURE_MAG_FILTER]) gl.texParameteri(gl.TEXTURE_2D, k, gl.NEAREST);
    return { t, w, h };
  };
  const fbo = targets => {
    const f = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, f);
    targets.forEach((x, i) => gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0 + i, gl.TEXTURE_2D, x.t, 0));
    gl.drawBuffers(targets.map((_, i) => gl.COLOR_ATTACHMENT0 + i));
    return { f, w: targets[0].w, h: targets[0].h, targets };
  };

  function makeLimiter(W, H) {
    const two = make => [make(), make()];
    const s = {
      frame: tex(W, H, false), rows: tex(64, H, 32), S: tex(64, 36, true), C: tex(16, 9, true), Wn: tex(16, 9, true),
      G: two(() => tex(1, 1, true)), T0: two(() => tex(64, 36, true)), T1: two(() => tex(64, 36, true)),
      T2: two(() => tex(64, 36, true)), out: two(() => tex(W, H, false)), cur: 0,
    };
    s.fRows = fbo([s.rows]);
    s.fS = fbo([s.S]);
    s.fC = fbo([s.C]);
    s.fW = fbo([s.Wn]);
    s.fG = s.G.map(g => fbo([g]));
    s.fState = [0, 1].map(i => fbo([s.T0[i], s.T1[i], s.T2[i]]));
    s.fOut = s.out.map(o => fbo([o]));
    // The host clears the state to zero: no sub-block tracked yet.
    for (const f of [...s.fG, ...s.fState]) {
      gl.bindFramebuffer(gl.FRAMEBUFFER, f.f);
      f.targets.forEach((_, i) => gl.clearBufferuiv(gl.COLOR, i, new Uint32Array(4)));
    }
    return s;
  }
  const draw = (prog, target, inputs) => {
    gl.useProgram(prog);
    gl.bindFramebuffer(gl.FRAMEBUFFER, target.f);
    gl.viewport(0, 0, target.w, target.h);
    inputs.forEach((x, i) => { gl.activeTexture(gl.TEXTURE0 + i); gl.bindTexture(gl.TEXTURE_2D, x.t); });
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  };
  // The seven passes of one frame, in order; flips the ping-pong state.
  function drawFrame(s) {
    const a = s.cur, b = a ^ 1;
    const [rows, reduce, cells, windows, grant, state, output] = programs;
    draw(rows, s.fRows, [s.frame]);
    draw(reduce, s.fS, [s.rows, s.T0[a], s.T1[a]]);
    draw(cells, s.fC, [s.S, s.T2[a]]);
    draw(windows, s.fW, [s.C]);
    draw(grant, s.fG[b], [s.C, s.Wn, s.G[a]]);
    draw(state, s.fState[b], [s.S, s.G[b], s.T0[a], s.T1[a], s.T2[a]]);
    draw(output, s.fOut[b], [s.frame, s.out[a], s.T1[b]]);
    s.cur = b;
  }
  function step(s, px, block) {
    gl.bindTexture(gl.TEXTURE_2D, s.frame.t);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, s.frame.w, s.frame.h, gl.RGBA, gl.UNSIGNED_BYTE, px);
    gl.bindBuffer(gl.UNIFORM_BUFFER, ubo);
    gl.bufferSubData(gl.UNIFORM_BUFFER, 0, block);
    drawFrame(s);
  }
  const blockOf = (c, clock) => new Float32Array([c.window.cols, c.window.rows, c.window.limit, clock.refill, clock.tick, clock.deltaMs, 0, 0]);

  const results = [];
  for (const c of cases) {
    const s = makeLimiter(c.width, c.height);
    const px = new Uint8Array(c.width * c.height * 4);
    const out = new Uint8Array(c.width * c.height * 4);
    const t1 = new Uint32Array(64 * 36 * 4), g = new Uint32Array(4), mask = new Uint8Array(64 * 36);
    const frames = [];
    let last = '';
    for (let t = 0; t < c.frames; t++) {
      renderSignal(c.signal, t, c.width, c.height, px);
      step(s, px, blockOf(c, c.clock[t]));
      gl.bindFramebuffer(gl.FRAMEBUFFER, s.fState[s.cur].f);
      gl.readBuffer(gl.COLOR_ATTACHMENT1);
      gl.readPixels(0, 0, 64, 36, gl.RGBA_INTEGER, gl.UNSIGNED_INT, t1);
      gl.bindFramebuffer(gl.FRAMEBUFFER, s.fG[s.cur].f);
      gl.readBuffer(gl.COLOR_ATTACHMENT0);
      gl.readPixels(0, 0, 1, 1, gl.RGBA_INTEGER, gl.UNSIGNED_INT, g);
      gl.bindFramebuffer(gl.FRAMEBUFFER, s.fOut[s.cur].f);
      gl.readPixels(0, 0, c.width, c.height, gl.RGBA, gl.UNSIGNED_BYTE, out);
      for (let k = 0; k < mask.length; k++) mask[k] = t1[4 * k + 3];
      const hold = runLengths(mask);
      frames.push([hold === last ? '=' : hold, g[0], g[1], fnv1a(out)]);
      last = hold;
    }
    results.push({ name: c.name, frames });
  }

  let timing = null;
  if (time) {
    const s = makeLimiter(time.width, time.height);
    const px = new Uint8Array(time.width * time.height * 4);
    const pixels = [px, new Uint8Array(px.length)];
    renderSignal(time.signal, 0, time.width, time.height, pixels[0]);
    renderSignal(time.signal, 3, time.width, time.height, pixels[1]);
    const tq = gl.getExtension('EXT_disjoint_timer_query_webgl2');
    const wall = [], gpuMs = [];
    const one = new Uint8Array(4);
    for (let t = 0; t < time.frames; t++) {
      const block = blockOf(time, time.clock[t]);
      // Upload outside the timed region: the host's frame is already on the GPU.
      gl.bindTexture(gl.TEXTURE_2D, s.frame.t);
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, time.width, time.height, gl.RGBA, gl.UNSIGNED_BYTE, pixels[t % 2]);
      gl.bindFramebuffer(gl.FRAMEBUFFER, s.fOut[s.cur].f);
      gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, one);
      const q = tq ? gl.createQuery() : null;
      const t0 = performance.now();
      if (q) gl.beginQuery(tq.TIME_ELAPSED_EXT, q);
      gl.bindBuffer(gl.UNIFORM_BUFFER, ubo);
      gl.bufferSubData(gl.UNIFORM_BUFFER, 0, block);
      drawFrame(s);
      if (q) gl.endQuery(tq.TIME_ELAPSED_EXT);
      gl.bindFramebuffer(gl.FRAMEBUFFER, s.fOut[s.cur].f);
      gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, one);
      wall.push(performance.now() - t0);
      if (q) {
        for (let spin = 0; spin < 1000 && !gl.getQueryParameter(q, gl.QUERY_RESULT_AVAILABLE); spin++) await new Promise(r => setTimeout(r, 1));
        if (!gl.getParameter(tq.GPU_DISJOINT_EXT) && gl.getQueryParameter(q, gl.QUERY_RESULT_AVAILABLE)) gpuMs.push(gl.getQueryParameter(q, gl.QUERY_RESULT) / 1e6);
        gl.deleteQuery(q);
      }
    }
    const median = xs => { const v = [...xs].sort((x, y) => x - y); return v.length ? v[Math.floor(v.length / 2)] : null; };
    // Drop the first 30 frames (pipeline warm-up).
    timing = { wallMedianMs: median(wall.slice(30)), gpuMedianMs: median(gpuMs.slice(30)), gpuSamples: gpuMs.length, timerQuery: !!tq };
  }
  return { renderer, results, timing };
}

const passes = LIMITER_PASSES.map(p => ({ name: p.name, textures: p.textures, glsl: limiterGLSL300(p) }));
const cases = vectors.cases.map(c => ({ ...c, frameRecords: undefined, clock: clockFrames(c.frames) }));
let time = null;
if (timeSize) {
  const [width, height] = timeSize.split('x').map(Number);
  time = { width, height, frames: timeFrames, window: vectors.cases[0].window, clock: clockFrames(timeFrames),
    signal: { kind: 'checker', hz: 10, size: [1 / 32, 1 / 18], on: [255, 255, 255], off: [0, 0, 0] } };
}
let failed = 0;
const ran = [], skipped = [];
// Every expected case exactly once, each with every frame, before any value is compared.
function compare(leg, results) {
  const names = results.map(r => r.name);
  for (const c of vectors.cases) {
    const n = names.filter(x => x === c.name).length;
    if (n !== 1) { failed++; console.log(`FAIL ${leg} ${c.name}: returned ${n} times`); }
  }
  for (const x of new Set(names)) {
    if (!vectors.cases.some(c => c.name === x)) { failed++; console.log(`FAIL ${leg} ${x}: not a vector case`); }
  }
  for (const r of results) {
    const want = vectors.cases.find(c => c.name === r.name)?.frameRecords;
    if (!want) continue;
    if (!Array.isArray(r.frames) || r.frames.length !== want.length) {
      failed++;
      console.log(`FAIL ${leg} ${r.name}: ${r.frames?.length ?? 0} frames returned, ${want.length} expected`);
      continue;
    }
    const bad = r.frames.findIndex((f, t) => JSON.stringify(f) !== JSON.stringify(want[t]));
    if (bad < 0) {
      console.log(`ok   ${leg} ${r.name}: ${r.frames.length} frames match`);
    } else {
      failed++;
      const show = f => JSON.stringify(f).slice(0, 120);
      console.log(`FAIL ${leg} ${r.name}: frame ${bad} ${show(r.frames[bad])} != vector ${show(want[bad])}`);
    }
  }
}

const args = gpu ? ['--use-angle=metal', '--enable-gpu', '--ignore-gpu-blocklist'] : ['--enable-unsafe-swiftshader'];
const browser = await chromium.launch({ args });
try {
  const page = await browser.newPage();
  const helpers = { renderSignal: renderSignal.toString(), runLengths: runLengths.toString(), fnv1a: fnv1a.toString() };
  const { renderer, results, timing } = await page.evaluate(
    ([src, input]) => new Function(`return (${src})`)()(input),
    [pageMain.toString(), { passes, cases, helpers, time }],
  );
  console.log(`webgl2 renderer: ${renderer}`);
  compare('webgl2', results);
  ran.push(`webgl2 (${renderer})`);
  if (timing) console.log(`webgl2 timing ${timeSize}: ${JSON.stringify(timing)}${/swiftshader/i.test(renderer) ? ' (SwiftShader: CPU emulation, not representative of GPU cost)' : ''}`);
} finally {
  await browser.close();
}

// The Metal leg: frames go to limiter-metal.swift on stdin, records come back one line per case.
// On macOS the leg is required, so a missing prerequisite fails; elsewhere it is skipped before
// swiftc runs, since Swift off Apple platforms has no Metal framework.
function metalUnavailable(why) {
  failed++;
  console.log(`FAIL metal: ${why} (the Metal leg is required on macOS)`);
}
async function runMetal() {
  if (process.platform !== 'darwin') {
    skipped.push(`metal (${process.platform}: no Metal)`);
    return console.log(`skip metal: ${process.platform} has no Metal`);
  }
  const out = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'out', 'limiter-metal');
  mkdirSync(out, { recursive: true });
  try {
    execFileSync('swiftc', ['-O', join(dirname(fileURLToPath(import.meta.url)), 'limiter-metal.swift'), '-o', join(out, 'check')], { stdio: 'pipe' });
  } catch (e) {
    if (e.code === 'ENOENT') return metalUnavailable('no swiftc on PATH');
    throw new Error(`swiftc: ${String(e.stderr).slice(0, 2000)}`);
  }
  const metalPasses = LIMITER_PASSES.map(p => {
    const path = join(out, `${p.name}.metal`);
    writeFileSync(path, limiterMSL(p));
    return { function: limiterFunction(p), metal: path, formats: p.outputs.map(([, t]) => t) };
  });
  const asCase = c => ({ name: c.name, width: c.width, height: c.height, frames: c.frames, cols: c.window.cols, rows: c.window.rows,
    limit: c.window.limit, clock: c.clock.map(k => [k.tick, k.deltaMs, k.refill]) });
  const config = { passes: metalPasses, cases: cases.map(asCase), timing: time ? asCase({ ...time, name: 'timing' }) : null };
  writeFileSync(join(out, 'config.json'), JSON.stringify(config));
  const child = spawn(join(out, 'check'), [join(out, 'config.json')], { stdio: ['pipe', 'pipe', 'inherit'] });
  let stdout = '';
  child.stdout.on('data', d => { stdout += d; });
  const done = new Promise(resolve => child.on('close', resolve));
  const write = buf => new Promise(resolve => (child.stdin.write(buf) ? resolve() : child.stdin.once('drain', resolve)));
  child.stdin.on('error', () => {});
  for (const c of cases) {
    const px = new Uint8Array(c.width * c.height * 4);
    for (let t = 0; t < c.frames; t++) {
      renderSignal(c.signal, t, c.width, c.height, px);
      await write(Buffer.from(px));
    }
  }
  if (time) {
    for (const t of [0, 3]) {
      const px = new Uint8Array(time.width * time.height * 4);
      renderSignal(time.signal, t, time.width, time.height, px);
      await write(Buffer.from(px));
    }
  }
  child.stdin.end();
  const code = await done;
  const lines = stdout.trim().split('\n').filter(Boolean).map(l => JSON.parse(l));
  if (lines[0]?.skipped) return metalUnavailable(lines[0].skipped);
  if (code !== 0) throw new Error(`limiter-metal exited ${code}`);
  ran.push('metal');
  compare('metal', lines.filter(l => l.name).map(l => {
    let last = '';
    return { name: l.name, frames: l.frames.map(([mask, grant, deficit, digest]) => {
      const hold = runLengths(Array.from(mask, ch => (ch === '1' ? 1 : 0)));
      const rec = [hold === last ? '=' : hold, grant, deficit, digest];
      last = hold;
      return rec;
    }) };
  }));
  const timing = lines.find(l => l.timing)?.timing;
  if (timing) {
    timing.passMedianMs = Object.fromEntries(LIMITER_PASSES.map((p, k) => [p.name, timing.passMedianMs[k]]));
    console.log(`metal timing ${timeSize}: ${JSON.stringify(timing)}`);
  }
}
if (metal) await runMetal();

if (!metal) skipped.push('metal (not requested)');
console.log(`limiter gpu check: ran ${ran.join(', ') || 'nothing'}; skipped ${skipped.join(', ') || 'nothing'}: ` +
  `${failed ? `${failed} failures` : `all ${vectors.cases.length} cases match the vectors on every leg that ran`}`);
process.exit(failed ? 1 : 0);
