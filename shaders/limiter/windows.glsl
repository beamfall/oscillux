// SPDX-License-Identifier: AGPL-3.0-only
// Pass 4, windows: one fragment per window origin (16 x 9). Sums the cols x rows cells from this
// origin for each of the cells pass's six counts and flags those over the area limit (more than
// limit pixels); an origin whose window would leave the grid flags nothing. Running the windows
// in parallel keeps the single-fragment grant pass short. Input uC; output oW = (over bits: luma
// up 1, luma down 2, red up 4, red down 8, luma either 16, red either 32, 0, 0, 0). The limit is
// an integer below 2^24, exact in a float; a window holds under 2^27 pixels.

void main() {
    ivec2 o = ivec2(gl_FragCoord.xy);
    int cols = int(lu.limiter0.x);
    int rows = int(lu.limiter0.y);
    uint limit = uint(lu.limiter0.z);
    uint bits = 0u;
    if (o.x + cols <= GRID_X && o.y + rows <= GRID_Y) {
        uvec4 s = uvec4(0u);
        uvec2 e = uvec2(0u);
        for (int y = o.y; y < o.y + rows; y++) {
            for (int x = o.x; x < o.x + cols; x++) {
                uvec4 c = LIM_U(uC, ivec2(x, y));
                uvec4 h = (uvec4(c.w) >> uvec4(0u, 4u, 8u, 12u)) & 15u;
                uvec2 he = (uvec2(c.w) >> uvec2(16u, 20u)) & 15u;
                s += uvec4(c.x & 65535u, c.x >> 16u, c.y & 65535u, c.y >> 16u) + (h << 16u);
                e += uvec2(c.z & 65535u, c.z >> 16u) + (he << 16u);
            }
        }
        uvec4 over = uvec4(greaterThan(s, uvec4(limit)));
        uvec2 overE = uvec2(greaterThan(e, uvec2(limit)));
        bits = over.x | (over.y << 1u) | (over.z << 2u) | (over.w << 3u) | (overE.x << 4u)
            | (overE.y << 5u);
    }
    oW = uvec4(bits, 0u, 0u, 0u);
}
