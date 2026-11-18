// SPDX-License-Identifier: AGPL-3.0-only
// Ripple / beat + spectrum cymatics ripples.
// param0 = Ring Width ; param1 = Expansion ; param2 = Persistence

vec3 visual(vec2 uv, VisualUniforms u) {
    const float TEXTURE_REPEATS = 6.0;
    // Param mapping
    float ringHalfW   = mix(0.003, 0.022, u.param0);
    float expansion   = mix(0.28,  1.40,  u.param1);
    float persistence = mix(0.40,  0.92,  u.param2);

    // Coordinate setup — aspect-correct centered space
    vec2  p = motionCentered(uv, u);
    float a = atan2_(p.y, p.x);
    float ang01 = a / 6.2831853 + 0.5;

    // Per-angle spectrum read — used to distort ring radii (cymatics contours).
    // Wrap frequency: one monotone sweep per revolution, the same angular
    // frequency the ring contour has always had. bandAtWrapped closes the band
    // array into a loop, so an integer angular multiplier is periodic across the
    // atan2 wrap on the -x axis (ang01 == 0 vs ang01 == 1) and the ring radius
    // joins there instead of jumping (contract rule 13). The multiplier had to
    // go 0.55 -> 1.0: on a circle a continuous read cannot sweep a sub-range
    // monotonically, so the sweep spans the whole spectrum. Folding the old
    // sub-range back on itself instead (0.5-0.5*cos) also joins, but doubles the
    // contour frequency and mirrors it.
    float specBin  = bandAtWrapped(u, ang01 + 0.05);
    float specBin2 = bandAtWrapped(u, ang01 + 0.30);
    float warp     = specBin * 0.18 + specBin2 * 0.09;

    // Noise domain on a circle of radius 3.2/2pi: it traverses 3.2 domain units
    // per revolution, the same rate as the old fbm(ang01*3.2) ramp, so the noise
    // feature scale per unit angle is preserved — it just no longer tears.
    vec2 fbmDomain = vec2(cos(ang01 * 6.2831853), sin(ang01 * 6.2831853))
                     * (3.2 / 6.2831853)
                   + vec2(u.time * 0.07, (u.beatCount + u.beatPhase) * 0.17);
    float fbmAngle = fbm(fbmDomain);
    warp += (fbmAngle - 0.5) * 0.06 * (0.3 + u.mid * 0.7);

    // Ring train — 7 rings cycling in phase, seeded by beatCount for variation
    const int NRINGS = 7;
    vec3 col = vec3(0.0);

    // One continuous beat clock. The rings used to ride beatPhase (which wraps
    // every beat), a per-beat beatCount reseed and time * an audio-driven speed,
    // so every beat teleported the whole ring train and each pixel flickered:
    // a large-area flash. Now the beat only eases the train outward.
    float beatClock = u.beatCount + smoothstep(0.0, 1.0, u.beatPhase);

    for (int k = 0; k < NRINGS; ++k) {
        float fk = float(k);

        float phase = fract(fk / float(NRINGS) + beatClock * 0.10 + u.time * 0.04);

        float ringR   = phase * expansion;
        float ringRW  = ringR + warp * ringR;

        float r = length(p);
        float dist = abs(r - ringRW);

        float lineMask = aaLine(dist, ringHalfW);

        float age   = clamp(phase, 0.0, 1.0);
        float ageFade = pow(1.0 - age, 1.6 + u.param2 * 0.8);

        // Kick heat stays on the newborn ring near the centre (small area),
        // with a gentle boost instead of a 5x HDR slam.
        float birthAge    = smoothstep(0.18, 0.0, phase);
        float beatBoost   = 1.0 + birthAge * (u.bassImpact * 1.2 + u.beat * 0.5);

        float brightness = lineMask * ageFade * beatBoost *
                           (0.45 + u.amplitude * 0.55);

        float palT   = fract(phase * 0.55 + fk * 0.13 + u.spectralCentroid * 0.12
                             + u.time * 0.04);
        vec3 ringCol = palVisual(palT, u);

        vec3 hotBirth = vec3(1.7, 0.28, 0.03);
        ringCol = mix(ringCol, hotBirth, birthAge * 0.6 * saturate(u.bassImpact + u.beat));
        ringCol = peakWhite(ringCol, birthAge * u.bassImpact * 0.32);

        ringCol = accentize(ringCol, u.accent, 0.10);

        float hdrScale = mix(1.4, 2.2, birthAge * saturate(u.bassImpact + u.beat * 0.6));
        col += ringCol * brightness * hdrScale;
    }

    // Onset / treble: thin secondary caustic shards.
    if (u.onset > 0.05 || u.treble > 0.30) {
        float r = length(p);
        for (int s = 0; s < 4; s++) {
            float shardR = (0.15 + float(s) * 0.11) * expansion;
            float shardR2 = shardR + warp * shardR * 0.6;
            float shardDist = abs(r - shardR2);
            float shardMask = aaLine(shardDist, ringHalfW * 0.35);
            float angMod = 0.5 + 0.5 * sin(ang01 * 6.2831853 * TEXTURE_REPEATS
                                           + u.time * 1.8);
            vec3 shardCol = palVisual(ang01 + float(s) * 0.22, u);
            shardCol = peakWhite(shardCol, saturate(u.treble * u.onset * 0.35));
            // thin accents: kept well below the rings so onsets glint, not strobe
            col += shardCol * shardMask * angMod
                   * (u.onset * 0.6 + u.treble * 0.5);
        }
    }

    // Feedback trails: small outward zoom → persistent expanding rings.
    // steady zoom: a bass-pumped zoom smeared the whole trail field each kick
    float zoom    = 0.004 + 0.002 * u.bassImpact * u.param1;
    float rotAmt  = 0.0015 * u.mid;
    float effDecay = u.trailDecay * (0.75 + 0.25 * persistence);
    col = feedbackTrail(col, uv, effDecay, zoom, rotAmt);

    return col; // LINEAR HDR — post chain tonemaps
}
