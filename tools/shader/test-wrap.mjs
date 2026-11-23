// SPDX-License-Identifier: AGPL-3.0-only
// Pure-node checks for the shader wrapper and manifest loader: the example
// visual set must emit byte-identically to conformance/shader/examples, and
// malformed preludes and manifests must be rejected. The wrapper, the example
// prelude, the generated Packer field list and the packing vector must all
// agree with conformance/packing/visual-uniforms.schema.json. Also covers the
// provisioner's trust-boundary checkout arguments, the HLSL validator wiring and
// checkHlslABI against the HLSL goldens (`<id>.hlsl`). Those need SPIRV-Cross, so
// this test only checks their ABI; `make shader-verify` checks their bytes.
// Also checks that hosts/categories.json covers the default host bundle.
//
//   node tools/shader/test-wrap.mjs            # check
//   node tools/shader/test-wrap.mjs --update   # rewrite the goldens, then check
//                                              # (keeps the .hlsl goldens)
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { CATEGORIES_PATH, categorize, loadCategories } from './categories.mjs';
import { checkCollections, loadCollections } from './collections.mjs';
import { emitManifest } from './emit.mjs';
import { FORBIDDEN, LOCALLY_OWNED, importVisuals } from './import-visuals.mjs';
import { checkHlslABI, hlslValidator, mslEntryPoint, validateHLSL } from './glsl2msl.mjs';
import { loadManifest, loadReleaseSet, mergeVisualSets, PARAM_UNIFORMS, POST_DEFAULTS, POST_KEYS, POST_RANGES, RELEASE_CATALOG, RELEASE_ORIGINALS, releaseSet, transitionEntryId } from './manifest.mjs';
import { assertTrustBoundary } from './provision.mjs';
import {
  RUST_PATH, VECTOR_PATH, declarations, declared, layout, loadSchema, renderRust, renderVector,
} from './uniforms.mjs';
import { createWrapper } from './wrap.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const EXAMPLE = join(ROOT, 'examples', 'shader', 'manifest.json');
const GOLDEN = join(ROOT, 'conformance', 'shader', 'examples');
const CATALOG = join(ROOT, 'shaders', 'manifest.json');
const ORIGINALS = join(ROOT, 'shaders', 'originals', 'manifest.json');

const isHlsl = name => name.endsWith('.hlsl');

if (process.argv.includes('--update')) {
  mkdirSync(GOLDEN, { recursive: true });
  for (const name of readdirSync(GOLDEN)) if (!isHlsl(name)) rmSync(join(GOLDEN, name), { recursive: true, force: true });
  for (const [name, text] of emitManifest(loadManifest(EXAMPLE))) writeFileSync(join(GOLDEN, name), text);
}

test('example set emits byte-identically to the goldens', () => {
  const files = emitManifest(loadManifest(EXAMPLE));
  assert.deepEqual([...files.keys()], readdirSync(GOLDEN).filter(name => !isHlsl(name)).sort());
  for (const [name, text] of files) {
    assert.equal(text, readFileSync(join(GOLDEN, name), 'utf8'), `${name} differs from its golden`);
  }
});

