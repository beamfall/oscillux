// SPDX-License-Identifier: AGPL-3.0-only
// Interference — three band-driven wavefront emitters.
// Bass, mid and treble each own a slowly drifting emitter radiating circular
// wavefronts. The three share one wave clock, so their interference is a
// standing fringe lattice: where crests align the water glows HDR-hot, where
// they cancel it sinks into a cool wash. The travelling wavefronts ride over
// the lattice as a colour shimmer and soft ripples that surge outward on each
// beat; emitters wander slowly with the phrase and their coals breathe with the kick.
// Brightness over large areas moves only as fast as the emitters drift, so the
// visual keeps within the source flash budget (Makefile visual-flash-check).
// param0 = Ring Density ; param1 = Drift ; param2 = Heat

// Emitter position: a slow phrase wander (continuous beat clock, one lap of
// incommensurate sines every few bars) + slow time drift. Fringes slide
// k * |v| cycles a second, so the emitters move slowly: a beat re-anchor slid
// the whole lattice at once.
vec2 emitterPos(float fi, float driftAmt, VisualUniforms u) {
    float phrase = (u.beatCount + u.beatPhase) / 8.0;
    vec2 anchor = vec2(sin(phrase * 1.70 + fi * 2.39) + 0.5 * sin(phrase * 2.93 + fi * 4.11),
                       cos(phrase * 1.31 + fi * 1.73) + 0.5 * cos(phrase * 2.47 + fi * 3.07))
                * (vec2(1.30, 0.95) / 3.0);
    vec2 drift = vec2(sin(u.time * 0.11 + fi * 2.09), cos(u.time * 0.085 + fi * 1.37));
    // fixed triangulated homes keep the three sources spread apart
    vec2 home = vec2(cos(fi * 2.0944 + 0.65), sin(fi * 2.0944 + 0.65)) * 0.48;
    return home + anchor * 0.10 * driftAmt + drift * 0.08 * driftAmt;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);

    float freq = mix(2.6, 7.5, u.param0);
    float k = 6.2831853 * freq;
    float driftAmt = mix(0.35, 1.0, u.param1);
    float heat = mix(1.2, 2.6, u.param2);

    // Shared wave clock: steady travel plus an eased surge on every beat. Both
    // rates are constant so the phase stays continuous for hours; loudness
    // drives brightness below, never the phase (a level-scaled elapsed time
    // jumps further the longer the track plays).
    float surge = u.beatCount + smoothstep(0.0, 0.45, u.beatPhase);
    float clock = u.time * 0.25 + surge * 0.36;
    float wt = clock * 6.2831853;

    vec2 S = vec2(0.0);   // complex wave sum
    float sumA = 0.0;     // sum of amplitudes (full constructive)
    float sumA2 = 0.0;    // incoherent energy
    vec3 col = vec3(0.0);

    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        vec2 pos = emitterPos(fi, driftAmt, u);
        float r = length(p - pos) + 1e-4;
        float att = 1.0 / (1.0 + r * r * 2.2);
        // band colour of the source: mid and treble steady the lattice;
        // the bass source's swing is in its coal, not its whole field
        float band = (i == 0) ? 0.75 : ((i == 1) ? u.mid : u.treble);
        float a = att * (0.65 + 0.45 * band);
        float ph = k * r - wt - fi * 0.7;
        S += a * vec2(cos(ph), sin(ph));
        sumA += a;
        sumA2 += a * a;

        vec3 tint = (i == 0) ? palRoleBass(0.10, u)
                  : ((i == 1) ? palRoleTrace(0.45 + 0.08 * u.spectralCentroid, u)
                              : palRoleTreble(0.75, u));

        // Emitter core: a small coal that swells with its band (small area).
        float swell = (i == 0) ? u.bassImpact : ((i == 1) ? u.mid : u.treble);
        float core = exp(-r * r * (110.0 - 35.0 * swell));
        col += tint * core * (1.1 + 0.6 * swell);

        // Travelling wavefront of this source: a dim tinted ripple, bright
        // only in absolute terms near the coal.
        float front = 0.5 + 0.5 * cos(ph);
        col += tint * front * front * att * att * 0.10;
    }

    // ---- standing interference: |S|^2 against full constructive ----
    float I = dot(S, S);
    float v = I / max(sumA * sumA, 1e-4);             // 0 cancel .. 1 all crests aligned
    float env = sumA * sumA / max(3.0 * sumA2, 1e-4); // how evenly the sources overlap
    // the lattice burns near the sources and fades into the wash, rather than
    // raying out to the frame edges
    float near = smoothstep(0.35, 1.6, sumA);
    float hot = pow(v, heat) * sumA * sumA * near;

    // travelling phase of the sum: the wavefronts as they cross the lattice
    float wave = S.x / max(length(S), 1e-4);

    float hue = 0.06 + v * 0.30 + 0.10 * u.spectralCentroid;
    vec3 zoneCol = palVisual(hue, u);
    zoneCol = accentize(zoneCol, u.accent, 0.08);
    // colour shimmer at constant luma: the ripple moves the hue, not the light
    vec3 shimCol = palVisual(hue + 0.22, u);
    vec3 chroma = shimCol * (luma(zoneCol) / max(luma(shimCol), 1e-3)) - zoneCol;
    zoneCol = max(zoneCol + chroma * (0.45 * wave), vec3(0.0));
    col += zoneCol * hot * (0.55 + 0.25 * u.level) * (1.0 + 0.06 * wave) * (0.7 + 0.3 * env);
    // white-hot cores where three crests align
    col += peakWhite(zoneCol, 0.5) * smoothstep(0.80, 0.98, v) * env * sumA * near * 0.35;

    // destructive zones sink into a deep cool wash, not flat black
    float destructive = 1.0 - v;
    // and the wavefronts cross it as a shift between two fogs of equal luma
    vec3 fogA = palRoleFog(0.62 + 0.08 * u.spectralCentroid, u);
    vec3 fogB = palVisual(0.30 + 0.08 * u.spectralCentroid, u);
    fogB *= luma(fogA) / max(luma(fogB), 1e-3);
    vec3 fog = max(mix(fogA, fogB, 0.5 + 0.5 * wave), vec3(0.0));
    col += fog * (0.35 + 0.65 * destructive) * sumA * 0.07;

    vec3 outc = feedbackTrail(col, uv,
                              min(u.trailDecay, 0.55),
                              0.0018,
                              0.0);
    return outc; // LINEAR HDR
}
