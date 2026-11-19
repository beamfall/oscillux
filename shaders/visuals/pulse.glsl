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
    // the whole disc flash 30 times a second under loud audio.
    float level = saturate(u.level);
    float swell = pulseSwell(u) * (0.5 + 0.5 * level);
    // beat count that eases forward over each beat and never jumps back at the wrap
    float beatGlide = floor(u.beatCount) + smoothstep(0.0, 1.0, u.beatPhase);

    float breathe = 0.007 * sin(u.time * 1.1) + 0.005 * sin(u.time * 2.3 + 0.8);
    // only the core swells on the beat: the corona rings hold their radii, as their feedback
    // copies fill a disc that flickered whole when they moved
    float ringBase = 0.15 + 0.03 * level + breathe;
    float coreR    = ringBase + impactAmt * 0.07 * swell;
    float level01  = 0.5 + 0.5 * level;

    vec3 col = vec3(0.0);
    {
        float rSafe = max(r, 1e-4);
        float inner = smoothstep(coreR, coreR * 0.40, rSafe);
        float rim   = exp(-pow((rSafe - coreR) / 0.022, 2.0));

        // amber edge, never saturated red: R stays well under 0.8 of R + G + B
        vec3 coreCol = mix(vec3(1.00, 0.52, 0.16), vec3(1.00, 0.30, 0.72),
                           smoothstep(0.2, 1.0, inner));
        coreCol = mix(coreCol, vec3(0.30, 0.82, 1.00), rim * 0.45);
        float exposure = 0.85 + 1.25 * level;
        col += coreCol * (inner * 2.1 + rim * 1.6) * exposure;
        // a wide, faint corona haze that breathes with the swell: a small change per pixel
        float haze = exp(-max(rSafe - coreR, 0.0) / 0.07) * (1.0 - inner);
        col += vec3(1.00, 0.55, 0.30) * haze * (0.10 + 0.10 * swell) * glowAmt;
    }

    {
        float spacing = 0.075;
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

            // soft ring: a gaussian a few pixels wide, so the slow turbulence moves a gradient
            // over a pixel rather than snapping a hairline on and off it
            float halfW = max(0.010 - fi * 0.0008, 0.006);
            float mask  = exp(-(d * d) / (halfW * halfW));

            // hues from orange through yellow and pink to violet-blue, never the palette's red end;
            // the angular drift is a smooth sin so the ring has no colour seam at the -x axis
            float hue = 0.20 + fi * 0.17 + 0.03 * beatWave(u, 0.0)
                      + 0.03 * (1.0 + sin(a + fi * 1.7)) + 0.04 * saturate(u.spectralCentroid);
            hue = min(hue, 0.97);
            vec3 ringCol = palVisual(hue, u);
            ringCol      = accentize(ringCol, u.accent, 0.12);

            float bright = glowAmt * (1.10 - fi * 0.16) * (0.85 + 0.25 * level);
            bright = max(bright, 0.0);

            col += ringCol * mask * bright;
            // the beat ripple: a wide, faint glow that rolls out through the rings. It stays well
            // under a 0.1 luminance step on any pixel, so it reads as a swell of light, not a flash.
            float glowW = 0.035;
            col += ringCol * exp(-(d * d) / (glowW * glowW)) * (0.06 + 0.44 * impactAmt * level01 * ripple) * glowAmt;
        }
    }

    {
        // treble sparks: steady brightness from the slow treble level, small tight cores, and an
        // orbit that glides forward over each beat instead of jumping on it
        float trebleE = 0.35 + 0.45 * saturate(u.treble);
        float bandOuter = ringBase + float(numCorona) * 0.075 + 0.05;
        for (int i = 0; i < 32; ++i) {
            float fi = float(i);
            vec2  h  = hash22(vec2(fi, 3.7));
            float sr = mix(ringBase + 0.03, bandOuter, h.x);
            float sa = h.y * 6.2831853 + u.time * (0.10 + 0.15 * h.x) + beatGlide * 0.12;
            vec2  sp = vec2(cos(sa), sin(sa)) * sr;
            float dd = length(p - sp);
            float spark = 1.5e-5 / (dd * dd + 1.5e-5);
            float flicker = 0.85 + 0.15 * sin(u.time * 2.0 + fi * 2.3);
            vec3 scol = palVisual(0.30 + 0.60 * h.x + 0.05 * u.spectralCentroid, u);
            col += scol * spark * trebleE * flicker * 2.2;
        }
    }

    float outerFade = ringBase + float(numCorona) * 0.09 + 0.12;
    col *= 1.0 - smoothstep(outerFade, outerFade + 0.18, r);

    float trailZoom = 0.002;
    float trailRot  = 0.0004;
    col = feedbackTrail(col, uv, u.trailDecay, trailZoom, trailRot);

    return col; // LINEAR HDR — post chain tonemaps
}
