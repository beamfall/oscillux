// SPDX-License-Identifier: AGPL-3.0-only
// Shared by the frame flash limiter passes (README.md). The decisions are integer arithmetic on
// integer codes and match tools/shader/limiter-model.mjs bit for bit. The wrapper
// (tools/shader/limiter.mjs) declares the LimiterBlock `lu`, the pass's textures and outputs,
// LIM_F(tex, px) / LIM_U(tex, px) (texel fetch of a float or uint texture) and LIM_SIZE(tex) /
// LIM_USIZE(tex) (the size of a float or uint texture), and LIMITER_LUT in the passes that
// include luma-lut.glsl (rows, output), which measure pixels.
//   lu.limiter0 = (window columns, window rows, area limit in pixels, token refill)
//   lu.limiter1 = (tick in [0, 240), frame interval in ms, 0, 0)
// Tracker state, one RGBA16UI texel per pixel (uTrack, oTrack). Each measure's tracker has a
// direction (the way it last fired), its extreme since then (the peak when rising, the trough when
// falling) and its reference (the level at its last transition), stored as the extreme and the
// reference's distance from it, which stays under the step. x: luma extreme (15 bits), bit 15 set
// while the red tracker's latest change has not counted; y: luma distance (12 bits), bit 12 rising,
// bit 13 no state yet (the reference model's start), bit 15 a saturated red state seen since the red
// tracker's latest change; z: red extreme (8 bits), red distance << 8 (4 bits), bit 12 rising; w four
// 4-bit recency stamps (luma up, luma down << 4, red up << 8, red down << 12), 0 absent, else the
// event's unit (tick >> 4) + 1. The zero texel is tracked black: falling at 0 with every change
// counted. Hosts start the texture at zero (README.md, "Ping-pong and reset").

const int BLOCKS_X = 64;
const int BLOCKS_Y = 36;
const int GRID_X = 16;
const int GRID_Y = 9;
const int SUB = 4;
// Luma and red are measured in integer codes, and the codes are the measure: the auditor and the
// limiter both use them. A luma code is 0.74 above to 1.24 below 32767.5 Y and a red code 0.006
// above to 1.002 below WCAG's quantity in 256ths (every 8-bit colour, README.md, "Flash measure"),
// so the steps are the thresholds less those errors: every WCAG transition fires.
const int LUMA_STEP = 3275;  // 0.1 relative luminance (3276.75 of 32767.5, less 1.98)
const int LUMA_DARK = 26215; // 0.8 (26214, plus 0.74): the darker side is below this
// Luma codes are 15-bit so bit 15 of the luma words carries the red tracker's counted and
// saturated bits.
const int LUMA_MAX = 32767;
const uint LUMA_MASK = 32767u;
const uint PEND_BIT = 32768u;  // x: the red tracker's latest change has not counted
const uint LUMA_UP = 4096u;    // y: the luma tracker last fired rising
const uint UNTRACKED = 8192u;  // y: no state yet
const uint SAT_BIT = 32768u;   // y: a saturated red state seen since the red tracker's latest change
const uint RED_UP = 4096u;     // z: the red tracker last fired rising
const int RED_STEP = 15;     // 20 on WCAG's 320 max(0, R - G - B) scale (16 of 256, less 1.01)
const int NO_DARK = 256;
const int RED_MAX = 255;
const uint TOKEN = 65025u;
const float COVERAGE_MS = 66.66666666666667; // 1000 / 15

// Whether a 4-bit stamp is inside the coverage interval at `unit`: the frame interval is inside
// it and the stamp at most 5 units (of 15, modulo) old. A unit is 16 ticks of 1000/15/64 ms,
// 16.67 ms, so the 66.7 ms interval spans 4 units and reaches into a fifth: an event 5 units
// before the current one can be under 66.7 ms old.
bool limiterRecent(uint s, int unit, float deltaMs) {
    return s > 0u && deltaMs <= COVERAGE_MS && (unit - (int(s) - 1) + 15) % 15 <= 5;
}

