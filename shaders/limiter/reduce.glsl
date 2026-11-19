// SPDX-License-Identifier: AGPL-3.0-only
// Pass 2, reduce: one fragment per sub-block (64 x 36). Sums the rows pass's counts over the
// sub-block's rows [floor(j H / 36), floor((j + 1) H / 36)) and ORs its directions firing now:
// the sub-block requests each direction one of its pixels fires in. Input uRows (RGBA32UI, 64 x
// frame height); output oS (RGBA32UI) in the rows pass's layout. A sub-block holds under 65536
// pixels for any frame up to 8192 x 4320 (128 x 120 pixels a sub-block), so each count fits 16
// bits.

void main() {
    ivec2 b = ivec2(gl_FragCoord.xy);
    int height = LIM_USIZE(uRows).y;
    int y0 = b.y * height / BLOCKS_Y;
    int y1 = (b.y + 1) * height / BLOCKS_Y;
    uvec4 area = uvec4(0u);
    uint bits = 0u;
    for (int y = y0; y < y1; y++) {
        uvec4 r = LIM_U(uRows, ivec2(b.x, y));
        area += uvec4(r.x & 65535u, r.x >> 16u, r.y & 65535u, r.y >> 16u);
        bits |= r.z;
    }
    oS = uvec4(area.x | (area.y << 16u), area.z | (area.w << 16u), bits, 0u);
}
