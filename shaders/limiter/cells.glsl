// SPDX-License-Identifier: AGPL-3.0-only
// Pass 3, cells: one fragment per cell (16 x 9). Per direction (luma up, luma down, red up, red
// down), counts the cell's 16 sub-blocks that request the transition now or made it within the
// coverage interval, and the requests alone. Inputs uS, uT2; output oC = count | requests << 5.

void main() {
    ivec2 cell = ivec2(gl_FragCoord.xy);
    int tick = int(lu.limiter1.x);
    float deltaMs = lu.limiter1.y;
    uvec4 count = uvec4(0u);
    uvec4 asks = uvec4(0u);
    for (int j = 0; j < SUB; j++) {
        for (int i = 0; i < SUB; i++) {
            ivec2 b = cell * SUB + ivec2(i, j);
            uint bits = LIM_U(uS, b).z;
            uvec4 rec = LIM_U(uT2, b);
            for (int d = 0; d < 4; d++) {
                uint q = (bits >> uint(d)) & 1u;
                asks[d] += q;
                if (q == 1u || limiterRecent(rec[d], tick, deltaMs) != 0u) count[d] += 1u;
            }
        }
    }
    oC = count | (asks << 5u);
}
