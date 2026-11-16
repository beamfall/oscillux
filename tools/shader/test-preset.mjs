// SPDX-License-Identifier: AGPL-3.0-only
// Checks the preset schema (preset.mjs) against conformance/presets: the schema vectors, the
// adversarial set over every shipped visual, and the default preset of every shipped visual,
// which must resolve without clamping to the uniforms the reference hosts wrote before presets.
import { readFileSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { loadManifest } from './manifest.mjs';
import {
  defaultPreset, LEVEL_SOURCES, PARAM_UNIFORMS, PRESET_DEFAULTS, PRESET_MAX_BYTES, PRESET_RANGES, PRESET_UNIFORMS, presetMapping,
  presetUniforms, resolvePreset,
} from './preset.mjs';

const root = new URL('../../', import.meta.url);
const load = name => JSON.parse(readFileSync(new URL(`conformance/presets/${name}`, root)));
const failures = [];
const resolve = (c, catalog, sub = s => s) => resolvePreset(c.text !== undefined ? sub(c.text) : c.input, catalog);

const vectors = load('vectors.json');
const fixture = new Map(vectors.catalog.map(v => [v.id, v]));
for (const c of vectors.cases) {
  const r = resolve(c, fixture);
  const got = r.ok
    ? { uniforms: presetUniforms(r.preset, fixture.get(r.preset.visual)), mapping: presetMapping(r.preset), clamped: r.clamped, migratedFrom: r.migratedFrom }
    : { refuse: { path: r.error.path, code: r.error.code } };
  if (!isDeepStrictEqual(got, c.expect)) failures.push(`vectors ${c.kind} ${c.name}: got ${JSON.stringify(got)}`);
}
const big = `{"schemaVersion":1,"visual":"glow","params":{"glow":0.5${' '.repeat(PRESET_MAX_BYTES)}}}`;
if (resolvePreset(big, fixture).error?.code !== 'size') failures.push('vectors: text over PRESET_MAX_BYTES is not refused');
for (const n of [NaN, Infinity, -Infinity]) {
  if (resolvePreset({ schemaVersion: 1, visual: 'glow', accent: [0, n, 0, 0] }, fixture).error?.code !== 'non-finite') {
    failures.push(`vectors: accent value ${n} is not refused as non-finite`);
  }
}

const inRange = (n, [lo, hi]) => Number.isFinite(n) && n >= lo && n <= hi;
function bounded(u, m, v) {
  const bad = [];
  if (!isDeepStrictEqual(Object.keys(u), PRESET_UNIFORMS)) bad.push(`keys ${Object.keys(u)}`);
  if (!inRange(u.sensitivity, PRESET_RANGES.sensitivity)) bad.push('sensitivity');
  PARAM_UNIFORMS.forEach((name, i) => {
    const c = v.controls.find(x => x.uniform === name);
    if (c ? !inRange(u[name], [c.min, c.max]) : u[name] !== v.params[i]) bad.push(name);
  });
  for (const k of ['accent', 'motion']) u[k].forEach((n, i) => { if (!inRange(n, PRESET_RANGES[k][i])) bad.push(`${k}[${i}]`); });
  const [index, y, phase, w] = u.palette;
  if (!Number.isInteger(index) || !inRange(index, PRESET_RANGES.paletteIndex) || y !== 0 || w !== 0
    || !inRange(phase, PRESET_RANGES.palettePhase)) bad.push('palette');
  if (!inRange(u.trailDecay, PRESET_RANGES.trailDecay)) bad.push('trailDecay');
  if (!LEVEL_SOURCES.includes(m.levelSource) || !inRange(m.releaseSeconds, PRESET_RANGES.releaseSeconds)
    || !inRange(m.dbFloor, PRESET_RANGES.dbFloor) || Object.keys(m).length !== 3) bad.push('mapping');
  return bad;
}

const adversarial = load('adversarial.json').cases;
let visuals = 0, runs = 0;
for (const rel of ['shaders/manifest.json', 'shaders/originals/manifest.json', 'examples/shader/manifest.json']) {
  const { visuals: list, byId } = loadManifest(new URL(rel, root).pathname);
  for (const v of list) {
    visuals++;
    const def = resolvePreset(JSON.stringify(defaultPreset(v)), byId);
    const legacy = { sensitivity: 1, param0: v.params[0], param1: v.params[1], param2: v.params[2],
      accent: PRESET_DEFAULTS.accent, motion: [0, 0, 0, 0], palette: v.palette, trailDecay: v.trailDecay };
    if (!def.ok || def.clamped.length || !isDeepStrictEqual(presetUniforms(def.preset, v), legacy)) {
      failures.push(`${rel} ${v.id}: default preset does not resolve to the host uniforms: ${JSON.stringify(def)}`);
    }
    for (const c of adversarial) {
      runs++;
      let input = c.input && JSON.parse(JSON.stringify(c.input).replaceAll('$visual', v.id));
      if (input && '$params' in input) {
        const { $params: n, ...rest } = input;
        input = { ...rest, params: Object.fromEntries(v.controls.map(ctl => [ctl.id, n])) };
      }
      const r = resolve({ ...c, input }, byId, s => s.replaceAll('$visual', v.id));
      if (r.ok !== (c.expect === 'accept')) { failures.push(`${rel} ${v.id} ${c.name}: ${JSON.stringify(r.error ?? 'accepted')}`); continue; }
      if (!r.ok) continue;
      const bad = bounded(presetUniforms(r.preset, v), presetMapping(r.preset), v);
      if (bad.length) failures.push(`${rel} ${v.id} ${c.name}: out of bounds ${bad.join(', ')}`);
    }
  }
}
if ({}.safeRect !== undefined || {}.x !== undefined) failures.push('Object.prototype was polluted');

if (failures.length) { console.error(failures.join('\n')); process.exit(1); }
console.log(`test-preset: ${vectors.cases.length} vectors match; ${adversarial.length} adversarial presets over ${visuals} visuals (${runs} runs) stay in bounds; ${visuals} default presets resolve to the host uniforms`);
