// SPDX-License-Identifier: AGPL-3.0-only
// Drift / procedural liquid-glass caustics.
// Layered caustic ribbons drifting at three depths behind dark glass; a lens
// ring floats in the middle, refracting and pulsing with bass. Amplitude
// swells the whole light field; the artwork remains a low-frequency tint.
// Beat response is one smooth swell on beatPhase (~180 ms attack, zero at the
// wrap) instead of instant-attack kick/bassImpact/flux, and every colour keeps
// G+B a fair share of R, so the visual stays within the source flash budget
// (no saturated-red area, <= 6 large-area luma transitions a second).
// param0 Defocus/Flow ; param1 Lens Pulse ; param2 Edge Spectra

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float ar = u.resolution.x / max(u.resolution.y, 1.0);

    // Continuous beat swell: rises over ~180 ms at 120 bpm, releases slowly,
    // and is zero on both sides of the beat wrap.
    float bp = u.beatPhase;
    float sw = smoothstep(0.0, 0.36, bp) * (1.0 - smoothstep(0.40, 1.0, bp));
    float bassSw = sw * (0.45 + 0.55 * u.bass);
    // Light swell centred on the hit: rises over ~150 ms into the beat and
    // eases off over the same, smooth through the wrap. Scaled by the slow
    // level only, so the kick's instant jumps never step it.
    float hitDist = min(bp, 1.0 - bp);
    float pk = (1.0 - smoothstep(0.0, 0.30, hitDist)) * (0.55 + 0.45 * u.level);

    float flowAmt = mix(0.05, 0.24, u.param0);
    float lensPulse = mix(0.00, 0.09, u.param1) * bassSw;
    float spectra = mix(0.15, 1.0, u.param2);

    vec2 flow = p;
    flow += 0.12 * vec2(
        fbm(p * 1.35 + vec2(u.time * flowAmt, -u.time * flowAmt * 0.35)),
        fbm(rot2(0.7) * p * 1.15 + vec2(-u.time * flowAmt * 0.42, u.time * flowAmt))
    ) - 0.06;
    flow += normalize(p + 1e-5) * lensPulse * dot(p, p);

    // A smooth image is only tint. It never supplies full-frame brightness.
    vec3 tint = IMG(photoCover(uv * 0.22 + 0.39, u.resolution, IMGSIZE)).rgb;
    vec3 base = mix(vec3(0.010, 0.017, 0.024), tint * 0.12, 0.28);

    float r = length(p);
    float centralShadow = 1.0 - 0.38 * exp(-r * r * 2.7);
    float vignette = 1.0 - mix(0.60, 0.80, u.param2) * smoothstep(0.42, 1.35, r);
    base *= centralShadow * max(vignette, 0.0) * (0.75 + 0.45 * u.level);

    float swell = 0.95 + 0.45 * u.level + 0.32 * pk; // whole light field breathes

    vec3 glow = vec3(0.0);

    // Three depth layers of caustic ribbons: far (dim, slow, thin) -> near
    // (bright, faster, wider). 6 lanes per layer.
    for (int i = 0; i < 18; i++) {
        float fi = float(i);
        int layer = i / 6;
        float fl = float(layer);
        float depth = mix(1.0, 0.42, fl * 0.5);        // near=1 .. far=0.42
        float scale = mix(1.0, 1.9, fl * 0.5);         // far layers compressed
        float laneSeed = hash11(fi * 2.17 + fl * 9.4);

        float phase = fi * 1.37
                    + u.time * (0.05 + 0.022 * hash11(fi * 4.3)) * depth * (1.0 + u.level);
        vec2 q = rot2(mix(-0.42, 0.46, hash11(fi * 8.1))) * flow * scale;
        // parallax slide per layer
        q.x += u.time * flowAmt * (0.5 - fl * 0.45);

        float curve = sin(q.x * (1.2 + fi * 0.11) + phase) * 0.20
                    + sin(q.x * (2.6 + fi * 0.07) - phase * 0.71) * 0.06;
        float lane = q.y - curve - mix(-0.85, 0.85, laneSeed);
        float width = mix(0.0028, 0.0095, hash11(fi * 5.31)) * (1.0 + fl * 0.9);
        float line = aaLine(lane, width);
        float halo = exp(-abs(lane) * mix(90.0, 40.0, fl * 0.5)) * 0.35;

        float window = smoothstep(1.35, 0.25, abs(q.x) * 0.7);

        float energy = bandAt(u, fract(fi / 18.0 + 0.04 * sin(u.time * 0.13 + fi)));
        vec3 lineCol = palVisual(fract(fi / 18.0 + 0.30 * fl + 0.12 * u.spectralCentroid
                                       + 0.015 * u.time), u);
        lineCol = accentize(lineCol, u.accent, 0.12);
        glow += lineCol * (line + halo) * window
              * (0.35 + energy * 1.05) * depth * swell * 0.55;
    }

    // Lens ring: thin bright rim + faint refracted inner sheen.
    float rimR = 0.34 + 0.045 * bassSw;
    float rim = aaLine(r - rimR, 0.0035);
    float rimHalo = exp(-abs(r - rimR) * 26.0) * 0.30;
    vec3 rimCol = palVisual(0.55 + 0.12 * u.spectralCentroid, u);
    glow += rimCol * (rim + rimHalo) * (0.90 + 0.50 * pk) * swell;
    // interior sheen — the lens gathers the caustic light
    float inner = smoothstep(rimR, rimR * 0.25, r);
    glow += palRoleFog(0.45 + 0.1 * u.spectralCentroid, u)
          * inner * (0.06 + 0.14 * u.level + 0.08 * bassSw);

    // Tiny glints on the lens edge; they reseed each beat while the swell is zero.
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        float a = fi / 10.0 * 6.2831853 + hash11(fi * 0.57) * 0.4;
        float rr = 0.30 + 0.12 * hash11(fi * 1.91 + floor(u.beatCount));
        vec2 sp = vec2(cos(a) * rr / max(ar, 1e-3), sin(a) * rr);
        float d = length(p - sp);
        float spark = min(2.2, 0.00030 / (d * d + 0.00040));
        glow += palHeatIce(fi / 10.0 + 0.1 * u.spectralCentroid) * spark
              * sw * (0.35 + 0.4 * u.treble) * spectra;
    }

    vec3 trailedGlow = feedbackTrail(glow, uv,
                                     min(u.trailDecay, 0.50),
                                     0.0015 + 0.004 * bassSw,
                                     0.0015 * sin(u.time * 0.2));
    vec3 col = base + trailedGlow;
    // Colour floor: reds lean crimson (blue, a touch of green), so dim red
    // tails never round to pure saturated red yet keep their saturation.
    col.gb = max(col.gb, col.r * vec2(0.08, 0.42));
    return col;
}
