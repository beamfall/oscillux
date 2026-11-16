// SPDX-License-Identifier: AGPL-3.0-only
// Pass 5, grant: one fragment (1 x 1). A direction is over when some window of cols x rows cells
// (the 10° field) counts more than the area limit (flagged by the windows pass). Luminance over
// the limit is rationed by one token budget; red has its own with refill 0 and is never granted,
// so it never takes or waits for the luminance token. WCAG 2.3.1 (Three Flashes or Below
// Threshold) allows at most three red flashes a second over the area and ITU-R BT.1702 forbids
// saturated-red flashes; this limiter applies the red-0 rule: no large-area red transition.
// Inputs uC, uW, uG (the previous grant); output oG = (admitted bits | over bits << 4, token
// deficit, 0, 0).

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
    bool grantUp = over.x && asks.x > 0u && deficit == 0u;
    if (grantUp) deficit = TOKEN;
    bool grantDown = over.y && asks.y > 0u && deficit == 0u;
    if (grantDown) deficit = TOKEN;
    uint admitted = (!over.x || grantUp ? 1u : 0u) | (!over.y || grantDown ? 2u : 0u)
        | (!over.z ? 4u : 0u) | (!over.w ? 8u : 0u);
    uvec4 o = uvec4(over);
    oG = uvec4(admitted | (o.x << 4u) | (o.y << 5u) | (o.z << 6u) | (o.w << 7u), deficit, 0u, 0u);
}
