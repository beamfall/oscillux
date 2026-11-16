// SPDX-License-Identifier: AGPL-3.0-only
// Dev-only watch-mode preview. On every change under the manifest's directory
// (and to the pass list, when given) it reloads the manifest, wraps every visual
// for its node-only targets, validates the pass list, then runs render.mjs on
// the manifest. Not part of `make gate`; see docs/shader-toolchain.md.
//
//   node tools/shader/watch.mjs <manifest.json> [--passes pass-list.json]
//        [--once] [--no-render] [--out DIR] [--frames N] [--only id1,id2] [--img PNG]
//
// --once runs one iteration and exits with its status (0 ok, 1 invalid input,
// otherwise render.mjs's exit code). --no-render skips render.mjs, which needs
// Playwright Chromium. Changes to tools/shader itself need a restart.
//
// SIGINT, SIGTERM or SIGHUP, in either mode, sends SIGTERM to a running
// render.mjs, waits for it to exit (SIGKILL after KILL_AFTER_MS), then exits
// 128 + the signal number.
import { spawn } from 'node:child_process';
import { watch } from 'node:fs';
import { constants } from 'node:os';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { emitManifest } from './emit.mjs';
import { loadManifest } from './manifest.mjs';
import { loadPassList } from './passes.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const DEBOUNCE_MS = 150;
const KILL_AFTER_MS = 3000;

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    passes: { type: 'string', default: '' },
    once: { type: 'boolean', default: false },
    'no-render': { type: 'boolean', default: false },
    out: { type: 'string', default: '' },
    frames: { type: 'string', default: '' },
    only: { type: 'string', default: '' },
    img: { type: 'string', default: '' },
  },
});
if (positionals.length !== 1) {
  console.error('usage: watch.mjs <manifest.json> [--passes FILE] [--once] [--no-render] [--out DIR] [--frames N] [--only ids] [--img PNG]');
  process.exit(64);
}
const MANIFEST = resolve(positionals[0]);
const PASSES = opts.passes ? resolve(opts.passes) : '';
const OUT = resolve(opts.out || join(ROOT, 'out', 'shader-renders'));
const renderArgs = [join(HERE, 'render.mjs'), MANIFEST, '--out', OUT];
for (const key of ['frames', 'only', 'img']) if (opts[key]) renderArgs.push(`--${key}`, opts[key]);

let child = null;
let childExit = null; // resolves once the running child has exited

// One iteration: returns 0 when everything passed, 1 for invalid input, or
// render.mjs's exit code.
async function iterate() {
  const started = Date.now();
  try {
    const manifest = loadManifest(MANIFEST);
    const shaders = emitManifest(manifest);
    let summary = `${manifest.visuals.length} visual(s), ${shaders.size} shader(s) wrapped`;
    if (PASSES) {
      const list = loadPassList(PASSES, { visualIds: new Set(manifest.byId.keys()) });
      summary += `, pass list ok (${list.passes.length} passes)`;
    }
    console.log(`[watch] ${summary}`);
  } catch (e) {
    console.error(`[watch] invalid: ${e.message}`);
    return 1;
  }
  if (opts['no-render']) return 0;
  const code = await new Promise(done => {
    child = spawn(process.execPath, renderArgs, { stdio: 'inherit' });
    childExit = new Promise(exited => {
      child.on('error', e => { console.error(`[watch] render.mjs: ${e.message}`); done(1); exited(); });
      child.on('exit', (c, signal) => { done(c ?? (signal ? 1 : 0)); exited(); });
    });
  });
  child = null;
  childExit = null;
  console.log(`[watch] render.mjs exited ${code} after ${Date.now() - started} ms`);
  return code;
}

let timer = null;
const watchers = [];
let stopping = false;
async function stop(signal) {
  if (stopping) return;
  stopping = true;
  clearTimeout(timer);
  for (const w of watchers) w.close();
  if (child) {
    const exited = childExit;
    child.kill('SIGTERM');
    let timeout;
    const done = await Promise.race([
      exited.then(() => true),
      new Promise(r => { timeout = setTimeout(r, KILL_AFTER_MS, false); }),
    ]);
    clearTimeout(timeout);
    if (!done) {
      console.error(`[watch] render.mjs still running ${KILL_AFTER_MS} ms after SIGTERM; sending SIGKILL`);
      child.kill('SIGKILL');
      await exited;
    }
  }
  process.exit(128 + constants.signals[signal]);
}
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => stop(signal));

// Watch mode: debounce bursts of events and never run two iterations at once.
let running = false;
let pending = false;
async function schedule() {
  if (stopping) return;
  if (running) { pending = true; return; }
  running = true;
  do {
    pending = false;
    await iterate();
  } while (pending && !stopping);
  running = false;
  if (stopping) return;
  console.log('[watch] waiting for changes (Ctrl-C to stop)');
}
function onChange(base, only = '') {
  return (_event, name) => {
    const path = name ? resolve(base, name.toString()) : base;
    if (path === OUT || path.startsWith(OUT + sep) || (only && path !== only)) return;
    clearTimeout(timer);
    timer = setTimeout(schedule, DEBOUNCE_MS);
  };
}

async function watchMode() {
  const manifestDir = dirname(MANIFEST);
  watchers.push(watch(manifestDir, { recursive: true }, onChange(manifestDir)));
  // Watch the pass list's directory, not the file, so editors that save by
  // replacing the file keep being seen.
  if (PASSES && !PASSES.startsWith(manifestDir + sep)) {
    watchers.push(watch(dirname(PASSES), onChange(dirname(PASSES), PASSES)));
  }
  await schedule();
}

if (opts.once) {
  const code = await iterate();
  if (!stopping) process.exit(code); // otherwise stop() exits once render.mjs is gone
} else {
  await watchMode();
}
