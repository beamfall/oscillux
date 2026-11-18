// SPDX-License-Identifier: AGPL-3.0-only
// Spectral City / frequency + beat.
// A pulse-array skyline over a glossy black floor.
// param0 = Density ; param1 = Speed ; param2 = Reflection

// AA helpers with the derivative width passed in. The tower loop below visits
// only the cells nearest each pixel, so neighbouring pixels evaluate different
// towers in the same iteration and fwidth() of the per-tower SDF is garbage at
// cell boundaries; the widths are derived from fwidth(uv) once, outside.
float boxFillW(vec2 p, vec2 b, vec2 px) {
    vec2 q = abs(p) - b;
    vec2 qo = max(q, vec2(0.0));
    float lo = length(qo);
    float d = lo + min(max(q.x, q.y), 0.0);
    vec2 g = lo > 0.0 ? qo / lo : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
    float w = max(dot(g, px), 1e-5);
    return clamp(0.5 - d / w, 0.0, 1.0);
}
float aaLineW(float d, float halfWidth, float w) {
    return 1.0 - smoothstep(halfWidth, halfWidth + max(w, 1e-5), abs(d));
}
float aaLineCyclicW(float phase, float halfWidth, float w) {
    return 1.0 - smoothstep(halfWidth, halfWidth + max(w, 1e-5), abs(fract(phase) - 0.5));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    float floorY = 0.64;
    vec3 col = vec3(0.002, 0.004, 0.008);

    float road = smoothstep(floorY, 1.0, uv.y);
    if (road > 0.0) {
        float z = 1.0 / max(0.045, uv.y - floorY + 0.05);
        float lane = (uv.x - 0.5) * z;
        float grid = aaLineCyclic(lane * 0.34, 0.018) + aaLineCyclic(z * 0.10 - u.time * 0.22, 0.018);
        col += palVisual(fract(lane * 0.04 + z * 0.02), u) * grid * road * 0.26 * smoothstep(13.0, 1.2, z);
    }

    // Towers sit on a 72-cell grid with half-width <= 0.014 (~1 cell),
    // so only the cells within +-2 of this pixel can touch it: visit those 5
    // instead of all 72 (identical output, 14x fewer iterations).
    // On a narrow frame the grid has fewer, wider cells (frame fit): x distances
    // and widths are measured in authored-grid units, scaled by sx.
    int ncells = fitColumns(u, 72, 16);
    float sx = float(ncells) / 72.0;
    vec2 px = fwidth(uv) * vec2(sx, 1.0);
    int i0 = int(floor(uv.x * float(ncells)));
    for (int j = 0; j < 5; j++) {
        int i = i0 - 2 + j;
        if (i < 0 || i >= ncells) continue;
        float fi = float(i);
        float x = (fi + 0.5) / float(ncells);
        float perspective = mix(0.50, 1.0, hash11(fi * 2.3));
        float bandv = bandAt(u, x);
        float w = mix(0.004, 0.014, perspective);
        // most of the skyline stands on its own; the band only lifts the
        // roofline, since the kick jumps every low band at once and a full
        // band-driven height relit half the sky each beat
        float h = 0.07 + 0.17 * perspective + bandv * mix(0.07, 0.16, perspective) + hash11(fi * 5.1) * 0.12;
        float base = floorY - 0.01 * perspective;
        vec2 bp = vec2((uv.x - x) * sx, uv.y - (base - h * 0.5));
        float tower = boxFillW(bp, vec2(w, h * 0.5), px);
        float edge = aaLineW(abs(bp.x) - w, 0.0014, px.x) * step(abs(bp.y), h * 0.52);
        float rows = aaLineCyclicW((uv.y - base + h) * 42.0, 0.03, px.y * 42.0) * tower;
        vec3 c = palVisual(x + u.time * 0.018, u);
        col += c * tower * (0.12 + bandv * 0.65);
        col += peakWhite(c, rows * u.treble * 0.08) * rows * (0.7 + bandv * 3.0);
        // edges glint with the kick rather than flare: 72 lit outlines at once
        // add up to a large area
        col += c * edge * (0.9 + u.bassImpact * 0.5);

        float reflY = floorY + (base - h * 0.5 - uv.y) * 0.34;
        float refl = boxFillW(vec2((uv.x - x) * sx, uv.y - reflY), vec2(w, h * 0.18), px * vec2(1.0, 1.34))
                   * smoothstep(floorY, 1.0, uv.y) * (1.0 - smoothstep(floorY, 1.0, uv.y));
        col += c * refl * bandv * 0.45;
    }

    col += palVisual(0.55, u) * aaLine(uv.y - floorY, 0.0015) * 0.65;
    // steady zoom: a kick-pumped zoom smeared the lit skyline over the sky
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.82), 0.002 + 0.001 * u.bassImpact, 0.0);
    return col; // LINEAR HDR — post chain tonemaps
}
