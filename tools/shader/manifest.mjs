// SPDX-License-Identifier: AGPL-3.0-only
// Load a visual-set manifest: the host's prelude and visuals, passed in as data.
//
// {
//   "prelude": "prelude.glsl",                  // relative to the manifest; or a
//                                               // list of paths, joined in order
//   "visuals": [{
//     "id": "pulse-rings",                      // [a-z0-9][a-z0-9-]*
//     "body": "visuals/pulse-rings.glsl",       // relative to the manifest
//     "targets": ["web", "vulkan", "msl", "hlsl"], // non-empty subset
//     "imageInput": false,                      // optional, default false
//     "header": "// Pulse rings",               // optional MSL/HLSL header comment
//     "palette": [-1, 0, 1.3, 0],               // optional render-harness inputs
//     "trailDecay": 0.82,
//     "post": {                                 // optional per-visual post tuning
//       "bloomStrength": 0.6, "bloomThreshold": 0.95,  // (POST_RANGES); absent:
//       "chroma": 0.003, "vignette": 0.45,      // POST_DEFAULTS, every effect off
//       "grain": 0.02
//     },
//     "params": [{                              // one per param uniform the body
//       "id": "rings",                          // reads (and no others): a host
//       "uniform": "param0",                    // control's data, with no UI
//       "label": "Rings",                       // policy (AGENTS.md invariant 1).
//       "labelKey": "visual.pulse-rings.rings", // Unread params pack 0.5.
//       "min": 0, "max": 1, "default": 0.5, "step": 0.01,
//       "curve": "linear", "group": "shape"
//     }],
//     "tunables": ["palette", "trailDecay"],    // the host-tunable uniforms the
//                                               // body reads, directly or through
//                                               // prelude functions
//     "overrides": false,                       // optional: in a host bundle, this
//                                               // visual replaces the one with its id
//                                               // in a later manifest
//     "name": "Pulse Rings",                    // optional catalog fields, passed through
//     "blurb": "Rings on the beat.",            // as data (the release legs' catalog.json):
//     "tier": "lite",                           // name, blurb, tier (GPU cost class),
//     "input": "amplitude + beat",              // input and the overlay and calm hints come
//     "overlay": true, "calm": false,           // together; input names "image" exactly
//     "imageCapable": false,                    // when imageInput is true
//     "unreadParamLabels": {"param2": "Glow"}   // optional, with the catalog fields: a
//                                               // label for each param uniform the body
//                                               // does not read, for hosts that list all
//                                               // three; every other one has a control
//   }],
//   "catalogOrder": ["pulse-rings"],            // optional: every visual id once, in the
//                                               // order a catalog lists them
//   "transitions": [{                           // optional: switch effects for
//     "id": "iris",                             // the hosts; the same id rule,
//     "body": "transitions/iris.glsl",          // targets and header as visuals
//     "targets": ["web", "vulkan", "msl", "hlsl"],
//     "header": "// Iris: ..."
//   }]
// }
// A transition body defines vec3 transition(vec2 uv, float p, VisualUniforms u)
// (wrap.mjs). Its shader entry point is named from transitionEntryId(id), so a
// transition id may equal a visual id.
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { createWrapper } from './wrap.mjs';
import { PARAM_UNIFORMS, TRAIL_DECAY_MAX } from './preset.mjs';

export { PARAM_UNIFORMS, TRAIL_DECAY_MAX };
export const TARGETS = ['web', 'vulkan', 'msl', 'hlsl'];
const VISUAL_KEYS = new Set(['id', 'body', 'targets', 'imageInput', 'header', 'palette', 'params', 'tunables', 'trailDecay', 'post', 'overrides',
  'name', 'blurb', 'tier', 'input', 'overlay', 'calm', 'imageCapable', 'unreadParamLabels', 'safety']);
