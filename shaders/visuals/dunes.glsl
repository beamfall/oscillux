// SPDX-License-Identifier: AGPL-3.0-only
// Dunes — topographic neon wire landscape.
// Perspective screen-space contours, not a raymarched terrain.
// param0 = Speed ; param1 = Height ; param2 = Grid Density
//
// Flash budget (Makefile visual-flash-check): the beat answers as motion (a gentle surge in the
// grid's glide), a hue drift and a swell over ~1/3 beat, never as a brightness step. The wires are
// steadily bright, thick and haloed through the far and middle field and ease off toward the
// viewer, where rows sweep the screen fastest. The only instant response is the horizon haze,
// whose per-pixel change stays far below WCAG's 0.1 relative-luminance step. Warm wires and the
// gold crests keep a green floor, so no large saturated-red area changes.

vec3 visual(vec2 uv, VisualUniforms u) {
    float horizon = 0.42;
    vec3 glow = vec3(0.0);

    float p = saturate(u.beatPhase);
    // swell: rises over the first ~third of the beat (>= 150 ms at 120 BPM), eases off by the next
    float swell = smoothstep(0.0, 0.35, p) * (1.0 - smoothstep(0.35, 1.0, p));
    // continuous beat clock: a soft quadratic surge per beat, never the raw beatPhase saw
    float beatT = u.beatCount + 1.0 - (1.0 - p) * (1.0 - p);

    float fromHorizon = uv.y - horizon;
    if (fromHorizon > 0.0) {
        float ft = fromHorizon / max(1.0 - horizon, 0.001);
        float depth = 1.0 / max(ft * 2.2 + 0.035, 0.035);
        float speed = mix(0.08, 0.30, u.param0);
        float height = mix(0.10, 0.42, u.param1);
        float density = mix(0.50, 1.45, u.param2);
        float phase = beatRadians(u, ft * 0.22);
        // the dunes' own drift runs on the continuous beat clock: phase is a saw that resets on
        // every beat, and phase * k inside a sine snapped the whole terrain at each reset
        float drift = (beatT + ft * 0.22) * 0.35;
        float phaseLift = beatWave(u, ft * 0.18);

        float wx = (uv.x - 0.5) * depth * 1.55;
        float wz = depth + u.time * speed + beatT * 0.035;
        float surface = sin(wx * 1.7 + wz * 0.45 + drift) * 0.18;
        surface += sin(wx * 3.3 - wz * 0.32 + u.mid * 0.5 - drift * 1.2) * 0.08;
        surface += (fbm(vec2(wx * 0.22 + cos(phase) * 0.04, wz * 0.18 + sin(phase) * 0.03)) - 0.5) * 0.22;
        surface *= height * (0.92 + 0.08 * swell);

        float rows = (wz + surface * 3.0) * density;
        float cols = (wx + surface + sin(phase) * 0.02) * density * 0.72;
        // thick wires with a soft halo: the width is steady, so it costs no flash budget. Each
        // width is capped in screen units (per unit of uv) so the near rows, where one phase unit
        // spans much of the frame, stay wires rather than wide bands sweeping past the viewer.
        float uvStep = max(fwidth(uv.y) + fwidth(uv.x), 1e-6);
        float rowsPerUv = fwidth(rows) / uvStep, colsPerUv = fwidth(cols) / uvStep;
        float widthScale = 1.0 / max(depth * 0.25, 0.7);
        float rowCore = aaLineCyclic(rows, min(0.016 * widthScale, 0.0045 * rowsPerUv));
        float rowHalo = aaLineCyclic(rows, min(0.050 * widthScale, 0.0120 * rowsPerUv));
        float colCore = aaLineCyclic(cols, min(0.010 * widthScale, 0.0035 * colsPerUv));
        float colHalo = aaLineCyclic(cols, min(0.032 * widthScale, 0.0090 * colsPerUv));
        float rowLine = rowCore + 0.28 * rowHalo;
        float colLine = (colCore + 0.28 * colHalo) * 0.55;
        // bright through the far and middle field, easing off toward the viewer
        float fade = exp(-ft * 2.0) * smoothstep(0.02, 0.18, ft) * (1.0 - 0.92 * smoothstep(0.28, 0.95, ft));
        // the spectrum steers hue along the grid; brightness stays in one band
        float band = bandAt(u, fract(uv.x + beatT * 0.05));
        float hue = uv.x + 0.16 * u.spectralCentroid + surface + beatT * 0.05 + 0.12 * band;
        vec3 neon = palNeon(hue);
        // richer neon: push the palette's pale stretches away from grey (steady, not on the beat)
        neon = max(mix(vec3(dot(neon, vec3(0.2126, 0.7152, 0.0722))), neon, 1.35), 0.0);
        // keep a green floor under the warm wires so they read gold/orange, never pure red
        // (only where red leads blue, so magenta and violet keep their hue)
        float warm = saturate((neon.r - neon.b) * 3.0);
        neon.g = max(neon.g, 0.45 * neon.r * warm);
        neon.b = max(neon.b, 0.08 * neon.r * warm);
        glow += neon * max(rowLine, colLine) * fade * 1.55;

        // warm gold crest highlights that swell after the beat (G floor keeps them off red)
        float crest = smoothstep(0.20, 0.36, surface + phaseLift * 0.05) * rowLine;
        vec3 gold = mix(vec3(1.00, 0.50, 0.10), vec3(1.00, 0.70, 0.18), saturate(uv.x * 1.2 - 0.1));
        glow += gold * crest * fade * (0.95 + 0.20 * swell);
        glow += palVisual(0.15 + uv.x * 0.25 + beatT * 0.08, u) * rowLine * fade
              * phasePulse(u, ft * 0.35, 0.22) * 0.12;
    }

    // horizon haze: a narrow glow on the horizon that breathes with the kick (dim by design)
    float haze = exp(-abs(fromHorizon) * (fromHorizon > 0.0 ? 22.0 : 34.0));
    glow += palNight(0.58 + 0.1 * u.spectralCentroid) * haze * (0.020 + 0.02 * u.bassImpact + 0.015 * swell);

    float horizonLine = aaLine(fromHorizon, 0.0016);
    glow += palNight(0.58 + 0.1 * u.spectralCentroid) * horizonLine * 0.30;

    vec3 col = feedbackTrail(glow, uv, min(u.trailDecay, 0.82), 0.002, 0.0);
    // the faintest warm trail tails keep green up with red, so 8-bit rounding never leaves a
    // pure-red pixel for the next bright wire to flash red against
    col.g = max(col.g, min(col.r, 0.0012));
    return col; // LINEAR HDR — post chain tonemaps
}
