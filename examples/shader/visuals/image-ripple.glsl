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
