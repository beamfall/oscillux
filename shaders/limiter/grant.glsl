// SPDX-License-Identifier: AGPL-3.0-only
// Pass 5, grant: one fragment (1 x 1). The frame is over when some window of bcols x brows
// sub-blocks, or cols x rows cells without a sub-block window (covering the 10° field), counts
// more than the area limit pixels changing in any channel and direction (flagged by the windows
// pass); every direction is then over. Luminance over the limit
// is rationed by one token budget; red has its own, refilled at an eighth of the luma rate, so at
// most one large-area red transition (either direction) falls in any 1 s window: no saturated-red
// flash (ITU-R BT.1702, ADR-0232 R5), and a held red change is admitted instead of freezing (R7,
// CORE-2382): the red token is back by the first frame at which the frames after it was last
// spent, each counted up to one refill period of 1 / (2 maxFlashHz) s, have earned
// (65025 / 65024) · 8 periods. The bound is per grant and in periods the frames earn, not on the
// wall clock (README.md, Codex round 24), and it is the token's: a frame that asks luma too also
// waits for the luma token (below; Codex round 25). When both red directions are asked one is
// admitted, the other than last time, so neither starves. Both luma directions may be admitted in
// one frame (a pattern reversing: some pixels rise, others fall). That spends two luma tokens:
// the pair waits
// until the budget has also stood unspent for one refill period (credit, at most one token) and
// leaves two tokens of deficit, so it stands as two singles on both sides and no 1 s window holds
// more than singles allow (CORE-2515). A single grant forfeits the credit. A frame asking both
// channels is admitted only when both are ready: a pixel changing in both shows the change only if
// both are admitted, so a grant of one alone would spend its token on a held change (Codex round
// 13). Inputs uC, uW, uG (the previous grant); output oG = (admitted bits | held bits << 4 | second
// luma token << 8 | last red grant was down << 9 | red refill remainder << 10, luma token deficit, red token deficit, luma
// credit). The deficit can reach two tokens after a pair, more than a 16-bit channel holds, so bit
// 8 of x carries one token of it.

void main() {
    uint refill = uint(lu.limiter0.w);
    uint askBits = 0u;
    bool over = false;
    for (int k = 0; k < GRID_X * GRID_Y; k++) {
        ivec2 cell = ivec2(k % GRID_X, k / GRID_X);
        askBits |= LIM_U(uC, cell).y;
        over = over || LIM_U(uW, cell).x != 0u;
    }
    uint now = askBits & 15u;
    uint recent = askBits >> 4u;
    // When something fires now, a channel firing nowhere but changed recently is part of the over
    // area too: it is asked in one direction (up when it rose), so its own budget pays for the
    // frame and staggering red one frame behind luma cannot slip past the red budget (Codex
    // round 14).
    if (now != 0u) {
        if ((now & 3u) == 0u && (recent & 3u) != 0u) now |= (recent & 1u) != 0u ? 1u : 2u;
        if ((now & 12u) == 0u && (recent & 12u) != 0u) now |= (recent & 4u) != 0u ? 4u : 8u;
    }
    bvec4 asks = notEqual(uvec4(now) & uvec4(1u, 2u, 4u, 8u), uvec4(0u));
    uvec4 last = LIM_U(uG, ivec2(0));
    uint previous = last.y + ((last.x >> 8u) & 1u) * TOKEN;
    uint deficit = previous > refill ? previous - refill : 0u;
    uint credit = min(TOKEN, last.w + (refill > previous ? refill - previous : 0u));
    // An eighth of the luma refill, its remainder carried in bits 10 to 12 of x: exact at any frame
    // interval, so a tiny maxFlashHz does not freeze red (Codex round 14) and a very short one does
    // not refill it early (Codex round 16).
    uint redEarned = ((last.x >> 10u) & 7u) + refill;
    uint redRefill = redEarned / 8u;
    uint redDeficit = last.z > redRefill ? last.z - redRefill : 0u;
    bool lastRedDown = ((last.x >> 9u) & 1u) != 0u;
    bool askUp = over && asks.x, askDown = over && asks.y;
    bool askRedUp = over && asks.z, askRedDown = over && asks.w;
    bool askLuma = askUp || askDown, askRed = askRedUp || askRedDown;
    bool lumaReady = deficit == 0u && (!(askUp && askDown) || credit >= TOKEN);
    bool redReady = redDeficit == 0u;
    bool go = (!askLuma || lumaReady) && (!askRed || redReady);
    bool grantUp = askUp && go;
    bool grantDown = askDown && go;
    if (grantUp || grantDown) {
        deficit = grantUp && grantDown ? 2u * TOKEN : TOKEN;
        credit = 0u;
    }
    bool grantRedUp = askRedUp && go && (!askRedDown || lastRedDown);
    bool grantRedDown = askRedDown && go && !grantRedUp;
    if (grantRedUp || grantRedDown) {
        redDeficit = TOKEN;
        lastRedDown = grantRedDown;
    }
    uint admitted = (!over || grantUp ? 1u : 0u) | (!over || grantDown ? 2u : 0u)
        | (!over || grantRedUp ? 4u : 0u) | (!over || grantRedDown ? 8u : 0u);
    uint high = deficit > TOKEN ? 1u : 0u;
    // Bits 4 to 7: the directions some pixel fires in and the grant did not admit, which hold
    // pixels; a host may stop drawing a paused frame only when they are clear (Codex round 18).
    uint held = askBits & 15u & ~admitted;
    oG = uvec4(admitted | (held << 4u) | (high << 8u) | (lastRedDown ? 512u : 0u) | ((redEarned & 7u) << 10u),
        deficit - high * TOKEN, redDeficit, credit);
}
