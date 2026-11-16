// SPDX-License-Identifier: AGPL-3.0-only
// Chromatic Split: the outgoing frame is pulled apart into its spectrum, as
// if seen through a lens whose dispersion swells and relaxes: the colours
// fan out sideways along a slowly turning axis and in depth (red comes
// forward, blue sinks back, or the reverse), on a soft flowing current. A
// ring of extra dispersion rides out from a seeded point on the beat. At the
// widest split a soft front sweeps across and swaps in the incoming frame;
// the front is itself dispersed into a spectral edge and lights the frames'
// own highlights in the incoming palette, a thin prism line of palette light
// rides it, then the spectrum closes up again. The tap count follows the
// local spread so the fan stays smooth.
// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.3212, 0.3912, 0.4253, 0.4484, 0.4677, 0.4851, 0.5053, 0.5284, 0.5543, 0.5848, 0.6214, 0.6752, 0.7427, 0.8134, 0.8955, 1.0000);
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
    float e = p * p * (3.0 - 2.0 * p);
    float w = sin(3.14159265 * e);
    float w2 = w * w;
    vec2 s = vec2((uv.x - 0.5) * asp, 0.5 - uv.y);
    vec2 o = (vec2(hash11(sd * 31.7 + 0.2), hash11(sd * 17.3 + 1.3)) - 0.5) * vec2(asp, 1.0) * 0.6;
    float beat = 0.6 + 0.8 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    // dispersion strength: an overall bell, a travelling ring of extra split, a soft slope
    float dr = length(s - o);
    float rq = (dr - 1.6 * e + 0.15) / 0.2;
    float ring = exp(-rq * rq);
    float amp = 0.011 * w * (0.7 + 0.5 * ring * beat) * (0.8 + 0.35 * smoothstep(0.0, 1.2, dr));
    float ang = 6.2831853 * sd + 0.6 * (e - 0.5) * (fract(sd * 5.1) > 0.5 ? 1.0 : -1.0);
    vec2 dv = vec2(cos(ang), sin(ang));
    float zs = fract(sd * 2.3) > 0.5 ? 1.0 : -1.0;
    float swp = fract(sd * 3.7) * 6.2831853;
    vec2 sdir = vec2(cos(swp), sin(swp)) / (0.5 * asp + 0.5);
    vec2 cur = vec2(vnoise(s * 1.7 + vec2(sd * 5.0, e * 1.6)),
                    vnoise(s * 1.7 + vec2(11.0, -e * 1.4))) - 0.5;
    float flow = cur.x + 0.5;
    // the swap front is a prism edge: the split is widest where it passes
    float fd = p - 0.5 + 0.22 * dot(s, sdir) + 0.05 * (flow - 0.5);
    amp *= 1.0 + 1.3 * exp(-fd * fd / 0.0025);
    // per-pixel jitter of the taps across the spectrum: a continuous fan, not stepped copies
    vec2 fc = uv * u.resolution.xy;
    float jit = hash21(floor(fc) + vec2(sd * 91.0, 7.0));

    // taps across the split: a centre-weighted image that keeps each colour's own
    // hue, plus a spectral image of their brightness, which fringes the edges in
    // rainbow light instead of tearing a colour into its red and blue parts
    // tap count follows the local spread (sideways split plus the depth split), so the
    // taps stay about 3.6 px apart: the jitter then only smooths, it never reads as grain
    // (at most 12 taps, each of one frame except across the swap front)
    float spx = 2.0 * (amp + 0.016 * w * length(s)) * u.resolution.y;
    float K = lowQ ? clamp(ceil(spx / 6.0), 3.0, 8.0) : clamp(ceil(spx / 3.6), 5.0, 12.0);
    vec3 acc = vec3(0.0), wsum = vec3(0.0), ref = vec3(0.0), spec = vec3(0.0);
    float sw = 0.0, wc = 0.0;
    for (int k = 0; k < 12; ++k) {
        if (float(k) >= K) break;
        float t = (float(k) + jit) / K;
        float ts = 2.0 * t - 1.0;
        vec3 dq = (vec3(t) - vec3(0.18, 0.5, 0.82)) / 0.3;
        vec3 wk = exp(-dq * dq);                           // broad, overlapping spectral responses
        float sc = 1.0 - 0.05 * w - 0.016 * zs * ts * w;    // zoomed in a touch: edges stay off-screen
        vec2 ps = s * sc + dv * amp * ts + cur * 0.02 * w2;
        // the swap front, evaluated where this colour comes from
        float mc = smoothstep(-0.022, 0.022, p - 0.5 + 0.22 * dot(ps, sdir) + 0.05 * (flow - 0.5));
        vec2 pu = vec2(ps.x / asp + 0.5, 0.5 - ps.y);
        vec3 f = mc < 1.0 ? FROM(pu) : vec3(0.0);
        vec3 g = mc > 0.0 ? TO(pu) : vec3(0.0);
        vec3 ck = mix(f, g, mc);
        if (k == 0) ref = ck;
        float cw = exp(-3.0 * ts * ts);
        acc += cw * (ck - ref);                            // relative to the first tap: exact when closed
        wc += cw;
        spec += wk * (luma(ck) - luma(ref));
        wsum += wk;
        sw += mc * (1.0 - mc);
    }
    vec3 res = ref + acc / max(wc, 1e-4);
    vec3 sl = spec / max(wsum, vec3(1e-4));                // spectral brightness, relative to ref
    res = max(res + 1.15 * (sl - vec3(luma(res) - luma(ref))), vec3(0.0));
    sw *= 4.0 / K;

    // the front lights the frames' own highlights in the incoming palette
    vec3 rimC = suppressGreenCast(palVisual(fract(0.25 * sd + 0.2 * dot(s, sdir) + 0.1), u));
    float mx = max(rimC.r, max(rimC.g, rimC.b)), mn = min(rimC.r, min(rimC.g, rimC.b));
    rimC = (rimC - 0.4 * mn) / max(mx - 0.4 * mn, 1e-3);
    vec3 compC = rimC.brg.g < rimC.gbr.g ? rimC.brg : rimC.gbr;  // hue-turned accent, never olive
    float lum = luma(res);
    res += mix(rimC, compC, smoothstep(0.3, 0.7, flow)) * sw * (0.03 + 0.5 * lum) * 0.5 * beat;
    // a prism edge rides the front: a thin dispersed line of light, red to violet across it
    // (palette hue on one side, its accent on the other, a thin bright core between)
    float fdl = fd / 0.0045;
    float bA = exp(-(fdl + 0.9) * (fdl + 0.9) * 2.0), bB = exp(-(fdl - 0.9) * (fdl - 0.9) * 2.0);
    float bC = exp(-fdl * fdl * 6.0);
    float run = 0.75 + 0.25 * sin(9.0 * dot(s, sdir.yx) - 6.2831853 * (p + sd));
    vec3 prismL = rimC * bA + compC * bB + mix(rimC, compC, 0.5) * bC * 1.4;
    res += prismL * run * w2 * (0.12 + 0.5 * lum) * beat;
    // the beat ring shows itself as a faint iridescent halo where it widens the split
    float rh = 0.5 + 0.5 * cos(6.2831853 * (rq * 0.35 + sd));
    res += mix(rimC, compC, rh) * exp(-rq * rq * 6.0) * w * 0.05 * beat;
    // deepen the blacks a little while the spectrum is open
    res *= 1.0 - 0.1 * w2;
    return res;
}
