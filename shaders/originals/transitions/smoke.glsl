// SPDX-License-Identifier: AGPL-3.0-only
// Smoke: three depths of smoke roll across the screen from a seeded side. A
// thin, slow haze leads far behind; the main bank follows, its leading edge
// boiling forward in soft billows lit from ahead by a palette key light, with
// silver-lined crowns, self-shadowed undersides and the scene's own light
// scattering through its thin margins. Close to the camera, a few large,
// defocused wisps sweep past faster than the bank, so the layers slide over
// one another in real parallax. Deep in the bank an ember glow in the
// complementary hue breathes with the bass. The switch happens hidden under
// the thickest smoke; behind it the smoke thins into wisps that clear to the
// new frame, bending the image slightly where they pass.

// billow noise: soft puffs with a few shallow creases; q is already warped
float smBillow(vec2 q, int oct) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; ++i) {
        if (i >= oct) break;
        float n = vnoise(q);
        v += a * mix(n, 1.0 - abs(2.0 * n - 1.0), i < 2 ? 0.55 : 0.15);
        q = FBM_OCTAVE * q + vec2(1.7, 9.2);
        a *= 0.5;
    }
    return v * 1.07;
}

// the churning warp that the billows ride on
vec2 smWarp(vec2 q, float t) {
    vec2 wv = vec2(vnoise(q * 0.4 + vec2(0.0, t * 0.3)), vnoise(q * 0.4 + vec2(5.2, 1.3) - vec2(t * 0.25, 0.0))) - 0.5;
    return q + 1.1 * wv + vec2(0.0, -0.3 * t);
}

// density of a bank at along-travel offset xb, given the billow value n
float smShape(float xb, float n) {
    float lump = (n - 0.5) * 0.5;
    float prof = smoothstep(0.16, -0.1, xb + lump) * smoothstep(-1.0, -0.3, xb + 0.5 * lump);
    return (prof * 1.5 - 0.6 + (n - 0.5) * 1.8) * smoothstep(0.0, 0.1, prof);
}

