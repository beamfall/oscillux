// SPDX-License-Identifier: AGPL-3.0-only
// Wraps the shared present pass (shaders/present/present.glsl) for the reference hosts: GLSL
// ES 3.00 for WebGL2, and GLSL 450 compiled through glslangValidator and SPIRV-Cross to Metal,
// as bundle-hosts.mjs compiles the visuals. The PresentBlock is present0 followed by the
// OverlayUniforms members of conformance/packing/overlay-uniforms.schema.json, so the block a
// host uploads is 16 bytes of present0 and then the bytes oscillux_overlay_pack writes.
//
// Present pass v2 (CORE-0108) appends post0 and post1 (PRESENT_POST_OFFSET, 32 bytes) after the
// OverlayUniforms: post0 = (bloom strength, chromatic aberration, grain, dither amplitude in output
// codes), post1 = (frame seed, 0, 0, 0). presentPost() packs them. All zero turns every v2 stage
// off except the hue-preserving tone map.
//
// Bindings: the block is buffer 0 (WebGL2: uniform block binding 0); textures 0, 1 and 2 are
// the incoming frame, the outgoing frame and the history, texture 4 the bloom chain's L0
// (PRESENT_BLOOM_TEXTURE; WebGL2: the sampler uniform uBloom); sampler 0. A host without bloom
// still binds a texture there (any, such as the incoming frame) and leaves post0.x at 0, which
// skips the read. Colour 0 is the presented frame, colour 1 the history for the next frame.
//
// Bloom: bloomGLSL300(stage) and bloomMSL(stage) wrap shaders/present/bloom.glsl, and
// PRESENT_BLOOM_GRAPH lists its targets and passes (docs/shader-toolchain.md, "Present pass").
//
// Optional host layer: pass { layer: source } to presentGLSL300 or presentMSL to insert a layer
// (shaders/present/present.glsl, "Optional host layer") that defines
// vec3 oscillux_present_layer(vec2 uv, vec3 c). It adds the PresentLayerBlock (vec4 layer[8],
// 128 bytes) at buffer 1 (WebGL2: uniform block binding 1), the layer texture uL at texture 3
// and its sampler at sampler 1 (WebGL2: the sampler uniform uL). Without a layer the pass and
// its bindings are unchanged.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileGLSLToSPV, PINNED_GLSLANG, PINNED_SPIRV_CROSS_STAMP, run, withTempDir } from './glsl2msl.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const PRESENT_PATH = join(ROOT, 'shaders', 'present', 'present.glsl');
export const BLOOM_PATH = join(ROOT, 'shaders', 'present', 'bloom.glsl');
export const OVERLAY_SCHEMA_PATH = join(ROOT, 'conformance', 'packing', 'overlay-uniforms.schema.json');
export const PRESENT_FUNCTION = 'oscillux_present';
/** Bytes of present0 before the OverlayUniforms block. */
export const PRESENT_HEAD = 16;
/** Bytes of the PresentLayerBlock a layer reads, and its bindings. */
export const PRESENT_LAYER_BLOCK_SIZE = 128;
export const PRESENT_LAYER_BINDINGS = Object.freeze({ buffer: 1, texture: 3, sampler: 1, webglBlockBinding: 1 });
const LAYER_MARKER = '// OSCILLUX_PRESENT_LAYER_SOURCE\n';
/** Byte offset and size of post0 and post1 in the PresentBlock (after the OverlayUniforms). */
export const PRESENT_POST_OFFSET = 336;
export const PRESENT_POST_SIZE = 32;
/** Texture index of the bloom chain's L0 in the present pass. */
export const PRESENT_BLOOM_TEXTURE = 4;

