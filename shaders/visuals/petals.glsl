// SPDX-License-Identifier: AGPL-3.0-only
// Petals — spectral flower/speaker-cone rosette.
// param0 Petal Count ; param1 Bloom ; param2 Detail
//
// Flash budget (CORE-2659): brightness holds one band. The music moves the rosette (a swell that
// runs round the rim each beat, a spectral ripple along it) and shifts its colour; no term jumps
// brightness or size on the kick, nothing turns the whole rosette with the beat, and the trail
// neither zooms nor spins with it, so no large area flips light and dark several times a second.
// Size, the nested petal layers and the bright rims are steady, so the rosette stays large and
// ornate without the beat having to pump it.

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float r = length(p);
    float a = atan2_(p.y, p.x);
    float ang = a / 6.2831853 + 0.5;

    // Beat breath: continuous across the beat wrap, rising over half a beat to a peak just after
    // the beat and falling over the other half; scaled by the smoothed level, so silence is still.
    float breath = 0.5 + 0.5 * cos(6.2831853 * (u.beatPhase - 0.18));
    breath *= breath * saturate(u.level);
    // The same breath as a swell that runs once round the rosette each beat, so the rim never
    // moves everywhere at once.
    float swell = 0.5 + 0.5 * cos(6.2831853 * (u.beatPhase - 0.18 - ang));
    swell *= swell * saturate(u.level);

    float petals = mix(6.0, 18.0, u.param0);
    // Steady full size (the original reached this only on the kick); the swell adds a little.
    float bloom = mix(0.24, 0.62, u.param1) * (1.20 + 0.02 * swell);
    float detail = mix(0.4, 1.6, u.param2);

    // The spectrum shapes the rim; its weight is small so a kick moves the rim a few pixels.
    float wave = abs(cos(a * petals * 0.5 + u.time * 0.12));
    float bandv = bandAt(u, fract(ang + 0.05 * u.beatPhase));
    float petalR = bloom * (0.58 + wave * (0.86 + bandv * 0.08));
    float edge = aaLine(r - petalR, 0.0075);
    float halo = exp(-abs(r - petalR) / 0.014);
    // Layered petals: nested copies of the rim inside it, each a little dimmer, drawn steadily
    // (the original got these from a kick-driven trail zoom).
    float layers = aaLine(r - petalR * 0.86, 0.0055) * 0.80 +
                   aaLine(r - petalR * 0.74, 0.0045) * 0.60;
    float inner = aaLine(r - petalR * 0.62, 0.0035);
    float inside = 1.0 - smoothstep(petalR - 0.004, petalR + 0.004, r);
    float vein = aaLineCyclic(ang * petals + r * 2.0, 0.020) *
                 smoothstep(0.05, petalR, r) * inside;

    vec3 c = palVisual(ang + 0.12 * u.spectralCentroid + 0.04 * breath, u);
    c = accentize(c, u.accent, 0.10);
    // A steady petal body: brightest towards the rim, fading to the heart.
    float body = inside * smoothstep(0.10, petalR, r) * exp(-(petalR - r) / 0.10);
    vec3 glow = c * body * 0.55;
    vec3 rim = peakWhite(c, 0.18);
    glow += rim * edge * (2.6 + 0.25 * breath);
    glow += c * halo * 0.35;
    glow += peakWhite(c, 0.12) * layers * 1.6;
    glow += palVisual(ang + 0.2, u) * inner * (0.55 + 0.25 * u.level);
    glow += c * vein * detail * (0.45 + 0.15 * bandv);
    glow += peakWhite(palVisual(0.58 + 0.08 * u.spectralCentroid, u), 0.10 + 0.06 * breath) *
            exp(-r * r / 0.030) * (0.30 + 0.45 * saturate(u.level));

    // A blue floor: dim pinks stay pink, never saturated red that the limiter must hold.
    glow.b = max(glow.b, 0.50 * glow.r);
    vec3 col = feedbackTrail(glow, uv,
                             min(u.trailDecay, 0.82),
                             0.0015 + 0.0010 * breath,
                             0.0);
    return col;
}
