// SPDX-License-Identifier: AGPL-3.0-only
// Burn: the outgoing frame catches at two seeded points and burns away like
// paper. The front is a noise-ragged distance field that runs faster upwards,
// as flame does; ahead of it the paper scorches and chars, the front itself is
// a flickering palette-coloured ember line, sparks rise off it, and the heat
// above it shimmers both frames. The incoming frame lies behind, lit by the
// glow of the burning edge.
vec2 buMirror(vec2 x) { return 1.0 - abs(1.0 - abs(x)); }

float buDist(vec2 v) {
    // flame climbs: distance above the seed counts for less than below it
    float fy = mix(1.18, 0.72, smoothstep(-0.12, 0.12, -v.y));
    return length(v * vec2(1.0, fy));
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float win = 4.0 * p * (1.0 - p);
    float e = p * p * (3.0 - 2.0 * p);
    float px = 1.0 / max(u.resolution.y, 1.0);
    vec2 sa = vec2(asp, 1.0);
    vec2 a = (uv - 0.5) * sa;
    bool lowQ = u.presentation1.y > 0.5;

    vec2 c1 = (vec2(hash11(sd * 41.3 + 0.9), hash11(sd * 67.1 + 2.3)) - 0.5) * vec2(asp * 0.55, 0.45);
    float sx = c1.x < 0.0 ? 1.0 : -1.0;
    vec2 c2 = vec2(c1.x + sx * asp * (0.38 + 0.12 * hash11(sd * 23.9 + 4.7)), (hash11(sd * 31.7 + 7.1) - 0.5) * 0.6);

    // ragged, licking front: a coarse lobe layer and a fine layer that flows up
    float fl = p;
    float n1 = vnoise(a * 2.6 + vec2(sd * 17.0, sd * 5.0));
    float n2 = vnoise(a * 8.0 + vec2(sd * 11.0, 2.5 * fl));
    float n3 = vnoise(a * 26.0 + vec2(sd * 3.0, 5.0 * fl));
    float d1 = buDist(a - c1), d2 = buDist(a - c2) * 1.1 + 0.07;
    float kk = 0.12;
    float hm = clamp(0.5 + 0.5 * (d2 - d1) / kk, 0.0, 1.0);
    float d = mix(d2, d1, hm) - kk * hm * (1.0 - hm);
    vec2 nv = mix(a - c2, a - c1, hm);
    vec2 dv = nv / max(length(nv), 1e-4);
    float F = d * (1.0 - 0.36 * n1 - 0.2 * n2) - 0.024 * n3;

    float Tmax = 0.0;
    for (int i = 0; i < 8; ++i) {
        float fi = float(i);
        vec2 bp = vec2(fi < 4.0 ? mod(fi, 2.0) - 0.5 : (fi < 6.0 ? 0.0 : fi - 6.5),
                       fi < 4.0 ? floor(fi * 0.5) - 0.5 : (fi < 6.0 ? fi - 4.5 : 0.0));
        bp *= sa;
        Tmax = max(Tmax, min(buDist(bp - c1), buDist(bp - c2) * 1.1 + 0.07));
    }
    Tmax += 0.06;
    // the noise shortens the field, so the last paper goes near 0.42 Tmax: pace the
    // front so that happens late (p ~ 0.86), without a rush at the end
    float g = 0.2 * sqrt(e) + 0.8 * pow(mix(p, e, 0.4), 1.35);
    float T = mix(-0.02 - 3.0 * px, 0.48 * Tmax, g);
    float s = F - T;                                   // > 0: paper still there
    float mask = smoothstep(-1.5 * px, 1.5 * px, s) * (1.0 - smoothstep(0.88, 1.0, p));
    float sp = max(s, 0.0), si = max(-s, 0.0);

    // heat shimmer just above and around the front
    float heat = exp(-abs(s - 0.02) / 0.07) * win;
    vec2 sh = vec2(0.0);
    if (!lowQ && heat > 0.01) {
        vec2 hq = a * 10.0 + vec2(sd * 7.0, 9.0 * p);
        sh = (vec2(vnoise(hq), vnoise(hq + vec2(5.3, 1.7))) - 0.5) * 0.012 * heat / sa;
    }

    vec3 pc = suppressGreenCast(palVisual(0.3 + 0.45 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = vec3(mx + mn) - pc;
    vec3 pcn = pc / max(mx, 0.02);
    float beat = 0.75 + 0.5 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    vec3 col = vec3(0.0);
    if (mask < 1.0) {
        vec2 o1 = c1 / sa + 0.5;
        vec2 ut = o1 + (uv - o1) / (1.0 + 0.07 * (1.0 - e)) + sh;
        vec3 t = TO(buMirror(ut));
        float near = exp(-si / 0.05) * win;
        t *= 1.0 - 0.5 * near;                         // smoke right behind the edge
        t += pc * 0.06 * exp(-si / 0.02) * win * beat; // the edge lights the backdrop
        col = t;
    }
    if (mask > 0.0) {
        vec3 f = FROM(buMirror(uv + sh));
        // scorch: browned towards the palette's warm tone, then char
        float sc = exp(-sp / (0.05 + 0.06 * n1)) * win;
        vec3 scorched = vec3(luma(f)) * (0.35 * pcn + 0.15) + 0.02 * pcn;
        f = mix(f, scorched, 0.85 * sc);
        float ch = (1.0 - smoothstep(0.01, 0.034 + 0.035 * n2 * n2, sp)) * win;
        f = mix(f, scorched * 0.05, 0.97 * ch);
        col = mix(col, f, mask);
    }

    // ember line: a hot core on the edge, broken into brighter and duller
    // stretches, embers glinting in the char, and flame tongues licking upwards
    float flick = 0.2 + 1.5 * n2 * smoothstep(0.25, 0.75, n3);
    float core = exp(-abs(s - 0.0015) / (0.001 + 1.0 * px)) * win;
    float speck = smoothstep(0.6, 0.85, n3) * exp(-sp / 0.012) * smoothstep(0.0, 3.0 * px, s) * win;
    vec3 hot = mix(pc, vec3(mx), 0.35);
    col += hot * core * 1.4 * flick * beat;
    col += pc * speck * 0.45 * n2 * beat;
    float up = smoothstep(0.3, -0.6, dv.y);            // fronts facing up burn taller
    float fn = vnoise(a * vec2(15.0, 4.5) + vec2(sd * 9.0, 7.0 * p));
    float fv = (fn - 0.42) * 3.0 + 0.35 * (n3 - 0.5) - sp / (0.01 + 0.05 * up);
    float flame = smoothstep(0.0, 0.12, fv) * smoothstep(-2.0 * px, 2.0 * px, s) * win;   // crisp tongues
    float fcore = smoothstep(0.3, 0.75, fv);
    col += mix(mix(pc, comp, 0.2), hot, fcore) * flame * (0.4 + 0.35 * fcore) * beat;

    // sparks lifting off the front
    vec2 q = a * 16.0 + vec2(0.0, 14.0 * p);
    vec2 cid = floor(q);
    vec2 hs = hash22(cid + vec2(sd * 31.0, 7.0));
    float hl = hash21(cid + vec2(3.1, sd * 13.0));
    vec2 fo = fract(q) - (0.2 + 0.6 * hs);
    float dist = length(fo) / 16.0;
    float rad = 1.3 * px + 0.0012 * hl;
    float zone = exp(-abs(s - 0.04) / 0.05) * step(0.55, hl);
    float tw = 0.5 + 0.5 * sin(6.2831853 * (hs.x + 1.3 * p));
    float spark = exp(-dist * dist / (rad * rad)) * zone * tw * win;
    col += mix(pc, comp, 0.4 * hs.y) * spark * 1.6 * beat;
    return col;
}
