// SPDX-License-Identifier: AGPL-3.0-only
// Pass 1, rows: one fragment per sub-block column and frame row (64 x frame height). Over the
// row's pixels inside the sub-block column [floor(i W / 64), floor((i + 1) W / 64)), counts per
// direction the pixels whose tracker this frame would fire in that direction or that fired in it
// within the coverage interval, and ORs the directions firing now, so the reduce pass can finish
// the sub-block over few texels. Inputs uFrame (RGBA8), uTrack (RGBA16UI, the tracker state
// after the previous frame); output oR (RGBA32UI) = (luma up | luma down << 16, red up | red
// down << 16, directions firing now, luma either | red either << 16). The "either" counts take a
// pixel once when it counts in either direction of the channel, since pixels rising and pixels
// falling at once flash together (Codex round 12). A row segment is under 65536 pixels, so each
// count fits 16 bits.

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    int width = LIM_SIZE(uFrame).x;
    int x0 = p.x * width / BLOCKS_X;
    int x1 = (p.x + 1) * width / BLOCKS_X;
    int unit = int(lu.limiter1.x) >> 4;
    float deltaMs = lu.limiter1.y;
    uvec4 area = uvec4(0u);
    uint bits = 0u;
    uint either = 0u;
    for (int x = x0; x < x1; x++) {
        ivec2 q = ivec2(x, p.y);
        uvec4 t = LIM_U(uTrack, q);
        uint now = limiterFires(t, limiterBytes(LIM_F(uFrame, q).rgb));
        bits |= now;
        uint hit = 0u;
        for (int d = 0; d < 4; d++) {
            if (((now >> uint(d)) & 1u) != 0u || limiterRecent((t.w >> uint(4 * d)) & 15u, unit, deltaMs)) {
                area[d] += 1u;
                hit |= 1u << uint(d);
            }
        }
        either += ((hit & 3u) != 0u ? 1u : 0u) + ((hit & 12u) != 0u ? 65536u : 0u);
    }
    oR = uvec4(area.x | (area.y << 16u), area.z | (area.w << 16u), bits, either);
}
