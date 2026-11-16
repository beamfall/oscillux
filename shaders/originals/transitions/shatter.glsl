// SPDX-License-Identifier: AGPL-3.0-only
// Shatter: an impact at a seeded point cracks the outgoing frame into Voronoi
// glass shards. Cracks race out from the impact with lit lips, then each shard
// tilts on its own axis, refracts with dispersion and falls back into depth,
// darkening, so the incoming frame shows through the widening gaps. A falling
// shard only shrinks towards its own seed, so each pixel inverse-projects
// through the one shard that owns it: sharp, anti-aliased edges at low cost.
const float SH_K = 3.2;   // warp gain: cells per unit of log radius
const float SH_R0 = 0.2;  // warp knee radius (screen heights)
const float SH_F = 4.0;   // focal length in cell units

vec2 shSeed(vec2 g, float sd) {
    return g + 0.15 + 0.7 * hash22(g + vec2(17.0 * sd, 7.0 * sd + 3.1));
}

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.2573, 0.3418, 0.4017, 0.4511, 0.4931, 0.5334, 0.5715, 0.6088, 0.6466, 0.6836, 0.7209, 0.7588, 0.7947, 0.8318, 0.8783, 1.0000);
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
    vec2 off = vec2(0.37, 0.61) + 3.0 * vec2(sd, fract(sd * 7.31));
    vec2 ipA = (vec2(hash11(sd * 91.7 + 1.3), hash11(sd * 37.3 + 4.1)) - 0.5) * vec2(asp * 0.55, 0.5);
    // radial log warp around the impact: small shards at the hit, long radial
    // ones further out, like real safety glass
    vec2 rv = (uv - 0.5) * vec2(asp, 1.0) - ipA;
    float r = length(rv);
    float R = SH_K * log(1.0 + r / SH_R0);
    vec2 x = off + rv * (R / max(r, 1e-5));
    float pw = max(SH_K / (SH_R0 + r), R / max(r, 1e-5)) / max(u.resolution.y, 1.0);
    vec2 ip = off;
    float maxd = SH_K * log(1.0 + (length(vec2(asp, 1.0)) * 0.5 + length(ipA)) / SH_R0);

    // owner cell of x
    vec2 base = floor(x);
    vec2 sds[9];
    float bd = 1e5;
    vec2 so = x;
    for (int j = 0; j < 3; ++j) {
        for (int i = 0; i < 3; ++i) {
            vec2 s = shSeed(base + vec2(float(i - 1), float(j - 1)), sd);
            sds[j * 3 + i] = s;
            vec2 dv = s - x;
            float dd = dot(dv, dv);
            if (dd < bd) { bd = dd; so = s; }
        }
    }
    vec2 g = floor(so);
    vec2 h = hash22(g + vec2(3.7, 1.9 + sd * 5.0));
    vec2 h2 = hash22(g + vec2(9.1 + sd * 3.0, 4.3)) * 2.0 - 1.0;
    float dn = clamp(length(so - ip) / maxd, 0.0, 1.0);
    float crack = smoothstep(0.02 + 0.14 * dn, 0.07 + 0.14 * dn, p);
    float st = 0.07 + 0.46 * dn + 0.05 * h.x;
    float f = clamp((p - st) / 0.42, 0.0, 1.0);
    float fs = f * f * (3.0 - 2.0 * f);
    float fe = f * f;
    float z = 5.0 * fs;

    vec2 ax = h2 * inversesqrt(max(dot(h2, h2), 1e-4));
    vec2 pe = vec2(-ax.y, ax.x);
    // tilt via its half-angle tangent; small spin with polynomial sin/cos
    float tt = (0.03 + 0.03 * h.y) * crack * win + fe * (0.5 + 0.4 * h.y);
    float cp = (1.0 - tt * tt) / (1.0 + tt * tt), sp = 2.0 * tt / (1.0 + tt * tt);
    float a0 = h2.y * 0.5 * fe;
    float ss = a0 - a0 * a0 * a0 / 6.0, sc = 1.0 - 0.5 * a0 * a0;
    vec2 rel = x - so;
    vec2 o = vec2(sc * rel.x + ss * rel.y, -ss * rel.x + sc * rel.y);
    float oa = dot(o, ax), ob = dot(o, pe);
    float den = cp * SH_F - ob * sp;
    // incoming frame: a dolly that breathes with the bass, and two refractive
    // shock rings from the impact (one at the hit, one as the shards let go)
    float bassP = clamp(u.bassImpact + 0.4 * u.bass, 0.0, 1.0);
    vec2 rdir = rv / max(r, 1e-4);
    float sw = 0.0, swd = 0.0;
    for (int k = 0; k < 2; ++k) {
        float t0 = k == 0 ? 0.04 : 0.46;
        float a = clamp((p - t0) / (1.0 - t0), 0.0, 1.0);
        float rr = (a * (1.6 - 0.6 * a)) * (1.1 + 0.2 * float(k));
        float dx = (r - rr) / (0.05 + 0.05 * a);
        float env = smoothstep(0.0, 0.12, a) * (1.0 - a) * (k == 0 ? 1.0 : 0.8);
        float pr = exp(-dx * dx);
        sw += pr * env;
        swd += -2.0 * dx * pr * env;
    }
    float bw = 0.7 + 0.6 * bassP;
    vec2 tuv = 0.5 + (uv - 0.5) / (1.0 + (0.06 + 0.02 * bassP * win) * (1.0 - e));
    tuv -= rdir * vec2(1.0 / asp, 1.0) * swd * 0.014 * bw;
    vec3 to = TO(tuv) * (0.82 + 0.18 * e);
    // palette reads hoisted: three per pixel, shared by every glow below
    vec3 pA = palVisual(0.15, u), pB = palVisual(0.5, u), pC = palVisual(0.82, u);
    float pk = clamp(u.onset * 0.18 + u.bassImpact * 0.10, 0.0, 1.0);
    vec3 swC = suppressGreenCast(mix(pB, pC, 0.4));
    to += swC * sw * 0.3 * bw * (0.4 + 0.6 * to / (to + 0.3));
    if (den < 0.2) return to;
    float b = ob * (SH_F + z) / den;
    float kk = SH_F / max(SH_F + b * sp + z, 0.5);
    vec2 q = so + ax * (oa / kk) + pe * b;

    // distance from q to the owner's Voronoi border (positive inside)
    float d = 1e5;
    vec2 en = vec2(0.0);
    for (int k = 0; k < 9; ++k) {
        vec2 dv = sds[k] - so;
        float l2 = dot(dv, dv);
        if (l2 < 1e-6) continue;
        float il = inversesqrt(l2);
        float dd = (0.5 * l2 - dot(q - so, dv)) * il;
        if (dd < d) { d = dd; en = dv * il; }
    }
    float pwq = pw / (kk * max(cp, 0.2));
    float cov = clamp(d / pwq + 1.0, 0.0, 1.0) * (1.0 - smoothstep(0.6, 1.0, f));
    if (cov <= 0.0) return to;

    // glass: refraction through the tilted plane and the bevelled edge, dispersed
    vec2 n2 = -pe * sp;
    vec3 n3 = vec3(sc * n2.x - ss * n2.y, ss * n2.x + sc * n2.y, cp);
    vec2 eN = vec2(sc * en.x - ss * en.y, ss * en.x + sc * en.y);
    float lift = smoothstep(0.0, 0.05, tt);
    float bevel = 1.0 - smoothstep(0.0, 0.08, d);
    vec2 ref = (n3.xy * 0.06 - eN * 0.014 * bevel * crack) * lift;
    ref.x /= asp;
    vec2 qr = q - off;
    float Rq = length(qr);
    float rq = SH_R0 * (exp(min(Rq, 40.0) / SH_K) - 1.0);
    vec2 uq = (ipA + qr * (rq / max(Rq, 1e-5))) / vec2(asp, 1.0) + 0.5;
    vec3 col;
    if (u.presentation1.y > 0.5) {
        col = FROM(uq + ref);
    } else {
        col = vec3(FROM(uq + ref * 0.7).r, FROM(uq + ref).g, FROM(uq + ref * 1.35).b);
    }
    vec2 Lxy = rot2(0.8 * e - 0.25 * win) * vec2(-0.45, -0.6);
    vec3 L = normalize(vec3(Lxy, 0.66));
    float shade = 1.0 + 0.55 * (dot(n3, L) - L.z);
    col *= max(shade, 0.12) * (1.0 - 0.75 * fs);

    float beat = 0.7 + 0.6 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    vec3 rimC = suppressGreenCast(peakWhite(mix(pA, pB, h.x), pk));
    vec3 glintC = suppressGreenCast(mix(rimC, pC, 0.35)); // accent from across the palette
    vec3 Hv = normalize(L + vec3(0.0, 0.0, 1.0));
    float spec = pow(max(dot(n3, Hv), 0.0), 40.0) * lift;
    float edgeLit = 0.55 + 0.45 * dot(eN, vec2(0.6, 0.8));
    float core = (1.0 - smoothstep(0.0, 1.0 * pwq, d)) * crack * win;
    float line = (1.0 - smoothstep(0.5 * pwq, 1.7 * pwq, d)) * crack * win;
    float lip = exp(-d / (0.03 + 0.03 * fs)) * crack * win * fs;
    col *= 1.0 - 0.7 * core;
    col += rimC * beat * edgeLit * (line * (0.35 + 0.6 * fs) + lip * 1.4);
    // a soft reflection streak sweeps across the glass, bent by each shard's tilt
    vec2 sdir = vec2(0.8, 0.6);
    float bc = dot((uv - 0.5) * vec2(asp, 1.0), sdir) + 1.2 * dot(n3.xy, sdir);
    float sx = (bc - mix(-1.4, 1.4, e)) / 0.07, sx2 = (bc - mix(-1.4, 1.4, e) + 0.3) / 0.025;
    float envr = exp(-sx * sx) + 0.6 * exp(-sx2 * sx2);
    col += glintC * (spec * 0.12 + envr * 0.32 * bw) * win * (0.3 + 0.7 * lift);

    // a short glow at the point of impact
    float ig = exp(-length(x - ip) * 2.0) * smoothstep(0.0, 0.05, p) * (1.0 - smoothstep(0.08, 0.3, p));
    col += rimC * ig * 0.6;
    return mix(to, col, cov);
}
