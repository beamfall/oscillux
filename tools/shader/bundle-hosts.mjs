// SPDX-License-Identifier: AGPL-3.0-only
// Bundle one or more manifests for the reference hosts (hosts/web, hosts/apple).
//
//   node tools/shader/bundle-hosts.mjs <manifest.json>... [--out out/hosts]
//                                      [--categories hosts/categories.json]
//                                      [--collections hosts/collections.json]
//
// Each manifest is wrapped with its own prelude, in the order given, and ids
// must be unique across them, except that a visual marked "overrides" takes
// the place of the visual with its id in a later manifest. Writes DIR/visuals.json: the shared vertex
// shader plus, per visual that
// targets both "web" and "msl", its GLSL ES 3.00 fragment, its Metal source and
// entry point, the render inputs (palette, params, trailDecay, post, imageInput) and
// the tuning metadata (controls, tunables; docs/shader-toolchain.md). loadManifest
// refuses a visual whose read params have no control metadata.
// Both hosts read this one file, so they draw the same shaders with the same
// inputs. The Metal leg needs the pinned toolchain (glsl2msl.mjs).
// The manifests' transitions that target "web" and "msl" go into
// `transitions`, with their GLSL ES 3.00 and Metal sources; their ids must be
// unique across the manifests. `present` is the shared present pass (present.mjs) for
// both hosts, and `presentCdg` the same pass with the CD+G lyric layer (cdg-layer.mjs).
// Every visual gets its `type` and `intensity` from the categories file
// (categories.mjs), and `types` and `intensities` carry their ordered labels.
// `collections` carries the curated visual collections (collections.mjs); every
// visual and transition id they list must be bundled.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { CATEGORIES_PATH, categorize, loadCategories } from './categories.mjs';
import { COLLECTIONS_PATH, checkCollections, loadCollections } from './collections.mjs';
import { assertShaderToolchain, mslEntryPoint } from './glsl2msl.mjs';
import { loadManifest, mergeVisualSets, transitionEntryId } from './manifest.mjs';
import { cdgPresentLayer } from './cdg-layer.mjs';
import { PRESENT_FUNCTION, presentGLSL300, presentMSL } from './present.mjs';
import { VERTEX_300 } from './wrap.mjs';

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    out: { type: 'string', default: 'out/hosts' },
    categories: { type: 'string', default: CATEGORIES_PATH },
    collections: { type: 'string', default: COLLECTIONS_PATH },
  },
});
if (positionals.length === 0) {
  console.error('usage: bundle-hosts.mjs <manifest.json>... [--out DIR] [--categories FILE] [--collections FILE]');
  process.exit(64);
}
assertShaderToolchain();
const manifests = positionals.map(path => loadManifest(path));
const sets = manifests.map(manifest => {
  const w = manifest.wrapper;
  return manifest.visuals
    .filter(v => v.targets.includes('web') && v.targets.includes('msl'))
    .map(v => ({
      id: v.id,
      title: v.header.replace(/^\/\/\s*/, '') || v.id,
      imageInput: v.imageInput,
      palette: v.palette,
      params: v.params,
      controls: v.controls,
      tunables: v.tunables,
      trailDecay: v.trailDecay,
      post: v.post,
      web: w.wrapGLSL300(v.body, v.imageInput),
      metal: w.wrapMSL(v.id, v.body, v.header, v.imageInput),
      metalFunction: mslEntryPoint(v.id),
      overrides: v.overrides,
    }));
});
let visuals, categories, collections;
try {
  visuals = mergeVisualSets(sets);
  categories = loadCategories(opts.categories);
  categorize(visuals, categories);
  collections = loadCollections(opts.collections);
} catch (e) {
  console.error(`bundle-hosts: ${e.message}`);
  process.exit(1);
}
for (const v of visuals) delete v.overrides;
const transitions = manifests.flatMap(m => m.transitions
  .filter(t => t.targets.includes('web') && t.targets.includes('msl'))
  .map(t => ({
    id: t.id,
    title: t.header.replace(/^\/\/\s*/, '') || t.id,
    web: m.wrapper.wrapGLSL300(t.body, false, true),
    metal: m.wrapper.wrapMSL(transitionEntryId(t.id), t.body, t.header, false, true),
    metalFunction: mslEntryPoint(transitionEntryId(t.id)),
  })));
const dup = transitions.find((t, i) => transitions.findIndex(x => x.id === t.id) !== i);
if (dup) {
  console.error(`bundle-hosts: transition id "${dup.id}" appears in more than one manifest`);
  process.exit(1);
}
try {
  checkCollections(collections, visuals, transitions);
} catch (e) {
  console.error(`bundle-hosts: ${e.message}`);
  process.exit(1);
}
const out = resolve(opts.out);
mkdirSync(out, { recursive: true });
const present = { web: presentGLSL300(), metal: presentMSL(), metalFunction: PRESENT_FUNCTION };
const layer = cdgPresentLayer();
const presentCdg = { web: presentGLSL300({ layer }), metal: presentMSL({ layer }), metalFunction: PRESENT_FUNCTION };
writeFileSync(join(out, 'visuals.json'),
  JSON.stringify({
    vertex: VERTEX_300, visuals, types: categories.types, intensities: categories.intensities,
    collections, transitions, present, presentCdg,
  }) + '\n');
console.log(`${visuals.length} visuals and ${transitions.length} transitions bundled to ${join(out, 'visuals.json')}`);
