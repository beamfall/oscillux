// SPDX-License-Identifier: AGPL-3.0-only
// Checks the web host's CD+G lyrics (OSC-CDG, conformance/cdg/README.md).
//
//   node tools/shader/cdg-host-check.mjs [--screenshot DIR] [--json FILE]
//
// Serves hosts/web (out/hosts/visuals.json from make host-bundle, out/hosts/wasm
// from make host-wasm) with requestAnimationFrame driven at 60 Hz in presentation
// time on the synthetic source, as transition-check.mjs --host does, loads a
// conformance stream with ?cdg= and checks, per stepped frame of the page's trace,
// that the decoder holds exactly the packs of the frame's media time (pack
// floor(ms * 0.3) and those before it, clamped to the stream). The run outlasts
// the synthetic loop, so the wrap back to 0 seeks the decoder backwards. At
// sampled frames it reads the layer texture back and compares it with the
// decoder's window under the page's key (an upload skipped or stale fails), and
// it checks that the lyrics reach the canvas (a run without a stream differs).
// A drop of the stream with a song (conformance/dsp/kicks-120bpm.wav) loads both and
// holds the pack clock on the position heard: the page's output latency is fixed at
// 160 ms, as on Bluetooth output, and each frame's lyric time must trail the song's write
// position by exactly that. An MP3+G .zip of karaoke-blue and that song (built here, with
// AppleDouble entries beside them), dropped and given by ?karaoke=, opens both, keyed auto.
// With --screenshot it writes the canvas over the lyric screen
// to DIR. Exits 1 when a check fails.
import { chromium } from 'playwright';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { zip } from './zip-fixture.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const { values: opts } = parseArgs({
  options: {
    screenshot: { type: 'string', default: '' },
    json: { type: 'string', default: '' },
  },
});
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json' };
const HZ = 60;
// the page's base plus output latency, as the init script fixes them
const LATENCY_MS = 160;
// past the synthetic loop's 15.36 s
const RUN_SECONDS = 17;
const RUNS = [
  { stream: 'mixed', key: 'preset' },
  { stream: 'lyrics', key: 'preset' },
  { stream: 'lyrics', key: 'table' },
  { stream: 'lyrics', key: 'index:0' },
  { stream: 'lyrics', key: 'none' },
  // realistic screens under the default key: auto must find the blue background (the preset
  // colour on karaoke-blue, the two tiled blues on karaoke-tiles, which presets the outline black)
  { stream: 'karaoke-blue', key: 'auto', mask: 0x0002 },
  { stream: 'karaoke-tiles', key: 'auto', mask: 0x0006 },
];

const KARAOKE_ZIP = zip([
  { name: 'Artist - Song/Artist - Song.cdg', data: readFileSync(join(ROOT, 'conformance/cdg/karaoke-blue.cdg')) },
  { name: 'Artist - Song/Artist - Song.wav', data: readFileSync(join(ROOT, 'conformance/dsp/kicks-120bpm.wav')) },
  { name: '__MACOSX/Artist - Song/._Artist - Song.wav', data: new Uint8Array(82) },
]);

const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'] });
let failed = false;
const report = { runs: [] };
try {
  for (const run of RUNS) report.runs.push(await check(run));
  report.drop = await dropCheck();
  report.karaoke = [await karaokeCheck('drop'), await karaokeCheck('url')];
  report.canvas = await canvasCheck();
  if (opts.screenshot) await screenshot(opts.screenshot);
  if (opts.json) writeFileSync(opts.json, JSON.stringify(report, null, 1) + '\n');
} finally {
  await browser.close();
}
process.exit(failed ? 1 : 0);

function fail(message) {
  console.error(`FAIL ${message}`);
  failed = true;
}

