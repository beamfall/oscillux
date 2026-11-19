// SPDX-License-Identifier: AGPL-3.0-only
// Ripple / beat + spectrum cymatics ripples.
// param0 = Ring Width ; param1 = Expansion ; param2 = Persistence
//
// Flash budget (CORE-2659): every pixel inside the ring field is crossed by
// the ring train, and each crossing is one rise and one fall of luminance, so
// the train's speed times its ring count sets how much of the frame flashes in
// any 1/15 s. Rings drift slowly and the beat eases them instead of throwing
// them; nothing jumps on the kick (instant kick, onset, bassImpact and
// amplitude reads are gone), and the beat heat is a swell built from the
// continuous beatPhase clock (~150 ms attack, the rest of the beat to fall).

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
    float r = length(p);

    // Beat swell: ~0.3 beat rise from the beat, falling over the rest of it, so
    // heat breathes with the music instead of stepping on the kick. Zero at
    // both ends of the beat, so it is continuous across the beat wrap.
    float swell = smoothstep(0.0, 0.3, u.beatPhase)
                * (1.0 - smoothstep(0.3, 1.0, u.beatPhase))
                * saturate(u.level * 1.2);

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
    // Low gain: the spectrum steps on every kick, and a large gain jolted every
    // ring outward at once (a frame-wide flash). The contour stays readable.
    float specBin  = bandAtWrapped(u, ang01 + 0.05);
    float specBin2 = bandAtWrapped(u, ang01 + 0.30);
    float warp     = specBin * 0.05 + specBin2 * 0.025;

    // Noise domain on a circle of radius 3.2/2pi: it traverses 3.2 domain units
    // per revolution, the same rate as the old fbm(ang01*3.2) ramp, so the noise
    // feature scale per unit angle is preserved — it just no longer tears.
    vec2 fbmDomain = vec2(cos(ang01 * 6.2831853), sin(ang01 * 6.2831853))
                     * (3.2 / 6.2831853)
                   + vec2(u.time * 0.05, (u.beatCount + u.beatPhase) * 0.12);
    float fbmAngle = fbm(fbmDomain);
    warp += (fbmAngle - 0.5) * 0.08 * (0.3 + u.mid * 0.7);

    // Ring train — rings cycling in phase on one continuous beat clock.
    const int NRINGS = 6;
    vec3 col = vec3(0.0);

    // The beat eases the train outward (smoothstep over each beat), a gentle
    // surge, never a jump. Slow enough that a pixel sees about one ring pass a
    // second: faster trains crossed a quarter of the field every 1/15 s.
    float beatClock = u.beatCount + mix(u.beatPhase, smoothstep(0.0, 1.0, u.beatPhase), 0.6);
    float sustain   = 0.55 + u.level * 0.45;

    for (int k = 0; k < NRINGS; ++k) {
        float fk = float(k);

        float phase = fract(fk / float(NRINGS) + beatClock * 0.032 + u.time * 0.014);

        float ringR   = phase * expansion;
        float ringRW  = ringR + warp * ringR;

        float dist = abs(r - ringRW);

        // Crisp core plus a soft halo: the halo makes the ring read as glowing
        // without adding fast edges.
        float lineMask = aaLine(dist, ringHalfW);
        float halo     = exp(-dist * dist / (ringHalfW * ringHalfW * 9.0 + 1e-5)) * 0.35;

        float age     = clamp(phase, 0.0, 1.0);
        float ageFade = pow(1.0 - age, 1.6 + u.param2 * 0.8);
        // Fade in from the centre: a ring is born dark and brightens over its
        // first tenth instead of popping in at full strength at the wrap.
        ageFade *= smoothstep(0.0, 0.08, phase);

        // Beat heat stays on the newborn ring near the centre (small area).
        float birthAge  = smoothstep(0.22, 0.0, phase);
        float heat      = birthAge * swell;

        float brightness = (lineMask + halo) * ageFade * sustain * (1.0 + heat * 0.5);

        float palT   = fract(phase * 0.55 + fk * 0.13 + u.spectralCentroid * 0.12
                             + u.time * 0.03);
        vec3 ringCol = palVisual(palT, u);

        // Gold, not red: newborn rings blaze gold (R well under 80% of the sum).
        vec3 hotBirth = vec3(1.55, 0.95, 0.30);
        ringCol = mix(ringCol, hotBirth, birthAge * (0.35 + 0.35 * swell));
        ringCol = peakWhite(ringCol, heat * 0.25);

        ringCol = accentize(ringCol, u.accent, 0.10);

        float hdrScale = mix(1.4, 1.9, heat);
        col += ringCol * brightness * hdrScale;
    }

    // Treble: thin caustic shards. They drift slowly round their rings and
    // follow the sustained treble, so they glint without strobing.
    for (int s = 0; s < 4; s++) {
        float shardR = (0.15 + float(s) * 0.11) * expansion;
        float shardR2 = shardR + warp * shardR * 0.6;
        float shardDist = abs(r - shardR2);
        float shardMask = aaLine(shardDist, ringHalfW * 0.35);
        float angMod = 0.5 + 0.5 * sin(ang01 * 6.2831853 * TEXTURE_REPEATS
                                       + u.time * 0.35 + float(s) * 1.7);
        vec3 shardCol = palVisual(ang01 + float(s) * 0.22, u);
        col += shardCol * shardMask * angMod * angMod
               * (0.12 + u.treble * 0.22 + swell * 0.10);
    }

    // Feedback trails: small steady outward zoom → persistent expanding rings.
    float zoom    = 0.0045;
    float rotAmt  = 0.0012 * u.mid;
    float effDecay = u.trailDecay * (0.75 + 0.25 * persistence);
    col = feedbackTrail(col, uv, effDecay, zoom, rotAmt);

    return col; // LINEAR HDR — post chain tonemaps
}
