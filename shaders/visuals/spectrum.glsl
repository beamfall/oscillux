// SPDX-License-Identifier: AGPL-3.0-only
// Spectrum / neon glass skyline.
// param0 Perspective ; param1 Column Glass ; param2 Reflection
//
// Flash budget: the visual keeps within the general flash limit itself under loud audio. The
// spectrum shows as tower height, never as tower brightness or width, so a kick moves the caps
// of the bass towers rather than lighting them up. Brightness follows a slow beat swell (about
// 150 ms rise, the rest of the beat to fall) and the steady level, never the instant-attack
// kick, onset, flux, beat or bassImpact envelopes, nor the palette roles that follow them or the
// wrapping beatPhase. Everything that moves with the beat runs on the continuous beat clock.

// Beat swell: 0 on the beat, up over the first 30% of the beat, back down by the next one.
float spectrumSwell(VisualUniforms u) {
    float x = u.beatPhase;
    return smoothstep(0.0, 0.3, x) * (1.0 - smoothstep(0.3, 1.0, x));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    // Slow camera drift (suv = drifted coords; keep uv pristine for the trail).
    vec2 suv = uv + 0.0009 * vec2(sin(u.time * 0.53), sin(u.time * 0.41 + 1.3) * 0.45);
    suv = clamp(suv, 0.001, 0.999);

    float horizon = 0.62;
    float persp = mix(1.35, 2.75, u.param0);
    float glass = mix(0.48, 1.00, u.param1);
    float refl = mix(0.10, 0.42, u.param2);

    // Continuous beat clock with an eased surge per beat. Scrolling by
    // beatPhase alone snapped every floor line and segment ring back on the
    // beat wrap, a full-floor flash each beat.
    float beatClock = u.beatCount + smoothstep(0.0, 1.0, u.beatPhase);
    float swell = spectrumSwell(u);
    float lvl = sqrt(clamp(u.level, 0.0, 1.0));

    vec3 base = vec3(0.0);
    vec3 glow = vec3(0.0);

    // Floor grid/reflection, lower half only.
    if (suv.y > horizon) {
        float ft = (suv.y - horizon) / max(1.0 - horizon, 0.001);
        float depth = 1.0 / max(ft * persp + 0.025, 0.025);
        float wx = (suv.x - 0.5 + sin(beatClock * 1.5708 + ft * 1.5708) * 0.004) * depth * 1.8;
        float wz = depth + u.time * 0.10 + beatClock * 0.10;

        float gx = wx * 0.82 + 0.5;
        float gz = wz * 0.36;
        float grid = max(aaLineCyclic(gx, 0.0032), aaLineCyclic(gz, 0.0022));
        float fade = smoothstep(0.02, 0.20, ft) * exp(-ft * 3.4) * smoothstep(0.86, 0.16, abs(suv.x - 0.5));
        vec3 fog = palVisual(0.56, u);
        fog = mix(vec3(luma(fog) * 0.62), fog, 0.42);
        glow += mix(fog, palVisual(suv.x, u), 0.45) * grid * fade * (0.16 + 0.12 * u.mid);
    }

    // Fewer, wider columns on a narrow frame: x distances shrink by sx (frame fit).
    const int NCOLS = 58;
    int ncols = fitColumns(u, NCOLS, 12);
    float sx = float(ncols) / float(NCOLS);
    for (int i = 0; i < NCOLS; i++) {
        if (i >= ncols) break;
        float fi = float(i);
        float x = (fi + 0.5) / float(ncols);
        float lane = abs(suv.x - x) * sx;
        float phaseOffset = fi / float(ncols - 1);
        float raw = bandAtWrapped(u, phaseOffset + sin(beatClock * 0.7854) * 0.02);
        float seed = hash11(fi * 3.37);
        float b = max(raw, 0.06 + 0.10 * seed);
        float phaseLift = phasePulse(u, phaseOffset, 0.18);
        float cluster = hash11(floor(fi / 4.0) * 2.11);

        // The spectrum drives height only; the kick moves caps, it does not light towers.
        float h = pow(b, 0.72) * mix(0.20, 0.60, cluster) * glass;
        h += pow(seed, 6.0) * 0.26;
        h *= (1.0 + 0.04 * swell + phaseLift * 0.05);
        h = clamp(h, 0.035, 0.56);

        float yTop = horizon - h;
        float colW = mix(0.0034, 0.0058, seed);
        float inX = 1.0 - smoothstep(colW, colW + 0.002, lane);
        float inY = smoothstep(yTop - 0.002, yTop + 0.002, suv.y) * step(suv.y, horizon);
        vec3 c = palVisual(x + 0.02 * sin(u.time * 0.07), u);
        c = accentize(c, u.accent, 0.08);

        // Transparent body plus glass edges/caps/segment rings.
        float lift = 0.85 + 0.25 * lvl + 0.12 * swell;
        base += c * inX * inY * 0.022;
        float edge = aaLine(lane - colW, 0.0018) * inY;
        float cap = aaLine(suv.y - yTop, 0.0034) * inX;
        float seg = aaLineCyclic((suv.y - yTop) / max(h, 0.001) * 5.0 - beatClock * 0.55, 0.035) * inX * inY;
        glow += c * edge * 1.15 * lift;
        glow += mix(c, vec3(1.0), 0.35) * cap * (1.05 + 0.45 * clamp(u.treble, 0.0, 1.0)) * lift;
        glow += c * seg * (0.26 + phaseLift * 0.12) * lift;

        // Reflection as soft mirrored ticks, not a smear.
        if (suv.y > horizon) {
            float ft = (suv.y - horizon) / max(1.0 - horizon, 0.001);
            float mirrorY = horizon + (horizon - yTop) * (1.0 - ft * 0.62);
            float rLine = aaLine(suv.y - mirrorY, 0.0035) * inX;
            glow += c * rLine * refl * (1.0 - ft) * 0.55;
        }

        // Particle shafts above selected towers.
        float shaft = exp(-lane * lane * 23000.0)
                    * smoothstep(yTop - 0.22, yTop - 0.02, suv.y)
                    * (1.0 - smoothstep(yTop - 0.02, yTop + 0.04, suv.y));
        glow += c * shaft * step(0.78, seed) * (0.30 + 0.12 * lvl + 0.10 * swell);

        // Tiny spark caps rising off the towers on the continuous beat clock.
        float sparkLife = fract(seed + u.time * (0.18 + 0.3 * seed) + beatClock * 0.05);
        float sparkY = yTop - sparkLife * (0.06 + 0.22 * seed);
        float sparkD = length(vec2((suv.x - x) * sx * 1.9, suv.y - sparkY));
        float spark = min(1.0, 0.00003 / (sparkD * sparkD + 0.00006));
        float sparkFade = smoothstep(0.0, 0.10, sparkLife) * (1.0 - sparkLife);
        glow += palVisual(0.62 + x * 0.28, u) * spark * sparkFade * (0.42 + 0.18 * lvl);
    }

    // Molten waveform ribbon across the city front: the low end bends it, it does not flash it.
    float bline = bandAt(u, suv.x);
    float ribbonY = horizon + 0.055
                  + 0.030 * (bline - 0.5)
                  + 0.014 * sin(suv.x * 12.0 + u.time * 1.5 + beatClock * 1.1310)
                  + 0.006 * sin(suv.x * 35.0 - u.time * 2.6 - beatClock * 0.9425);
    float ribbonW = 0.0040;
    float ribbon = aaLine(suv.y - ribbonY, ribbonW);
    float halo = aaLine(suv.y - ribbonY, ribbonW * 4.0) * 0.16;
    vec3 rc = mix(palVisual(0.18, u), palVisual(0.06, u), 0.7);
    glow += rc * (ribbon + halo) * (1.45 + 0.30 * lvl + 0.25 * swell);

    vec3 trailedGlow = feedbackTrail(glow, uv, min(u.trailDecay, 0.80), 0.002, 0.0);
    return base + trailedGlow;
}
