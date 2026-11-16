// SPDX-License-Identifier: AGPL-3.0-only
// Visual presets: the versioned JSON a host saves for one visual's tuning, its validator and
// migration, and the uniforms it may set (docs/shader-toolchain.md, conformance/presets/).
//
//   { "schemaVersion": 1, "visual": "<id>", "params": { "<control id>": n, ... },
//     "sensitivity": n, "accent": [r, g, b, a], "motion": [angle, tx, ty, depth],
//     "palette": { "index": i, "phase": n }, "trailDecay": n,
//     "mapping": { "levelSource": "absolute" | "relative", "releaseSeconds": n, "dbFloor": n } }
//
// Only schemaVersion and visual are required; a missing field takes the visual's default.
// resolvePreset refuses unknown keys, wrong types, non-finite numbers, an unknown visual or
// param, a schemaVersion newer than PRESET_SCHEMA_VERSION and text over PRESET_MAX_BYTES, and
// clamps finite numbers into PRESET_RANGES (a param into its control's [min, max]), reporting
// each clamped path. Older versions migrate one step at a time (MIGRATIONS). presetUniforms
// returns only the tunable uniforms: the host writes resolution, time, the audio uniforms,
// presentation and safeRect itself, so a preset never reaches the flash limiter or the overlay
// contrast bounds. presetMapping returns the mapping settings the host applies: releaseSeconds
// and dbFloor through MappingConfig, levelSource through oscillux_mapping_set_level_source.
// No imports, so the browser host loads it as is.

export const PARAM_UNIFORMS = ['param0', 'param1', 'param2'];
// Upper bound of a visual's trail decay, in the manifest (manifest.mjs) and in presets.
export const TRAIL_DECAY_MAX = 0.96;
export const PRESET_SCHEMA_VERSION = 1;
export const PRESET_MAX_BYTES = 65536;
export const LEVEL_SOURCES = ['absolute', 'relative'];
export const PRESET_RANGES = Object.freeze({
  sensitivity: [0, 2],
  accent: [[0, 1], [0, 1], [0, 1], [0, 1]],
  motion: [[-Math.PI, Math.PI], [-0.25, 0.25], [-0.25, 0.25], [-0.25, 0.25]],
  paletteIndex: [-1, 31],
  palettePhase: [0, 32],
  trailDecay: [0, TRAIL_DECAY_MAX],
  releaseSeconds: [0.02, 2],
  dbFloor: [-96, -12],
});
export const PRESET_DEFAULTS = Object.freeze({
  sensitivity: 1,
  accent: [0.15, 0.9, 0.72, 1],
  motion: [0, 0, 0, 0],
  mapping: { levelSource: 'absolute', releaseSeconds: 0.2, dbFloor: -60 },
});
// The uniform names presetUniforms may return.
export const PRESET_UNIFORMS = ['sensitivity', ...PARAM_UNIFORMS, 'accent', 'motion', 'palette', 'trailDecay'];

const KEYS = ['schemaVersion', 'visual', 'params', 'sensitivity', 'accent', 'motion', 'palette', 'trailDecay', 'mapping'];
const MAPPING_KEYS = ['levelSource', 'releaseSeconds', 'dbFloor'];

// MIGRATIONS[n] turns a version-n document into version n + 1. Version 0 is the host bundle's
// positional form, { schemaVersion: 0, visual, params: [p0, p1, p2] }: each value moves to the
// control of that param uniform, and a value for a uniform the visual does not read is dropped.
const MIGRATIONS = [
  (doc, visual, at) => {
    exactKeys(doc, ['schemaVersion', 'visual', 'params'], at);
    const params = {};
    if (doc.params !== undefined) {
      if (!Array.isArray(doc.params) || doc.params.length !== 3) refuse(`${at}.params`, 'type', 'must be 3 numbers');
      doc.params.forEach((n, i) => {
        number(n, `${at}.params[${i}]`);
        const control = visual.controls.find(c => c.uniform === PARAM_UNIFORMS[i]);
        if (control) params[control.id] = n;
      });
    }
    return { schemaVersion: 1, visual: doc.visual, params };
  },
];

class PresetError extends Error {
  constructor(path, code, message) { super(`${path}: ${message}`); this.path = path; this.code = code; }
}
const refuse = (path, code, message) => { throw new PresetError(path, code, message); };

// catalog: a Map of visual id to loaded manifest visual (manifest.mjs byId) or bundle visual,
// each with controls and params. input: preset JSON text or a parsed value.
// Returns { ok: true, preset, clamped, migratedFrom } or { ok: false, error: { path, code, message } }.
export function resolvePreset(input, catalog) {
  try {
    let doc = input;
    if (typeof input === 'string') {
      if (new TextEncoder().encode(input).length > PRESET_MAX_BYTES) refuse('preset', 'size', `must be at most ${PRESET_MAX_BYTES} bytes`);
      try { doc = JSON.parse(input); } catch { refuse('preset', 'json', 'must be JSON'); }
    }
    if (!isObject(doc)) refuse('preset', 'type', 'must be an object');
    const version = doc.schemaVersion;
    if (!Number.isInteger(version) || version < 0) refuse('preset.schemaVersion', 'version', 'must be a non-negative integer');
    if (version > PRESET_SCHEMA_VERSION) refuse('preset.schemaVersion', 'version', `${version} is newer than ${PRESET_SCHEMA_VERSION}`);
    if (typeof doc.visual !== 'string') refuse('preset.visual', 'type', 'must be a visual id');
    const visual = catalog.get(doc.visual);
    if (!visual) refuse('preset.visual', 'unknown-visual', `no visual ${JSON.stringify(doc.visual)}`);
    for (let v = version; v < PRESET_SCHEMA_VERSION; v++) doc = MIGRATIONS[v](doc, visual, 'preset');
    const clamped = [];
    return { ok: true, preset: validate(doc, visual, clamped), clamped, migratedFrom: version < PRESET_SCHEMA_VERSION ? version : null };
  } catch (e) {
    if (!(e instanceof PresetError)) throw e;
    return { ok: false, error: { path: e.path, code: e.code, message: e.message } };
  }
}

