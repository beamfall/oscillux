// SPDX-License-Identifier: AGPL-3.0-only
// Dissolve: the incoming visual's bright features come through first, the
// centre a little before the edges, in soft veils that flow and curl slowly
// across the frame. The outgoing frame drifts towards the viewer and gently
// out of focus, as if the camera were pulling focus past it; the incoming one
// settles from a slight zoom and soft focus into sharpness, breathing faintly
// with the bass. The threshold is lined with a thin iridescent sheen whose
// hue runs through the palette, and where it passes, soft bokeh motes of
// light kindle and drift upward like dust in a beam, then fade: calm, with
// depth, never busy.
vec2 dsZoom(vec2 p, float z) { return 0.5 + (p - 0.5) / z; }

// slow, domain-warped veils in [-0.5, 0.5]
float dsVeil(vec2 q, float t, float sd) {
    vec2 w = vec2(vnoise(q * 1.3 + vec2(sd * 13.0, 0.3 * t)), vnoise(q * 1.3 + vec2(5.2, sd * 7.0 - 0.25 * t))) - 0.5;
    return 0.65 * vnoise(q * 2.0 + 1.3 * w + vec2(sd * 17.0 + 0.4 * t, -0.25 * t))
         + 0.35 * vnoise(q * 4.3 - 0.8 * w + vec2(-0.3 * t, 0.2 * t)) - 0.5;
}

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.2114, 0.2986, 0.3409, 0.3780, 0.4156, 0.4568, 0.5013, 0.5459, 0.5907, 0.6371, 0.6861, 0.7414, 0.7993, 0.8624, 0.9288, 1.0000);
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
    float px = 1.0 / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    bool lowQ = u.presentation1.y > 0.5;
    vec2 sa = vec2(asp, 1.0);
    float e = p * p * (3.0 - 2.0 * p);
    float P = mix(p, e, 0.5);
    float win = sin(3.14159265 * p);
    float bassP = clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    float beat = 0.8 + 0.4 * bassP;

    // focus: the old frame blurs as it recedes, the new one sharpens as it settles
    vec2 ta = dsZoom(uv, 1.0 + 0.05 * (1.0 - e) * (1.0 - e) + 0.004 * bassP * win);
    vec2 fa = dsZoom(uv, 1.0 + 0.08 * P);
    float bt = 5.0 * px * (1.0 - e) * (1.0 - e) * smoothstep(0.0, 0.3, p);
    float bf = 6.0 * px * P * P;
    vec2 d1 = vec2(0.7071, 0.7071) / sa, d2 = vec2(-0.7071, 0.7071) / sa;
    vec3 a = TO(ta);
    vec3 ab = a;                                              // a soft copy, for the bloom
    if (!lowQ) ab = 0.5 * (TO(clamp(ta + d1 * (bt + 3.0 * px), 0.0, 1.0)) + TO(clamp(ta - d2 * (bt + 3.0 * px), 0.0, 1.0)));
    if (!lowQ) a = mix(a, ab, smoothstep(0.0, 4.0 * px, bt) * 0.7);
    vec3 b = FROM(fa);
    if (bf > 0.0 && !lowQ) b = mix(b, 0.5 * (FROM(clamp(fa + d2 * bf, 0.0, 1.0)) + FROM(clamp(fa - d1 * bf, 0.0, 1.0))), 0.65);
    b *= 1.0 - 0.12 * e;                                      // receding, it dims a little

    // the threshold: brightness first, centre first, in slow flowing veils;
    // the bass leans it forward a touch
    float la = luma(a);
    la /= 1.0 + la;
    vec2 s = (uv - 0.5) * sa;                                 // y down
    float veil = dsVeil(s, 3.0 * p, sd);
    float kp = P * 2.3 - 0.5 - 0.4 * length(uv - 0.5) + (0.45 * veil + 0.04 * bassP) * win;
    float k = kp + 0.4 * (la - 0.5);
    float m = smoothstep(0.0, 1.0, k);
    vec3 col = mix(b, a, m);

    // palette light: the rim colour and a hue-rotated accent (never its muddy RGB complement)
    vec3 pc = suppressGreenCast(palRoleRim(0.3 + 0.4 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    pc = clamp((pc - 0.5 * mn) / max(mx - 0.5 * mn, 0.02), 0.0, 1.0);
    vec3 acc = pc.brg.g < pc.gbr.g ? pc.brg : pc.gbr;

    // the arriving highlights bloom
    float arriving = 4.0 * m * (1.0 - m);
    float lb = luma(ab);
    lb /= 1.0 + lb;
    vec3 bloom = (ab * 0.5 + pc * 0.5 * lb) * smoothstep(0.2, 0.75, lb) * arriving * 0.5;

    // an iridescent sheen lines the threshold, its hue running along it
    float th = 6.2831853 * (1.6 * kp + 0.7 * veil) - 2.5 * p;
    vec3 film = mix(pc, acc, 0.5 + 0.5 * cos(th));
    float fm = min(film.r, min(film.g, film.b));
    film = max(film - 0.5 * fm, 0.0);
    film /= max(max(film.r, max(film.g, film.b)), 0.05);
    float edge = exp(-abs(k - 0.1) / 0.045) * smoothstep(0.0, 0.12, p);
    vec3 light = bloom + film * edge * (0.05 + 0.2 * lb);

    // bokeh motes kindle where the threshold passes and drift upward
    if (!lowQ) {
        const float DN = 9.0;
        vec2 gq = (s + vec2(0.0, 0.32 * P)) * DN;
        vec2 ci = floor(gq), cf = gq - ci;
        float h1 = hash21(ci + vec2(sd * 31.0, 1.7)), h2 = hash21(ci + vec2(7.3, sd * 17.0)), h3 = hash21(ci + vec2(13.1, 4.9));
        if (h3 < 0.14) {
            vec2 mc = 0.3 + 0.4 * vec2(h1, h2);
            float rad = 0.1 + 1.1 * h3;                      // in cells, keeps the disc inside its cell
            float d = length(cf - mc) / rad;
            float aa = 1.5 * px * DN / rad;
            float disc = (1.0 - smoothstep(1.0 - aa, 1.0 + aa, d)) * (0.5 + 0.5 * smoothstep(0.4, 1.0, d));
            float near = exp(-abs(kp - 0.2) / 0.08);
            float tw = 0.65 + 0.35 * sin(6.2831853 * (h1 + 1.3 * p));
            light += mix(pc, film, h2) * disc * near * tw * 0.26;
        }
    }
    col += light * win * beat;
    return col;
}
