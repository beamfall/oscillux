// SPDX-License-Identifier: AGPL-3.0-only
// Pass 5, grant: one fragment (1 x 1). A direction is over when some window of cols x rows cells
// (the 10° field) counts more than the area limit (flagged by the windows pass). Luminance over
// the limit is rationed by one token budget; red has its own, refilled at an eighth of the luma
// rate, so at most one large-area red transition (either direction) falls in any 1 s window: no
// saturated-red flash (ITU-R BT.1702, ADR-0232 R5), and a held red change is admitted within
// 8 / (2 maxFlashHz) s instead of freezing (R7, CORE-2382). Red never takes or waits for the
// luminance token. Both luma directions may be admitted in one frame (a pattern reversing: some
// pixels rise, others fall); that costs two luma tokens, the second owed and taken when the first
// has refilled (CORE-2515). Inputs uC, uW, uG (the previous grant); output oG = (admitted bits |
// over bits << 4, luma token deficit, red token deficit, luma token owed).

void main() {
    uint refill = uint(lu.limiter0.w);
    uvec4 asks = uvec4(0u);
    uint overBits = 0u;
    for (int k = 0; k < GRID_X * GRID_Y; k++) {
        ivec2 cell = ivec2(k % GRID_X, k / GRID_X);
        asks += LIM_U(uC, cell) >> 5u;
        overBits |= LIM_U(uW, cell).x;
    }
    bvec4 over = notEqual(uvec4(overBits) & uvec4(1u, 2u, 4u, 8u), uvec4(0u));
    uint previous = LIM_U(uG, ivec2(0)).y;
    uint deficit = previous > refill ? previous - refill : 0u;
    uint owed = LIM_U(uG, ivec2(0)).w;
    if (deficit == 0u && owed != 0u) {
        deficit = TOKEN;
        owed = 0u;
    }
    bool grantUp = over.x && asks.x > 0u && deficit == 0u;
    bool grantDown = over.y && asks.y > 0u && deficit == 0u;
    if (grantUp || grantDown) deficit = TOKEN;
    if (grantUp && grantDown) owed = 1u;
    uint redRefill = refill / 8u;
    uint redPrevious = LIM_U(uG, ivec2(0)).z;
    uint redDeficit = redPrevious > redRefill ? redPrevious - redRefill : 0u;
    bool grantRedUp = over.z && asks.z > 0u && redDeficit == 0u;
    if (grantRedUp) redDeficit = TOKEN;
    bool grantRedDown = over.w && asks.w > 0u && redDeficit == 0u;
    if (grantRedDown) redDeficit = TOKEN;
    uint admitted = (!over.x || grantUp ? 1u : 0u) | (!over.y || grantDown ? 2u : 0u)
        | (!over.z || grantRedUp ? 4u : 0u) | (!over.w || grantRedDown ? 8u : 0u);
    uvec4 o = uvec4(over);
    oG = uvec4(admitted | (o.x << 4u) | (o.y << 5u) | (o.z << 6u) | (o.w << 7u), deficit,
        redDeficit, owed);
}
