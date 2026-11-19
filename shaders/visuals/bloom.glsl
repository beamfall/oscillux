// SPDX-License-Identifier: AGPL-3.0-only
// Bloom / centered organic ink bloom.
// A single luminous organism blooming from the center: domain-warped petals
// breathing with the level, a hot core, bass light-leak ring and electric
// treble veins. Everything outside the bloom stays black.
// param0 = Flow ; param1 = Color Spread ; param2 = Veins

vec3 visual(vec2 uv, VisualUniforms u) {
    float flowSpeed   = mix(0.05, 0.30, u.param0);
    float colorSpread = mix(0.15, 0.90, u.param1);
    float veinAmt     = mix(0.00, 1.00, u.param2);

    vec2 p = motionCentered(uv, u);
    float r = length(p);
    float ang = atan2_(p.y, p.x);

    float t = u.time;
    float hueTemp = u.spectralCentroid;

    // ---- breathing envelope: the bloom's overall radius ----
    // Two per-beat envelopes, both zero at the beat wrap so nothing jumps there.
    // beatEnv: slow brightness swell (~150 ms attack) for the core, ring glow
    // and rim, all small areas.
    float beatEnv = smoothstep(0.0, 0.3, u.beatPhase)
                  * (1.0 - u.beatPhase) * (1.0 - u.beatPhase) * 2.0;
    // motion-only kick: snaps out on the beat (starting ~25 ms ahead, as the
    // beat pulse does) and settles back over the beat, zero at its wrap; it
    // moves edges, never brightness
    float kPhase = fract(u.beatPhase + 0.05);
    float kickEnv = (1.0 - exp(-16.0 * kPhase)) * (1.0 - kPhase) * (1.0 - kPhase);
    float breatheBase = 0.66
                      + 0.07 * sin(t * 0.45)
                      + 0.22 * u.level;
    // Only the silhouette rides the kick: shading inside the bloom follows the
    // unpulsed radius, since a beat-driven body shade relit the whole bloom
    // twice a beat under loud audio.
    float breathe = breatheBase + 0.05 * kickEnv;

    // ---- organic petals: domain-warped noise sculpting the radius ----
    float warpAmp = 0.30 + 1.10 * u.level; // smoothed level: amplitude reshaped the whole bloom on each kick
    vec2 seed = p * 1.45 + vec2(t * flowSpeed * 0.35, -t * flowSpeed * 0.22);
    vec2 w = vec2(fbm(seed), fbm(seed + vec2(5.23, 3.78))) - 0.5;
    float n = fbm(seed * 1.35 + w * warpAmp + vec2(0.0, -t * flowSpeed * 0.5));

    // slow-rotating petal lobes, count breathing with the mid band
    float lobes = 5.0;
    float petal = 0.5 + 0.5 * sin(ang * lobes - t * 0.35 + w.x * 3.2);
    petal = mix(0.72, 1.0, petal);

    // signed field: positive inside the bloom
    float shape = petal * (0.62 + 0.62 * n);
    float field = breathe * shape - r;
    float fieldBase = breatheBase * shape - r;

    float gate = smoothstep(-0.03, 0.16, field);
    float bodyShade = smoothstep(-0.03, 0.42, fieldBase);

    // ---- color: radius + noise walks the palette ----
    float palT = fract(0.06 * t
                     + (1.0 - saturate(r / (breatheBase + 0.2))) * colorSpread
                     + n * colorSpread * 0.8
                     + 0.08 * sin(ang + w.x * 4.0)
                     + 0.16 * hueTemp);
    vec3 col = palVisual(palT, u);
    col = accentize(col, u.accent, 0.08);
    col *= gate * (0.22 + 0.70 * bodyShade) * (0.32 + 0.42 * u.level)
         * (0.55 + 0.45 * petal);

    // hot HDR core: a gentle swell on the beat envelope, not the raw kick
    float core = exp(-r * r * 16.0);
    vec3 coreCol = palVisual(palT + 0.12, u);
    col += peakWhite(coreCol, 0.06)
         * core * (0.24 + 0.08 * beatEnv);

    // ---- bass light-leak ring around the bloom ----
    // snaps out on the kick (bass sets how far) at a steady, low glow: a ring
    // flashed to full on each kick lit a long circumference
    float leak = beatEnv;
    float ringR = breathe * (0.94 + (0.14 + 0.10 * u.bass) * kickEnv);
    float ringW = 0.05 + 0.03 * leak;
    float ringD = (r - ringR) / ringW;
    float ringMask = exp(-ringD * ringD * 3.0);
    vec3 leakCol = accentize(palVisual(0.10 + 0.45 * hueTemp, u), u.accent, 0.2);
    // keep its dim halo off pure red: lift green so G + B >= 0.6 R
    leakCol.g += max(0.0, 0.6 * leakCol.r - leakCol.g - leakCol.b);
    col += leakCol * ringMask * (0.10 + 0.08 * leak);

    // ---- electric veins radiating through the bloom (treble) ----
    float veinPower = (0.25 + u.treble) * veinAmt;
    if (veinPower > 0.005) {
        float vein = fbmRidged(seed * 2.1 + w * 1.4 + vec2(4.1, 2.7));
        float veinLine = smoothstep(0.62, 0.86, vein) * gate;
        vec3 veinCol = palVisual(0.72 + 0.18 * hueTemp + 0.05 * sin(t * 1.3), u);
        veinCol = peakWhite(veinCol, veinLine * u.treble * 0.12);
        col += veinCol * veinLine * veinPower * (0.6 + 1.4 * u.treble) * 1.1;
    }

    // beat accent: a thin cool rim tracing the bloom's silhouette, on the
    // smooth envelope (the raw onset relit the whole perimeter in one frame)
    float silh = gate * (1.0 - smoothstep(0.0, 0.10, field));
    col += vec3(0.5, 1.1, 1.3) * silh * beatEnv * 0.18;

    // feedback trail — slow outward exhale
    float trailZoom = 0.004 + 0.010 * u.level; // amplitude kicked the trail zoom each beat
    float trailRot  = 0.002; // a beat-kicked spin ghosts the whole bloom
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.70), trailZoom, trailRot);

    return col; // LINEAR HDR — post chain tonemaps
}
