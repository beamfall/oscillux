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

// Hue wheel over palHeatIce that skips its two bad spans: the red end (0..0.14),
// which must not fill large changing areas, and the green middle (0.55..0.78),
// which the wrapper's green-cast suppression greys out. The wheel runs
// magenta, blue, cyan, (short bridge) yellow, orange, salmon, then a pink
// bridge back to magenta, so a hue drifting through fract() never jumps.
vec3 wheel(float h, VisualUniforms u) {
    float x = fract(h) * 0.76;
    if (x < 0.40) return palVisual(0.14 + x, u);
    if (x < 0.43) return mix(palVisual(0.54, u), palVisual(0.79, u), smoothstep(0.40, 0.43, x));
    if (x < 0.64) return palVisual(0.79 + (x - 0.43), u);
    return mix(palVisual(1.0, u), palVisual(0.14, u), smoothstep(0.64, 0.76, x));
}

vec3 spectral(float h, VisualUniforms u) {
    vec3 c = wheel(h, u);
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
    float hue = cid * 0.90 + row * 0.055 + u.time * 0.012;
    vec3 pane = accentize(spectral(hue, u) * 1.6, u.accent, 0.15);

    // internal gradient: light pools toward the pane's outer edge
    float grad = mix(0.45, 1.0, rl * rl);
    float roomWin = smoothstep(0.10, 0.30, r) * (1.0 - smoothstep(0.85, 1.35, r));
    float heart = mix(1.0, 0.70, smoothstep(0.40, 1.10, r));
    // every pane is clear spectral glass at a steady brightness; a hot band
    // only lifts its glow a little, so the room stays in one brightness band
    float lit = smoothstep(0.20, 0.90, bandE);
    vec3 glass = pane * (1.0 + 0.18 * lit + 0.08 * u.level);
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
    vec3 rim = wheel(hue + 0.12, u);
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
