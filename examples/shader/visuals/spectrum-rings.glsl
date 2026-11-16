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
