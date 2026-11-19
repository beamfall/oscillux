// SPDX-License-Identifier: AGPL-3.0-only
// Pass 3, cells: one fragment per cell (16 x 9). Sums the counts of the cell's 16 sub-blocks for
// luma up, luma down, red up, red down, luma either and red either, and notes which directions
// any of them requests. A cell holds under 2^20 pixels for any supported frame (512 x 911), so
// each count takes its low 16 bits in x, y or z and its high 4 bits in w. Input uS (RGBA32UI);
// output oC (RGBA32UI) = (luma up | luma down << 16, red up | red down << 16, luma either | red
// either << 16, high nibbles of the six counts in that order (bits 0-23) | requests << 24).

void main() {
    ivec2 cell = ivec2(gl_FragCoord.xy);
    uvec4 count = uvec4(0u);
    uvec2 either = uvec2(0u);
    uint asks = 0u;
    for (int j = 0; j < SUB; j++) {
        for (int i = 0; i < SUB; i++) {
            uvec4 s = LIM_U(uS, cell * SUB + ivec2(i, j));
            count += uvec4(s.x & 65535u, s.x >> 16u, s.y & 65535u, s.y >> 16u);
            either += uvec2(s.w & 65535u, s.w >> 16u);
            asks |= s.z;
        }
    }
    uint high = (count.x >> 16u) | ((count.y >> 16u) << 4u) | ((count.z >> 16u) << 8u)
        | ((count.w >> 16u) << 12u) | ((either.x >> 16u) << 16u) | ((either.y >> 16u) << 20u);
    oC = uvec4((count.x & 65535u) | (count.y << 16u), (count.z & 65535u) | (count.w << 16u),
        (either.x & 65535u) | (either.y << 16u), high | ((asks & 15u) << 24u));
}
