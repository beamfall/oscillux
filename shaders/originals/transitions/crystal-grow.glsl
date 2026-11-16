// SPDX-License-Identifier: AGPL-3.0-only
// Crystal Grow: frost nucleates at a few seeded points and grows across the
// outgoing frame in fern-like fingers, its growth front a fine sparkling line
// in the palette. Behind the front the frost scatters and frosts over the old
// image, then hardens into faceted crystal: each facet is tilted, so the new
// frame is seen refracted through it with a slight prismatic split, the facet
// edges catch the light and single facets glint as the light moves (more on
// the beat), its edges cut as grooves with a lit bevel. Once the frost has
// covered the frame, a clearing wave spreads from the nuclei: the facets
// settle flat and the crystal clears, leaving the new frame.
float cgArrive(vec2 q, vec2 c1, vec2 c2, vec2 c3) {
    return min(length(q - c1), min(length(q - c2) * 1.25 + 0.12, length(q - c3) * 1.4 + 0.25));
}

vec4 cgFacet(vec2 g, float sd) {                             // nearest facet: (edge dist, centre dist, id hash)
    vec2 i = floor(g), f = fract(g);
    float d1 = 8.0, d2 = 8.0;
    vec2 best = vec2(0.0);
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 o = vec2(float(x), float(y));
            vec2 h = hash22(i + o + vec2(sd * 41.0, sd * 17.0));
            vec2 r = o + 0.15 + 0.7 * h - f;
            float d = dot(r, r);
            if (d < d1) { d2 = d1; d1 = d; best = h; }
            else if (d < d2) { d2 = d; }
        }
    }
    return vec4(sqrt(d2) - sqrt(d1), sqrt(d1), best);
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    bool lowQ = u.presentation1.y > 0.5;
    vec2 sa = vec2(asp, 1.0);
    float win = sin(3.14159265 * p);
    vec2 s = (uv - 0.5) * sa;
    float beat = 0.7 + 0.6 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    // nucleation points, the first one leading
    vec2 c1 = (vec2(hash11(sd * 31.7 + 0.4), hash11(sd * 47.3 + 2.2)) - 0.5) * vec2(asp * 0.8, 0.7);
    vec2 c2 = (vec2(hash11(sd * 13.1 + 5.4), hash11(sd * 77.9 + 1.7)) - 0.5) * vec2(asp * 0.9, 0.8);
    vec2 c3 = (vec2(hash11(sd * 59.3 + 3.3), hash11(sd * 23.9 + 6.1)) - 0.5) * vec2(asp * 0.9, 0.8);
    // the latest arrival, over the corners, edge midpoints and centre
    float Tmax = 0.0;
    for (int k = 0; k < 9; ++k) {
        vec2 q = (vec2(float(k - 3 * (k / 3)), float(k / 3)) * 0.5 - 0.5) * sa;
        Tmax = max(Tmax, cgArrive(q, c1, c2, c3));
    }
    // arrival distance: nearest nucleus, pulled ahead along fern-like ridges
    // fern fingers radiate from the nearest nucleus: ridged noise stretched along the radius
    float d1 = length(s - c1), d2 = length(s - c2) * 1.25 + 0.12, d3 = length(s - c3) * 1.4 + 0.25;
    vec2 cn = d1 < min(d2, d3) ? c1 : (d2 < d3 ? c2 : c3);
    vec2 rv = s - cn;
    float rr = length(rv);
    vec2 dir = rv / max(rr, 1e-4);
    float fr = fbmRidged(dir * 3.2 + vec2(sd * 9.0, rr * 1.8 + sd * 4.0));
    float T = min(d1, min(d2, d3)) * (1.0 - 0.5 * fr * smoothstep(0.0, 0.12, rr));

    // timing in progress units: the front reaches every point by p ~ 0.74, the
    // crystal holds, then a clearing wave from the nuclei settles it by p = 1
    float Tm = 0.78 * Tmax;                                   // (the fern fingers run ahead of the plain distance)
    float tA = 0.02 + 0.7 * mix(T / max(Tm, 1e-3), smoothstep(0.0, 1.0, T / max(Tm, 1e-3)), 0.3);
    float ag = p - tA;                                        // time since the front passed
    float ad = ag * Tm / 0.7;                                 // (the same, as a distance behind the front)
    float tc = 0.76 + 0.18 * clamp(tA / 0.74, 0.0, 1.0);
    float clr = max(smoothstep(tc - 0.07, tc + 0.05, p), smoothstep(0.95, 1.0, p));

    vec3 pc = suppressGreenCast(palRoleRim(0.35 + 0.4 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = (vec3(mx + mn) - pc) / max(mx, 0.05);
    pc = clamp((pc - 0.6 * mn) / max(mx - 0.6 * mn, 0.02), 0.0, 1.0);   // vivid, never white

    // the facets: tilted when the crystal hardens, flat again as it clears
    vec4 fc = cgFacet(s * 15.0, sd);
    float tilt = smoothstep(0.03, 0.1, ag) * (1.0 - clr);
    vec2 tn = (fc.zw - 0.5) * 2.0;
    vec3 nrm = normalize(vec3(tn * 0.55 * tilt, 1.0));
    float reveal = max(smoothstep(0.025, 0.075, ag), smoothstep(0.9, 0.97, p));   // the new frame behind the crystal
    float frost = smoothstep(0.0, 0.02, ag) * (1.0 - smoothstep(0.035, 0.08, ag)) * (1.0 - reveal * reveal);

    vec3 col = vec3(0.0);
    if (reveal < 1.0) {
        // the old frame, frosting over: scattered by the fine frost grain
        vec2 gj = (hash22(floor(uv * u.resolution.xy * 0.5)) - 0.5) * 7.0 * px * frost;
        vec3 f = FROM(clamp(uv + gj * 0.5, 0.0, 1.0));
        if (!lowQ && frost > 0.01) f = 0.5 * (f + FROM(clamp(uv - gj * 0.7, 0.0, 1.0)));
        if (frost > 0.0) {
            float ft = fbmRidged(s * 26.0 + vec2(sd * 3.0, 0.0));
            float lf = luma(f);
            f = mix(f, mix(f, vec3(lf), 0.5) * 0.7 + pc * (0.04 + 0.18 * lf / (1.0 + lf)) + pc * 0.12 * ft * ft, frost);
        }
        // just ahead of the front the old frame cools slightly
        f *= 1.0 - 0.15 * smoothstep(-0.08, 0.0, ad) * (1.0 - frost) * step(ad, 0.0) * win;
        col = f;
    }
    if (reveal > 0.0) {
        vec2 off = nrm.xy * 0.05 / sa;
        vec3 t;
        if (lowQ) t = TO(clamp(uv + off, 0.0, 1.0));
        else t = vec3(TO(clamp(uv + off * 1.25, 0.0, 1.0)).r, TO(clamp(uv + off, 0.0, 1.0)).g, TO(clamp(uv + off * 0.75, 0.0, 1.0)).b);
        // facets lit: a key light from above, specular glints on single facets
        vec3 L = normalize(vec3(0.35 * sin(6.2831853 * sd + 2.0 * p), -0.6, 0.75));
        float lam = dot(nrm, L) - L.z;
        t *= 1.0 + (0.62 * lam + 0.2 * (fc.z - 0.5)) * tilt;    // each facet catches the light its own way
        // a faint milky body in some facets, tinted by the palette
        t = mix(t, vec3(luma(t)) * mix(vec3(1.0), pc, 0.5) + pc * 0.03, 0.15 * tilt * fc.w * fc.w);
        vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
        // glints: a small star of light on the facets that face the light
        float sp = pow(max(dot(nrm, H), 0.0), 30.0) * tilt;
        float star = exp(-fc.y * fc.y / 0.012);               // (centre distance in facet units)
        float pick = smoothstep(0.7, 0.85, fract(fc.z * 7.0 + 0.6 * p));   // the light finds a few facets at a time
        t += mix(pc, comp, fc.w) * sp * (0.06 + 1.1 * star * pick) * beat;
        // facet edges catch the light
        // facet edges: a cut groove with a bright bevel, readable on busy frames
        float gp = 15.0 * px;                                 // one pixel in facet units
        float groove = 1.0 - smoothstep(0.0, 2.5 * gp, fc.x);
        float bevel = exp(-abs(fc.x - 2.0 * gp) / (1.2 * gp));
        t *= 1.0 - 0.35 * groove * tilt;
        t += mix(pc, comp, 0.3) * bevel * tilt * (0.1 + 0.24 * fc.w) * (0.8 + 0.2 * beat);
        col = mix(col, t, reveal);
    }

    // the growth front: a fine sparkling line in the palette
    float lw = 1.5 * px + 0.004;
    float front = exp(-abs(ad - 0.004) / lw) * smoothstep(0.0, 0.03, p);
    float hs = hash21(floor(s * 220.0) + sd * 7.0);
    float spark = smoothstep(0.75, 1.0, hs) * (0.5 + 0.5 * sin(hs * 40.0 + 12.0 * p));   // twinkling, never strobing
    col += (pc * (0.5 + 1.2 * spark) + comp * 0.15) * front * 0.45 * beat * (1.0 - smoothstep(0.76, 0.86, p));
    return col;
}