async function hostPage(params, viewport = { width: 320, height: 180 }) {
  const page = await browser.newPage({ viewport });
  page.errors = [];
  page.on('console', m => { if (m.type() === 'error') page.errors.push(m.text().slice(0, 400)); });
  page.on('pageerror', e => page.errors.push(String(e).slice(0, 400)));
  await page.route('http://oscillux.test/**', route => {
    if (new URL(route.request().url()).pathname === '/karaoke.zip') return route.fulfill({ status: 200, contentType: 'application/zip', body: Buffer.from(KARAOKE_ZIP) });
    const path = join(ROOT, decodeURIComponent(new URL(route.request().url()).pathname));
    if (!path.startsWith(ROOT + '/')) return route.fulfill({ status: 403 });
    try {
      return route.fulfill({ status: 200, contentType: TYPES[extname(path)] ?? 'application/octet-stream', body: readFileSync(path) });
    } catch {
      return route.fulfill({ status: 404 });
    }
  });
  // requestAnimationFrame at a fixed rate in presentation time
  await page.addInitScript(() => {
    const queue = [];
    let now = 1000;
    window.requestAnimationFrame = cb => queue.push(cb);
    window.__tick = (n, hz) => {
      for (let i = 0; i < n; i++) {
        now += 1000 / hz;
        for (const cb of queue.splice(0)) cb(now);
      }
    };
    // a song plays on the audio clock, which follows the wall clock: catch the frame clock up
    window.__catchUp = hz => { while (now + 1000 / hz <= performance.now()) window.__tick(1, hz); };
    // a fixed output latency (LATENCY_MS), so the heard position differs from the write one
    Object.defineProperty(AudioContext.prototype, 'baseLatency', { get: () => 0.01 });
    Object.defineProperty(AudioContext.prototype, 'outputLatency', { get: () => 0.15 });
  });
  await page.goto(`http://oscillux.test/hosts/web/index.html?${new URLSearchParams(params)}`);
  await page.waitForFunction(() => window.__oscilluxTrace && typeof window.__tick === 'function', null, { timeout: 120000, polling: 100 });
  // run until the visual draws (and, with a stream, until it is loaded)
  for (let i = 0; i < 400; i++) {
    await page.evaluate(hz => window.__tick(5, hz), HZ);
    const ready = await page.evaluate(wait => /frame \d+/.test(document.getElementById('status').textContent)
      && (!wait || window.__oscilluxCdg.loaded), 'cdg' in params);
    if (ready) break;
    await page.waitForTimeout(20);
  }
  return page;
}

// The layer texture against the decoder's window at its current position, in the page.
function textureMatches(page) {
  return page.evaluate(() => {
    const layer = window.__oscilluxCdg, c = layer.cdg, gl = layer.gl;
    // the key for the window as it stands (auto resolved afresh), so a stale auto mask fails
    const key = layer.resolveKey();
    if (c.windowRgba(key[0], key[1]) < 0) return { error: 'windowRgba refused' };
    const want = new Uint8Array(layer.m.wasmMemory().buffer, c.rgbaPtr(), 288 * 192 * 4).slice();
    const fb = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, layer.texture, 0);
    const got = new Uint8Array(288 * 192 * 4);
    gl.readPixels(0, 0, 288, 192, gl.RGBA, gl.UNSIGNED_BYTE, got);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.deleteFramebuffer(fb);
    let differ = 0, opaque = 0;
    for (let i = 0; i < want.length; i += 4) {
      if (want[i + 3]) opaque++;
      if (want[i] !== got[i] || want[i + 1] !== got[i + 1] || want[i + 2] !== got[i + 2] || want[i + 3] !== got[i + 3]) differ++;
    }
    return { applied: c.applied, differ, opaque, mode: key[0], mask: key[1] };
  });
}

function packsAt(ms, packCount) {
  return Math.min(packCount, Math.max(0, Math.floor(ms / 1000 * 300) + 1));
}

