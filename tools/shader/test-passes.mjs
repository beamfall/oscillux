// SPDX-License-Identifier: AGPL-3.0-only
// Pure-node checks for the pass-list schema and validator (passes.mjs) and a
// smoke run of the watch-mode preview (watch.mjs --once --no-render). The
// examples in conformance/passes/examples must validate against the example
// manifest; each edited copy below must be rejected with the stated reason.
//
//   node tools/shader/test-passes.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { loadManifest } from './manifest.mjs';
import { PASS_SCHEMA_PATH, passListErrors, schemaErrors } from './passes.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const MANIFEST = join(ROOT, 'examples', 'shader', 'manifest.json');
const EXAMPLES = join(ROOT, 'conformance', 'passes', 'examples');
const BLOOM = join(EXAMPLES, 'bloom-feedback.json');
const visualIds = new Set(loadManifest(MANIFEST).byId.keys());
const read = path => JSON.parse(readFileSync(path, 'utf8'));
const node = (...args) => spawnSync(process.execPath, args, { cwd: ROOT, encoding: 'utf8' });

test('every example pass list is valid against the example manifest', () => {
  const names = readdirSync(EXAMPLES).filter(n => n.endsWith('.json')).sort();
  assert.deepEqual(names, ['bloom-feedback.json', 'feedback-tonemap.json']);
  for (const name of names) assert.deepEqual(passListErrors(read(join(EXAMPLES, name)), { visualIds }), [], name);
});

test('the feedback example is the render.mjs ping-pong', () => {
  const list = read(join(EXAMPLES, 'feedback-tonemap.json'));
  assert.deepEqual(list.targets, [
    { id: 'scene', format: 'rgba16f', scale: 1, filter: 'linear', feedback: true, clear: [0, 0, 0, 1] },
  ]);
  assert.deepEqual(list.passes.map(p => [p.inputs, p.output]), [
    [{ image: 'image', prev: 'scene.previous' }, 'scene'],
    [{ source: 'scene' }, 'screen'],
  ]);
});

// [reason, edit applied to a copy of bloom-feedback.json, expected error]
const REJECTIONS = [
  ['unknown top-level key', l => { l.renderer = 'x'; }, /\$\.renderer: unknown key/],
  ['unsupported version', l => { l.version = 2; }, /\$\.version: must be 1/],
  ['no passes', l => { l.passes = []; }, /\$\.passes: must have at least 1 items/],
  ['unknown format', l => { l.targets[1].format = 'rgb8'; }, /targets\[1\]\.format: must be one of/],
  ['zero scale', l => { l.targets[1].scale = 0; }, /targets\[1\]\.scale: must be > 0/],
  ['scale above 1', l => { l.targets[1].scale = 2; }, /targets\[1\]\.scale: must be <= 1/],
  ['bad clear', l => { l.targets[0].clear = [0, 0, 0]; }, /targets\[0\]\.clear: must have at least 4 items/],
  ['bad target name', l => { l.targets[1].id = 'Bright'; }, /targets\[1\]\.id: must match/],
  ['reserved target name', l => { l.targets[1].id = 'screen'; }, /"screen" is reserved/],
  ['duplicate target', l => { l.targets.push({ id: 'bloom', format: 'rgba8' }); }, /duplicate target "bloom"/],
  ['duplicate pass', l => { l.passes[2].id = 'threshold'; }, /duplicate pass "threshold"/],
  ['visual and post together', l => { l.passes[1].shader.visual = 'image-ripple'; }, /shader: must match exactly one of 2/],
  ['visual not in manifest', l => { l.passes[0].shader.visual = 'missing'; }, /"missing" is not in the manifest/],
  ['visual without prev', l => { delete l.passes[0].inputs.prev; }, /binds exactly the slots image and prev/],
  ['bad slot name', l => { l.passes[1].inputs['Source'] = 'scene'; }, /inputs\.Source \(name\): must match/],
  ['unknown input target', l => { l.passes[1].inputs.source = 'hdr'; }, /inputs\.source: unknown target "hdr"/],
  ['previous of a plain target', l => { l.passes[2].inputs.source = 'bright.previous'; }, /"bright" is not a feedback target/],
  ['read before write', l => { l.passes.splice(0, 0, l.passes.splice(1, 1)[0]); }, /"scene" is read before any pass writes it/],
  ['read own output', l => { l.passes[2].inputs.source = 'blur-h'; }, /cannot read the target it writes/],
  ['unknown output', l => { l.passes[1].output = 'glow'; }, /output: unknown target "glow"/],
  ['unknown blend', l => { l.passes[4].blend = 'multiply'; }, /blend: must be one of/],
  ['target never written', l => { l.targets.push({ id: 'spare', format: 'rgba8' }); }, /"spare" is never written/],
  ['target never read', l => { delete l.passes[4].inputs.bloom; }, /"bloom" is never read/],
  ['nothing reaches the screen', l => { l.passes[4].output = 'bright'; }, /no pass writes "screen"/],
  ['unknown uniform', l => { l.passes[1].uniforms.threshold = 1; }, /uniforms\.threshold: is not a VisualUniforms member/],
  ['audio-sourced uniform', l => { l.passes[1].uniforms.bass = 1; }, /uniforms\.bass: is filled from audio analysis/],
  ['array uniform', l => { l.passes[1].uniforms.spectrum = [0, 0, 0, 0]; }, /uniforms\.spectrum: array members cannot be set/],
  ['vec4 arity', l => { l.passes[1].uniforms.accent = [1, 0, 0]; }, /uniforms\.accent: vec4 needs 4 numbers/],
  ['float given a vector', l => { l.passes[1].uniforms.param0 = [1, 0]; }, /uniforms\.param0: float needs a number/],
  ['non-number uniform', l => { l.passes[1].uniforms.param0 = '1'; }, /uniforms\.param0: must match exactly one of 2/],
];

for (const [reason, edit, expected] of REJECTIONS) {
  test(`rejects a pass list: ${reason}`, () => {
    const list = read(BLOOM);
    edit(list);
    const errors = passListErrors(list, { visualIds });
    assert.ok(errors.some(e => expected.test(e)), `expected ${expected}, got:\n${errors.join('\n')}`);
  });
}

test('the schema interpreter refuses keywords it does not implement', () => {
  const schema = read(PASS_SCHEMA_PATH);
  schema.properties.version.multipleOf = 1;
  assert.throws(() => schemaErrors(schema, read(BLOOM)), /unsupported schema keyword multipleOf/);
  assert.throws(() => schemaErrors({ $ref: '#/definitions/none' }, 1), /unresolvable \$ref/);
});

test('passes.mjs validates from the command line', () => {
  const ok = node('tools/shader/passes.mjs', BLOOM, '--manifest', MANIFEST);
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /bloom-feedback\.json: ok \(4 targets, 5 passes\)/);
  const bad = node('tools/shader/passes.mjs', join(ROOT, 'conformance', 'packing', 'visual-uniforms.json'));
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /\$: version is required/);
});

test('watch.mjs --once --no-render runs one iteration without a browser', () => {
  const ok = node('tools/shader/watch.mjs', MANIFEST, '--passes', BLOOM, '--once', '--no-render');
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /\[watch\] 2 visual\(s\), 9 shader\(s\) wrapped, pass list ok \(5 passes\)/);
  const bad = node('tools/shader/watch.mjs', MANIFEST, '--passes', PASS_SCHEMA_PATH, '--once', '--no-render');
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /\[watch\] invalid: .*pass-list\.schema\.json/);
});
