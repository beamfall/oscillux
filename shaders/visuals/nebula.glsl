// SPDX-License-Identifier: AGPL-3.0-only
// Nebula — frequency + beat.
//
// Volumetric smoke around a dark core, with a fan of bold spectrum rays bursting out of it.
// Performance path: layered analytic shells, not a full raymarch: 12 shells at full
// detail, down to 6 as the host raises presentation1.y, each weighted to keep density.
// DARK CORE enforced: radial carve + density clamp keeps the center black.
// Bold spectrum rays fan out of the core; the beat turns the cloud and the thin rays.
//
// Flash budget (Makefile visual-flash-check): the rays are bright and large, so their brightness
// holds steady and they barely move: the fan drifts slowly, only the thin rays take the beat's
// notch turn, and each ray fades in and out over a twelve-beat life, staggered across the fan.
// The beat moves the smoke and swells the core through a smooth envelope (about 150 ms attack,
// the rest of the beat to release), never as a brightness step. Kick-gated signals (bassImpact,
// flux, onset, the low bins) do not touch brightness, geometry or hue over large areas, and
// nothing is re-seeded per frame or per beat. Ray and smoke colours keep G + B above R, so no
// large area reads as saturated red.
//
// param0  Density    (0..1) — cloud thickness/opacity scale
// param1  Swirl      (0..1) — rotational domain-warp strength
// param2  Emission   (0..1) — ridge/lightning emission multiplier