// Catalog fields: descriptive data a host may show or select by. Oscillux applies no policy to
// them. CATALOG_KEYS come together or not at all; imageCapable is optional with them, and with
// them every param uniform has a label: its control's, else one from unreadParamLabels.
export const CATALOG_KEYS = Object.freeze(['name', 'blurb', 'tier', 'input', 'overlay', 'calm']);
export const CATALOG_TIERS = Object.freeze(['lite', 'standard', 'flagship']);
// A catalog visual's measured photosensitivity data (CORE-3417), required with the catalog fields:
// maxFlashHz, the most flashes a second the visual itself makes (half its large-area luma
// transitions in any one second, before the limiter); maxLuminanceDelta, the largest change in mean
// relative luminance of a WCAG field window within the limiter's coverage interval; textSafeZone,
// the band ('center' or 'upper', else 'none') dark and steady enough for overlaid text. The
// declared values bound the measured ones (limiter-red-audit.mjs --check-safety).
export const TEXT_SAFE_ZONES = Object.freeze(['none', 'center', 'upper']);
/** True when a catalog input names the image, which it must exactly when imageInput is true. */
export const inputIsImage = input => /\bimage\b/.test(input);
const CONTROL_KEYS = new Set(['id', 'uniform', 'label', 'labelKey', 'min', 'max', 'default', 'step', 'curve', 'group']);
export const PARAM_CURVES = ['linear'];
export const PARAM_GROUPS = ['shape', 'motion', 'color', 'detail', 'reaction'];
// Host values a preset may set (tools/shader/preset.mjs), in uniform order.
export const TUNABLES = ['sensitivity', 'trailDecay', 'accent', 'motion', 'palette'];
// Per-visual post tuning a host's post chain reads: bloom gain and its linear-light threshold,
// radial chromatic aberration (offset at the corners as a fraction of the distance to the
// centre), vignette strength and film-grain amplitude. Every key is required when `post` is
// present; a visual without it takes POST_DEFAULTS, which turn every effect off.
export const POST_RANGES = Object.freeze({
  bloomStrength: [0, 2],
  bloomThreshold: [0, 4],
  chroma: [0, 0.05],
  vignette: [0, 1],
  grain: [0, 0.25],
});
export const POST_KEYS = Object.freeze(Object.keys(POST_RANGES));
export const POST_DEFAULTS = Object.freeze({ bloomStrength: 0, bloomThreshold: 1, chroma: 0, vignette: 0, grain: 0 });
const TRANSITION_KEYS = new Set(['id', 'body', 'targets', 'header']);
const ID = /^[a-z0-9][a-z0-9-]*$/;

export const transitionEntryId = id => `transition-${id}`;