function blockMembers() {
  const schema = JSON.parse(readFileSync(OVERLAY_SCHEMA_PATH, 'utf8'));
  let offset = PRESENT_HEAD;
  const lines = ['    vec4 present0;'];
  for (const f of schema.fields) {
    if (f.type !== 'vec4' || f.offset + PRESENT_HEAD !== offset) {
      throw new Error(`present: ${f.name} is not a vec4 at std140 offset ${offset - PRESENT_HEAD}`);
    }
    lines.push(`    vec4 ${f.name}${f.count ? `[${f.count}]` : ''};`);
    offset += 16 * (f.count ?? 1);
  }
  if (offset !== PRESENT_HEAD + schema.size) throw new Error(`present: block is ${offset} bytes`);
  if (offset !== PRESENT_POST_OFFSET) throw new Error(`present: post0 would be at ${offset}, not ${PRESENT_POST_OFFSET}`);
  lines.push('    vec4 post0;', '    vec4 post1;');
  return { members: lines.join('\n'), size: offset + PRESENT_POST_SIZE };
}

/**
 * post0 and post1 as 8 floats, for the PresentBlock at PRESENT_POST_OFFSET. bloom multiplies the
 * chain's L0; aberration is the red/blue offset at the corners as a fraction of the distance to
 * the centre; grain the film-grain amplitude (multiplicative, display-linear); dither the
 * triangular dither amplitude in output codes (1 is the full TPDF); frame the integer frame
 * seed (wrapped to 24 bits). Under reduced motion grain is 0 (the pass also zeroes it from the
 * packed reducedMotion flag).
 */
export function presentPost({ bloom = 0, aberration = 0, grain = 0, dither = 0, frame = 0, reducedMotion = false } = {}) {
  return new Float32Array([bloom, aberration, reducedMotion ? 0 : grain, dither, frame % 16777216, 0, 0, 0]);
}

/** The visual's trail decay a host uploads: 0 under reduced motion. */
export const presentTrailDecay = (trailDecay, reducedMotion) => (reducedMotion ? 0 : trailDecay);

/** The pass body, with the layer's source at its marker when there is one. source overrides
 * the body (for A/B checks against an earlier pass). */