// The complete version-1 preset holding the visual's defaults.
export function defaultPreset(visual) {
  return {
    schemaVersion: PRESET_SCHEMA_VERSION,
    visual: visual.id,
    params: Object.fromEntries(visual.controls.map(c => [c.id, c.default])),
    sensitivity: PRESET_DEFAULTS.sensitivity,
    accent: [...PRESET_DEFAULTS.accent],
    motion: [...PRESET_DEFAULTS.motion],
    palette: { index: visual.palette[0] < 0 ? -1 : visual.palette[0], phase: visual.palette[2] },
    trailDecay: visual.trailDecay,
    mapping: { ...PRESET_DEFAULTS.mapping },
  };
}

// The tunable uniforms of a resolved preset, as the host writes them: scalars as numbers and
// vec4s as 4-number arrays. Nothing else.
export function presetUniforms(preset, visual) {
  const params = [...visual.params];
  for (const c of visual.controls) params[PARAM_UNIFORMS.indexOf(c.uniform)] = preset.params[c.id];
  return {
    sensitivity: preset.sensitivity,
    param0: params[0], param1: params[1], param2: params[2],
    accent: [...preset.accent],
    motion: [...preset.motion],
    palette: [preset.palette.index, 0, preset.palette.phase, 0],
    trailDecay: preset.trailDecay,
  };
}

export const presetMapping = preset => ({ ...preset.mapping });

function validate(doc, visual, clamped) {
  exactKeys(doc, KEYS, 'preset');
  const base = defaultPreset(visual);
  const out = { ...base, params: { ...base.params } };
  if (doc.params !== undefined) {
    if (!isObject(doc.params)) refuse('preset.params', 'type', 'must be an object of control id to number');
    for (const [id, n] of Object.entries(doc.params)) {
      const c = visual.controls.find(x => x.id === id);
      if (!c) refuse(`preset.params.${id}`, 'unknown-param', `${visual.id} has no param ${JSON.stringify(id)}`);
      out.params[id] = clamp(number(n, `preset.params.${id}`), [c.min, c.max], `preset.params.${id}`, clamped);
    }
  }
  if (doc.sensitivity !== undefined) out.sensitivity = clamp(number(doc.sensitivity, 'preset.sensitivity'), PRESET_RANGES.sensitivity, 'preset.sensitivity', clamped);
  for (const k of ['accent', 'motion']) {
    if (doc[k] === undefined) continue;
    if (!Array.isArray(doc[k]) || doc[k].length !== 4) refuse(`preset.${k}`, 'type', 'must be 4 numbers');
    out[k] = doc[k].map((n, i) => clamp(number(n, `preset.${k}[${i}]`), PRESET_RANGES[k][i], `preset.${k}[${i}]`, clamped));
  }
  if (doc.palette !== undefined) {
    exactKeys(doc.palette, ['index', 'phase'], 'preset.palette');
    if (doc.palette.index !== undefined) {
      if (!Number.isInteger(number(doc.palette.index, 'preset.palette.index'))) refuse('preset.palette.index', 'type', 'must be an integer');
      out.palette.index = clamp(doc.palette.index, PRESET_RANGES.paletteIndex, 'preset.palette.index', clamped);
    }
    if (doc.palette.phase !== undefined) {
      out.palette.phase = clamp(number(doc.palette.phase, 'preset.palette.phase'), PRESET_RANGES.palettePhase, 'preset.palette.phase', clamped);
    }
  }
  if (doc.trailDecay !== undefined) out.trailDecay = clamp(number(doc.trailDecay, 'preset.trailDecay'), PRESET_RANGES.trailDecay, 'preset.trailDecay', clamped);
  if (doc.mapping !== undefined) {
    exactKeys(doc.mapping, MAPPING_KEYS, 'preset.mapping');
    const m = doc.mapping;
    if (m.levelSource !== undefined) {
      if (!LEVEL_SOURCES.includes(m.levelSource)) refuse('preset.mapping.levelSource', 'enum', `must be one of ${LEVEL_SOURCES.join(', ')}`);
      out.mapping.levelSource = m.levelSource;
    }
    for (const k of ['releaseSeconds', 'dbFloor']) {
      if (m[k] !== undefined) out.mapping[k] = clamp(number(m[k], `preset.mapping.${k}`), PRESET_RANGES[k], `preset.mapping.${k}`, clamped);
    }
  }
  return out;
}

function exactKeys(obj, keys, at) {
  if (!isObject(obj)) refuse(at, 'type', 'must be an object');
  for (const k of Object.keys(obj)) if (!keys.includes(k)) refuse(`${at}.${k}`, 'unknown-key', 'unknown key');
}

function number(n, at) {
  if (typeof n !== 'number') refuse(at, 'type', 'must be a number');
  if (!Number.isFinite(n)) refuse(at, 'non-finite', 'must be finite');
  return n;
}

function clamp(n, [lo, hi], at, clamped) {
  if (n >= lo && n <= hi) return n === 0 ? 0 : n;
  clamped.push(at);
  return n < lo ? lo : hi;
}

const isObject = v => v !== null && typeof v === 'object' && !Array.isArray(v);
