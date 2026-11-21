// SPDX-License-Identifier: AGPL-3.0-only
// Pastel Drift.
// A field of soft colour with no edges at all: five broad pools of pastel
// light wander on slow, looping paths and blend into one another like dye in
// still water, under a faint grain and a gentle, lazy warp. It never shows a
// line, a point or a flash, so it sits quietly behind anything drawn over it.
// Audio breathes the pools: the loudness widens them a little and swells their
// light, and the level lifts the overall light.
// param0 = Pools (blend softness) ; param1 = Wander (speed) ; param2 = Tone (brightness)

vec3 osBody(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = vec2((uv.x - 0.5) * aspect, uv.y - 0.5);
    float breath = osCalmBreath(u);
    float t = u.time * mix(0.03, 0.12, u.param1);

    // a lazy warp so the pools' edges are never perfect circles
    p += 0.06 * vec2(vnoise(p * 2.0 + t), vnoise(p * 2.0 - t + 5.0)) - 0.03;

    // weighted blend of the pools' colours (inverse-square of distance)
    float soft = mix(0.04, 0.16, u.param0) * (1.0 + 0.08 * breath);
    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        vec2 c = vec2(sin(t * (0.7 + 0.13 * fi) + fi * 1.9) * aspect * 0.42,
                      cos(t * (0.5 + 0.11 * fi) + fi * 2.7) * 0.40);
        vec2 d = p - c;
        float w = 1.0 / (dot(d, d) + soft);
        w *= w;                                    // sharper falloff keeps each pool's own colour
        // pink to lavender to sky to mint: the warm yellow end goes olive when dimmed
        acc += osPalCalm(0.04 + fi * 0.15, 19, u) * w;
        wsum += w;
    }
    vec3 c = acc / wsum;
    // pastel: lifted toward white, then scaled into a calm range
    c = mix(c, vec3(1.0), 0.2);
    vec3 col = c * mix(0.07, 0.16, u.param2) * (0.85 + 0.2 * saturate(u.level)) * (0.92 + 0.16 * breath);
    // a faint grain hides banding in the gradients
    col *= 0.97 + 0.06 * hash21(floor(uv * u.resolution));
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