function body(layer, source) {
  const text = source ?? readFileSync(PRESENT_PATH, 'utf8');
  if (layer === undefined) return text;
  if (typeof layer !== 'string' || !/vec3\s+oscillux_present_layer\s*\(/.test(layer)) {
    throw new Error('present: a layer defines vec3 oscillux_present_layer(vec2 uv, vec3 c)');
  }
  if (text.split(LAYER_MARKER).length !== 2) throw new Error('present: the pass has no single layer marker');
  return text.replace(LAYER_MARKER, () => `${layer.trimEnd()}\n`);
}

const LAYER_MEMBERS = `    vec4 layer[${PRESENT_LAYER_BLOCK_SIZE / 16}];`;

/** The GLSL ES 3.00 fragment shader; uniforms uA, uB, uH, uBloom and block PresentBlock (and
 * uL and PresentLayerBlock with a layer). */
export function presentGLSL300({ layer, source } = {}) {
  const { members } = blockMembers();
  const decl = layer === undefined ? '' : `#define OSCILLUX_PRESENT_LAYER 1
layout(std140) uniform PresentLayerBlock {
${LAYER_MEMBERS}
} pl;
uniform sampler2D uL;
#define PRESENT_LAYER_TEX(uv) textureLod(uL, uv, 0.0)
#define PRESENT_LAYER_FETCH(px) texelFetch(uL, px, 0)
`;
  return `#version 300 es
precision highp float;
precision highp int;
layout(std140) uniform PresentBlock {
${members}
} pu;
uniform sampler2D uA, uB, uH, uBloom;
in vec2 vUV;
layout(location = 0) out vec4 oColor;
layout(location = 1) out vec4 oHist;
#define PRESENT_A(uv) textureLod(uA, uv, 0.0)
#define PRESENT_B(uv) textureLod(uB, uv, 0.0)
#define PRESENT_HIST(px) texelFetch(uH, px, 0)
#define PRESENT_BLOOM(uv) textureLod(uBloom, uv, 0.0)
${decl}${body(layer, source)}`;
}

/** The GLSL 450 fragment shader that the Metal leg compiles. */
export function presentGLSL450({ layer, source } = {}) {
  const { members } = blockMembers();
  const b = PRESENT_LAYER_BINDINGS;
  const decl = layer === undefined ? '' : `#define OSCILLUX_PRESENT_LAYER 1
layout(set = 0, binding = ${b.buffer}, std140) uniform PresentLayerBlock {
${LAYER_MEMBERS}
} pl;
layout(set = 0, binding = ${b.texture}) uniform texture2D uL;
layout(set = 0, binding = ${b.sampler}) uniform sampler uLayerSamp;
#define PRESENT_LAYER_TEX(uv) textureLod(sampler2D(uL, uLayerSamp), uv, 0.0)
#define PRESENT_LAYER_FETCH(px) texelFetch(sampler2D(uL, uLayerSamp), px, 0)
`;
  return `#version 450
layout(set = 0, binding = 0, std140) uniform PresentBlock {
${members}
} pu;
layout(set = 0, binding = 0) uniform texture2D uA;
layout(set = 0, binding = 1) uniform texture2D uB;
layout(set = 0, binding = 2) uniform texture2D uH;
layout(set = 0, binding = ${PRESENT_BLOOM_TEXTURE}) uniform texture2D uBloom;
layout(set = 0, binding = 0) uniform sampler uSamp;
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 oColor;
layout(location = 1) out vec4 oHist;
#define PRESENT_A(uv) textureLod(sampler2D(uA, uSamp), uv, 0.0)
#define PRESENT_B(uv) textureLod(sampler2D(uB, uSamp), uv, 0.0)
#define PRESENT_HIST(px) texelFetch(sampler2D(uH, uSamp), px, 0)
#define PRESENT_BLOOM(uv) textureLod(sampler2D(uBloom, uSamp), uv, 0.0)
${decl}${body(layer, source)}`;
}

/** Metal source with entry point PRESENT_FUNCTION; checks the reflected bindings. source
 * replaces the pass body (an earlier present.glsl, for A/B checks); the ABI check then applies
 * only to the v2 body. */
export function presentMSL({ layer, source } = {}) {
  return withTempDir('present', dir => {
    const spv = compileGLSLToSPV(presentGLSL450({ layer, source }), dir);
    const reflection = JSON.parse(run('spirv-cross', [spv, '--reflect']));
    const msl = run('spirv-cross', [
      spv, '--msl', '--msl-decoration-binding', '--msl-force-native-arrays',
      '--rename-entry-point', 'main', PRESENT_FUNCTION, 'frag',
    ]);
    if (source === undefined) checkPresentABI(msl, reflection, layer !== undefined);
    return `// SPDX-License-Identifier: AGPL-3.0-only
// GENERATED from shaders/present/present.glsl by glslangValidator ${PINNED_GLSLANG} + SPIRV-Cross ${PINNED_SPIRV_CROSS_STAMP}.

${msl}`;
  });
}

function checkPresentABI(msl, reflection, layer) {
  const b = PRESENT_LAYER_BINDINGS;
  const need = [
    [reflection.ubos, 'PresentBlock', 0],
    [reflection.separate_images, 'uA', 0],
    [reflection.separate_images, 'uB', 1],
    [reflection.separate_images, 'uH', 2],
    [reflection.separate_images, 'uBloom', PRESENT_BLOOM_TEXTURE],
    [reflection.separate_samplers, 'uSamp', 0],
    ...(layer ? [
      [reflection.ubos, 'PresentLayerBlock', b.buffer],
      [reflection.separate_images, 'uL', b.texture],
      [reflection.separate_samplers, 'uLayerSamp', b.sampler],
    ] : []),
  ];
  for (const [list, name, binding] of need) {
    const found = (list || []).find(r => r.name === name);
    if (!found || found.binding !== binding) throw new Error(`present: SPIR-V binding of ${name} is not ${binding}`);
  }
  const ubo = reflection.ubos.find(r => r.name === 'PresentBlock');
  if (ubo.block_size !== blockMembers().size) throw new Error(`present: PresentBlock is ${ubo.block_size} bytes`);
  const lb = (reflection.ubos || []).find(r => r.name === 'PresentLayerBlock');
  if (layer && lb.block_size !== PRESENT_LAYER_BLOCK_SIZE) throw new Error(`present: PresentLayerBlock is ${lb.block_size} bytes`);
  if (!layer && (lb || (reflection.separate_images || []).length !== 4)) throw new Error('present: layer bindings without a layer');
  const checks = [
    new RegExp(`fragment\\s+\\w+\\s+${PRESENT_FUNCTION}\\(`),
    /\[\[buffer\(0\)\]\]/, /\[\[texture\(0\)\]\]/, /\[\[texture\(1\)\]\]/, /\[\[texture\(2\)\]\]/, /\[\[texture\(4\)\]\]/, /\[\[sampler\(0\)\]\]/,
    /\[\[color\(0\)\]\]/, /\[\[color\(1\)\]\]/, /\[\[user\(locn0\)\]\]/,
    ...(layer ? [/\[\[buffer\(1\)\]\]/, /\[\[texture\(3\)\]\]/, /\[\[sampler\(1\)\]\]/] : []),
  ];
  for (const re of checks) if (!re.test(msl)) throw new Error(`present: MSL has no ${re.source}`);
}

export const presentBlockSize = () => blockMembers().size;

// ---------- Bloom (shaders/present/bloom.glsl) ----------

export const BLOOM_STAGES = Object.freeze(['prefilter', 'down', 'up']);
/** BloomBlock: vec4 bloom0 (1 / source size, threshold, knee), vec4 bloom1 (eased switch
 * progress, up-sample radius in source texels, 0, 0). */
export const BLOOM_BLOCK_SIZE = 32;
export const BLOOM_LEVELS = 5;
export const PRESENT_BLOOM_DEFAULTS = Object.freeze({ threshold: 1.0, knee: 0.5, radius: 1.0 });

/** Size of bloom level k (0 = L0 at half size) for a width by height output. */
export function bloomLevelSize(width, height, level) {
  const d = 2 ** (level + 1);
  return [Math.max(1, Math.ceil(width / d)), Math.max(1, Math.ceil(height / d))];
}

/**
 * The present pass graph: five rgba16f levels (linear filter, clamp to edge) and the passes in
 * order. A host runs the passes as listed, each a full-target triangle; "add" blends ONE, ONE
 * onto what the level holds, "replace" overwrites it. bloom0.xy is the reciprocal size of the
 * pass's source, so it follows from the sizes. The graph is outside the v1 pass-list grammar
 * (conformance/passes): the bloom passes read BloomBlock, not VisualUniforms, and the present
 * pass writes two colour targets and reads the history.
 */
export const PRESENT_BLOOM_GRAPH = Object.freeze({
  targets: Object.freeze(Array.from({ length: BLOOM_LEVELS }, (_, k) => Object.freeze({
    id: `L${k}`, scale: 1 / 2 ** (k + 1), format: 'rgba16f', filter: 'linear', wrap: 'clamp',
  }))),
  passes: Object.freeze([
    Object.freeze({ id: 'prefilter', stage: 'prefilter', inputs: Object.freeze({ src: 'incoming', srcB: 'outgoing' }), output: 'L0', blend: 'replace' }),
    ...[1, 2, 3, 4].map(k => Object.freeze({ id: `down${k}`, stage: 'down', inputs: Object.freeze({ src: `L${k - 1}` }), output: `L${k}`, blend: 'replace' })),
    ...[3, 2, 1, 0].map(k => Object.freeze({ id: `up${k}`, stage: 'up', inputs: Object.freeze({ src: `L${k + 1}` }), output: `L${k}`, blend: 'add' })),
    Object.freeze({ id: 'present', stage: 'present', inputs: Object.freeze({ incoming: 'incoming', outgoing: 'outgoing', history: 'history', bloom: 'L0' }), output: 'screen', blend: 'replace' }),
  ]),
});

function bloomBody(stage) {
  const i = BLOOM_STAGES.indexOf(stage);
  if (i < 0) throw new Error(`bloom: stage is one of ${BLOOM_STAGES.join(', ')}`);
  return { define: `#define BLOOM_STAGE ${i}\n`, text: readFileSync(BLOOM_PATH, 'utf8'), prefilter: i === 0 };
}

/** The GLSL ES 3.00 fragment shader of one bloom stage; uniforms uSrc (and uSrcB for the
 * prefilter) and block BloomBlock. */
export function bloomGLSL300(stage) {
  const { define, text, prefilter } = bloomBody(stage);
  return `#version 300 es
precision highp float;
precision highp int;
${define}layout(std140) uniform BloomBlock {
    vec4 bloom0;
    vec4 bloom1;
} bu;
uniform sampler2D uSrc${prefilter ? ', uSrcB' : ''};
in vec2 vUV;
layout(location = 0) out vec4 oColor;
#define BLOOM_SRC(uv) textureLod(uSrc, uv, 0.0)
${prefilter ? '#define BLOOM_SRC_B(uv) textureLod(uSrcB, uv, 0.0)\n' : ''}${text}`;
}

export function bloomGLSL450(stage) {
  const { define, text, prefilter } = bloomBody(stage);
  return `#version 450
${define}layout(set = 0, binding = 0, std140) uniform BloomBlock {
    vec4 bloom0;
    vec4 bloom1;
} bu;
layout(set = 0, binding = 0) uniform texture2D uSrc;
${prefilter ? 'layout(set = 0, binding = 1) uniform texture2D uSrcB;\n' : ''}layout(set = 0, binding = 0) uniform sampler uSamp;
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 oColor;
#define BLOOM_SRC(uv) textureLod(sampler2D(uSrc, uSamp), uv, 0.0)
${prefilter ? '#define BLOOM_SRC_B(uv) textureLod(sampler2D(uSrcB, uSamp), uv, 0.0)\n' : ''}${text}`;
}

/** Metal entry point of a bloom stage. */
export const bloomFunction = stage => `oscillux_bloom_${stage}`;

/** Metal source of one bloom stage: buffer 0, texture 0 (and 1 for the prefilter), sampler 0. */
export function bloomMSL(stage) {
  return withTempDir(`bloom-${stage}`, dir => {
    const spv = compileGLSLToSPV(bloomGLSL450(stage), dir);
    const reflection = JSON.parse(run('spirv-cross', [spv, '--reflect']));
    const ubo = (reflection.ubos || []).find(r => r.name === 'BloomBlock');
    if (!ubo || ubo.binding !== 0 || ubo.block_size !== BLOOM_BLOCK_SIZE) throw new Error(`bloom ${stage}: BloomBlock is not 32 bytes at buffer 0`);
    const images = (reflection.separate_images || []).map(r => `${r.name}@${r.binding}`).sort().join(',');
    if (images !== (stage === 'prefilter' ? 'uSrc@0,uSrcB@1' : 'uSrc@0')) throw new Error(`bloom ${stage}: textures are ${images}`);
    const msl = run('spirv-cross', [
      spv, '--msl', '--msl-decoration-binding', '--rename-entry-point', 'main', bloomFunction(stage), 'frag',
    ]);
    if (!new RegExp(`fragment\\s+\\w+\\s+${bloomFunction(stage)}\\(`).test(msl)) throw new Error(`bloom ${stage}: no entry point`);
    return `// SPDX-License-Identifier: AGPL-3.0-only
// GENERATED from shaders/present/bloom.glsl (${stage}) by glslangValidator ${PINNED_GLSLANG} + SPIRV-Cross ${PINNED_SPIRV_CROSS_STAMP}.

${msl}`;
  });
}
