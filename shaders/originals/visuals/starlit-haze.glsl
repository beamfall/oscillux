// SPDX-License-Identifier: AGPL-3.0-only
// Starlit Haze.
// A clear, moonless night far from any town. The band of the galaxy arcs
// across the upper sky, a soft glow of countless faint stars cut by dark dust
// lanes; brighter stars twinkle slowly around it, and the dark outline of a
// treeline runs along the bottom under a faint green-blue airglow. The whole
// sky turns very slowly about a pole off the top of the frame. The middle of
// the frame is empty sky. Audio breathes the light: the loudness swells the glow
// of the galaxy's core and the level lifts the airglow.
// param0 = Stars (density) ; param1 = Turn (sky rotation) ; param2 = Glow (galaxy brightness)

vec3 visual(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = vec2((uv.x - 0.5) * aspect, 1.0 - uv.y);
    float breath = osCalmBreath(u);

    // the sky turns about a pole above the frame
    vec2 pole = vec2(0.3 * aspect, 1.6);
    float ang = u.time * mix(0.0015, 0.008, u.param1);
    vec2 s = rot2(ang) * (p - pole) + pole;

    vec3 night = osPalCalm(0.05, 25, u);
    vec3 glowC = osPalCalm(0.55, 25, u);
    vec3 col = night * mix(0.04, 0.016, p.y);

    // the galaxy band: a gentle arc high across the sky
    float arc = s.y - (0.86 - 0.12 * s.x * s.x / max(aspect, 1.0) + 0.06 * s.x);
    float dust = fbm(s * vec2(3.0, 7.0) + 2.0);
    float lane = smoothstep(0.45, 0.7, fbm(s * vec2(5.0, 11.0) + 9.0));
    float band = exp(-arc * arc * 40.0) * (0.6 + 0.4 * dust) * (1.0 - 0.6 * lane);
    float core = exp(-dot(s - vec2(-0.25 * aspect, 0.85), s - vec2(-0.25 * aspect, 0.85)) * 6.0);
    float gain = mix(0.07, 0.16, u.param2);
    col += mix(glowC, vec3(luma(glowC)), 0.6) * band * gain * (1.0 + core * (0.8 + 0.4 * breath));

    // stars: denser in the band, each with a slow twinkle
    float dens = mix(0.985, 0.965, u.param0) - band * 0.02;
    for (int l = 0; l < 2; l++) {
        float sc = l == 0 ? 70.0 : 140.0;
        vec2 g = s * sc + float(l) * 17.0;
        vec2 id = floor(g);
        float h = hash21(id);
        if (h > dens) {
            vec2 off = hash22(id + 3.0) * 0.6 + 0.2;
            float r = length(fract(g) - off);
            float tw = 0.6 + 0.4 * sin(u.time * (0.4 + h * 0.8) + h * 40.0);
            vec3 sc3 = mix(vec3(0.8, 0.85, 1.0), glowC, 0.3);
            col += sc3 * smoothstep(0.35, 0.0, r) * tw * (l == 0 ? 0.18 : 0.07);
        }
    }

    // airglow over the horizon and the treeline in front of it
    col += osPalCalm(0.35, 25, u) * 0.045 * exp(-max(p.y - 0.1, 0.0) * 9.0) * (0.8 + 0.3 * saturate(u.level));
    float trees = 0.08 + 0.03 * fbm(vec2(p.x * 4.0, 1.0)) + 0.025 * pow(vnoise(vec2(p.x * 22.0, 3.0)), 3.0);
    col = mix(col, night * 0.003, smoothstep(trees + 0.003, trees - 0.003, p.y));
    return col; // LINEAR HDR — post chain tonemaps
}
