// SPDX-License-Identifier: AGPL-3.0-only
// Pass 7, output: one fragment per pixel. A pixel of a held sub-block shows the previous output
// frame. A pixel of a sub-block that is not held blends toward the previous output frame by the
// largest weight (0..15, in sixteenths) of its sub-block's eight neighbours that are held, so a
// hold has no hard edge; a pixel whose input, history or blend is red-dominant (r > g + b in
// 8-bit) shows the input, so red is never blended. Inputs uFrame (RGBA8), uHist (the previous
// output, RGBA8), uT1 (this frame's state); output oColor (RGBA8, alpha 1), which is next frame's
// uHist.

int heldAt(ivec2 b) {
    if (b.x < 0 || b.y < 0 || b.x >= BLOCKS_X || b.y >= BLOCKS_Y) return 0;
    return LIM_U(uT1, b).w != 0u ? 1 : 0;
}

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    ivec2 size = LIM_SIZE(uFrame);
    ivec2 n = ivec2(BLOCKS_X, BLOCKS_Y);
    ivec2 b = (n * (p + 1) - 1) / size;
    vec3 frame = LIM_F(uFrame, p).rgb;
    vec3 hist = LIM_F(uHist, p).rgb;
    if (heldAt(b) != 0) {
        oColor = vec4(hist, 1.0);
        return;
    }
    oColor = vec4(frame, 1.0);
    ivec3 a = ivec3(frame * 255.0 + 0.5);
    ivec3 h = ivec3(hist * 255.0 + 0.5);
    if (a.r > a.g + a.b || h.r > h.g + h.b) return;
    ivec2 lo = b * size / n;
    ivec2 hi = (b + 1) * size / n;
    ivec2 f = 16 * (p - lo) / (hi - lo);
    int wl = 15 - f.x, wr = f.x, wu = 15 - f.y, wd = f.y;
    int w = max(max(heldAt(b + ivec2(-1, 0)) * wl, heldAt(b + ivec2(1, 0)) * wr),
                max(heldAt(b + ivec2(0, -1)) * wu, heldAt(b + ivec2(0, 1)) * wd));
    w = max(w, max(max(heldAt(b + ivec2(-1, -1)) * ((wl * wu) >> 4), heldAt(b + ivec2(1, -1)) * ((wr * wu) >> 4)),
                   max(heldAt(b + ivec2(-1, 1)) * ((wl * wd) >> 4), heldAt(b + ivec2(1, 1)) * ((wr * wd) >> 4))));
    if (w == 0) return;
    ivec3 o = (a * (16 - w) + h * w + 8) >> 4;
    if (o.r > o.g + o.b) return;
    oColor = vec4(vec3(o) / 255.0, 1.0);
}
