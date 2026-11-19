// SPDX-License-Identifier: AGPL-3.0-only
// Ribbons — layered silk-light ribbons with spectral edge highlights.
// param0 Flow ; param1 Width ; param2 Layers
//
// Flash budget (CORE-2659): the edges are bright and cover much of the frame, so they drift
// slowly and keep one brightness band; the spectrum tints the silk and edges within it. The beat
// lights compact glints that run along each ribbon once a bar, so it changes small areas only,
// and its swell rises from zero over the first third of the beat, so a kick never steps it.

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    p = rot2(-0.18) * p;
    float flow = mix(0.04, 0.26, u.param0);
    float width = mix(0.014, 0.050, u.param1);
    int layers = int(mix(5.0, 12.0, u.param2) + 0.5);

    float rise = smoothstep(0.0, 0.32, u.beatPhase);
    float fall = 1.0 - smoothstep(0.32, 1.0, u.beatPhase);
    float swell = rise * fall * saturate(0.25 + 0.85 * u.bass);
    float loud = saturate(u.level);

    vec3 base = vec3(0.0);
    vec3 glow = vec3(0.0);

    for (int i = 0; i < 12; i++) {
        if (i >= layers) break;
        float fi = float(i);
        float y0 = mix(-0.70, 0.70, (fi + 0.5) / float(layers));
        float bandv = saturate(bandAtWrapped(u, fi / float(layers) + p.x * 0.08));
        float curve = y0
                    + sin(p.x * (1.2 + fi * 0.11) + u.time * flow + fi) * (0.11 + 0.05 * loud)
                    + sin(p.x * (2.4 + fi * 0.07) - u.time * flow * 0.7) * 0.045;
        float d = p.y - curve;

        vec3 c = palVisual(fi / 12.0 + 0.12 * u.spectralCentroid + 0.06 * p.x, u);
        c = accentize(c, u.accent, 0.10);
        // The tonemap's toe crushes green and blue first, so a dim salmon halo reads as saturated
        // red (WCAG) and every drift of it as a red change: keep some of both under the red.
        c.gb = max(c.gb, c.r * vec2(0.22));

        // Glints run along each ribbon once a bar; the beat swell lights them and the silk round them.
        float glintPhase = p.x * 0.35 - u.barPhase + fi * 0.07;
        float window = pow(0.5 + 0.5 * cos(6.2831853 * glintPhase), 40.0);

        // Silk body: a dim fill that carries the spectrum.
        float body = exp(-(d * d) / (width * width * 0.55));
        base += c * body * (0.020 + 0.035 * bandv);

        // Edges: soft, unclipped glow lines that only drift.
        float ea = (d - width) / 0.0055, eb = (d + width) / 0.0055;
        float edge = exp(-ea * ea) + exp(-eb * eb);
        float halo = exp(-ea * ea * 0.08) + exp(-eb * eb * 0.08);
        glow += c * (edge * (0.42 + 0.10 * bandv) + halo * 0.04);

        float core = exp(-d * d / (0.0045 * 0.0045));
        glow += peakWhite(c, 0.5) * core * window * (0.12 + 1.6 * swell);
        glow += c * exp(-d * d / (0.028 * 0.028)) * window * swell * 0.10;
    }

    vec3 trailedGlow = feedbackTrail(glow, uv, min(u.trailDecay, 0.82), 0.0006, 0.0003);
    return base + trailedGlow;
}
