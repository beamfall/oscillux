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
