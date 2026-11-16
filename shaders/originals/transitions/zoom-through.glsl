// SPDX-License-Identifier: AGPL-3.0-only
// Zoom Through: the camera dives into the brightest feature of the outgoing
// frame. The dive accelerates smoothly with a light radial motion blur and no
// rotation, and the light itself opens up: the bright shapes of the outgoing
// frame, nearest the dive point first, turn into windows on the incoming
// frame, their edges glowing and refracting like light through a lens. The
// incoming frame is seen deeper through them, so it grows more slowly
// (parallax), and as the dive carries through it settles to rest. Beat and
// bass brighten the light edges.
vec2 ztMirror(vec2 q) { return 1.0 - abs(1.0 - abs(q)); }

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1593, 0.2281, 0.2827, 0.3258, 0.3655, 0.4051, 0.4407, 0.4728, 0.5021, 0.5306, 0.5619, 0.5976, 0.6389, 0.6871, 0.7594, 1.0000);
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
    bool lowQ = u.presentation1.y > 0.5;
    float E = p * p * (3.0 - 2.0 * p);
    float win = sin(3.14159265 * p);
    float beat = 0.6 + 0.8 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    // the dive point: a soft, brightness-weighted centre of nine candidates
    vec2 c = vec2(0.0);
    float cw = 0.0, lsum = 0.0;
    for (int i = 0; i < 9; ++i) {
        vec2 g = vec2(float(i - 3 * (i / 3)), float(i / 3));
        vec2 j = vec2(hash11(sd * 13.1 + float(i) * 0.71), hash11(sd * 7.7 + float(i) * 1.37)) - 0.5;
        vec2 cand = vec2(0.3) + (g + 0.5 + 0.6 * j) * (0.4 / 3.0);
        // each candidate's brightness is a five-tap area mean, so one small
        // moving highlight cannot swing the dive point from frame to frame
        float lc = 0.0;
        for (int t = 0; t < 5; ++t) {
            vec2 o = t == 0 ? vec2(0.0) : 0.05 * vec2(t == 1 ? 1.0 : t == 2 ? -1.0 : 0.0, t == 3 ? 1.0 : t == 4 ? -1.0 : 0.0);
            lc += 0.2 * clamp(luma(FROM(cand + o)), 0.0, 1.5);
        }
        float w = exp(4.0 * lc);
        lsum += lc;
        c += cand * w;
        cw += w;
    }
    c /= cw;
    vec2 ra = (uv - c) * vec2(asp, 1.0);
    float dist = length(ra);
    vec2 rd = dist > 1e-5 ? (uv - c) / dist : vec2(0.0);   // radial, in uv per screen unit

    // the outgoing frame: an accelerating dive with a light radial blur
    float Z = exp(1.7918 * E);                               // up to 6x
    float bl = 0.045 * win * (0.4 + 0.6 * E);
    float K = lowQ ? 3.0 : 6.0;
    vec3 fa = vec3(0.0), f0 = vec3(0.0);
    float fw = 0.0;
    for (int k = 0; k < 6; ++k) {
        if (float(k) >= K) break;
        float t = float(k) / max(K - 1.0, 1.0);
        vec3 ck = FROM(ztMirror(c + (uv - c) / (Z * (1.0 + bl * t))));
        if (k == 0) f0 = ck;
        float w = 1.0 - 0.6 * t;
        fa += w * (ck - f0);
        fw += w;
    }
    vec3 a = f0 + fa / fw;

    // the light opens: bright shapes near the dive point first, then everything
    float ql = clamp((p - 0.12) / 0.8, 0.0, 1.0);
    float q = mix(ql, ql * ql * (3.0 - 2.0 * ql), 0.5);
    // the opening front, in screen units; it ends past the farthest corner, so
    // wide frames open fully too
    float dmax = length(max(c, 1.0 - c) * vec2(asp, 1.0));
    float Rf = -0.4 + max(2.5, 1.5 * dmax + 0.75) * q;
    // brightness relative to the frame's own level, so a dark frame's neon opens
    // first too; and the front is a ragged, many-pointed burst, never a round bubble
    float lm = lsum / 9.0;
    float lr = smoothstep(0.4 * lm + 0.01, 2.6 * lm + 0.06, luma(a));
    vec2 dn = rd * vec2(asp, 1.0);
    float r1 = vnoise(dn * 2.4 + vec2(sd * 17.0, 0.4 * p));
    float r2 = vnoise(dn * 6.0 + vec2(3.1, sd * 9.0 - 0.6 * p));
    float rag = 0.55 * r1 + 0.45 * (1.0 - abs(2.0 * r2 - 1.0));      // ridged: pointed shards of light
    float F = 1.1 * (lr - 0.5) + 1.5 * (Rf - dist * (0.55 + 0.95 * rag));
    float m = smoothstep(-0.035, 0.035, F);
    float edge = exp(-F * F / 0.006) * win;
    float halo = exp(-max(-F, 0.0) / 0.09) * (1.0 - m) * win; // light spilling ahead of the edge

    // the incoming frame, deeper: it grows more slowly and settles to rest
    float St = 1.0 + 0.6 * (1.0 - E) * (1.0 - E);
    vec2 refr = rd * 0.035 * edge;                           // the lit edge bends the view like a lens
    float KT = lowQ ? 2.0 : 4.0;
    vec3 ta = vec3(0.0), t0 = vec3(0.0);
    float tw = 0.0;
    if (m > 0.0) {
        for (int k = 0; k < 4; ++k) {
            if (float(k) >= KT) break;
            float t = float(k) / max(KT - 1.0, 1.0);
            vec3 ck = TO(ztMirror(c + (uv - c) / St * (1.0 - 0.022 * win * t) - refr));
            if (k == 0) t0 = ck;
            ta += ck - t0;
            tw += 1.0;
        }
    }
    vec3 b = t0 + ta / max(tw, 1.0);
    vec3 col = mix(a * (1.0 - 0.12 * win * smoothstep(0.2, 1.2, dist)), b, m);

    // glowing light edges in the incoming palette, the inner side in its complement
    vec3 rimC = suppressGreenCast(palVisual(fract(0.2 + 0.3 * sd + 0.15 * dist), u));
    float mx = max(rimC.r, max(rimC.g, rimC.b)), mn = min(rimC.r, min(rimC.g, rimC.b));
    vec3 compC = vec3(mx + mn) - rimC;
    vec3 glow = mix(rimC, compC, 0.3 * smoothstep(-0.03, 0.03, F));
    col += glow * (edge * (0.25 + 0.6 * luma(col)) * 0.6 + halo * 0.08) * beat;
    return col;
}
