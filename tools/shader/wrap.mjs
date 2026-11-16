// SPDX-License-Identifier: AGPL-3.0-only
// Assemble platform shaders from a portable visual body.
// A body defines:  vec3 visual(vec2 uv, VisualUniforms u)
// Texture reads: IMG(uv) / PREV(uv) macros, vec4-valued.
// Feedback: feedbackTrail(col, uv, decay, zoom, rotAmt) — defined per platform.
//
// A transition body defines:  vec3 transition(vec2 uv, float p, VisualUniforms u)
// It blends two linear HDR frames: FROM(uv) (the outgoing visual, texture 0)
// and TO(uv) (the incoming one, texture 1), vec3-valued. p is the linear
// progress, 0 to 1, from presentation0.x; presentation0.y is a seed in [0, 1)
// that the host draws per switch. The other uniforms are the incoming visual's.
// Transitions use the visuals' binding layout, so every target's ABI check
// applies to them unchanged.
//
// The prelude is host data, not part of this tool. It must define
// `struct VisualUniforms { ... };` (the schema layout, closed by "};" and a
// newline), `mat2 rot2(float)`, `vec3 sanitizeColor(vec3)` and
// `vec3 suppressGreenCast(vec3)`. See docs/shader-toolchain.md.
import { glslToHlsl, glslToMsl } from './glsl2msl.mjs';
import { layout, loadSchema } from './uniforms.mjs';

// Finished-frame grade. Procedural visuals get suppressGreenCast; visuals that
// take an image as input keep only sanitizeColor so an image's real greens are
// not pushed toward blue/magenta.
const finish = imageInput => imageInput ? 'sanitizeColor' : 'suppressGreenCast';

// What main() writes: a visual's graded colour, or a transition's blend.
const result = (imageInput, transition) => transition
  ? 'sanitizeColor(transition(vUV, clamp(u.presentation0.x, 0.0, 1.0), u))'
  : `${finish(imageInput)}(visual(vUV, u))`;

// Texture reads for a transition body. Visual bodies get IMG and PREV.
const TRANSITION_MACROS = `#define FROM(x) IMG(x).rgb
#define TO(x) PREV(x).rgb`;

// decay is authored per 60 Hz frame; raising it to dt*60 keeps the trail's
// persistence in seconds the same at 30/60/120 Hz. dt <= 0 (no frame clock)
// applies one 60 Hz step. dt is the host frame-delta uniform expression.
function feedbackTrail(imageInput, dt) {
  const grade = finish(imageInput);
  return `vec3 feedbackTrail(vec3 col, vec2 uv, float decay, float zoom, float rotAmt) {
    vec2 q = uv - 0.5;
    q = rot2(rotAmt) * q;
    q *= (1.0 - zoom);
    vec3 p = ${grade}(PREV(q + 0.5).rgb);
    float k = pow(clamp(decay, 0.0, 0.90), ${dt} > 0.0 ? ${dt} * 60.0 : 1.0);
    return ${grade}(max(${grade}(col), p * k));
}`;
}

// Shared fullscreen vertex shader for GLSL 300 es hosts.
export const VERTEX_300 = `#version 300 es
layout(location=0) in vec2 aPos;
out vec2 vUV;
void main() {
    vUV = vec2(aPos.x * 0.5 + 0.5, 0.5 - aPos.y * 0.5); // origin top-left, matches Apple
    gl_Position = vec4(aPos, 0.0, 1.0);
}
`;

// The 450 uniform block members, the 450 VisualUniforms struct and loadUniforms()
// are emitted from conformance/packing/visual-uniforms.schema.json, one member per line.
const MEMBERS = layout(loadSchema()).members;

const UNIFORM_FIELDS = MEMBERS
  .map(m => `    ${m.type} ${m.name}${m.count ? `[${m.count}]` : ''};`).join('\n');

const LOAD_UNIFORMS = `VisualUniforms loadUniforms() {
    VisualUniforms u;
${MEMBERS.map(m => (m.count
    ? `    for (int i = 0; i < ${m.count}; ++i) u.${m.name}[i] = ub.${m.name}[i];`
    : `    u.${m.name} = ub.${m.name};`)).join('\n')}
    return u;
}`;

const STRUCT_RE = /\bstruct VisualUniforms \{[\s\S]*?\};\n/;