vec3 visual(vec2 uv, VisualUniforms u) {
    // ---- coordinate setup --------------------------------------------------
    vec2  p0 = motionCentered(uv, u);   // aspect-correct ~[-1,1]
    float t  = u.time * 0.14;

    // ---- param mapping -----------------------------------------------------
    float densScale = mix(0.15, 0.70, u.param0);   // keep upper end < 1 to stay wispy
    float swirlAmt  = mix(0.4,  3.2,  u.param1);
    float emitScale = mix(0.8,  3.5,  u.param2);

    // ---- audio features ----------------------------------------------------
    float midE    = u.mid;
    float trebleE = u.treble;
    float levelE  = saturate(u.level);
    float specCentroid = u.spectralCentroid;
    float trebleBand = bandRange(u, 40, 64);
    // Smooth beat swell: 0 on the beat, peaks 0.3 beat later, back to 0 by the next beat.
    float ph    = u.beatPhase;
    float swell = smoothstep(0.0, 0.3, ph) * (1.0 - smoothstep(0.3, 1.0, ph));
    // Each beat turns the cloud one notch, fast on the beat and easing out: motion, not light.
    // 120 notches make a full turn, so the wrap of beatCount is seamless.
    // The notch starts 0.07 beat early so the turn lands with the kick, not after it.
    float nph   = ph + 0.07;
    float notch = (1.0 - exp(-fract(nph) * 4.5)) / (1.0 - exp(-4.5));
    float beatTurn = (mod(u.beatCount + floor(nph), 120.0) + notch) * (6.2831853 / 120.0);

    // ---- dark core carve ---------------------------------------------------
    float coreRadius = 0.24 + swell * 0.05;

    // ---- layered volume ----------------------------------------------------
    vec3  col      = vec3(0.0);
    float transmit = 1.0;

    // presentation1.y is the host's detail reduction in [0, 1]; it raises it to hold frame rate.
    float detail      = 1.0 - clamp(u.presentation1.y, 0.0, 1.0);
    int   layers      = 6 + int(floor(6.0 * detail + 0.5));
    float invLayers   = 1.0 / float(layers);
    float layerWeight = 12.0 / float(layers);
    float radius = length(p0);
    float outerMask = 1.0 - smoothstep(1.05, 1.48, radius);
    float coreMask = smoothstep(coreRadius, coreRadius + 0.28, radius);

    for (int i = 0; i < 12; ++i) {
        if (i >= layers) break;
        float fi = (float(i) + 0.5) * invLayers;
        float depth = 1.0 - fi;
        float sliceAngle = t * 0.55 + swirlAmt * fi * 1.65 + beatTurn;
        float shell = mix(1.28, 0.72, fi);
        vec2 sp = rot2(sliceAngle) * (p0 * shell);

        vec2 warp = vec2(
            fbm(sp * 1.05 + vec2(1.7, 9.2) + t * 0.9),
            fbm(sp * 1.05 + vec2(8.3, 2.8) - t * 0.7)
        ) - 0.5;
        sp += warp * (0.30 + midE * 0.30 + depth * 0.10);

        float ridgeA = fbmRidged(sp * (1.55 + fi * 0.75) + vec2(fi * 2.1, t * 0.8));
        float ridgeB = fbmRidged(sp * 2.85 + vec2(t * 0.45, fi * 3.7));
        float rawDens = ridgeA * 0.70 + ridgeB * 0.30;
        float dens = smoothstep(0.63, 0.98, rawDens);
        dens *= (0.30 + 0.70 * smoothstep(0.40, 0.92, ridgeB));
        dens *= coreMask * outerMask * densScale * (0.40 + levelE * 0.20);
        dens = min(dens, 0.20);

        // Ridge glints: treble lights the crests; fixed to the smoke, so they drift, not sparkle.
        float ridgeLine = smoothstep(0.78, 0.97, ridgeA) * (0.25 + trebleBand * 0.9 + trebleE * 0.35);

        vec3 smokeCol = accentize(palVisual(fi * 0.55 + specCentroid * 0.22 + t * 0.04, u), u.accent, 0.10);
        vec3 litCol = palVisual(0.75 + specCentroid * 0.2 - fi * 0.15, u);
        // Keep G + B above R: orange smoke leans gold, never toward saturated red.
        smokeCol.g = max(smokeCol.g, smokeCol.r - smokeCol.b + 0.03);
        litCol.g   = max(litCol.g, litCol.r - litCol.b + 0.03);
        float stir = swell * depth * 0.18; // the beat warms the near shells a little

        float alpha = min(dens * 0.55, 0.12) * layerWeight;
        vec3 emissive = smokeCol * (dens * 4.0 * emitScale * (1.0 + stir))
                      + litCol * (ridgeLine * dens * 9.0 * emitScale);
        col += transmit * alpha * emissive * 0.45;
        transmit *= (1.0 - alpha * 0.45);
    }

    // ---- spectrum rays (screen-space, on top of volume) ---------------------
    // Bold tapered beams fanning out of the core, each its own palette hue. They are large and
    // bright, so they hold still: brightness never follows the beat, the fan drifts slowly, and
    // each beam fades in and out over a sixteen-beat life, staggered so one changes at a time.
    {
        float ang = atan(p0.y, p0.x);
        float rayStart = smoothstep(coreRadius - 0.02, coreRadius + 0.16, radius);
        for (int j = 0; j < 16; ++j) {
            float fj = float(j);
            float cyc = (u.beatCount + ph - fj * (12.0 / 16.0)) / 12.0;
            float age = fract(cyc);                                    // 0..1 over the life
            float gen = floor(cyc);
            float life = smoothstep(0.0, 0.35, age) * (1.0 - smoothstep(0.65, 1.0, age));
            vec2 h   = hash22(vec2(fj * 3.1 + gen * 1.37, 7.3 + fj));
            // Thin beams carry the beat as a turn of the fan; wide ones only drift (they are large).
            float thin = 1.0 - smoothstep(0.25, 0.55, h.y);
            float fAngle = h.x * 6.2831853 + t * 0.12 + beatTurn * 0.5 * thin;
            float da = abs(mod(ang - fAngle + 3.14159265, 6.2831853) - 3.14159265);
            // Angular width, so each beam widens into a wedge toward the frame edge.
            float wA = mix(0.022, 0.105, h.y * h.y);
            float beam = max(exp(-(da * da) / (wA * wA)) - 0.01, 0.0);
            float core = exp(-(da * da) / (wA * wA * 0.12));   // hot centre line
            float reach = 1.35 + 0.45 * h.y;
            float along = rayStart * (1.0 - smoothstep(reach * 0.75, reach + 0.35, radius));
            float amp = life * along * (0.90 + trebleE * 0.10) * emitScale * 0.55;
            vec3 rayCol = palVisual(fj * 0.0625 + h.x * 0.25 + specCentroid * 0.2, u);
            // Keep G + B above R: pinks lean magenta and never read as saturated red.
            rayCol.b = max(rayCol.b, rayCol.r - rayCol.g + 0.03);
            col += rayCol * beam * amp * 1.6 + peakWhite(rayCol, 0.35) * core * amp * 0.55;
        }
    }

    // ---- background star field (visible only through volume gaps) ----------
    {
        vec2 sv  = uv * vec2(90.0, 50.0);
        vec2 sci = floor(sv);
        vec2 scf = fract(sv);
        float rng  = hash21(sci);
        float rng2 = hash21(sci + 17.3);
        float starR = 0.04 + rng2 * 0.05;
        float star  = smoothstep(starR, 0.0, length(scf - 0.5));
        star *= step(0.92, rng) * transmit;
        vec3 starCol = palVisual(rng + specCentroid * 0.2, u);
        col += starCol * star * (0.35 + trebleE * 0.5);
    }

    // ---- feedback trails (curl-ish UV offset to simulate smoke advection) --
    {
        float swirlFeedback = 0.0015 + swirlAmt * 0.0008;
        float zoomFeedback  = 0.0025;
        col = feedbackTrail(col, uv, u.trailDecay, zoomFeedback, swirlFeedback);
    }

    return col; // LINEAR HDR — post chain tonemaps
}
