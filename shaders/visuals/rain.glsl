// SPDX-License-Identifier: AGPL-3.0-only
// Rain — frequency + beat.
//
// Neon spectrum rain over a glossy black floor.
// 64 deterministic drops; no texture dependency.
// param0 Density, param1 Fall Speed, param2 Reflection
//
// Flash budget (CORE-2659): the music never steps the brightness of the whole field at once.
// Every beat-driven term rides a swell that is zero at the beat boundary, rises over ~0.3 beat and
// falls over the rest, so the instant kick, flux and bin jumps of a loud mix reach the screen as a
// smooth lengthening of the drops, not as a frame-to-frame step. Positions, colours and band
// sampling follow the continuous beat clock, so nothing jumps when the beat wraps. Drop, splash-band
// and reflection brightness is steady, so the rain can be dense and bright: only motion changes a
// pixel. Drops do not sway sideways (a beat sway shifted every streak's edge at once and broke the
// budget), and the near-white tint cap keeps the brightest columns from carrying the whole swing.

vec3 visual(vec2 uv, VisualUniforms u) {
    float density = mix(28.0, 64.0, u.param0);
    float speed   = mix(0.35, 1.45, u.param1);
    float refl    = mix(0.15, 0.65, u.param2);

    float floorY = 0.72;
    float beats = u.beatCount + u.beatPhase;
    // 0 at the beat, peak at 0.3 beat, 0 again by the next beat.
    float swell = smoothstep(0.0, 0.3, u.beatPhase) * (1.0 - smoothstep(0.3, 1.0, u.beatPhase));
    vec3 glow = vec3(0.0);

    for (int i = 0; i < 64; i++) {
        if (float(i) >= density) break;
        float fi = float(i);
        vec2 h = hash22(vec2(fi * 2.71, 8.0));
        // Golden-ratio columns spread the drops evenly, so no patch of the frame holds a pile of
        // overlapping streaks whose heads and tails change many pixels at once.
        float x = fract(fi * 0.6180340 + 0.012 * h.x);
        float bandv = bandAtWrapped(u, h.x + beats * 0.02);
        // The band's level reaches the drop only through the swell.
        float drive = mix(0.35, bandv, swell);
        // A narrow spread of fall rates and thin streaks keep the pixels a dense field changes per
        // frame under the limiter's area gate, so the limited output shows the drops unheld.
        float fall = fract(h.y + u.time * speed * (0.30 + 0.28 * h.y) + beats * (0.03 + 0.03 * h.y));
        float y = mix(-0.12, floorY + 0.08, fall);
        float len = mix(0.16, 0.26, drive);
        float dx = abs(uv.x - x);
        float t = (y - uv.y) / len;  // 0 at the head, 1 at the tail
        // Soft ends: the head ramps up over ~8 px and the tail fades out over its last third, so a
        // falling drop changes each pixel gradually rather than switching it on or off in a frame.
        float lead = smoothstep(0.0, 0.03, y - uv.y);
        float body = (1.0 - smoothstep(0.0012, 0.0052, dx)) * lead * (1.0 - smoothstep(0.6, 1.0, t))
                   * (0.75 + 0.25 * (1.0 - t));
        vec2 hd = vec2((uv.x - x) * 1.7, (uv.y - y) * 0.35);
        float head = exp(-dot(hd, hd) / 0.000012);
        // palRoleTrace's beat nudge rides beatArc, which is 0 at both ends of the beat: no step.
        vec3 c = palRoleTrace(x + 0.02 * beats, u);
        // Near-white drops would carry most of the frame's luminance swing: tint them pale cyan and
        // hold them below the blue drops' ceiling.
        float whiteness = smoothstep(0.25, 0.6, min(c.r, min(c.g, c.b)) / max(max(c.r, max(c.g, c.b)), 1e-3));
        c *= mix(vec3(1.0), vec3(0.62, 0.9, 1.0), whiteness);
        c *= min(1.0, mix(0.75, 0.55, whiteness) / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-3));
        // A soft halo hugs each streak, so the rain glows without any one pixel swinging far.
        float halo = exp(-dx * dx * 6000.0) * smoothstep(-0.05, 0.1, t) * (1.0 - smoothstep(0.9, 1.15, t));
        glow += c * (body * 1.7 + head * 0.7 + halo * 0.08);

        // A steady glowing splash band along the floor, fed by every drop column, and reflection.
        float splash = exp(-(uv.y - floorY)*(uv.y - floorY) * 1800.0) * exp(-(uv.x - x)*(uv.x - x) * 900.0);
        float bloomBand = exp(-(uv.y - floorY)*(uv.y - floorY) * 160.0) * exp(-(uv.x - x)*(uv.x - x) * 400.0);
        glow += c * (splash * 0.6 + bloomBand * 0.06);

        if (uv.y > floorY) {
            float ry = floorY + (floorY - y) * 0.42;
            float refLine = (1.0 - smoothstep(0.001, 0.005, dx)) * aaLine(uv.y - ry, len * 0.22);
            glow += c * refLine * refl * (1.0 - smoothstep(floorY, 1.0, uv.y)) * 0.8;
        }
    }

    float floorLine = aaLine(uv.y - floorY, 0.0016);
    glow += palRoleFog(0.56, u) * floorLine * 0.28;

    vec3 col = feedbackTrail(glow, uv,
                             min(u.trailDecay, 0.82),
                             0.0,
                             0.0);
    return col; // LINEAR HDR — post chain tonemaps
}
