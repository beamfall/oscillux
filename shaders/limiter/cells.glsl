// SPDX-License-Identifier: AGPL-3.0-only
// Pass 3, cells: one fragment per cell (16 x 9). Per direction (luma up, luma down, red up, red
// down), sums the counts of the cell's 16 sub-blocks and notes whether any of them requests the
// direction. Input uS (RGBA32UI); output oC (RGBA32UI) = count | request << 31 per direction.

void main() {
    ivec2 cell = ivec2(gl_FragCoord.xy);
    uvec4 count = uvec4(0u);
    uint asks = 0u;
    for (int j = 0; j < SUB; j++) {
        for (int i = 0; i < SUB; i++) {
            uvec4 s = LIM_U(uS, cell * SUB + ivec2(i, j));
            count += uvec4(s.x & 65535u, s.x >> 16u, s.y & 65535u, s.y >> 16u);
            asks |= s.z;
        }
    }
    oC = count | (((uvec4(asks) >> uvec4(0u, 1u, 2u, 3u)) & 1u) << 31u);
}
