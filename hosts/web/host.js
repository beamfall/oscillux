// SPDX-License-Identifier: AGPL-3.0-only
// WebGL2 reference host for a bundled visual set (tools/shader/bundle-hosts.mjs).
// The pipeline matches tools/shader/render.mjs and hosts/apple: RGBA16F
// ping-pong feedback, a fixed 1/60 s step and the shared present pass
// (shaders/present/present.glsl) with the page's overlay regions (overlay.js),
// with audio through the Oscillux DSP, mapper and reaction sampler (audio.js).
// Without a renderable RGBA16F the feedback falls back to 8 bits (feedbackFormat),
// and a lost WebGL context is rebuilt in place when the browser restores it
// (the webglcontextrestored handler in start).
// The drawing buffer is preserved only for capture and trace runs (frames, size,
// trace), which read the canvas after the frame.
// Query parameters: visual=<id>, frames=<N> (stop after N
// frames), size=<W>x<H> (fixed render size instead of the window's),
// colour=vivid|manifest (palette tour and saturation, or the manifest palette),
// quality=auto|0..3 (governed or fixed quality level; auto unless size or
// frames is given, which pin the top level), transition=auto|<id> (cycle
// through the switch transitions, or always use one), quantise=bar|beat|none
// (where a switch starts: on the next bar or beat of the tracked music
// after a 0.5 s pre-roll, or at once), trace (record each switch in
// window.__oscilluxTrace for tools/shader/transition-check.mjs),
// cdg=<url> (CD+G lyrics over the visual, cdg.js; a .cdg, or an MP3+G .zip with its song,
// karaoke-zip.js), karaoke=<url> (the same, for a .zip), cdgkey=auto|preset|table|none|index:<N>|mask:<hex>
// (its transparency key, auto by default: the colours of the window edge), type=<id> and
// intensity=<id> (show only the visuals of that type and intensity,
// hosts/categories.json), collection=<id> (show only that curated collection,
// in its order, and switch with its transitions, hosts/collections.json).
import { Audio } from './audio.js';
import { CdgLayer, parseCdgKey } from './cdg.js';
import { looksLikeZip, openKaraokeZip, ZIP_LIMITS } from './karaoke-zip.js';
import { paletteTour, VIVID_SATURATION, VIVID_VIBRANCE } from '../../tools/shader/palette-tour.mjs';
import { Governor } from '../../tools/shader/governor.mjs';
import { defaultPreset, presetUniforms } from '../../tools/shader/preset.mjs';
import { TransitionDirector, QUANTISE_NONE, QUANTISE_BEAT, QUANTISE_BAR, STATE_BLENDING, STATE_DONE } from './transition.js';
import { DEFAULT_CONFIG, packOverlay, trackOverlay } from './overlay.js';

const DT = 1 / 60;
const AUDIO_KEYS = ['amplitude', 'bass', 'mid', 'treble', 'beat', 'beatPhase', 'onset', 'bassImpact',
  'level', 'spectralCentroid', 'flux', 'beatCount', 'barPhase', 'downbeat'];
// The present pass is the bundle's shared one (shaders/present/present.glsl),
// which Renderer.swift draws too. During a switch it dissolves from the
// outgoing frame (texture 1) to the incoming one (texture 0) in linear light,
// before the tone map, with present0.y the eased progress, 1 outside a switch.
// present0.z 0 writes the blend unmapped, to hold it as the outgoing frame when
// a switch starts during another. A switch with a bundled transition blends in
// the transition's own pass instead, and this pass then maps that blend with
// progress 1. On screen it draws into an RGBA8 target with a history target
// beside it, the previous presented frame it damps against, and is blitted to
// the canvas. Its block is present0 and then the OverlayUniforms of the page's
// overlay regions.

// Quality levels, lowest first: render scale of each side, and the detail
// reduction passed in presentation1.y. hosts/apple/Sources/Renderer.swift
// has the same ladder.
const LADDER = [{ scale: 0.5, reduce: 1 }, { scale: 0.67, reduce: 0.6 }, { scale: 0.83, reduce: 0.25 }, { scale: 1, reduce: 0 }];
// A switch is scheduled by TransitionDirector (transition.js) in presentation
// time: the incoming visual starts at the request and runs offscreen through
// the pre-roll, the blend starts on the next bar (or beat) and lasts four
// beats, 0.8 to 2.5 s, or 1.6 s without a beat. The outgoing visual keeps
// running during it, every frame when the averaged GPU time leaves room for
// two visuals. Otherwise it steps every second or third frame at the same
// speed, so the average frame stays within 90% of the budget. Above that its
// frame holds and only drifts.
function outgoingStride(ms) {
  if (ms === null) return 2;
  const n = Math.ceil(ms / Math.max(0.9 * 1000 / 60 - ms, 1e-3));
  return n <= 3 ? Math.max(n, 1) : 0;
}

const query = new URLSearchParams(location.search);
const quantise = { none: QUANTISE_NONE, beat: QUANTISE_BEAT, bar: QUANTISE_BAR }[query.get('quantise')] ?? QUANTISE_BAR;
const trace = query.has('trace') ? (window.__oscilluxTrace = { switches: [], frames: [], beats: [], cdg: [], restores: [] }) : null;
const stopAt = query.has('frames') ? parseInt(query.get('frames'), 10) : Infinity;
const fixedSize = /^(\d+)x(\d+)$/.exec(query.get('size') ?? '');
let vivid = query.get('colour') !== 'manifest';
const pinned = /^[0-3]$/.test(query.get('quality') ?? '') ? +query.get('quality')
  : query.get('quality') !== 'auto' && (fixedSize || query.has('frames')) ? LADDER.length - 1 : null;
