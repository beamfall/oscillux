// SPDX-License-Identifier: AGPL-3.0-only
// Glyph — frequency + beat.
//
// Rotating spectral sigil with radial bars and broken rings.
// Polar linework, visually distinct from Kaleidoscope's folded mandala.
// param0 Rings, param1 Rotation, param2 Glyph Density
//
// Flash budget (limiter-red-audit --audio loud): the linework is thin and dense over most of the
// sigil, so brightness may not follow the beat or the spectrum. The music moves geometry (ring
// radius, spoke length, line weight) and shifts hue within one brightness band; the beat swells
// only the small hub ring, with a slow attack. Lines are soft and kept below clipping so a
// sub-pixel move changes a pixel gradually, and rotation stays slow.

// Soft line: a Gaussian core at least ~1.3 px wide, so motion fades pixels instead of toggling them.
float glyphLine(float d, float halfWidth) {
    float w = max(halfWidth, 1.3 * fwidth(d));
    return exp(-(d * d) / (w * w));
}

// Beat swell for the hub: ~150 ms rise after the beat, slow release through the rest of the beat.
float glyphSwell(VisualUniforms u) {
    float ph = saturate(u.beatPhase);
    return smoothstep(0.0, 0.3, ph) * (1.0 - smoothstep(0.3, 1.0, ph));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float spin = u.time * mix(0.012, 0.06, u.param1);
    p = rot2(spin) * p;
    float r = length(p);
    float a = atan2_(p.y, p.x);
    float ang = a / 6.2831853 + 0.5;

    float rings = mix(4.0, 11.0, u.param0);
    // integer dash count so the ring joins across the ang 1->0 wrap (rule 13)
    float density = floor(mix(12.0, 42.0, u.param2) + 0.5);
    float hue = 0.10 * u.spectralCentroid;
    vec3 glow = vec3(0.0);

    for (int k = 0; k < 11; k++) {
        if (float(k) >= rings) break;
        float fk = float(k);
        float bandv = bandAtWrapped(u, fk / 11.0 + ang);
        // rings breathe with their band; alternate rings counter-drift slowly against the spin
        float rr = 0.12 + fk * 0.065 + 0.010 * sin(u.time * 0.3 + fk) + bandv * 0.028;
        float drift = (mod(fk, 2.0) < 0.5 ? 1.0 : -1.0) * u.time * 0.010;
        float cell = fract((ang + drift) * (density + fk * 2.0) + fk * 0.23);
        float dash = smoothstep(0.04, 0.16, cell) * smoothstep(0.74, 0.58, cell);
        float line = glyphLine(r - rr, 0.0035 + bandv * 0.0025) * dash;
        vec3 c = palVisual(ang + fk * 0.08 + hue + 0.12 * bandv, u);
        glow += c * line * (0.55 + 0.10 * bandv);
    }

    float swell = glyphSwell(u);
    for (int i = 0; i < 32; i++) {
        float fi = float(i);
        float spokeA = fi / 32.0;
        float ad = abs(fract(ang - spokeA + 0.5) - 0.5) * 6.2831853 * max(r, 0.05);
        float bandv = bandAt(u, spokeA);
        float reach = 0.66 + bandv * 0.22;
        float spoke = glyphLine(ad, 0.0018 + r * (0.0065 + bandv * 0.0045)) *
                      smoothstep(0.10, 0.18, r) * (1.0 - smoothstep(reach - 0.10, reach + 0.04, r));
        vec3 c = palVisual(0.62 + spokeA * 0.28 + hue + 0.08 * bandv, u);
        glow += c * spoke * (0.40 + 0.08 * bandv + 0.08 * swell);
    }

    // hub ring: the strongest beat-led brightness, small and with a slow attack
    glow += palVisual(0.58 + hue, u) * glyphLine(r - 0.085, 0.0045) * (0.45 + 0.35 * swell * u.level);

    vec3 col = feedbackTrail(glow, uv, min(u.trailDecay, 0.84), 0.0015, 0.0);
    return col; // LINEAR HDR — post chain tonemaps
}
