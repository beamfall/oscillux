// SPDX-License-Identifier: AGPL-3.0-only
// Snowfall.
// Snow falling on a windless night under a single old street lamp. Flakes
// come down at three depths: far ones are fine and slow, near ones large,
// soft and out of focus, each turning on its own gentle sway. The lamp
// stands at one side of the frame and warms the flakes that pass through its
// light; the rest are lit only by the cool sky, and a soft drift of fallen
// snow glows faintly along the bottom. Audio breathes the lamp: the loudness
// swells its glow a little and the level lifts the snowlight.
// param0 = Snow (density) ; param1 = Fall (speed) ; param2 = Lamp (position)

vec3 osBody(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = vec2((uv.x - 0.5) * aspect, 1.0 - uv.y);
    float breath = osCalmBreath(u);
    float fall = u.time * mix(0.03, 0.09, u.param1);

    vec3 night = osPalCalm(0.1, 13, u);
    vec3 lampC = mix(osPalCalm(0.75, 13, u), vec3(1.0, 0.8, 0.55), 0.6);
    vec3 snowC = mix(osPalCalm(0.4, 13, u), vec3(0.85, 0.9, 1.0), 0.7);

    vec3 col = night * mix(0.025, 0.01, p.y);
    // the lamp: a warm pool of light high at one side
    vec2 lp = vec2(mix(-0.7, 0.7, u.param2) * aspect * 0.5 + (u.param2 < 0.5 ? -0.15 : 0.15) * aspect, 0.78);
    float lr = length(p - lp);
    float pool = exp(-lr * 3.5) * (0.08 + 0.04 * breath);
    col += lampC * pool + lampC * exp(-lr * 40.0) * 0.5;

    // flakes at three depths
    float dens = mix(0.25, 0.6, u.param0);
    for (int l = 0; l < 3; l++) {
        float fl = float(l);
        float scale = mix(18.0, 6.0, fl / 2.0);
        float speed = mix(0.6, 1.4, fl / 2.0);
        vec2 q = vec2(p.x * scale, (p.y + fall * speed) * scale);
        vec2 id = floor(q);
        vec2 sd = id + fl * 19.3;
        if (hash21(sd) < dens) {
            vec2 off = hash22(sd + 1.0) * 0.6 + 0.2;
            off.x += 0.15 * sin(u.time * 0.5 + hash21(sd + 2.0) * 6.2832);
            float r = length(fract(q) - off);
            float size = mix(0.08, 0.28, fl / 2.0);
            float flake = smoothstep(size, size * mix(0.4, 0.05, fl / 2.0), r);
            // flakes in the lamp's pool are warm and brighter
            vec3 lit = snowC * 0.05 + lampC * pool * 1.6;
            col += lit * flake * mix(0.6, 1.0, fl / 2.0);
        }
    }

    // fallen snow along the bottom
    float drift = 0.08 + 0.025 * fbm(vec2(p.x * 1.8, 2.0));
    float ground = smoothstep(drift + 0.006, drift - 0.006, p.y);
    vec3 groundC = snowC * 0.04 * (0.85 + 0.3 * saturate(u.level)) + lampC * exp(-abs(p.x - lp.x) * 2.5) * 0.04;
    col = mix(col, groundC, ground);
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