export function loadManifest(path) {
  const file = resolve(path);
  const dir = dirname(file);
  const doc = JSON.parse(readFileSync(file, 'utf8'));
  exactKeys(doc, new Set(['prelude', 'visuals', 'transitions', 'catalogOrder']), 'manifest', ['prelude', 'visuals']);
  const preludes = typeof doc.prelude === 'string' ? [doc.prelude] : doc.prelude;
  if (!Array.isArray(preludes) || preludes.length === 0 || !preludes.every(p => typeof p === 'string')) {
    fail('manifest.prelude', 'must be a path string or a non-empty list of them');
  }
  if (!Array.isArray(doc.visuals) || doc.visuals.length === 0) fail('manifest.visuals', 'must be a non-empty array');
  if (doc.transitions !== undefined && !Array.isArray(doc.transitions)) fail('manifest.transitions', 'must be an array');

  const prelude = preludes.map(p => readFileSync(resolve(dir, p), 'utf8')).join('\n');
  const seen = new Set();
  const visuals = doc.visuals.map((v, i) => {
    const at = `manifest.visuals[${i}]`;
    common(v, VISUAL_KEYS, at, seen);
    if (v.imageInput !== undefined && typeof v.imageInput !== 'boolean') fail(`${at}.imageInput`, 'must be a boolean');
    numbers(v.palette, 4, `${at}.palette`);
    if (v.palette !== undefined) {
      const [index, y, phase, w] = v.palette;
      if (!(Number.isInteger(index) && index >= -1 && index <= 31 && y === 0 && phase >= 0 && phase <= 32 && w === 0)) {
        fail(`${at}.palette`, 'must be [index, 0, phase, 0] with an integer index in [-1, 31] and phase in [0, 32]');
      }
    }
    if (v.trailDecay !== undefined && !(v.trailDecay >= 0 && v.trailDecay <= TRAIL_DECAY_MAX)) {
      fail(`${at}.trailDecay`, `must be a number in [0, ${TRAIL_DECAY_MAX}]`);
    }
    const post = postTuning(v.post, `${at}.post`);
    if (v.overrides !== undefined && typeof v.overrides !== 'boolean') fail(`${at}.overrides`, 'must be a boolean');
    const body = readFileSync(resolve(dir, v.body), 'utf8');
    const reads = uniformReads(prelude, body);
    const controls = paramControls(v.id, v.params ?? [], reads, `${at}.params`);
    const catalog = catalogFields(v, at, controls);
    const tunables = v.tunables ?? [];
    if (!Array.isArray(tunables) || tunables.some(t => !TUNABLES.includes(t)) || new Set(tunables).size !== tunables.length) {
      fail(`${at}.tunables`, `must be a list of distinct names from ${TUNABLES.join(', ')}`);
    }
    for (const t of TUNABLES) {
      if (reads.has(t) !== tunables.includes(t)) fail(`${at}.tunables`, `${t} is ${reads.has(t) ? 'read but not listed' : 'listed but not read'}`);
    }
    const params = [0.5, 0.5, 0.5];
    for (const c of controls) params[PARAM_UNIFORMS.indexOf(c.uniform)] = c.default;
    return Object.freeze({
      id: v.id,
      body,
      targets: Object.freeze([...v.targets]),
      imageInput: v.imageInput ?? false,
      header: v.header ?? '',
      palette: v.palette ?? [-1, 0, 1.3, 0],
      params,
      controls,
      tunables: Object.freeze(TUNABLES.filter(t => tunables.includes(t))),
      trailDecay: v.trailDecay ?? 0.82,
      post,
      overrides: v.overrides ?? false,
      catalog,
    });
  });
  const catalogOrder = order(doc.catalogOrder, visuals);

  const seenTransitions = new Set();
  const transitions = (doc.transitions ?? []).map((v, i) => {
    common(v, TRANSITION_KEYS, `manifest.transitions[${i}]`, seenTransitions);
    return Object.freeze({
      id: v.id,
      body: readFileSync(resolve(dir, v.body), 'utf8'),
      targets: Object.freeze([...v.targets]),
      header: v.header ?? '',
    });
  });

  const byTarget = Object.fromEntries(TARGETS.map(t => [t, visuals.filter(v => v.targets.includes(t))]));
  return { file, prelude, visuals, transitions, byTarget, byId: new Map(visuals.map(v => [v.id, v])), catalogOrder, wrapper: createWrapper({ prelude }) };
}

// Merge the visuals of several manifests, in order, into one list for a host
// bundle. Ids must be unique, except that a visual with `overrides` takes the
// place of the visual with its id in a later set. Throws on a duplicate id, on
// two overrides of one id and on an override that replaces nothing.
export function mergeVisualSets(sets) {
  const visuals = [];
  const pending = new Map();  // id -> overriding visual not yet placed
  for (const set of sets) {
    for (const v of set) {
      if (visuals.some(x => x.id === v.id) || (v.overrides && pending.has(v.id))) {
        throw new Error(`visual id "${v.id}" appears in more than one manifest`);
      } else if (pending.has(v.id)) {
        visuals.push(pending.get(v.id));
        pending.delete(v.id);
      } else if (v.overrides) {
        pending.set(v.id, v);
      } else {
        visuals.push(v);
      }
    }
  }
  if (pending.size) throw new Error(`nothing to override for ${[...pending.keys()].join(', ')}`);
  return visuals;
}

// The manifests the release legs ship: the catalog, and the rebuilt originals that override it.
export const RELEASE_CATALOG = 'shaders/manifest.json';
export const RELEASE_ORIGINALS = 'shaders/originals/manifest.json';

