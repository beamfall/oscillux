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
    float warpSpeed  = baseSpeed + swell * 2.0;

    // Monotonic warp position: steady cruise plus an eased forward lunge per
    // beat (0 at phase 0, 1 at phase 1, so it is seamless across beats).
    float lunge = (1.0 - exp(-u.beatPhase * 4.0)) / (1.0 - exp(-4.0));
    // Wrap the beat count where depth (beatClock * 0.3 * 0.065) has run a whole number of
    // cycles: 2000 beats is exactly 39, so the wrap moves no star (OSC-0040).
    float beatClock = mod(u.beatCount, 2000.0) + lunge;
    float warpPos = u.time * baseSpeed + beatClock * 0.3;

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
                          * (1.0 + swell * 0.25); // the swell stretches tails slowly; a kick-rate stretch flashed every tail

        // Guard near-zero for normalize
        float starDist = length(starPos);
        vec2 tailDir = starDist > 1e-5 ? (-starPos / starDist) : vec2(0.0, -1.0);

        // Project pixel onto streak segment, find closest point
        vec2  toPixel = p - starPos;
        float tProj   = clamp(dot(toPixel, tailDir),
                              0.0, max(streakLen, 1e-5));
        vec2  closest = starPos + tailDir * tProj;
        float dist    = length(p - closest);

        // Star dot size: tiny near origin, blooms toward viewer
        float dotSize = (0.0005 + h3 * 0.0025) * (0.2 + depth * 2.0);

        // Brightness envelope: fade in from singularity, fade out past edge
        float bright = smoothstep(0.0, 0.30, depth)
                     * smoothstep(1.0, 0.72, depth)
                     * (0.55 + h3 * 0.45) * (0.55 + specBend * 0.25 + swell * 0.12);

        // Glow falloff along the streak — quadratic so halos stay tight and
        // space between stars stays black; cores still reach ~5x HDR
        float glow = (dotSize * dotSize) / (dist * dist + dotSize * dotSize * 0.2);
        glow = min(glow, 5.0) * bright;

        // ── color ────────────────────────────────────────────────────────────
        float tailFrac = tProj / max(streakLen, 1e-5); // 0=head, 1=tail

        // Base hue follows the active semantic palette across star index + depth.
        vec3 coreCol = palRoleTrace(h4 + depth * 0.15 + u.spectralCentroid * 0.12, u);

        // Star cores: saturated palette color, only a hint of white-hot
        vec3 headCol = mix(coreCol * 1.15, vec3(1.1, 1.15, 1.25),
                           0.18 + 0.25 * smoothstep(0.9, 1.0, depth));

        // Tail: semantic bass colour, shifted (not brightened) by the swell.
        vec3 tailCol = palRoleBass(h4 * 0.6 + swell * 0.12, u);

        vec3 starCol = mix(headCol, tailCol, tailFrac * 0.7);
        starCol = accentize(starCol, u.accent, 0.10);

        // treble: tiny bright white sparks among the stars
        float whiteSpark = smoothstep(0.86, 1.0, h3) * saturate(u.treble * 1.4);
        starCol = mix(starCol, vec3(1.3, 1.3, 1.5), whiteSpark * 0.7);

        col += starCol * glow;
    }

    // ── beat wave: a thin gold ring rides out on each beat ───────────────────
    // It expands with the beat phase and swells in and out (no on-beat flash), stays thin,
    // and keeps green in it so it never reads as saturated red (CORE-2659).
    {
        float r = length(p);
        float a = atan2_(p.y, p.x);
        float ringR  = 0.22 + u.beatPhase * 0.95;
        float ringEnv = swell * (1.0 - smoothstep(0.6, 1.2, ringR));
        float ring = ringEnv * 0.16 * aaLine(r - ringR, 0.004);
        vec3 burstCol = mix(palNeon(0.10 + a / 6.28318530718 * 0.15), vec3(1.0, 0.85, 0.55), 0.45);
        col += burstCol * ring;

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