test('450 targets declare VisualUniforms once, after the uniform block', () => {
  const m = loadManifest(EXAMPLE);
  for (const v of m.visuals) {
    for (const src of [m.wrapper.wrapGLSL450(v.body, v.imageInput), m.wrapper.wrapGLSL450MSL(v.body, v.imageInput)]) {
      assert.equal(src.match(/\bstruct VisualUniforms \{/g).length, 1);
      assert.ok(src.indexOf('} ub;') < src.indexOf('struct VisualUniforms {'));
    }
  }
});

test('generated uniform files match the schema', () => {
  const schema = loadSchema();
  assert.equal(readFileSync(RUST_PATH, 'utf8'), renderRust(schema),
    'packing/visual_uniforms.rs is stale; run node tools/shader/uniforms.mjs --write');
  assert.equal(readFileSync(VECTOR_PATH, 'utf8'), renderVector(schema),
    'conformance/packing/visual-uniforms.json is stale; run node tools/shader/uniforms.mjs --write');
});

test('every emitted VisualUniforms declaration and copy matches the schema', () => {
  const want = declarations(loadSchema());
  const m = loadManifest(EXAMPLE);
  for (const v of m.visuals) {
    assert.deepEqual(declared(m.wrapper.wrapGLSL300(v.body, v.imageInput), 'struct VisualUniforms'), want,
      `${v.id}: the prelude's VisualUniforms differs from the schema`);
    for (const src of [m.wrapper.wrapGLSL450(v.body, v.imageInput), m.wrapper.wrapGLSL450MSL(v.body, v.imageInput)]) {
      assert.deepEqual(declared(src, 'uniform VisualUniformBlock'), want,
        `${v.id}: wrap.mjs VisualUniformBlock differs from the schema`);
      assert.deepEqual(declared(src, 'struct VisualUniforms'), want,
        `${v.id}: wrap.mjs VisualUniforms differs from the schema`);
      const load = src.slice(src.indexOf('VisualUniforms loadUniforms() {'), src.indexOf('return u;'));
      // Arrays are copied in a loop whose bound must equal the declared count.
      const copied = [...load.matchAll(/(?:for \(int i = 0; i < (\d+); \+\+i\) )?u\.(\w+)(\[i\])? = ub\.\2\3;/g)]
        .map(c => (c[3] ? `${c[2]}[${c[1]}]` : c[2]));
      assert.deepEqual(copied.sort(), want.map(d => d.split(' ')[1]).sort(),
        `${v.id}: loadUniforms() does not copy each schema member once`);
    }
  }
});

// A re-import must not bring the upstream library (and its third-party hashes) back over the
// locally owned one, and the controls must be read against the local library.
test('import-visuals leaves the locally owned library alone', () => {
  const dir = mkdtempSync(join(tmpdir(), 'import-visuals-'));
  try {
    const src = join(dir, 'src');
    const out = join(dir, 'out');
    for (const d of [join(src, 'catalog.parts'), join(src, 'shared'), join(src, 'visuals'), out]) mkdirSync(d, { recursive: true });
    writeFileSync(join(src, 'catalog.json'), JSON.stringify({ visuals: [{
      id: 'probe', name: 'Probe', blurb: 'A probe.', tier: 'lite', input: 'amplitude', overlay: true, calm: false,
      palette: { index: 1, phase: 0 },
      params: [0, 1, 2, 3].map(i => ({ label: `P${i}`, def: 0.5 })),
      postFX: { bloomStrength: 0.6, bloomThreshold: 0.95, trailDecay: 0.8, chroma: 0.003, vignette: 0.45, grain: 0.02 },
    }] }));
    writeFileSync(join(src, 'shared', 'visual_shared.glsl'), '// upstream\nfloat upstreamOnly(float p) { return p; }\n');
    writeFileSync(join(src, 'visuals', 'probe.glsl'), '// Probe\nvec3 visual(vec2 uv) { return vec3(localGlow()); }\n');
    writeFileSync(join(out, 'library.glsl'), '// local\nfloat localGlow() { return u.param0; }\n');
    const files = importVisuals(src, out);
    assert.deepEqual([...LOCALLY_OWNED], ['library.glsl']);
    assert.deepEqual([...files.keys()].sort(), ['manifest.json', 'visuals/probe.glsl']);
    const manifest = JSON.parse(files.get('manifest.json'));
    const [probe] = manifest.visuals;
    assert.deepEqual(probe.params.map(p => p.uniform), ['param0'], 'controls read against the local library');
    assert.deepEqual([probe.name, probe.blurb, probe.tier, probe.input, probe.overlay, probe.calm, probe.imageCapable],
      ['Probe', 'A probe.', 'lite', 'amplitude', true, false, undefined]);
    assert.deepEqual(probe.unreadParamLabels, { param1: 'P1', param2: 'P2' });
    assert.deepEqual(manifest.catalogOrder, ['probe']);
    assert.deepEqual([probe.trailDecay, probe.post],
      [0.8, { bloomStrength: 0.6, bloomThreshold: 0.95, chroma: 0.003, vignette: 0.45, grain: 0.02 }]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// The reference catalog (shaders/, from import-visuals.mjs) wraps for every
// target without compilers; shader-verify and shader-render compile and render it.
test('reference catalog wraps for every target and stays host data', () => {
  const m = loadManifest(CATALOG);
  const want = declarations(loadSchema());
  assert.equal(m.visuals.length, 62);
  const sources = ['library.glsl', ...JSON.parse(readFileSync(CATALOG, 'utf8')).visuals.map(v => v.body)]
    .map(name => [name, readFileSync(join(ROOT, 'shaders', name), 'utf8')]);
  for (const [name, text] of sources) {
    assert.ok(text.startsWith('// SPDX-License-Identifier: AGPL-3.0-only\n'), `${name}: SPDX header`);
    assert.doesNotMatch(text, FORBIDDEN, `${name}: product or tier name`);
  }
  for (const v of m.visuals) {
    assert.deepEqual(v.targets, ['web', 'vulkan', 'msl', 'hlsl'], `${v.id}: targets`);
    assert.doesNotMatch(v.header, FORBIDDEN, `${v.id}: header`);
    assert.deepEqual(declared(m.wrapper.wrapGLSL300(v.body, v.imageInput), 'struct VisualUniforms'), want, v.id);
    assert.deepEqual(declared(m.wrapper.wrapGLSL450MSL(v.body, v.imageInput), 'uniform VisualUniformBlock'), want, v.id);
  }
  assert.equal(emitManifest(m).size, 1 + 62 * 4);
  // Every reference visual carries its own post tuning (in range: loadManifest checks it).
  const raw = JSON.parse(readFileSync(CATALOG, 'utf8'));
  for (const v of raw.visuals) assert.deepEqual(Object.keys(v.post ?? {}), POST_KEYS, `${v.id}: post`);
  // Every reference visual carries the catalog fields the release legs' catalog.json lists.
  for (const v of m.visuals) assert.ok(v.catalog, `${v.id}: catalog fields`);
  assert.equal(raw.catalogOrder.length, 62);
});

// The Oscillux originals (shaders/originals/) share the catalog's library and
// are held to the same rules. An original that reuses a catalog id must say it
// overrides it, and one that does not must not.
test('originals wrap for every target, stay host data and override only catalog ids', () => {
  const m = loadManifest(ORIGINALS);
  const want = declarations(loadSchema());
  assert.ok(m.visuals.length >= 4);
  const catalogIds = new Set(loadManifest(CATALOG).visuals.map(v => v.id));
  for (const v of m.visuals) {
    const text = readFileSync(join(ROOT, 'shaders', 'originals', 'visuals', `${v.id}.glsl`), 'utf8');
    assert.ok(text.startsWith('// SPDX-License-Identifier: AGPL-3.0-only\n'), `${v.id}: SPDX header`);
    assert.doesNotMatch(text, FORBIDDEN, `${v.id}: product or tier name`);
    assert.doesNotMatch(v.header, FORBIDDEN, `${v.id}: header`);
    assert.equal(v.overrides, catalogIds.has(v.id), `${v.id}: overrides must match a catalog id`);
    assert.deepEqual(v.targets, ['web', 'vulkan', 'msl', 'hlsl'], `${v.id}: targets`);
    assert.deepEqual(declared(m.wrapper.wrapGLSL300(v.body, v.imageInput), 'struct VisualUniforms'), want, v.id);
    assert.deepEqual(declared(m.wrapper.wrapGLSL450MSL(v.body, v.imageInput), 'uniform VisualUniformBlock'), want, v.id);
  }
  assert.equal(emitManifest(m).size, 1 + m.visuals.length * 4);
});

// Transitions blend the outgoing frame (texture 0, FROM) into the incoming one
// (texture 1, TO) and reuse the visual binding ABI, with no feedback trail.
test('transitions wrap for every target, stay host data and keep the visual ABI', () => {
  const m = loadManifest(ORIGINALS);
  const want = declarations(loadSchema());
  assert.ok(m.transitions.length >= 1);
  for (const t of m.transitions) {
    const text = readFileSync(join(ROOT, 'shaders', 'originals', 'transitions', `${t.id}.glsl`), 'utf8');
    assert.ok(text.startsWith('// SPDX-License-Identifier: AGPL-3.0-only\n'), `${t.id}: SPDX header`);
    assert.doesNotMatch(text, FORBIDDEN, `${t.id}: product or tier name`);
    assert.doesNotMatch(t.header, FORBIDDEN, `${t.id}: header`);
    assert.deepEqual(t.targets, ['web', 'vulkan', 'msl', 'hlsl'], `${t.id}: targets`);
    for (const src of [m.wrapper.wrapGLSL300(t.body, false, true), m.wrapper.wrapGLSL450MSL(t.body, false, true)]) {
      assert.match(src, /#define FROM\(x\) IMG\(x\)\.rgb/, t.id);
      assert.match(src, /#define TO\(x\) PREV\(x\)\.rgb/, t.id);
      assert.match(src, /sanitizeColor\(transition\(vUV, clamp\(u\.presentation0\.x, 0\.0, 1\.0\), u\)\)/, t.id);
      assert.doesNotMatch(src, /visual\(vUV, u\)/, t.id);
    }
    assert.deepEqual(declared(m.wrapper.wrapGLSL300(t.body, false, true), 'struct VisualUniforms'), want, t.id);
    assert.deepEqual(declared(m.wrapper.wrapGLSL450MSL(t.body, false, true), 'uniform VisualUniformBlock'), want, t.id);
    const msl = m.wrapper.wrapMSL(transitionEntryId(t.id), t.body, t.header, false, true);
    assert.ok(msl.includes(mslEntryPoint(transitionEntryId(t.id))), `${t.id}: MSL entry point`);
  }
});

test('host bundles merge manifests and place overrides in catalog order', () => {
  const v = (id, overrides = false) => ({ id, overrides });
  const ids = sets => mergeVisualSets(sets).map(x => `${x.id}${x.overrides ? '*' : ''}`);
  assert.deepEqual(ids([[v('new'), v('b', true)], [v('a'), v('b'), v('c')]]), ['new', 'a', 'b*', 'c']);
  assert.throws(() => mergeVisualSets([[v('a')], [v('a')]]), /more than one manifest/);
  assert.throws(() => mergeVisualSets([[v('a', true)], [v('a', true)], [v('a')]]), /more than one manifest/);
  assert.throws(() => mergeVisualSets([[v('a', true)], [v('b')]]), /nothing to override for a/);
});

// The release legs ship the catalog with each overridden visual drawn by its rebuilt original
// (CORE-2760), keeping the catalog's fields and order.
test('the release set draws overrides from the originals and keeps the catalog fields', () => {
  const catalog = loadManifest(join(ROOT, RELEASE_CATALOG));
  const originals = loadManifest(join(ROOT, RELEASE_ORIGINALS));
  const set = releaseSet(catalog, originals);
  assert.deepEqual(loadReleaseSet(ROOT).visuals.map(v => v.body), set.visuals.map(v => v.body));
  assert.deepEqual(set.catalogOrder, catalog.catalogOrder);
  assert.deepEqual(set.visuals.map(v => v.id), catalog.visuals.map(v => v.id));
  const overridden = originals.visuals.filter(o => o.overrides);
  assert.ok(overridden.length > 0);
  for (const o of overridden) {
    const v = set.byId.get(o.id), c = catalog.byId.get(o.id);
    assert.equal(v.body, o.body, o.id);
    assert.equal(v.wrapper, originals.wrapper, o.id);
    for (const k of ['palette', 'params', 'controls', 'trailDecay', 'post']) assert.deepEqual(v[k], o[k], `${o.id} ${k}`);
    for (const k of ['name', 'blurb', 'tier', 'input', 'overlay', 'calm', 'imageCapable']) assert.equal(v.catalog[k], c.catalog[k], `${o.id} ${k}`);
    for (const ctl of o.controls) assert.equal(v.catalog.paramLabels[PARAM_UNIFORMS.indexOf(ctl.uniform)], ctl.label);
  }
  const rest = set.visuals.filter(v => !originals.byId.get(v.id)?.overrides);
  for (const v of rest) assert.equal(v.body, catalog.byId.get(v.id).body);
  const ev = emitManifest(set).get('event-horizon.web.frag');
  assert.equal(ev, originals.wrapper.wrapGLSL300(originals.byId.get('event-horizon').body, false));
  assert.throws(() => releaseSet(catalog, { ...originals, visuals: [{ id: 'nope', overrides: true }] }), /nothing to override for nope/);
});

// The reference hosts filter their picker by type and intensity, so every
// visual the default host bundle carries needs exactly one of each.
test('the host categories cover exactly the default host bundle', () => {
  const sets = ['shaders/originals/manifest.json', 'shaders/manifest.json']
    .map(p => loadManifest(join(ROOT, p)).visuals.filter(v => v.targets.includes('web') && v.targets.includes('msl')));
  const visuals = mergeVisualSets(sets).map(v => ({ id: v.id }));
  const categories = loadCategories(join(ROOT, CATEGORIES_PATH));
  categorize(visuals, categories);
  for (const key of ['types', 'intensities']) {
    const ids = categories[key].map(e => e.id);
    assert.equal(new Set(ids).size, ids.length, `${key} ids are unique`);
  }
  const one = { types: [{ id: 't', label: 'T' }], intensities: [{ id: 'i', label: 'I' }] };
  assert.throws(() => categorize([{ id: 'a' }], { ...one, visuals: {} }), /"a" has no category/);
  assert.throws(() => categorize([], { ...one, visuals: { gone: ['t', 'i'] } }), /not bundled: gone/);
  assert.throws(() => categorize([{ id: 'a' }], { ...one, visuals: { a: ['x', 'i'] } }), /unknown type "x"/);
  assert.throws(() => categorize([{ id: 'a' }], { ...one, visuals: { a: ['t', 'x'] } }), /unknown intensity "x"/);
});

test('host collections name only bundled visuals and transitions, once each', () => {
  const sets = ['shaders/originals/manifest.json', 'shaders/manifest.json'].map(path =>
    JSON.parse(readFileSync(join(ROOT, path), 'utf8')).visuals.map(v => ({ id: v.id, overrides: v.overrides })));
  const bundled = mergeVisualSets(sets);
  const transitions = ['shaders/originals/manifest.json', 'shaders/manifest.json'].flatMap(path =>
    JSON.parse(readFileSync(join(ROOT, path), 'utf8')).transitions ?? []);
  const collections = checkCollections(loadCollections(join(ROOT, 'hosts/collections.json')), bundled, transitions);
  assert.ok(collections.length >= 1);
  const c = (id, visuals, labelKey = `collection.${id}`) => ({ id, label: id, labelKey, visuals });
  const vis = [{ id: 'a' }, { id: 'b' }];
  assert.throws(() => checkCollections([c('x', ['a', 'z'])], vis), /not bundled: z/);
  assert.throws(() => checkCollections([c('x', ['a', 'b', 'a'])], vis), /lists "a" more than once/);
  assert.throws(() => checkCollections([c('x', ['a']), c('x', ['b'])], vis), /listed more than once/);
  assert.throws(() => checkCollections([c('x', ['a'], 'visual.x')], vis), /labelKey must be collection.x/);
  const tr = [{ id: 'fade' }, { id: 'smoke' }];
  assert.doesNotThrow(() => checkCollections([{ ...c('x', ['a']), transitions: ['fade', 'smoke'] }], vis, tr));
  assert.throws(() => checkCollections([{ ...c('x', ['a']), transitions: ['fade', 'burn'] }], vis, tr), /transitions that are not bundled: burn/);
  assert.throws(() => checkCollections([{ ...c('x', ['a']), transitions: ['fade', 'fade'] }], vis, tr), /transition "fade" more than once/);
});

// Offsets worked out by hand from the std140 rules, so a wrong rule in
// uniforms.mjs cannot regenerate the Rust list and vector consistently and pass.
test('std140 offsets match hand-computed values', () => {
  const f = (name, type, extra = {}) => ({ name, type, source: 'host', ...extra });
  const synthetic = layout({ struct: 'VisualUniforms', fields: [
    f('a', 'float'), f('b', 'vec2'), f('c', 'float'), f('d', 'vec4'), f('e', 'vec4', { count: 2 }), f('g', 'float'),
  ] });
  assert.deepEqual(synthetic.members.map(m => [m.name, m.offset, m.size]),
    [['a', 0, 4], ['b', 8, 8], ['c', 16, 4], ['d', 32, 16], ['e', 48, 32], ['g', 80, 4]]);
  assert.equal(synthetic.blockSize, 96);
  const real = layout(loadSchema());
  const at = Object.fromEntries(real.members.map(m => [m.name, m.offset]));
  assert.deepEqual([at.resolution, at.time, at.trailDecay, at.barPhase, at.downbeat, at.accent, at.safeRect, at.spectrum],
    [0, 8, 80, 84, 88, 96, 176, 192]);
  assert.equal(real.blockSize, 448);
});

test('uniform schemas the layout rules cannot express are rejected', () => {
  const field = { name: 'time', type: 'float', source: 'host' };
  const cases = [
    [[{ ...field, type: 'vec3' }], /fields\[0\]: type must be one of/],
    [[{ ...field, count: 4 }], /fields\[0\]: count must be a positive integer on a vec4/],
    [[field, field], /fields\[1\]: name must be a unique identifier/],
    [[{ ...field, source: 'scalar', index: 9 }], /fields\[0\]: index must place/],
    [[{ ...field, type: 'vec4', count: 17, source: 'spectrum', index: 0 }], /fields\[0\]: index must place/],
    [[{ ...field, index: 0 }], /fields\[0\]: host values are assigned in order/],
    [[{ ...field, offset: 0 }], /fields\[0\]: unknown key offset/],
  ];
  for (const [fields, error] of cases) {
    assert.throws(() => layout({ struct: 'VisualUniforms', fields }), error);
  }
  assert.throws(() => layout({ struct: 'VisualUniforms', fields: [field], layout: 'std430' }), /schema: unknown key layout/);
});

test('the finishing grade follows imageInput', () => {
  const { wrapGLSL300 } = createWrapper({ prelude: 'struct VisualUniforms { float time; };\n' });
  const body = 'vec3 visual(vec2 uv, VisualUniforms u) { return vec3(uv, 0.0); }';
  assert.match(wrapGLSL300(body, false), /fragColor = vec4\(suppressGreenCast\(visual/);
  assert.match(wrapGLSL300(body, true), /fragColor = vec4\(sanitizeColor\(visual/);
});

test('a prelude without the VisualUniforms struct is rejected', () => {
  for (const prelude of ['', 'mat2 rot2(float a);', 'struct VisualUniforms { float time; }', undefined]) {
    assert.throws(() => createWrapper({ prelude }), /prelude must define/);
  }
});

test('malformed manifests are rejected with a path to the fault', () => {
  const dir = mkdtempSync(join(tmpdir(), 'oscillux-manifest-'));
  try {
    writeFileSync(join(dir, 'prelude.glsl'), 'struct VisualUniforms { float time; };\n');
    writeFileSync(join(dir, 'a.glsl'), 'vec3 visual(vec2 uv, VisualUniforms u) { return vec3(0.0); }\n');
    // p.glsl reads param0 directly and accent through a prelude helper.
    writeFileSync(join(dir, 'prelude.glsl'), 'struct VisualUniforms { float time; };\nvec3 tint(VisualUniforms u) { return u.accent.rgb; }\n');
    writeFileSync(join(dir, 'p.glsl'), 'vec3 visual(vec2 uv, VisualUniforms u) { return tint(u) * u.param0; }\n');
    // q.glsl reads motion through a function-like macro and a helper's VisualUniforms argument.
    writeFileSync(join(dir, 'q.glsl'), '#define SPIN(v) v.motion.x\nfloat spin(VisualUniforms w) { return SPIN(w); }\n'
      + 'vec3 visual(vec2 uv, VisualUniforms u) { return vec3(spin(u)); }\n');
    const visual = { id: 'a', body: 'a.glsl', targets: ['web'] };
    const control = { id: 'glow', uniform: 'param0', label: 'Glow', labelKey: 'visual.a.glow', min: 0, max: 0.8, default: 0.5,
      step: 0.01, curve: 'linear', group: 'color' };
    const post = { bloomStrength: 0.6, bloomThreshold: 0.95, chroma: 0.003, vignette: 0.45, grain: 0.02 };
    const cat = { name: 'A', blurb: 'A visual.', tier: 'lite', input: 'amplitude', overlay: false, calm: true };
    const unread = { param0: 'One', param1: 'Two', param2: 'Three' };
    const listed = { ...visual, ...cat, unreadParamLabels: unread };
    const one = v => ({ prelude: 'prelude.glsl', visuals: [v] });
    const cases = [
      [{ prelude: 'prelude.glsl', visuals: [] }, /manifest\.visuals: must be a non-empty array/],
      [{ prelude: 'prelude.glsl', visuals: [visual], catalog: {} }, /manifest\.catalog: unknown key/],
      [{ prelude: 'prelude.glsl', visuals: [visual, visual] }, /visuals\[1\]\.id: duplicate id/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, id: 'Bad_Id' }] }, /visuals\[0\]\.id: must match/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, targets: ['gles'] }] }, /visuals\[0\]\.targets/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, targets: ['web', 'web'] }] }, /visuals\[0\]\.targets/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, palette: [0, 0, 0] }] }, /visuals\[0\]\.palette: must be 4 finite numbers/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, palette: [0.5, 0, 0, 0] }] }, /visuals\[0\]\.palette: must be \[index, 0, phase, 0\]/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, palette: [0, 1, 0, 0] }] }, /visuals\[0\]\.palette: must be \[index, 0, phase, 0\]/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, palette: [32, 0, 0, 0] }] }, /visuals\[0\]\.palette: must be \[index, 0, phase, 0\]/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, title: 'x' }] }, /visuals\[0\]\.title: unknown key/],
      // Catalog fields: all six or none, well formed, input agreeing with imageInput, and a label
      // for every param uniform; catalogOrder lists every visual once.
      [one({ ...visual, name: 'A' }), /visuals\[0\]\.blurb: is required with name/],
      [one({ ...visual, imageCapable: true }), /visuals\[0\]\.imageCapable: needs the catalog fields/],
      [one({ ...visual, unreadParamLabels: unread }), /visuals\[0\]\.unreadParamLabels: needs the catalog fields/],
      [one({ ...listed, name: ' A' }), /visuals\[0\]\.name: must be a non-empty one-line string/],
      [one({ ...listed, blurb: 'two\nlines' }), /visuals\[0\]\.blurb: must be a non-empty one-line string/],
      [one({ ...listed, tier: 'photos' }), /visuals\[0\]\.tier: must be one of lite, standard, flagship/],
      [one({ ...listed, overlay: 'yes' }), /visuals\[0\]\.overlay: must be a boolean/],
      [one({ ...listed, imageCapable: 1 }), /visuals\[0\]\.imageCapable: must be a boolean/],
      [one({ ...listed, input: 'image + beat' }), /visuals\[0\]\.input: names the image, but imageInput is false/],
      [one({ ...listed, imageInput: true }), /visuals\[0\]\.input: does not name the image, but imageInput is true/],
      [one({ ...listed, unreadParamLabels: { param0: 'One', param1: 'Two' } }), /visuals\[0\]\.unreadParamLabels: param2 is not read and needs a label/],
      [one({ ...listed, unreadParamLabels: { ...unread, param3: 'Four' } }), /visuals\[0\]\.unreadParamLabels\.param3: unknown key/],
      [one({ ...listed, unreadParamLabels: { ...unread, param1: ' Two' } }), /visuals\[0\]\.unreadParamLabels\.param1: must be 1 to 40/],
      [one({ ...listed, body: 'p.glsl', params: [control], tunables: ['accent'] }),
        /visuals\[0\]\.unreadParamLabels\.param0: is read and has a control/],
      [{ ...one(visual), catalogOrder: [] }, /manifest\.catalogOrder: must list every visual id exactly once/],
      [{ ...one(visual), catalogOrder: ['a', 'a'] }, /manifest\.catalogOrder: must list every visual id exactly once/],
      [{ ...one(visual), catalogOrder: ['b'] }, /manifest\.catalogOrder: must list every visual id exactly once/],
      [{ prelude: 'prelude.glsl', visuals: [{ id: 'a', body: 'a.glsl' }] }, /visuals\[0\]\.targets: is required/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, header: 'no comment' }] }, /visuals\[0\]\.header: must be one/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, header: '// a\n#error x' }] }, /visuals\[0\]\.header: must be one/],
      [{ prelude: 'prelude.glsl', visuals: [visual], transitions: {} }, /manifest\.transitions: must be an array/],
      [{ prelude: 'prelude.glsl', visuals: [visual], transitions: [visual, visual] }, /transitions\[1\]\.id: duplicate id/],
      [{ prelude: 'prelude.glsl', visuals: [visual], transitions: [{ ...visual, palette: [0, 0, 0, 0] }] },
        /transitions\[0\]\.palette: unknown key/],
      [{ prelude: 'prelude.glsl', visuals: [visual], transitions: [{ id: 'a', body: 'a.glsl' }] },
        /transitions\[0\]\.targets: is required/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, trailDecay: 0.99 }] }, /visuals\[0\]\.trailDecay: must be a number in \[0, 0\.96\]/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, post: [0, 1, 0, 0, 0] }] }, /visuals\[0\]\.post: must be an object/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, post: { ...post, bloom: 0.5 } }] }, /visuals\[0\]\.post\.bloom: unknown key/],
      ...POST_KEYS.map(k => {
        const { [k]: _, ...rest } = post;
        return [{ prelude: 'prelude.glsl', visuals: [{ ...visual, post: rest }] }, new RegExp(`visuals\\[0\\]\\.post\\.${k}: is required`)];
      }),
      ...POST_KEYS.flatMap(k => [POST_RANGES[k][0] - 0.001, POST_RANGES[k][1] + 0.001, '0.5', null].map(x =>
        [{ prelude: 'prelude.glsl', visuals: [{ ...visual, post: { ...post, [k]: x } }] },
          new RegExp(`visuals\\[0\\]\\.post\\.${k}: must be a number in \\[${POST_RANGES[k][0]}, ${POST_RANGES[k][1]}\\]`)])),
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, params: [0.5, 0.5, 0.5] }] }, /visuals\[0\]\.params\[0\]: must be an object/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, params: [{ ...control, uniform: 'param1' }] }] },
        /visuals\[0\]\.params: param1 has a control but is not read/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl' }] }, /visuals\[0\]\.params: param0 is read but has no control metadata/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [control, { ...control, id: 'b', labelKey: 'visual.a.b' }] }] },
        /visuals\[0\]\.params: param0 has more than one control/],
      ...[['labelKey'], ['step'], ['group'], ['curve']].map(([k]) => {
        const { [k]: _, ...rest } = control;
        return [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [rest] }] }, new RegExp(`params\\[0\\]\\.${k}: is required`)];
      }),
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [{ ...control, default: 0.9 }] }] },
        /params\[0\]\.default: must lie in \[min, max\]/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [{ ...control, max: 1.5 }] }] },
        /params\[0\]\.max: must satisfy 0 <= min < max <= 1/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [{ ...control, step: 0 }] }] }, /params\[0\]\.step: must lie in/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [{ ...control, curve: 'log' }] }] }, /params\[0\]\.curve: must be one of/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [{ ...control, group: 'misc' }] }] }, /params\[0\]\.group: must be one of/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [{ ...control, label: ' Glow' }] }] }, /params\[0\]\.label: must be 1 to 40/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [{ ...control, labelKey: 'Visual Glow' }] }] }, /params\[0\]\.labelKey: must be visual\.<visual id>\.<control id>/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [{ ...control, labelKey: 'visual.b.glow' }] }] }, /params\[0\]\.labelKey: must be visual\./],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'q.glsl' }] }, /visuals\[0\]\.tunables: motion is read but not listed/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, body: 'p.glsl', params: [control] }] }, /visuals\[0\]\.tunables: accent is read but not listed/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, tunables: ['accent'] }] }, /visuals\[0\]\.tunables: accent is listed but not read/],
      [{ prelude: 'prelude.glsl', visuals: [{ ...visual, tunables: ['glow'] }] }, /visuals\[0\]\.tunables: must be a list of distinct names/],
    ];
    for (const [doc, error] of cases) {
      const path = join(dir, 'manifest.json');
      writeFileSync(path, JSON.stringify(doc));
      assert.throws(() => loadManifest(path), error);
    }
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify({ prelude: 'prelude.glsl',
      visuals: [{ ...visual, body: 'p.glsl', params: [control], tunables: ['accent'] }] }));
    const loaded = loadManifest(join(dir, 'manifest.json')).visuals[0];
    assert.deepEqual([loaded.params, loaded.controls.map(c => c.id), loaded.tunables], [[0.5, 0.5, 0.5], ['glow'], ['accent']]);
    assert.deepEqual(loaded.post, POST_DEFAULTS);
    assert.equal(loaded.catalog, null);
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify({ prelude: 'prelude.glsl',
      visuals: [{ ...listed, body: 'p.glsl', params: [control], tunables: ['accent'], unreadParamLabels: { param1: 'Two', param2: 'Three' } }] }));
    assert.deepEqual(loadManifest(join(dir, 'manifest.json')).visuals[0].catalog,
      { ...cat, imageCapable: false, paramLabels: ['Glow', 'Two', 'Three'] });
    // Both ends of every range load as written.
    for (const end of [0, 1]) {
      const edge = Object.fromEntries(POST_KEYS.map(k => [k, POST_RANGES[k][end]]));
      writeFileSync(join(dir, 'manifest.json'), JSON.stringify({ prelude: 'prelude.glsl', visuals: [{ ...visual, post: edge }] }));
      assert.deepEqual(loadManifest(join(dir, 'manifest.json')).visuals[0].post, edge);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('trust-boundary checkouts must be existing Git checkouts inside the workspace', () => {
  const ws = mkdtempSync(join(tmpdir(), 'oscillux-trust-'));
  try {
    mkdirSync(join(ws, 'host', '.git'), { recursive: true });
    writeFileSync(join(ws, 'host', '.git', 'config'), '[core]\n');
    const env = { GITHUB_WORKSPACE: ws };
    assertTrustBoundary(env, ['host']);
    assert.throws(() => assertTrustBoundary(env, ['hots']), /checkout hots has no \.git\/config/);
    assert.throws(() => assertTrustBoundary(env, ['/etc']), /must be a relative path/);
    assert.throws(() => assertTrustBoundary(env, ['../x']), /must be a relative path/);
    writeFileSync(join(ws, 'host', '.git', 'config'), '[http]\n\textraheader = AUTHORIZATION: basic x\n');
    assert.throws(() => assertTrustBoundary(env, ['host']), /credential-bearing/);
  } finally {
    rmSync(ws, { recursive: true, force: true });
  }
});

test('the HLSL validator comes from OSCILLUX_FXC, OSCILLUX_DXC or PATH, else none', () => {
  const dir = mkdtempSync(join(tmpdir(), 'oscillux-hlsl-'));
  try {
    assert.equal(hlslValidator({ PATH: dir }), null);
    assert.equal(hlslValidator({}), null);
    assert.deepEqual(hlslValidator({ PATH: dir, OSCILLUX_DXC: '/x/dxc' }), { kind: 'dxc', path: '/x/dxc' });
    assert.deepEqual(hlslValidator({ OSCILLUX_DXC: '/x/dxc', OSCILLUX_FXC: '/y/fxc' }), { kind: 'fxc', path: '/y/fxc' });
    writeFileSync(join(dir, 'dxc'), '#!/bin/sh\n');
    assert.equal(hlslValidator({ PATH: dir }), null, 'a non-executable dxc is not a validator');
    chmodSync(join(dir, 'dxc'), 0o755);
    assert.deepEqual(hlslValidator({ PATH: dir }), { kind: 'dxc', path: join(dir, 'dxc') });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('validateHLSL passes the entry point and profile to the validator and surfaces rejections', () => {
  const dir = mkdtempSync(join(tmpdir(), 'oscillux-hlsl-'));
  try {
    const log = join(dir, 'args');
    const stub = join(dir, 'stub');
    // Records its arguments; rejects a source containing "bad".
    writeFileSync(stub, `#!/bin/sh\nprintf '%s\\n' "$@" > '${log}'\n` +
      'for a; do f="$a"; done\nif grep -q bad "$f"; then echo "error X3000: bad" >&2; exit 1; fi\n');
    chmodSync(stub, 0o755);
    validateHLSL('float4 frag_a() : SV_Target0 { return 0; }', 'frag_a', { kind: 'fxc', path: stub });
    assert.match(readFileSync(log, 'utf8'), /^\/nologo\n\/T\nps_5_0\n\/E\nfrag_a\n\/Fo\n/);
    validateHLSL('float4 frag_a() : SV_Target0 { return 0; }', 'frag_a', { kind: 'dxc', path: stub });
    assert.match(readFileSync(log, 'utf8'), /^-T\nps_6_0\n-E\nfrag_a\n-HV\n2018\n-Fo\n/);
    assert.throws(() => validateHLSL('bad', 'frag_a', { kind: 'fxc', path: stub }), /fxc rejected frag_a:\nerror X3000: bad/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('every hlsl visual has an HLSL golden that passes checkHlslABI', () => {
  const ids = loadManifest(EXAMPLE).byTarget.hlsl.map(v => v.id);
  assert.deepEqual(readdirSync(GOLDEN).filter(isHlsl).sort(), ids.map(id => `${id}.hlsl`).sort());
  for (const id of ids) checkHlslABI(readFileSync(join(GOLDEN, `${id}.hlsl`), 'utf8'), mslEntryPoint(id));
});

test('checkHlslABI accepts the HLSL golden and rejects register, packing, type and entry drift', () => {
  const src = readFileSync(join(GOLDEN, 'image-ripple.hlsl'), 'utf8');
  const entry = 'frag_image_ripple';
  checkHlslABI(src, entry);
  const tampered = (from, to) => {
    const text = src.replaceAll(from, to);
    assert.notEqual(text, src, `fixture no longer contains ${from}`);
    return text;
  };
  const abi = /HLSL ABI mismatch for frag_image_ripple/;
  const packing = /HLSL cbuffer packing mismatch for frag_image_ripple/;
  for (const [from, to, want] of [
    ['uPrevTex : register(t1)', 'uPrevTex : register(t2)', abi],
    ['register(b0)', 'register(b1)', abi],
    ['frag_image_ripple(', 'main(', abi],
    ['SV_Target0', 'SV_Target1', abi],
    ['ub_accent : packoffset(c6)', 'ub_accent : packoffset(c7)', packing],
    ['ub_dt : packoffset(c0.w)', 'ub_dt : packoffset(c0.z)', packing],
    ['float4 ub_spectrum[16]', 'float4 ub_spectrum[8]', packing],
    ['float ub_time : packoffset(c0.z)', 'int ub_time : packoffset(c0.z)', packing],
    ['float ub_time : packoffset(c0.z)', 'float2 ub_time : packoffset(c0.z)', packing],
  ]) {
    assert.throws(() => checkHlslABI(tampered(from, to), entry), want, `${from} -> ${to} was accepted`);
  }
});
