// SPDX-License-Identifier: AGPL-3.0-only
// Nebula — frequency + beat.
//
// Volumetric smoke threaded with spectrum lightning around a dark core.
// Performance path: layered analytic shells, not a full raymarch: 12 shells at full
// detail, down to 6 as the host raises presentation1.y, each weighted to keep density.
// DARK CORE enforced: radial carve + density clamp keeps the center black.
// Lightning filaments driven by treble; the beat turns and stirs the cloud.
//
// Flash budget (Makefile visual-flash-check): the beat moves the smoke and swells the core and
// filaments through a smooth envelope (about 150 ms attack, the rest of the beat to release),
// never as a brightness step. Kick-gated signals (bassImpact, flux, onset, the low bins) do not
// touch brightness, geometry or hue over large areas, and nothing is re-seeded per frame or per
// beat: each filament fades in and out over a four-beat life, one taking over each beat.
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
    float hazeOuter = 1.0 - smoothstep(0.75, 1.95, radius);

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
        // Broad glowing gas: a softer, wider cut of the same field, fading out toward the corners.
        float haze = smoothstep(0.48, 0.90, rawDens) * coreMask * hazeOuter;
        dens *= (0.30 + 0.70 * smoothstep(0.40, 0.92, ridgeB));
        dens *= coreMask * outerMask * densScale * (0.40 + levelE * 0.20);
        dens = min(dens, 0.20);

        // Ridge glints: treble lights the crests; fixed to the smoke, so they drift, not sparkle.
        float ridgeLine = smoothstep(0.78, 0.97, ridgeA) * (0.25 + trebleBand * 0.9 + trebleE * 0.35);

        vec3 smokeCol = accentize(palVisual(fi * 0.55 + specCentroid * 0.22 + t * 0.04, u), u.accent, 0.10);
        vec3 litCol = palVisual(0.75 + specCentroid * 0.2 - fi * 0.15, u);
        float stir = swell * depth * 0.18; // the beat warms the near shells a little

        float alpha = min(dens * 0.55, 0.12) * layerWeight;
        vec3 emissive = smokeCol * (dens * 4.0 * emitScale * (1.0 + stir))
                      + litCol * (ridgeLine * dens * 9.0 * emitScale);
        vec3 hazeCol = palVisual(0.20 + radius * 0.42 + fi * 0.10 + specCentroid * 0.15 + t * 0.03, u);
        col += transmit * (alpha * emissive
                         + hazeCol * haze * densScale * emitScale * (0.075 + 0.030 * levelE) * invLayers * 6.0);
        transmit *= (1.0 - alpha * 0.45);
    }

    // ---- spectrum lightning filaments (screen-space, on top of volume) -----
    // Four-beat lives, staggered one beat apart: filament j is born on beats where
    // (beatCount - j) % 4 == 0, fades in, holds, fades out, and is re-seeded only while dark.
    {
        for (int j = 0; j < 5; ++j) {
            float fj = float(j);
            float age = (mod(u.beatCount - fj, 4.0) + ph) * 0.25;   // 0..1 over the life
            float gen = floor((u.beatCount - fj) * 0.25 + 1e-3);
            float life = smoothstep(0.0, 0.35, age) * (1.0 - smoothstep(0.65, 1.0, age));
            vec2 h   = hash22(vec2(fj * 3.1 + gen * 1.37, 7.3 + fj));
            float fAngle = h.x * 6.2831853 + t * 0.5 + (age - 0.5) * 0.35 * (h.y - 0.5);
            vec2 fDir = vec2(cos(fAngle), sin(fAngle));
            float proj = dot(p0, fDir);
            float dist = length(p0 - fDir * proj);
            float reach = 0.7 + 0.5 * life + swell * 0.08;
            float along = smoothstep(reach + 0.25, coreRadius + 0.1, proj);
            along *= smoothstep(coreRadius - 0.05, coreRadius + 0.25, radius);
            float bolt = exp(-dist * dist * 3200.0) * along;
            bolt *= life * (0.30 + trebleE * 0.35 + trebleBand * 0.25) * (0.55 + h.y * 0.45);
            vec3 boltCol = palVisual(h.x + specCentroid * 0.3, u);
            col += boltCol * bolt * (0.75 + swell * 0.2);
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
