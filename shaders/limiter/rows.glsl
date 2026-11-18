// SPDX-License-Identifier: AGPL-3.0-only
// Pass 1, rows: one fragment per sub-block column and frame row (64 x frame height). Sums the
// row's pixels inside the sub-block column [floor(i W / 64), floor((i + 1) W / 64)) so the
// reduce pass can finish the box sum over few texels. The split keeps the GPU busy (a fragment
// per sub-block alone would loop over every pixel of the sub-block); the sums are exact integers,
// so the result is the one-pass box sum. Inputs uFrame (RGBA8) and uHist (the previous output,
// RGBA8); output oR (RGBA32UI) = (sum of luma codes, sum of red excess, pixel count, pixels whose
// luma rose by LUMA_STEP against uHist | pixels whose luma fell by it << 16), the darker side
// below LUMA_DARK. A row segment is under 65536 pixels, so the counts fit 16 bits. Saturation (5 R >= 4 (R + G + B)) and
// red excess (R - G - B) are tested on the linear channel codes LUMA_LUT[k].w, as WCAG defines
// them on linear light; a sub-block of up to 65535 pixels cannot overflow the 32-bit sums.

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    int width = LIM_SIZE(uFrame).x;
    int x0 = p.x * width / BLOCKS_X;
    int x1 = (p.x + 1) * width / BLOCKS_X;
    uint sy = 0u;
    uint sr = 0u;
    uint up = 0u;
    uint down = 0u;
    for (int x = x0; x < x1; x++) {
        ivec3 c = ivec3(round(LIM_F(uFrame, ivec2(x, p.y)).rgb * 255.0));
        int v = LUMA_LUT[c.r].x + LUMA_LUT[c.g].y + LUMA_LUT[c.b].z;
        sy += uint(v);
        ivec3 hc = ivec3(round(LIM_F(uHist, ivec2(x, p.y)).rgb * 255.0));
        int h = LUMA_LUT[hc.r].x + LUMA_LUT[hc.g].y + LUMA_LUT[hc.b].z;
        if (v - h >= LUMA_STEP && h < LUMA_DARK) up++;
        if (h - v >= LUMA_STEP && v < LUMA_DARK) down++;
        ivec3 l = ivec3(LUMA_LUT[c.r].w, LUMA_LUT[c.g].w, LUMA_LUT[c.b].w);
        int s = l.r + l.g + l.b;
        if (s > 0 && 5 * l.r >= 4 * s && l.r > l.g + l.b) sr += uint(l.r - l.g - l.b);
    }
    oR = uvec4(sy, sr, uint(x1 - x0), up | (down << 16u));
}
