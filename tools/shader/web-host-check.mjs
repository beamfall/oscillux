// SPDX-License-Identifier: AGPL-3.0-only
// Checks the web host's resilience (OSC-WEB-HOST-RESILIENCE).
//
//   node tools/shader/web-host-check.mjs [--json FILE]
//
// Serves hosts/web (out/hosts/visuals.json from make host-bundle, out/hosts/wasm
// from make host-wasm) with requestAnimationFrame driven at 60 Hz in presentation
// time, as cdg-host-check.mjs does, and checks:
//   - a context lost and restored with WEBGL_lose_context, once on a steady
//     visual and once part-way through a switch, draws again within 1 s of the
//     restore with the same visual, frame count and switch progress, carries on
//     (the switch finishes), raises no GL error (an object left from the lost
//     context would), shows a picture rather than black and logs no error;
//   - lost during a switch that interrupted another (the outgoing layer baked
//     and holding), the restore ends that switch on the incoming visual;
//   - with background compiles (KHR_parallel_shader_compile, emulated where the
//     browser lacks it), the first switch after a restore still has its
//     transition;
//   - a context lost before the host has started is restored and the host
//     starts on it;
//   - with EXT_color_buffer_float masked, and again with
//     EXT_color_buffer_half_float masked too, the host still draws a picture and
//     names the feedback mode it fell back to in the status line;
//   - the drawing buffer is preserved only for capture and trace runs (frames=,
//     size=, trace).
// Exits 1 when a check fails.
import { chromium } from 'playwright';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const { values: opts } = parseArgs({ options: { json: { type: 'string', default: '' } } });
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json' };
const HZ = 60;
const RESTORE_MS = 1000;
const BASE = { visual: 'aurora', size: '160x90', quality: '3', trace: '', quantise: 'none' };

const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader', '--mute-audio', '--autoplay-policy=no-user-gesture-required'] });
let failed = false;
const report = {};
try {
  report.steady = await lossCheck('steady', false);
  report.switching = await lossCheck('switching', true);
  report.held = await lossCheck('held', true, { held: true });
  report.after = await lossCheck('switch after restore', false, { after: true });
  report.startup = await startupCheck();
  report.halfFloat = await formatCheck('half-float', ['EXT_color_buffer_float']);
  report.eightBit = await formatCheck('8-bit', ['EXT_color_buffer_float', 'EXT_color_buffer_half_float']);
  report.preserve = await preserveCheck();
  if (opts.json) writeFileSync(opts.json, JSON.stringify(report, null, 1) + '\n');
} finally {
  await browser.close();
}
process.exit(failed ? 1 : 0);

function fail(message) {
  console.error(`FAIL ${message}`);
  failed = true;
}

// The host page with `masked` extensions hidden from getExtension, run until
// the visual draws (unless `wait` is false). `parallel` reports a program
// compiling until 30 ms after it was made, as KHR_parallel_shader_compile can;
// `hold` is a promise visuals.json waits for, and `asked` is called when the
// host asks for it.
async function hostPage(params, { masked = [], wait = true, parallel = false, hold = null, asked = null } = {}) {
  const page = await browser.newPage({ viewport: { width: 320, height: 180 } });
  page.errors = [];
  page.on('console', m => { if (m.type() === 'error') page.errors.push(m.text().slice(0, 400)); });
  page.on('pageerror', e => page.errors.push(String(e).slice(0, 400)));
  await page.route('http://oscillux.test/**', async route => {
    const path = join(ROOT, decodeURIComponent(new URL(route.request().url()).pathname));
    if (!path.startsWith(ROOT + '/')) return route.fulfill({ status: 403 });
    if (hold && path.endsWith('/out/hosts/visuals.json')) {
      asked?.();
      await hold;
    }
    try {
      return route.fulfill({ status: 200, contentType: TYPES[extname(path)] ?? 'application/octet-stream', body: readFileSync(path) });
    } catch {
      return route.fulfill({ status: 404 });
    }
  });
  await page.addInitScript(([masked, parallel]) => {
    const queue = [];
    let now = 1000;
    window.requestAnimationFrame = cb => queue.push(cb);
    window.__tick = (n, hz) => {
      for (let i = 0; i < n; i++) {
        now += 1000 / hz;
        for (const cb of queue.splice(0)) cb(now);
      }
    };
    const get = WebGL2RenderingContext.prototype.getExtension;
    WebGL2RenderingContext.prototype.getExtension = function (name) {
      return masked.includes(name) ? null : get.call(this, name);
    };
    const supported = WebGL2RenderingContext.prototype.getSupportedExtensions;
    WebGL2RenderingContext.prototype.getSupportedExtensions = function () {
      return supported.call(this)?.filter(n => !masked.includes(n)) ?? null;
    };
    if (!parallel) return;
    const P = WebGL2RenderingContext.prototype, born = new WeakMap(), COMPLETION_STATUS_KHR = 0x91B1;
    const ext = { COMPLETION_STATUS_KHR, maxShaderCompilerThreadsKHR() {} };
    const create = P.createProgram;
    P.createProgram = function () { const p = create.call(this); born.set(p, performance.now()); return p; };
    const param = P.getProgramParameter;
    P.getProgramParameter = function (p, n) {
      return n === COMPLETION_STATUS_KHR ? performance.now() - (born.get(p) ?? 0) > 30 : param.call(this, p, n);
    };
    const ext0 = P.getExtension;
    P.getExtension = function (name) { return name === 'KHR_parallel_shader_compile' ? ext : ext0.call(this, name); };
  }, [masked, parallel]);
  const query = new URLSearchParams(params).toString().replace(/=(&|$)/g, '$1');
  await page.goto(`http://oscillux.test/hosts/web/index.html?${query}`, { waitUntil: hold ? 'commit' : 'load' });
  if (wait) await waitDrawn(page, params);
  return page;
}

