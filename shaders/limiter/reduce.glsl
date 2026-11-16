// SPDX-License-Identifier: AGPL-3.0-only
// Pass 2, reduce: one fragment per sub-block (64 x 36). Finishes the box reduction of the
// sub-block's footprint (every pixel counts once) from the rows pass's partial sums to a luma and
// a red code, and tests the trackers for the transitions this frame would make. Inputs uRows
// (RGBA32UI, 64 x frame height), uT0, uT1; output oS = (luma code, red code, request bits: luma
// up 1, luma down 2, red up 4, red down 8, 0).

void main() {
    ivec2 b = ivec2(gl_FragCoord.xy);
    int height = LIM_USIZE(uRows).y;
    int y0 = b.y * height / BLOCKS_Y;
    int y1 = (b.y + 1) * height / BLOCKS_Y;
    uint sy = 0u;
    uint sr = 0u;
    uint n = 0u;
    for (int y = y0; y < y1; y++) {
        uvec4 r = LIM_U(uRows, ivec2(b.x, y));
        sy += r.x;
        sr += r.y;
        n += r.z;
    }
    int luma = int(min(65535u, (sy + n / 2u) / n));
    int red = int(min(65535u, (sr + n / 2u) / n));
    uvec4 t0 = LIM_U(uT0, b);
    uvec4 t1 = LIM_U(uT1, b);
    uint bits = 0u;
    if (t1.z != 0u) {
        int fl = limiterTrackStep(ivec3(t0.xy, int(t1.x) - 1), luma, LUMA_STEP, LUMA_DARK).w;
        int fr = limiterTrackStep(ivec3(t0.zw, int(t1.y) - 1), red, RED_STEP, NO_DARK).w;
        bits = (fl > 0 ? 1u : 0u) | (fl < 0 ? 2u : 0u) | (fr > 0 ? 4u : 0u) | (fr < 0 ? 8u : 0u);
    }
    oS = uvec4(uint(luma), uint(red), bits, 0u);
}
