// SPDX-License-Identifier: AGPL-3.0-only
// Wave Cascade — a live master trace at the top; on each beat a
// slice of the trace detaches and falls as a fading sheet (gravity + shear),
// stacking into a luminous waterfall pool; each beat flings spray; trail afterglow.
// param0 Fall Speed ; param1 Sheet Life ; param2 Spray
// Flash budget (Makefile visual-flash-check): every beat response is a swell on
// the beat clock with a ~150 ms attack, never a per-frame kick step, and the
// master trace drifts slowly, so no large area changes brightness fast.

// smooth per-beat swell: 0 on the beat, ~0.32 beat attack, long release
float beatSwell(float p) {
    return smoothstep(0.0, 0.32, p) * (1.0 - smoothstep(0.32, 1.0, p));
}

float cascadeShape(float x, float seed, float live, VisualUniforms u) {
    // frozen sheets read a noise pseudo-spectrum keyed by seed; the live master
    // blends in the real spectrum
    float frozen = vnoise(vec2(x * 6.5, seed * 17.31)) * 1.3;
    float liveB = bandAt(u, fract(x * 0.82 + 0.03 * sin(u.time * 0.31)));
    float b = mix(frozen, liveB * 1.6, live);
    // slow phase drift: the trace glides instead of sweeping the frame
    float w = sin(x * 9.0 + seed * 0.70) * 0.42
            + sin(x * 23.0 - seed * 1.15) * 0.22
            + sin(x * 57.0 + seed * 1.90) * 0.06 * (0.6 + live * u.treble * 0.8);
    // the spectrum shapes the trace, damped so a kick only nudges it
    return w * (0.55 + 0.45 * b);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    float g = mix(0.22, 0.62, u.param0);
    float life = mix(0.55, 0.30, u.param1); // decay rate (lower = longer life)
    float sprayAmt = mix(0.3, 1.4, u.param2);
    // NOTE: uv.y increases DOWN the displayed frame — master lives at small y,
    // sheets fall by increasing y into the pool near y = 0.88.
    float topY = 0.16;
    float floorY = 0.88;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);

    vec3 col = vec3(0.0);
    float swell = beatSwell(u.beatPhase);
    float lvl = clamp(u.level, 0.0, 1.0);

    // ---- background: dim spectral columns hanging below the master trace ----
    float cb = bandAt(u, uv.x);
    float colGlow = cb * cb * smoothstep(floorY, topY, uv.y)
                  * smoothstep(topY - 0.05, topY + 0.06, uv.y) * 0.08;
    col += palRoleFog(0.45 + 0.10 * u.spectralCentroid, u) * (colGlow + 0.010);

    // ---- luminous pool at the bottom of the falls ----
    float poolMist = fbm(vec2(uv.x * 5.0, uv.y * 9.0 - u.time * 0.7));
    float pool = exp(-((uv.y - floorY) * 9.0)*((uv.y - floorY) * 9.0));
    col += palRoleBass(0.12, u) * pool * (0.12 + 0.20 * lvl + 0.10 * swell)
         * (0.55 + 0.6 * poolMist);

    // ---- falling sheets (one detaches per beat) ----
    // each sheet keeps one seed for its whole fall, so nothing reshapes
    // when the beat clock wraps; the master morphs continuously into it
    float seedBase = u.beatCount + u.beatPhase;
    for (int j = 0; j < 7; ++j) {
        float fj = float(j);
        float age = u.beatPhase + fj;
        float seed = u.beatCount - fj;
        // gravity fall, easing into the stack near the pool
        float yFall = topY + 0.5 * g * age * age * 0.30;
        float yStack = floorY - 0.020 - fj * 0.007;
        float yj = min(yFall, yStack);
        float settled = smoothstep(yStack - 0.03, yStack, yFall);
        // slight shear: sheet skews sideways as it falls
        float xq = uv.x + age * 0.030 * (uv.x - 0.5) + age * 0.012;

        float shapeAmp = 0.085 * exp(-age * 0.30) * (0.6 + 0.5 * lvl);
        float ys = yj + cascadeShape(xq, seed, 0.0, u) * shapeAmp;
        float d = uv.y - ys;
        // a new sheet eases in off the master over its first beat and a half,
        // and sheets stay a soft echo of the trace: bright sheets sweeping
        // down the frame were the strobe
        float fade = exp(-age * life) * (1.0 - 0.60 * settled) * smoothstep(0.0, 1.5, age);
        float halfW = 0.0022 + 0.0010 * age;
        // motion blur: a fast-falling sheet spreads its light, so a thin
        // bright line never sweeps the frame as a strobe edge
        float vel = 0.3 * g * age * (1.0 - settled);
        float line = aaLine(d, halfW + 0.010 * vel) / (1.0 + 25.0 * vel);
        // thin translucent skirt trailing back up toward where it came from
        float veil = exp(-abs(d) * 70.0) * 0.09;
        float above = step(d, 0.0);
        vec3 sc = palVisual(fract(0.30 + seed * 0.043), u);
        sc = accentize(sc, u.accent, 0.08);
        col += 0.6 * sc * (line + veil * above) * fade * (0.45 + 0.55 * cb);
    }

    // ---- live master trace on top (drawn last: hottest layer) ----
    float mShape = cascadeShape(uv.x, seedBase, 1.0, u);
    float mAmp = 0.10 * (0.55 + 0.65 * lvl) * (1.0 + 0.12 * swell);
    float yM = topY + mShape * mAmp;
    float dM = uv.y - yM;
    vec3 mc = palRoleTrace(fract(uv.x * 0.7 + 0.10 * u.spectralCentroid), u);
    col += mc * aaLine(dM, 0.0035) * (2.0 + 1.0 * bandAt(u, uv.x) + 0.6 * swell);
    col += mc * exp(-abs(dM) * 45.0) * (0.22 + 0.18 * lvl + 0.06 * swell);
    // white-hot crest pulse sliding along with the beat
    float crest = exp(-(uv.x - u.beatPhase)*(uv.x - u.beatPhase) * 70.0);
    col += palRolePeak(0.10, u) * crest * aaLine(dM, 0.008) * swell * 1.6;

    // ---- beat spray: droplets flung off the newest detachment ----
    for (int i = 0; i < 24; ++i) {
        float fi = float(i);
        vec2 h = hash22(vec2(fi * 1.91, u.beatCount * 3.7));
        float sAge = u.beatPhase;
        float sx = h.x + (h.y - 0.5) * 0.35 * sAge;
        // flung up first (decreasing y), then falling back (increasing y)
        float sy = topY - 0.02 - (0.28 * h.y) * sAge + 0.42 * sAge * sAge;
        vec2 dv = uv - vec2(sx, sy);
        dv.x *= aspect;
        float d2 = dot(dv, dv);
        float spark = 1.6e-5 / (d2 + 2.2e-5);
        col += palRoleTreble(fract(fi * 0.083), u) * spark
             * (0.5 + 0.7 * u.treble) * swell * sprayAmt;
    }

    // frame falloff
    vec2 c = uv - vec2(0.5, 0.48);
    col *= 1.0 - dot(c, c) * 0.6;

    // afterglow: the waterfall's smoke
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.72),
                        0.004 + 0.002 * u.bassImpact, 0.0);
    return col; // LINEAR HDR
}
