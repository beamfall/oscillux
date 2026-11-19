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
// smooth lengthening and brightening of the drops, not as a frame-to-frame step. Positions,
// colours and band sampling follow the continuous beat clock, so nothing jumps when the beat wraps.
// Drops fade from head to tail and their heads are tight points, so they leave no broad haze.

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
        float x = fract(h.x + sin(beatRadians(u, h.x)) * 0.003);
        float bandv = bandAtWrapped(u, h.x + beats * 0.02);
        // The band's level reaches the drop only through the swell.
        float drive = mix(0.35, bandv, swell);
        float fall = fract(h.y + u.time * speed * (0.30 + 0.45 * h.x) + beats * (0.03 + 0.03 * h.y));
        float y = mix(-0.12, floorY + 0.08, fall);
        float len = mix(0.10, 0.20, drive);
        float dx = abs(uv.x - x);
        float t = (y - uv.y) / len;  // 0 at the head, 1 at the tail
        float body = (1.0 - smoothstep(0.0012, 0.0055, dx)) * step(0.0, t) * step(t, 1.0)
                   * (1.0 - t) * (0.4 + 0.6 * (1.0 - t));
        vec2 hd = vec2((uv.x - x) * 1.7, (uv.y - y) * 0.35);
        float head = exp(-dot(hd, hd) / 0.000012);
        // palRoleTrace adds 0.03 * beatPhase, which steps at the wrap: take it back out.
        vec3 c = palRoleTrace(x + 0.02 * beats - 0.03 * u.beatPhase, u);
        // Near-white drops would carry most of the frame's luminance swing: hold them to a pale tint.
        c *= min(1.0, 0.5 / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-3));
        glow += c * (body * (0.6 + 0.2 * drive) + head * 0.7);

        // Floor splash, only while this drop's head is at the floor, and reflection.
        float landing = exp(-(y - floorY) * (y - floorY) * 250.0);
        float splash = exp(-(uv.y - floorY)*(uv.y - floorY) * 2400.0) * exp(-(uv.x - x)*(uv.x - x) * 2600.0);
        glow += c * splash * landing * (0.3 + 0.2 * drive);

        if (uv.y > floorY) {
            float ry = floorY + (floorY - y) * 0.42;
            float refLine = (1.0 - smoothstep(0.001, 0.005, dx)) * aaLine(uv.y - ry, len * 0.22);
            glow += c * refLine * refl * (1.0 - smoothstep(floorY, 1.0, uv.y)) * (0.25 + 0.5 * drive);
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
