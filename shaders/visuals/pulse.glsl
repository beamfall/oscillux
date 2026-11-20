// SPDX-License-Identifier: AGPL-3.0-only
// Pulse — "Black-room Solar Core"
// param0 = Glow ; param1 = Impact ; param2 = Corona Count

// Beat swell on the beat clock: rises over the first ~180 ms of a beat (at 120 BPM) and eases
// back over the rest, 0 at both ends of the beat so it never jumps at the wrap. The core grows
// with it instead of flashing on the instant kick or onset (CORE-2659 source flash budget).
float pulseSwell(VisualUniforms u) {
    float ph = clamp(u.beatPhase, 0.0, 1.0);
    return smoothstep(0.0, 0.36, ph) * (1.0 - smoothstep(0.36, 1.0, ph));
}

// The same swell for corona ring i, delayed 0.07 beat per ring and done within 0.7 beat, so each
// beat sends one soft ripple outward through the rings and every ring is back at rest before the
// beat wraps.
float pulseRipple(VisualUniforms u, float fi) {
    float x = (clamp(u.beatPhase, 0.0, 1.0) - 0.07 * fi) / 0.7;
    return smoothstep(0.0, 0.4, x) * (1.0 - smoothstep(0.4, 1.0, x));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2  p = motionCentered(uv, u);
    float r = length(p);
    float a = atan2_(p.y, p.x);

    float glowAmt   = mix(0.25, 1.40, u.param0);
    float impactAmt = mix(0.06, 0.26, u.param1);
    int   numCorona = int(mix(3.0, 5.0, u.param2) + 0.5);

    // Loudness enters only through the slow level and the beat-clock swell: amplitude, bass and
    // onset change within a frame on every kick, and the rings, core and sparks they moved made
    // the whole disc flash 30 times a second under loud audio. The picture itself stays large,
    // bright and saturated all the time; it is the change, not the level, that would flash.
    float level   = saturate(u.level);
    float level01 = 0.5 + 0.5 * level;
    float swell   = pulseSwell(u) * level01;
    // beat count that eases forward over each beat and never jumps back at the wrap
    float beatGlide = floor(u.beatCount) + smoothstep(0.0, 1.0, u.beatPhase);

    float breathe = 0.007 * sin(u.time * 1.1) + 0.005 * sin(u.time * 2.3 + 0.8);
    // only the core breathes and swells on the beat: the corona rings hold their radii, as every
    // ring edge and feedback copy that moves with them changes at once, and with the sparks that
    // held most of the disc in the flash limiter whenever the breath moved fastest
    float ringBase = 0.12 + 0.06 * level;
    float spacing  = 0.083;
    float coreR    = ringBase + breathe + impactAmt * 0.09 * swell;
    float outerR   = ringBase + float(numCorona) * spacing;

    vec3 col = vec3(0.0);
    {
        float rSafe = max(r, 1e-4);
        float inner = smoothstep(coreR, coreR * 0.40, rSafe);
        // a solid white-hot rim band with soft edges a couple of pixels wide
        float rimW  = 0.022;
        float rim   = 1.0 - smoothstep(rimW * 0.55, rimW * 1.35, abs(rSafe - coreR));

        // hot pink core with an amber edge; G and B never drop to zero, so no pixel reads as
        // pure red
        vec3 coreCol = mix(vec3(1.00, 0.36, 0.08), vec3(1.00, 0.10, 0.70),
                           smoothstep(0.2, 1.0, inner));
        coreCol = mix(coreCol, vec3(0.30, 0.82, 1.00), rim * 0.35);
        float exposure = 0.85 + 1.25 * level;
        col += coreCol * (inner * 2.1 + rim * 3.0) * exposure;

        // a steady amber line just outside the rim
        float edgeD = rSafe - (coreR + 0.026);
        float edge  = exp(-(edgeD * edgeD) / (0.006 * 0.006));
        col += vec3(1.00, 0.46, 0.10) * edge * 1.2;
    }

    {
        // Contract rule 8: compile-time-constant loop bound (numCorona tops out
        // at 5); break on the dynamic count instead of looping on it directly.
        for (int i = 0; i < 5; ++i) {
            if (i >= numCorona) break;
            float fi    = float(i);
            float ringR = ringBase + (fi + 1.0) * spacing;
            float ripple = pulseRipple(u, fi);

            // turbulence sampled on the unit circle, so the wobble has no seam at the -x axis
            vec2  dir     = p / max(r, 1e-4);
            float turb    = fbm(dir * (1.1 + fi * 0.2) + vec2(fi * 1.7 + u.time * (0.03 + fi * 0.01), r));
            float d       = r - ringR - turb * 0.020;

            // a solid band with soft edges, so the slow turbulence moves a gradient over a pixel
            // rather than snapping a hairline on and off it
            float halfW = 0.017 - fi * 0.0010;
            float mask  = 1.0 - smoothstep(halfW - 0.005, halfW + 0.004, abs(d));

            // orange, two yellows, then pink and violet-blue outside: never the palette's red end.
            // The angular drift is a smooth sin so the ring has no colour seam at the -x axis.
            float baseHue = fi < 0.5 ? 0.19 : (fi < 1.5 ? 0.40 : (fi < 2.5 ? 0.44 : (fi < 3.5 ? 0.74 : 0.86)));
            float hue = baseHue + 0.02 * beatWave(u, 0.0)
                      + 0.02 * (1.0 + sin(a + fi * 1.7)) + 0.02 * saturate(u.spectralCentroid);
            hue = min(hue, 0.95);
            vec3 ringCol = palVisual(hue, u);
            ringCol      = accentize(ringCol, u.accent, 0.12);

            float bright = glowAmt * (1.15 - fi * 0.10) * (0.9 + 0.45 * level);
            bright = max(bright, 0.0);

            col += ringCol * mask * bright;
            // a steady soft glow under every ring, plus the beat ripple: a wide, faint glow that
            // rolls out through the rings, well under a 0.1 luminance step on any pixel
            float glowW = 0.035;
            col += ringCol * exp(-(d * d) / (glowW * glowW)) * (0.05 + 0.44 * impactAmt * level01 * ripple) * glowAmt;
        }
    }

    {
        // a constant warm halo around the outer rings, fading out past the disc, that leaves the gaps
        // between the inner rings dark
        float halo = exp(-pow(max(r - outerR + 0.04, 0.0) / 0.14, 2.0))
                   * smoothstep(coreR, outerR, r);
        col += vec3(1.00, 0.55, 0.45) * halo * 0.12 * glowAmt;
    }

    {
        // treble sparks: steady brightness from the slow treble level, and an orbit that glides
        // forward over each beat instead of jumping on it. The glide is a small step per beat:
        // 32 sparks sweeping a quarter radian a beat changed enough of the disc at once, with
        // the core swell, to count as large-area flashes at fast tempos
        float trebleE = 0.55 + 0.35 * saturate(u.treble);
        float bandOuter = outerR + 0.06;
        for (int i = 0; i < 32; ++i) {
            float fi = float(i);
            vec2  h  = hash22(vec2(fi, 3.7));
            float sr = mix(ringBase + 0.03, bandOuter, h.x);
            float sa = h.y * 6.2831853 + u.time * (0.25 + 0.35 * h.x) + beatGlide * 0.10;
            vec2  sp = vec2(cos(sa), sin(sa)) * sr;
            float dd = length(p - sp);
            // a bright point with a soft glow whose long tail is cut off, so 32 tails do not
            // add up to a haze over the gaps between the rings
            float spark = min(7e-5 / (dd * dd + 7e-5), 3.0) * exp(-(dd * dd) / 0.0016);
            float flicker = 0.85 + 0.15 * sin(u.time * 2.0 + fi * 2.3);
            vec3 scol = palVisual(0.70 + 0.28 * h.x + 0.02 * u.spectralCentroid, u);
            scol = mix(scol, vec3(0.90, 0.97, 1.00), 0.30);
            col += scol * spark * trebleE * flicker * 4.0;
        }
    }

    float outerFade = ringBase + float(numCorona) * 0.09 + 0.12;
    col *= 1.0 - smoothstep(outerFade, outerFade + 0.18, r);

    // a steady outward zoom: the rings' feedback copies spread into a soft glow beyond the disc
    float trailZoom = 0.003;
    float trailRot  = 0.0006;
    col = feedbackTrail(col, uv, u.trailDecay, trailZoom, trailRot);

    return col; // LINEAR HDR — post chain tonemaps
}
