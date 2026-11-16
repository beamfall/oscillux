// SPDX-License-Identifier: AGPL-3.0-only
// Heat Haze: the air over the outgoing frame starts to shimmer as if above
// hot tarmac, rising in seeded columns. The incoming frame comes up from below
// on the hot air, its edge pushed into soft rising plumes; along that edge the
// air is hottest, so both frames refract strongly there with a chromatic
// fringe and the edge glows faintly in the incoming palette, the plume tips
// in its complement, swelling with the bass. Then the air cools and clears.
vec3 transition(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    bool lowQ = u.presentation1.y > 0.5;
    float e = p * p * (3.0 - 2.0 * p);
    float win = sin(3.14159265 * p);
    vec2 s = vec2((uv.x - 0.5) * asp, 0.5 - uv.y);
    float yu = s.y + 0.5;                                   // 0 at the bottom, 1 at the top
    float beat = 0.6 + 0.8 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    // rising columns of hot air and the shimmer they carry
    float pl = vnoise(vec2(s.x * 2.6 + sd * 17.0, 0.6 * e + sd * 3.0));
    vec2 hq = vec2(s.x * 7.0, s.y * 4.5 - 2.6 * p) + vec2(sd * 31.0, 0.0);
    vec2 n = vec2(vnoise(hq), vnoise(hq * 1.9 + vec2(4.7, -1.3 * p))) - 0.5;
    n.y = n.y * 0.6 + 0.4 * n.x;                             // shimmer leans vertical

    // the incoming frame rises from below, its edge drawn up into tongues of hot air
    float nf = vnoise(vec2(s.x * 9.0 - sd * 5.0, s.y * 3.0 - 2.0 * p));
    float pk = 0.5 + 0.5 * sin(s.x * 10.0 + 4.0 * pl + 2.2 * nf + 6.2831853 * sd);
    float tg = pk * pk * pk * (0.35 + 1.3 * pl);           // tongues of uneven height, wavering
    float f = -0.42 + 1.75 * mix(p, e, 0.6) + (0.3 * tg + 0.22 * (pl - 0.5)) * win + 0.07 * (nf - 0.5);
    float dy = yu - f;
    float bw = 0.035 + 0.07 * tg;                            // the tips thin into wisps
    float m = 1.0 - smoothstep(-bw, bw, dy);                 // 1 below the edge: incoming
    float hot = exp(-dy * dy / 0.02) + 0.5 * exp(-max(dy, 0.0) * 2.5) * smoothstep(-0.05, 0.0, dy);
    float amp = win * (0.009 + 0.012 * pl + 0.024 * hot);
    vec2 d = vec2(n.x, -n.y) * amp * vec2(1.0 / asp, 1.0);
    vec2 dc = d * 0.45 * min(hot, 1.0);                                // dispersion grows at the edge
    vec3 a = vec3(0.0), b = vec3(0.0);
    if (m < 1.0) {
        vec2 q = uv + d * 0.8;
        a = lowQ ? FROM(q) : vec3(FROM(q + dc).r, FROM(q).g, FROM(q - dc).b);
    }
    if (m > 0.0) {
        vec2 q = uv + d * 1.1;
        b = lowQ ? TO(q) : vec3(TO(q + dc).r, TO(q).g, TO(q - dc).b);
    }
    vec3 col = mix(a, b, m);

    // the edge glows in the incoming palette, plume tips in the complement
    // the glow takes the incoming frame's own hue where it has one, the palette
    // elsewhere, at full chroma, so it never sinks to a murky olive over dark frames
    vec3 rA = suppressGreenCast(palVisual(fract(0.62 + 0.2 * sd), u));
    vec3 rB = suppressGreenCast(palVisual(fract(0.95 + 0.2 * sd), u));
    vec3 rimC = min(rA.r, rA.g) - rA.b < min(rB.r, rB.g) - rB.b ? rA : rB;   // the less yellow one
    vec3 fr = b * m + a * (1.0 - m) * 0.7;
    vec3 bc = max(fr - 0.7 * min(fr.r, min(fr.g, fr.b)), 0.0);
    vec3 base = mix(rimC, bc / max(max(bc.r, max(bc.g, bc.b)), 1e-3), 0.8 * smoothstep(0.01, 0.06, luma(fr)));
    base = max(base - 0.5 * min(base.r, min(base.g, base.b)), 0.0);
    base = suppressGreenCast(base / max(max(base.r, max(base.g, base.b)), 0.05));
    // accent: the base hue turned a third of the way round, whichever way is
    // further from yellow-green (a dim yellow over dark frames reads as olive)
    vec3 compC = base.brg.g < base.gbr.g ? base.brg : base.gbr;
    float tip = tg;
    float edge = exp(-dy * dy / 0.0016);
    // the plume tips flare in the complement; the two hues never blend to grey
    vec3 glow = mix(base, compC, smoothstep(0.55, 0.95, tip));
    col += glow * (edge * (0.16 + 0.4 * luma(col)) * 0.6 + hot * 0.015) * win * beat;
    // the hot air darkens the frame behind it slightly, like a heat mirage
    col *= 1.0 - 0.1 * min(hot, 1.0) * win;
    return col;
}
