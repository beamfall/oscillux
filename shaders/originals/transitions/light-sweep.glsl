// SPDX-License-Identifier: AGPL-3.0-only
// Light Sweep: a broad bar of light crosses the screen at a seeded angle like
// a moving glass prism. Inside the bar both frames are refracted and split
// into their colours, highlights flare into anamorphic streaks along the bar,
// and a double palette-coloured core with a complementary trailing fringe
// carries the cut from the outgoing frame to the incoming one.
vec2 lsMirror(vec2 x) { return 1.0 - abs(1.0 - abs(x)); }

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1926, 0.2560, 0.3071, 0.3519, 0.3942, 0.4348, 0.4733, 0.5100, 0.5474, 0.5856, 0.6252, 0.6671, 0.7139, 0.7685, 0.8389, 1.0000);
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
    float th = 6.2831853 * sd;
    vec2 dir = vec2(cos(th), sin(th));
    vec2 pd = vec2(-dir.y, dir.x);
    vec2 a = (uv - 0.5) * sa;
    float t = dot(a, dir);
    float L = 0.5 * (asp * abs(dir.x) + abs(dir.y));
    float Wb = 0.24;
    float bpos = mix(-L - 1.6 * Wb, L + 1.6 * Wb, mix(p, e, 0.6));
    float x = (t - bpos) / Wb;                  // band coordinate, + ahead
    float prof = exp(-4.0 * x * x);
    float m = smoothstep(-0.35, 0.35, x);       // 1 = still the old frame
    bool lowQ = u.presentation1.y > 0.5;

    // refraction through the bar: a prism-like push along the sweep
    float dpr = -8.0 * x * prof;                // d(prof)/dx
    vec2 ref = dir * (0.028 * dpr * win) / sa;
    vec2 disp = dir * (0.010 * prof * win) / sa;
    vec2 dirU = dir / sa;
    vec2 uf = 0.5 + (uv - 0.5) / (1.0 + 0.04 * e) + dirU * 0.03 * e;
    vec2 ut = 0.5 + (uv - 0.5) / (1.0 + 0.06 * (1.0 - e)) - dirU * 0.04 * (1.0 - e);
    bool inBand = prof * win > 0.01;
    vec3 fc = vec3(0.0), tc = vec3(0.0);
    if (m > 0.0) {
        if (!inBand || lowQ) fc = FROM(lsMirror(uf + ref));
        else fc = vec3(FROM(lsMirror(uf + ref - disp)).r, FROM(lsMirror(uf + ref)).g, FROM(lsMirror(uf + ref + disp)).b);
    }
    if (m < 1.0) {
        if (!inBand || lowQ) tc = TO(lsMirror(ut + ref));
        else tc = vec3(TO(lsMirror(ut + ref - disp)).r, TO(lsMirror(ut + ref)).g, TO(lsMirror(ut + ref + disp)).b);
    }
    vec3 col = mix(tc, fc, m);

    vec3 pc = suppressGreenCast(palVisual(0.3 + 0.5 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = vec3(mx + mn) - pc;
    float beat = 0.75 + 0.5 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    // anamorphic streaks: highlights inside the bar smear along it
    float st = 0.0;
    if (inBand) {
        vec2 pu = pd / sa;
        int n = lowQ ? 2 : 4;
        for (int k = 0; k < 4; ++k) {
            if (k >= n) break;
            float o = (float(k) - 0.5 * float(n - 1)) * (lowQ ? 0.09 : 0.045);
            vec2 q = lsMirror(uv + pu * o + ref);
            vec3 sc = m > 0.5 ? FROM(q) : TO(q);
            float l = dot(sc, vec3(0.2126, 0.7152, 0.0722));
            st += l * l / (1.0 + l * l) * (1.0 - abs(o) * 6.0);
        }
        st /= float(n);
    }
    // the core line, its trailing fringe and a faint ghost bar behind
    float core = exp(-abs(t - bpos) / (0.003 + 1.5 * px));
    float fr = exp(-abs(t - bpos + 0.03) / 0.012);
    float core2 = exp(-abs(t - bpos - 0.022) / (0.0015 + 1.0 * px));
    float halo = exp(-0.3 * x * x);             // wide anticipation glow
    vec3 compS = mix(vec3(dot(comp, vec3(0.3333))), comp, 0.7);
    float lw = win * beat;
    col *= 1.0 + (0.25 * prof + 0.08 * halo) * win;
    col += pc * (prof * 0.14 + halo * 0.03 + core * 1.2 + core2 * 0.45 + st * prof * 2.2) * lw;
    col += compS * fr * 0.3 * lw;
    return col;
}