export function createWrapper({ prelude }) {
  if (typeof prelude !== 'string' || !STRUCT_RE.test(prelude)) {
    throw new Error('prelude must define `struct VisualUniforms { ... };` followed by a newline');
  }
  // The 450 targets declare the struct themselves, after the uniform block.
  const prelude450 = prelude.replace(STRUCT_RE, '');

  // ---------- GLSL ES 3.00 (WebGL2 / GLES hosts) ----------
  function wrapGLSL300(body, imageInput = false, transition = false) {
    return `#version 300 es
precision highp float;
precision highp int;
uniform sampler2D uImage;
uniform sampler2D uPrev;
#define IMG(x) texture(uImage,(x))
#define IMGSIZE vec2(textureSize(uImage,0))
#define PREV(x) texture(uPrev,(x))
${prelude}
uniform VisualUniforms u;
${transition ? TRANSITION_MACROS : feedbackTrail(imageInput, 'u.dt')}
${body}
in vec2 vUV;
layout(location=0) out vec4 fragColor;
void main() {
    fragColor = vec4(${result(imageInput, transition)}, 1.0);
}
`;
  }

  // ---------- Vulkan GLSL 450 ----------
  function wrapGLSL450(body, imageInput = false, transition = false) {
    return `#version 450
layout(set = 0, binding = 0) uniform VisualUniformBlock {
${UNIFORM_FIELDS}
} ub;
layout(set = 0, binding = 1) uniform sampler2D uImage;
layout(set = 0, binding = 2) uniform sampler2D uPrev;
#define IMG(x) texture(uImage,(x))
#define IMGSIZE vec2(textureSize(uImage,0))
#define PREV(x) texture(uPrev,(x))
struct VisualUniforms {
${UNIFORM_FIELDS}
};
${LOAD_UNIFORMS}
${prelude450}
${transition ? TRANSITION_MACROS : feedbackTrail(imageInput, 'ub.dt')}
${body}
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
void main() {
    VisualUniforms u = loadUniforms();
    outColor = vec4(${result(imageInput, transition)}, 1.0);
}
`;
  }

  // ---------- GLSL 450 input for the SPIR-V -> MSL and HLSL paths ----------
  // Separate textures and one sampler so SPIRV-Cross maps them to
  // [[texture(0)]], [[texture(1)]] and [[sampler(0)]] in MSL, and to
  // register(t0), register(t1) and register(s0) in HLSL.
  function wrapGLSL450MSL(body, imageInput = false, transition = false) {
    return `#version 450
layout(set = 0, binding = 0) uniform VisualUniformBlock {
${UNIFORM_FIELDS}
} ub;
layout(set = 0, binding = 0) uniform texture2D uImageTex;
layout(set = 0, binding = 1) uniform texture2D uPrevTex;
layout(set = 0, binding = 0) uniform sampler uSamp;
#define IMG(x) texture(sampler2D(uImageTex,uSamp),(x))
#define IMGSIZE vec2(textureSize(sampler2D(uImageTex,uSamp),0))
#define PREV(x) texture(sampler2D(uPrevTex,uSamp),(x))
struct VisualUniforms {
${UNIFORM_FIELDS}
};
${LOAD_UNIFORMS}
${prelude450}
${transition ? TRANSITION_MACROS : feedbackTrail(imageInput, 'ub.dt')}
${body}
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
void main() {
    VisualUniforms u = loadUniforms();
    outColor = vec4(${result(imageInput, transition)}, 1.0);
    if (u.time < -1e20) outColor += IMG(vec2(0.0)) + PREV(vec2(0.0));
}
`;
  }

  // ---------- Metal ----------
  // Requires glslangValidator and spirv-cross on PATH (see glsl2msl.mjs).
  function wrapMSL(id, body, headerComment = '', imageInput = false, transition = false) {
    return glslToMsl(wrapGLSL450MSL(body, imageInput, transition), id, headerComment);
  }

  // ---------- HLSL SM 5.0 (D3D11) ----------
  // Requires glslangValidator and spirv-cross on PATH (see glsl2msl.mjs).
  function wrapHLSL(id, body, headerComment = '', imageInput = false, transition = false) {
    return glslToHlsl(wrapGLSL450MSL(body, imageInput, transition), id, headerComment);
  }

  return { wrapGLSL300, wrapGLSL450, wrapGLSL450MSL, wrapMSL, wrapHLSL, VERTEX_300 };
}
