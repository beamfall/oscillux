// SPDX-License-Identifier: AGPL-3.0-only
// Cymatics/Prism / frequency + beat.
// A prismatic cymatics ring with audio-carved contours.
// param0 = Density ; param1 = Displace ; param2 = Glow

float ring(float r, float at, float w) {
    return aaLine(r - at, w);
}

// The prism's colour. The prismatic palette starts on pure red (1, 0.06, 0.10); lift green
// where red dominates so G + B stays a fair share of R (coral, never saturated red), also in the
// dim trail tails. Violet and magenta (blue-led) are left alone.
vec3 prismCol(float t, VisualUniforms u) {
    vec3 c = palVisual(t, u);
    c.g = max(c.g, 0.42 * c.r - 0.6 * c.b);
    c.b = max(c.b, 0.12 * c.r);
    return c;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    // Beat swell: ~175 ms smoothstep attack, decaying to zero at the beat wrap, so nothing jumps
    // there. It drives brightness on the thin contours and rims only.
    float swell = smoothstep(0.0, 0.35, u.beatPhase) * (1.0 - u.beatPhase) * (1.0 - u.beatPhase) * 2.0;
    // Motion-only kick: snaps the rims out on the beat and settles back, zero at its wrap.
    float kPhase = fract(u.beatPhase + 0.05);
    float kick = (1.0 - exp(-16.0 * kPhase)) * (1.0 - kPhase) * (1.0 - kPhase);
    float push = kick * (0.4 + 0.6 * u.bass);

    vec2 p = motionCentered(uv, u);
    p.y = (p.y + 0.18) / 0.48;
    // Steady rotation: a beatPhase term here snapped the whole ring back at every beat wrap.
    p = rot2(u.time * 0.035) * p;
    float r = length(p);
    float a = atan2_(p.y, p.x);
    float a01 = a / 6.2831853 + 0.5;
    float audio = bandAtWrapped(u, a01);
    float surface = 0.38 + audio * 0.22 + fbm(vec2(a01 * 5.0, u.time * 0.10)) * 0.035 + push * 0.012;
    vec3 col = vec3(0.0);

    for (int k = -18; k <= 18; k++) {
        float fk = float(k);
        float rr = surface + fk * 0.014;
        float wire = ring(r, rr, 0.00075);
        float crest = 1.0 - min(1.0, abs(fk) / 18.0);
        float spike = smoothstep(0.70, 0.96, fbmRidged(vec2(a01 * 18.0, fk * 0.1 + u.time * 0.12)));
        vec3 c = prismCol(a01 + fk * 0.012 + u.spectralCentroid * 0.08, u);
        col += c * wire * (0.10 + crest * crest * (audio * 2.6 + swell * 0.8));
        col += peakWhite(c, spike * crest * u.treble * 0.14) * wire * spike * crest * 1.8;
    }

    float aperture = ring(r, 0.18 + push * 0.030, 0.004);
    float outer = ring(r, 0.66 + push * 0.045, 0.004);
    col += prismCol(a01 + 0.33, u) * aperture * 2.0;
    col += prismCol(a01, u) * outer * (0.55 + 0.5 * u.bass + swell * 0.9);
    float beam = exp(-abs(p.y) * 42.0) * smoothstep(0.92, 0.10, abs(p.x)) * (0.04 + 0.12 * u.bass + swell * 0.22);
    col += prismCol(a01 + 0.08, u) * beam;
    col *= smoothstep(1.25, 0.42, r);
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.86), 0.0025 + 0.003 * push, 0.003);
    return col; // LINEAR HDR — post chain tonemaps
}
