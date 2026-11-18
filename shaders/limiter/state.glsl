// SPDX-License-Identifier: AGPL-3.0-only
// Pass 6, state: one fragment per sub-block (64 x 36). A sub-block that requests a transition
// the grant did not admit is held: it shows the previous output frame and its trackers do not
// advance (recency stamps only age). Every other sub-block advances its trackers on the frame and
// makes the transitions it requested (the trackers' and the reduce pass's pixel counts').
// The pass also writes the hold field the output pass blends by: at each sub-block, 0..64, the
// largest over the held sub-blocks within four of it on each axis of clamp(72 - 4 d2, 0, 64), d2
// the squared distance in sub-blocks. It is 64 at a held sub-block and its eight neighbours and
// reaches 0 a little past four sub-blocks away, so a hold fades out round, not square.
// Inputs uS, uG (this frame's grant), uT0, uT1, uT2; outputs the next state:
//   oT0 = (luma lo, luma hi, red lo, red hi)
//   oT1 = (luma dir + 1, red dir + 1, live, hold + 2 * hold field)
//   oT2 = recency stamps (luma up, luma down, red up, red down)

const int FIELD_REACH = 4;

void main() {
    ivec2 b = ivec2(gl_FragCoord.xy);
    int tick = int(lu.limiter1.x);
    float deltaMs = lu.limiter1.y;
    uvec4 s = LIM_U(uS, b);
    uvec4 t0 = LIM_U(uT0, b);
    uvec4 t1 = LIM_U(uT1, b);
    uvec4 t2 = LIM_U(uT2, b);
    uint grant = LIM_U(uG, ivec2(0)).x;
    int field = 0;
    for (int j = -FIELD_REACH; j <= FIELD_REACH; j++) {
        for (int i = -FIELD_REACH; i <= FIELD_REACH; i++) {
            ivec2 q = b + ivec2(i, j);
            if (q.x < 0 || q.y < 0 || q.x >= BLOCKS_X || q.y >= BLOCKS_Y) continue;
            if ((LIM_U(uS, q).z & ~grant & 15u) == 0u) continue;
            field = max(field, clamp(72 - 4 * (i * i + j * j), 0, 64));
        }
    }
    uint fw = uint(2 * field);
    if (t1.z == 0u) {
        oT0 = uvec4(s.x, s.x, s.y, s.y);
        oT1 = uvec4(1u, 1u, 1u, fw);
        oT2 = uvec4(0u);
        return;
    }
    uvec4 rec = uvec4(limiterRecent(t2.x, tick, deltaMs), limiterRecent(t2.y, tick, deltaMs),
        limiterRecent(t2.z, tick, deltaMs), limiterRecent(t2.w, tick, deltaMs));
    if ((s.z & ~grant & 15u) != 0u) {
        oT0 = t0;
        oT1 = uvec4(t1.xyz, 1u + fw);
        oT2 = rec;
        return;
    }
    ivec4 fl = limiterTrackStep(ivec3(t0.xy, int(t1.x) - 1), int(s.x), LUMA_STEP, LUMA_DARK);
    ivec4 fr = limiterTrackStep(ivec3(t0.zw, int(t1.y) - 1), int(s.y), RED_STEP, NO_DARK);
    bvec4 fired = notEqual(uvec4(s.z) & uvec4(1u, 2u, 4u, 8u), uvec4(0u));
    oT0 = uvec4(fl.xy, fr.xy);
    oT1 = uvec4(uint(fl.z + 1), uint(fr.z + 1), 1u, fw);
    oT2 = uvec4(fired.x ? uint(tick + 1) : rec.x, fired.y ? uint(tick + 1) : rec.y,
        fired.z ? uint(tick + 1) : rec.z, fired.w ? uint(tick + 1) : rec.w);
}
