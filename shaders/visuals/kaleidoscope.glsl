// SPDX-License-Identifier: AGPL-3.0-only
// Kaleidoscope — frequency + beat.
//
// Radial spectrum mandala around a dark event horizon. Angular wedge folding
// produces nested mirrored rings; spectrum bins map to radial teeth; the beat
// surges the spin and breathes the void, rim, tooth caps and thin rays along
// the fold seams; feedbackTrail with zoom-in rotation creates
// tunnel trails.
//
// Flash budget: the teeth fill most of the frame, so their body brightness
// stays steady and the music moves their length, the spin and the colour.
// Brightness swells ride a beat envelope with a ~150 ms attack and a long
// release, and only on thin or small elements (caps, rim, seam rays). The
// seam ray mask also no longer lights the whole wedge (its far-seam term was
// inverted, so every onset flashed the full disc white).
//
// param0  Segments   mirror-fold count (2..16)
// param1  Spin       base rotation speed, surged on each beat
// param2  Vortex     radial swirl / depth of the inward tunnel

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);

    // ---- parameters ----
    float nSegs   = max(floor(mix(2.0, 16.0, u.param0) + 0.5), 2.0);
    float spinSpd = mix(0.02, 0.22, u.param1);
    float vortex  = u.param2;

    // ---- polar coords ----
    float r = length(p);
    float a = atan2_(p.y, p.x);   // -pi..pi

    // ---- beat envelope: 0 on the beat, peaks ~30% into it, back to 0 by the next ----
    // continuous across the beatPhase wrap, so no swell starts or ends in one frame
    float swell = smoothstep(0.0, 0.30, u.beatPhase) * (1.0 - smoothstep(0.30, 1.0, u.beatPhase));
    swell *= 0.55 + 0.45 * saturate(u.bass);

    // ---- center event-horizon void breathes on the beat envelope ----
    // only the void and its rim breathe; the teeth and rings stand on the
    // fixed base radius so a beat does not move every edge at once
    float baseR = 0.10;
    float voidR = baseR + 0.02 * swell;

    // ---- param2 vortex: radius-dependent angle swirl ----
    float vortexTwist = vortex * 1.4 * 0.04 / max(r, 0.05);

    // ---- rotation: continuous spin + eased surge after each beat ----
    // beat count that surges after each beat and never jumps back at the wrap
    float beatSurge = floor(u.beatCount) + 1.0 - pow(1.0 - u.beatPhase, 3.0);
    float rotAngle = u.time * spinSpd + beatSurge * 0.35 * spinSpd;
    float aTwisted = a + rotAngle + vortexTwist;

    // ---- kaleidoscope angular fold into one mirrored wedge ----
    float wedge   = 3.14159265 / nSegs;               // half-angle of one segment
    float aWrap   = mod(abs(aTwisted), 2.0 * wedge);  // [0, 2*wedge)
    float aFolded = (aWrap > wedge) ? (2.0 * wedge - aWrap) : aWrap; // mirror
    float ang01   = aFolded / max(wedge, 1e-5);

    // ---- spectrum at this folded angle ----
    float bSmooth = bandAt(u, ang01);             // continuous read for teeth
    float bHi     = bandAt(u, ang01 * 0.5 + 0.5); // upper-half for veins

    // spectralCentroid shifts the palette hue globally
    float hueShift = 0.18 * u.spectralCentroid;

    vec3 col = vec3(0.0);

    // ====================================================================
    // LAYER 1 — Radial teeth (spectrum bars from voidR outward)
    // The spectrum sets each tooth's length; the body keeps a steady radial
    // gradient so a kick moves the tips rather than pumping the whole disc.
    // ====================================================================
    float toothBase  = baseR + 0.02;
    float toothLen   = 0.12 + bSmooth * 0.40;
    float toothOuter = toothBase + toothLen;

    float angEdge = smoothstep(0.0, 0.06, ang01) * smoothstep(1.0, 0.94, ang01);
    float radIn   = smoothstep(toothBase, toothBase + 0.015, r);
    float radOut  = 1.0 - smoothstep(toothOuter - 0.03, toothOuter, r);
    float radMask = radIn * radOut;

    float toothT   = 0.35 * ang01 + hueShift + 0.05 * u.time;
    vec3 toothCol  = palVisual(toothT, u);
    toothCol = accentize(toothCol, u.accent, 0.25);

    float along     = saturate((r - toothBase) / max(toothLen, 1e-3));
    float body      = mix(0.62, 0.30, along) * (0.85 + 0.15 * bSmooth);
    float capProx   = smoothstep(toothOuter - 0.05, toothOuter - 0.015, r);
    float toothBright = body + capProx * (0.55 + 0.20 * swell);
    // seams dim the teeth rather than cut them, so the spin sweeps soft edges
    col += toothCol * radMask * mix(0.6, 1.0, angEdge) * toothBright;

    // ====================================================================
    // LAYER 2 — Nested concentric ring lines
    // ====================================================================
    for (int ri = 1; ri <= 5; ri++) {
        float fRi   = float(ri);
        float ringR = baseR + (1.0 - baseR) * (fRi / 5.5);
        float rBand = bandAt(u, fRi / 6.0);
        float rLine = aaLine(r - ringR, 0.003 + 0.004 * rBand);
        float rT    = ang01 + hueShift + fRi * 0.13 + 0.04 * u.time;
        vec3 rCol   = palVisual(rT, u);
        float hiFreq = fRi / 5.0;
        rCol = mix(rCol, vec3(0.0, 0.78, 1.0), hiFreq * 0.45 * u.treble);
        rCol = accentize(rCol, u.accent, 0.12);
        col += rCol * rLine * (0.80 + rBand * 0.70) * angEdge;
    }

    // ====================================================================
    // LAYER 3 — Center rim glow (inner edge of the event horizon)
    // ====================================================================
    float rimWidth = 0.008 + 0.006 * swell;
    float rimLine  = aaLine(r - voidR, rimWidth);
    vec3 rimCol    = palVisual(hueShift + 0.62, u) * (1.15 + 0.55 * swell);
    col += rimCol * rimLine;

    // ====================================================================
    // LAYER 4 — beat: thin light rays along the fold-mirror seams
    // ====================================================================
    {
        float rayNear0 = 1.0 - smoothstep(0.0,  0.08, ang01);
        float rayNear1 = smoothstep(0.92, 1.0,  ang01);
        float rayMask  = max(rayNear0, rayNear1);
        float rayRadial = smoothstep(baseR, baseR + 0.06, r)
                        * (1.0 - smoothstep(0.5, 1.0, r));
        float rayThin = pow(rayMask, 4.0);
        col += peakWhite(palVisual(0.04 + hueShift, u), 0.15 * swell) * rayThin * rayRadial * swell * 0.60;
    }

    // ====================================================================
    // LAYER 5 — treble fine veins (crisp lines from upper spectrum)
    // ====================================================================
    {
        float veinR    = baseR + 0.04 + bHi * 0.12;
        float veinLine = aaLine(r - veinR, 0.004);
        vec3 veinCol   = palVisual(0.76 + hueShift, u) * (1.2 + u.treble * 0.9);
        col += veinCol * veinLine * u.treble * angEdge;
    }

    // ====================================================================
    // BLACK EVENT HORIZON core — soft mask inside voidR
    // ====================================================================
    col *= smoothstep(0.0, voidR, r);

    // ====================================================================
    // FEEDBACK TRAILS — zoom-in rotation produces collapsing tunnel trails
    // ====================================================================
    float fbZoom = 0.004 + 0.001 * swell;
    float fbRot  = 0.004 * spinSpd;
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.76), fbZoom, fbRot);

    return col; // LINEAR HDR — post chain tonemaps
}
