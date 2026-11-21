// SPDX-License-Identifier: AGPL-3.0-only
// Wraps the photo slideshow (shaders/slideshow/slideshow.glsl) as a full-frame pass: GLSL ES 3.00
// for WebGL2, and GLSL 450 compiled through glslangValidator and SPIRV-Cross to Metal, as
// switch.mjs wraps the switch transitions. slideshow-check.mjs draws it for the golden vectors,
// the audio identity check, the flash sequence and the contact frames; verify.mjs compiles it on
// every run, and bundle-legs.mjs ships it in the glsl300 and msl legs.
//
// Bindings: SlideshowBlock is buffer 0 (WebGL2: uniform block binding 0), 176 bytes std140:
//   pass0  = (p, style, aspect, motion)
//   pass1  = (amplitude, beatPhase, beatsPerSlide, 0)
//   size   = (width, height, 0, 0) of the target
//   slideA = (k, layout, direction, aspect0)   outgoing slide
//   extraA = (aspect1, 0, 0, 0)
//   rectA0 = (x0, y0, x1, y1) salient rect of the primary photo, photo uv
//   rectA1 = salient rect of the secondary photo (pair)
//   slideB, extraB, rectB0, rectB1             incoming slide, same layout
// Textures 0..3 are the outgoing primary and secondary and the incoming primary and secondary
// photos (bind the primary again when a slide has no secondary); sampler 0. Photos are linear
// (sRGB-decoded). Colour 0 is the linear HDR result. uv = gl_FragCoord.xy / size, so target row j
// is v = (j + 0.5) / height with row 0 first in memory on both WebGL2 and Metal, and photo row 0
// is v = 0.
//
// sampling 'linear' (default) reads through the hardware filter (clamp-to-edge; the blurred
// fill reads a mip level, so give photos mipmaps), as a host does. sampling 'fetch' reads level
// 0 bilinear by hand from texelFetch, so the conformance vectors do not depend on a GPU's
// fixed-point filter weights or mip generation.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileGLSLToSPV, PINNED_GLSLANG, PINNED_SPIRV_CROSS_STAMP, run, withTempDir } from './glsl2msl.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const SLIDESHOW_PATH = join(ROOT, 'shaders', 'slideshow', 'slideshow.glsl');
export const SLIDESHOW_FUNCTION = 'oscillux_slideshow';
export const SLIDESHOW_BLOCK_SIZE = 176;
export const SLIDESHOW_STYLES = Object.freeze(['dissolve', 'lightSweep', 'iris']);
export const SLIDESHOW_LAYOUTS = Object.freeze(['cover', 'fill', 'pair']);
const PHOTOS = ['uPhoto0', 'uPhoto1', 'uPhoto2', 'uPhoto3'];

const BLOCK = `    vec4 pass0;
    vec4 pass1;
    vec4 size;
    vec4 slideA;
    vec4 extraA;
    vec4 rectA0;
    vec4 rectA1;
    vec4 slideB;
    vec4 extraB;
    vec4 rectB0;
    vec4 rectB1;`;

function fetchTap(s) {
  return `    ivec2 n = textureSize(${s}, 0);
    vec2 f = uv * vec2(n) - 0.5;
    vec2 b = floor(f);
    vec2 a = f - b;
    ivec2 i0 = clamp(ivec2(b), ivec2(0), n - 1);
    ivec2 i1 = clamp(ivec2(b) + 1, ivec2(0), n - 1);
    vec3 c00 = texelFetch(${s}, ivec2(i0.x, i0.y), 0).rgb;
    vec3 c10 = texelFetch(${s}, ivec2(i1.x, i0.y), 0).rgb;
    vec3 c01 = texelFetch(${s}, ivec2(i0.x, i1.y), 0).rgb;
    vec3 c11 = texelFetch(${s}, ivec2(i1.x, i1.y), 0).rgb;
    return mix(mix(c00, c10, a.x), mix(c01, c11, a.x), a.y);`;
}

