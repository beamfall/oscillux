// SPDX-License-Identifier: AGPL-3.0-only
// Soft Bokeh.
// A string of far-off lights seen through a lens focused on nothing: every
// light opens into a soft disc with a slightly brighter rim, the discs
// overlap and their colours add, and the whole field drifts sideways as if
// the camera were slowly panning. Near discs are large and faint, far ones
// small and clearer. The discs gather toward the top and bottom of the frame,
// leaving a darker band through the middle. Audio breathes the lights: the
// loudness swells every disc a touch and the level brightens the far ones.
// param0 = Lights (density) ; param1 = Pan (drift speed) ; param2 = Size (aperture)

vec3 sbLayer(vec2 p, float layer, float pan, float density, float size, float breath, VisualUniforms u) {
    float scale = mix(2.6, 6.5, layer / 3.0);
    vec2 q = (p + vec2(pan * mix(0.6, 1.0, layer / 3.0), layer * 0.37)) * scale;
    vec2 cell = floor(q);
    vec3 c = vec3(0.0);
    // neighbours too, so a large disc is never clipped at its cell edge
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 id = cell + vec2(float(i), float(j));
            vec2 sd = id + vec2(layer * 31.7, layer * 11.3);
            if (hash21(sd + 0.7) > density) continue;
            vec2 ctr = id + 0.5 + (hash22(sd) - 0.5) * 0.7;
            // each light drifts on its own slow loop
            float ph = hash21(sd + 5.1) * 6.2832;
            ctr += 0.12 * vec2(sin(u.time * 0.05 + ph), cos(u.time * 0.04 + ph * 1.3));
            float rad = mix(0.35, 0.65, hash21(sd + 2.9)) * size * (1.0 + 0.06 * breath);
            float r = length(q - ctr);
            float disc = smoothstep(rad, rad * 0.8, r);
            float rim = smoothstep(rad * 0.75, rad * 0.95, r) * disc;
            vec3 tint = osPalCalm(hash21(sd + 8.3), 10, u);
            c += tint * (disc * 0.7 + rim * 0.25);
        }
    }
    return c;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = vec2((uv.x - 0.5) * aspect, uv.y - 0.5);
    float breath = osCalmBreath(u);
    float pan = u.time * mix(0.005, 0.03, u.param1);
    float density = mix(0.12, 0.4, u.param0);
    float size = mix(0.7, 1.1, u.param2);

    vec3 col = osPalCalm(0.1, 10, u) * 0.012 + osPalCalm(0.6, 10, u) * 0.01 * (1.0 - uv.y);
    // a band through the middle is kept dim, so the discs gather above and below it
    float band = 1.0 - 0.8 * exp(-p.y * p.y * 16.0);
    for (int l = 0; l < 4; l++) {
        float layer = float(l);
        // near layers are larger, fainter and slower
        float gain = mix(0.035, 0.075, layer / 3.0) * (layer > 2.5 ? 0.85 + 0.25 * saturate(u.level) : 1.0);
        col += sbLayer(p, layer, pan, density, size, breath, u) * gain * band;
    }
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
