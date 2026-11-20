// SPDX-License-Identifier: AGPL-3.0-only
// Filament — a single elastic string spanning the screen, plucked
// by the music. Displacement is a sum of standing-wave harmonics whose weights
// come from band energies (fundamental=bass, so bass bows the whole span … high
// harmonics=treble), swelled by a per-beat pluck envelope. The string is three
// thick glowing strands braided around that shape; glowing harmonic-node beads
// ride every strand and a glint runs along them over each beat. Calm-capable:
// quiet audio leaves a near-still glowing braid.
// param0 Tension ; param1 Glow ; param2 Bead Shine
//
// Flash budget (visual-flash-check, --audio loud): the string is the only bright
// thing on screen, so every pixel its glow crosses makes a luma transition, and
// motion that moves the whole span at once covers a large area. So the span moves
// at a bounded speed: slow harmonic rates, saturating band weights (a kick on a
// loud band cannot snap the shape), a small eased pluck swell, and no
// instantaneous bassImpact/amplitude/onset jumps in position, width or glow. The
// beat shows as the glint instead of a whole-span lurch. Brightness, width and
// glow are steady (a constant level makes no transitions), so the strands stay
// thick and bright; what the budget limits is how much bright edge sweeps past
// per moment, which grows with the strands' spread and the span's speed. Hence
// the slow harmonic rates, the strands' moderate spread, and one shared halo
// and bloom (low enough to stay under the luma step) rather than one per strand.

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
        float om = tension * (0.21 + 0.13 * fn);
        float shape = sin(fn * 3.14159265 * x01);
        float osc = cos(om * t + fn * 1.7);
        y += shape * osc * w * (0.38 / fn) * pluck * give;
    }
    return y;
}

// Three strands share the plucked shape and twist around it: each rides a slow
// travelling wave pinned to zero at both anchors, a third of a turn apart, so the
// strands cross and braid along the span while it moves at a bounded speed.
float strandTwist(float x01, float i, float t) {
    float env = sin(3.14159265 * x01);
    return 0.055 * env * sin(6.2831853 * (1.15 * x01 - 0.07 * t) + i * 2.0943951);
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

    // string velocity proxy (finite difference in x -> local slope energy)
    float y2 = filamentY(x01 + 0.004, u, tension, pluck, u.time);
    float slope = abs(y2 - y) * 250.0;
    float energy = saturate(slope * 0.35 + 0.35 * u.level);

    // the beat's glint runs along every strand over the beat (small area, eased)
    float flashX = u.beatPhase;
    float flash = exp(-(x01 - flashX)*(x01 - flashX) * 90.0) * env;
    vec3 cPeak = palRolePeak(0.5, u);

    // ---- three braided strands: hot cores + a shared halo and wide bloom ----
    float th = 0.0080;
    vec3 col = vec3(0.0);
    float haloMax = 0.0;
    float dMin = 1e3;
    for (int i = 0; i < 3; ++i) {
        float fi = float(i);
        float d = p.y - (y + strandTwist(x01, fi, u.time));
        dMin = min(dMin, abs(d));
        float core = aaLine(d, th);
        float halo = exp(-d * d / (th * th * 9.0));
        haloMax = max(haloMax, halo);
        vec3 cTrace = palRoleTrace(x01 * 0.55 + 0.10 * u.spectralCentroid + 0.12 * fi, u);
        cTrace = accentize(cTrace, u.accent, 0.08);
        col += cTrace * core * (2.6 + 2.0 * energy) * glowAmt;
        col += cPeak * flash * core * 2.0;
    }
    // the glow is shared, not summed: where strands cross or gather at the
    // anchors the bundle keeps one halo and one bloom instead of a white blob
    vec3 cGlow = accentize(palRoleTrace(x01 * 0.55 + 0.10 * u.spectralCentroid + 0.12, u), u.accent, 0.08);
    float bloom = exp(-dMin * dMin / 0.020) * 0.07;
    col += cGlow * (haloMax * 0.35 * (1.0 + 0.5 * energy) + bloom) * glowAmt;
    col += cPeak * flash * haloMax * 0.6;

    // ---- harmonic-node beads at k/8 span positions, on every strand ----
    for (int k = 1; k <= 7; ++k) {
        float fk = float(k);
        float xk = fk / 8.0;
        float yk = filamentY(xk, u, tension, pluck, u.time);
        float wk = 0.5 + 0.5 * bandAt(u, (fk - 1.0) / 7.0);
        vec3 cb = palRoleTreble(fk / 7.0, u);
        float dx = (uv.x - xk) * aspect * fit * 2.0;
        for (int i = 0; i < 3; ++i) {
            vec2 db = vec2(dx, p.y - (yk + strandTwist(xk, float(i), u.time)));
            float r2 = dot(db, db);
            float bead = exp(-r2 / (0.00022 + 0.00012 * wk));
            float beadHalo = exp(-r2 / 0.0030) * 0.22;
            col += cb * (bead * (2.4 + 2.6 * wk) * (0.9 + 0.2 * env) + beadHalo * wk) * beadAmt;
        }
    }

    // anchors: endpoints where the strands gather ground the string physically
    float edge = aspect * fit;
    float endL = exp(-dot(vec2(p.x + edge, p.y), vec2(p.x + edge, p.y)) / 0.004);
    float endR = exp(-dot(vec2(p.x - edge, p.y), vec2(p.x - edge, p.y)) / 0.004);
    col += palRoleFog(0.3, u) * (endL + endR) * 0.8;

    // faint ambient fog so calm mode isn't a void
    col += palRoleFog(0.62, u) * exp(-p.y * p.y * 3.0) * 0.015 * (0.4 + 0.6 * u.level);

    return feedbackTrail(col, uv, min(u.trailDecay, 0.62), 0.0012 + 0.0010 * env, 0.0);
}
