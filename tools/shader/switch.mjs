// SPDX-License-Identifier: AGPL-3.0-only
// Wraps the host switch transitions (shaders/switch/switch.glsl) as a full-frame reference pass:
// GLSL ES 3.00 for WebGL2, and GLSL 450 compiled through glslangValidator and SPIRV-Cross to
// Metal, as present.mjs wraps the present pass. switch-transition-check.mjs draws it for the
// golden vectors, the contact strip and the 1080p timings; verify.mjs compiles it on every run.
//
// Bindings: SwitchBlock is buffer 0 (WebGL2: uniform block binding 0), 48 bytes std140:
//   switch0 = (p, beatPhase, energy, focus)
//   switch1 = (motion, aspect, style, 0)
//   size    = (width, height, 0, 0) of the target
// Textures 0, 1 and 2 are the outgoing frame, the incoming frame and the photo; sampler 0.
// Colour 0 is the linear HDR result. uv = gl_FragCoord.xy / size, so target row j is
// v = (j + 0.5) / height with row 0 first in memory on both WebGL2 and Metal.
//
// sampling 'linear' (default) reads through the hardware bilinear filter (clamp-to-edge), as a
// host does. sampling 'fetch' reads bilinear by hand from texelFetch, clamping texel indices, so
// the conformance vectors do not depend on a GPU's fixed-point filter weights.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileGLSLToSPV, PINNED_GLSLANG, PINNED_SPIRV_CROSS_STAMP, run, withTempDir } from './glsl2msl.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const SWITCH_PATH = join(ROOT, 'shaders', 'switch', 'switch.glsl');
export const SWITCH_FUNCTION = 'oscillux_switch';
export const SWITCH_BLOCK_SIZE = 48;
export const SWITCH_STYLES = Object.freeze(['lumaKey', 'photoKey', 'melt', 'downbeatCutLightLeak', 'beatIris']);

const BLOCK = `    vec4 switch0;
    vec4 switch1;
    vec4 size;`;

// One tap per texture: SAMPLE(name, uv) for 'linear', a clamped texelFetch bilinear for 'fetch'.
function taps(sampling, tex) {
  const names = { From: 'uFrom', To: 'uTo', Photo: 'uPhoto' };
  return Object.entries(names).map(([k, n]) => {
    const s = tex(n);
    if (sampling === 'linear') return `vec3 oscTap${k}(vec2 uv) { return textureLod(${s}, uv, 0.0).rgb; }`;
    return `vec3 oscTap${k}(vec2 uv) {
    ivec2 n = textureSize(${s}, 0);
    vec2 f = uv * vec2(n) - 0.5;
    vec2 b = floor(f);
    vec2 a = f - b;
    ivec2 i0 = clamp(ivec2(b), ivec2(0), n - 1);
    ivec2 i1 = clamp(ivec2(b) + 1, ivec2(0), n - 1);
    vec3 c00 = texelFetch(${s}, ivec2(i0.x, i0.y), 0).rgb;
    vec3 c10 = texelFetch(${s}, ivec2(i1.x, i0.y), 0).rgb;
    vec3 c01 = texelFetch(${s}, ivec2(i0.x, i1.y), 0).rgb;
    vec3 c11 = texelFetch(${s}, ivec2(i1.x, i1.y), 0).rgb;
    return mix(mix(c00, c10, a.x), mix(c01, c11, a.x), a.y);
}`;
  }).join('\n');
}

function pass(sampling, tex) {
  if (sampling !== 'linear' && sampling !== 'fetch') throw new Error(`switch: unknown sampling ${sampling}`);
  return `${taps(sampling, tex)}
#define OSC_SWITCH_FROM(uv) oscTapFrom(uv)
${readFileSync(SWITCH_PATH, 'utf8')}
void main() {
    vec2 uv = gl_FragCoord.xy / su.size.xy;
    TransitionInputs t;
    t.from = oscTapFrom(uv);
    t.to = oscTapTo(uv);
    t.photo = oscTapPhoto(uv);
    t.p = su.switch0.x;
    t.beatPhase = su.switch0.y;
    t.energy = su.switch0.z;
    t.focus = su.switch0.w;
    t.motion = su.switch1.x;
    t.aspect = su.switch1.y;
    oColor = vec4(transition(int(su.switch1.z + 0.5), uv, t), 1.0);
}
`;
}

