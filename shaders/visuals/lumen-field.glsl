// SPDX-License-Identifier: AGPL-3.0-only
// Lumen Field — a field of spectral light pillars on a mirror floor.
// bottom-anchored light stalks, one per
// spectrum slice, HDR tip orbs, rising energy pulses, rippled floor reflection.
// param0 = Pillars ; param1 = Bloom ; param2 = Sway
//
// Flash budget (CORE-2659): the wide halos glow from the floor up on a fixed vertical profile and
// fade out well below each tip, so a band that jumps moves only the thin spine and the small orb.
// Beat response is a swell with a ~150 ms attack (from beatPhase, continuous across the wrap)
// scaled by level, never an instant kick, onset or bassImpact over a large area.

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
    // monotonic beat surge for the rising pulses: beatCount + eased phase is continuous at the wrap
    float surge = (u.beatCount + smoothstep(0.0, 0.6, u.beatPhase)) * 0.4 * saturate(u.level * 1.15);

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
        float bandE = bandAt(u, fr * 0.85);

        float x0 = mix(-1.45, 1.45, fr)
                 + sin(u.time * (0.30 + 0.11 * fi) + fi * 1.9) * sway;
        float dx = p.x + rippleX - x0;

        float wCore = 0.012 + 0.004 * bandE;
        float wHalo = 0.021 * (3.2 + 1.5 * bloom);
        float core = exp(-dx * dx / max(wCore * wCore, 1e-6));
        float halo = exp(-dx * dx / max(wHalo * wHalo, 1e-6));

        float hgt = 0.30 + 0.56 * bandE + 0.04 * sw;
        float tipY = floorY - hgt;
        float up = floorY - yA; // height above the floor
        float floorCut = 1.0 - smoothstep(floorY - 0.005, floorY + 0.03, yA);
        // spine: sharp top that follows the band
        float ywin = smoothstep(tipY - 0.03, tipY + 0.06, yA) * floorCut;
        // halo: fixed glow from the floor that dies out well below the tip, so a jump in
        // height never lights or darkens a wide area
        float hwin = smoothstep(tipY - 0.05, tipY + 0.45, yA) * floorCut * exp(-max(up, 0.0) * 1.3);
        // spine brighter higher up (absolute, so it does not rescale when the band jumps)
        float vshade = mix(0.45, 1.10, saturate(up / 0.9));

        // rising energy pulses inside the stalk; the beat pushes them up a step
        float pulse = 0.80 + 0.20 * sin(up * 16.0 - u.time * 2.4 - surge + fi * 1.3);

        float hue = fr * 0.7 + 0.08 * u.spectralCentroid + 0.02 * u.time + 0.015 * sw;
        vec3 c = palVisual(hue, u);
        c = accentize(c, u.accent, 0.10);

        float refDim = mix(1.0, 0.34 * saturate(1.0 - below * 1.8), isRefl);
        float eHalo = (0.85 + 0.30 * bandE) * refDim;
        float eCore = (0.70 + 0.80 * bandE) * refDim;

        // pale hues glow no brighter than saturated ones, so the bright halos keep one band
        vec3 ch = c / (1.0 + 1.2 * max(luma(c) - 0.30, 0.0));
        col += ch * halo * hwin * pulse * eHalo * 0.55 * bloom;
        col += mix(c, vec3(2.2, 2.0, 1.85), 0.25) * core * ywin * vshade * eCore * 1.3; // HDR spine

        // HDR tip orb: a tight soft core plus a faint tail, so a jumping tip moves little light
        float tdy = yA - tipY;
        float td2 = dx * dx + tdy * tdy;
        float orb = 1.3 * exp(-td2 / 2.2e-4) + 0.08 * exp(-td2 / 4.0e-3);
        vec3 oc = palVisual(0.62 + (hue + 0.2) * 0.28 + 0.10 * u.spectralCentroid, u);
        oc = mix(oc, vec3(2.2, 2.0, 1.85), 0.15);
        col += oc * orb * (1.0 + 0.4 * bandE) * refDim * bloom;
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
