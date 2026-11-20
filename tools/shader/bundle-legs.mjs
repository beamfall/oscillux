// SPDX-License-Identifier: AGPL-3.0-only
// Emits one platform leg of a pinned checkout into OUT with a sha256 index:
//   msl          every manifest visual (.metal), present, bloom stages, limiter passes, switch,
//                and catalog.json
//   glsl300      every manifest visual (.web.frag) plus vertex.web.vert, present, bloom stages,
//                limiter passes and switch, as GLSL ES 3.00 (WebGL2 and GLES 3), and catalog.json
//   android-gles AndroidGlesShaders.kt: the GLES 3.00 visuals and their catalog fields as the
//                Kotlin contract 1.0.0 (android-gles-contract.mjs)
// catalog.json (catalog.mjs) lists every visual's catalog fields in catalogOrder.
// The visuals are the release set (manifest.mjs releaseSet): the catalog's, each overridden
// visual drawn by its rebuilt original (shaders/originals).
// usage: node bundle-legs.mjs <msl|glsl300|android-gles> <oscillux-checkout> <out-dir> <tag> <rev>
import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [leg, root, out, tag, rev] = process.argv.slice(2);
if (!['msl', 'glsl300', 'android-gles'].includes(leg) || !out || !/^[0-9a-f]{40}$/.test(rev ?? '')) {
  console.error('usage: bundle-legs.mjs <msl|glsl300|android-gles> <oscillux-checkout> <out-dir> <tag> <40-hex rev>');
  process.exit(64);
}
const T = p => import(pathToFileURL(join(root, 'tools/shader', p)).href);
const { assertShaderToolchain } = await T('glsl2msl.mjs');
const { loadReleaseSet } = await T('manifest.mjs');
const { emitManifest } = await T('emit.mjs');
const P = await T('present.mjs');
const L = await T('limiter.mjs');
const S = await T('switch.mjs');
const { catalogDocument } = await T('catalog.mjs');
const A = await T('android-gles-contract.mjs');
const files = new Map();
const m = loadReleaseSet(root);
if (leg === 'msl') {
  assertShaderToolchain();
  for (const [name, text] of emitManifest(m, { msl: true })) if (name.endsWith('.metal')) files.set(`visuals/${name}`, text);
  files.set('post/present.metal', P.presentMSL());
  for (const s of P.BLOOM_STAGES) files.set(`post/bloom-${s}.metal`, P.bloomMSL(s));
  for (const p of L.LIMITER_PASSES) files.set(`limiter/${p.name}.metal`, L.limiterMSL(p));
  files.set('switch/switch.metal', S.switchMSL());
} else if (leg === 'android-gles') {
  files.set(A.ANDROID_GLES_CONTRACT_PATH, A.renderAndroidGlesContract(A.androidGlesInputs(m, tag, rev)));
} else {
  for (const [name, text] of emitManifest(m)) if (name.endsWith('.web.frag') || name === 'vertex.web.vert') files.set(`visuals/${name}`, text);
  files.set('post/present.frag', P.presentGLSL300());
  for (const s of P.BLOOM_STAGES) files.set(`post/bloom-${s}.frag`, P.bloomGLSL300(s));
  for (const p of L.LIMITER_PASSES) files.set(`limiter/${p.name}.frag`, L.limiterGLSL300(p));
  files.set('switch/switch.frag', S.switchGLSL300());
}
if (leg !== 'android-gles') files.set('catalog.json', JSON.stringify(catalogDocument(m, tag, rev), null, 2) + '\n');
const index = { schemaVersion: 1, producer: 'oscillux', leg, release: tag, rev, license: 'AGPL-3.0-only',
  generator: `tools/shader/bundle-legs.mjs ${leg} at the pinned rev`, files: [] };
rmSync(out, { recursive: true, force: true });
for (const [name, text] of [...files].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
  const path = join(out, name); mkdirSync(join(path, '..'), { recursive: true }); writeFileSync(path, text);
  index.files.push({ path: name, sha256: createHash('sha256').update(text).digest('hex'), bytes: Buffer.byteLength(text) });
}
writeFileSync(join(out, 'index.json'), JSON.stringify(index, null, 2) + '\n');
console.log(`${leg}: ${index.files.length} files`);
