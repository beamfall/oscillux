// SPDX-License-Identifier: AGPL-3.0-only
// Pass 6, state: one fragment per sub-block (64 x 36). A sub-block that requests a transition
// the grant did not admit is held: it shows the previous output frame and its trackers do not
// advance (recency stamps only age). Every other sub-block advances its trackers on the frame and
// makes the transitions it requested (the trackers' and the reduce pass's pixel counts').
// Inputs uS, uG (this frame's grant), uT0, uT1, uT2; outputs the next state:
//   oT0 = (luma lo, luma hi, red lo, red hi)
//   oT1 = (luma dir + 1, red dir + 1, live, hold)
//   oT2 = recency stamps (luma up, luma down, red up, red down)

void main() {
    ivec2 b = ivec2(gl_FragCoord.xy);
    int tick = int(lu.limiter1.x);
    float deltaMs = lu.limiter1.y;
    uvec4 s = LIM_U(uS, b);
    uvec4 t0 = LIM_U(uT0, b);
    uvec4 t1 = LIM_U(uT1, b);
    uvec4 t2 = LIM_U(uT2, b);
    uint grant = LIM_U(uG, ivec2(0)).x;
    if (t1.z == 0u) {
        oT0 = uvec4(s.x, s.x, s.y, s.y);
        oT1 = uvec4(1u, 1u, 1u, 0u);
        oT2 = uvec4(0u);
        return;
    }
    uvec4 rec = uvec4(limiterRecent(t2.x, tick, deltaMs), limiterRecent(t2.y, tick, deltaMs),
        limiterRecent(t2.z, tick, deltaMs), limiterRecent(t2.w, tick, deltaMs));
    if ((s.z & ~grant & 15u) != 0u) {
        oT0 = t0;
        oT1 = uvec4(t1.xyz, 1u);
        oT2 = rec;
        return;
    }
    ivec4 fl = limiterTrackStep(ivec3(t0.xy, int(t1.x) - 1), int(s.x), LUMA_STEP, LUMA_DARK);
    ivec4 fr = limiterTrackStep(ivec3(t0.zw, int(t1.y) - 1), int(s.y), RED_STEP, NO_DARK);
    bvec4 fired = notEqual(uvec4(s.z) & uvec4(1u, 2u, 4u, 8u), uvec4(0u));
    oT0 = uvec4(fl.xy, fr.xy);
    oT1 = uvec4(uint(fl.z + 1), uint(fr.z + 1), 1u, 0u);
    oT2 = uvec4(fired.x ? uint(tick + 1) : rec.x, fired.y ? uint(tick + 1) : rec.y,
        fired.z ? uint(tick + 1) : rec.z, fired.w ? uint(tick + 1) : rec.w);
}