// The visual set the release legs ship, shaped like a loaded manifest. Every catalog visual is
// kept, in catalogOrder; one an original overrides takes the original's body, header, targets,
// render inputs (palette, params, controls, tunables, trailDecay, post) and the originals'
// prelude, and keeps its catalog fields, with each param label from the original's control
// where it has one. Each visual carries the `wrapper` its body is wrapped with. Originals that
// override nothing are not shipped: they have no catalog fields.
export function releaseSet(catalog, originals) {
  const visuals = catalog.visuals.map(c => {
    const o = originals.byId.get(c.id);
    if (!o?.overrides) return Object.freeze({ ...c, wrapper: catalog.wrapper });
    if (o.imageInput !== c.imageInput) throw new Error(`release set: ${c.id} imageInput differs from its catalog entry`);
    const paramLabels = PARAM_UNIFORMS.map((u, i) => o.controls.find(x => x.uniform === u)?.label ?? c.catalog.paramLabels[i]);
    return Object.freeze({ ...o, overrides: false, wrapper: originals.wrapper,
      catalog: Object.freeze({ ...c.catalog, paramLabels: Object.freeze(paramLabels) }) });
  });
  const missing = originals.visuals.filter(o => o.overrides && !catalog.byId.has(o.id)).map(o => o.id);
  if (missing.length) throw new Error(`release set: nothing to override for ${missing.join(', ')}`);
  const byTarget = Object.fromEntries(TARGETS.map(t => [t, visuals.filter(v => v.targets.includes(t))]));
  return { file: catalog.file, prelude: catalog.prelude, visuals, transitions: catalog.transitions, byTarget,
    byId: new Map(visuals.map(v => [v.id, v])), catalogOrder: catalog.catalogOrder, wrapper: catalog.wrapper };
}

/** releaseSet for an Oscillux checkout at root. */
export const loadReleaseSet = root => releaseSet(loadManifest(resolve(root, RELEASE_CATALOG)), loadManifest(resolve(root, RELEASE_ORIGINALS)));

// The id, body, targets and header rules visuals and transitions share.
function common(v, keys, at, seen) {
  exactKeys(v, keys, at, ['id', 'body', 'targets']);
  if (typeof v.id !== 'string' || !ID.test(v.id)) fail(`${at}.id`, `must match ${ID}`);
  if (seen.has(v.id)) fail(`${at}.id`, `duplicate id ${JSON.stringify(v.id)}`);
  seen.add(v.id);
  if (typeof v.body !== 'string') fail(`${at}.body`, 'must be a path string');
  if (!Array.isArray(v.targets) || v.targets.length === 0 ||
      v.targets.some(t => !TARGETS.includes(t)) || new Set(v.targets).size !== v.targets.length) {
    fail(`${at}.targets`, `must be a non-empty subset of ${TARGETS.join(', ')}`);
  }
  if (v.header !== undefined && !(typeof v.header === 'string' && /^(?:\/\/[^\n\r]*)?$/.test(v.header))) {
    fail(`${at}.header`, 'must be one // comment line or empty');
  }
}

// Param control metadata (one per param uniform the body reads), checked and frozen.
function paramControls(visualId, list, reads, at) {
  if (!Array.isArray(list)) fail(at, 'must be an array of param controls');
  const ids = new Set();
  const controls = list.map((c, i) => {
    const ct = `${at}[${i}]`;
    exactKeys(c, CONTROL_KEYS, ct, [...CONTROL_KEYS]);
    if (typeof c.id !== 'string' || !ID.test(c.id) || ids.has(c.id)) fail(`${ct}.id`, `must match ${ID} and be unique`);
    ids.add(c.id);
    if (!PARAM_UNIFORMS.includes(c.uniform)) fail(`${ct}.uniform`, `must be one of ${PARAM_UNIFORMS.join(', ')}`);
    if (typeof c.label !== 'string' || !/^\S(?:.{0,38}\S)?$/.test(c.label)) fail(`${ct}.label`, 'must be 1 to 40 characters, trimmed');
    if (c.labelKey !== `visual.${visualId}.${c.id}`) fail(`${ct}.labelKey`, 'must be visual.<visual id>.<control id>');
    for (const k of ['min', 'max', 'default', 'step']) if (!Number.isFinite(c[k])) fail(`${ct}.${k}`, 'must be a finite number');
    if (!(c.min >= 0 && c.min < c.max && c.max <= 1)) fail(`${ct}.max`, 'must satisfy 0 <= min < max <= 1');
    if (!(c.default >= c.min && c.default <= c.max)) fail(`${ct}.default`, 'must lie in [min, max]');
    if (!(c.step > 0 && c.step <= c.max - c.min)) fail(`${ct}.step`, 'must lie in (0, max - min]');
    if (!PARAM_CURVES.includes(c.curve)) fail(`${ct}.curve`, `must be one of ${PARAM_CURVES.join(', ')}`);
    if (!PARAM_GROUPS.includes(c.group)) fail(`${ct}.group`, `must be one of ${PARAM_GROUPS.join(', ')}`);
    return Object.freeze({ ...c });
  });
  for (const u of PARAM_UNIFORMS) {
    const n = controls.filter(c => c.uniform === u).length;
    if (n > 1) fail(at, `${u} has more than one control`);
    if (reads.has(u) && n === 0) fail(at, `${u} is read but has no control metadata`);
    if (!reads.has(u) && n === 1) fail(at, `${u} has a control but is not read`);
  }
  return Object.freeze(controls.sort((a, b) => PARAM_UNIFORMS.indexOf(a.uniform) - PARAM_UNIFORMS.indexOf(b.uniform)));
}

