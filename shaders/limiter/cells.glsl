// SPDX-License-Identifier: AGPL-3.0-only
// Pass 3, cells: one fragment per cell (16 x 9). Sums the counts of the cell's 16 sub-blocks and
// notes which directions any of them requests. With a sub-block window (lu.limiter1.zw, columns x
// rows of sub-blocks), it also flags whether any of the window origins at its 4 x 4 sub-blocks
// holds more than limit pixels; an origin whose window would leave the grid flags nothing. Each
// column's sums for the 4 origin rows are streamed into the 16 origins' sums, so a fragment reads
// at most (cols + 3) x (rows + 3) sub-blocks. Input uS (RGBA32UI); output oC (RGBA32UI) = (count,
// requests, over, 0). A window holds under 2^27 pixels.

void main() {
    ivec2 cell = ivec2(gl_FragCoord.xy);
    ivec2 b0 = cell * SUB;
    uint count = 0u;
    uint asks = 0u;
    for (int j = 0; j < SUB; j++) {
        for (int i = 0; i < SUB; i++) {
            uvec4 s = LIM_U(uS, b0 + ivec2(i, j));
            count += s.x;
            asks |= s.y;
        }
    }
    int bc = int(lu.limiter1.z);
    int br = int(lu.limiter1.w);
    uint over = 0u;
    if (bc > 0 && br > 0) {
        uint limit = uint(lu.limiter0.z);
        uint win[16];
        for (int k = 0; k < 16; k++) win[k] = 0u;
        int x1 = min(b0.x + SUB - 1 + bc, BLOCKS_X);
        int y1 = min(b0.y + SUB - 1 + br, BLOCKS_Y);
        for (int x = b0.x; x < x1; x++) {
            uint col0 = 0u, col1 = 0u, col2 = 0u, col3 = 0u;
            for (int y = b0.y; y < y1; y++) {
                uint v = LIM_U(uS, ivec2(x, y)).x;
                int d = y - b0.y;
                if (d < br) col0 += v;
                if (d >= 1 && d < 1 + br) col1 += v;
                if (d >= 2 && d < 2 + br) col2 += v;
                if (d >= 3 && d < 3 + br) col3 += v;
            }
            for (int i = 0; i < SUB; i++) {
                int e = x - b0.x - i;
                if (e >= 0 && e < bc) {
                    win[i] += col0;
                    win[4 + i] += col1;
                    win[8 + i] += col2;
                    win[12 + i] += col3;
                }
            }
        }
        for (int j = 0; j < SUB; j++) {
            for (int i = 0; i < SUB; i++) {
                if (b0.x + i + bc <= BLOCKS_X && b0.y + j + br <= BLOCKS_Y && win[4 * j + i] > limit) over = 1u;
            }
        }
    }
    oC = uvec4(count, asks & 255u, over, 0u);
}
