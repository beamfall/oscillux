// SPDX-License-Identifier: AGPL-3.0-only
// Pass 7, output: one fragment per pixel. A pixel of a held sub-block shows the previous output
// frame; every other pixel shows the input exactly, so the output makes only the transitions the
// trackers counted. (Until v0.2.9 the pixels around a hold blended toward the previous output; a
// blended change appeared after the token it spent had refilled, so the output could make seven
// luma transitions in 1 s: CORE-2543, CORE-2541.) Inputs uFrame (RGBA8), uHist (the previous
// output, RGBA8), uT1 (this frame's state); output oColor (RGBA8, alpha 1), which is next frame's
// uHist.

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    ivec2 size = LIM_SIZE(uFrame);
    ivec2 b = (ivec2(BLOCKS_X, BLOCKS_Y) * (p + 1) - 1) / size;
    bool held = (LIM_U(uT1, b).w & 1u) != 0u;
    oColor = vec4((held ? LIM_F(uHist, p) : LIM_F(uFrame, p)).rgb, 1.0);
}