async function check({ stream, key, mask }) {
  const name = `${stream} ${key}`;
  const page = await hostPage({ visual: 'aurora', size: '160x90', quality: '3', trace: '', cdg: `../../conformance/cdg/${stream}.cdg`, cdgkey: key });
  const out = { stream, key, rows: 0, mismatched: 0, wrapped: false, textures: [] };
  try {
    const start = await page.evaluate(() => window.__oscilluxTrace.cdg.length);
    // in steps of a quarter second, comparing the texture after each
    for (let s = 0; s < RUN_SECONDS * 4; s++) {
      await page.evaluate(([n, hz]) => window.__tick(n, hz), [HZ / 4, HZ]);
      const t = await textureMatches(page);
      if (t.error || t.differ) fail(`${name}: layer texture differs from the decoder at ${t.applied} packs (${t.error ?? `${t.differ} texels`})`);
      out.textures.push(t);
    }
    const rows = (await page.evaluate(() => window.__oscilluxTrace.cdg)).slice(start);
    out.rows = rows.length;
    let lastMs = -1;
    for (const [step, ms, applied, count] of rows) {
      if (ms < lastMs) out.wrapped = true;
      lastMs = ms;
      if (ms === null || applied !== packsAt(ms, count)) {
        if (out.mismatched++ < 5) fail(`${name}: step ${step} at ${ms} ms holds ${applied} packs, not ${ms === null ? '?' : packsAt(ms, count)}`);
      }
    }
    out.packCount = rows.at(-1)?.[3];
    if (out.rows < RUN_SECONDS * HZ * 0.9) fail(`${name}: ${out.rows} traced frames, expected about ${RUN_SECONDS * HZ}`);
    if (!out.wrapped) fail(`${name}: the run did not wrap the synthetic loop`);
    if (key !== 'none' && !out.textures.some(t => t.opaque > 0)) fail(`${name}: the window has no opaque texel`);
    if (mask !== undefined) {
      const done = out.textures.filter(t => t.applied === out.packCount);
      out.masks = [...new Set(out.textures.map(t => t.mode === 4 ? t.mask : -1))];
      if (!done.length) fail(`${name}: no texture read at the end of the stream`);
      for (const t of done) if (t.mode !== 4 || t.mask !== mask) fail(`${name}: auto keyed mask ${t.mask.toString(16)} (mode ${t.mode}) at the end, not ${mask.toString(16)}`);
    }
    if (page.errors.length) fail(`${name}: page errors: ${page.errors.join(' | ')}`);
    console.log(`${name}: ${out.rows} frames, ${out.mismatched} off the pack clock, wrapped ${out.wrapped}, ` +
      `${out.textures.length} texture reads, opaque texels max ${Math.max(...out.textures.map(t => t.opaque))}` +
      (out.masks ? `, auto masks ${out.masks.map(m => m.toString(16)).join(' ')}` : ''));
  } finally {
    await page.close();
  }
  return out;
}

