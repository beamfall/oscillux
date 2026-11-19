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
        float x = h.x;
        float bandv = bandAtWrapped(u, h.x + beats * 0.02);
        // The band's level reaches the drop only through the swell.
        float drive = mix(0.35, bandv, swell);
        float fall = fract(h.y + u.time * speed * (0.30 + 0.45 * h.x) + beats * (0.03 + 0.03 * h.y));
        float y = mix(-0.12, floorY + 0.08, fall);
        float len = mix(0.16, 0.26, drive);
        float dx = abs(uv.x - x);
        float t = (y - uv.y) / len;  // 0 at the head, 1 at the tail
        float body = (1.0 - smoothstep(0.0014, 0.0065, dx)) * step(0.0, t) * step(t, 1.0)
                   * (0.7 + 0.3 * (1.0 - t));
        vec2 hd = vec2((uv.x - x) * 1.7, (uv.y - y) * 0.35);
        float head = exp(-dot(hd, hd) / 0.000012);
        // palRoleTrace adds 0.03 * beatPhase, which steps at the wrap: take it back out.
        vec3 c = palRoleTrace(x + 0.02 * beats - 0.03 * u.beatPhase, u);
        // Near-white drops would carry most of the frame's luminance swing: hold them to a pale tint.
        c *= min(1.0, 0.75 / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-3));
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
