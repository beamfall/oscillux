// SPDX-License-Identifier: AGPL-3.0-only
// Validate a declarative pass list against conformance/passes/pass-list.schema.json
// and the rules JSON Schema cannot express. Oscillux defines and validates pass
// lists; host renderers execute them (docs/shader-toolchain.md, "Pass lists").
//
//   node tools/shader/passes.mjs <pass-list.json>... [--manifest manifest.json]
//
// With --manifest, every {"visual": id} must name a visual in that manifest.
// Exits 1 on the first invalid pass list.
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { loadManifest } from './manifest.mjs';
import { layout, loadSchema } from './uniforms.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const PASS_SCHEMA_PATH = join(ROOT, 'conformance', 'passes', 'pass-list.schema.json');
const RESERVED = new Set(['image', 'screen']);
const VISUAL_SLOTS = ['image', 'prev'];
const COMPONENTS = { float: 1, vec2: 2, vec4: 4 };

// ---------- JSON Schema subset (draft-07) ----------
// Enough for pass-list.schema.json. Unsupported keywords throw, so the schema
// cannot silently use a rule this interpreter would skip.
const ANNOTATIONS = new Set(['$schema', '$id', 'title', 'description', 'definitions', 'default']);
const KEYWORDS = new Set([...ANNOTATIONS, '$ref', 'type', 'const', 'enum', 'properties', 'required',
  'additionalProperties', 'propertyNames', 'items', 'minItems', 'maxItems', 'pattern',
  'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'oneOf']);

const typeOf = v => (v === null ? 'null' : Array.isArray(v) ? 'array'
  : Number.isInteger(v) ? 'integer' : typeof v);
const isType = (v, t) => t === typeOf(v) || (t === 'number' && typeOf(v) === 'integer');
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// Returns a list of "<path>: <message>" errors; empty when `value` is valid.
export function schemaErrors(schema, value, root = schema, at = '$') {
  for (const k of Object.keys(schema)) if (!KEYWORDS.has(k)) throw new Error(`unsupported schema keyword ${k} at ${at}`);
  if (schema.$ref !== undefined) {
    const m = /^#\/definitions\/([A-Za-z0-9_-]+)$/.exec(schema.$ref);
    if (!m || !root.definitions?.[m[1]]) throw new Error(`unresolvable $ref ${schema.$ref}`);
    return schemaErrors(root.definitions[m[1]], value, root, at);
  }
  const errors = [];
  const err = message => errors.push(`${at}: ${message}`);
  if (schema.type !== undefined && !isType(value, schema.type)) return [`${at}: must be ${schema.type}`];
  if ('const' in schema && !same(value, schema.const)) err(`must be ${JSON.stringify(schema.const)}`);
  if (schema.enum && !schema.enum.some(e => same(e, value))) err(`must be one of ${schema.enum.map(e => JSON.stringify(e)).join(', ')}`);
  if (typeof value === 'number') {
    if (schema.minimum !== undefined && !(value >= schema.minimum)) err(`must be >= ${schema.minimum}`);
    if (schema.maximum !== undefined && !(value <= schema.maximum)) err(`must be <= ${schema.maximum}`);
    if (schema.exclusiveMinimum !== undefined && !(value > schema.exclusiveMinimum)) err(`must be > ${schema.exclusiveMinimum}`);
    if (schema.exclusiveMaximum !== undefined && !(value < schema.exclusiveMaximum)) err(`must be < ${schema.exclusiveMaximum}`);
  }
  if (typeof value === 'string' && schema.pattern !== undefined && !new RegExp(schema.pattern, 'u').test(value)) {
    err(`must match ${schema.pattern}`);
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) err(`must have at least ${schema.minItems} items`);
    if (schema.maxItems !== undefined && value.length > schema.maxItems) err(`must have at most ${schema.maxItems} items`);
    if (schema.items) value.forEach((v, i) => errors.push(...schemaErrors(schema.items, v, root, `${at}[${i}]`)));
  }
  if (typeOf(value) === 'object') {
    for (const k of schema.required ?? []) if (!Object.hasOwn(value, k)) err(`${k} is required`);
    for (const [k, v] of Object.entries(value)) {
      const where = `${at}.${k}`;
      if (schema.propertyNames) errors.push(...schemaErrors(schema.propertyNames, k, root, `${where} (name)`));
      if (schema.properties && Object.hasOwn(schema.properties, k)) {
        errors.push(...schemaErrors(schema.properties[k], v, root, where));
      } else if (schema.additionalProperties === false) {
        errors.push(`${where}: unknown key`);
      } else if (typeof schema.additionalProperties === 'object') {
        errors.push(...schemaErrors(schema.additionalProperties, v, root, where));
      }
    }
  }
  if (schema.oneOf) {
    const matches = schema.oneOf.filter(s => schemaErrors(s, value, root, at).length === 0).length;
    if (matches !== 1) err(`must match exactly one of ${schema.oneOf.length} alternatives (matched ${matches})`);
  }
  return errors;
}

// The uniform schema's fields (name, type, count, source), after layout() has
// checked the schema.
function uniformFields() {
  const schema = loadSchema();
  layout(schema);
  return schema.fields;
}

// ---------- Pass-list rules beyond the schema ----------
// Returns the same list of errors; `visualIds` (a Set) enables the manifest check.
export function passListErrors(list, { schema = JSON.parse(readFileSync(PASS_SCHEMA_PATH, 'utf8')),
  uniforms = uniformFields(), visualIds } = {}) {
  const errors = schemaErrors(schema, list);
  if (errors.length) return errors;
  const err = (at, message) => errors.push(`${at}: ${message}`);

  const targets = new Map();
  list.targets.forEach((t, i) => {
    if (RESERVED.has(t.id)) err(`$.targets[${i}].id`, `${JSON.stringify(t.id)} is reserved`);
    else if (targets.has(t.id)) err(`$.targets[${i}].id`, `duplicate target ${JSON.stringify(t.id)}`);
    else targets.set(t.id, t);
  });
  const members = new Map(uniforms.map(m => [m.name, m]));
  const written = new Set();
  const read = new Set();
  const passIds = new Set();
  let screen = false;

  list.passes.forEach((p, i) => {
    const at = `$.passes[${i}]`;
    if (passIds.has(p.id)) err(`${at}.id`, `duplicate pass ${JSON.stringify(p.id)}`);
    passIds.add(p.id);

    if (p.output === 'screen') screen = true;
    else if (!targets.has(p.output)) err(`${at}.output`, `unknown target ${JSON.stringify(p.output)}`);

    if (p.shader.visual !== undefined) {
      if (visualIds && !visualIds.has(p.shader.visual)) err(`${at}.shader.visual`, `${JSON.stringify(p.shader.visual)} is not in the manifest`);
      const slots = Object.keys(p.inputs).sort();
      if (!same(slots, VISUAL_SLOTS)) err(`${at}.inputs`, `a visual pass binds exactly the slots ${VISUAL_SLOTS.join(' and ')}`);
    }

    for (const [slot, ref] of Object.entries(p.inputs)) {
      const where = `${at}.inputs.${slot}`;
      if (ref === 'image') continue;
      const previous = ref.endsWith('.previous');
      const id = previous ? ref.slice(0, -'.previous'.length) : ref;
      const t = targets.get(id);
      if (!t) { err(where, `unknown target ${JSON.stringify(id)}`); continue; }
      read.add(id);
      if (previous) {
        if (!t.feedback) err(where, `${JSON.stringify(id)} is not a feedback target, so it has no .previous`);
      } else if (id === p.output) {
        err(where, `a pass cannot read the target it writes; read ${JSON.stringify(`${id}.previous`)} from a feedback target instead`);
      } else if (!written.has(id)) {
        err(where, `${JSON.stringify(id)} is read before any pass writes it this frame`);
      }
    }

    for (const [name, value] of Object.entries(p.uniforms ?? {})) {
      const where = `${at}.uniforms.${name}`;
      const m = members.get(name);
      if (!m) { err(where, 'is not a VisualUniforms member'); continue; }
      if (m.count) { err(where, 'array members cannot be set per pass'); continue; }
      if (m.source !== 'host') { err(where, `is filled from audio analysis (${m.source}), not by the host`); continue; }
      const n = COMPONENTS[m.type];
      const ok = n === 1 ? typeof value === 'number' : Array.isArray(value) && value.length === n;
      if (!ok) err(where, `${m.type} needs ${n === 1 ? 'a number' : `${n} numbers`}`);
    }

    if (p.output !== 'screen') written.add(p.output);
  });

  for (const id of targets.keys()) {
    if (!written.has(id)) err('$.targets', `${JSON.stringify(id)} is never written`);
    else if (!read.has(id)) err('$.targets', `${JSON.stringify(id)} is never read`);
  }
  if (!screen) err('$.passes', 'no pass writes "screen"');
  return errors;
}

export function loadPassList(path, options) {
  const list = JSON.parse(readFileSync(path, 'utf8'));
  const errors = passListErrors(list, options);
  if (errors.length) throw new Error(`${path}:\n  ${errors.join('\n  ')}`);
  return list;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: { manifest: { type: 'string' } } });
  if (!positionals.length) {
    console.error('usage: passes.mjs <pass-list.json>... [--manifest manifest.json]');
    process.exit(64);
  }
  try {
    const visualIds = values.manifest ? new Set(loadManifest(values.manifest).byId.keys()) : undefined;
    for (const path of positionals) {
      const list = loadPassList(path, { visualIds });
      console.log(`${path}: ok (${list.targets.length} targets, ${list.passes.length} passes)`);
    }
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
