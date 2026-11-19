// SPDX-License-Identifier: AGPL-3.0-only
// Shared by the frame flash limiter passes (README.md). The decisions are integer arithmetic on
// 16-bit codes and match tools/shader/limiter-model.mjs bit for bit. The wrapper
// (tools/shader/limiter.mjs) declares the LimiterBlock `lu`, the pass's textures and outputs,
// LIM_F(tex, px) / LIM_U(tex, px) (texel fetch of a float or uint texture) and LIM_SIZE(tex) /
// LIM_USIZE(tex) (the size of a float or uint texture), and LIMITER_LUT in the passes that
// include luma-lut.glsl (rows, output), which measure pixels.
//   lu.limiter0 = (window columns, window rows, area limit in pixels, token refill)
//   lu.limiter1 = (tick in [0, 240), frame interval in ms, 0, 0)
// Tracker state, one RGBA16UI texel per pixel (uTrack, oTrack): x, y luma lo, hi; z red lo |
// hi << 8; w four 4-bit recency stamps (luma up, luma down << 4, red up << 8, red down << 12),
// 0 absent, else the event's unit (tick >> 4) + 1. After a rise lo is the maximum code and hi
// the reference; after a fall hi is 0 and lo the reference; lo <= hi is no direction. (65535, 0)
// in x, y marks a pixel with no state yet; hosts clear the texture to (65535, 0, 255, 0).

const int BLOCKS_X = 64;
const int BLOCKS_Y = 36;
const int GRID_X = 16;
const int GRID_Y = 9;
const int SUB = 4;
const int LUMA_STEP = 6553;  // 0.1 relative luminance
const int LUMA_DARK = 52429; // 0.8: the darker side of a luminance transition is below this
const int LUMA_MAX = 65535;
const int RED_STEP = 16;     // 20 on WCAG's 320 max(0, R - G - B) scale
const int NO_DARK = 256;
const int RED_MAX = 255;
const uint TOKEN = 65025u;
const float COVERAGE_MS = 66.66666666666667; // 1000 / 15

#ifdef LIMITER_LUT
// A pixel's luma code from its 8-bit display values.
int limiterLuma(ivec3 c) {
    return min(LUMA_MAX, LUMA_LUT[c.r].x + LUMA_LUT[c.g].y + LUMA_LUT[c.b].z);
}

// A pixel's red code: (R - G - B) >> 8 of the linear channel codes when saturated red
// (5 R >= 4 (R + G + B) and R > G + B), else 0.
int limiterRed(ivec3 c) {
    int r = LUMA_LUT[c.r].w;
    int g = LUMA_LUT[c.g].w;
    int b = LUMA_LUT[c.b].w;
    return 5 * r >= 4 * (r + g + b) && r > g + b ? (r - g - b) >> 8 : 0;
}

// The audit counter's step on a packed tracker (lo, hi) for value v: returns (lo', hi', fired),
// fired 1 rising, -1 falling, 0 none.
ivec3 limiterTrackStep(int lo, int hi, int v, int stepSize, int dark, int maxCode) {
    int dir = 0;
    if (lo > hi) {
        if (lo == maxCode) {
            dir = 1;
            lo = hi;
        } else {
            dir = -1;
            hi = lo;
        }
    }
    lo = min(lo, v);
    hi = max(hi, v);
    if (dir <= 0 && v - lo >= stepSize && lo < dark) return ivec3(maxCode, v, 1);
    if (dir >= 0 && hi - v >= stepSize && v < dark) return ivec3(v, 0, -1);
    return ivec3(dir > 0 ? maxCode : lo, dir < 0 ? 0 : hi, 0);
}

bool limiterUntracked(uvec4 t) {
    return t.x == uint(LUMA_MAX) && t.y == 0u;
}

// The directions (luma up 1, luma down 2, red up 4, red down 8) tracker t fires in on the pixel
// with display values c; none for a pixel with no state yet.
uint limiterFires(uvec4 t, ivec3 c) {
    if (limiterUntracked(t)) return 0u;
    int fl = limiterTrackStep(int(t.x), int(t.y), limiterLuma(c), LUMA_STEP, LUMA_DARK, LUMA_MAX).z;
    int fr = limiterTrackStep(int(t.z & 255u), int(t.z >> 8u), limiterRed(c), RED_STEP, NO_DARK, RED_MAX).z;
    return (fl > 0 ? 1u : 0u) | (fl < 0 ? 2u : 0u) | (fr > 0 ? 4u : 0u) | (fr < 0 ? 8u : 0u);
}
#endif

// Whether a 4-bit stamp is inside the coverage interval at `unit`: the frame interval is inside
// it and the stamp at most 4 units (of 15, modulo) old.
bool limiterRecent(uint s, int unit, float deltaMs) {
    return s > 0u && deltaMs <= COVERAGE_MS && (unit - (int(s) - 1) + 15) % 15 <= 4;
}

ivec3 limiterBytes(vec3 c) {
    return ivec3(round(c * 255.0));
}
