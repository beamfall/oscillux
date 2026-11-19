// SPDX-License-Identifier: AGPL-3.0-only
// Filament — a single elastic string spanning the screen, plucked
// by the music. Displacement is a sum of standing-wave harmonics whose weights
// come from band energies (fundamental=bass, so bass bows the whole span … high
// harmonics=treble), swelled by a per-beat pluck envelope; glowing harmonic-node
// beads ride the string and a glint runs along it over each beat. Calm-capable:
// quiet audio leaves a near-still glowing thread.
// param0 Tension ; param1 Glow ; param2 Bead Shine
//
// Flash budget (visual-flash-check, --audio loud): the string is the only bright
// thing on screen, so every pixel its glow crosses makes a luma transition, and
// motion that moves the whole span at once covers a large area. So the span moves
// at a bounded speed: slow harmonic rates, saturating band weights (a kick on a
// loud band cannot snap the shape), a small eased pluck swell, and no
// instantaneous bassImpact/amplitude/onset jumps in position, width or glow. The
// beat shows as the glint, bead and core swell instead of a whole-span lurch.

// Pluck envelope over one beat: an eased swell that peaks 0.45 beat after the
// kick (225 ms at 120 BPM) and eases back to zero by the next beat, so the
// string never snaps on the beat or its wrap. (A step from 0.09 to 1 in one
// frame swept the whole bright string and its halo across the frame at once,
// and a fast exponential release after the peak still moved the span faster
// than the flash budget allows.)
float pluckEnv(float bp) {
    return smoothstep(0.0, 0.45, bp) * (1.0 - smoothstep(0.45, 1.0, bp));
}

float filamentY(float x01, VisualUniforms u, float tension, float pluck, float t) {
    // a tighter string answers faster with less travel, so the span's speed
    // (and its flash budget) hardly depends on the Tension setting
    float give = clamp(1.35 / tension, 0.75, 1.3);
    float y = 0.0;
    for (int n = 1; n <= 8; ++n) {
        float fn = float(n);
        // saturating band weight: quiet bands leave their harmonic still, loud ones
        // drive it fully, and a kick on an already loud band cannot snap the shape
        float b = bandAt(u, (fn - 1.0) / 7.0);
        float w = b * (2.0 - b) * (1.25 - 0.09 * fn);
        float om = tension * (0.48 + 0.30 * fn);
        float shape = sin(fn * 3.14159265 * x01);
        float osc = cos(om * t + fn * 1.7);
        y += shape * osc * w * (0.38 / fn) * pluck * give;
    }
    return y;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    // motionCentered scales p by the short-side fit, so the screen's edges sit at
    // x = +-aspect * fit: beads and anchors measure x in that same space.
    float fit = shortSideFit(aspect);
    float x01 = saturate(uv.x);

    float tension = mix(0.7, 2.0, u.param0);
    float glowAmt = mix(0.6, 1.9, u.param1);
    float beadAmt = mix(0.3, 1.7, u.param2);

    // pluck envelope: excitation swells after each beat and settles before the next
    float env = pluckEnv(u.beatPhase);
    float pluck = 0.43 + 0.04 * env;

    float y = filamentY(x01, u, tension, pluck, u.time);
    float d = p.y - y;

    // temporal echo: the string a moment ago, as a dim ghost (depth cue)
    float yGhost = filamentY(x01, u, tension, pluck, u.time - 0.18);
    float dGhost = p.y - yGhost;

    // string velocity proxy (finite difference in x -> local slope energy)
    float y2 = filamentY(x01 + 0.004, u, tension, pluck, u.time);
    float slope = abs(y2 - y) * 250.0;
    float energy = saturate(slope * 0.35 + 0.35 * u.level + 0.25 * env);

    // ---- the string: hot core + inner halo + wide bloom ----
    float th = 0.0035 * (1.15 + 0.35 * env);
    float core = aaLine(d, th);
    float halo = aaLine(d, th * 5.0) * 0.22;
    float bloom = exp(-d * d / 0.008) * 0.08;

    vec3 cTrace = palRoleTrace(x01 * 0.55 + 0.10 * u.spectralCentroid, u);
    cTrace = accentize(cTrace, u.accent, 0.08);
    vec3 col = cTrace * (core * (2.2 + 2.4 * energy) * glowAmt
                       + halo * (0.7 + 1.2 * energy)
                       + bloom * glowAmt);

    // ghost pass: dim, cooler — reads as motion history
    vec3 cGhost = palRoleFog(x01 * 0.55 + 0.35, u);
    col += cGhost * aaLine(dGhost, th * 2.0) * 0.12;

    // pluck glint races along the string over the beat: a short stretch of the
    // core and its inner halo shifts to the peak colour (a small area, eased in)
    float flashX = u.beatPhase;
    float flash = exp(-(x01 - flashX)*(x01 - flashX) * 90.0) * env;
    col += palRolePeak(0.5, u) * flash * (core * 2.5 + halo * 2.5);

    // ---- harmonic-node beads at k/8 span positions ----
    for (int k = 1; k <= 7; ++k) {
        float fk = float(k);
        float xk = fk / 8.0;
        float yk = filamentY(xk, u, tension, pluck, u.time);
        vec2 db = vec2((uv.x - xk) * aspect * fit * 2.0, p.y - yk);
        float r2 = dot(db, db);
        float wk = 0.5 + 0.5 * bandAt(u, (fk - 1.0) / 7.0);
        float bead = exp(-r2 / (0.00012 + 0.00010 * wk));
        float beadHalo = exp(-r2 / 0.0025) * 0.10;
        vec3 cb = palRoleTreble(fk / 7.0, u);
        col += cb * (bead * (1.2 + 2.4 * wk) * (0.8 + 0.4 * env) + beadHalo * wk) * beadAmt;
    }

    // anchors: dim endpoints ground the string physically
    float edge = aspect * fit;
    float endL = exp(-dot(vec2(p.x + edge, p.y), vec2(p.x + edge, p.y)) / 0.004);
    float endR = exp(-dot(vec2(p.x - edge, p.y), vec2(p.x - edge, p.y)) / 0.004);
    col += palRoleFog(0.3, u) * (endL + endR) * 0.5;

    // faint ambient fog so calm mode isn't a void
    col += palRoleFog(0.62, u) * exp(-p.y * p.y * 3.0) * 0.015 * (0.4 + 0.6 * u.level);

    return feedbackTrail(col, uv, min(u.trailDecay, 0.62), 0.0012 + 0.0010 * env, 0.0);
}
