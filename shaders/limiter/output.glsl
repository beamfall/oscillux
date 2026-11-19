// SPDX-License-Identifier: AGPL-3.0-only
// Pass 6, output: one fragment per pixel. A pixel whose trackers would fire on the input in a
// direction the grant did not admit shows the previous output frame; every other pixel shows the input exactly, so
// the output makes only the transitions the grant admitted. (Until v0.2.9 the pixels around a
// hold blended toward the previous output; a blended change appeared after the token it spent had
// refilled: CORE-2543, CORE-2541.) The pixel's trackers then step on the output, so they hold the
// pixel auditor's state: a held pixel shows the value its tracker last took and does not move it,
// and stamps outside the coverage interval clear. Inputs uFrame (RGBA8), uHist (the previous
// output, RGBA8), uTrack (the tracker state after the previous frame), uG (this frame's
// grant); outputs oColor (RGBA8, alpha 1), next frame's uHist, and
// oTrack (RGBA16UI), next frame's uTrack.

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    uint grant = LIM_U(uG, ivec2(0)).x;
    uvec4 t = LIM_U(uTrack, p);
    vec3 color = LIM_F(uFrame, p).rgb;
    if ((limiterFires(t, limiterBytes(color)) & ~grant & 15u) != 0u) color = LIM_F(uHist, p).rgb;
    oColor = vec4(color, 1.0);
    ivec3 c = limiterBytes(color);
    int v = limiterLuma(c);
    int rv = limiterRed(c);
    if (limiterUntracked(t)) {
        oTrack = uvec4(uint(v), uint(v), uint(rv | (rv << 8)), 0u);
        return;
    }
    ivec3 fl = limiterTrackStep(int(t.x), int(t.y), v, LUMA_STEP, LUMA_DARK, LUMA_MAX);
    ivec3 fr = limiterTrackStep(int(t.z & 255u), int(t.z >> 8u), rv, RED_STEP, NO_DARK, RED_MAX);
    uint fired = (fl.z > 0 ? 1u : 0u) | (fl.z < 0 ? 2u : 0u) | (fr.z > 0 ? 4u : 0u) | (fr.z < 0 ? 8u : 0u);
    int unit = int(lu.limiter1.x) >> 4;
    float deltaMs = lu.limiter1.y;
    uint stamps = 0u;
    for (int d = 0; d < 4; d++) {
        uint s = (t.w >> uint(4 * d)) & 15u;
        uint keep = ((fired >> uint(d)) & 1u) != 0u ? uint(unit + 1) : limiterRecent(s, unit, deltaMs) ? s : 0u;
        stamps |= keep << uint(4 * d);
    }
    oTrack = uvec4(uint(fl.x), uint(fl.y), uint(fr.x | (fr.y << 8)), stamps);
}
