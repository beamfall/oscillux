// SPDX-License-Identifier: AGPL-3.0-only
// Present bloom (CORE-0108): the five-level chain whose result the present pass adds before its
// tone map. tools/shader/present.mjs wraps this body once per stage (bloomGLSL300, bloomMSL)
// with BLOOM_STAGE defined, and exports the pass graph as PRESENT_BLOOM_GRAPH:
//
//   prefilter  scene (full size)  -> L0 (1/2)   soft-knee threshold, Karis-weighted 13-tap down
//   down       L0 -> L1 (1/4), L1 -> L2 (1/8), L2 -> L3 (1/16), L3 -> L4 (1/32)   13-tap down
//   up         L4 -> L3, L3 -> L2, L2 -> L1, L1 -> L0   9-tap tent, blended additively (ONE, ONE)
//                                                       onto the level's downsampled content
//
// The present pass then samples L0 (texture 4) and adds post0.x times it in linear light. All
// five levels are rgba16f, linear filtering, clamp to edge.
//
// The wrapper declares:
//   vUV              viewport position of the destination pixel, origin top-left, y down
//   BLOOM_SRC(uv)    the source level (prefilter: the incoming frame), texture 0, sampler 0
//   BLOOM_SRC_B(uv)  prefilter only: the outgoing frame during a switch, texture 1
//   bu.bloom0        (1 / source width, 1 / source height, threshold, knee)
//   bu.bloom1        (eased switch progress or 1, up-sample radius in source texels, 0, 0)
//   oColor           the stage's output (rgb; alpha 1)
//
// BLOOM_STAGE is 0 (prefilter), 1 (down) or 2 (up).

const vec3 BLOOM_LUMA = vec3(0.2126, 0.7152, 0.0722);

vec3 bloomTap(vec2 uv) {
#if BLOOM_STAGE == 0
    // The switch's two frames mixed by the eased progress: the present pass's dissolve without
    // its drift, which a blurred term does not need.
    float e = bu.bloom1.x;
    vec3 a = BLOOM_SRC(uv).rgb;
    return e >= 1.0 ? a : mix(BLOOM_SRC_B(uv).rgb, a, e);
#else
    return BLOOM_SRC(uv).rgb;
#endif
}

// Weight of a 2x2 box in the first down-sample: 1 / (1 + luma), so one very bright texel cannot
// flicker as a block (Karis average).
float bloomKaris(vec3 c) { return 1.0 / (1.0 + dot(c, BLOOM_LUMA)); }

// The 13-tap down-sample: a centre 2x2 box weighted 1/2 and four overlapping corner boxes
// weighted 1/8 each, from bilinear taps at whole and half texel offsets.
vec3 bloomDown(vec2 uv, vec2 t, bool karis) {
    vec3 a = bloomTap(uv + t * vec2(-2.0, -2.0));
    vec3 b = bloomTap(uv + t * vec2(0.0, -2.0));
    vec3 c = bloomTap(uv + t * vec2(2.0, -2.0));
    vec3 d = bloomTap(uv + t * vec2(-1.0, -1.0));
    vec3 e = bloomTap(uv + t * vec2(1.0, -1.0));
    vec3 f = bloomTap(uv + t * vec2(-2.0, 0.0));
    vec3 g = bloomTap(uv);
    vec3 h = bloomTap(uv + t * vec2(2.0, 0.0));
    vec3 i = bloomTap(uv + t * vec2(-1.0, 1.0));
    vec3 j = bloomTap(uv + t * vec2(1.0, 1.0));
    vec3 k = bloomTap(uv + t * vec2(-2.0, 2.0));
    vec3 l = bloomTap(uv + t * vec2(0.0, 2.0));
    vec3 m = bloomTap(uv + t * vec2(2.0, 2.0));
    vec3 box0 = (d + e + i + j) * 0.25;
    vec3 box1 = (a + b + f + g) * 0.25;
    vec3 box2 = (b + c + g + h) * 0.25;
    vec3 box3 = (f + g + k + l) * 0.25;
    vec3 box4 = (g + h + l + m) * 0.25;
    vec4 w = vec4(0.125);
    float w0 = 0.5;
    if (karis) {
        w0 *= bloomKaris(box0);
        w *= vec4(bloomKaris(box1), bloomKaris(box2), bloomKaris(box3), bloomKaris(box4));
    }
    vec3 sum = box0 * w0 + box1 * w.x + box2 * w.y + box3 * w.z + box4 * w.w;
    return sum / (w0 + w.x + w.y + w.z + w.w);
}

// Soft-knee threshold on the brightest channel: nothing below threshold - knee, all of the
// excess above threshold + knee, a quadratic between; the colour's ratios are kept.
vec3 bloomKnee(vec3 c, float threshold, float knee) {
    float br = max(c.r, max(c.g, c.b));
    float soft = clamp(br - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-5);
    return c * (max(soft, br - threshold) / max(br, 1e-5));
}

// The 9-tap tent (1 2 1 / 2 4 2 / 1 2 1) / 16 at radius r source texels.
vec3 bloomUp(vec2 uv, vec2 t) {
    vec3 s = bloomTap(uv) * 4.0;
    s += (bloomTap(uv + vec2(-t.x, 0.0)) + bloomTap(uv + vec2(t.x, 0.0))
        + bloomTap(uv + vec2(0.0, -t.y)) + bloomTap(uv + vec2(0.0, t.y))) * 2.0;
    s += bloomTap(uv - t) + bloomTap(uv + t) + bloomTap(uv + vec2(-t.x, t.y)) + bloomTap(uv + vec2(t.x, -t.y));
    return s * (1.0 / 16.0);
}

void main() {
    vec2 t = bu.bloom0.xy;
#if BLOOM_STAGE == 0
    vec3 c = bloomKnee(bloomDown(vUV, t, true), bu.bloom0.z, max(bu.bloom0.w, 1e-4));
#elif BLOOM_STAGE == 1
    vec3 c = bloomDown(vUV, t, false);
#else
    vec3 c = bloomUp(vUV, t * bu.bloom1.y);
#endif
    oColor = vec4(max(c, 0.0), 1.0);
}
