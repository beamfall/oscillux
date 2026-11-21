// SPDX-License-Identifier: AGPL-3.0-only
// Silk Veil.
// Long sheets of sheer silk hang in a dim room and lift on a slow draught.
// Each sheet is a soft band of colour with a satin sheen along its fold; where
// two sheets cross their colours add like layered gauze. The sheets keep to
// the top and bottom of the frame and only their faintest edges cross the
// middle. Nothing is sharp and nothing moves quickly. Audio breathes the
// light: the loudness lifts the sheen a little and the level deepens the folds.
// param0 = Sheets (count) ; param1 = Draught (drift speed) ; param2 = Sheen

vec3 osBody(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float x = (uv.x - 0.5) * aspect;
    float y = 1.0 - uv.y;
    float sens = 0.5 + 0.5 * u.sensitivity;
    float breath = osCalmBreath(u);
    float t = u.time * mix(0.04, 0.16, u.param1);

    vec3 col = mix(osPalCalm(0.08, 14, u) * 0.03, osPalCalm(0.4, 14, u) * 0.015, y);
    int sheets = int(mix(3.0, 6.0, u.param0) + 0.5);
    for (int i = 0; i < 6; i++) {
        if (i >= sheets) break;
        float fi = float(i);
        // alternate sheets hang in the upper and lower thirds
        float home = mod(fi, 2.0) < 0.5 ? 0.80 - 0.05 * fi : 0.20 + 0.04 * fi;
        float wave = 0.10 * sin(x * (1.1 + 0.3 * fi) + t * (1.0 + 0.2 * fi) + fi * 1.9)
                   + 0.05 * sin(x * (2.3 + 0.4 * fi) - t * 0.7 + fi * 4.1)
                   + 0.06 * (fbm(vec2(x * 0.7 + fi * 3.3, t * 0.5 + fi)) - 0.5);
        float centre = home + wave;
        float width = 0.09 + 0.04 * sin(x * 0.9 + t * 0.6 + fi * 2.7);
        float dy = (y - centre) / width;
        float body = exp(-dy * dy);
        // the sheen rides just above the fold line and slides along it
        float fold = 0.5 + 0.5 * sin(x * 3.0 - t * 1.4 + fi * 2.2 + dy * 1.5);
        float sheen = exp(-(dy + 0.35) * (dy + 0.35) * 6.0) * fold;
        vec3 tint = osPalCalm(0.35 + fi * 0.11, 14, u);
        float shade = 0.07 * (0.9 + 0.4 * breath);
        col += tint * body * shade + mix(tint, vec3(luma(tint)), 0.5) * sheen
             * mix(0.03, 0.11, u.param2) * (0.8 + 0.4 * breath);
    }
    // a soft vignette keeps the corners quiet
    vec2 v = uv - 0.5;
    col *= 1.0 - 0.45 * dot(v, v) * 2.0;
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
