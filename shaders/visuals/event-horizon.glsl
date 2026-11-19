// SPDX-License-Identifier: AGPL-3.0-only
// Event Horizon — gravitational vortex tunnel.
// Identity: a black hole seen down the
// throat — spiral accretion arms sheared by gravity, doppler-lit disk, HDR
// photon ring, infalling ember streams. Deliberately distinct from Tunnel
// (no concentric ring flythrough, no circular equalizer) and from any lens
// visual: this stays an opaque vortex tunnel.
// param0 = Pull ; param1 = Spin ; param2 = Disk Detail

// Flash budget (limiter-red-audit --audio loud --max-luma 6): no brightness,
// radius or hue here follows an instant kick value (bassImpact, onset, bass,
// the low spectrum bins) or jumps at the beatPhase wrap. The beat reaches the
// picture as ehSwell, a ~180 ms attack and slow release that is continuous
// across the wrap: horizon breathing, photon-ring flare, ember glints and a
// thin ripple, kept small over the disk.

// palVisual without its free-mode beatPhase nudge, which steps at the wrap.
vec3 ehPal(float t, VisualUniforms u) {
    return palVisual(t - (u.palette.x >= 0.0 ? 0.0 : 0.015 * u.beatPhase), u);
}

// 0 on the beat, rising fastest on it and peaking ~180 ms later (at 120 BPM),
// easing back to 0 by the next beat; continuous across the wrap and scaled by
// the smoothed level, never by an instant kick value.
float ehSwell(VisualUniforms u) {
    float bp = fract(u.beatPhase);
    float k = 1.0 - saturate(bp / 0.36);
    return (1.0 - k * k) * (1.0 - smoothstep(0.36, 1.0, bp)) * saturate(u.level * 1.15);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    p = rot2(-0.12) * p;
    p.y /= 0.86; // tilt the disc slightly toward the camera

    float r = length(p);
    float rS = max(r, 1e-3);
    float a = atan2_(p.y, p.x);

    float pull   = mix(0.55, 2.1, u.param0);
    float spin   = mix(0.12, 0.75, u.param1);
    float detail = mix(2.5, 7.0, u.param2);

    float swell = ehSwell(u);
    float coreR = 0.165 + 0.012 * sin(u.time * 0.7) + 0.012 * swell;

    // gravitational shear — inner material orbits faster. The arms turn at
    // half the spin rate: at full rate their bright edges sweep enough of the
    // disk per frame that the flash limiter holds (ghosts) large areas.
    float swirl = a + pull / (rS + 0.11) + u.time * spin * 0.5;

    vec3 col = vec3(0.0);

    // ---- spiral accretion arms ----
    float lr = log(rS + 0.05);
    float arm1 = 0.5 + 0.5 * sin(swirl * 3.0 - lr * detail);
    float arm2 = 0.5 + 0.5 * sin(swirl * 5.0 + lr * detail * 1.7 + 2.1);
    // Angular noise embedded on a circle of radius 0.85: it traverses
    // 2*pi*0.85 ~= 5.34 domain units per revolution, exactly the rate the old
    // fbm(swirl*0.85) ramp had, so the feature scale is preserved but the
    // domain no longer tears where atan2 wraps on the -x axis (rule 13).
    float turb = fbm(vec2(cos(swirl), sin(swirl)) * 0.85
                     + vec2(rS * 3.2 - u.time * 0.35, 0.0));

    float disk = smoothstep(0.28, 0.92, arm1) * (0.45 + 0.85 * turb)
               + 0.55 * smoothstep(0.45, 0.97, arm2) * turb;

    // radial window: hot at the horizon, fading into the void
    float win = smoothstep(coreR * 0.85, coreR * 1.35, r) * (1.0 - smoothstep(0.50, 1.30, r));
    float heat = exp(-(rS - coreR) * 2.4);

    // doppler beaming — the approaching side burns brighter and bluer
    float dopp = 0.5 + 0.5 * sin(a + u.time * spin * 0.6);

    float hue = fract(0.04 + heat * 0.22 + dopp * 0.10 + 0.06 * u.spectralCentroid);
    vec3 hot = mix(ehPal(hue + 0.10, u), ehPal(0.03 + hue * 0.18, u), 0.7);
    vec3 cold = ehPal(hue + 0.34, u);
    vec3 armCol = mix(cold, hot, saturate(heat * 1.2));

    float exposure = 0.65 + 1.3 * u.level + 0.5 * swell * heat;
    col += armCol * disk * win * (0.55 + 2.6 * heat) * (0.5 + 0.9 * dopp) * exposure * 1.2;

    // ---- infalling ember streams ----
    for (int i = 0; i < 36; ++i) {
        float fi = float(i);
        vec2 h = hash22(vec2(fi, 5.7));
        float life = fract(h.y + u.time * (0.10 + 0.22 * h.x));
        float er = mix(1.25, coreR * 1.05, life); // falls inward
        float ea = h.x * 6.2831853 + pull / (er + 0.11) * 0.9 + u.time * spin;
        vec2 ep = vec2(cos(ea), sin(ea)) * er;
        // compact core only: a halo or long tail sums, over 36 embers, into
        // a glow wide enough that the limiter holds the disk around it
        vec2 dv = p - ep;
        float dd2 = dot(dv, dv);
        float ember = exp(-dd2 * 4500.0);
        // fade in at the rim and out before the final whip round the horizon,
        // where an ember's streak would flash a ring of pixels every frame
        float fade = smoothstep(0.0, 0.2, life) * (1.0 - smoothstep(0.55, 0.85, life));
        vec3 ec = mix(ehPal(h.x * 0.3 + 0.10, u), ehPal(0.03 + h.x * 0.054, u), 0.7);
        ec = peakWhite(ec, life * swell * 0.25);
        col += ec * ember * fade * life * (0.25 + 1.1 * u.mid) * smoothstep(coreR, coreR * 1.5, er);
    }

    // ---- HDR photon ring ----
    float ring = aaLine(r - coreR * 1.06, 0.006 + 0.004 * swell);
    vec3 ringCol = peakWhite(ehPal(0.07 + 0.05 * u.spectralCentroid, u),
                             0.35 + 0.45 * swell);
    col += ringCol * ring * (3.5 + 4.5 * swell) * (0.55 + 0.45 * dopp);

    // faint lensed halo just outside the ring
    vec3 rimCol = mix(ehPal(0.12, u), peakWhite(ehPal(0.30, u), 0.2), 0.45);
    col += rimCol * exp(-abs(r - coreR * 1.06) * 22.0) * (0.5 + 0.9 * u.level + 0.3 * swell);

    // beat ripple: a thin, soft ring leaving the horizon, faint and fading
    // as it widens so it never sweeps a bright band over the disk
    float bp = fract(u.beatPhase);
    float shockR = coreR * 1.1 + bp * 0.9;
    float shockA = smoothstep(0.0, 0.12, bp) * (1.0 - smoothstep(0.25, 0.75, bp));
    col += ehPal(0.2, u) * aaLine(r - shockR, 0.004) * shockA * 0.6 * saturate(u.level * 1.15)
         * (1.0 - smoothstep(0.45, 0.9, r));

    // ---- absolute black core ----
    col *= smoothstep(coreR * 0.70, coreR * 1.00, r);

    // swirl smear trails
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.88),
                        0.006 + 0.004 * swell,
                        0.004 + 0.004 * spin);
    return col; // LINEAR HDR
}
