// SPDX-License-Identifier: AGPL-3.0-only
// Emit every platform shader a manifest declares.
//
//   node tools/shader/emit.mjs <manifest.json> [--out DIR] [--msl] [--hlsl]
//
// Per visual: <id>.web.frag (GLSL ES 3.00) for "web"; <id>.vulkan.frag
// (GLSL 450) for "vulkan"; <id>.msl.frag (the GLSL 450 fed to SPIR-V) and,
// with --msl, <id>.metal for "msl"; <id>.hlsl.frag (the GLSL 450 fed to
// SPIR-V) and, with --hlsl, <id>.hlsl (SM 5.0) for "hlsl". Plus
// vertex.web.vert when any visual targets web. Prints one "sha256  name" line
// per file, sorted by name.
import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { assertShaderToolchain } from './glsl2msl.mjs';
import { loadManifest } from './manifest.mjs';

export function emitManifest(manifest, { msl = false, hlsl = false } = {}) {
  const w = manifest.wrapper;
  const files = new Map();
  if (manifest.byTarget.web.length) files.set('vertex.web.vert', w.VERTEX_300);
  for (const v of manifest.visuals) {
    if (v.targets.includes('web')) files.set(`${v.id}.web.frag`, w.wrapGLSL300(v.body, v.imageInput));
    if (v.targets.includes('vulkan')) files.set(`${v.id}.vulkan.frag`, w.wrapGLSL450(v.body, v.imageInput));
    if (v.targets.includes('msl')) {
      files.set(`${v.id}.msl.frag`, w.wrapGLSL450MSL(v.body, v.imageInput));
      if (msl) files.set(`${v.id}.metal`, w.wrapMSL(v.id, v.body, v.header, v.imageInput));
    }
    if (v.targets.includes('hlsl')) {
      files.set(`${v.id}.hlsl.frag`, w.wrapGLSL450MSL(v.body, v.imageInput));
      if (hlsl) files.set(`${v.id}.hlsl`, w.wrapHLSL(v.id, v.body, v.header, v.imageInput));
    }
  }
  return new Map([...files].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
}

export const sha256 = text => createHash('sha256').update(text).digest('hex');

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { values: { out, msl, hlsl }, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      out: { type: 'string' },
      msl: { type: 'boolean', default: false },
      hlsl: { type: 'boolean', default: false },
    },
  });
  if (positionals.length !== 1) {
    console.error('usage: emit.mjs <manifest.json> [--out DIR] [--msl] [--hlsl]');
    process.exit(64);
  }
  if (msl || hlsl) {
    // Unpinned binaries still print digests; the header then names a version that was not
    // used, so writing goldens with --out needs the pinned toolchain.
    try { assertShaderToolchain(); }
    catch (e) {
      if (out) throw e;
      console.error(`warning: ${e.message.split('\n')[0]}`);
    }
  }
  const files = emitManifest(loadManifest(positionals[0]), { msl, hlsl });
  if (out) mkdirSync(out, { recursive: true });
  for (const [name, text] of files) {
    if (out) writeFileSync(join(out, name), text);
    console.log(`${sha256(text)}  ${name}`);
  }
}
