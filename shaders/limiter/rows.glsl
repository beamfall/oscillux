// SPDX-License-Identifier: AGPL-3.0-only
// Pass 1, rows: one fragment per sub-block column and frame row (64 x frame height). Over the
// row's pixels inside the sub-block column [floor(i W / 64), floor((i + 1) W / 64)), counts the
// pixels whose tracker this frame would fire in any direction or that fired in any direction within
// the coverage interval, and ORs the directions firing now, so the reduce pass can finish the
// sub-block over few texels, and the directions with a recent stamp in bits 4..7: a channel that
// changed recently is part of the area, so it is charged with the frame (Codex round 14). One
// count across channels and directions: pixels rising, falling, changing luminance and changing
// red at once flash together, and per-channel counts let two adjacent patches each stay under the
// limit while their union is over it (Codex rounds 12, 13).
// Inputs uFrame (RGBA8), uTrack (RGBA32UI, the tracker state after the previous frame), uHist (the
// previous output, RGBA8: the chromaticity step fires only on a changed colour); output
// oR (RGBA32UI) = (count, directions firing now | recent directions << 4, 0, 0).

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
        uint now = limiterFires(t, limiterBytes(LIM_F(uFrame, q).rgb), limiterBytes(LIM_F(uHist, q).rgb));
        bits |= now;
        uint recent = 0u;
        for (int d = 0; d < 4; d++) recent |= limiterRecent((t.w >> uint(4 * d)) & 15u, unit, deltaMs) ? 1u << uint(d) : 0u;
        bits |= recent << 4u;
        count += now != 0u || recent != 0u ? 1u : 0u;
    }
    oR = uvec4(count, bits, 0u, 0u);
}
