// SPDX-License-Identifier: AGPL-3.0-only
// Sunlit Shallows.
// Under clear, shallow water on a bright day. Above, the rippled surface
// glows; below it, broad soft shafts of light slant down through the water
// and sway with the waves, fine motes hang and drift in them, and a pale sand
// floor at the bottom carries a slowly crawling net of caustics. The shafts
// fade before they reach the middle of the frame, so the water there is a
// clear, even blue. Audio breathes the light: the loudness swells the water's
// glow, the shafts and the caustics, and the level brightens the surface.
// param0 = Shafts (count) ; param1 = Current (sway speed) ; param2 = Depth (water tint)

// Two crossed, warped ridge fields make a caustic net that never repeats.
float ssCaustic(vec2 p, float t) {
    vec2 w = vec2(vnoise(p * 1.3 + t * 0.3), vnoise(p * 1.3 - t * 0.25 + 4.0));
    p += (w - 0.5) * 1.2;
    float a = 1.0 - abs(sin(p.x * 2.1 + t * 0.4 + sin(p.y * 1.7)));
    float b = 1.0 - abs(sin(p.y * 2.4 - t * 0.35 + sin(p.x * 1.4 + 1.0)));
    return pow(a * b, 3.0);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float x = (uv.x - 0.5) * aspect;
    float y = 1.0 - uv.y;
    float breath = osCalmBreath(u);
    float t = u.time * mix(0.15, 0.5, u.param1);

    vec3 deep = osPalCalm(0.15, 21, u);
    vec3 shallow = osPalCalm(0.45, 21, u);
    vec3 sun = mix(osPalCalm(0.85, 21, u), vec3(1.0, 0.95, 0.8), 0.6);
    vec3 water = mix(shallow, deep, mix(0.3, 0.8, u.param2));

    // the water column: brighter toward the surface
    vec3 col = water * mix(0.03, 0.11, smoothstep(0.1, 1.0, y)) * (0.9 + 0.25 * breath);

    // the surface, seen from below: a bright rippled ceiling
    float surf = smoothstep(0.88, 0.97, y);
    float ripple = vnoise(vec2(x * 7.0 + t * 0.6, y * 30.0 - t)) * vnoise(vec2(x * 13.0 - t * 0.4, y * 18.0));
    col += mix(water, sun, 0.4) * surf * (0.10 + 0.20 * ripple) * (0.85 + 0.2 * saturate(u.level));

    // shafts: slanted soft bands from the surface, each swaying slowly
    float n = mix(4.0, 9.0, u.param0);
    float sx = x + (1.0 - y) * 0.35;               // slant
    float shafts = 0.0;
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        if (fi >= n) break;
        float c = (hash11(fi * 7.3) - 0.5) * aspect * 1.3 + 0.08 * sin(t * 0.5 + fi * 1.7);
        float w = mix(0.03, 0.09, hash11(fi * 3.1 + 1.0));
        float d = (sx - c) / w;
        shafts += exp(-d * d) * (0.5 + 0.5 * sin(t * 0.7 + fi * 2.3));
    }
    // they fade with depth, well above the middle of the frame
    float reach = smoothstep(0.55, 0.95, y);
    col += mix(water, sun, 0.5) * shafts * reach * 0.05 * (0.8 + 0.4 * breath);

    // motes: tiny, slow, only where a shaft lights them
    vec2 mq = vec2(x, y) * 60.0 + vec2(t * 0.8, t * 0.3);
    float mote = step(0.985, hash21(floor(mq))) * smoothstep(0.5, 0.0, length(fract(mq) - 0.5));
    col += sun * mote * shafts * reach * 0.15;

    // the sand floor and its caustics
    float floorLine = 0.17 + 0.02 * sin(x * 2.0 + 1.0) + 0.015 * vnoise(vec2(x * 6.0, 0.0));
    float sand = smoothstep(floorLine + 0.01, floorLine - 0.01, y);
    vec3 sandC = mix(osPalCalm(0.7, 21, u), vec3(0.85, 0.78, 0.6), 0.6) * 0.06;
    float caus = ssCaustic(vec2(x, y * 2.5) * 3.0, t);
    vec3 floorC = sandC * (0.7 + 0.3 * vnoise(vec2(x, y) * 40.0)) + sun * caus * 0.06 * (0.8 + 0.4 * breath);
    col = mix(col, floorC * mix(1.0, 0.5, smoothstep(floorLine, 0.0, y)), sand);
    return col; // LINEAR HDR — post chain tonemaps
}