async function waitDrawn(page, params) {
  await page.waitForFunction(() => typeof window.__tick === 'function' && document.getElementById('c'), null, { timeout: 120000, polling: 100 });
  for (let i = 0; i < 400 && !await drawn(page); i++) {
    await page.evaluate(hz => window.__tick(5, hz), HZ);
    await page.waitForTimeout(20);
  }
  if (!await drawn(page)) fail(`${JSON.stringify(params)}: the visual never drew (${await status(page)})`);
}

function drawn(page) {
  return page.evaluate(() => /frame \d+/.test(document.getElementById('status').textContent));
}

function status(page) {
  return page.evaluate(() => document.getElementById('status').textContent);
}

// The GL errors raised over `n` frames: an object left from the lost context
// (a program, texture or buffer) raises INVALID_OPERATION when used.
function glErrors(page, n = 10) {
  return page.evaluate(([n, hz]) => {
    const gl = document.getElementById('c').getContext('webgl2'), seen = [];
    while (gl.getError() !== gl.NO_ERROR);
    for (let i = 0; i < n; i++) {
      window.__tick(1, hz);
      for (let e; (e = gl.getError()) !== gl.NO_ERROR;) seen.push(e);
    }
    return seen;
  }, [n, HZ]);
}

// The share of the canvas that is not black, read in the task that draws the
// frame (the trace run preserves the drawing buffer).
function lit(page) {
  return page.evaluate(hz => {
    window.__tick(1, hz);
    const c = document.getElementById('c'), x = document.createElement('canvas');
    x.width = c.width; x.height = c.height;
    const g = x.getContext('2d');
    g.drawImage(c, 0, 0);
    const px = g.getImageData(0, 0, x.width, x.height).data;
    let n = 0;
    for (let i = 0; i < px.length; i += 4) if (px[i] + px[i + 1] + px[i + 2] > 24) n++;
    return n / (px.length / 4);
  }, HZ);
}

// Ticks until the blend of the switch under way is between 0.2 and 0.6.
async function blendUnderWay(page) {
  for (let i = 0; i < 600; i++) {
    await page.evaluate(hz => window.__tick(2, hz), HZ);
    const p = await page.evaluate(() => window.__oscilluxTrace.frames.at(-1)?.[3] ?? 0);
    if (p > 0.2 && p < 0.6) return;
  }
}