// The VisualUniforms members a body may read, found conservatively: member accesses on u, on
// any name declared VisualUniforms (a helper's argument, a copy) and on function-like macro
// parameters, in the body and in every prelude function and prelude or body #define (object- or
// function-like) whose name the body, or text reached from it, mentions. An over-read only asks
// for a control; a missed read would ship a param without one.
export function uniformReads(prelude, body) {
  const src = stripComments(prelude);
  const text0 = stripComments(body);
  const fns = topLevelFunctions(prelude);
  const defines = new Map();
  const names = new Set(['u']);
  for (const m of `${src}\n${text0}`.matchAll(/^[ \t]*#define[ \t]+(\w+)(?:\(([^)\n]*)\))?([^\n]*)$/gm)) {
    defines.set(m[1], (defines.get(m[1]) ?? '') + m[3]);
    for (const p of (m[2] ?? '').split(',')) if (p.trim()) names.add(p.trim());
  }
  for (const m of `${src}\n${text0}`.matchAll(/\bVisualUniforms\s+(\w+)/g)) names.add(m[1]);
  const member = new RegExp(`\\b(?:${[...names].join('|')})\\s*\\.\\s*([A-Za-z_]\\w*)`, 'g');
  const reads = new Set();
  const seen = new Set();
  const queue = [text0];
  while (queue.length) {
    const text = queue.pop();
    for (const m of text.matchAll(member)) reads.add(m[1]);
    for (const [w] of text.matchAll(/\b[A-Za-z_]\w*\b/g)) {
      if (seen.has(w) || !(fns.has(w) || defines.has(w))) continue;
      seen.add(w);
      queue.push(`${fns.get(w) ?? ''}\n${defines.get(w) ?? ''}`);
    }
  }
  return reads;
}

// Name -> the bodies of the top-level functions with that name (overloads joined).
function topLevelFunctions(src) {
  const text = stripComments(src);
  const fns = new Map();
  let depth = 0, start = 0, open = 0, name = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '{') {
      if (depth++ === 0) {
        name = /(\w+)\s*\([^()]*\)\s*$/.exec(text.slice(start, i))?.[1] ?? null;
        open = i;
      }
    } else if (c === '}' && --depth === 0) {
      if (name) fns.set(name, (fns.get(name) ?? '') + text.slice(open, i + 1));
      start = i + 1;
    } else if (c === ';' && depth === 0) {
      start = i + 1;
    }
  }
  return fns;
}

function stripComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, '');
}