/** The GLSL ES 3.00 fragment shader; uniforms uFrom, uTo, uPhoto and block SwitchBlock. */
export function switchGLSL300({ sampling = 'linear' } = {}) {
  return `#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
layout(std140) uniform SwitchBlock {
${BLOCK}
} su;
uniform sampler2D uFrom, uTo, uPhoto;
layout(location = 0) out vec4 oColor;
${pass(sampling, n => n)}`;
}

/** The GLSL 450 fragment shader that the Metal leg compiles. */
export function switchGLSL450({ sampling = 'linear' } = {}) {
  return `#version 450
layout(set = 0, binding = 0, std140) uniform SwitchBlock {
${BLOCK}
} su;
layout(set = 0, binding = 0) uniform texture2D uFrom;
layout(set = 0, binding = 1) uniform texture2D uTo;
layout(set = 0, binding = 2) uniform texture2D uPhoto;
layout(set = 0, binding = 0) uniform sampler uSamp;
layout(location = 0) out vec4 oColor;
${pass(sampling, n => `sampler2D(${n}, uSamp)`)}`;
}

/** Metal source with entry point SWITCH_FUNCTION; checks the reflected bindings. */
export function switchMSL({ sampling = 'linear' } = {}) {
  return withTempDir('switch', dir => {
    const spv = compileGLSLToSPV(switchGLSL450({ sampling }), dir);
    const reflection = JSON.parse(run('spirv-cross', [spv, '--reflect']));
    const msl = run('spirv-cross', [
      spv, '--msl', '--msl-decoration-binding', '--msl-force-native-arrays',
      '--rename-entry-point', 'main', SWITCH_FUNCTION, 'frag',
    ]);
    checkSwitchABI(msl, reflection);
    return `// SPDX-License-Identifier: AGPL-3.0-only
// GENERATED from shaders/switch/switch.glsl by glslangValidator ${PINNED_GLSLANG} + SPIRV-Cross ${PINNED_SPIRV_CROSS_STAMP}.

${msl}`;
  });
}

function checkSwitchABI(msl, reflection) {
  const need = [
    [reflection.ubos, 'SwitchBlock', 0],
    [reflection.separate_images, 'uFrom', 0],
    [reflection.separate_images, 'uTo', 1],
    [reflection.separate_images, 'uPhoto', 2],
    [reflection.separate_samplers, 'uSamp', 0],
  ];
  for (const [list, name, binding] of need) {
    const found = (list || []).find(r => r.name === name);
    if (!found || found.binding !== binding) throw new Error(`switch: SPIR-V binding of ${name} is not ${binding}`);
  }
  const ubo = reflection.ubos.find(r => r.name === 'SwitchBlock');
  if (ubo.block_size !== SWITCH_BLOCK_SIZE) throw new Error(`switch: SwitchBlock is ${ubo.block_size} bytes`);
  const checks = [
    new RegExp(`fragment\\s+\\w+\\s+${SWITCH_FUNCTION}\\(`),
    /\[\[buffer\(0\)\]\]/, /\[\[texture\(0\)\]\]/, /\[\[texture\(1\)\]\]/, /\[\[texture\(2\)\]\]/, /\[\[sampler\(0\)\]\]/,
    /\[\[color\(0\)\]\]/,
  ];
  for (const re of checks) if (!re.test(msl)) throw new Error(`switch: MSL has no ${re.source}`);
}

/** The 48-byte SwitchBlock for one draw. */
export function switchBlock({ p, beatPhase, energy, focus, motion, aspect, style, width, height }) {
  const id = typeof style === 'number' ? style : SWITCH_STYLES.indexOf(style);
  if (id < 0) throw new Error(`switch: unknown style ${style}`);
  return new Float32Array([p, beatPhase, energy, focus, motion, aspect, id, 0, width, height, 0, 0]);
}