// The audit counter's step on a tracker (extreme, distance, rising) for value v: returns
// (extreme', distance', rising', change), change 1 rising, -1 falling, 0 none. A change of at least
// stepSize whose darker side is below dark is a transition: against the direction from the extreme
// (a reversal), or onward from the reference, the level at the previous transition. So a rise, a
// pause and a further rise of a step are two transitions: a large area can reach a step in one
// frame after its pixels started rising at different times (Codex round 16).
ivec4 limiterTrackStep(int ext, int dist, int up, int v, int stepSize, int dark) {
    if (up != 0) {
        if (ext - v >= stepSize && v < dark) return ivec4(v, 0, 0, -1);
        int ref = ext - dist;
        ext = max(ext, v);
        if (ext - ref < stepSize) return ivec4(ext, ext - ref, 1, 0);
        return ivec4(ext, 0, 1, ref < dark ? 1 : 0);
    }
    if (v - ext >= stepSize && ext < dark) return ivec4(v, 0, 1, 1);
    int ref = ext + dist;
    ext = min(ext, v);
    if (ref - ext < stepSize) return ivec4(ext, ref - ext, 0, 0);
    return ivec4(ext, 0, 0, ext < dark ? -1 : 0);
}

// The luma tracker's step on tracker t for luma code v.
ivec4 limiterLumaStep(uvec4 t, int v) {
    return limiterTrackStep(int(t.x & LUMA_MASK), int(t.y & 4095u), (t.y & LUMA_UP) != 0u ? 1 : 0, v, LUMA_STEP, LUMA_DARK);
}

// The red tracker's step on tracker t for red code rv and saturation sat: returns (z', count,
// counted', seen'), count 1 rising, -1 falling, 0 none. A change counts as a red transition when the
// new state or one since the previous change is saturated; one that did not count then counts at the
// first saturated state before the next change, so a change through an unsaturated state to
// saturated red is not lost. Direction changes never wait for saturation: a gated direction let an
// unsaturated reversal hide the transition after it (Codex round 13).
ivec4 limiterRedStep(uvec4 t, int rv, bool sat) {
    ivec4 s = limiterTrackStep(int(t.z & 255u), int((t.z >> 8u) & 15u), (t.z & RED_UP) != 0u ? 1 : 0, rv, RED_STEP, NO_DARK);
    bool counted = (t.x & PEND_BIT) == 0u;
    bool seen = (t.y & SAT_BIT) != 0u;
    int count = 0;
    if (s.w != 0) {
        counted = sat || seen;
        count = counted ? s.w : 0;
        seen = sat;
    } else {
        if (!counted && sat) {
            count = s.z != 0 ? 1 : -1;
            counted = true;
        }
        seen = seen || sat;
    }
    return ivec4(s.x | (s.y << 8) | (s.z << 12), count, counted ? 1 : 0, seen ? 1 : 0);
}

#ifdef LIMITER_LUT
// A pixel's luma code from its 8-bit display values.
int limiterLuma(ivec3 c) {
    return min(65535, LUMA_LUT[c.r].x + LUMA_LUT[c.g].y + LUMA_LUT[c.b].z) >> 1;
}

// Whether a pixel is saturated red, R / (R + G + B) >= 0.8 of the linear channel codes, widened by
// their rounding so every saturated colour passes.
bool limiterSat(ivec3 c) {
    int r = LUMA_LUT[c.r].w;
    int g = LUMA_LUT[c.g].w;
    int b = LUMA_LUT[c.b].w;
    return r > g + b && r + 4 >= 4 * (g + b);
}

// A pixel's red code: (R - G - B) >> 8 of the linear channel codes when R > G + B, else 0. A red
// change counts only when a saturated state is seen with it (limiterRedStep), so every WCAG
// transition between saturated red and any other state counts and orange to orange does not.
int limiterRed(ivec3 c) {
    int r = LUMA_LUT[c.r].w;
    int g = LUMA_LUT[c.g].w;
    int b = LUMA_LUT[c.b].w;
    return r > g + b ? (r - g - b) >> 8 : 0;
}

bool limiterUntracked(uvec4 t) {
    return (t.y & UNTRACKED) != 0u;
}

// The directions (luma up 1, luma down 2, red up 4, red down 8) tracker t fires in on the pixel
// with display values c; none for a pixel with no state yet.
uint limiterFires(uvec4 t, ivec3 c) {
    if (limiterUntracked(t)) return 0u;
    int fl = limiterLumaStep(t, limiterLuma(c)).w;
    int fr = limiterRedStep(t, limiterRed(c), limiterSat(c)).y;
    return (fl > 0 ? 1u : 0u) | (fl < 0 ? 2u : 0u) | (fr > 0 ? 4u : 0u) | (fr < 0 ? 8u : 0u);
}
#endif


ivec3 limiterBytes(vec3 c) {
    return ivec3(round(c * 255.0));
}
