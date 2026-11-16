// SPDX-License-Identifier: AGPL-3.0-only
// Hex Reveal: a honeycomb force field sweeps out from a seeded point. As the
// front reaches a cell its outline lights in the incoming palette and the
// cell turns to a domed glass lens that magnifies the outgoing frame with a
// chromatic fringe and a specular glint; then the lens falls away into depth,
// shrinking to its centre with a lit rim and a soft shadow on the incoming
// frame beneath, which shows through the widening honeycomb gaps. Beat and
// bass pulse the rims.
vec2 hxCell(vec2 q) {
    const vec2 r = vec2(1.0, 1.7320508);
    vec2 h = 0.5 * r;
    vec2 a = q - r * floor(q / r) - h;
    vec2 b = (q - h) - r * floor((q - h) / r) - h;
    return dot(a, a) < dot(b, b) ? a : b;                // offset from the cell centre
}

float hxDist(vec2 g) {
    vec2 a = abs(g);
    return max(a.x, dot(a, vec2(0.5, 0.8660254)));       // 0.5 on the cell edge
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    bool lowQ = u.presentation1.y > 0.5;
    float win = sin(3.14159265 * p);
    vec2 s = vec2((uv.x - 0.5) * asp, 0.5 - uv.y);
    float cs = 0.12 + 0.03 * fract(sd * 5.3);           // cell width (edge to edge)
    float A = 0.5 * (fract(sd * 3.1) - 0.5);
    vec2 sq = rot2(A) * s / cs + vec2(sd * 7.0, sd * 3.0);
    vec2 g = hxCell(sq);
    vec2 cq = sq - g;
    vec2 cc = s + (rot2(-0.5 * (fract(sd * 3.1) - 0.5)) * (-g)) * cs;   // cell centre on screen
    float hd = hxDist(g);
    float ch = hash21(floor(cq * 2.0 + 0.5) + vec2(sd * 13.0, 1.7));

    // wave from a seeded origin
    vec2 o = (vec2(hash11(sd * 41.7 + 0.3), hash11(sd * 23.1 + 2.1)) - 0.5) * vec2(asp, 1.0) * 0.7;
    // a second, later origin and a lobed front, so the wave surges unevenly
    vec2 o2 = vec2(-0.75 * o.x, 0.6 * o.y) + (vec2(hash11(sd * 17.3 + 5.5), hash11(sd * 61.9 + 0.9)) - 0.5) * vec2(asp * 0.35, 0.4);
    float md = length(vec2(0.5 * asp, 0.5)) + length(o);
    float lobe = vnoise(cc * 1.7 + vec2(sd * 11.0, 3.0)) - 0.5;
    float dn = min(length(cc - o), length(cc - o2) * 1.3 + 0.22 * md) / md + 0.16 * lobe;
    float dl = 0.42 * clamp(dn, 0.0, 1.0) + 0.1 * ch;
    // the front breathes: it surges and eases twice in the switch (always forward)
    float pp = p + 0.03 * sin(12.566371 * p + 6.2831853 * sd) * win;
    float q = clamp((pp - dl) / 0.46, 0.0, 1.0);
    float gl = smoothstep(0.0, 0.22, q);                   // glass forms
    float k = smoothstep(0.28, 1.0, q);
    float sc = 1.0 - k * k * (3.0 - 2.0 * k);              // lens scale as it falls away
    float env = smoothstep(0.0, 0.08, q) * (1.0 - smoothstep(0.08, 0.55, q));

    float bassP = clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    float beat = 0.6 + 0.8 * bassP;
    // a falling lens drifts out, away from the wave, inside its own cell
    vec2 od = cc - (length(cc - o) < length(cc - o2) * 1.3 + 0.22 * md ? o : o2);
    vec2 dL = rot2(A) * (od / max(length(od), 1e-4)) * vec2(1.0, 1.0);
    vec2 drift = dL * 0.38 * (1.0 - sc);
    vec2 g0 = g;
    g -= drift;
    cc += rot2(-A) * drift * cs;
    hd = hxDist(g);
    vec3 rimC = suppressGreenCast(palVisual(fract(0.3 * sd + 0.35 * dn + 0.12 * ch), u));
    float mx = max(rimC.r, max(rimC.g, rimC.b)), mn = min(rimC.r, min(rimC.g, rimC.b));
    vec3 compC = vec3(mx + mn) - rimC;

    // the incoming frame beneath, shaded by the falling lens
    vec2 dir = length(g) > 1e-4 ? g / length(g) : vec2(0.0);
    vec2 sdir = rot2(-0.5 * (fract(sd * 3.1) - 0.5)) * vec2(dir.x, dir.y);
    vec2 ripple = vec2(sdir.x, -sdir.y) * 0.006 * sin(18.0 * hd - 9.0 * q) * sc * (1.0 - sc) * 4.0;
    vec3 back = TO(uv + ripple);
    float shd = sc * (1.0 - sc) * 4.0 * (1.0 - smoothstep(0.5 * sc - 0.05, 0.5 * sc + 0.22, hd - 0.04));
    back *= 1.0 - 0.6 * shd;
    float edgePx = (0.5 - hxDist(g0)) * cs / px;           // pixels inside this cell's border
    float lines = exp(-edgePx / 1.1) * 0.9 + exp(-edgePx / 7.0) * 0.22;
    back += mix(rimC, compC, 0.3) * lines * 0.7 * sin(3.14159265 * q) * (1.0 - sc) * beat;

    // the lens: the outgoing frame, magnified and dispersed, falling into depth
    float scd = max(sc, 1e-3);
    float hl = clamp(hd / (0.5 * scd), 0.0, 1.0);          // 0 centre .. 1 rim of the lens
    float mag = 0.28 * gl * (1.0 - hl * hl) * (0.75 + 0.45 * bassP);
    vec2 rel = (s - cc) / scd;                              // the image shrinks with the lens
    vec2 fs0 = cc + rel * (1.0 - mag);
    vec2 fu = vec2(fs0.x / asp + 0.5, 0.5 - fs0.y);
    vec3 lens;
    if (lowQ) {
        lens = FROM(fu);
    } else {
        vec2 dsp = (vec2(rel.x, -rel.y) / asp) * 0.09 * gl * hl * hl;
        lens = vec3(FROM(fu + dsp).r, FROM(fu).g, FROM(fu - dsp).b);
    }
    // glass shading: darker towards the falling rim, a glint, a lit lip
    lens *= 1.0 - 0.35 * gl * hl * hl * hl * hl - 0.4 * (1.0 - sc);
    // a crescent highlight on the dome's upper-left shoulder
    vec2 rn = length(rel) > 1e-5 ? rel / length(rel) : vec2(0.0);
    float cres = pow(max(dot(rn, vec2(-0.7071, 0.7071)), 0.0), 3.0) * smoothstep(0.45, 0.9, hl) * (1.0 - smoothstep(0.9, 1.0, hl));
    lens += mix(compC, rimC, 0.3) * cres * 0.45 * gl * sc * beat;
    float lensPx = (0.5 * scd - hd) * cs / px;
    lens += rimC * (exp(-lensPx / 1.2) * 0.9 + exp(-lensPx / 5.0) * 0.3) * (env + 0.6 * gl * sc * (1.0 - sc)) * beat;
    lens += rimC * 0.18 * pow(hl, 6.0) * gl * sc;
    float cov = clamp(lensPx + 0.5, 0.0, 1.0);
    cov = 1.0 - (1.0 - cov) * min((1.0 - sc) * 40.0, 1.0); // flush at rest: no seam
    cov *= step(1e-3, sc);
    return mix(back, lens, cov);
}
