// SPDX-License-Identifier: AGPL-3.0-only
// Shockwave: energy gathers at a seeded point, pinching the outgoing frame
// inwards, then bursts. A thin pressure shell races out and slows as it
// spreads: its compressed air refracts both frames like a lens, splitting
// them into a chromatic edge, and its leading lip burns in the palette with
// a complementary trailing fringe. Behind the shell the incoming frame is
// carried outwards, smeared into radial motion streaks that relax as the
// air settles, with a heat shimmer in the wake. A weaker echo shell follows
// on the bass, and the shell's glow pulses with the beat.
vec2 swMirror(vec2 x) { return 1.0 - abs(1.0 - abs(x)); }

// keep an accent clear of green-leaning hues: green may not exceed red/blue,
// except in a palette that has no red or blue to speak of
vec3 swTame(vec3 c) {
    float rb = max(c.r, c.b);
    c.g = min(c.g, max(0.92 * rb, 0.3 * c.g));
    return c / max(max(c.r, max(c.g, c.b)), 0.05);
}

// lens profile of the shell at signed distance x (in shell widths)
float swLens(float x) { return x * exp(-x * x); }

vec3 swBody(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    bool lowQ = u.presentation1.y > 0.5;
    vec2 sa = vec2(asp, 1.0);
    float win = sin(3.14159265 * p);

    vec2 c = (vec2(hash11(sd * 37.1 + 1.3), hash11(sd * 59.3 + 4.1)) - 0.5) * vec2(asp * 0.5, 0.4);
    vec2 v = (uv - 0.5) * sa - c;
    float r = length(v);
    vec2 dir = v / max(r, 1e-4);
    float Rmax = length(vec2(0.5 * asp + abs(c.x), 0.5 + abs(c.y))) + 0.22;

    // charge, then the burst: the shell is born fast and decelerates smoothly
    const float T0 = 0.12;
    float t = clamp((p - T0) / (0.96 - T0), 0.0, 1.0);
    float R = Rmax * mix(t * t * (3.0 - 2.0 * t), 1.0 - pow(1.0 - t, 2.2), 0.45);
    float born = smoothstep(T0 - 0.04, T0 + 0.05, p);
    float W = 0.035 + 0.05 * t;                              // the shell thickens as it spreads
    float beat = 0.7 + 0.6 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    float amp = born * win;

    // a slightly ragged front, seamless around the circle
    float rag = (vnoise(dir * 2.3 + sd * 13.0) - 0.5) * 0.06 + (vnoise(dir * 6.0 + sd * 7.0 + 2.0 * p) - 0.5) * 0.025;
    float Rf = R * (1.0 + rag * born);
    float x = (r - Rf) / W;

    // refraction: main shell, a bass echo shell, and the charge pinch
    float Re = 0.62 * Rf;
    float We = 0.6 * W;
    float echo = clamp(0.35 + 0.65 * (u.bass + u.bassImpact), 0.0, 1.0) * smoothstep(0.25, 0.45, t);
    float pinch = sin(3.14159265 * clamp(p / 0.14, 0.0, 1.0));
    pinch *= pinch;                                           // smooth bump before the burst
    float disp = 0.05 * swLens(x) * amp * (1.1 - 0.4 * t)
               + 0.02 * swLens((r - Re) / We) * echo * amp
               - 0.05 * pinch * r * exp(-r / 0.25);
    vec2 d = dir * disp / sa;

    // the wake: a turbulent shimmer just behind the shell
    float wake = exp(-max(-x, 0.0) * 0.35) * smoothstep(0.5, -1.5, x) * amp;
    vec2 sh = vec2(0.0);
    if (!lowQ && wake > 0.01) {
        vec2 hq = v * 9.0 + vec2(sd * 5.0, sd * 3.0) - dir * 4.0 * p;
        sh = (vec2(vnoise(hq), vnoise(hq + vec2(4.1, 2.7))) - 0.5) * 0.008 * wake / sa;
    }

    float m = smoothstep(-1.5 * px, 1.5 * px, r - Rf + 0.25 * W);   // 1 = still the old frame
    vec2 ca = d * 0.25;                                       // the dispersion follows the lens slope
    vec3 col = vec3(0.0);
    if (m > 0.0) {
        vec2 uf = uv + d;
        vec3 f;
        if (lowQ) f = FROM(swMirror(uf));
        else f = vec3(FROM(swMirror(uf + ca)).r, FROM(swMirror(uf)).g, FROM(swMirror(uf - ca)).b);
        // the air just ahead of the shell is compressed and a touch darker
        f *= 1.0 - 0.22 * exp(-pow((x - 1.6) / 1.2, 2.0)) * amp;
        col = f;
    }
    if (m < 1.0) {
        // the incoming frame is carried outwards behind the shell and relaxes
        float carry = 0.14 * exp(-max(-x, 0.0) * W / 0.35) * amp;
        vec2 ct = c / sa + 0.5;
        vec2 ut = ct + (uv - ct) / (1.0 + carry) + d + sh;
        vec3 tc;
        if (lowQ) {
            tc = TO(swMirror(ut));
        } else {
            // radial motion streaks, strongest just behind the shell
            vec2 st = (uv - ct) * 0.06 * exp(-max(-x, 0.0) * W / 0.18) * amp;
            tc = vec3(0.0);
            for (int i = 0; i < 4; ++i) {
                float k = float(i) / 3.0;
                vec2 q = ut - st * k;
                tc += vec3(TO(swMirror(q + ca)).r, TO(swMirror(q)).g, TO(swMirror(q - ca)).b);
            }
            tc *= 0.25;
        }
        tc *= 1.0 - 0.18 * exp(-pow((x + 1.8) / 1.4, 2.0)) * amp;   // rarefied air behind
        col = mix(tc, col, m);
    }

    // light: palette lip on the shell, complementary trailing fringe, echo rim
    // (the trailing accent is the palette's complement pulled towards its peak
    //  role, with any green cast removed, so magenta palettes never fringe green)
    vec3 pc = suppressGreenCast(palRoleRim(0.25 + 0.5 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    pc = swTame(pc);
    vec3 comp = suppressGreenCast(vec3(1.0 + mn / max(mx, 0.05)) - pc);
    vec3 pk = suppressGreenCast(palRolePeak(0.6 + 0.3 * sd, u));
    pk /= max(max(pk.r, max(pk.g, pk.b)), 0.05);
    comp = swTame(mix(comp, pk, 0.55));
    float fade = 1.0 - 0.45 * t;
    float lip = exp(-abs(r - Rf + 0.25 * W) / (1.2 * px + 0.004 * (1.0 - t) + 0.002));
    float halo = exp(-pow(x / 0.9, 2.0));
    float fringe = exp(-pow((x + 1.1) / 0.4, 2.0));
    // caustic: the lens gathers the frames' own light into a bright band inside the lip
    float caus = exp(-pow((x + 0.45) / 0.3, 2.0));
    float cl = luma(col);
    vec3 light = pc * (lip * 0.6 + halo * 0.08) * (0.7 + 0.3 * smoothstep(0.0, 0.4, cl))
               + comp * fringe * 0.11 + col * caus * 0.45;
    light += mix(pc, comp, 0.5) * exp(-pow((r - Re) / We, 2.0)) * 0.07 * echo;
    col += light * amp * fade * beat;
    // the charge: a ring of light converges on the point and a core gathers
    float ci = clamp(p / T0, 0.0, 1.0);
    float Rc = 0.45 * (1.0 - ci) * (1.0 - ci);
    float conv = exp(-abs(r - Rc) / (1.2 * px + 0.006 * (1.0 - ci))) * pinch * (1.0 - ci);
    col += pc * conv * 0.55 * beat;
    float core = exp(-r * r / (0.0003 + 0.0015 * pinch)) * (pinch + 0.6 * exp(-pow((p - T0) / 0.04, 2.0))) * win;
    col += mix(pc, comp, 0.25) * core * 0.9 * beat;
    return col;
}

// The ends hand over to the frames themselves over the first and last 4%, so
// p = 0 is exactly FROM and p = 1 exactly TO at any render size.
// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1483, 0.2114, 0.2553, 0.2978, 0.3386, 0.3783, 0.4168, 0.4548, 0.4949, 0.5378, 0.5855, 0.6391, 0.6977, 0.7797, 0.8812, 1.0000);
float trPace(float p) {
    if (!(p > 0.0)) return 0.0;
    if (p >= 1.0) return 1.0;
    float x = p * 16.0;
    int i = int(x);
    return mix(TR_PACE[i], TR_PACE[i + 1], x - float(i));
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    p = trPace(p);
    vec3 col = mix(FROM(uv), swBody(uv, p, u), smoothstep(0.0, 0.04, p));
    return mix(col, TO(uv), smoothstep(0.96, 1.0, p));
}