// Per-photo taps, and a dispatch on the photo index (textures cannot be indexed at run time).
function taps(sampling, tex) {
  const fns = PHOTOS.map((n, i) => {
    const s = tex(n);
    if (sampling === 'linear') {
      return `vec3 oscTap${i}(vec2 uv) { return textureLod(${s}, uv, 0.0).rgb; }
vec3 oscSoft${i}(vec2 uv, float r) {
    float lod = max(log2(r * float(textureSize(${s}, 0).y)) - 1.0, 0.0);
    return textureLod(${s}, uv, lod).rgb;
}`;
    }
    return `vec3 oscTap${i}(vec2 uv) {
${fetchTap(s)}
}
vec3 oscSoft${i}(vec2 uv, float r) { return oscTap${i}(uv); }`;
  });
  const pick = (fn, args) => `    if (i == 0) return ${fn}0(${args});
    if (i == 1) return ${fn}1(${args});
    if (i == 2) return ${fn}2(${args});
    return ${fn}3(${args});`;
  return `${fns.join('\n')}
vec3 oscSlideTap(int i, vec2 uv) {
${pick('oscTap', 'uv')}
}
vec3 oscSlideSoft(int i, vec2 uv, float r) {
${pick('oscSoft', 'uv, r')}
}`;
}

function pass(sampling, tex) {
  if (sampling !== 'linear' && sampling !== 'fetch') throw new Error(`slideshow: unknown sampling ${sampling}`);
  return `${taps(sampling, tex)}
#define OSC_SLIDE_TAP(i, uv) oscSlideTap(i, uv)
#define OSC_SLIDE_SOFT(i, uv, r) oscSlideSoft(i, uv, r)
${readFileSync(SLIDESHOW_PATH, 'utf8')}
SlideInputs oscSlideUnpack(vec4 slide, vec4 extra, vec4 r0, vec4 r1) {
    SlideInputs sl;
    sl.k = slide.x;
    sl.fit = int(slide.y + 0.5);
    sl.direction = slide.z;
    sl.aspect0 = slide.w;
    sl.aspect1 = extra.x;
    sl.rect0 = r0;
    sl.rect1 = r1;
    return sl;
}
void main() {
    vec2 uv = gl_FragCoord.xy / su.size.xy;
    SlideshowInputs s;
    s.p = su.pass0.x;
    s.style = int(su.pass0.y + 0.5);
    s.aspect = su.pass0.z;
    s.motion = su.pass0.w;
    s.amplitude = su.pass1.x;
    s.beatPhase = su.pass1.y;
    s.beatsPerSlide = su.pass1.z;
    s.size = su.size.xy;
    s.a = oscSlideUnpack(su.slideA, su.extraA, su.rectA0, su.rectA1);
    s.b = oscSlideUnpack(su.slideB, su.extraB, su.rectB0, su.rectB1);
    oColor = vec4(slideshow(uv, s), 1.0);
}
`;
}

/** The GLSL ES 3.00 fragment shader; uniforms uPhoto0..uPhoto3 and block SlideshowBlock. */
export function slideshowGLSL300({ sampling = 'linear' } = {}) {
  return `#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
layout(std140) uniform SlideshowBlock {
${BLOCK}
} su;
uniform sampler2D ${PHOTOS.join(', ')};
layout(location = 0) out vec4 oColor;
${pass(sampling, n => n)}`;
}

/** The GLSL 450 fragment shader that the Metal leg compiles. */
export function slideshowGLSL450({ sampling = 'linear' } = {}) {
  return `#version 450
layout(set = 0, binding = 0, std140) uniform SlideshowBlock {
${BLOCK}
} su;
${PHOTOS.map((n, i) => `layout(set = 0, binding = ${i}) uniform texture2D ${n};`).join('\n')}
layout(set = 0, binding = 0) uniform sampler uSamp;
layout(location = 0) out vec4 oColor;
${pass(sampling, n => `sampler2D(${n}, uSamp)`)}`;
}

