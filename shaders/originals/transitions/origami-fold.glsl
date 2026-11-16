// SPDX-License-Identifier: AGPL-3.0-only
// Origami Fold: the outgoing frame is a printed sheet of paper. Starting at
// its far end, it pleats into an accordion in a travelling wave, each pleat
// tilting up out of the screen and gathering towards a seeded side, so the
// new frame opens up behind it. The pleats are lit by a palette key light:
// faces turned to it brighten with a soft sheen, faces turned away fall into
// shade, the mountain creases catch a fine line of light (brighter on the
// beat) and the valleys darken. As it folds, the sheet stands off the screen
// in mild perspective, its zig-zag silhouette and the shadow it casts falling
// on the new frame. Fully gathered, the folded stack lifts away off the side.
// fold angle of pleat i: far pleats first, each a little late or early, and
// while it folds it flutters gently, more so on the bass
float ofAngle(float i, float n, float f, float sd, float fl, float t) {
    float k = clamp(f * 1.7 - (1.0 - i / max(n - 1.0, 1.0)) * 0.6 - 0.08 * hash11(i * 3.17 + sd * 17.3), 0.0, 1.0);
    return 1.36 * k * k * (3.0 - 2.0 * k) + fl * sin(i * 1.9 + t) * 4.0 * k * (1.0 - k);
}

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.2208, 0.2837, 0.3276, 0.3656, 0.4008, 0.4356, 0.4709, 0.5065, 0.5443, 0.5850, 0.6297, 0.6811, 0.7332, 0.7876, 0.8599, 1.0000);
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
    float win = sin(3.14159265 * p);
    float bassP = clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    float beat = 0.7 + 0.6 * bassP;
    float fl = 0.05 + 0.08 * bassP;
    float ft = 9.0 * p + 6.2831853 * sd;

    // the gather side: left, right, top or bottom
    int side = int(floor(fract(sd * 3.7 + 0.13) * 4.0));
    bool horiz = side < 2;
    float x = side == 0 ? uv.x : (side == 1 ? 1.0 - uv.x : (side == 2 ? uv.y : 1.0 - uv.y));
    float v = horiz ? uv.y : uv.x;
    float Lx = horiz ? asp : 1.0;                             // sheet length, screen-height units
    float Lv = horiz ? 1.0 : asp;
    float N = horiz ? 12.0 : 8.0;
    float wp = 1.0 / N;
    float pxx = px / Lx, pxv = px / Lv;

    float f = smoothstep(0.0, 0.84, p);
    float lift = smoothstep(0.62, 0.98, p);
    float gath = N * wp * cos(1.36);                          // width of the fully gathered stack
    float X0 = -lift * (gath + 0.08);                         // the stack slides off the gather side

    // walk the pleats: find the one under this pixel and the sheet's far edge
    float X = X0, zc = 0.0;
    float pi_ = -1.0, pt = 0.0, pz0 = 0.0, pth = 0.0, pw = 1.0, hmax = 0.0;
    for (int i = 0; i < 12; ++i) {
        float fi = float(i);
        if (fi >= N) break;
        float th = ofAngle(fi, N, f, sd, fl, ft);
        float w = wp * cos(th);
        if (pi_ < 0.0 && x >= X && x < X + w) {
            pi_ = fi; pt = (x - X) / max(w, 1e-5); pz0 = zc; pth = th; pw = w;
        }
        zc += (mod(fi, 2.0) < 0.5 ? 1.0 : -1.0) * wp * Lx * sin(th);
        hmax = max(hmax, zc);
        X += w;
    }
    float XN = X;

    vec3 pc = suppressGreenCast(palRoleRim(0.25 + 0.5 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    pc /= max(mx, 0.05);
    vec3 acc = pc.brg.g < pc.gbr.g ? pc.brg : pc.gbr;        // hue-rotated accent, never muddy

    // the new frame behind, in the sheet's shadow, settling from a slight zoom
    float e = p * p * (3.0 - 2.0 * p);
    vec3 col = TO(0.5 + (uv - 0.5) / (1.0 + 0.04 * (1.0 - e) * (1.0 - e)));
    float sh = smoothstep(0.0, 0.03, hmax) * (1.0 - lift);
    float beyond = x - XN;
    float slen = 0.06 + 1.3 * hmax / Lx;                     // taller folds throw longer shadows
    float sf = 1.0 - smoothstep(0.0, slen, beyond);
    float shadow = sh * sf * sf * step(0.0, beyond) * 0.72;
    // under the sheet's zig-zag edge, where it stands off the screen
    float under = step(X0, x) * step(x, XN) * sh * 0.62;
    col *= 1.0 - max(shadow, under);

    if (pi_ >= 0.0) {
        bool rising = mod(pi_, 2.0) < 0.5;
        float dz = (rising ? 1.0 : -1.0) * wp * Lx * sin(pth);
        float z = pz0 + dz * pt;                              // height of the paper here
        // mild perspective: the folding sheet stands back, its raised parts larger
        float sc = (1.0 - 0.08 * f) * (1.0 + 0.85 * z) * (1.0 + 0.06 * lift);
        float vs = 0.5 + (v - 0.5) / sc;
        float inside = smoothstep(-pxv * 1.5, 0.0, vs) * smoothstep(-pxv * 1.5, 0.0, 1.0 - vs)
                     * smoothstep(-pxx, 0.0, x - X0) * smoothstep(-pxx, 0.0, XN - x);
        if (inside > 0.0) {
            float us = (pi_ + pt) * wp;                       // along the flat sheet
            vec2 suv = horiz ? vec2(side == 0 ? us : 1.0 - us, vs) : vec2(vs, side == 2 ? us : 1.0 - us);
            vec3 paper = FROM(clamp(suv, 0.0, 1.0));
            // lighting: face normals in the fold plane, light from above the far side
            float sn = sin(pth), cn = cos(pth);
            vec2 nrm = vec2(rising ? -sn : sn, cn);
            vec2 L = normalize(vec2(0.8, 0.6));
            float dif = dot(nrm, L) - L.y;                    // relative to the flat sheet: 0 at rest
            vec2 H = normalize(L + vec2(0.0, 1.0));
            float spec = pow(max(dot(nrm, H), 0.0), 28.0) - pow(H.y, 28.0);
            float lp = luma(paper);
            vec3 c = paper * max(1.0 + 0.8 * dif, 0.2) * (1.0 + 0.3 * z);
            // key-lit faces read on dark frames too: a faint graded glow, not a flat tint
            float gq = rising ? pt : 1.0 - pt;
            c += pc * 0.014 * max(dif, 0.0) * gq * gq * (0.6 + 0.4 * beat);
            // a diagonal gloss band sweeps across the lit faces as the sheet gathers
            float gb = (vs + 0.6 * us - mix(1.75, -0.15, f)) / 0.07;
            c += mix(pc, acc, 0.35 + 0.3 * pt) * exp(-gb * gb) * min(max(dif, 0.0) * 3.0, 1.0) * sn * 0.28 * beat;
            // shaded faces darken towards their valley rather than taking a flat tint
            c *= 1.0 - 0.25 * sn * step(dif, -0.05) * (rising ? pt : 1.0 - pt);
            // creases: mountains catch a line of light, valleys fall into shade
            float dA = pt * pw, dB = (1.0 - pt) * pw;          // distance to the pleat's two creases
            bool mtnAtEnd = rising;
            float dM = mtnAtEnd ? dB : dA, dV = mtnAtEnd ? dA : dB;
            float crease = exp(-dM / (pxx * 1.6)) * sn;
            float valley = exp(-dV / (0.25 * wp * (cn + 0.15))) * sn;
            c *= 1.0 - 0.45 * valley;
            c += pc * crease * (0.12 + 0.25 * lp) * beat;
            // the specular lobe rolls off the mountain crease rather than washing the face
            c += mix(pc, acc, 0.25) * max(spec, 0.0) * sn * (0.22 + 0.35 * lp / (1.0 + lp)) * exp(-dM / (0.16 * pw + pxx));
            // the free edge of the sheet catches the light
            float fe = exp(-(XN - x) / (pxx * 1.5)) * smoothstep(0.0, 0.1, f) * (1.0 - lift);
            c += mix(pc, acc, 0.3) * fe * 0.35 * beat;
            // the fine grain of the paper
            float gr = vnoise(suv * vec2(420.0, 360.0));
            c *= 1.0 - 0.06 * gr * f;
            col = mix(col, c, inside);
        }
    }
    return col;
}
