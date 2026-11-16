// SPDX-License-Identifier: AGPL-3.0-only
// Lantern Drift.
// Paper sky lanterns rise slowly through a still evening above a dark line of
// hills. They float at three depths: far ones are small warm points, near
// ones soft glowing shells, a little out of focus, swaying as they climb.
// Most of them keep to the sides of the frame, so the middle stays a clear
// dusk gradient. Audio only breathes the flames: the loudness swells every
// lantern's glow a little and the song's level warms the afterglow.
// param0 = Lanterns (density) ; param1 = Rise (climb speed) ; param2 = Warmth (glow colour)

// The light one depth layer of lanterns adds at p (frame units, y up).
vec3 ldLayer(vec2 p, float layer, float rise, float density, float aspect, float breath, vec3 warm, vec3 hot) {
    float scale = 4.0 + 3.5 * layer;
    vec2 q = vec2(p.x * scale, (p.y + rise * (0.6 + 0.25 * layer)) * scale);
    vec2 cell = floor(q);
    vec2 f = fract(q) - 0.5;
    vec2 sd = cell + vec2(layer * 13.1, layer * 7.7);
    // fewer lanterns toward the middle, decided per cell so none is ever cut
    float side = 0.35 + 0.65 * smoothstep(0.12, 0.55, abs((cell.x + 0.5) / scale) / max(aspect, 1e-3) * 2.0);
    if (hash21(sd + 0.5) > density * mix(1.0, side, 0.4 + 0.3 * layer)) return vec3(0.0);
    // each lantern sways on its own slow phase and sits off the cell centre
    float ph = hash21(sd + 2.3) * 6.2832;
    vec2 off = (hash22(sd) - 0.5) * 0.25;
    off.x += 0.05 * sin(ph + rise * 2.0 + p.y * 3.0);
    vec2 d = f - off;
    // a rounded paper shell, taller than wide, brightest low where the flame is
    float size = mix(0.07, 0.16, hash21(sd + 4.1)) * (1.0 - 0.25 * layer / 2.0);
    vec2 e = d / vec2(size, size * 1.35);
    float shell = smoothstep(1.0, 0.55, length(e));
    float flame = exp(-dot(e - vec2(0.0, -0.45), e - vec2(0.0, -0.45)) * 3.0);
    // the halo dies out inside the cell, so no cell edge ever shows
    float glow = exp(-length(d) / (size * 1.8)) * 0.25 * smoothstep(0.5, 0.2, length(f));
    // gentle flicker, a few seconds long, never a blink
    float flick = 0.85 + 0.15 * sin(ph * 3.0 + rise * 5.0);
    float depthDim = mix(0.55, 1.0, layer / 2.0);
    vec3 c = warm * (shell * (0.35 + 0.65 * flame) + glow) + hot * flame * shell * 0.35;
    return c * flick * depthDim * (0.85 + 0.30 * breath);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = vec2((uv.x - 0.5) * aspect, 1.0 - uv.y);
    float breath = osCalmBreath(u);

    vec3 sky0 = osPalCalm(0.05, 17, u);
    vec3 sky1 = osPalCalm(0.30, 17, u);
    vec3 warm = mix(osPalCalm(0.62, 17, u), osPalCalm(0.80, 17, u), u.param2);
    vec3 hot = mix(warm, vec3(luma(warm)), 0.5) + 0.2;

    // dusk: a deep top, a soft warm afterglow low in the sky
    float y = p.y;
    vec3 col = mix(sky1 * 0.10, sky0 * 0.035, smoothstep(0.15, 0.95, y));
    col += warm * 0.05 * exp(-max(y - 0.18, 0.0) * 6.0) * (0.8 + 0.2 * saturate(u.level));

    // lanterns, far to near, mostly toward the sides
    float rise = u.time * mix(0.012, 0.045, u.param1);
    float density = mix(0.06, 0.3, u.param0);
    vec3 lights = vec3(0.0);
    for (int l = 0; l < 3; l++) {
        float layer = float(l);
        lights += ldLayer(p, layer, rise, density, aspect, breath, warm, hot);
    }
    // lanterns fade in as they clear the hills and thin out high in the sky
    col += lights * smoothstep(0.10, 0.28, y) * (1.0 - 0.4 * smoothstep(0.8, 1.0, y));

    // the hills: two dark ridges, the far one hazed by the afterglow
    float far = 0.17 + 0.05 * fbm(vec2(p.x * 1.4 + 3.0, 1.7));
    float near = 0.10 + 0.06 * fbm(vec2(p.x * 2.2 - 5.0, 4.1));
    col = mix(col, sky1 * 0.06 + warm * 0.02, smoothstep(far + 0.004, far - 0.004, y));
    col = mix(col, sky0 * 0.02, smoothstep(near + 0.004, near - 0.004, y));
    return col; // LINEAR HDR — post chain tonemaps
}
