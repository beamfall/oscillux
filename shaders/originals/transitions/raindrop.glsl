// SPDX-License-Identifier: AGPL-3.0-only
// Raindrop: a bead of water falls at a seeded point, showing the old frame
// upside down inside it, and strikes the surface. A ring wave packet runs out
// from the impact: its slope refracts both frames with dispersion, its
// curvature focuses caustic light, its crests catch a palette-coloured
// specular, and it carries the incoming frame in behind it. A trailing ring
// and small beat-driven ripples keep the water alive.
vec2 rdMirror(vec2 x) { return 1.0 - abs(1.0 - abs(x)); }

// ring packet: returns (height, slope) at signed distance x from its centre
vec2 rdPacket(float x, float sig, float k) {
    float g = exp(-x * x / (sig * sig));
    float cs = cos(k * x), sn = sin(k * x);
    return vec2(g * cs, g * (-2.0 * x / (sig * sig) * cs - k * sn));
}

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1721, 0.2199, 0.2603, 0.2982, 0.3353, 0.3723, 0.4096, 0.4475, 0.4876, 0.5303, 0.5753, 0.6233, 0.6773, 0.7453, 0.8495, 1.0000);
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
    float px = 1.0 / max(u.resolution.y, 1.0);
    vec2 sa = vec2(asp, 1.0);
    vec2 c = (vec2(hash11(sd * 29.3 + 0.8), hash11(sd * 83.7 + 3.3)) - 0.5) * vec2(asp * 0.5, 0.45);
    vec2 v = (uv - 0.5) * sa - c;
    float r = length(v);
    vec2 dir = v / max(r, 1e-4);
    float Rtot = length(vec2(0.5 * asp + abs(c.x), 0.5 + abs(c.y))) + 0.3;
    const float TI = 0.13;
    float ts = clamp((p - TI) / (0.97 - TI), 0.0, 1.0);
    float R = Rtot * ts * (1.55 - 0.55 * ts) - 0.05;
    float beat = 0.75 + 0.5 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    bool lowQ = u.presentation1.y > 0.5;

    // main packet, a trailing one, and beat ripples from the impact point
    float k = 6.2831853 / 0.075;
    float amp = smoothstep(TI - 0.01, TI + 0.06, p) * win;
    vec2 w1 = rdPacket(r - R, 0.07, k) * amp;
    vec2 w2 = rdPacket(r - 0.6 * R, 0.05, k * 1.3) * amp * 0.35;
    float bp = fract(u.beatPhase);
    vec2 w3 = rdPacket(r - 0.05 - 0.45 * bp, 0.04, k * 1.6) * (sin(3.14159265 * bp) * 0.3 * clamp(u.bass + u.bassImpact, 0.0, 1.0)) * amp;
    float h = w1.x + w2.x + w3.x;
    float sl = w1.y + w2.y + w3.y;
    float curv = -(w1.x * k * k + w2.x * k * k * 1.69 + w3.x * k * k * 2.56);

    // falling bead before the impact
    float bA = smoothstep(0.0, 0.05, p) * (1.0 - smoothstep(TI - 0.03, TI, p));
    float br = 0.012 + 0.03 * smoothstep(0.0, TI, p);
    float bd = r / br;

    vec2 ref = dir * sl * 0.00045 / sa;
    float m = smoothstep(R - 0.025, R + 0.025, r);          // 1 = old frame
    vec2 uf = uv + ref;
    vec2 ut = 0.5 + (uv - 0.5) / (1.0 + 0.05 * (1.0 - p) * (1.0 - p)) + ref;
    bool disp = !lowQ && amp > 0.0;                         // continuous: the split follows the slope
    vec2 dd = ref * 0.22;
    vec3 fc = vec3(0.0), tc = vec3(0.0);
    if (m > 0.0) {
        if (bA > 0.0 && bd < 1.2) {
            // the bead: an inverted, magnified view of the frame
            float z = sqrt(max(1.0 - bd * bd, 0.0));
            vec2 bu = (c - v * (1.6 + 1.2 * z)) / sa + 0.5;
            vec3 bead = FROM(rdMirror(bu));
            float edge = smoothstep(1.0, 1.0 - 2.5 * px / br, bd);
            fc = mix(FROM(uv) * (1.0 - 0.35 * bA * exp(-max(bd - 1.0, 0.0) * 3.0)), bead * 1.15, edge * bA);
        } else if (disp) {
            fc = vec3(FROM(rdMirror(uf - dd)).r, FROM(rdMirror(uf)).g, FROM(rdMirror(uf + dd)).b);
        } else {
            fc = FROM(rdMirror(uf));
        }
    }
    if (m < 1.0) {
        if (disp) tc = vec3(TO(rdMirror(ut - dd)).r, TO(rdMirror(ut)).g, TO(rdMirror(ut + dd)).b);
        else tc = TO(rdMirror(ut));
    }
    vec3 col = mix(tc, fc, m);

    vec3 pc = suppressGreenCast(palVisual(0.35 + 0.5 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = vec3(mx + mn) - pc;
    // caustics: light gathers under the converging part of each crest
    float ca = max(curv, 0.0) / (k * k);
    col *= 1.0 + 0.45 * ca;
    col += mix(pc, comp, 0.3) * ca * ca * 0.25 * beat;
    // crest specular from the surface normal
    vec3 n = normalize(vec3(-dir * sl * 0.0042, 1.0));
    vec3 Hh = normalize(vec3(-0.35, -0.55, 1.0) + vec3(0.0, 0.0, 1.0));
    float nh = max(dot(n, Hh), 0.0);
    float nh0 = Hh.z;                                       // the flat water reflects nothing extra
    float sp = (max(pow(nh, 36.0) - pow(nh0, 36.0), 0.0) * 1.1
              + max(pow(nh, 8.0) - pow(nh0, 8.0), 0.0) * 0.25) * amp;  // broad enough to stay smooth per pixel
    col += mix(pc, comp, 0.25) * sp * 0.9 * beat;
    col -= col * 0.25 * max(-h, 0.0);                      // troughs a touch darker
    // bead rim and highlight
    if (bA > 0.0) {
        float rim = exp(-abs(bd - 1.0) * br / (1.5 * px + 0.002)) * bA;
        float hl = exp(-length(v / br + vec2(0.35, 0.4)) * 6.0) * bA * step(bd, 1.0);
        col += pc * rim * 0.6 + mix(pc, comp, 0.5) * hl * 0.9;
    }
    return col;
}