const $ = id => document.getElementById(id);
const canvas = $('c');
const capture = query.has('frames') || fixedSize !== null || trace !== null;
const gl = canvas.getContext('webgl2', { antialias: false, preserveDrawingBuffer: capture });
// Without this the browser would not restore a context lost before start() has
// its own handlers (see the webglcontextrestored handler in start).
canvas.addEventListener('webglcontextlost', e => e.preventDefault());
// Where the browser offers timer queries, the governor reads the visual pass's
// GPU time with the Apple host's thresholds: at vsync the frame interval sticks
// at the refresh period and hides both a small overrun and the headroom to step
// up. Without them it reads the frame interval with the default configuration.
// Extension objects die with the context, so build() fetches them again.
let timer = gl?.getExtension('EXT_disjoint_timer_query_webgl2') ?? null;
// The feedback and history targets' format (feedbackFormat).
let feedback = null;
const governor = new Governor({
  ...(timer ? { demoteFactor: 0.9, promoteRefreshFactor: 0.01, promoteTargetFactor: 0.2 } : {}),
  maxLevel: LADDER.length - 1, initialLevel: pinned ?? LADDER.length - 1,
});

try {
  if (!gl) throw new Error('WebGL2 is not available');
  const res = await fetch('../../out/hosts/visuals.json');
  if (!res.ok) throw new Error(`visuals.json: HTTP ${res.status}; run make host-bundle`);
  const [bundle, audio] = [await res.json(), await Audio.create()];
  if (gl.isContextLost()) await new Promise(r => canvas.addEventListener('webglcontextrestored', r, { once: true }));
  start(bundle, audio);
} catch (e) {
  $('err').textContent = String(e.message || e);
}

