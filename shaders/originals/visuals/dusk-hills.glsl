// SPDX-License-Identifier: AGPL-3.0-only
// Dusk Hills.
// Layered hills fade into mist at the end of the day. Five ridges, each paler
// and bluer than the one in front of it, fill the bottom of the frame; the
// sun has just touched the farthest ridge and lights the haze around it, and
// a few long clouds drift high across a clear gradient sky. The view slides
// sideways so slowly that the near ridges barely pass the far ones. The sky
// above the ridges is left open for the lyrics. Audio breathes the light: the
// loudness warms the sun's glow and the level lifts the mist.
// param0 = Ridges (height) ; param1 = Drift (slide speed) ; param2 = Sun (position)

float dhRidge(float x, float seed) {
    return fbm(vec2(x + seed * 17.3, seed * 3.1)) * 0.7 + 0.3 * vnoise(vec2(x * 3.0, seed));
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float x = (uv.x - 0.5) * aspect;
    float y = 1.0 - uv.y;
    float breath = osCalmBreath(u);
    float slide = u.time * mix(0.004, 0.02, u.param1);

    vec3 high = osPalCalm(0.05, 11, u);
    vec3 low = osPalCalm(0.55, 11, u);
    vec3 sunC = mix(osPalCalm(0.75, 11, u), vec3(1.0, 0.85, 0.65), 0.35);

    // sky: deep overhead, warm toward the ridges
    vec3 col = mix(low * 0.14, high * 0.05, smoothstep(0.15, 0.95, y));
    vec2 sp = vec2(mix(-0.5, 0.5, u.param2) * aspect, 0.30);
    float sr = length(vec2(x, y) - sp);
    col += sunC * (exp(-sr * 4.0) * (0.10 + 0.05 * breath) + exp(-sr * 14.0) * 0.12);
    col += sunC * smoothstep(0.045, 0.040, sr) * 0.8;

    // long clouds high up, lit underneath by the sun
    float cy = (y - 0.82) * 9.0;
    float cloud = smoothstep(0.55, 0.8, fbm(vec2(x * 0.9 - u.time * 0.006, cy))) * exp(-cy * cy * 0.5);
    col = mix(col, low * 0.10 + sunC * 0.03, cloud * 0.7);

    // ridges, far to near: each lower, darker and slides a little faster
    float mist = 0.8 + 0.2 * saturate(u.level);
    float h = mix(0.7, 1.2, u.param0);
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float near = fi / 4.0;
        float base = mix(0.34, 0.06, near) * h;
        float top = base + mix(0.06, 0.14, near) * h * dhRidge(x * mix(0.8, 1.6, near) + slide * (0.3 + fi), fi);
        vec3 tone = mix(mix(low, high, 0.3) * 0.10 * mist + sunC * 0.03 * (1.0 - near), high * 0.012, near);
        float fill = smoothstep(top + 0.003, top - 0.003, y);
        // mist pools at the foot of each ridge
        float foot = exp(-max(y - base + 0.02, 0.0) * 30.0) * (1.0 - near) * 0.5;
        col = mix(col, tone + low * 0.04 * foot * mist, fill);
    }
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
