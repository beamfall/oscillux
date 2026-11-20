// SPDX-License-Identifier: AGPL-3.0-only
// Starfield "Warp Drive"
// param0 = Warp Speed ; param1 = Density ; param2 = Streak Length

vec3 visual(vec2 uv, VisualUniforms u) {
    // ── aspect-correct centred coords ────────────────────────────────────────
    vec2 p = motionCentered(uv, u);   // ~[-1,1] x-scaled by aspect

    // ── params ───────────────────────────────────────────────────────────────
    float baseSpeed  = mix(0.30, 5.0, u.param0);
    int   starCount  = int(mix(20.0, 120.0, clamp(u.param1, 0.0, 1.0)));
    float streakMult = mix(0.10, 0.80, u.param2);

    // ── warp speed: locked to beat tempo + beat swell ────────────────────────
    // Speed only lengthens streaks; position must stay continuous. time *
    // (speed + surge) teleported every star on each beat, a full-field flash.
    // The beat drives motion and a slow swell, never a per-frame brightness jump: every star
    // pulsing together on the kick strobed the whole field (CORE-2659). The swell rises over
    // ~175 ms after the beat and falls over the rest of it, scaled by the smoothed level.
    float swell = smoothstep(0.0, 0.35, u.beatPhase) * (1.0 - smoothstep(0.35, 1.0, u.beatPhase))
                * saturate(u.level * 1.2);
    float warpSpeed  = baseSpeed + swell * 1.6;

    // Monotonic warp position: steady cruise plus an eased forward surge per
    // beat (0 at phase 0, 1 at phase 1, so it is seamless across beats). The surge
    // is spread over the beat with no velocity step at the wrap: a sharp lunge just
    // after the kick swept every thick streak across new pixels at once.
    float lunge = mix(u.beatPhase, smoothstep(0.0, 1.0, u.beatPhase), 0.6);
    // Wrap the beat count where depth (beatClock * 18/130 * 0.065) has run a whole number of
    // cycles: 2000 beats is exactly 18, so the wrap moves no star (OSC-0040).
    // Cruise and surge are slower than the streaks' width would suggest: thick bright streaks
    // sweeping quickly fire enough pixels at once that the frame limiter held them, leaving
    // ghost heads behind (CORE-2659).
    float beatClock = mod(u.beatCount, 2000.0) + lunge;
    float warpPos = u.time * baseSpeed * 0.45 + beatClock * (18.0 / 130.0);

    // ── accumulate stars ─────────────────────────────────────────────────────
    vec3 col = vec3(0.0);

    for (int i = 0; i < 120; ++i) {
        if (i >= starCount) break;

        float fi = float(i);

        // Per-star deterministic seeds
        float h1 = hash11(fi * 0.1731 + 1.73);   // base angle [0,1)
        float h2 = hash11(fi * 0.3741 + 3.17);   // depth offset [0,1)
        float h3 = hash11(fi * 0.6191 + 7.37);   // brightness / size seed
        float h4 = hash11(fi * 0.2513 + 5.09);   // color selector

        // Star angle in [-π, π]
        float baseAngle = h1 * 6.28318530718;

        // Depth in [0,1): 0=center singularity, 1=viewer; advances with warpPos
        float depth = fract(h2 + warpPos * 0.065);

        // ── bending: mids drive path curvature around spectrum rings ─────────
        float ang01     = h1;                          // same as angle/2π, in [0,1)
        float specBend  = bandAt(u, ang01);            // 0..1
        // Mids bend the paths; the kick-driven spectrum would swing long streaks sideways
        // together on every beat, sweeping large areas, so it does not enter the bend.
        float bendAmt   = (0.4 + 0.6 * h2) * u.mid * 0.22;
        float bentAngle = baseAngle + bendAmt * sin(depth * 6.2832 + u.time * 0.8);

        // Radial distance: non-linear growth for perspective acceleration
        float radius = depth * depth * 1.6;            // 0..1.6

        // 2D star position
        vec2 starPos = vec2(cos(bentAngle), sin(bentAngle)) * radius;

        // ── streak segment toward centre (tail direction) ────────────────────
        float streakLen = streakMult * depth * depth
                          * (1.0 + warpSpeed * 0.04)
                          * (1.0 + swell * 0.2); // the swell stretches tails slowly; a kick-rate stretch flashed every tail

        // Guard near-zero for normalize
        float starDist = length(starPos);
        vec2 tailDir = starDist > 1e-5 ? (-starPos / starDist) : vec2(0.0, -1.0);

        // Project pixel onto streak segment, find closest point
        vec2  toPixel = p - starPos;
        float tProj   = clamp(dot(toPixel, tailDir),
                              0.0, max(streakLen, 1e-5));
        vec2  closest = starPos + tailDir * tProj;
        float dist    = length(p - closest);
        float tailFrac = tProj / max(streakLen, 1e-5); // 0=head, 1=tail

        // Streak width: tiny near origin, thick toward the viewer, tapering head to tail
        // into a wedge. Width is steady per star (depth only), so it never pulses.
        float dotSize = (0.0034 + h3 * 0.011) * (0.25 + depth * 2.2) * (1.0 - 0.5 * tailFrac);

        // Brightness envelope: fade in from singularity, fade out past edge
        float bright = smoothstep(0.0, 0.30, depth)
                     * smoothstep(1.0, 0.72, depth)
                     * (0.65 + h3 * 0.35) * (0.85 + specBend * 0.15 + swell * 0.08);

        // Core falloff along the streak: quartic, so the bright core has a crisp edge and the
        // pixels a moving streak brightens past the limiter's 0.1 step stay few; cores still
        // reach ~5x HDR. The wide halo is a soft lavender glow kept dim enough (well under a
        // 0.1 luminance step) that its motion never counts as a flash.
        float gx   = dist / dotSize;
        float glow = min(1.0 / (gx * gx * gx * gx + 0.2), 5.0) * bright;
        float halo = exp(-gx * gx * 0.08) * 0.09 * bright;

        // ── color ────────────────────────────────────────────────────────────
        // Base hue follows the active semantic palette across star index + depth.
        vec3 coreCol = palRoleTrace(h4 + depth * 0.15 + u.spectralCentroid * 0.12, u);

        // Star cores: palette colour pushed toward lavender-white hot cores
        vec3 headCol = mix(coreCol * 1.15, vec3(1.1, 1.05, 1.3),
                           0.1 + 0.3 * smoothstep(0.8, 1.0, depth));

        // Tail: semantic bass colour, shifted (not brightened) by the swell.
        vec3 tailCol = palRoleBass(h4 * 0.6 + swell * 0.12, u);

        vec3 starCol = mix(headCol, tailCol, tailFrac * 0.7);
        starCol = accentize(starCol, u.accent, 0.10);

        // treble: tiny bright white sparks among the stars
        float whiteSpark = smoothstep(0.86, 1.0, h3) * saturate(u.treble * 1.4);
        starCol = mix(starCol, vec3(1.3, 1.3, 1.5), whiteSpark * 0.7);

        col += starCol * glow + coreCol * halo;
    }

    // ── warp rings: a bright gold inner ring and a gold-to-amber outer ring ──
    // Both are steady in place and brightness; the beat warms their hue on the slow swell
    // (CORE-2659): even a 2% radius breath, stacked by the trail zoom, tipped the field
    // over the luma budget with the swell-stretched streaks. Amber keeps green and blue in
    // it so it never reads as saturated red.
    {
        float r = length(p);
        float a = atan2_(p.y, p.x);
        float innerR = 0.34;
        float inner  = aaLine(r - innerR, 0.011) + 0.25 * exp(-abs(r - innerR) * 70.0);
        vec3 innerCol = mix(vec3(1.0, 0.74, 0.18), vec3(1.0, 0.84, 0.36), 0.5 + 0.5 * sin(a * 2.0 + u.time * 0.4));
        innerCol = mix(innerCol, vec3(1.0, 0.68, 0.22), swell * 0.5);
        col += innerCol * inner * 0.75;

        float outerR = 0.94;
        float outer  = aaLine(r - outerR, 0.007) + 0.2 * exp(-abs(r - outerR) * 80.0);
        // gold around half the ring, warming to amber around the other half, drifting slowly
        float warm = smoothstep(0.15, 0.85, 0.5 + 0.5 * sin(a + 2.4 + u.time * 0.15 + swell * 0.3));
        vec3 outerCol = mix(vec3(0.7, 0.52, 0.14), vec3(0.8, 0.34, 0.08), warm);
        col += outerCol * outer * 0.62;

        // flux filaments: faint radial rays, re-seeded each beat while their envelope is 0
        for (int j = 0; j < 12; ++j) {
            float fj   = float(j);
            float ha   = hash11(fj * 0.411 + u.beatCount * 0.1);
            float sa   = ha * 6.28318530718;
            vec2 dir = vec2(cos(sa), sin(sa));
            float t   = max(dot(p, dir), 0.0);
            float dd  = length(p - dir * t);
            float filament = 0.0003 / max(dd * dd * 400.0 + dd, 0.0006);
            filament *= smoothstep(0.8, 0.1, t) * swell * saturate(u.flux + 0.3) * 0.8;
            col += mix(palNeon(ha + 0.15), vec3(0.8, 0.85, 1.0), 0.4) * filament;
        }
    }

    // ── center singularity: fade to BLACK (not white) ─────────────────────────
    float cr = length(p);
    col *= smoothstep(0.0, 0.12, cr);      // fully black at the singularity

    // ── feedback warp trails (zoom-OUT = warp-speed effect) ──────────────────
    // Short, steady trails: a kick-rate zoom and rotation smeared every star into wide
    // wedges that flashed across the field as they faded (CORE-2659).
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.55), 0.004, 0.0);

    return col; // LINEAR HDR — post chain tonemaps
}