// A .cdg dropped together with its song: both load, and each frame on the song holds the
// packs of its playback position, which advances on the audio clock.
async function dropCheck() {
  const page = await hostPage({ visual: 'aurora', size: '160x90', quality: '3', trace: '' });
  const out = { rows: 0, mismatched: 0, offLatency: 0 };
  try {
    await page.evaluate(async () => {
      const files = [['../../conformance/cdg/lyrics.cdg', 'lyrics.cdg', 'application/octet-stream'],
        ['../../conformance/dsp/kicks-120bpm.wav', 'kicks-120bpm.wav', 'audio/wav']];
      const dt = new DataTransfer();
      for (const [url, name, type] of files) dt.items.add(new File([await (await fetch(url)).arrayBuffer()], name, { type }));
      dispatchEvent(new DragEvent('drop', { dataTransfer: dt, cancelable: true }));
    });
    let start = null;
    for (let i = 0; i < 300; i++) {
      await page.evaluate(hz => window.__catchUp(hz), HZ);
      const s = await page.evaluate(() => ({ loaded: window.__oscilluxCdg.name, n: window.__oscilluxTrace.cdg.length,
        file: window.__oscilluxTrace.cdg.at(-1)?.[0] === null }));
      if (start === null && s.loaded === 'lyrics.cdg' && s.file) start = s.n;
      if (start !== null && s.n - start >= 120) break;
      await page.waitForTimeout(25);
    }
    if (start === null) fail('drop: the stream and song did not both load');
    const rows = start === null ? [] : (await page.evaluate(() => window.__oscilluxTrace.cdg)).slice(start).filter(r => r[0] === null);
    out.rows = rows.length;
    for (const [, ms, applied, count, write] of rows) {
      if (ms === null || applied !== packsAt(ms, count)) {
        if (out.mismatched++ < 5) fail(`drop: at ${ms} ms the decoder holds ${applied} packs, not ${ms === null ? '?' : packsAt(ms, count)}`);
      }
      // the lyrics at the heard position: the write position less the latency (from the
      // song's start, before a wrap)
      if (ms > 0 && write > ms && Math.abs(write - ms - LATENCY_MS) > 0.01) {
        if (out.offLatency++ < 5) fail(`drop: lyrics at ${ms} ms while the song writes ${write} ms, not ${LATENCY_MS} ms behind`);
      }
    }
    out.heard = rows.filter(([, ms, , , write]) => ms > 0 && write > ms).length;
    if (out.heard < 60) fail(`drop: ${out.heard} frames to compare with the write position, expected 60 or more`);
    // the 2 s song loops, so its position moves forward on all but the wrapping frames
    out.forward = rows.filter((r, i) => i > 0 && r[1] > rows[i - 1][1]).length;
    if (out.forward < rows.length / 2) fail(`drop: the song's position moved forward on ${out.forward} of ${rows.length} frames`);
    const t = await textureMatches(page);
    if (t.error || t.differ) fail(`drop: layer texture differs from the decoder (${t.error ?? `${t.differ} texels`})`);
    if (page.errors.length) fail(`drop: page errors: ${page.errors.join(' | ')}`);
    console.log(`drop: ${out.rows} frames on the song, ${out.forward} moving forward, ${out.mismatched} off the pack clock, ` +
      `${out.offLatency} of ${out.heard} not ${LATENCY_MS} ms behind the write position`);
  } finally {
    await page.close();
  }
  return out;
}

// An MP3+G .zip, dropped or given by ?karaoke=: its song and lyrics both open, the frames on
// the song hold its packs, and auto keys the blue background once the stream has played.
async function karaokeCheck(via) {
  const name = `karaoke ${via}`;
  const params = { visual: 'aurora', size: '160x90', quality: '3', trace: '' };
  const page = await hostPage(via === 'url' ? { ...params, karaoke: '/karaoke.zip' } : params);
  const out = { via, rows: 0, mismatched: 0 };
  try {
    if (via === 'drop') {
      await page.evaluate(async () => {
        const dt = new DataTransfer();
        dt.items.add(new File([await (await fetch('/karaoke.zip')).arrayBuffer()], 'Artist - Song.zip', { type: 'application/zip' }));
        dispatchEvent(new DragEvent('drop', { dataTransfer: dt, cancelable: true }));
      });
    }
    let start = null;
    for (let i = 0; i < 300; i++) {
      await page.evaluate(hz => window.__catchUp(hz), HZ);
      const s = await page.evaluate(() => ({ loaded: window.__oscilluxCdg.name, n: window.__oscilluxTrace.cdg.length,
        file: window.__oscilluxTrace.cdg.at(-1)?.[0] === null }));
      if (start === null && s.loaded === 'Artist - Song.cdg' && s.file) start = s.n;
      if (start !== null && s.n - start >= 120) break;
      await page.waitForTimeout(25);
    }
    if (start === null) fail(`${name}: the archive's song and lyrics did not both load (${await page.evaluate(() => document.getElementById('err').textContent)})`);
    const rows = start === null ? [] : (await page.evaluate(() => window.__oscilluxTrace.cdg)).slice(start).filter(r => r[0] === null);
    out.rows = rows.length;
    for (const [, ms, applied, count] of rows) {
      if (ms === null || applied !== packsAt(ms, count)) {
        if (out.mismatched++ < 5) fail(`${name}: at ${ms} ms the decoder holds ${applied} packs, not ${ms === null ? '?' : packsAt(ms, count)}`);
      }
    }
    // the 2 s song outlasts the 0.98 s stream: wait for a frame past its end
    for (let i = 0; i < 200; i++) {
      const done = await page.evaluate(() => window.__oscilluxCdg.cdg?.applied === window.__oscilluxCdg.cdg?.packCount);
      if (done) break;
      await page.evaluate(hz => window.__catchUp(hz), HZ);
      await page.waitForTimeout(25);
    }
    const t = await textureMatches(page);
    out.mask = t.mask;
    if (t.error || t.differ) fail(`${name}: layer texture differs from the decoder (${t.error ?? `${t.differ} texels`})`);
    if (t.applied === undefined || t.mode !== 4 || t.mask !== 0x0002) fail(`${name}: keyed mode ${t.mode} mask ${t.mask?.toString(16)} at ${t.applied} packs, not auto's 2`);
    if (page.errors.length) fail(`${name}: page errors: ${page.errors.join(' | ')}`);
    console.log(`${name}: ${out.rows} frames on the song, ${out.mismatched} off the pack clock, auto mask ${t.mask?.toString(16)} at ${t.applied} packs`);
  } finally {
    await page.close();
  }
  return out;
}

