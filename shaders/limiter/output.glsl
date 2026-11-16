// SPDX-License-Identifier: AGPL-3.0-only
// Pass 7, output: one fragment per pixel. A pixel of a held sub-block shows the previous output
// frame, every other pixel the input. Inputs uFrame (RGBA8), uHist (the previous output, RGBA8),
// uT1 (this frame's state); output oColor (RGBA8, alpha 1), which is next frame's uHist.

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    ivec2 b = (ivec2(BLOCKS_X, BLOCKS_Y) * (p + 1) - 1) / LIM_SIZE(uFrame);
    bool held = LIM_U(uT1, b).w != 0u;
    oColor = vec4(held ? LIM_F(uHist, p).rgb : LIM_F(uFrame, p).rgb, 1.0);
}
