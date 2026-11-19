// SPDX-License-Identifier: AGPL-3.0-only
// Pass 1, rows: one fragment per sub-block column and frame row (64 x frame height). Over the
// row's pixels inside the sub-block column [floor(i W / 64), floor((i + 1) W / 64)), counts the
// pixels whose tracker this frame would fire in any direction or that fired in any direction within
// the coverage interval, and ORs the directions firing now, so the reduce pass can finish the
// sub-block over few texels. One count across channels and directions: pixels rising, falling,
// changing luminance and changing red at once flash together, and per-channel counts let two
// adjacent patches each stay under the limit while their union is over it (Codex rounds 12, 13).
// Inputs uFrame (RGBA8), uTrack (RGBA16UI, the tracker state after the previous frame); output
// oR (RGBA32UI) = (count, directions firing now, 0, 0).

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    int width = LIM_SIZE(uFrame).x;
    int x0 = p.x * width / BLOCKS_X;
    int x1 = (p.x + 1) * width / BLOCKS_X;
    int unit = int(lu.limiter1.x) >> 4;
    float deltaMs = lu.limiter1.y;
    uint count = 0u;
    uint bits = 0u;
    for (int x = x0; x < x1; x++) {
        ivec2 q = ivec2(x, p.y);
        uvec4 t = LIM_U(uTrack, q);
        uint now = limiterFires(t, limiterBytes(LIM_F(uFrame, q).rgb));
        bits |= now;
        bool hit = now != 0u;
        for (int d = 0; d < 4; d++) hit = hit || limiterRecent((t.w >> uint(4 * d)) & 15u, unit, deltaMs);
        count += hit ? 1u : 0u;
    }
    oR = uvec4(count, bits, 0u, 0u);
}
