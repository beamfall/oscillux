// SPDX-License-Identifier: AGPL-3.0-only
// The one source for the VisualUniforms layout is
// conformance/packing/visual-uniforms.schema.json. From it this module derives
// the GLSL member declarations, the std140 offsets (equal to the Metal layout
// for the types allowed here) and the Packer field list, and renders the two
// generated files: the Rust field list and the packing vector.
// test-wrap.mjs checks both files and the wrapper's GLSL against the schema.
//
//   node tools/shader/uniforms.mjs --write   # regenerate both files
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const SCHEMA_PATH = join(ROOT, 'conformance', 'packing', 'visual-uniforms.schema.json');
export const VECTOR_PATH = join(ROOT, 'conformance', 'packing', 'visual-uniforms.json');
export const RUST_PATH = join(ROOT, 'crates', 'oscillux-core', 'src', 'packing', 'visual_uniforms.rs');

// [float components, base alignment in bytes]. std140 and Metal agree on these;
// vec3, matrices and arrays of anything but vec4, where they differ, are rejected.
const TYPES = { float: [1, 4], vec2: [2, 8], vec4: [4, 16] };
// [Packer source, number of values] (Mapped::values, Mapped::spectrum, host array).
const SOURCES = { scalar: [0, 9], spectrum: [1, 64], host: [2, Infinity] };
const KEYS = new Set(['name', 'type', 'count', 'source', 'index']);

export const loadSchema = (path = SCHEMA_PATH) => JSON.parse(readFileSync(path, 'utf8'));

// Members with std140 offsets and Packer fields, the block size and the host
// array length. Host values are assigned in declaration order.
export function layout(schema) {
  if (schema?.struct !== 'VisualUniforms' || !Array.isArray(schema.fields) || !schema.fields.length) {
    throw new Error('schema: must name struct VisualUniforms and list its fields');
  }
  for (const key of Object.keys(schema)) {
    if (key !== 'struct' && key !== 'fields') throw new Error(`schema: unknown key ${key}`);
  }
  const names = new Set();
  let offset = 0;
  let host = 0;
  const members = schema.fields.map((f, i) => {
    const fail = message => { throw new Error(`schema.fields[${i}]: ${message}`); };
    for (const key of Object.keys(f)) if (!KEYS.has(key)) fail(`unknown key ${key}`);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(f.name ?? '') || names.has(f.name)) fail('name must be a unique identifier');
    names.add(f.name);
    if (!Object.hasOwn(TYPES, f.type)) fail(`type must be one of ${Object.keys(TYPES).join(', ')}`);
    if (f.count !== undefined && (f.type !== 'vec4' || !Number.isInteger(f.count) || f.count < 1)) {
      fail('count must be a positive integer on a vec4');
    }
    if (!Object.hasOwn(SOURCES, f.source)) fail(`source must be one of ${Object.keys(SOURCES).join(', ')}`);
    const [components, align] = TYPES[f.type];
    const total = components * (f.count ?? 1);
    const [source, available] = SOURCES[f.source];
    let sourceOffset;
    if (f.source === 'host') {
      if (f.index !== undefined) fail('host values are assigned in order; index is not allowed');
      sourceOffset = host;
      host += total;
    } else {
      if (!Number.isInteger(f.index) || f.index < 0 || f.index + total > available) {
        fail(`index must place all ${total} values within the ${available} ${f.source} values`);
      }
      sourceOffset = f.index;
    }
    offset = Math.ceil(offset / align) * align;
    const member = {
      name: f.name,
      type: f.type,
      ...(f.count === undefined ? {} : { count: f.count }),
      offset,
      size: 4 * total,
      field: { source, source_offset: sourceOffset, components: total, offset, stride: 4 },
    };
    offset += member.size;
    return member;
  });
  // A std140 block rounds up to a multiple of 16; Metal's sizeof may be smaller for
  // an all-float struct, so the buffer is at least as large as either needs.
  return { members, blockSize: Math.ceil(offset / 16) * 16, hostValues: host };
}

// GLSL member declarations, e.g. ['vec2 resolution', ..., 'vec4 spectrum[16]'].
export const declarations = schema =>
  layout(schema).members.map(m => `${m.type} ${m.name}${m.count ? `[${m.count}]` : ''}`);

// The declarations inside `<opener> { ... }` in GLSL source, whitespace-normalised.
export function declared(source, opener) {
  const start = source.indexOf(`${opener} {`);
  if (start < 0) throw new Error(`no \`${opener} {\` in the source`);
  const end = source.indexOf('}', start);
  return source.slice(start + opener.length + 2, end).split(';')
    .map(d => d.trim().replace(/\s+/g, ' ')).filter(Boolean);
}

export function renderRust(schema) {
  const { members, blockSize, hostValues } = layout(schema);
  const hostLines = members.filter(m => m.field.source === 2).map(m => {
    const { source_offset: first, components } = m.field;
    const span = components === 1 ? `${first}` : `${first}..=${first + components - 1}`;
    return `//! - ${span}: \`${m.name}\``;
  });
  const fieldLines = members.map(({ name, field: f }) =>
    `    Field { source: ${f.source}, source_offset: ${f.source_offset}, components: ${f.components}, ` +
    `offset: ${f.offset}, stride: ${f.stride} }, // ${name}`);
  return `// SPDX-License-Identifier: AGPL-3.0-only
// Generated by tools/shader/uniforms.mjs from conformance/packing/visual-uniforms.schema.json.
// Do not edit; change the schema and run \`node tools/shader/uniforms.mjs --write\`.
//! Packer layout of the shader \`VisualUniforms\` block (std140, equal to the Metal layout).
//!
//! Mapped values and the mapped spectrum fill the audio members; the host array fills the rest:
${hostLines.join('\n')}

use super::Field;

/// Bytes in one packed block.
pub const BLOCK_SIZE: usize = ${blockSize};
/// Length of the host array these fields read.
pub const HOST_VALUES: usize = ${hostValues};
/// One field per member, in declaration order.
#[rustfmt::skip]
pub const FIELDS: [Field; ${members.length}] = [
${fieldLines.join('\n')}
];
`;
}

// Distinct, float32-exact inputs, packed with DataView independently of the Rust Packer.
export function renderVector(schema) {
  const { members, blockSize, hostValues } = layout(schema);
  const scalars = Array.from({ length: 9 }, (_, i) => (i + 1) / 8);
  const spectrum = Array.from({ length: 64 }, (_, i) => (i + 1) / 128);
  const host = Array.from({ length: hostValues }, (_, i) => 1000 + i);
  const values = [scalars, spectrum, host];
  const view = new DataView(new ArrayBuffer(blockSize));
  for (const { field: f } of members) {
    for (let i = 0; i < f.components; ++i) {
      view.setFloat32(f.offset + i * f.stride, values[f.source][f.source_offset + i], true);
    }
  }
  const doc = {
    generated_by: 'tools/shader/uniforms.mjs',
    schema: 'visual-uniforms.schema.json',
    block_size: blockSize,
    host_values: hostValues,
    members: members.map(({ field, ...m }) => m),
    fields: members.map(m => m.field),
    case: { scalars, spectrum, host, bytes: [...new Uint8Array(view.buffer)] },
  };
  return `${JSON.stringify(doc, null, 2)}\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv[2] !== '--write' || process.argv.length !== 3) {
    console.error('usage: node tools/shader/uniforms.mjs --write');
    process.exit(2);
  }
  const schema = loadSchema();
  writeFileSync(RUST_PATH, renderRust(schema));
  writeFileSync(VECTOR_PATH, renderVector(schema));
}
