// SPDX-License-Identifier: AGPL-3.0-only
// Ink Bleed: two seeded drops of ink bloom over the outgoing frame. Their
// fronts are a domain-warped distance field with fingered, flowing tendrils;
// ahead of each front the old frame darkens as if wetted, the front itself is
// a lensing meniscus with a palette-coloured glow, and behind it a band of
// fibrous dark pigment thins out to reveal the incoming frame.
vec2 ibMirror(vec2 x) { return 1.0 - abs(1.0 - abs(x)); }

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.2299, 0.3173, 0.3793, 0.4303, 0.4747, 0.5150, 0.5524, 0.5886, 0.6243, 0.6608, 0.6985, 0.7383, 0.7814, 0.8310, 0.8997, 1.0000);
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
    vec2 a = (uv - 0.5) * vec2(asp, 1.0);

    // seeded drop points; the second blooms a little behind the first
    vec2 c1 = (vec2(hash11(sd * 53.1 + 0.7), hash11(sd * 71.3 + 2.9)) - 0.5) * vec2(asp * 0.55, 0.5);
    vec2 c2 = -0.8 * c1 + (vec2(hash11(sd * 19.7 + 5.1), hash11(sd * 29.9 + 8.3)) - 0.5) * vec2(asp * 0.35, 0.3);

    // a third, later drop lands across the frame, so the bloom has an uneven rhythm
    vec2 c3 = vec2((c1.x < 0.0 ? 0.62 : -0.62) * asp * 0.5, -0.55 * c1.y + 0.18 * (hash11(sd * 43.7 + 1.1) - 0.5));

    // flowing domain warp: the ink keeps creeping the whole time
    float fl = 1.6 * p + 0.06 * u.time;
    vec2 wq = a * 2.3 + vec2(sd * 13.0, sd * 7.0);
    vec2 wv = vec2(vnoise(wq + vec2(0.0, fl)), vnoise(wq + vec2(5.2, 1.3 - fl))) - 0.5;
    vec2 aw = a + wv * 0.16;
    vec2 v1 = aw - c1, v2 = aw - c2;
    float d1 = length(v1), d2 = length(v2) * 1.15 + 0.05;
    float k = 0.14;
    vec2 v3 = aw - c3;
    float d3 = length(v3) * 1.3 + 0.2;
    float hm = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
    float d = mix(d2, d1, hm) - k * hm * (1.0 - hm);
    vec2 nv = mix(v2, v1, hm);
    float h3 = clamp(0.5 + 0.5 * (d3 - d) / k, 0.0, 1.0);
    d = mix(d3, d, h3) - k * h3 * (1.0 - h3);
    nv = mix(v3, nv, h3);
    vec2 dv = nv / max(length(nv), 1e-4);
    vec2 dvs = nv / max(length(nv), 0.15);       // continuous through the merge

    // lobed tendrils plus a ridged filament layer (continuous across the
    // seam where the two blooms merge)
    float tn = vnoise(aw * 2.4 + dvs * 2.2 + vec2(sd * 31.0, 3.0) - fl * 0.4);
    float tr = 1.0 - abs(2.0 * vnoise(aw * 6.0 + dvs * 2.0 + vec2(1.7, sd * 17.0) + fl * 0.3) - 1.0);
    float F = d * (1.0 - 0.34 * tn - 0.12 * tr * tr);

    // furthest the field reaches on screen: corners and edge midpoints
    float Tmax = 0.0;
    for (int i = 0; i < 8; ++i) {
        float fi = float(i);
        vec2 bp = vec2(fi < 4.0 ? mod(fi, 2.0) - 0.5 : (fi < 6.0 ? 0.0 : fi - 6.5),
                       fi < 4.0 ? floor(fi * 0.5) - 0.5 : (fi < 6.0 ? fi - 4.5 : 0.0));
        bp *= vec2(asp, 1.0);
        Tmax = max(Tmax, min(min(length(bp - c1), length(bp - c2) * 1.15 + 0.05), length(bp - c3) * 1.3 + 0.2));
    }
    // the tendril terms shrink F well below d, so the front clears the frame
    // near 0.6 * Tmax; pace it to finish late in the switch
    Tmax = Tmax * 0.66 + 0.08;
    // area grows with T^2: a sqrt ramp keeps the covered area close to linear
    float g = 0.32 * sqrt(e) + 0.68 * e * e * e;
    float bassP = clamp(u.bassImpact + 0.4 * u.bass, 0.0, 1.0);
    float T = mix(-0.012 - 3.0 * px, Tmax, g) + 0.02 * bassP * win * win; // the ink breathes on the bass
    float s = F - T;
    float w = 2.0 * px;
    float mask = smoothstep(-w, w, s) * (1.0 - smoothstep(0.86, 1.0, p)); // 1 = old frame

    float beat = 0.75 + 0.5 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    float sp = max(s, 0.0), si = max(-s, 0.0);
    float halo = exp(-sp / 0.035) * win;
    float rim = exp(-abs(s) / (0.0025 + 1.2 * px)) * win;
    float glow = exp(-abs(s) / 0.03) * win;
    float pig = smoothstep(0.0, 0.008, si) * exp(-si / 0.12) * win;
    float thread = smoothstep(0.82, 1.0, tr) * exp(-si / 0.18) * win * (1.0 - mask);
    float fil = smoothstep(0.86, 0.95, tr) * exp(-sp / 0.05) * smoothstep(-0.004, 0.004, s) * win;

    // the meniscus lenses the frames outward along the bloom
    vec2 ref = dv * (0.010 * glow + 0.006 * halo);
    ref *= smoothstep(0.0, 0.12, length(nv));
    ref.x /= asp;

    vec3 col = vec3(0.0);
    if (mask < 1.0) {
        vec2 o1 = c1 / vec2(asp, 1.0) + 0.5;
        vec2 ut = o1 + (uv - o1) / (1.0 + 0.1 * (1.0 - e));
        vec3 t;
        if (u.presentation1.y > 0.5 || glow < 0.02) {
            t = TO(ibMirror(ut - ref));
        } else {
            t = vec3(TO(ibMirror(ut - ref * 0.6)).r, TO(ibMirror(ut - ref)).g, TO(ibMirror(ut - ref * 1.5)).b);
        }
        col = t;
    }
    if (mask > 0.0) {
        vec3 f = FROM(ibMirror(uv - ref));
        f *= 1.0 - 0.45 * halo;
        col = mix(col, f, mask);
    }

    vec3 pc = suppressGreenCast(palVisual(0.25 + 0.5 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = vec3(mx + mn) - pc;              // complementary accent
    vec3 inkC = pc * 0.05;
    float pm = pig * (0.6 + 0.4 * tr * tr) * (1.0 - mask);
    col = mix(col, col * 0.1 + inkC, pm);
    col *= 1.0 - 0.6 * thread;
    col = mix(col, col * 0.2 + inkC, 0.85 * fil);
    float lit = 0.65 + 0.35 * dot(dv, vec2(-0.6, -0.8));
    col += pc * rim * 1.0 * beat * lit;
    col += comp * glow * (1.0 - mask) * 0.04 * beat;
    col += pc * fil * 0.12 * beat;
    return col;
}