// The catalog fields of a visual, checked and frozen, or null when it has none.
function catalogFields(v, at, controls) {
  const present = CATALOG_KEYS.filter(k => v[k] !== undefined);
  if (present.length === 0) {
    for (const k of ['imageCapable', 'unreadParamLabels', 'safety']) {
      if (v[k] !== undefined) fail(`${at}.${k}`, `needs the catalog fields ${CATALOG_KEYS.join(', ')}`);
    }
    return null;
  }
  for (const k of CATALOG_KEYS) if (v[k] === undefined) fail(`${at}.${k}`, `is required with ${present.join(', ')}`);
  for (const k of ['name', 'blurb', 'input']) {
    if (typeof v[k] !== 'string' || !/^\S(?:[^\n\r]*\S)?$/.test(v[k])) fail(`${at}.${k}`, 'must be a non-empty one-line string, trimmed');
  }
  if (!CATALOG_TIERS.includes(v.tier)) fail(`${at}.tier`, `must be one of ${CATALOG_TIERS.join(', ')}`);
  for (const k of ['overlay', 'calm', 'imageCapable']) {
    if (v[k] !== undefined && typeof v[k] !== 'boolean') fail(`${at}.${k}`, 'must be a boolean');
  }
  if (inputIsImage(v.input) !== (v.imageInput ?? false)) {
    fail(`${at}.input`, `${inputIsImage(v.input) ? 'names' : 'does not name'} the image, but imageInput is ${v.imageInput ?? false}`);
  }
  const unread = v.unreadParamLabels ?? {};
  exactKeys(unread, new Set(PARAM_UNIFORMS), `${at}.unreadParamLabels`, []);
  const paramLabels = PARAM_UNIFORMS.map(u => {
    const control = controls.find(c => c.uniform === u);
    if (control && u in unread) fail(`${at}.unreadParamLabels.${u}`, 'is read and has a control, which carries its label');
    if (!control && !(u in unread)) fail(`${at}.unreadParamLabels`, `${u} is not read and needs a label`);
    const label = control ? control.label : unread[u];
    if (typeof label !== 'string' || !/^\S(?:.{0,38}\S)?$/.test(label)) fail(`${at}.unreadParamLabels.${u}`, 'must be 1 to 40 characters, trimmed');
    return label;
  });
  return Object.freeze({ name: v.name, blurb: v.blurb, tier: v.tier, input: v.input, overlay: v.overlay, calm: v.calm,
    imageCapable: v.imageCapable ?? false, paramLabels: Object.freeze(paramLabels), safety: safetyFields(v.safety, `${at}.safety`) });
}

export function safetyFields(s, at) {
  if (s === undefined) fail(at, 'is required with the catalog fields');
  const keys = ['maxFlashHz', 'maxRedFlashHz', 'maxLuminanceDelta', 'textSafeZone'];
  exactKeys(s, new Set(keys), at, keys);
  for (const k of ['maxFlashHz', 'maxRedFlashHz']) {
    if (!(typeof s[k] === 'number' && s[k] >= 0 && s[k] <= 30)) fail(`${at}.${k}`, 'must be a number in [0, 30]');
  }
  if (!(typeof s.maxLuminanceDelta === 'number' && s.maxLuminanceDelta >= 0 && s.maxLuminanceDelta <= 1)) {
    fail(`${at}.maxLuminanceDelta`, 'must be a number in [0, 1]');
  }
  if (!TEXT_SAFE_ZONES.includes(s.textSafeZone)) fail(`${at}.textSafeZone`, `must be one of ${TEXT_SAFE_ZONES.join(', ')}`);
  return Object.freeze({ maxFlashHz: s.maxFlashHz, maxRedFlashHz: s.maxRedFlashHz, maxLuminanceDelta: s.maxLuminanceDelta, textSafeZone: s.textSafeZone });
}

// catalogOrder: every visual id exactly once. Absent, the manifest's own order.
function order(value, visuals) {
  const ids = visuals.map(v => v.id);
  if (value === undefined) return Object.freeze(ids);
  if (!Array.isArray(value) || value.length !== ids.length || new Set(value).size !== value.length ||
      !value.every(id => ids.includes(id))) {
    fail('manifest.catalogOrder', 'must list every visual id exactly once');
  }
  return Object.freeze([...value]);
}

function postTuning(value, at) {
  if (value === undefined) return POST_DEFAULTS;
  exactKeys(value, new Set(POST_KEYS), at, POST_KEYS);
  for (const k of POST_KEYS) {
    const [lo, hi] = POST_RANGES[k];
    if (!(Number.isFinite(value[k]) && value[k] >= lo && value[k] <= hi)) fail(`${at}.${k}`, `must be a number in [${lo}, ${hi}]`);
  }
  return Object.freeze(Object.fromEntries(POST_KEYS.map(k => [k, value[k]])));
}

function exactKeys(obj, allowed, at, required) {
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) fail(at, 'must be an object');
  for (const k of Object.keys(obj)) if (!allowed.has(k)) fail(`${at}.${k}`, 'unknown key');
  for (const k of required) if (!(k in obj)) fail(`${at}.${k}`, 'is required');
}

function numbers(value, length, at) {
  if (value === undefined) return;
  if (!Array.isArray(value) || value.length !== length || !value.every(Number.isFinite)) {
    fail(at, `must be ${length} finite numbers`);
  }
}

function fail(at, message) {
  throw new Error(`${at}: ${message}`);
}
