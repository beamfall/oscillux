// SPDX-License-Identifier: AGPL-3.0-only
// Aurora Veil: a curtain of aurora light is drawn down over the outgoing
// frame at a seeded slant. Its lower hem is a bright, folded ribbon with a
// thin complementary fringe beneath it, like the pink lower border of a real
// aurora; above the hem fine vertical rays rise and fade, brightest where the
// curtain folds back on itself, drifting and flickering along its length.
// The incoming frame is seen through the rays, coming through first where
// they are brightest, and a second, fainter curtain hangs further back for
// depth. The veil's light spills onto the old frame below it, both frames
// shimmer faintly where the curtain passes, and pulses of brightness run
// along the hem with the beat.
float avRays(vec2 q, float t) {
    float a = vnoise(vec2(q.x * 21.0 + 1.8 * sin(q.x * 1.7 + t), q.y * 0.9 + 0.4 * t));
    float b = vnoise(vec2(q.x * 57.0 - 2.0 * t, q.y * 1.6 + 0.7 * t));
    float r = 0.62 * a + 0.38 * b;
    return r * r * 2.2;
}

// a light colour at full intensity and saturation, keeping its hue
vec3 avVivid(vec3 c) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    return clamp((c - 0.8 * mn) / max(mx - 0.8 * mn, 0.02), 0.0, 1.0);
}

// height of a curtain's hem above which the veil hangs (y up, screen units)
float avHem(float x, float base, float ph, float t) {
    return base + 0.055 * sin(x * 2.3 + ph + 0.9 * t) + 0.025 * sin(x * 5.9 - ph * 1.7 - 1.3 * t)
         + 0.01 * sin(x * 13.0 + 2.1 * t);
}

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1722, 0.2379, 0.2899, 0.3367, 0.3803, 0.4214, 0.4609, 0.4991, 0.5367, 0.5742, 0.6122, 0.6513, 0.6971, 0.7623, 0.8655, 1.0000);
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
    float win = sin(3.14159265 * p);
    float e = p * p * (3.0 - 2.0 * p);
    float E = mix(p, e, 0.6);
    vec2 s = vec2((uv.x - 0.5) * asp, 0.5 - uv.y);
    float dirx = sd < 0.5 ? 1.0 : -1.0;
    float slant = (0.04 + 0.06 * hash11(sd * 17.3 + 1.1)) * dirx;
    float ph = 6.2831853 * hash11(sd * 29.1 + 3.7);
    float t = 5.0 * p * dirx + 4.0 * sd;                     // folds and rays travel along the veil
    float bassP = clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    float beat = 0.7 + 0.6 * bassP;

    // palette: hem colour, high colour, complementary fringe
    vec3 cH = suppressGreenCast(palRoleRim(0.28 + 0.3 * sd, u));
    float mx = max(cH.r, max(cH.g, cH.b)), mn = min(cH.r, min(cH.g, cH.b));
    vec3 comp = avVivid(vec3(mx + mn) - cH);
    cH = avVivid(cH);
    vec3 cT = mix(cH, avVivid(suppressGreenCast(palVisual(0.62 + 0.3 * sd, u))), 0.55);

    // main curtain: the hem travels from above the top to below the bottom
    const float H = 0.34;
    // the hem surges and eases, and a broad drape swell rolls sideways along it
    float Ep = E + 0.03 * sin(12.566371 * p + 6.2831853 * sd) * win;
    float swl = win * (0.13 + 0.03 * bassP) * sin(s.x * 1.5 - 5.0 * p * dirx + ph);
    float base = mix(0.72, -1.06, Ep) + slant * s.x + swl;
    float Y = avHem(s.x, base, ph, t);
    float h = s.y - Y;                                        // > 0: behind the veil
    float rays = avRays(vec2(s.x + 0.05 * sin(s.y * 3.0 + t), s.y), t);
    float fold = pow(0.5 + 0.5 * sin(s.x * 3.3 + ph * 1.3 + 0.7 * t), 6.0);
    fold += 0.6 * pow(0.5 + 0.5 * sin(s.x * 7.1 - ph + 1.1 * t), 8.0);

    // the reveal: through the rays first, complete a little above the hem
    float rv = smoothstep(0.0, H, h + 0.09 * (rays - 0.6) * win + 0.04 * fold * win);
    float shimmer = exp(-abs(h - 0.08) / 0.18) * win;
    vec2 sh = vec2(0.0035 * sin(s.y * 40.0 + 9.0 * p + s.x * 6.0), 0.0) * shimmer;
    vec3 col = vec3(0.0);
    if (rv < 1.0) {
        vec3 f = FROM(clamp(uv + sh, 0.0, 1.0));
        // light spill from the hem onto the old frame below it
        float spill = exp(-max(-h, 0.0) / 0.09) * step(h, 0.0);
        f += cH * f * 0.6 * spill * win;
        col = f;
    }
    if (rv > 0.0) {
        vec3 tc = TO(clamp(uv + sh, 0.0, 1.0));
        col = mix(col, tc, rv);
    }

    // emission of the main curtain
    float hp = max(h, 0.0);
    float prof = (exp(-hp / 0.05) * 0.6 + exp(-hp / 0.16) * 0.36) * smoothstep(-2.5 * px - 0.006, 0.0, h);
    float pulse = 1.0 + 0.7 * clamp(u.bassImpact + 0.4 * u.beat, 0.0, 1.0)
                * pow(0.5 + 0.5 * sin(s.x * 2.0 * dirx - 6.2831853 * u.beatPhase), 4.0);
    float em = prof * (0.25 + 0.9 * rays + 0.9 * fold * (0.4 + rays)) * pulse;
    vec3 ec = mix(cH, cT, smoothstep(0.02, 0.3, hp));
    float hem = exp(-abs(h) / (1.5 * px + 0.004)) * (0.6 + 0.8 * fold);
    float fringe = exp(-pow((h + 0.012) / 0.008, 2.0));
    vec3 light = ec * em * 0.42 + cH * hem * 0.35 + comp * fringe * 0.22 * (0.5 + rays);

    // a second curtain further back crosses the sky on the other diagonal and
    // keeps sweeping through the end of the switch, for depth and counter-motion
    if (!lowQ) {
        float sa2 = -0.48 * dirx, ca2 = 0.877;
        vec2 s2 = vec2(ca2 * s.x + sa2 * s.y, ca2 * s.y - sa2 * s.x);
        float base2 = mix(1.05, -0.95, mix(p, e, 0.75));
        float Y2 = avHem(s2.x * 0.7 + 1.7, base2, ph + 2.0, -0.8 * t);
        float h2 = s2.y - Y2;
        float r2 = avRays(vec2(s2.x * 0.7 + 3.1, s2.y), -0.7 * t + 1.0);
        h2 += 0.05 * (r2 - 0.6);                                  // ragged along the rays
        float hp2 = max(h2, 0.0);
        // it is further back, so its hem is softer than the front one: a
        // broken, out-of-focus glow along the rays, never a hard seam
        float prof2 = (exp(-hp2 / 0.08) * 0.5 + exp(-hp2 / 0.25) * 0.5) * smoothstep(-0.14, 0.1, h2);
        float hem2 = exp(-h2 * h2 / 0.0008) * (0.3 + 0.9 * r2);
        light += mix(cT, cH, 0.3) * (prof2 * (0.2 + 0.8 * r2) * 0.26 + hem2 * 0.09)
               + comp * exp(-pow((h2 + 0.03) / 0.025, 2.0)) * 0.05;
    }
    col += light * win * beat;
    return col;
}
