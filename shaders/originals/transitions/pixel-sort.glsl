// SPDX-License-Identifier: AGPL-3.0-only
// Pixel Sort: the screen splits into pixel-aligned columns along a seeded
// axis. Groups of columns run a sort front across at staggered times: ahead
// of it the old frame's highlights are dragged into luminous sorted streaks,
// the front itself glows in the palette, and behind it the incoming frame
// resolves out of its own streaks with a slight colour split. Every column
// moves smoothly once; nothing flickers.
vec2 psUv(float s, float q, bool vert, float sg) {
    float ss = sg > 0.0 ? s : 1.0 - s;
    ss = 1.0 - abs(1.0 - abs(ss));
    return vert ? vec2(q, ss) : vec2(ss, q);
}

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.2119, 0.2685, 0.3094, 0.3468, 0.3827, 0.4179, 0.4520, 0.4851, 0.5181, 0.5521, 0.5884, 0.6287, 0.6754, 0.7385, 0.8535, 1.0000);
float trPace(float p) {
    if (!(p > 0.0)) return 0.0;
    if (p >= 1.0) return 1.0;
    float x = p * 16.0;
    int i = int(x);
    return mix(TR_PACE[i], TR_PACE[i + 1], x - float(i));
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    p = trPace(p);
    float sd = u.presentation0.y;
    float win = 4.0 * p * (1.0 - p);
    bool vert = hash11(sd * 17.3 + 0.9) < 0.65;
    float sg = hash11(sd * 43.1 + 2.3) < 0.5 ? 1.0 : -1.0;
    vec2 res = max(u.resolution, vec2(1.0));
    float s0 = vert ? uv.y : uv.x;
    float s = sg > 0.0 ? s0 : 1.0 - s0;          // along the sort, 0 -> 1
    float q = vert ? uv.x : uv.y;                // across the columns
    float qpx = q * (vert ? res.x : res.y);
    float px = 1.0 / (vert ? res.y : res.x);     // one pixel along s
    float cw = max(2.0, floor(res.y / 180.0));
    float ci = floor(qpx / cw);
    float hc = hash11(ci * 0.731 + sd * 61.0 + 0.4);
    float hg = hash11(floor(ci / 11.0) * 1.37 + sd * 23.0 + 5.1);
    float hl = hash11(ci * 0.419 + sd * 11.0 + 7.7);
    float delay = 0.3 * hg + 0.08 * hc;
    float k = clamp((p - delay) / 0.55, 0.0, 1.0);
    k = k * k * (3.0 - 2.0 * k);
    float front = mix(-0.35, 1.35, k);
    float Lz = 0.18 + 0.2 * hl;
    float qs = (ci + 0.5) * cw / (vert ? res.x : res.y);   // column centre
    bool lowQ = u.presentation1.y > 0.5;
    int n = lowQ ? 4 : 8;
    float beat = 0.75 + 0.5 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    vec3 col = vec3(0.0);
    vec3 edgeC = vec3(0.0);
    float m = smoothstep(front - px, front + px, s);   // 1 = ahead: old frame
    float sw = smoothstep(0.0, 0.25, win);
    if (m > 0.0) {
        // a sorted run ahead of the front: the column's pixels just ahead of the front are
        // ranked by brightness and laid out as one clean gradient, brightest at the front.
        // The taps are anchored to the front, so each run is a steady gradient, not dashes.
        float Lr = Lz * win;
        vec3 hi = vec3(0.0), lo = vec3(0.0);
        float wh = 1e-4, wl = 1e-4;
        for (int i = 0; i < 8; ++i) {
            if (i >= n) break;
            float t = (float(i) + 0.5) / float(n);
            vec3 c = FROM(psUv(front + Lr * t, qs, vert, sg));
            float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
            l = l / (1.0 + l);
            float w1 = 0.02 + l * l * l;
            float w0 = 0.02 + (1.0 - l) * (1.0 - l) * (1.0 - l);
            hi += c * w1; wh += w1;
            lo += c * w0; wl += w0;
        }
        hi /= wh; lo /= wl;
        float g = clamp((s - front) / max(Lr, 1e-4), 0.0, 1.0);
        vec3 run = mix(hi * (1.0 + 0.25 * (1.0 - g) * (1.0 - g)), lo, smoothstep(0.0, 1.0, g));
        vec3 base = FROM(psUv(s, q, vert, sg));
        vec3 f = mix(base, run, sw * (1.0 - smoothstep(0.65, 1.0, g)));
        col += f * m;
        edgeC += hi * m;
    }
    if (m < 1.0) {
        // behind the front the incoming frame resolves out of its own sorted run
        float Lr = 0.6 * Lz * win;
        vec3 hi = vec3(0.0), lo = vec3(0.0);
        float wh = 1e-4, wl = 1e-4;
        for (int i = 0; i < 8; ++i) {
            if (i >= n) break;
            float t = (float(i) + 0.5) / float(n);
            vec3 c = TO(psUv(front - Lr * t, qs, vert, sg));
            float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
            l = l / (1.0 + l);
            float w1 = 0.02 + l * l * l;
            float w0 = 0.02 + (1.0 - l) * (1.0 - l) * (1.0 - l);
            hi += c * w1; wh += w1;
            lo += c * w0; wl += w0;
        }
        hi /= wh; lo /= wl;
        float g = clamp((front - s) / max(Lr, 1e-4), 0.0, 1.0);
        vec3 run = mix(hi * (1.0 + 0.25 * (1.0 - g) * (1.0 - g)), lo, smoothstep(0.0, 1.0, g));
        vec3 base = TO(psUv(s, q, vert, sg));
        float rs = (1.0 - g) * win;                        // a slight colour split as it resolves
        base.r = mix(base.r, TO(psUv(s + 0.012 * rs, q, vert, sg)).r, 0.6 * rs);
        vec3 tb = mix(base, run, sw * (1.0 - smoothstep(0.55, 1.0, g)));
        col += tb * (1.0 - m);
        edgeC += hi * (1.0 - m);
    }

    // glowing sort front: palette hue lit by the pixels it carries
    vec3 pc = suppressGreenCast(palVisual(0.15 + 0.7 * hg, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = vec3(mx + mn) - pc;
    float el = dot(edgeC, vec3(0.2126, 0.7152, 0.0722));
    float line = exp(-abs(s - front) / (2.5 * px)) * win;
    float tail = exp(-max(front - s, 0.0) / 0.05) * step(s, front) * win;
    vec3 hot = mix(pc, edgeC / max(el, 0.05) * 0.5, 0.35);
    col += hot * line * (0.9 + 0.8 * el / (1.0 + el)) * beat;
    col += mix(comp, pc, 0.5) * tail * 0.07 * beat;
    return col;
}