// The canvas at the same stepped frame with and without the lyric screen.
async function canvasAt(params, seconds) {
  const page = await hostPage(params);
  try {
    const target = Math.round(seconds * HZ);
    for (let i = 0; i < 400; i++) {
      const steps = await page.evaluate(() => window.__oscilluxTrace.beats.at(-1)?.[0] ?? 0);
      if (steps >= target - 1) break;
      await page.evaluate(([n, hz]) => window.__tick(n, hz), [Math.min(15, target - 1 - steps), HZ]);
    }
    // the last frame and its read in one task, before the canvas is presented and cleared
    const px = await page.evaluate(hz => {
      window.__tick(1, hz);
      const gl = document.getElementById('c').getContext('webgl2');
      const w = gl.drawingBufferWidth, h = gl.drawingBufferHeight, p = new Uint8Array(w * h * 4);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, p);
      return Array.from(p);
    }, HZ);
    const steps = await page.evaluate(() => window.__oscilluxTrace.beats.at(-1)?.[0]);
    if (page.errors.length) fail(`canvas ${params.cdg ?? 'without lyrics'}: page errors: ${page.errors.join(' | ')}`);
    return { steps, px };
  } finally {
    await page.close();
  }
}

async function canvasCheck() {
  const base = { visual: 'aurora', size: '160x90', quality: '3', trace: '' };
  const a = await canvasAt(base, 1);
  const b = await canvasAt({ ...base, cdg: '../../conformance/cdg/lyrics.cdg' }, 1);
  let changed = 0;
  for (let i = 0; i < a.px.length; i += 4) {
    if (Math.abs(a.px[i] - b.px[i]) + Math.abs(a.px[i + 1] - b.px[i + 1]) + Math.abs(a.px[i + 2] - b.px[i + 2]) > 24) changed++;
  }
  const share = changed / (a.px.length / 4);
  if (a.steps !== b.steps) fail(`canvas: compared steps ${a.steps} and ${b.steps}`);
  if (share < 0.01) fail(`canvas: the lyrics change ${(share * 100).toFixed(2)}% of the canvas`);
  console.log(`canvas at step ${b.steps}: lyrics change ${(share * 100).toFixed(1)}% of the pixels`);
  return { steps: b.steps, changedShare: share };
}

async function screenshot(dir) {
  mkdirSync(dir, { recursive: true });
  const page = await hostPage({ visual: 'aurora', size: '960x540', quality: '3', trace: '', cdg: '../../conformance/cdg/lyrics.cdg' }, { width: 960, height: 540 });
  try {
    // the frame and its encoding in one task, before the canvas is presented and cleared (a
    // locator screenshot waits on requestAnimationFrame, which this page queues)
    const url = await page.evaluate(([n, hz]) => {
      window.__tick(n, hz);
      return document.getElementById('c').toDataURL('image/png');
    }, [HZ, HZ]);
    writeFileSync(join(dir, 'web-host.png'), Buffer.from(url.slice(url.indexOf(',') + 1), 'base64'));
    console.log(`wrote ${join(dir, 'web-host.png')}`);
  } finally {
    await page.close();
  }
}
