// SPDX-License-Identifier: AGPL-3.0-only
// Terrain / Pulse Array City skyline stage.
// Screen-space pseudo-3D stage: black sky, dark glass skyline, dim lower-third
// floor grid, and a thin hot orange waveform river.
// param0 = Floor Speed ; param1 = Skyline Height ; param2 = Floor/Grid Visibility

vec3 visual(vec2 uv, VisualUniforms u) {
    // Beat swell: about 180 ms attack after the beat, eased release, zero at
    // the beat wrap, so every beat-driven size and brightness term is
    // continuous. The instant kick/onset/flux signals and a kick camera shake
    // jolted every thin edge, cap and shaft at once under loud audio.
    float swell = smoothstep(0.0, 0.36, u.beatPhase)
                * (1.0 - smoothstep(0.36, 1.0, u.beatPhase));
    // Slow hue drift in place of the beat-phase palette nudges, which jumped
    // at the wrap.
    float hueDrift = 0.04 * sin(u.time * 0.21);

    float horizon = 0.64;
    float heightScale = mix(0.85, 1.85, u.param1);
    float floorVis = mix(0.18, 0.58, u.param2);

    vec3 base = vec3(0.0);
    vec3 glow = vec3(0.0);

    // Continuous beat clock with an eased surge per beat. Scrolling by
    // beatPhase alone snapped every floor line back on the beat wrap.
    float beatClock = u.beatCount + smoothstep(0.0, 1.0, u.beatPhase);

    // ---------------------------------------------------------------------
    // Floor: lower-third support only. Dim circuit lines, never HDR.
    // ---------------------------------------------------------------------
    if (uv.y > horizon) {
        float ft = (uv.y - horizon) / max(1.0 - horizon, 0.001);
        float depth = 1.0 / max(ft * 2.45 + 0.025, 0.025);
        float scroll = u.time * mix(0.12, 0.75, u.param0) * 0.6 + beatClock * 0.09;
        float wx = (uv.x - 0.5 + sin(beatRadians(u, ft * 0.20)) * 0.0035) * depth * 1.55;
        float wz = depth + scroll;

        float cellX = wx * 0.75 + 0.5;
        float cellZ = wz * 0.34;
        float vLine = aaLineCyclic(cellX, 0.0035);
        float hLine2 = aaLineCyclic(cellZ, 0.0024);
        float grid = max(vLine, hLine2);

        float nearHorizonFade = smoothstep(0.02, 0.20, ft);
        float farFade = exp(-ft * 3.8);
        float sideFade = smoothstep(0.78, 0.18, abs(uv.x - 0.5));
        float floorFade = nearHorizonFade * farFade * sideFade * floorVis;
        vec3 floorCol = mix(palRoleFog(0.56 + hueDrift, u),
                            palVisual(uv.x + hueDrift, u),
                            0.45);
        glow += floorCol * grid * floorFade * (0.32 + 0.24 * u.mid);

        // Very dim reflected ticks directly beneath active columns.
        float tickCell = fract(uv.x * 40.0 * columnFit(u));
        float tick = smoothstep(0.08, 0.18, tickCell) * smoothstep(0.92, 0.82, tickCell);
        float b = bandAt(u, uv.x);
        float tickY = step(ft, b * 0.26);
        glow += palVisual(uv.x + hueDrift, u) * tick * tickY * floorFade * b * 0.25;
    }

    // ---------------------------------------------------------------------
    // Skyline: dark glass bodies with bright edges and caps.
    // ---------------------------------------------------------------------
    // Fewer, wider columns on a narrow frame: x distances shrink by sx (frame fit).
    const int NCOLS = 56;
    int ncols = fitColumns(u, NCOLS, 12);
    float sx = float(ncols) / float(NCOLS);
    for (int i = 0; i < NCOLS; i++) {
        if (i >= ncols) break;
        float fi = float(i);
        float x = (fi + 0.5) / float(ncols);
        float lane = abs(uv.x - x) * sx;
        float phaseOffset = fi / float(ncols - 1);
        float rawB = bandAtWrapped(u, phaseOffset + beatWave(u, 0.0) * 0.032);
        float seed = hash11(fi * 2.91);
        float b = max(rawB, 0.10 + 0.18 * seed);
        float phaseLift = phasePulse(u, phaseOffset, 0.19);

        float group = hash11(floor(fi / 3.0) * 2.3);
        float peak = pow(seed, 5.0) * 0.36;
        float h = pow(b, 0.68) * heightScale * (0.16 + 0.34 * group) + peak;
        h *= (1.0 + 0.06 * swell + phaseLift * 0.075);
        h = clamp(h, 0.045, 0.60);
        float yTop = horizon - h;

        // Width fixed per column: a band-driven width slid every edge line
        // sideways by sub-pixel steps on each kick.
        float colW = mix(0.0034, 0.0062, seed);
        float insideX = 1.0 - smoothstep(colW, colW + 0.002, lane);
        float insideY = step(yTop, uv.y) * step(uv.y, horizon);
        vec3 c = palVisual(x + hueDrift, u);
        c = accentize(c, u.accent, 0.08);

        float body = insideX * insideY * b * 0.035;
        float edge = aaLine(lane - colW, 0.0018) * insideY;
        float cap = aaLine(uv.y - yTop, 0.0035) * insideX;

        base += c * body;
        glow += c * edge * (0.85 + 1.75 * b);
        glow += mix(c, vec3(1.0), 0.45) * cap * (1.6 + 1.6 * u.treble + 0.8 * b + 0.8 * swell);

        // Tall particle shafts above active towers, like the city reference.
        float shaft = exp(-lane * lane * 22000.0)
                    * smoothstep(yTop - 0.28, yTop, uv.y)
                    * (1.0 - smoothstep(yTop, yTop + 0.05, uv.y));
        float shaftMask = step(0.72, seed) * (0.2 + 0.8 * b);
        glow += c * shaft * shaftMask * (0.45 + 0.35 * swell + phaseLift * 0.22);

        // Sparse upward sparks, one set per beat.
        float sparkSeed = hash11(fi * 5.19 + floor(u.beatCount));
        if (sparkSeed > 0.72) {
            float life = fract(sparkSeed + u.time * (0.55 + sparkSeed) + u.beatPhase * 0.14);
            float sparkY = horizon - h * life;
            float sparkD = length(vec2((uv.x - x) * sx * 1.8, uv.y - sparkY));
            float spark = min(1.2, 0.00018 / (sparkD * sparkD + 0.00045));
            // Faded in and out across the beat: the spark set re-seeds at the wrap.
            float sparkEnv = sin(3.14159265 * u.beatPhase);
            glow += palVisual(0.62 + x * 0.28 + hueDrift, u) * spark * sparkEnv * 0.8 * (1.0 - life);
        }
    }

    // ---------------------------------------------------------------------
    // Foreground waveform river: the visual hero, thin and hot.
    // ---------------------------------------------------------------------
    float riverBand = bandAt(u, uv.x);
    float riverY = horizon + 0.080
                 + 0.028 * (riverBand - 0.5)
                 + 0.012 * sin(uv.x * 12.0 + u.time * 1.4 + beatRadians(u, 0.0) * 0.16)
                 + 0.006 * sin(uv.x * 31.0 - u.time * 2.7 - beatRadians(u, 0.25) * 0.14);
    float riverW = 0.0042 + 0.0018 * swell;
    float river = aaLine(uv.y - riverY, riverW);
    float riverHalo = aaLine(uv.y - riverY, riverW * 4.5) * 0.22;
    float riverWindow = smoothstep(horizon + 0.02, horizon + 0.09, riverY)
                      * smoothstep(0.96, 0.72, uv.y);
    vec3 riverCol = mix(palVisual(0.18, u), palVisual(0.044, u), 0.7);
    glow += riverCol * (river + riverHalo) * riverWindow * (2.5 + 2.0 * riverBand + 0.8 * swell);

    // Thin horizon separator: narrow, not a fog bar.
    float hLine = aaLine(uv.y - horizon, 0.0018);
    glow += palRoleFog(0.60 + hueDrift, u) * hLine * 0.20;

    vec3 trailedGlow = feedbackTrail(glow, uv,
                                     min(u.trailDecay, 0.56),
                                     0.0015 + 0.001 * swell,
                                     0.0);
    vec3 col = base + trailedGlow;
    // Colour floor: keep G and B a fair share of R so dim copper tails and the
    // river halo stay amber and never round to saturated red.
    col.g = max(col.g, col.r * 0.40);
    col.b = max(col.b, col.r * 0.20);
    return col; // LINEAR HDR — post chain tonemaps
}
