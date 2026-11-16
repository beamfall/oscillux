// SPDX-License-Identifier: AGPL-3.0-only
// Particle Dust: the outgoing frame disintegrates from a seeded side. Its
// ragged, anti-aliased edge smoulders with a thin ember rim in the palette
// (brighter on the beat), charring the image just ahead of it; behind the
// edge the sheet boils off into motes that drift away on a curling,
// divergence-free wind, rising, shrinking and cooling as they go. Motes are
// scattered at random, carry the colour of the spot they came from, are
// key-lit spheres that glow hot as they leave and glint as they tumble, and
// are depth-sorted, with a sparser layer of large, defocused motes in front
// for parallax. Behind them the incoming frame settles into place.
float pdRelease(vec2 o, vec2 w, float he, float sd) {
    float a = clamp((dot(o, w) + he) / (2.0 * he), 0.0, 1.0);
    // cheap smooth ragging (evaluated many times per pixel)
    float ph = sd * 6.2831853;
    float n = 0.5 * sin(o.x * 2.3 + o.y * 1.4 + 3.0 * ph) * sin(o.y * 3.1 - o.x * 0.9 + 2.0 * ph);
    return 0.1 + 0.44 * a + 0.12 * n;
}

// divergence-free swirl from an analytic stream function
vec2 pdCurl(vec2 q, float t) {
    vec2 k1 = vec2(2.1, 1.3), k2 = vec2(-1.2, 2.7), k3 = vec2(3.9, -2.2);
    vec2 c = cos(dot(k1, q) + t) * vec2(k1.y, -k1.x) * 0.5
           + cos(dot(k2, q) - 1.3 * t + 1.7) * vec2(k2.y, -k2.x) * 0.35
           + cos(dot(k3, q) + 0.7 * t + 4.1) * vec2(k3.y, -k3.x) * 0.15;
    return c;
}

