// SPDX-License-Identifier: AGPL-3.0-only
// Moonlit Tide.
// A still night over open water. A low moon sits high in one corner behind a
// thin veil of cloud, and its light falls in a long broken path across slow
// swells that roll toward the viewer. The sky is a soft gradient from deep
// blue at the top to a pale haze on the horizon, and the middle of the frame
// stays dark and quiet. Nothing moves faster than a slow tide. Audio only
// breathes the light: the loudness swells the moon's halo and the glitter on its
// path, and the song's level lifts the haze.
// param0 = Swell (wave height) ; param1 = Drift (tide speed) ; param2 = Moon (position)

float mtWave(vec2 p, float t) {
    // three long crests, each turned a little, travel toward the viewer
    float h = 0.0;
    h += sin(p.y * 9.0 - t * 0.9 + sin(p.x * 1.3) * 0.8) * 0.5;
    h += sin(p.y * 15.0 + p.x * 3.0 - t * 1.3) * 0.25;
    h += (vnoise(vec2(p.x * 6.0, p.y * 22.0 - t * 0.7)) - 0.5) * 0.5;
    return h;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float y = 1.0 - uv.y;                        // 0 at the bottom, 1 at the top
    float x = (uv.x - 0.5) * aspect;
    float t = u.time * mix(0.25, 0.8, u.param1);
    float breath = osCalmBreath(u);
    float horizon = 0.36;

    vec3 deep = osPalCalm(0.02, 9, u);
    vec3 haze = osPalCalm(0.55, 9, u);
    vec3 moonC = mix(osPalCalm(0.85, 9, u), vec3(luma(osPalCalm(0.85, 9, u))), 0.55);

    // ---- sky: gradient, a cloud veil and a few faint stars ----
    float sy = saturate((y - horizon) / (1.0 - horizon));
    vec3 col = mix(haze * 0.20, deep * 0.10, pow(sy, 0.6));
    col *= 0.75 + 0.25 * saturate(u.level);
    vec2 mp = vec2(mix(-0.55, 0.55, u.param2) * aspect, 0.86);
    vec2 d = vec2(x, y) - mp;
    float r = length(d);
    float veil = fbm(vec2(x * 1.6 + u.time * 0.02, y * 4.0));
    float disc = smoothstep(0.052, 0.046, r);
    float halo = exp(-r * 7.0) * (0.22 + 0.12 * breath) + exp(-r * 2.2) * 0.05;
    col += moonC * (disc * 0.9 * (1.0 - 0.35 * veil) + halo);
    col = mix(col, haze * 0.16, smoothstep(0.45, 0.8, veil) * 0.45 * smoothstep(horizon, horizon + 0.25, y));
    vec2 sc = floor(vec2(x, y) * 90.0);
    float star = step(0.992, hash21(sc)) * smoothstep(horizon + 0.15, 0.9, y);
    star *= 0.5 + 0.5 * sin(u.time * 0.6 + hash21(sc + 3.1) * 6.283);
    col += moonC * star * 0.10 * (1.0 - disc);

    // ---- water: perspective swells with the moon's path ----
    if (y < horizon) {
        float depth = (horizon - y) / horizon;   // 0 at the horizon, 1 at the bottom
        float z = 1.0 / max(depth, 0.02);
        vec2 wp = vec2(x * z * 0.35, z * 0.25);
        float amp = mix(0.4, 1.2, u.param0);
        float h = mtWave(wp, t) * amp;
        float hx = mtWave(wp + vec2(0.02, 0.0), t) * amp - h;
        // a darker body, lighter on the faces that tilt toward the sky
        vec3 water = mix(deep * 0.08, haze * 0.12, saturate(0.5 + 0.35 * h));
        // the moon's path widens toward the viewer and breaks on each crest
        float pq = (x - mp.x) / (0.05 + 0.32 * depth);
        float path = exp(-pq * pq);
        float glint = smoothstep(0.35, 0.9, h + hx * 4.0) * path;
        float sparkle = step(0.86, vnoise(wp * vec2(14.0, 3.0) + vec2(0.0, -t * 2.0)));
        water += moonC * glint * (0.10 + 0.08 * breath) * (0.6 + 0.4 * sparkle);
        water += haze * 0.07 * exp(-depth * 6.0);   // horizon mist
        // a hair of blur at the horizon line
        col = mix(water, col, smoothstep(0.006, 0.0, horizon - y));
    }

    // the middle band, where lyrics sit, stays the quietest part of the frame
    float lyric = smoothstep(0.16, 0.0, abs(uv.y - 0.55) - 0.22) * smoothstep(0.55, 0.2, abs(uv.x - 0.5));
    col *= 1.0 - 0.25 * lyric;
    return col; // LINEAR HDR — post chain tonemaps
}
