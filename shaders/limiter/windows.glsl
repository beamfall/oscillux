// SPDX-License-Identifier: AGPL-3.0-only
// Pass 4, windows: one fragment per window origin (16 x 9). Sums the cols x rows cells from this
// origin per direction and flags the directions over the area limit (more than limit
// sub-blocks); an origin whose window would leave the grid flags nothing. Running the windows
// in parallel keeps the single-fragment grant pass short. Input uC; output oW = (over bits: luma
// up 1, luma down 2, red up 4, red down 8, 0, 0, 0).

void main() {
    ivec2 o = ivec2(gl_FragCoord.xy);
    int cols = int(lu.limiter0.x);
    int rows = int(lu.limiter0.y);
    float limit = lu.limiter0.z;
    uint bits = 0u;
    if (o.x + cols <= GRID_X && o.y + rows <= GRID_Y) {
        uvec4 s = uvec4(0u);
        for (int y = o.y; y < o.y + rows; y++) {
            for (int x = o.x; x < o.x + cols; x++) s += LIM_U(uC, ivec2(x, y)) & 31u;
        }
        uvec4 over = uvec4(greaterThan(vec4(s), vec4(limit)));
        bits = over.x | (over.y << 1u) | (over.z << 2u) | (over.w << 3u);
    }
    oW = uvec4(bits, 0u, 0u, 0u);
}