async function lossCheck(name, switching, { held = false, after = false } = {}) {
  const page = await hostPage(BASE, { parallel: after });
  const out = { name };
  try {
    await page.evaluate(hz => window.__tick(30, hz), HZ);
    if (switching) {
      // a switch to the next visual, lost once the blend is under way
      await page.evaluate(() => document.getElementById('next').click());
      await blendUnderWay(page);
    }
    if (held) {
      // a second switch bakes the blend into the outgoing layer, which holds
      await page.evaluate(() => document.getElementById('next').click());
      for (let i = 0; i < 60 && await page.evaluate(() => window.__oscilluxTrace.switches.length < 2); i++)
        await page.evaluate(hz => window.__tick(1, hz), HZ);
      await page.evaluate(hz => window.__tick(5, hz), HZ);
    }
    // the loss and the restore each arrive as an event after the call returns
    await page.evaluate(() => {
      window.__loseExt = document.getElementById('c').getContext('webgl2').getExtension('WEBGL_lose_context');
      window.__loseExt.loseContext();
    });
    await page.waitForFunction(() => window.__oscilluxTrace.restores.length === 1, null, { timeout: 5000 });
    // frames while lost draw nothing
    await page.evaluate(hz => window.__tick(10, hz), HZ);
    await page.evaluate(() => window.__loseExt.restoreContext());
    await page.waitForFunction(() => window.__oscilluxTrace.restores[0].restoredAt !== null, null, { timeout: 5000 });
    await page.evaluate(hz => window.__tick(1, hz), HZ);
    const r = out.restore = await page.evaluate(() => window.__oscilluxTrace.restores[0]);
    const ms = r.drawnAt === null ? Infinity : r.drawnAt - r.restoredAt;
    out.restoreMs = ms;
    if (!(ms <= RESTORE_MS)) fail(`${name}: drew ${ms.toFixed(0)} ms after the restore (limit ${RESTORE_MS})`);
    if (r.drawnVisual !== r.visual) fail(`${name}: ${r.visual} lost, ${r.drawnVisual} drawn after the restore`);
    if (!(r.drawnFrame >= r.frame && r.drawnFrame <= r.frame + 2)) fail(`${name}: frame ${r.frame} lost, frame ${r.drawnFrame} drawn after the restore`);
    // the frames straight after the restore, while a switch still blends
    out.glErrors = await glErrors(page);
    if (out.glErrors.length) fail(`${name}: GL errors after the restore: ${out.glErrors.join(', ')}`);
    if (held) {
      if (!r.held) fail(`${name}: the outgoing layer was not holding when the context was lost`);
      if (r.drawnOut) fail(`${name}: the held outgoing layer was still blending after the restore`);
    } else if (switching) {
      if (r.drawnState !== r.state) fail(`${name}: switch state ${r.state} lost, ${r.drawnState} after the restore`);
      if (!(r.drawnP >= r.blendP && r.drawnP < r.blendP + 0.1)) fail(`${name}: blend ${r.blendP} lost, ${r.drawnP} after the restore`);
      for (let i = 0; i < 300 && await page.evaluate(() => window.__oscilluxTrace.switches[0]?.doneSeconds === null); i++)
        await page.evaluate(hz => window.__tick(2, hz), HZ);
      const done = out.doneSeconds = await page.evaluate(() => window.__oscilluxTrace.switches[0]?.doneSeconds ?? null);
      if (done === null) fail(`${name}: the switch did not finish after the restore`);
    }
    if (after) {
      // the background compiles started by the restore finish in real time
      for (let i = 0; i < 10; i++) {
        await page.evaluate(hz => window.__tick(1, hz), HZ);
        await page.waitForTimeout(20);
      }
      await page.evaluate(() => document.getElementById('next').click());
      for (let i = 0; i < 100 && await page.evaluate(() => window.__oscilluxTrace.switches.length === 0); i++) {
        await page.evaluate(hz => window.__tick(1, hz), HZ);
        await page.waitForTimeout(20);
      }
      const s = await page.evaluate(() => window.__oscilluxTrace.switches[0] ?? null);
      out.transition = s?.transition ?? null;
      if (!s) fail(`${name}: no switch after the restore`);
      else if (s.transition === null) fail(`${name}: the first switch after the restore had no transition`);
    }
    await page.evaluate(hz => window.__tick(30, hz), HZ);
    out.lit = await lit(page);
    if (out.lit < 0.05) fail(`${name}: ${(out.lit * 100).toFixed(1)}% of the canvas lit after the restore`);
    out.status = await status(page);
    out.errors = page.errors.concat(await page.evaluate(() => document.getElementById('err').textContent).then(t => t ? [t] : []));
    if (out.errors.length) fail(`${name}: ${out.errors.join(' | ')}`);
    console.log(`${name}: lost at frame ${r.frame}${switching ? ` (blend ${r.blendP.toFixed(2)})` : ''}, drew ${ms.toFixed(0)} ms after the restore${after ? `, then switched with ${out.transition}` : ''}, ${(out.lit * 100).toFixed(0)}% lit`);
  } finally {
    await page.close();
  }
  return out;
}