function start(bundle, audio) {
  const layerBlock = new Float32Array(32);
  layerBlock.set([0, 1.5, 1, 0, 4.5, 3, 1, 0], 4);
  // present0, the 320-byte overlay block, then post0/post1 (presentPost in tools/shader/present.mjs):
  // bloom, aberration and grain stay 0 here; the dither is on and its noise moves each frame.
  const presentBlock = new Float32Array(92);
  let presentFrame = 0;
  const presentBytes = new Uint8Array(presentBlock.buffer, 16);
  // The GL objects that outlive a frame, made by build() at start and again
  // when a lost context is restored. `picture` is the picked image, kept to
  // upload again.
  let quad, vs, vsFbo, present, presentFbo, presentCdg, layerUbo, ubo, image, parallel, gpuQuery;
  let picture = null, cdg = null;
  function build() {
    feedback = feedbackFormat();
    timer = gl.getExtension('EXT_disjoint_timer_query_webgl2');
    parallel = gl.getExtension('KHR_parallel_shader_compile');
    gpuQuery = timer && gl.createQuery();
    quad = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    vs = compile(gl.VERTEX_SHADER, bundle.vertex);
    // Offscreen passes negate clip-space y so texel row v == vUV.y (render.mjs).
    vsFbo = compile(gl.VERTEX_SHADER,
      bundle.vertex.replace('gl_Position = vec4(aPos, 0.0, 1.0);', 'gl_Position = vec4(aPos.x, -aPos.y, 0.0, 1.0);'));
    // The on-screen present draws into a target blitted unflipped to the canvas,
    // so it uses the canvas vertex shader; the bake into a feedback target, the
    // offscreen one.
    present = presentProgram(vs, bundle.present.web);
    presentFbo = presentProgram(vsFbo, bundle.present.web);
    // With CD+G lyrics loaded the on-screen present is the bundle's lyric pass (presentCdg:
    // the present pass with shaders/cdg/cdg-layer.glsl as its host layer); the bake into a
    // feedback target never carries them. Its layer block: the output size, the placement
    // (contain at the 3:2 square-pixel aspect, whole output pixels per CD+G row) and the
    // 4.5:1 halo with a 3 px feather.
    // A lyric pass that does not build leaves the lyrics hidden, not the host down.
    presentCdg = null;
    try {
      if (bundle.presentCdg) presentCdg = presentProgram(vs, bundle.presentCdg.web, true);
    } catch (e) {
      console.warn(`cdg: the lyric pass did not build, lyrics stay hidden (${e.message || e})`);
    }
    layerUbo = gl.createBuffer();
    gl.bindBuffer(gl.UNIFORM_BUFFER, layerUbo);
    gl.bufferData(gl.UNIFORM_BUFFER, layerBlock.byteLength, gl.DYNAMIC_DRAW);
    ubo = gl.createBuffer();
    gl.bindBuffer(gl.UNIFORM_BUFFER, ubo);
    gl.bufferData(gl.UNIFORM_BUFFER, presentBlock.byteLength, gl.DYNAMIC_DRAW);
    image = gl.createTexture();
    standInImage(image);
    if (picture) upload(image, picture);
    if (cdg) cdg.restore(); else cdg = new CdgLayer(gl, audio.m);
  }
  build();
  cdg.setKey(parseCdgKey(query.get('cdgkey')));
  // the layer for tools/shader/cdg-host-check.mjs, which compares its texture with the decoder
  if (trace) window.__oscilluxCdg = cdg;
  // The marked UI (index.html), its safe rectangle and reduced motion.
  const overlay = trackOverlay(document);
  let screen = null, lastPresent = null;

  const pick = $('pick'), type = $('type'), intensity = $('intensity'), collection = $('collection');
  const byId = new Map(bundle.visuals.map(v => [v.id, v]));
  const collections = new Map((bundle.collections ?? []).map(c => [c.id, c]));
  // The collection, type and intensity filters: the picker, prev/next and the
  // warmed neighbours cover only the visuals in `listed`.
  collection.add(new Option('All visuals', ''));
  for (const c of collections.values()) collection.add(new Option(c.label, c.id));
  type.add(new Option('All types', ''));
  for (const t of bundle.types) type.add(new Option(t.label, t.id));
  intensity.add(new Option('Any intensity', ''));
  for (const i of bundle.intensities) intensity.add(new Option(i.label, i.id));
  const filters = [[collection, 'collection'], [type, 'type'], [intensity, 'intensity']];
  for (const [el, key] of filters) {
    if ([...el.options].some(o => o.value && o.value === query.get(key))) el.value = query.get(key);
  }
  const transitions = bundle.transitions ?? [];
  // The visuals the type and intensity filters choose from: the collection's,
  // in its order, or the whole bundle.
  const pool = () => collections.get(collection.value)?.visuals.map(id => byId.get(id)) ?? bundle.visuals;
  const matches = (v, t, i) => (!t || v.type === t) && (!i || v.intensity === i);
  const any = (t, i) => pool().some(v => matches(v, t, i));
  // Every transition once, or the collection's own, in a fixed shuffle that
  // Renderer.swift shares; `switches` counts switches and picks the next one.
  let listed = bundle.visuals, order = [];
  // Rebuilds `listed`, the picker and the transition cycle from the filters,
  // dropping the type and intensity when the collection or type has none of
  // them, and disables the options that would match nothing.
  function filter() {
    if (!any(type.value, '')) type.value = '';
    if (!any(type.value, intensity.value)) intensity.value = '';
    for (const o of type.options) o.disabled = !any(o.value, intensity.value);
    for (const o of intensity.options) o.disabled = !any(type.value, o.value);
    listed = pool().filter(v => matches(v, type.value, intensity.value));
    pick.replaceChildren(...listed.map(v => new Option(v.id, v.id)));
    const own = collections.get(collection.value)?.transitions;
    order = shuffled(own ? transitions.filter(t => own.includes(t.id)) : transitions);
    const url = new URL(location.href);
    for (const [el, key] of filters) {
      if (el.value) url.searchParams.set(key, el.value); else url.searchParams.delete(key);
    }
    history.replaceState(null, '', url);
  }
  filter();
  // Each visual's tunable uniforms, resolved once from its default preset (tools/shader/preset.mjs).
  const tuning = new Map(bundle.visuals.map(v => [v, presetUniforms(defaultPreset(v), v)]));
  const trans = $('trans');
  for (const t of transitions) trans.add(new Option(t.id, t.id));
  if (transitions.some(t => t.id === query.get('transition'))) trans.value = query.get('transition');
  // `active` is the switch's transition program, made from `activeTransition`.
  let switches = 0, active = null, activeTransition = null, seed = 0, mix = null;
  // A layer is one running visual: its program, feedback targets and clock.
  // `out` is the outgoing layer during a switch; `progress` counts its steps.
  let cur = null, out = null, progress = 0, paused = false, frameMs = null, gpuMs = null;
  let timing = false, staleGpu = false, draws = 0;
  // The switch's schedule and its blend progress p (0 until the incoming
  // visual shows, exactly 1 on the last blended frame); `shown` once it has
  // shown. clockMs is presentation time, which stops while paused. A switch
  // is timed as a whole frame, both visuals and the blend (timedBoth), and
  // the governor's level applies to the render size and detail (`level`)
  // only between switches: a size change would end the switch. A begun
  // switch is requested on the first frame that steps the outgoing visual
  // (requestDue); tickMs is the display frame interval.
  const director = new TransitionDirector(quantise);
  let blendP = 0, shown = false, clockMs = 0, timedBoth = false, level = governor.level;
  let requestDue = false, requestUsed = null, tickMs = null;
  const p0 = [0, 0, 0, 0], VISUAL_P0 = [0, 1, 0, 0];

  // Programs are compiled ahead of a switch and kept: compiling on the frame
  // that switches stalls it. With KHR_parallel_shader_compile the driver
  // compiles in the background, and a switch waits for the program with the
  // current visual still running. After each switch the neighbouring visuals
  // are compiled, one per frame, so the previous and next buttons find them
  // ready.
  const programs = new Map();
  let pending = null, warm = [];

  // Visual programs are keyed by id, transition programs by transitionKey(id).
  function prepare(v, key = v.id) {
    let e = programs.get(key);
    if (!e) {
      const fs = gl.createShader(gl.FRAGMENT_SHADER);
      gl.shaderSource(fs, v.web); gl.compileShader(fs);
      const p = gl.createProgram();
      gl.attachShader(p, vsFbo); gl.attachShader(p, fs); gl.linkProgram(p);
      programs.set(key, e = { p, fs, error: null, checked: false });
    }
    return e;
  }

  // Returns the program once it has compiled, null while it is compiling
  // (unless `wait`), and throws if it failed.
  function program(v, key = v.id, wait = false) {
    const e = prepare(v, key);
    if (!e.checked) {
      if (parallel && !wait && !gl.getProgramParameter(e.p, parallel.COMPLETION_STATUS_KHR)) return null;
      e.checked = true;
      if (!gl.getProgramParameter(e.p, gl.LINK_STATUS))
        e.error = gl.getShaderInfoLog(e.fs) || gl.getProgramInfoLog(e.p);
      gl.deleteShader(e.fs);
    }
    if (e.error) throw new Error(e.error);
    return e.p;
  }

  function select(id) {
    const v = listed.includes(byId.get(id)) ? byId.get(id) : listed[0];
    $('err').textContent = '';
    prepare(v);
    pending = v;
  }

  // Called each frame: starts the pending visual once its program is ready,
  // otherwise compiles one neighbour.
  function startPending() {
    if (!pending) {
      const v = warm.shift();
      if (v) prepare(v);
      return;
    }
    let p;
    try {
      p = program(pending);
    } catch (e) {
      $('err').textContent = `${pending.id}: ${e.message}`;
      pending = null;
      return;
    }
    if (!p) return;
    const v = pending, i = listed.indexOf(v), n = listed.length;
    pending = null;
    pick.value = v.id;
    $('title').textContent = v.title;
    $('caption-title').textContent = v.title;
    const url = new URL(location.href);
    url.searchParams.set('visual', v.id);
    history.replaceState(null, '', url);
    begin(v, p);
    warm = [listed[(i + 1) % n], listed[(i + n - 1) % n]];
  }

  const transitionKey = id => 'transition/' + id;

  // The transition the next switch uses: the picked one, or the next in the
  // shuffled cycle.
  function nextTransition() {
    return transitions.find(t => t.id === trans.value) ?? order[switches % order.length] ?? null;
  }

  // Transition t's program (the next one's by default) if it has compiled; a
  // transition that is still compiling, or failed, leaves the switch to the
  // present pass.
  function transitionProgram(t = nextTransition(), wait = false) {
    if (!t) return null;
    try {
      return program(t, transitionKey(t.id), wait);
    } catch (e) {
      console.warn(`transition ${t.id}: ${e.message}`);
      return null;
    }
  }

  function restart() {
    audio.restart();
    if (trace) trace.beats.length = 0;
    if (cur) begin(cur.visual, cur.prog);
  }

  // Starts visual v with program p from frame 0. After the first visual this is
  // a switch: the current layer becomes the outgoing one. A switch during
  // another first bakes the blend on screen into the outgoing layer, which then
  // holds, so nothing on screen jumps.
  function begin(v, p) {
    const dims = cur && [cur.targets[0].w, cur.targets[0].h];
    if (out && !shown) {
      // the incoming visual has not shown yet: it is dropped and the outgoing
      // one keeps running
      freeTargets(cur);
    } else if (out) {
      const [a, b] = out.targets;
      if (active) blend(b); else composite(presentFbo, b.f, b.w, b.h);
      out.targets = [b, a];
      out.prog = null;
      out.stride = 0;
      freeTargets(cur);
    } else if (cur) {
      out = cur;
      out.stride = outgoingStride(gpuMs);
    }
    cur = { visual: v, prog: p, frame: 0, stride: 1, targets: dims ? [target(...dims), target(...dims)] : null,
      locations: new Map() };
    progress = 0;
    if (out) {
      activeTransition = nextTransition();
      active = transitionProgram(activeTransition);
      seed = (switches * 0.618034) % 1;
      requestUsed = trace && active ? activeTransition?.id : null;
      switches++;
      director.reset();
      requestDue = true;
      blendP = 0;
      shown = false;
    }
    const t = nextTransition();
    if (t) prepare(t, transitionKey(t.id));
    governor.reset(governor.level);
    staleGpu = timing;
    resize();
  }

  // Schedules the begun switch at presentation time t from the beat clock the
  // visuals react to: the reaction sampler's beat for the frame just stepped.
  // The synthetic source runs on the step clock, so below 60 Hz its music runs
  // slower by the step rate; a file or the microphone runs in real time.
  function requestSwitch(t) {
    const c = director.clock, v = audio.values;
    const rate = audio.live || frameMs === null ? 1 : Math.min(1, STEP_MS / frameMs);
    c.timeSeconds = t;
    c.beatPhase = v.beatPhase;
    c.barPhase = v.barPhase;
    c.tempoBpm = v.tempo * rate;
    // quantise none ignores the beat: the blend starts after the pre-roll and
    // lasts 1.6 s, as it does before the tracker locks
    c.confidence = quantise === QUANTISE_NONE || !v.locked ? 0 : v.confidence;
    director.request();
    requestDue = false;
    trace?.switches.push({ ...director.status, clock: { ...c }, outFrame: out.frame, transition: requestUsed,
      shownSeconds: null, ownSecondsShown: null, lastP: null, doneSeconds: null });
  }

  function finish() {
    freeTargets(out);
    out = null;
    director.reset();
    blendP = 0;
    active = null;
    if (mix) freeTargets({ targets: [mix] });
    mix = null;
  }

  function freeTargets(layer) {
    for (const t of layer.targets) { gl.deleteTexture(t.t); gl.deleteFramebuffer(t.f); }
  }

  // A lost context takes every GL object with it. While it is lost nothing
  // draws and presentation time holds; when the browser restores it, build()
  // makes the objects again, the running layers get their programs back and
  // fresh feedback targets of the same size (the history went with the
  // context), and the switch in progress carries on from its schedule. The
  // programs compile synchronously here: the visual on screen cannot wait for
  // a background compile it was not warmed for. An outgoing layer that was
  // baked and holds has nothing to redraw it from, so its switch ends there.
  // The next transition and the neighbours compile in the background again, as
  // after a switch.
  let lost = false;
  canvas.addEventListener('webglcontextlost', e => {
    e.preventDefault();
    lost = true;
    trace?.restores.push({ lostAt: performance.now(), restoredAt: null, drawnAt: null, visual: cur?.visual.id ?? null,
      frame: cur?.frame ?? null, state: director.status.state, blendP, held: !!out && !out.prog, feedback: null });
  });
  canvas.addEventListener('webglcontextrestored', () => {
    const r = trace?.restores.at(-1);
    if (r) r.restoredAt = performance.now();
    try {
      build();
    } catch (e) {
      $('err').textContent = `restore: ${e.message || e}`;
      return;
    }
    programs.clear();
    screen = mix = null;
    timing = staleGpu = timedBoth = false;
    for (const layer of [cur, out]) {
      if (!layer) continue;
      layer.locations = new Map();
      if (layer.targets) layer.targets = layer.targets.map(t => target(t.w, t.h));
      if (!layer.prog) continue;
      try {
        layer.prog = program(layer.visual, layer.visual.id, true);
      } catch (e) {
        $('err').textContent = `${layer.visual.id}: ${e.message}`;
      }
    }
    if (out && !out.prog) finish();
    if (active) active = transitionProgram(activeTransition, true);
    const t = nextTransition();
    if (t) prepare(t, transitionKey(t.id));
    if (cur && listed.length) {
      const i = listed.indexOf(cur.visual), n = listed.length;
      warm = [listed[(i + 1) % n], listed[(i + n - 1) % n]];
    }
    lost = false;
    if (r) r.feedback = feedback.label;
  });

  // A size change ends a switch: both layers would lose their history anyway.
  function resize() {
    const dpr = Math.min(devicePixelRatio || 1, 2);
    const W = fixedSize ? +fixedSize[1] : Math.max(1, Math.round(canvas.clientWidth * dpr));
    const H = fixedSize ? +fixedSize[2] : Math.max(1, Math.round(canvas.clientHeight * dpr));
    const scale = LADDER[level].scale;
    const rW = Math.max(1, Math.round(W * scale)), rH = Math.max(1, Math.round(H * scale));
    const t = cur.targets;
    if (t && canvas.width === W && canvas.height === H && t[0].w === rW && t[0].h === rH) return;
    canvas.width = W; canvas.height = H;
    if (out) finish();
    if (t) freeTargets(cur);
    cur.targets = [target(rW, rH), target(rW, rH)];
  }

  // Sets a layer's uniforms on program p (the layer's own, or a transition's)
  // for a W×H pass, with presentation0 = p0.
  function uniforms(layer, p, W, H, p0) {
    // the uniform writer is made once per layer and program
    let U = layer.locations.get(p);
    if (!U) {
      const loc = new Map();
      U = n => { if (!loc.has(n)) loc.set(n, gl.getUniformLocation(p, n)); return loc.get(n); };
      layer.locations.set(p, U);
    }
    const v = layer.visual, tm = layer.frame * DT, au = audio.values;
    gl.uniform2f(U('u.resolution'), W, H);
    gl.uniform1f(U('u.time'), tm);
    gl.uniform1f(U('u.dt'), layer.stride * DT);
    const t = tuning.get(v);
    gl.uniform1f(U('u.sensitivity'), t.sensitivity);
    gl.uniform1f(U('u.param0'), t.param0); gl.uniform1f(U('u.param1'), t.param1); gl.uniform1f(U('u.param2'), t.param2);
    gl.uniform1f(U('u.trailDecay'), overlay.reducedMotion ? 0 : t.trailDecay);
    gl.uniform4fv(U('u.accent'), t.accent);
    gl.uniform4fv(U('u.motion'), t.motion);
    gl.uniform4f(U('u.palette'), ...(vivid ? paletteTour(tm, v.palette[0]) : t.palette));
    gl.uniform4f(U('u.presentation0'), ...p0);
    gl.uniform4f(U('u.presentation1'), presentBlock[4], LADDER[level].reduce, 0, 0);
    gl.uniform4f(U('u.safeRect'), ...overlay.safeRect);
    for (const k of AUDIO_KEYS) gl.uniform1f(U('u.' + k), au[k]);
    gl.uniform4fv(U('u.spectrum[0]'), au.spectrum);
    gl.uniform1i(U('uImage'), 0);
    gl.uniform1i(U('uPrev'), 1);
  }

  function step(layer) {
    const [a, b] = layer.targets;
    gl.useProgram(layer.prog);
    bindQuad();
    uniforms(layer, layer.prog, a.w, a.h, VISUAL_P0);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, image);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, a.t);
    gl.bindFramebuffer(gl.FRAMEBUFFER, b.f);
    gl.viewport(0, 0, a.w, a.h);
    // a switch runs two visuals, so it is neither timed nor fed to the governor
    const timed = gpuQuery && !timing && !out;
    if (timed) gl.beginQuery(timer.TIME_ELAPSED_EXT, gpuQuery);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    if (timed) { gl.endQuery(timer.TIME_ELAPSED_EXT); timing = true; }
    layer.targets = [b, a];
    layer.frame += layer.stride;
  }

  // Runs the switch's transition from the outgoing frame (texture 0) to the
  // incoming one (texture 1) into the RGBA16F target dst, with the incoming
  // visual's uniforms and presentation0 = (p, seed, 0, 0).
  function blend(dst) {
    const src = out.targets[0];
    gl.useProgram(active);
    bindQuad();
    p0[0] = blendP; p0[1] = seed;
    uniforms(cur, active, dst.w, dst.h, p0);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, src.t);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, cur.targets[0].t);
    gl.bindFramebuffer(gl.FRAMEBUFFER, dst.f);
    gl.viewport(0, 0, dst.w, dst.h);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  // Runs the present pass into fbo (null for the canvas) at W×H: it maps the
  // transition's blend during a switch that has one, and otherwise dissolves
  // itself.
  function composite(p, fbo, W, H) {
    const t = blendP;
    const [a] = cur.targets;
    const blended = out && active && blendP > 0;
    if (blended) {
      if (!mix || mix.w !== a.w || mix.h !== a.h) {
        if (mix) freeTargets({ targets: [mix] });
        mix = target(a.w, a.h);
      }
      blend(mix);
    }
    gl.useProgram(p);
    bindQuad();
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, (blended ? mix : a).t);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, (out ?? cur).targets[0].t);
    presentBlock.set([vivid ? VIVID_SATURATION : 1, out && !blended ? t * t * (3 - 2 * t) : 1, fbo ? 0 : 1,
      vivid ? VIVID_VIBRANCE : 0]);
    presentBlock.set([0, 0, 0, 1, presentFrame++ % 16777216, 0, 0, 0], 84);
    gl.bindBuffer(gl.UNIFORM_BUFFER, ubo);
    gl.bufferSubData(gl.UNIFORM_BUFFER, 0, presentBlock);
    gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, ubo);
    if (p === presentCdg) {
      layerBlock[0] = W; layerBlock[1] = H;
      gl.bindBuffer(gl.UNIFORM_BUFFER, layerUbo);
      gl.bufferSubData(gl.UNIFORM_BUFFER, 0, layerBlock);
      gl.bindBufferBase(gl.UNIFORM_BUFFER, 1, layerUbo);
      gl.activeTexture(gl.TEXTURE3); gl.bindTexture(gl.TEXTURE_2D, cdg.texture);
    }
    if (fbo) {
      gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
      gl.viewport(0, 0, W, H);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      return;
    }
    if (!screen || screen.w !== W || screen.h !== H) screen = screenTargets(screen, W, H);
    const [next, prev] = screen.hist;
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, prev.t);
    gl.bindFramebuffer(gl.FRAMEBUFFER, next.f);
    gl.viewport(0, 0, W, H);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, next.f);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
    gl.blitFramebuffer(0, 0, W, H, 0, 0, W, H, gl.COLOR_BUFFER_BIT, gl.NEAREST);
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, null);
    screen.hist = [prev, next];
  }

  // Packs this frame's overlay block after present0: the canvas size, the
  // interval since the last presented frame and the tracked regions. A region
  // list the core would refuse is dropped, with a warning, rather than drawn.
  function packFrame(now) {
    const interval = lastPresent === null ? 1000 / 60 : Math.min(Math.max(now - lastPresent, 1e-3), 1000);
    lastPresent = now;
    const config = { ...DEFAULT_CONFIG, viewport_width: canvas.width, viewport_height: canvas.height,
      frame_interval_ms: interval, reduced_motion: overlay.reducedMotion };
    try {
      packOverlay(config, overlay.regions, presentBytes);
    } catch (e) {
      console.warn(`overlay: ${e.message}`);
      packOverlay(config, [], presentBytes);
    }
  }

  // The on-screen present targets at W×H: an RGBA8 colour and two feedback-format
  // history targets, each with a framebuffer that writes the colour and its
  // history. A new history starts empty (alpha 0), so nothing is damped
  // against a frame of another size.
  function screenTargets(old, W, H) {
    if (old) {
      gl.deleteTexture(old.color);
      for (const h of old.hist) { gl.deleteTexture(h.t); gl.deleteFramebuffer(h.f); }
    }
    const color = texture(gl.RGBA8, W, H, gl.RGBA, gl.UNSIGNED_BYTE);
    const hist = [0, 1].map(() => {
      const t = texture(feedback.internal, W, H, gl.RGBA, feedback.type);
      const f = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, f);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color, 0);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT1, gl.TEXTURE_2D, t, 0);
      gl.drawBuffers([gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1]);
      gl.clearBufferfv(gl.COLOR, 1, [0, 0, 0, 0]);
      return { t, f };
    });
    return { w: W, h: H, color, hist };
  }

  function presentProgram(v, source, layer = false) {
    const p = link(v, compile(gl.FRAGMENT_SHADER, source));
    gl.useProgram(p);
    gl.uniformBlockBinding(p, gl.getUniformBlockIndex(p, 'PresentBlock'), 0);
    gl.uniform1i(gl.getUniformLocation(p, 'uA'), 0);
    gl.uniform1i(gl.getUniformLocation(p, 'uB'), 1);
    gl.uniform1i(gl.getUniformLocation(p, 'uH'), 2);
    gl.uniform1i(gl.getUniformLocation(p, 'uBloom'), 4);
    if (layer) {
      gl.uniformBlockBinding(p, gl.getUniformBlockIndex(p, 'PresentLayerBlock'), 1);
      gl.uniform1i(gl.getUniformLocation(p, 'uL'), 3);
    }
    return p;
  }

  function draw(now) {
    packFrame(now);
    composite(cdg.loaded && presentCdg ? presentCdg : present, null, canvas.width, canvas.height);
    const r = trace?.restores.at(-1);
    if (r && r.restoredAt !== null && r.drawnAt === null) {
      r.drawnAt = performance.now();
      Object.assign(r, { drawnVisual: cur.visual.id, drawnFrame: cur.frame, drawnState: director.status.state, drawnP: blendP,
        drawnOut: out !== null });
    }
    const { frame, targets } = cur;
    // the status every ten draws: a text change each frame costs a layout
    if (draws++ % 10 !== 0 && frame !== stopAt) return;
    const ms = frameMs === null ? '–' : frameMs.toFixed(1);
    const gpu = gpuMs === null ? '' : ` (GPU ${gpuMs.toFixed(1)})`;
    $('status').textContent = `frame ${frame} · t ${(frame * DT).toFixed(2)} s · ${targets[0].w}×${targets[0].h}`
      + ` · quality ${governor.level}${pinned === null ? '' : ' (fixed)'} · ${ms} ms${gpu} · ${audio.status()}`
      + (feedback.label ? ` · ${feedback.label}` : '');
  }

  // The visual steps at 60 Hz at most, as on the Apple host: on a faster
  // display a tick that comes early is skipped rather than speeding it up, and
  // `due` keeps the remainder, so a 120 Hz display steps on every other tick.
  // A switch draws on every tick, so its progress follows presentation time.
  const STEP_MS = DT * 1000;
  let last = null, prevStep = null, due = 0;
  function tick(now) {
    requestAnimationFrame(tick);
    audio.tick(now);
    // the loss event follows the loss itself by a task
    if (lost || gl.isContextLost()) return;
    if (last !== null) {
      const gap = now - last;
      if (gap < 250) tickMs = tickMs === null ? gap : tickMs + 0.1 * (gap - tickMs);
      due = Math.min(due + now - last, 2 * STEP_MS);
      // presentation time stops while paused, and skips a long gap (a hidden page)
      if (!paused && cur && cur.frame < stopAt) clockMs += Math.min(now - last, 100);
    }
    last = now;
    const stepDue = prevStep === null || due >= STEP_MS - 1.5;
    if (!stepDue && !out) return;
    if (stepDue) {
      due = Math.max(due - STEP_MS, -STEP_MS);
      if (prevStep !== null) {
        const ms = now - prevStep;
        if (ms < 250) frameMs = frameMs === null ? ms : frameMs + 0.1 * (ms - frameMs);
        if (pinned === null && !timer) governor.record(ms);
      }
      prevStep = now;
    }
    if (timing && gl.getQueryParameter(gpuQuery, gl.QUERY_RESULT_AVAILABLE)) {
      timing = false;
      // a disjoint event (a clock change, say) makes the result meaningless,
      // and a query begun before a visual switch timed the old visual
      if (!gl.getParameter(timer.GPU_DISJOINT_EXT) && !staleGpu) {
        const ms = gl.getQueryParameter(gpuQuery, gl.QUERY_RESULT) / 1e6;
        if (!timedBoth) gpuMs = gpuMs === null ? ms : gpuMs + 0.1 * (ms - gpuMs);
        if (pinned === null) governor.record(ms);
      }
      staleGpu = false;
      timedBoth = false;
    }
    startPending();
    if (cur) {
      if (!out) level = governor.level;
      resize();
      const run = !paused && cur.frame < stopAt, t = clockMs / 1000;
      const both = out && gpuQuery && !timing && stepDue && run;
      if (both) gl.beginQuery(timer.TIME_ELAPSED_EXT, gpuQuery);
      if (run && stepDue) {
        audio.frame(now);
        // the beat clock per stepped frame, at the synthetic source's step
        if (trace) {
          const v = audio.values;
          trace.beats.push([audio.source.steps ?? null, v.beatCount + v.beatPhase, v.beat, v.locked, v.tempo]);
        }
        step(cur);
        if (out && out.stride && progress % out.stride === 0) step(out);
        if (out) progress++;
      }
      // the lyrics at the frame's media time, traced per stepped frame with the packs applied
      // and the write position; paused, the held time applies nothing, and a stream loaded
      // meanwhile shows at it
      if (cdg.loaded) {
        const applied = cdg.update(audio.mediaMs);
        if (trace && run && stepDue) {
          trace.cdg.push([audio.source.steps ?? null, audio.mediaMs, applied, cdg.cdg.packCount, audio.source.writeMs ?? null]);
        }
      }
      if (out && requestDue && (stepDue || !run)) requestSwitch(t);
      if (out && !requestDue) {
        blendP = director.frame(t);
        // pre-roll: until it shows, the incoming visual keeps up with
        // presentation time from the request, feedback included, so it has
        // run for the pre-roll at least when it first shows
        for (let n = 0; run && !shown && n < 4 && cur.frame * DT < t - director.status.requestSeconds; n++) step(cur);
      }
      draw(now);
      if (both) { gl.endQuery(timer.TIME_ELAPSED_EXT); timing = true; timedBoth = true; }
      if (out && !requestDue) {
        const s = trace?.switches.at(-1);
        if (s && !shown && blendP > 0) { s.shownSeconds = t; s.ownSecondsShown = cur.frame * DT; }
        if (blendP > 0) shown = true;
        if (s) {
          s.lastP = blendP;
          const v = audio.values;
          trace.frames.push([now, t, director.status.state, blendP, cur.frame, out.frame, switches,
            v.beatCount + v.beatPhase, v.barPhase, audio.source.steps ?? null]);
        }
        if (director.status.state === STATE_DONE) {
          if (s) s.doneSeconds = t;
          finish();
        }
      }
    }
  }

  function bindQuad() {
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  }

  const offset = d => select(listed[(listed.indexOf(pending ?? cur?.visual) + d + listed.length) % listed.length].id);
  pick.onchange = () => select(pick.value);
  // A filter change keeps the visual when it still matches, otherwise
  // switches to the first that does.
  collection.onchange = type.onchange = intensity.onchange = () => {
    filter();
    const v = pending ?? cur?.visual;
    if (listed.includes(v)) pick.value = v.id; else select(listed[0].id);
    const t = nextTransition();
    if (t) prepare(t, transitionKey(t.id));
  };
  $('prev').onclick = () => offset(-1);
  $('next').onclick = () => offset(1);
  $('pause').onclick = () => { paused = !paused; audio.setPaused(paused); $('pause').textContent = paused ? 'Play' : 'Pause'; };
  $('restart').onclick = restart;
  trans.onchange = () => {
    const url = new URL(location.href);
    if (trans.value === 'auto') url.searchParams.delete('transition'); else url.searchParams.set('transition', trans.value);
    history.replaceState(null, '', url);
    const t = nextTransition();
    if (t) prepare(t, transitionKey(t.id));
  };
  const colourLabel = () => { $('colour').textContent = vivid ? 'Vivid' : 'Manifest'; };
  colourLabel();
  $('colour').onclick = () => {
    vivid = !vivid;
    colourLabel();
    const url = new URL(location.href);
    if (vivid) url.searchParams.delete('colour'); else url.searchParams.set('colour', 'manifest');
    history.replaceState(null, '', url);
  };
  $('img').onchange = async e => {
    const file = e.target.files[0];
    if (!file) return;
    picture?.close();
    picture = await createImageBitmap(file);
    upload(image, picture);
  };
  // A new source drops the last song's lyrics unless its own come with it (`keep`).
  const audioSource = (open, name, keep = false) => open.then(() => { $('err').textContent = ''; if (!keep) cdg.clear(); })
    .catch(e => { $('err').textContent = `${name}: ${e.message || e}`; });
  $('audio').onchange = e => {
    const file = e.target.files[0];
    if (file) audioSource(audio.openFile(file), file.name);
    e.target.value = '';
  };
  // CD+G lyrics: a .cdg file, alone or dropped together with its song, or an MP3+G .zip
  // holding both (karaoke-zip.js), picked, dropped or given by ?cdg=<url> or ?karaoke=<url>.
  // A zip's lyrics replace the current ones only once its song has opened too.
  const openLyrics = (bytes, name) => bytes.then(async b => {
    if (!looksLikeZip(b)) { cdg.load(b, name); $('err').textContent = ''; return; }
    const k = await openKaraokeZip(b);
    await audio.openFile(new File([k.audio.bytes], k.audio.name));
    cdg.load(k.cdg.bytes, k.cdg.name);
    $('err').textContent = '';
  }).catch(e => { $('err').textContent = `${name}: ${e.message || e}`; });
  const isZip = f => /\.zip$/i.test(f.name) || /zip/.test(f.type);
  const readFile = f => isZip(f) && f.size > ZIP_LIMITS.archive
    ? Promise.reject(new Error(`archive is over ${ZIP_LIMITS.archive >> 20} MiB`)) : f.arrayBuffer();
  $('cdg').onchange = e => {
    const file = e.target.files[0];
    if (file) openLyrics(readFile(file), file.name);
    e.target.value = '';
  };
  addEventListener('dragover', e => e.preventDefault());
  addEventListener('drop', e => {
    e.preventDefault();
    const files = [...e.dataTransfer.files];
    const karaoke = files.find(isZip);
    if (karaoke) { openLyrics(readFile(karaoke), karaoke.name); return; }
    const lyrics = files.find(f => /\.cdg$/i.test(f.name));
    const song = files.find(f => f !== lyrics && f.type.startsWith('audio/'));
    if (lyrics) openLyrics(lyrics.arrayBuffer(), lyrics.name);
    if (song) audioSource(audio.openFile(song), song.name, !!lyrics);
  });
  for (const param of ['cdg', 'karaoke']) {
    const url = query.get(param);
    if (url === null) continue;
    openLyrics(fetch(url).then(r => {
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      if (+r.headers.get('content-length') > ZIP_LIMITS.archive) throw new Error(`over ${ZIP_LIMITS.archive >> 20} MiB`);
      return r.arrayBuffer();
    }), url);
  }
  $('mic').onclick = () => audioSource(audio.openMic(), 'microphone');
  $('synth').onclick = () => { audio.synthetic(); cdg.clear(); };
  addEventListener('keydown', e => {
    if (e.target !== document.body) return;
    if (e.key === 'ArrowRight') offset(1);
    else if (e.key === 'ArrowLeft') offset(-1);
    else if (e.key === ' ') { e.preventDefault(); $('pause').click(); }
  });

  select(query.get('visual'));
  requestAnimationFrame(tick);
}

