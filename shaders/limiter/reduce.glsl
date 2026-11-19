// SPDX-License-Identifier: AGPL-3.0-only
// Pass 2, reduce: one fragment per sub-block (64 x 36). Sums the rows pass's counts over the
// sub-block's rows [floor(j H / 36), floor((j + 1) H / 36)) and ORs its directions firing now:
// the sub-block requests each direction one of its pixels fires in. Input uRows (RGBA32UI, 64 x
// frame height); output oS (RGBA32UI) in the rows pass's layout.

void main() {
    ivec2 b = ivec2(gl_FragCoord.xy);
    int height = LIM_USIZE(uRows).y;
    int y0 = b.y * height / BLOCKS_Y;
    int y1 = (b.y + 1) * height / BLOCKS_Y;
    uint count = 0u;
    uint bits = 0u;
    for (int y = y0; y < y1; y++) {
        uvec4 r = LIM_U(uRows, ivec2(b.x, y));
        count += r.x;
        bits |= r.y;
    }
    oS = uvec4(count, bits, 0u, 0u);
}