// The context is lost and restored while the host waits for visuals.json,
// before its own handlers exist.
async function startupCheck() {
  let release, asked;
  const hold = new Promise(r => { release = r; }), waiting = new Promise(r => { asked = r; });
  const page = await hostPage(BASE, { wait: false, hold, asked });
  const out = { name: 'startup' };
  try {
    await waiting;
    await page.evaluate(() => {
      window.__loseExt = document.getElementById('c').getContext('webgl2').getExtension('WEBGL_lose_context');
      window.__loseExt.loseContext();
    });
    await page.waitForTimeout(50);
    await page.evaluate(() => window.__loseExt.restoreContext());
    out.restored = await page.waitForFunction(() => !document.getElementById('c').getContext('webgl2').isContextLost(), null, { timeout: 5000 })
      .then(() => true, () => false);
    if (!out.restored) fail('startup: the context lost before the host started was not restored');
    release();
    if (out.restored) {
      await waitDrawn(page, BASE);
      out.glErrors = await glErrors(page);
      if (out.glErrors.length) fail(`startup: GL errors: ${out.glErrors.join(', ')}`);
      await page.evaluate(hz => window.__tick(30, hz), HZ);
      out.lit = await lit(page);
      if (out.lit < 0.05) fail(`startup: ${(out.lit * 100).toFixed(1)}% of the canvas lit`);
    }
    out.errors = page.errors.concat(await page.evaluate(() => document.getElementById('err').textContent).then(t => t ? [t] : []));
    if (out.errors.length) fail(`startup: ${out.errors.join(' | ')}`);
    console.log(`startup: lost and restored before the host started, ${out.restored ? `${(out.lit * 100).toFixed(0)}% lit` : 'not restored'}`);
  } finally {
    release();
    await page.close();
  }
  return out;
}

async function formatCheck(name, masked) {
  const page = await hostPage(BASE, { masked });
  const out = { name, masked };
  try {
    await page.evaluate(hz => window.__tick(60, hz), HZ);
    out.status = await status(page);
    out.glErrors = await glErrors(page);
    if (out.glErrors.length) fail(`${name}: GL errors: ${out.glErrors.join(', ')}`);
    out.lit = await lit(page);
    const want = `${name} feedback`;
    if (!out.status.includes(want)) fail(`${name}: status line does not name ${want}: ${out.status}`);
    if (out.lit < 0.05) fail(`${name}: ${(out.lit * 100).toFixed(1)}% of the canvas lit`);
    if (page.errors.length) fail(`${name}: ${page.errors.join(' | ')}`);
    console.log(`${name}: ${out.status.split(' · ').at(-1)}, ${(out.lit * 100).toFixed(0)}% lit`);
  } finally {
    await page.close();
  }
  return out;
}

async function preserveCheck() {
  const cases = [
    [{ visual: 'aurora' }, false],
    [{ visual: 'aurora', frames: '30' }, true],
    [{ visual: 'aurora', size: '160x90' }, true],
    [{ visual: 'aurora', trace: '' }, true],
  ];
  const out = [];
  for (const [params, want] of cases) {
    const page = await hostPage(params, { wait: false });
    try {
      await page.waitForFunction(() => document.getElementById('c').getContext('webgl2'), null, { timeout: 120000 });
      const got = await page.evaluate(() => document.getElementById('c').getContext('webgl2').getContextAttributes().preserveDrawingBuffer);
      const label = new URLSearchParams(params).toString();
      if (got !== want) fail(`preserveDrawingBuffer ${got} for ${label}, want ${want}`);
      out.push({ params, preserveDrawingBuffer: got });
    } finally {
      await page.close();
    }
  }
  console.log(`preserveDrawingBuffer: ${out.map(o => `${new URLSearchParams(o.params)} ${o.preserveDrawingBuffer}`).join(', ')}`);
  return out;
}
