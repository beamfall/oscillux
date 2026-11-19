// SPDX-License-Identifier: AGPL-3.0-only
// Aurora — frequency + beat.
//
// A night landscape: soft aurora curtains and a thin, static starfield fill
// the sky behind two mountain ranges, and a still lake below the shore holds
// a dim, rippled reflection of the sky and the ridges. Each curtain is a
// glowing lower edge with rays streaking upward, lit by the spectrum across
// the width of the frame. The music moves the curtains (sway and a wave that
// travels along them) and swells their brightness slowly around each beat.
// param0 Curtains -> 3..5 curtain layers
// param1 Sway     -> undulation amplitude
// param2 Altitude -> how high the rays reach

// Ridge tops in y-down coordinates (smaller y is higher on screen).
float auroraPeak(float x) { return 1.0 - abs(sin(x)); }  // sharp crests, round valleys

float auroraFarRidge(float x, float horizonY) {
    float h = 0.15 + 0.05 * sin(x * 0.9 + 1.0)
            + 0.10 * auroraPeak(x * 1.7 + 0.3) * (0.6 + 0.4 * sin(x * 0.5 + 2.0))
            + 0.030 * auroraPeak(x * 4.3 + 1.1)
            + 0.030 * fbm(vec2(x * 6.0 + 2.3, 7.1));
    return horizonY - h;
}

float auroraNearRidge(float x, float horizonY) {
    float flank = smoothstep(0.45, 1.70, abs(x + 0.20));
    float h = 0.025 + 0.030 * auroraPeak(x * 2.1 + 0.7)
            + 0.15 * flank * (0.65 + 0.35 * sin(x * 1.9 + 1.3))
            + 0.020 * fbm(vec2(x * 9.0 + 9.2, 3.4));
    return horizonY - h;
}

