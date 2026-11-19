// SPDX-License-Identifier: AGPL-3.0-only
// Prism Room — faceted caustic chamber.
// kaleidoscopic wedge fold builds a room
// of glass panes; each facet is lit by its own spectrum band, caustic sweeps
// wash across rows, HDR edge filaments carve the geometry and carry the kick.
// param0 = Facets ; param1 = Sweep ; param2 = Edge Glow
//
// Flash budget: the panes are large saturated areas, so nothing moves or
// recolours them on the beat. The room turns and its hues drift on the clock,
// band energy sets each pane's glow within one brightness band, and the kick
// lands on the thin seams and vertex glints. Pane hues stay out of the red end
// of the palette and a red guard keeps any accent or palette off saturated red.

// Fold a hue into the palette's span off the red end (0.14..0.94 of palHeatIce)
// with a triangle wave, so a drifting hue turns back instead of wrapping (no jump).
float safeHue(float h) {
    return 0.14 + 0.80 * abs(fract(h) * 2.0 - 1.0);
}

vec3 spectral(float h, VisualUniforms u) {
    vec3 c = palVisual(safeHue(h), u);
    c = clamp(mix(vec3(luma(c)), c, 1.45), vec3(0.0), vec3(4.0));
    return c * c;
}

// Keep green + blue at least 0.4 of red: R / (R + G + B) stays under ~0.72.
vec3 redGuard(vec3 c) {
    float lack = max(0.4 * c.r - (c.g + c.b), 0.0);
    return c + vec3(0.0, 0.55, 0.45) * lack;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float facetsF = floor(mix(5.0, 10.0, u.param0) + 0.5);
    float sweepSpd = mix(0.06, 0.30, u.param1);
    float edgeGlow = mix(0.9, 3.4, u.param2);

    float r = length(p);
    // steady turn on the clock: a beat-driven turn sweeps every pane seam
    // across the frame at once
    float a = atan2_(p.y, p.x) + u.time * 0.05;

    // ---- kaleidoscopic wedge fold ----
    float sector = 6.2831853 / facetsF;
    float ai = floor((a + 3.14159265) / sector);
    float am = a + 3.14159265 - (ai + 0.5) * sector; // wedge-local angle, centered

    // facet rows marching outward in radius
    float rowW = 0.155;
    float rr = r + 0.04 * sin(am * 3.0 + u.time * 0.2); // subtle pane warp
    float row = floor(rr / rowW);
    float rl = fract(rr / rowW);

    // per-facet identity
    float aid = mod(ai, facetsF);
    float cid = hash21(vec2(row * 7.1, aid * 3.3));
    int bi = int(mod(cid * 63.0 + row * 5.0, 63.0));
    float bandE = band(u, bi);

    vec3 col = vec3(0.0);

    // ---- glass pane fill ----
    // hue drifts slowly on the clock; each pane turns within its own span
    float hue = cid * 0.55 + row * 0.055 + u.time * 0.012;
    vec3 pane = accentize(spectral(hue, u) * 0.85, u.accent, 0.15);

    // internal gradient: light pools toward the pane's outer edge, the rest
    // of the pane stays smoked glass over darkness
    float grad = mix(0.18, 1.0, rl * rl);
    float roomWin = smoothstep(0.10, 0.30, r) * (1.0 - smoothstep(0.85, 1.35, r));
    float heart = mix(1.0, 0.38, smoothstep(0.40, 1.10, r));
    // a hot band turns its pane from smoked to clear spectral glass: the
    // colour deepens while the glow moves within one brightness band
    float lit = smoothstep(0.20, 0.90, bandE);
    vec3 smoke = mix(vec3(luma(pane)), pane, 0.45);
    vec3 glass = mix(smoke, pane, lit) * (0.50 + 0.38 * lit + 0.14 * u.level);
    col += glass * grad * roomWin * heart;

    // ---- caustic sweep washing outward through the rows ----
    // a soft, slow wash on the clock; the mid band sets how much light it carries
    float sweepR = fract(u.time * sweepSpd) * 1.6 - 0.05;
    float sd = (rr - sweepR) * 9.0;
    float sweep = exp(-sd * sd);
    vec3 sweepCol = spectral(hue + 0.25, u);
    col += sweepCol * sweep * roomWin * heart * (0.05 + 0.08 * u.mid);

    // ---- HDR edge filaments ----
    // wedge seams (arc-length distance so lines stay thin)
    float edgeA = aaLine((abs(am) - sector * 0.5) * max(r, 0.05), 0.0032);
    // row seams
    float dRow = min(rl, 1.0 - rl) * rowW;
    float edgeR = aaLine(dRow, 0.0030);
    vec3 rim = palVisual(safeHue(hue + 0.12), u);
    rim = clamp(mix(vec3(luma(rim)), rim, 1.4), vec3(0.0), vec3(4.0));
    // the kick lives here: thin seams can pulse without a large-area flash
    float edgeE = edgeGlow * (0.45 + 0.9 * u.bassImpact + 0.8 * bandE);
    col += rim * (edgeA + edgeR) * roomWin * heart * edgeE * (0.30 + 0.6 * sweep);

    // vertex glints where seams cross — sparks ride the caustic sweep
    float glint = edgeA * edgeR;
    col += peakWhite(rim, 0.4) * glint * roomWin * edgeE
         * (0.25 + 3.0 * sweep + 1.5 * u.onset);

    // ---- dark heart of the room + falloff ----
    col *= smoothstep(0.05, 0.16, r);
    col += spectral(hue, u) * exp(-r * r * 2.6) * smoothstep(0.05, 0.22, r) * (0.04 + 0.03 * u.level);
    // walls beyond the glass fall to black
    col *= 1.0 - smoothstep(1.05, 1.5, r) * 0.95;

    col = redGuard(col);
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.55), 0.002, 0.0006);
    return col; // LINEAR HDR
}