vec2 pdDrift(vec2 o, float age, vec2 w, float sd, float par) {
    float a = max(age, 0.0);
    vec2 wind = (-w * 0.8 + vec2(0.0, -0.55)) * 2.6 * a * a;
    vec2 sw = pdCurl(o * 1.3 + vec2(sd * 11.0, 0.0), 3.0 * a + sd * 6.0) * 0.32 * a * smoothstep(0.0, 0.12, a);
    return (wind + sw) * par;
}

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1417, 0.1989, 0.2416, 0.2789, 0.3161, 0.3528, 0.3880, 0.4231, 0.4591, 0.4966, 0.5371, 0.5802, 0.6348, 0.7173, 0.8452, 1.0000);
float trPace(float p) {
    if (!(p > 0.0)) return 0.0;
    if (p >= 1.0) return 1.0;
    float x = p * 16.0;
    int i = int(x);
    return mix(TR_PACE[i], TR_PACE[i + 1], x - float(i));
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    p = trPace(p);
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    bool lowQ = u.presentation1.y > 0.5;
    vec2 sa = vec2(asp, 1.0);
    float win = sin(3.14159265 * p);
    float e = p * p * (3.0 - 2.0 * p);
    vec2 s = (uv - 0.5) * sa;                                 // y down

    float ang = (hash11(sd * 23.1 + 0.7) - 0.5) * 0.9 + (sd < 0.5 ? 0.0 : 3.14159265);
    vec2 w = vec2(cos(ang), sin(ang));                        // the front moves along w
    float he = 0.5 * asp * abs(w.x) + 0.5 * abs(w.y) + 0.12;
    float fin = 1.0 - smoothstep(0.9, 1.0, p);
    float beat = 0.7 + 0.6 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    const float LIFE = 0.3;

    vec3 pc = suppressGreenCast(palRoleRim(0.3 + 0.45 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = (vec3(mx + mn) - pc) / max(mx, 0.05);
    pc /= max(mx, 0.05);
    vec3 Ld = normalize(vec3(-w.x * 0.6, -0.7, 0.6));         // key light from the wind's source, above

    // the incoming frame, settling from a slight zoom
    vec3 col = TO(0.5 + (uv - 0.5) / (1.0 + 0.05 * (1.0 - e) * (1.0 - e)));

    // the old frame still in place, eaten by a smouldering, ragged edge
    float cs = 1.0 / (lowQ ? 70.0 : 90.0);
    float rCell = pdRelease((floor(s / cs) + 0.5) * cs, w, he, sd);
    float rP = pdRelease(s, w, he, sd) + 0.045 * (vnoise(s * 7.0 + vec2(sd * 40.0, 0.0)) - 0.5) + 0.02 * (vnoise(s * 26.0 + vec2(3.0, sd * 40.0)) - 0.5);
    float d = rP - p;                                         // > 0: still intact
    float sheet = clamp(d / (0.8 * px) + 0.5, 0.0, 1.0);
    if (sheet > 0.0) {
        vec3 f = FROM(uv);
        float ch = smoothstep(0.035, 0.0, d) * win;           // charring just ahead of the edge
        f *= 1.0 - 0.55 * ch;
        f += pc * luma(f) * 0.6 * ch;
        col = mix(col, f, sheet);
    }
    // the ember rim on both sides of the edge
    float ember = (exp(-abs(d) / 0.0016) + 0.35 * exp(-abs(d) / 0.006)) * win;
    vec3 emc = mix(pc, comp, 0.25 * smoothstep(0.0, -0.01, d));
    col += emc * ember * (0.22 + 0.26 * beat) * (0.6 + 0.4 * sheet);

    // dust layers: fine motes (depth-sorted), then large near ones
    vec2 o0 = s;
    for (int L = 0; L < 2; ++L) {
        // motes drift back from the front, so nothing reaches the intact sheet ahead of it
        if ((L == 1 && lowQ) || fin <= 0.0 || p <= 0.0 || rCell > p + 0.03) break;
        float lcs = L == 0 ? cs : 1.0 / 26.0;
        float par = L == 0 ? 1.0 : 1.55;
        // back-trace the wind to the origin this pixel's motes came from
        // (the near layer starts from the fine layer's answer, scaled by its parallax)
        vec2 o = L == 0 ? s : s - par * (s - o0);
        float ag = 0.0;
        for (int it = 0; it < 2; ++it) {
            if (L == 1 && it == 1) break;
            ag = p - pdRelease(o, w, he, sd);
            o = mix(o, s - pdDrift(o, ag, w, sd, par), 0.85);
        }
        o0 = o;
        if (ag < -0.04 || ag > LIFE + 0.04) continue;
        // the 2x2 cells nearest the origin hold every mote that can reach here
        vec2 bc = floor(o / lcs - 0.5);
        vec4 A = vec4(0.0), B = vec4(0.0);                    // front-most two motes (rgb, alpha)
        float za = 2.0, zb = 2.0;
        for (int j = 0; j <= 1; ++j) {
            for (int i = 0; i <= 1; ++i) {
                vec2 id = bc + vec2(float(i), float(j));
                float h1 = hash21(id + vec2(sd * 37.0, float(L) * 17.0));
                if ((L == 1 && h1 > 0.16) || (L == 0 && h1 > 0.6)) continue;
                vec2 cc = (id + 0.5) * lcs;
                float age = p - pdRelease(cc, w, he, sd);
                if (age <= 0.0 || age > LIFE) continue;
                vec2 h2 = hash22(id + vec2(5.3, sd * 23.0 + float(L) * 3.0));
                float lt = age / (LIFE * (0.45 + 0.55 * h2.y));   // each mote burns out in its own time
                if (lt >= 1.0) continue;
                vec2 jit = (h2 - 0.5) * lcs * 0.72;             // scattered from the start: no lattice
                vec2 pos = cc + pdDrift(cc, age, w, sd, par) + jit;
                vec2 dv = s - pos;
                float k = 1.0;
                float size = L == 0 ? (0.1 + 0.38 * pow(fract(h1 * 7.31), 2.0)) * smoothstep(0.0, 0.06, lt) : 0.2 + 0.12 * h2.x;
                size *= 1.0 - lt * lt;
                float rad = size * lcs;
                float dq = length(dv);
                float soft = L == 0 ? px : px + 0.012 * k;     // the near layer is out of focus
                float al = clamp((rad - dq) / soft + 0.5, 0.0, 1.0) * (1.0 - smoothstep(0.55, 1.0, lt));
                if (al <= 0.0) continue;
                // shading: a lit sphere with a hot core that cools, and a tumbling glint
                vec2 nl = dv / max(rad, 1e-4);
                vec3 n = vec3(nl, sqrt(max(1.0 - dot(nl, nl), 0.0)));
                                vec3 base = FROM(clamp(cc / sa + 0.5, 0.0, 1.0));
                float dif = max(dot(n, Ld), 0.0);
                float hot = exp(-age / 0.05);
                float gl = 0.5 + 0.5 * sin(6.2831853 * h2.x + age * 22.0);
                gl *= gl; gl *= gl;
                float glint = gl * gl * k;
                float rimL = smoothstep(0.55, 1.0, length(nl)) * k;     // lit edge of the sphere
                vec3 c = base * (0.45 + 0.75 * dif) + pc * (0.05 + 0.25 * rimL * dif) * (0.3 + 1.5 * luma(base));
                c += mix(pc, comp, 0.3 * h2.x) * hot * (0.25 + 0.45 * dif) * (0.7 + 0.3 * beat);
                c += mix(pc, comp, h2.y) * (0.35 * glint * beat + 0.15 * pow(max(n.z, 0.0), 2.0) * dif * k);
                c *= 1.0 - 0.35 * lt;                         // cooling, receding
                if (L == 1) {                                 // near bokeh: fades in, softly glowing
                    c = c * 0.7 + mix(pc, comp, 0.3 * h2.y) * (0.1 + 0.4 * luma(base));
                    al *= 0.6 * smoothstep(0.0, 0.2, lt);
                }
                float z = h1;
                if (z < za) { B = A; zb = za; A = vec4(c, al); za = z; }
                else if (z < zb) { B = vec4(c, al); zb = z; }
            }
        }
        col = mix(col, B.rgb, B.a * fin);
        col = mix(col, A.rgb, A.a * fin);
    }
    return col;
}