// Sky light at q: night gradient plus the curtains (no stars, no land).
vec3 auroraSky(vec2 q, VisualUniforms u, int nCurtains, float swayAmt,
               float altitude, float swell, float horizonY) {
    float t = u.time;
    float skyT = saturate((q.y + 1.0) / (horizonY + 1.0));
    vec3 col = palVisual(0.30 + 0.04 * u.spectralCentroid, u)
             * (0.004 + 0.036 * skyT * skyT * skyT) * (0.75 + 0.25 * u.level);

    vec3 aur = vec3(0.0);
    for (int ci = 0; ci < 5; ci++) {
        if (ci >= nCurtains) break;
        float fi = float(ci);
        float fr = (fi + 0.5) / float(nCurtains);

        // farther curtains sit higher on screen and render dimmer
        float depth = mix(1.0, 0.50, fr);
        float baseY = mix(0.42, -0.40, fr);

        // spectrum drive across the frame width
        float xb = saturate(q.x * 0.26 + 0.5);
        float energy = bandAt(u, fr * 0.22 + xb * 0.58);

        // undulating lower edge; the music widens the sway and sends a wave along it
        float sway = sin(q.x * 0.65 - t * 0.21 + fi * 4.0) * 0.90
                   + sin(q.x * 1.5 + t * 0.47 + fi * 2.3) * 0.50
                   + sin(q.x * 3.1 - t * 0.31 + fi * 1.1) * 0.22;
        sway += (fbm(vec2(q.x * 0.85 + fi * 7.0, t * 0.10 + fi * 3.3)) - 0.5) * 2.2;
        float yc = baseY + sway * swayAmt * (0.85 + 0.25 * u.level + 0.10 * swell);
        yc += 0.020 * (0.4 + 0.6 * swell) * sin(q.x * 3.4 - u.beatPhase * 6.2831853 + fi * 1.7);

        float d = q.y - yc;              // >0 below the edge, <0 in the rays
        float above = max(-d, 0.0);

        // vertical ray striations; brighter rays reach higher
        float rays = fbmRidged(vec2(q.x * (4.0 + fi * 0.8) + fi * 11.0 + sway * 0.6,
                                    t * 0.12 + fi * 5.0));
        rays = smoothstep(0.15, 0.95, rays + energy * 0.10);
        float reach = 0.20 * altitude * (0.55 + 0.90 * rays);

        // soft lower edge (continuous at d = 0) and rays fading upward
        float lower = d / 0.045;
        float body = d > 0.0 ? exp(-lower * lower) : exp(-above / reach);
        float edge = exp(-d * d * 1100.0);

        // curtain presence: wide, soft gaps between folds
        float pres = smoothstep(0.30, 0.72,
                     fbm(vec2(q.x * 0.40 + fi * 13.7, t * 0.04 + fi)) + energy * 0.06);

        float bright = depth * pres * (0.62 + 0.22 * energy + 0.12 * swell);

        // teal at the lower edge, cooling to blue in the high rays
        float hue = 0.05 * u.spectralCentroid + 0.025 * sin(t * 0.07 + fi * 1.9);
        vec3 cLow = palVisual(0.50 + 0.03 * fr + hue, u);
        vec3 cHigh = palVisual(0.30 + 0.04 * fr + hue, u);
        vec3 c = mix(cLow, cHigh, saturate(above * 1.6 / altitude));
        c = accentize(c, u.accent, 0.08);

        // treble shimmer drifting along the lower edge
        float shimmer = smoothstep(0.55, 0.90,
                        vnoise(vec2(q.x * 6.0 - t * 1.4 + fi * 5.0, fi * 3.0)));

        aur += c * bright * (body * (0.10 + 0.55 * rays)
                           + edge * (0.06 + 0.16 * rays) * (1.0 + 0.8 * shimmer * u.treble));
    }
    // overlapping folds blend instead of stacking into hot seams
    float peak = max(aur.r, max(aur.g, aur.b));
    aur *= 1.0 / (1.0 + 0.55 * peak);
    return col + aur;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    // y-down coords: p.y = -1 top of screen, +1 bottom.

    int nCurtains = int(mix(3.0, 5.0, u.param0) + 0.5);
    float swayAmt = mix(0.10, 0.28, u.param1);
    float altitude = mix(0.60, 1.30, u.param2);
    float t = u.time;
    float horizonY = 0.70;
    float px = 2.0 / max(u.resolution.y, 1.0);

    // Smooth swell around each beat: continuous across the phase wrap,
    // ~250 ms rise to a peak just after the beat and ~250 ms fall.
    float swell = 0.5 + 0.5 * cos(6.2831853 * (u.beatPhase - 0.15));
    swell *= swell;

    // Below the shore, look up the mirrored sky through gentle ripples.
    float water = step(horizonY, p.y);
    float w = max(p.y - horizonY, 0.0);
    float rz = 1.0 / (w + 0.05);
    vec2 q = p;
    if (water > 0.5) {
        q.y = horizonY - w * 1.8;   // foreshortened mirror
        q.x += (0.002 + 0.040 * w) * (vnoise(vec2(p.x * 2.5, rz * 5.0 + t * 0.35)) - 0.5) * 2.0;
        q.y += (0.002 + 0.020 * w) * (vnoise(vec2(p.x * 1.5 + 5.0, rz * 8.0 - t * 0.30)) - 0.5) * 2.0;
    }

    vec3 sky = auroraSky(q, u, nCurtains, swayAmt, altitude, swell, horizonY);
    vec3 skyLight = sky;  // what the land catches: curtains and sky glow, no stars

    // Stars: sparse, fixed in place, twinkling slowly; fainter near the horizon.
    if (water < 0.5) {
        vec2 cell = floor(p * vec2(34.0, 20.0));
        float seed = hash21(cell + 7.0);
        vec2 sPos = (cell + 0.15 + 0.7 * hash22(cell)) / vec2(34.0, 20.0);
        vec2 sd = p - sPos;
        float mag = hash21(cell + 19.0);
        float twinkle = 0.80 + 0.20 * sin(t * (0.5 + mag * 0.9) + seed * 40.0);
        float star = exp(-dot(sd, sd) * 30000.0) * step(0.89, seed)
                   * (0.25 + 0.75 * mag * mag) * twinkle;
        float extinction = 1.0 - smoothstep(-0.2, horizonY, p.y);
        sky += vec3(0.70, 0.82, 1.0) * star * 0.55 * extinction;
    }

    // Land: a hazy far range and a dark near range occlude everything behind them.
    float farY = auroraFarRidge(q.x, horizonY);
    float nearY = auroraNearRidge(q.x, horizonY);
    float farMask = smoothstep(farY - px, farY + px, q.y);
    float nearMask = smoothstep(nearY - px, nearY + px, q.y);
    vec3 night = palVisual(0.28, u);
    // far slopes: dark haze, catching a little curtain light along the crest
    vec3 farCol = night * 0.004 + skyLight * (0.025 + 0.10 * exp(-max(q.y - farY, 0.0) * 50.0));
    vec3 nearCol = night * 0.0008 + skyLight * 0.02 * exp(-max(q.y - nearY, 0.0) * 80.0);
    vec3 col = mix(sky, farCol, farMask);
    col = mix(col, nearCol, nearMask);

    if (water > 0.5) {
        // dim, cool reflection with soft horizontal ripple streaks, darker away from shore
        float streak = 0.80 + 0.35 * vnoise(vec2(p.x * 1.2 + 3.0, rz * 12.0 + t * 0.25));
        col *= vec3(0.80, 0.92, 1.0) * streak * mix(0.55, 0.30, saturate(w / 0.30));
    }

    // a faint, broken glint along the shoreline in the scene's palette
    float shore = exp(-abs(p.y - horizonY - 0.003) / 0.003);
    float broken = smoothstep(0.35, 0.80, vnoise(vec2(p.x * 2.2 + t * 0.10, 2.0)))
                 * (0.5 + 0.5 * vnoise(vec2(p.x * 19.0 - t * 0.20, 4.0)));
    col += palVisual(0.48, u) * shore * broken * (0.030 + 0.015 * u.level);

    // brief persistence softens curtain motion; no zoom or turn, so the land never smears
    return feedbackTrail(col, uv, min(u.trailDecay, 0.45), 0.0, 0.0); // LINEAR HDR — post chain tonemaps
}
