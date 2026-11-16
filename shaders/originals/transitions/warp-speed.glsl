// SPDX-License-Identifier: AGPL-3.0-only
// Warp Speed: the camera jumps to light speed towards a seeded vanishing
// point. The outgoing frame surges forward and smears into a radial zoom blur
// whose channels trail at different lengths (chromatic streaking), star lines
// race outwards along the rays, and at full stretch the incoming frame takes
// over inside the blur, still rushing in from the distance, then settles as
// the streaks thin out.
vec2 wsMirror(vec2 x) { return 1.0 - abs(1.0 - abs(x)); }

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1296, 0.2112, 0.2774, 0.3369, 0.3878, 0.4309, 0.4719, 0.5142, 0.5603, 0.6078, 0.6563, 0.7073, 0.7636, 0.8254, 0.9000, 1.0000);
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
    float win = 4.0 * p * (1.0 - p);
    float e = p * p * (3.0 - 2.0 * p);
    float px = 1.0 / max(u.resolution.y, 1.0);
    vec2 sa = vec2(asp, 1.0);
    vec2 a = (uv - 0.5) * sa;
    bool lowQ = u.presentation1.y > 0.5;

    vec2 vp = (vec2(hash11(sd * 37.1 + 1.7), hash11(sd * 59.3 + 6.1)) - 0.5) * vec2(asp * 0.3, 0.22);
    vec2 v = a - vp;
    float r = length(v);
    float qk = p * (1.3 - 0.3 * p);                     // stretch peaks a little early
    float wk = 4.0 * qk * (1.0 - qk);
    float k = wk * wk * (3.0 - 2.0 * wk);
    float m = smoothstep(0.38, 0.54, p);                 // 1 = incoming frame
    float zf = 1.0 + 0.55 * e * e;                      // outgoing frame surges forward
    float zt = 1.0 + 0.8 * (1.0 - e) * (1.0 - e);       // incoming rushes in from afar
    float Lb = 0.12 * k;

    // radial zoom blur, R/G/B trailing at different lengths
    // tap offsets are constant along each ray and random between rays a few pixels wide (an
    // integer count, so no seam): the residual sampling pattern becomes radial speed streaks
    // instead of pixel grain
    float tha = atan2_(v.y, v.x);
    float jb = floor((tha * 0.15915494 + 0.5) * 1440.0);
    float jit = hash21(vec2(mod(jb, 1440.0), 17.0 + sd * 41.0));
    int n = lowQ ? 7 : 14;
    float fn = float(n);
    vec3 cf = vec3(0.0), ct = vec3(0.0), ws = vec3(0.0);
    for (int i = 0; i < 14; ++i) {
        if (i >= n) break;
        float t = (float(i) + jit) / fn;
        float sc = 1.0 - Lb * t;
        vec3 wc = exp(-t * vec3(2.0, 1.4, 0.9) * k);
        ws += wc;
        if (m < 1.0) cf += FROM(wsMirror((vp + v * sc / zf) / sa + 0.5)) * wc;
        if (m > 0.0) ct += TO(wsMirror((vp + v * sc * zt) / sa + 0.5)) * wc;
    }
    vec3 col = mix(cf, ct, m) / ws;

    vec3 pc = suppressGreenCast(palVisual(0.25 + 0.5 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    pc = max(pc + (pc - vec3(0.5 * (mx + mn))) * 0.9, 0.0);   // keep light coloured, never white
    mx = max(pc.r, max(pc.g, pc.b)); mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = vec3(mx + mn) - pc;
    float beat = 0.75 + 0.5 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    // tunnel depth: the rim of the view falls into shadow at full stretch
    col *= 1.0 - 0.32 * k * smoothstep(0.25, 1.0, r);

    // star lines: angular bins (integer counts, so no seam), each with a head
    // that accelerates outwards and a tail that lengthens with the stretch
    float th = tha * 0.15915494;
    float Rm = length(vec2(0.5 * asp + abs(vp.x), 0.5 + abs(vp.y)));
    vec3 st = vec3(0.0);
    for (int j = 0; j < 2; ++j) {
        if (lowQ && j > 0) break;
        float N = j == 0 ? 96.0 : 151.0;
        float fb = th * N + 0.37 * float(j);
        float id = mod(floor(fb), N);
        float fr = fract(fb) - 0.5;
        vec2 hh = hash22(vec2(id, float(j) * 7.0 + sd * 13.0));
        if (hh.x < 0.3) continue;
        float ph = fract(hh.x * 7.3 + p * (0.9 + 0.7 * hh.y));
        float head = ph * ph * Rm * 1.15;
        float len = (0.03 + 0.5 * k) * head + 0.01;
        float tail = clamp((r - head + len) / len, 0.0, 1.0);
        float seg = tail * tail * smoothstep(head + 1.5 * px, head, r);
        float dist = abs(fr) * 6.2831853 / N * r;
        float wid = 0.8 * px + 0.0012 * ph;
        float prof = exp(-dist * dist / (wid * wid));
        vec3 sc = mix(pc, comp, step(0.8, hh.y));
        st += sc * seg * prof * (0.4 + 0.8 * ph);
    }
    col += st * 1.3 * k * beat;

    // the glow of the vanishing point at full stretch
    col += mix(pc, comp, 0.2) * exp(-r * r / 0.03) * 0.22 * k * beat;
    return col;
}
