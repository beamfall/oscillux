#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
uniform sampler2D uImage;
uniform sampler2D uPrev;
#define IMG(x) texture(uImage,(x))
#define IMGSIZE vec2(textureSize(uImage,0))
#define PREV(x) texture(uPrev,(x))
// SPDX-License-Identifier: AGPL-3.0-only
// Minimal example prelude for tools/shader. A host supplies its own; this one
// shows the contract (docs/shader-toolchain.md) and nothing more.
struct VisualUniforms {
    vec2  resolution; float time; float dt;
    float amplitude; float bass; float mid; float treble;
    float beat; float beatPhase; float onset;
    float sensitivity; float param0; float param1; float param2;
    float level; float bassImpact; float spectralCentroid; float flux;
    float beatCount; float trailDecay; float barPhase; float downbeat;
    vec4 accent; vec4 motion; vec4 palette;
    vec4 presentation0; vec4 presentation1; vec4 safeRect;
    vec4 spectrum[16];
};

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

uniform VisualUniforms u;
vec3 feedbackTrail(vec3 col, vec2 uv, float decay, float zoom, float rotAmt) {
    float n = u.dt > 0.0 ? min(u.dt * 60.0, 4.0) : 1.0;
    vec2 q = uv - 0.5;
    q = rot2(rotAmt * n) * q;
    q *= pow(max(1.0 - zoom, 1e-4), n);
    vec2 s = q + 0.5;
    vec2 out2 = max(-s, s - 1.0);
    float inside = clamp(1.0 - 32.0 * max(max(out2.x, out2.y), 0.0), 0.0, 1.0);
    vec3 p = suppressGreenCast(PREV(s).rgb) * inside;
    float k = pow(clamp(decay, 0.0, 0.90), n);
    return suppressGreenCast(max(suppressGreenCast(col), p * k));
}
// SPDX-License-Identifier: AGPL-3.0-only
// Concentric rings driven by the spectrum, smeared by the feedback trail.
vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = (uv - 0.5) * vec2(u.resolution.x / max(u.resolution.y, 1.0), 1.0);
    float r = length(p);
    float e = spectrumBin(u, int(clamp(r * 1.6, 0.0, 0.999) * 64.0));
    float ring = smoothstep(0.06, 0.0, abs(fract(r * 8.0 - u.time * 0.5) - 0.5) - 0.12 * e);
    vec3 hue = 0.5 + 0.5 * cos(6.28318 * (u.palette.z + r + vec3(0.0, 0.33, 0.67)));
    vec3 col = hue * ring * (0.4 + 1.2 * e) + u.accent.rgb * u.beat * 0.15 * max(1.0 - r, 0.0);
    return feedbackTrail(col, uv, u.trailDecay, 0.01 + 0.02 * u.bass, 0.04 * (u.param0 - 0.5));
}

in vec2 vUV;
layout(location=0) out vec4 fragColor;
void main() {
    fragColor = vec4(suppressGreenCast(visual(vUV, u)), 1.0);
}