/** Metal source with entry point SLIDESHOW_FUNCTION; checks the reflected bindings. */
export function slideshowMSL({ sampling = 'linear' } = {}) {
  return withTempDir('slideshow', dir => {
    const spv = compileGLSLToSPV(slideshowGLSL450({ sampling }), dir);
    const reflection = JSON.parse(run('spirv-cross', [spv, '--reflect']));
    const msl = run('spirv-cross', [
      spv, '--msl', '--msl-decoration-binding', '--msl-force-native-arrays',
      '--rename-entry-point', 'main', SLIDESHOW_FUNCTION, 'frag',
    ]);
    checkSlideshowABI(msl, reflection);
    return `// SPDX-License-Identifier: AGPL-3.0-only
// GENERATED from shaders/slideshow/slideshow.glsl by glslangValidator ${PINNED_GLSLANG} + SPIRV-Cross ${PINNED_SPIRV_CROSS_STAMP}.

${msl}`;
  });
}

function checkSlideshowABI(msl, reflection) {
  const need = [[reflection.ubos, 'SlideshowBlock', 0], [reflection.separate_samplers, 'uSamp', 0]];
  PHOTOS.forEach((n, i) => need.push([reflection.separate_images, n, i]));
  for (const [list, name, binding] of need) {
    const found = (list || []).find(r => r.name === name);
    if (!found || found.binding !== binding) throw new Error(`slideshow: SPIR-V binding of ${name} is not ${binding}`);
  }
  const ubo = reflection.ubos.find(r => r.name === 'SlideshowBlock');
  if (ubo.block_size !== SLIDESHOW_BLOCK_SIZE) throw new Error(`slideshow: SlideshowBlock is ${ubo.block_size} bytes`);
  const checks = [
    new RegExp(`fragment\\s+\\w+\\s+${SLIDESHOW_FUNCTION}\\(`),
    /\[\[buffer\(0\)\]\]/, /\[\[texture\(0\)\]\]/, /\[\[texture\(1\)\]\]/, /\[\[texture\(2\)\]\]/,
    /\[\[texture\(3\)\]\]/, /\[\[sampler\(0\)\]\]/, /\[\[color\(0\)\]\]/,
  ];
  for (const re of checks) if (!re.test(msl)) throw new Error(`slideshow: MSL has no ${re.source}`);
}

function index(list, v, what) {
  const id = typeof v === 'number' ? v : list.indexOf(v);
  if (id < 0 || id >= list.length) throw new Error(`slideshow: unknown ${what} ${v}`);
  return id;
}

const UNKNOWN_RECT = Object.freeze([0, 0, 0, 0]);

function slideWords({ k = 0, layout = 'cover', direction = 0, aspect0 = 1, aspect1 = aspect0, rect0 = UNKNOWN_RECT, rect1 = UNKNOWN_RECT } = {}) {
  return [k, index(SLIDESHOW_LAYOUTS, layout, 'layout'), direction, aspect0, aspect1, 0, 0, 0, ...rect0, ...rect1];
}

/**
 * The 176-byte SlideshowBlock for one draw. `a` and `b` are the outgoing and incoming slides:
 * { k, layout, direction, aspect0, aspect1, rect0, rect1 } (rects [x0, y0, x1, y1] in photo uv,
 * [0, 0, 0, 0] when unknown). Audio coupling is off unless amplitude > 0; beatsPerSlide is the
 * tempo in beats per second times the slide interval in seconds.
 */
export function slideshowBlock({ p = 0, style = 'dissolve', aspect, motion = 1, amplitude = 0, beatPhase = 0, beatsPerSlide = 1, width, height, a, b }) {
  return new Float32Array([
    p, index(SLIDESHOW_STYLES, style, 'style'), aspect, motion,
    amplitude, beatPhase, beatsPerSlide, 0,
    width, height, 0, 0,
    ...slideWords(a), ...slideWords(b ?? a),
  ]);
}
