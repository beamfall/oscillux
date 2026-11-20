// SPDX-License-Identifier: AGPL-3.0-only
// Lumen Field — a field of spectral light pillars on a mirror floor.
// bottom-anchored light stalks, one per
// spectrum slice, HDR tip orbs, rising energy pulses, rippled floor reflection.
// param0 = Pillars ; param1 = Bloom ; param2 = Sway
//
// Flash budget (CORE-2659): the columns stand tall and glow steadily; a band adds only the last
// stretch of height, and the halo's long soft top slides with it, so a jump moves the tip and the
// compact orb rather than lighting a wide area. The rising pulses keep a moderate depth so the
// whole field never throbs in step. Beat response is a swell with a ~150 ms attack (from
// beatPhase, continuous across the wrap) scaled by level, never an instant kick, onset or
// bassImpact over a large area.

// 0 at the beat, up over ~0.3 beat, back down by the next beat: continuous at the wrap.
float lumenSwell(VisualUniforms u) {
    float bp = u.beatPhase;
    return smoothstep(0.0, 0.3, bp) * (1.0 - smoothstep(0.3, 1.0, bp)) * saturate(u.level * 1.15);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    int nP = int(mix(7.0, 13.0, u.param0) + 0.5);
    float bloom = mix(0.6, 2.2, u.param1);
    float sway = mix(0.012, 0.10, u.param2);
    float sw = lumenSwell(u);
    // how much of each band's own value the pillars show: none at the beat, where the kick lands
    // on the low bins in a single frame, rising over ~150 ms and handing back to the level before
    // the next beat, so a kick lifts the bass pillars, their orbs and spines gradually instead of
    // in one frame (an instant jump of the bright orbs left grey caps in the limiter)
    float bandMix = smoothstep(0.0, 0.3, u.beatPhase) * (1.0 - smoothstep(0.6, 1.0, u.beatPhase));
    float steadyE = saturate(u.level);
    // monotonic beat surge for the rising pulses: whole beats plus an eased glide over each beat,
    // continuous at the wrap and a fixed 0.4 rad a beat however long the track has played (a
    // level factor here would scale the whole elapsed count, so each change of level jumped it)
    float surge = (u.beatCount + smoothstep(0.0, 0.6, u.beatPhase)) * 0.4;

    float floorY = 0.42; // +y is down (origin top-left)
    float below = p.y - floorY;
    float isRefl = step(0.0, below);
    // mirror coordinate + water ripple in the reflection
    float yA = mix(p.y, floorY - below, isRefl);
    float rippleX = isRefl * sin(p.y * 34.0 + u.time * 1.7) * 0.010 * (1.0 + 0.8 * sw);

    vec3 col = vec3(0.0);

    for (int i = 0; i < 13; ++i) {
        if (i >= nP) break;
        float fi = float(i);
        float fr = (fi + 0.5) / float(nP);
        float bandE = mix(steadyE, bandAt(u, fr * 0.85), bandMix);

        // a slow sway: each HDR spine crossing a pixel is a bright transition, so a fast sway
        // swept a dozen spines over many pixels a second and held them in the limiter
        float x0 = mix(-1.45, 1.45, fr)
                 + sin(u.time * (0.10 + 0.035 * fi) + fi * 1.9) * sway;
        float dx = p.x + rippleX - x0;

        float wCore = 0.017 + 0.005 * bandE;
        float wHalo = 0.024 * (3.2 + 1.5 * bloom);
        float core = exp(-dx * dx / max(wCore * wCore, 1e-6));
        float halo = exp(-dx * dx / max(wHalo * wHalo, 1e-6));

        // tall by default: the band only adds the last stretch, so the columns stay near the
        // ceiling under music and a jump moves the tip a little
        float hgt = 0.72 + 0.26 * bandE + 0.04 * sw;
        float tipY = floorY - hgt;
        float up = floorY - yA; // height above the floor
        float floorCut = 1.0 - smoothstep(floorY - 0.005, floorY + 0.03, yA);
        // spine: sharp top that follows the band
        float ywin = smoothstep(tipY - 0.03, tipY + 0.06, yA) * floorCut;
        // halo: glows up the whole column with a long soft top, so a jump in height only
        // slides a gentle gradient instead of lighting or darkening a wide area
        float hwin = smoothstep(tipY - 0.15, tipY + 0.35, yA) * floorCut;
        // spine brighter higher up (absolute, so it does not rescale when the band jumps)
        float vshade = mix(0.55, 1.15, saturate(up / 0.9));

        // rising energy pulses inside the stalk; the beat pushes them up a step
        float pulse = 0.74 + 0.26 * sin(up * 16.0 - u.time * 2.4 - surge + fi * 1.3);

        float hue = fr * 0.7 + 0.08 * u.spectralCentroid + 0.02 * u.time + 0.015 * sw;
        vec3 c = palVisual(hue, u);
        c = accentize(c, u.accent, 0.10);

        float refDim = mix(1.0, 0.34 * saturate(1.0 - below * 1.8), isRefl);
        float eHalo = (1.45 + 0.25 * bandE) * refDim;
        float eCore = (1.30 + 0.70 * bandE) * refDim;

        // pale hues glow no brighter than saturated ones, so the bright halos keep one band
        vec3 ch = c / (1.0 + 1.2 * max(luma(c) - 0.30, 0.0));
        col += ch * halo * hwin * pulse * eHalo * 0.55 * bloom;
        col += mix(c, vec3(2.2, 2.0, 1.85), 0.25) * core * ywin * vshade * eCore * 1.4; // HDR spine

        // HDR tip orb: a bright core and a small halo; it rides the tip, so it stays compact
        float tdy = yA - tipY;
        float td2 = dx * dx + tdy * tdy;
        float orb = 1.9 * exp(-td2 / 2.6e-4) + 0.16 * exp(-td2 / 2.0e-3);
        vec3 oc = palVisual(0.62 + (hue + 0.2) * 0.28 + 0.10 * u.spectralCentroid, u);
        oc = mix(oc, vec3(2.2, 2.0, 1.85), 0.15);
        col += oc * orb * (1.3 + 0.5 * bandE) * refDim * bloom;
    }

    // floor line + soft haze hugging it
    float rimT = 0.5 + 0.1 * u.spectralCentroid;
    vec3 rim = mix(palVisual(rimT, u), palVisual(rimT + 0.18, u), 0.4);
    col += rim * aaLine(p.y - floorY, 0.0028) * (1.6 + 0.5 * sw);
    col += palRoleFog(0.55, u) * exp(-abs(p.y - floorY) * 5.5) * (0.10 + 0.05 * sw) * saturate(u.level * 1.15 + 0.2);

    // dark ceiling / edge falloff keeps the room black
    col *= 1.0 - smoothstep(0.75, 1.45, length(p * vec2(0.75, 1.15))) * 0.85;

    col = feedbackTrail(col, uv, min(u.trailDecay, 0.70), 0.0018, 0.0004);
    return col; // LINEAR HDR
}
