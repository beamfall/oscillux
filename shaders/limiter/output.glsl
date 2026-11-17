// SPDX-License-Identifier: AGPL-3.0-only
// Pass 7, output: one fragment per pixel. A pixel of a held sub-block shows the previous output
// frame. Every other pixel blends toward the previous output frame by a weight that is continuous
// across sub-block boundaries and falls off round, so a hold has no visible edge: the hold field
// the state pass wrote (0..64 at each sub-block centre) is interpolated bilinearly between the
// four nearest centres (in 64ths per axis), scaled to t in 0..4096 and eased,
// w = ((t^2 >> 12) (12288 - 2 t)) >> 12. A pixel whose input, history or blend is red-dominant
// (r > g + b in 8-bit) shows the input, so red is never blended. Inputs uFrame (RGBA8), uHist (the
// previous output, RGBA8), uT1 (this frame's state); output oColor (RGBA8, alpha 1), which is next
// frame's uHist.

int fieldAt(ivec2 b) {
    if (b.x >= BLOCKS_X || b.y >= BLOCKS_Y) return 0;
    return int(LIM_U(uT1, b).w >> 1u);
}

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    ivec2 size = LIM_SIZE(uFrame);
    ivec2 n = ivec2(BLOCKS_X, BLOCKS_Y);
    ivec2 b = (n * (p + 1) - 1) / size;
    vec3 frame = LIM_F(uFrame, p).rgb;
    vec3 hist = LIM_F(uHist, p).rgb;
    if ((LIM_U(uT1, b).w & 1u) != 0u) {
        oColor = vec4(hist, 1.0);
        return;
    }
    oColor = vec4(frame, 1.0);
    ivec3 a = ivec3(frame * 255.0 + 0.5);
    ivec3 h = ivec3(hist * 255.0 + 0.5);
    if (a.r > a.g + a.b || h.r > h.g + h.b) return;
    // l: the first of the two sub-blocks, per axis, whose centres the pixel lies between; f: the
    // second's weight in 64ths. Centres are doubled so they stay integers. Before the first centre
    // and after the last the pixel takes its own sub-block alone.
    ivec2 at = 2 * p + 1;
    ivec2 l = b - ivec2(lessThan(at, b * size / n + (b + 1) * size / n));
    ivec2 cl = l * size / n + (l + 1) * size / n;
    ivec2 cr = (l + 1) * size / n + (l + 2) * size / n;
    ivec2 f = 64 * (at - cl) / (cr - cl);
    if (l.x < 0 || l.x + 1 >= n.x) { l.x = b.x; f.x = 0; }
    if (l.y < 0 || l.y + 1 >= n.y) { l.y = b.y; f.y = 0; }
    int t = ((fieldAt(l) * (64 - f.x) + fieldAt(l + ivec2(1, 0)) * f.x) * (64 - f.y)
        + (fieldAt(l + ivec2(0, 1)) * (64 - f.x) + fieldAt(l + ivec2(1, 1)) * f.x) * f.y) >> 6;
    if (t == 0) return;
    int w = (((t * t) >> 12) * (12288 - 2 * t)) >> 12;
    ivec3 o = (a * (4096 - w) + h * w + 2048) >> 12;
    if (o.r > o.g + o.b) return;
    oColor = vec4(vec3(o) / 255.0, 1.0);
}
