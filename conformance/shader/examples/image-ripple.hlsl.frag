#version 450
layout(set = 0, binding = 0) uniform VisualUniformBlock {
    vec2 resolution;
    float time;
    float dt;
    float amplitude;
    float bass;
    float mid;
    float treble;
    float beat;
    float beatPhase;
    float onset;
    float sensitivity;
    float param0;
    float param1;
    float param2;
    float level;
    float bassImpact;
    float spectralCentroid;
    float flux;
    float beatCount;
    float trailDecay;
    float barPhase;
    float downbeat;
    vec4 accent;
    vec4 motion;
    vec4 palette;
    vec4 presentation0;
    vec4 presentation1;
    vec4 safeRect;
    vec4 spectrum[16];
} ub;
layout(set = 0, binding = 0) uniform texture2D uImageTex;
layout(set = 0, binding = 1) uniform texture2D uPrevTex;
layout(set = 0, binding = 0) uniform sampler uSamp;
#define IMG(x) texture(sampler2D(uImageTex,uSamp),(x))
#define IMGSIZE vec2(textureSize(sampler2D(uImageTex,uSamp),0))
#define PREV(x) texture(sampler2D(uPrevTex,uSamp),(x))
struct VisualUniforms {
    vec2 resolution;
    float time;
    float dt;
    float amplitude;
    float bass;
    float mid;
    float treble;
    float beat;
    float beatPhase;
    float onset;
    float sensitivity;
    float param0;
    float param1;
    float param2;
    float level;
    float bassImpact;
    float spectralCentroid;
    float flux;
    float beatCount;
    float trailDecay;
    float barPhase;
    float downbeat;
    vec4 accent;
    vec4 motion;
    vec4 palette;
    vec4 presentation0;
    vec4 presentation1;
    vec4 safeRect;
    vec4 spectrum[16];
};
VisualUniforms loadUniforms() {
    VisualUniforms u;
    u.resolution = ub.resolution;
    u.time = ub.time;
    u.dt = ub.dt;
    u.amplitude = ub.amplitude;
    u.bass = ub.bass;
    u.mid = ub.mid;
    u.treble = ub.treble;
    u.beat = ub.beat;
    u.beatPhase = ub.beatPhase;
    u.onset = ub.onset;
    u.sensitivity = ub.sensitivity;
    u.param0 = ub.param0;
    u.param1 = ub.param1;
    u.param2 = ub.param2;
    u.level = ub.level;
    u.bassImpact = ub.bassImpact;
    u.spectralCentroid = ub.spectralCentroid;
    u.flux = ub.flux;
    u.beatCount = ub.beatCount;
    u.trailDecay = ub.trailDecay;
    u.barPhase = ub.barPhase;
    u.downbeat = ub.downbeat;
    u.accent = ub.accent;
    u.motion = ub.motion;
    u.palette = ub.palette;
    u.presentation0 = ub.presentation0;
    u.presentation1 = ub.presentation1;
    u.safeRect = ub.safeRect;
    for (int i = 0; i < 16; ++i) u.spectrum[i] = ub.spectrum[i];
    return u;
}
// SPDX-License-Identifier: AGPL-3.0-only
// Minimal example prelude for tools/shader. A host supplies its own; this one
// shows the contract (docs/shader-toolchain.md) and nothing more.

mat2 rot2(float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, -s, s, c);
}

// Zero non-finite channels and bound the HDR range.
vec3 sanitizeColor(vec3 c) {
    for (int i = 0; i < 3; ++i) {
        if (isnan(c[i]) || isinf(c[i])) c[i] = 0.0;
    }
    return clamp(c, 0.0, 16.0);
}

// Keep green from exceeding the brighter of red and blue by more than a margin.
vec3 suppressGreenCast(vec3 c) {
    c = sanitizeColor(c);
    c.g = min(c.g, max(c.r, c.b) * 1.1 + 0.02);
    return c;
}

float spectrumBin(VisualUniforms u, int i) {
    i = clamp(i, 0, 63);
    return u.spectrum[i / 4][i - (i / 4) * 4];
}

vec3 feedbackTrail(vec3 col, vec2 uv, float decay, float zoom, float rotAmt) {
    vec2 q = uv - 0.5;
    q = rot2(rotAmt) * q;
    q *= (1.0 - zoom);
    vec3 p = sanitizeColor(PREV(q + 0.5).rgb);
    float k = pow(clamp(decay, 0.0, 0.90), ub.dt > 0.0 ? ub.dt * 60.0 : 1.0);
    return sanitizeColor(max(sanitizeColor(col), p * k));
}
// SPDX-License-Identifier: AGPL-3.0-only
// Radial ripple over the input image, kicked by bass impact.
vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = uv - 0.5;
    float r = length(p);
    float wave = sin(r * 40.0 - u.time * 6.0) * (0.004 + 0.012 * u.bassImpact) * u.param1;
    vec3 col = IMG(uv + p / max(r, 1e-4) * wave).rgb;
    col *= 0.85 + 0.3 * u.level;
    return feedbackTrail(col, uv, u.trailDecay * 0.5, 0.0, 0.0);
}

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
void main() {
    VisualUniforms u = loadUniforms();
    outColor = vec4(sanitizeColor(visual(vUV, u)), 1.0);
    if (u.time < -1e20) outColor += IMG(vec2(0.0)) + PREV(vec2(0.0));
}