// A Fisher-Yates shuffle with a fixed 32-bit LCG (Renderer.shuffled).
function shuffled(items) {
  const a = [...items];
  let s = 1;
  for (let i = a.length - 1; i > 0; i--) {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    const j = s % (i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function compile(type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src); gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}

function link(vs, fs) {
  const p = gl.createProgram();
  gl.attachShader(p, vs); gl.attachShader(p, fs);
  gl.linkProgram(p);
  gl.deleteShader(fs);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  return p;
}

function texture(internal, W, H, format, type) {
  const t = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texImage2D(gl.TEXTURE_2D, 0, internal, W, H, 0, format, type, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  return t;
}

function target(W, H) {
  const t = texture(feedback.internal, W, H, gl.RGBA, feedback.type);
  const f = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, f);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
  gl.clearColor(0, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  return { t, f, w: W, h: H };
}

// The feedback format: RGBA16F where the browser renders to it, with
// EXT_color_buffer_float or else EXT_color_buffer_half_float, otherwise RGBA8,
// which clamps the feedback to [0, 1] and quantises it to 8 bits. Each is
// tried on a 1x1 target, since an enabled extension does not promise a
// complete framebuffer. `label` names a mode other than the first for the
// status line.
function feedbackFormat() {
  const formats = [
    { ext: 'EXT_color_buffer_float', internal: gl.RGBA16F, type: gl.HALF_FLOAT, label: null },
    { ext: 'EXT_color_buffer_half_float', internal: gl.RGBA16F, type: gl.HALF_FLOAT, label: 'half-float feedback' },
  ];
  for (const f of formats) {
    if (!gl.getExtension(f.ext)) continue;
    const t = texture(f.internal, 1, 1, gl.RGBA, f.type);
    const fb = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
    const complete = gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.deleteFramebuffer(fb);
    gl.deleteTexture(t);
    if (complete) return f;
  }
  return { ext: null, internal: gl.RGBA8, type: gl.UNSIGNED_BYTE, label: '8-bit feedback' };
}

function upload(tex, bitmap) {
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
}

// The 64x64 gradient stand-in the render harnesses use for image input.
function standInImage(tex) {
  const px = new Uint8Array(64 * 64 * 4);
  for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) {
    const i = (y * 64 + x) * 4;
    px[i] = 40 + x * 2.5; px[i + 1] = 30 + y * 1.8; px[i + 2] = 120 + ((x + y) & 15) * 6; px[i + 3] = 255;
  }
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 64, 64, 0, gl.RGBA, gl.UNSIGNED_BYTE, px);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
}
