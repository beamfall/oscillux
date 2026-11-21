// SPDX-License-Identifier: AGPL-3.0-only
// Falling beams.
// Soft shafts of light fall at a shared lean through a dark room, widening
// as they come down, with fine streaks sliding along them and dust motes
// that only show where a shaft catches them. It is an ambient picture for a
// quiet screen: it moves on time alone and needs no audio. Fill lights the
// shafts one after another and warms them, so a host can map its own 0..1
// progress onto it. Audio, when there is any, only breathes the light.
// param0 = Fill (shafts lit, warmth) ; param1 = Tilt (lean) ; param2 = Dust (motes)

vec3 osBody(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = vec2((uv.x - 0.5) * aspect, uv.y); // y runs down from the top
    float t = u.time;
    float fill = saturate(u.param0);
    float tilt = mix(0.10, 0.50, u.param1);
    float breath = osCalmBreath(u);

    vec3 night = osPalCalm(0.08, 7, u);
    vec3 cool = mix(osPalCalm(0.35, 7, u), vec3(0.035, 0.26, 0.38), 0.85);
    vec3 warm = mix(osPalCalm(0.8, 7, u), vec3(0.347, 0.686, 0.781), 0.7);

    // the shafts: each is lit across one seventh of Fill, two are always on
    vec3 light = vec3(0.0);
    float beams = 0.0;
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        float on = smoothstep(0.0, 1.0, clamp(2.0 + fill * 7.0 - fi, 0.0, 1.0));
        float h1 = hash11(fi * 7.13 + 1.7);
        float h2 = hash11(fi * 3.71 + 9.2);
        float x0 = (h1 - 0.5) * aspect * 1.3 - tilt * 0.5;
        float sway = 0.02 * sin(t * (0.11 + 0.07 * h2) + h1 * 6.2832);
        float d = p.x - (x0 + sway + tilt * p.y);
        float w = mix(0.035, 0.10, h2) * (1.0 + 1.4 * p.y);
        float core = exp(-d * d / (w * w));
        float streak = 0.72 + 0.28 * vnoise(vec2(d * 38.0 + fi * 11.0, p.y * 2.2 - t * (0.08 + 0.06 * h2)));
        float fade = 1.0 - 0.85 * smoothstep(-0.25, 1.0, p.y);
        float slow = 0.75 + 0.25 * sin(t * (0.17 + 0.11 * h1) + h2 * 6.2832);
        float b = core * streak * fade * slow * on * mix(0.5, 1.0, h2);
        float warmth = saturate(fill * 1.25 - 0.2 + (h1 - 0.5) * 0.45);
        light += mix(cool, warm, warmth) * b;
        beams += b;
    }

    vec3 col = night * mix(0.03, 0.008, p.y);
    col += light * (0.30 + 0.5 * breath);

    // haze drifting through the lit air
    float haze = fbm(vec2(p.x * 1.6 + t * 0.015, p.y * 2.4 - t * 0.02));
    col += light * haze * 0.18;

    // dust at two depths, seen only inside a shaft
    float dens = mix(0.05, 0.4, u.param2);
    for (int l = 0; l < 2; l++) {
        float fl = float(l);
        float scale = mix(26.0, 12.0, fl);
        vec2 q = vec2(p.x * scale + 0.3 * sin(t * 0.1 + fl), (p.y - t * mix(0.012, 0.025, fl)) * scale);
        vec2 id = floor(q) + fl * 23.7;
        if (hash21(id) < dens) {
            vec2 off = hash22(id + 1.0) * 0.6 + 0.2;
            off.x += 0.12 * sin(t * 0.4 + hash21(id + 2.0) * 6.2832);
            float r = length(fract(q) - off);
            float size = mix(0.05, 0.11, fl);
            float mote = 1.0 - smoothstep(size * 0.2, size, r);
            float twinkle = 0.6 + 0.4 * sin(t * 0.8 + hash21(id + 3.0) * 6.2832);
            col += light * mote * twinkle * mix(0.5, 0.9, fl);
        }
    }

    // a soft glow where the shafts enter at the top
    col += mix(cool, warm, fill) * exp(-p.y * 5.0) * (0.02 + 0.05 * fill) * saturate(beams + 0.3);
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