// cheap soft noise for the haze and the near wisps
float smSoft(vec2 q) {
    return 0.62 * vnoise(q) + 0.38 * vnoise(FBM_OCTAVE * q + vec2(3.1, 7.7));
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    bool lowQ = u.presentation1.y > 0.5;
    vec2 sa = vec2(asp, 1.0);
    float win = sin(3.14159265 * p);
    float e = p * p * (3.0 - 2.0 * p);
    float E = mix(p, e, 0.5);
    vec2 s = (uv - 0.5) * sa;                                 // y down

    // the layers travel along w across the whole screen
    float ang = (hash11(sd * 19.7 + 0.3) - 0.5) * 0.7 + (sd < 0.5 ? 0.0 : 3.14159265);
    vec2 w = vec2(cos(ang), sin(ang));
    vec2 nrm = vec2(-w.y, w.x);
    float he = 0.5 * asp * abs(w.x) + 0.5 * abs(w.y);
    float X = mix(-he - 0.3, he + 0.9, E);
    float a = dot(s, w), b = dot(s, nrm);
    float t = 2.2 * p + 7.0 * sd;
    // big rolling lobes along the front, so the bank bulges rather than marches
    float lobe = vnoise(vec2(b * 1.7 + sd * 31.0, 0.5 * t)) - 0.5;
    float xb = a - X + 0.34 * lobe;                           // > 0 ahead of the bank
    float bass = clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    // main bank: billows roll along with it, a little slower than it travels
    const float FQ = 3.1;
    vec2 q = vec2(a - 0.5 * X, b) * FQ + vec2(sd * 13.0, sd * 5.0);
    vec2 qw = smWarp(q, t);
    float n = smBillow(qw, 4);
    float shape = smShape(xb, n);
    float D = clamp(shape, 0.0, 1.0);

    // key light from ahead and above; the density towards it gives the shading
    vec2 Lg = normalize(w * 0.75 + vec2(0.0, -0.65));
    vec2 Lq = vec2(dot(Lg, w), dot(Lg, nrm));
    const float LS = 0.035;
    float shapeL = shape - 0.3 * (n - 0.5);                   // low quality: a cheap guess
    if (!lowQ && shape > -0.3) shapeL = smShape(xb + Lq.x * LS, smBillow(qw + Lq * LS * FQ, 3));
    float D2 = clamp(shapeL, 0.0, 1.0);
    float dif = clamp((shape - shapeL) * 2.0 + 0.35, 0.0, 1.0);

    // far haze: leads the bank, larger and slower, so it slides behind it
    float Xf = mix(-he - 0.05, he + 1.5, mix(p, e, 0.3));
    float Df = 0.0;
    if (a - Xf > -1.75 && a - Xf < 0.6) {
        float nf = smSoft(vec2(a * 0.6 - 0.25 * Xf, b * 1.4) * 1.6 + vec2(sd * 9.0, 2.0 + 0.4 * t));
        Df = smoothstep(0.25, -0.35, a - Xf + 0.6 * (nf - 0.5)) * smoothstep(-1.4, -0.4, a - Xf);
        Df = clamp(Df * (0.25 + 1.1 * nf) - 0.08, 0.0, 1.0) * win;
    }

    // near wisps: large, defocused, crossing faster than the bank
    float Xn = mix(-he - 1.5, he + 1.7, e);
    vec2 qn = vec2(a * 0.7 - 0.55 * Xn, b * 1.6) * 1.15 + vec2(sd * 4.0 + 11.0, 0.3 * t);
    float nn = 0.0, Dn = 0.0;
    if (abs(a - Xn) < 0.6) {
        nn = smSoft(qn);
        Dn = smoothstep(0.5, 0.78, nn) * smoothstep(0.45, 0.0, abs(a - Xn) - 0.12) * win;
    }

    // the frames behind, bent slightly by the thin smoke
    float thin = D * (1.0 - D) * 4.0;
    vec2 off = (Lg * (D2 - D) * 0.025 + nrm * (n - 0.5) * 0.012 * thin + w * Dn * 0.01) * win / sa;
    float cut = smoothstep(-0.2, -0.3, xb + 0.3 * (n - 0.5));   // 1 = the new frame
    vec2 st = clamp(uv + off, 0.0, 1.0);
    vec3 bg = vec3(0.0);
    if (cut < 1.0) bg = FROM(st);
    if (cut > 0.0) bg = mix(bg, TO(st), cut);
    // scene light scattered into the smoke: a wide, cheap tap towards the light
    vec2 sct = clamp(uv - Lg * 0.06 / sa, 0.0, 1.0);
    vec3 scat = mix(FROM(sct), TO(sct), cut);
    // the bank's shadow falls just ahead of it
    bg *= 1.0 - 0.32 * smoothstep(0.4, 0.0, xb) * smoothstep(-0.5, 0.0, xb) * win;

    // palette key light and its complement
    vec3 pc = suppressGreenCast(palRoleRim(0.3 + 0.4 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = (vec3(mx + mn) - pc) / max(mx, 0.05);
    pc /= max(mx, 0.05);
    vec3 ember = suppressGreenCast(comp);
    ember /= max(max(ember.r, max(ember.g, ember.b)), 0.05);
    vec3 sl = min(scat, vec3(2.0));

    // far haze: dim veil tinted by the scene
    vec3 col = mix(bg, sl * 0.4 + mix(pc, comp, 0.4) * 0.09, Df * 0.6);

    // main bank: scene-tinted ambient, key light, silver lining, scattering, ember core
    vec3 amb = sl * 0.14 + mix(pc, comp, 0.5) * 0.014;
    float crown = dif * dif * dif;
    vec3 sc = amb * (0.3 + 0.9 * dif) + pc * 0.32 * crown * (1.0 - 0.4 * D);
    float edge = smoothstep(0.02, 0.18, D) * (1.0 - smoothstep(0.18, 0.5, D));
    sc += (pc * 0.38 * dif + sl * 0.22) * edge;
    float core = smoothstep(0.8, 1.0, D) * smoothstep(0.58, 0.85, n) * (1.0 - dif) * (1.0 - dif);
    sc += ember * core * (0.07 + 0.32 * bass);
    float al = (1.0 - exp(-3.6 * D)) * smoothstep(0.0, 0.05, p) * (1.0 - smoothstep(0.95, 1.0, p));
    col = mix(col, sc, al);

    // near wisps: dark, soft silhouettes with a key-lit rim that pulses with the beat
    float rim = smoothstep(0.5, 0.62, nn) * (1.0 - smoothstep(0.62, 0.8, nn));
    vec3 wc = sl * 0.22 + mix(pc, comp, 0.3) * 0.04 + pc * (0.16 + 0.16 * bass) * rim;
    col = mix(col, wc, Dn * 0.7);
    return col;
}
