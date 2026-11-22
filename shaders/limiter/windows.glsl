// SPDX-License-Identifier: AGPL-3.0-only
// Pass 4, windows: one fragment per cell origin (16 x 9). With a sub-block window (lu.limiter1.zw
// nonzero) it passes on the cells pass's flag for the window origins at this cell's sub-blocks.
// Otherwise it sums the cells pass's counts over the cols x rows cells from this origin and flags
// a sum over the area limit (more than limit pixels); an origin whose window would leave the grid
// flags nothing. Running the windows in parallel keeps the single-fragment grant pass short. Input
// uC; output oW = (over, 0, 0, 0). The limit is an integer below 2^24, exact in a float; a window
// holds under 2^27 pixels.

void main() {
    ivec2 o = ivec2(gl_FragCoord.xy);
    int cols = int(lu.limiter0.x);
    int rows = int(lu.limiter0.y);
    uint limit = uint(lu.limiter0.z);
    uint over = 0u;
    if (lu.limiter1.z > 0.0 && lu.limiter1.w > 0.0) {
        over = LIM_U(uC, o).z;
    } else if (o.x + cols <= GRID_X && o.y + rows <= GRID_Y) {
        uint sum = 0u;
        for (int y = o.y; y < o.y + rows; y++) {
            for (int x = o.x; x < o.x + cols; x++) sum += LIM_U(uC, ivec2(x, y)).x;
        }
        over = sum > limit ? 1u : 0u;
    }
    oW = uvec4(over, 0u, 0u, 0u);
}
