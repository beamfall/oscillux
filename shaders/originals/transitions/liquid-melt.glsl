// SPDX-License-Identifier: AGPL-3.0-only
// Liquid Melt: the incoming frame pours down over the outgoing one as a
// sheet of glossy liquid. Its leading edge is a rounded meniscus that runs
// in drips; each drip starts as a bead, then stretches into a thin neck with
// a heavy round head and accelerates away. The liquid is lit like wet
// lacquer: it refracts the incoming frame with a slight chromatic split, a
// softbox glint and Fresnel sheen in the palette slide over its domed edges,
// and slow ripples run down it. Ahead of it the outgoing frame sags and
// smears downward, and the drips cast a soft wet shadow. Beat and bass lift
// the glints. When it has covered the screen the liquid settles flat.
float lmSmin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

float lmCurtain(float x, float E, float sd) {
    return 0.62 - 1.36 * E + 0.03 * sin(x * 6.0 + 6.2831853 * sd) + 0.018 * sin(x * 15.0 + 9.0 * sd);
}

// signed distance to the edge of the liquid in screen units (negative inside)
float lmField(vec2 s, float p, float E, float sd) {
    float d = lmCurtain(s.x, E, sd) - s.y;
    const float WC = 0.1;
    float ci = floor(s.x / WC);
    for (int j = -1; j <= 1; ++j) {
        float c = ci + float(j);
        float h1 = hash11(c * 0.137 + sd * 7.3);
        float h2 = hash11(c * 0.291 + sd * 3.1 + 0.5);
        float cx = (c + 0.5 + 0.12 * (h1 - 0.5)) * WC;
        float yA = lmCurtain(cx, E, sd) - 0.012;
        float tt = max(p - 0.32 * h1, 0.0);
        float L = (0.06 + 2.2 * h2 * h2 * h2) * tt * tt;      // a few long runs, many short beads
        float rh = 0.016 + 0.022 * h2;
        float rn = mix(rh, 0.009, min(L / 0.18, 1.0));
        float hh = clamp((yA - s.y) / max(L, 1e-4), 0.0, 1.0);
        vec2 cp = vec2(cx, yA - hh * L);
        float dd = length(s - cp) - mix(rn, rh, smoothstep(0.55, 1.0, hh));
        d = lmSmin(d, dd, 0.035);
    }
    return d;
}

float lmRip(vec2 s, float p, float sd) {
    return sin(s.x * 21.0 + 2.2 * sin(s.y * 5.0 + 4.0 * p + 6.0 * sd)) * sin(s.y * 11.0 + 9.0 * p - 2.5 * s.x);
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    bool lowQ = u.presentation1.y > 0.5;
    float E = p * p * (3.0 - 2.0 * p);
    E = mix(p, E, 0.7);
    float win = sin(3.14159265 * p);
    vec2 s = vec2((uv.x - 0.5) * asp, 0.5 - uv.y);
    float beat = 0.6 + 0.8 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    vec3 rimC = suppressGreenCast(palRoleRim(0.3 + 0.4 * sd, u));
    float mx = max(rimC.r, max(rimC.g, rimC.b)), mn = min(rimC.r, min(rimC.g, rimC.b));
    vec3 compC = vec3(mx + mn) - rimC;

    float d = lmField(s, p, E, sd);

    // the outgoing frame ahead of the liquid sags downward and takes a wet shadow
    vec3 a = vec3(0.0);
    if (d > -2.0 * px) {
        float pull = 0.045 * exp(-max(d, 0.0) / 0.07) * win;
        a = FROM(uv - vec2(0.0, pull));
        float ds = lmField(s + vec2(-0.012, 0.022), p, E, sd);
        a *= 1.0 - 0.45 * (1.0 - smoothstep(-0.01, 0.025, ds)) * win;
    }
    float cov = clamp(-d / px + 0.5, 0.0, 1.0);
    if (cov <= 0.0) return a;

    // the liquid: a slab with a rounded meniscus edge and slow ripples
    const float R = 0.04;
    float ex = 1.5 * px;
    float dx = lmField(s + vec2(ex, 0.0), p, E, sd) - d;
    float dy = lmField(s + vec2(0.0, ex), p, E, sd) - d;
    float uu = clamp(-d / R, 0.0, 1.0);
    float dhdd = -(2.0 - 2.0 * uu) / R;
    vec2 g = dhdd * vec2(dx, dy) / ex * 0.03;
    float r0 = lmRip(s, p, sd);
    g += vec2(lmRip(s + vec2(ex, 0.0), p, sd) - r0, lmRip(s + vec2(0.0, ex), p, sd) - r0) / ex * 0.0012 * win;
    g *= win;
    vec3 n = normalize(vec3(-g, 1.0));

    // refracted incoming frame, split slightly by colour on the domed edges
    vec2 off = vec2(n.x / asp, -n.y) * 0.035;
    vec3 col;
    if (lowQ) {
        col = TO(uv + off);
    } else {
        col = vec3(TO(uv + off * 1.25).r, TO(uv + off).g, TO(uv + off * 0.75).b);
    }
    float thick = uu * (2.0 - uu);
    col *= 1.0 - 0.12 * thick * win;
    vec3 L = normalize(vec3(-0.45, 0.6, 0.66));
    vec3 Hv = normalize(L + vec3(0.0, 0.0, 1.0));
    float nh = max(dot(n, Hv), 0.0);
    float spec = pow(nh, 90.0) * 0.9 + pow(nh, 14.0) * 0.08;
    float fres = 1.0 - n.z;
    fres = fres * fres * 4.0;
    vec3 envC = mix(compC * 0.4, rimC, smoothstep(-0.6, 0.8, n.y));
    col += (mix(rimC, compC, 0.3) * spec + envC * min(fres, 1.0) * 0.3) * win * beat;
    // a thin bright lip along the meniscus
    float lip = exp(-abs(d + 1.5 * px) / (1.3 * px));
    col += mix(rimC, compC, 0.4) * lip * 0.35 * win * beat;
    return mix(a, col, cov);
}
