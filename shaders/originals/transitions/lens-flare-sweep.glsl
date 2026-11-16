// SPDX-License-Identifier: AGPL-3.0-only
// Lens Flare Sweep: a light source in the palette's colour crosses the lens
// on a gently arcing, seeded path, and the new frame is exposed in its wake:
// a bowed front trails the source, glowing and bending the image slightly as
// it passes. The source carries a full optical flare: a soft core and a
// slowly turning starburst, a long anamorphic streak in the complementary
// hue, and a chain of hexagonal aperture ghosts strung along the line through
// the centre of the lens, mirroring the source's motion. Each ghost is a
// little lens of its own: it shows the other frame, magnified, inside a rim
// split into chromatic rings. A faint veiling glare follows the light, and
// the flare swells with the beat.
float lfHex(vec2 q) {                                        // hexagon distance, 1 on the edge
    q = abs(q);
    return max(q.x * 0.8660254 + q.y * 0.5, q.y);
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    bool lowQ = u.presentation1.y > 0.5;
    vec2 sa = vec2(asp, 1.0);
    float e = p * p * (3.0 - 2.0 * p);
    float E = mix(p, e, 0.55);
    vec2 s = (uv - 0.5) * sa;                                 // y down
    float env = smoothstep(0.0, 0.12, p) * (1.0 - smoothstep(0.86, 1.0, p));
    float bassP = clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    float beat = 0.7 + 0.6 * bassP;

    // the source's path: across the lens, arcing gently
    float ang = (hash11(sd * 27.3 + 0.9) - 0.5) * 0.8 + (sd < 0.5 ? 0.0 : 3.14159265);
    vec2 dir = vec2(cos(ang), sin(ang));
    vec2 nrm = vec2(-dir.y, dir.x);
    float he = 0.5 * asp * abs(dir.x) + 0.5 * abs(dir.y);
    float off = (hash11(sd * 41.9 + 2.6) - 0.5) * 0.5;
    // an S-shaped arc, so the light swings as it crosses rather than gliding straight
    vec2 S = dir * mix(-he - 0.2, he + 0.6, E)
           + nrm * (off - 0.14 * sin(3.14159265 * E) + 0.06 * sin(6.2831853 * E + 6.2831853 * sd));
    // how much of the source is in the lens: ghosts and streak die as it leaves
    vec2 dOut = max(abs(S) - 0.5 * sa, 0.0);
    float vis = exp(-length(dOut) / 0.07);

    // the exposure front: bowed back from the source
    vec2 rs = s - S;
    float al = dot(rs, dir), ac = dot(rs, nrm);
    float fc = al + 0.3 * ac * ac + 0.015 * sin(ac * 17.0 + 4.0 * p + sd * 9.0);
    float rev = smoothstep(0.03, -0.09, fc);
    rev = max(rev, smoothstep(0.9, 1.0, p));
    float fg = exp(-abs(fc + 0.03) / 0.05) * env;            // light along the front
    vec2 bend = dir * 0.014 * fg / sa;

    vec3 pc = suppressGreenCast(palRoleRim(0.2 + 0.6 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = suppressGreenCast((vec3(mx + mn) - pc) / max(mx, 0.05));
    comp /= max(max(comp.r, max(comp.g, comp.b)), 0.05);
    pc = clamp((pc - 0.5 * mn) / max(mx - 0.5 * mn, 0.02), 0.0, 1.0);

    vec3 col = vec3(0.0);
    if (rev < 1.0) col = FROM(clamp(uv + bend, 0.0, 1.0));
    if (rev > 0.0) {
        vec3 t = TO(clamp(uv + bend, 0.0, 1.0));
        if (fg > 0.03 && !lowQ) {
            // the front refracts like a lens edge: the new frame splits into its primaries
            vec2 cs = dir * 0.007 * fg / sa;
            t.r = TO(clamp(uv + bend + cs, 0.0, 1.0)).r;
            t.b = TO(clamp(uv + bend - cs, 0.0, 1.0)).b;
        }
        t *= 1.0 + 0.35 * fg;                                 // freshly exposed: a little hot
        col = mix(col, t, rev);
    }

    // aperture ghosts along the line from the source through the centre
    vec3 light = vec3(0.0);
    float gr = 0.5 + 0.5 * cos(ang * 3.0 + sd * 5.0);
    for (int k = 0; k < 5; ++k) {
        if (lowQ && k >= 3) break;
        float fk = k == 0 ? -0.45 : (k == 1 ? -0.85 : (k == 2 ? 0.42 : (k == 3 ? -1.25 : -0.2)));
        float rk = k == 0 ? 0.1 : (k == 1 ? 0.06 : (k == 2 ? 0.045 : (k == 3 ? 0.15 : 0.03)));
        vec2 gc = S * fk;
        vec2 gq = rot2(0.26) * (s - gc) / rk;
        float hd = lfHex(gq);
        if (hd > 1.35) continue;
        float soft = 1.5 * px / rk + 0.02;
        float inside = 1.0 - smoothstep(1.0 - soft, 1.0 + soft, hd);
        float gi = env * vis * (0.6 + 0.4 * gr) * (k == 3 ? 0.6 : 1.0);
        if (gi < 0.002) continue;
        vec3 tint = (k == 1 || k == 3) ? comp : pc;
        if (inside > 0.0) {
            // the ghost shows the other frame, magnified about its centre
            vec2 guv = clamp((gc + (s - gc) * 0.7) / sa + 0.5, 0.0, 1.0);
            vec3 other = rev < 0.5 ? TO(guv) : FROM(guv);
            float w = inside * gi * 0.55 * (1.0 - 0.4 * hd * hd);
            col = mix(col, other * (0.85 + 0.3 * tint), w);
            light += tint * inside * gi * 0.04;
        }
        // the rim, split into chromatic rings
        float rw = 0.02 + 1.5 * px / rk;
        vec3 ring = vec3(exp(-abs(hd - 1.06) / rw), exp(-abs(hd - 1.0) / rw), exp(-abs(hd - 0.94) / rw));
        light += (ring * 0.55 + tint * 0.45 * ring.g) * gi * 0.22;
    }

    // the source: core, starburst, anamorphic streak, veiling glare
    float r = length(rs);
    float a = atan2_(rs.y, rs.x) + 0.35 * p;                 // the burst turns only slowly
    float burst = pow(0.5 + 0.5 * cos(a * 7.0), 14.0) + 0.6 * pow(0.5 + 0.5 * cos(a * 11.0 + 1.3), 22.0);
    burst *= 0.6 + 0.8 * vnoise(vec2(a * 6.0 + sd * 20.0, 0.0));
    float core = exp(-r / 0.022) * 0.8 + exp(-r / 0.09) * 0.25;
    float rays = burst * exp(-r / 0.2) * 0.35;
    float sy = abs(s.y - S.y), sx = abs(s.x - S.x);
    float streak = exp(-sy / (0.003 + 1.5 * px)) * exp(-sx / 0.75) * 0.5 + exp(-sy / 0.03) * exp(-sx / 0.4) * 0.12;
    float glare = exp(-r / 0.55) * 0.07;
    // a halo ring breathes out from the source on each beat
    float bph = fract(u.beatPhase);
    float halo = exp(-abs(r - 0.05 - 0.22 * bph) / 0.012) * bph * (1.0 - bph) * (1.0 - bph) * 2.4 * bassP;
    vec3 hot = mix(pc, comp, 0.15);
    light += hot * (core + rays * vis) * beat + mix(comp, pc, 0.25) * (streak * beat + halo) * vis + pc * glare;
    // the exposure front: a bright lit seam whose hue shifts along it, with
    // pulses running along it on the beat
    float seam = exp(-abs(fc + 0.03) / 0.01);
    float run = 1.0 + 0.9 * bassP * pow(0.5 + 0.5 * sin(ac * 5.0 - 6.2831853 * u.beatPhase), 4.0);
    vec3 fcC = mix(pc, comp, 0.5 + 0.5 * sin(ac * 4.0 - 5.0 * p + 6.2831853 * sd));
    light += fcC * (fg * 0.2 + seam * 0.55) * run * env;

    // added light stays bounded: a soft knee
    light *= env;
    light = light / (1.0 + 0.5 * luma(light));
    return col + light;
}
