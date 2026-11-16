// SPDX-License-Identifier: AGPL-3.0-only
// Still Pond.
// Looking straight down into a dark garden pond at dusk. The water mirrors the
// pale glow of the low sky under slow streaks of cloud, a few dark lily pads,
// rim-lit on the side facing the glow, drift and turn at the edges, and now and
// then a drop from an overhanging leaf sends one wide ring spreading across
// the surface, bending the reflection as it passes. The rings are slow and
// faint; the pads keep to the corners, so the middle stays open water. Audio
// breathes the light: the loudness lifts the reflected sky and a drop falls on
// each bar's downbeat.
// param0 = Pads (count) ; param1 = Rings (strength) ; param2 = Sky (reflection)

vec3 visual(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = vec2((uv.x - 0.5) * aspect, uv.y - 0.5);
    float sens = 0.5 + 0.5 * u.sensitivity;
    float breath = osCalmBreath(u);

    // the last four drops, one a bar, each a ring that spreads and fades
    vec2 bend = vec2(0.0);
    float rings = 0.0;
    float bar = floor(u.beatCount / 4.0);
    float since = mod(u.beatCount, 4.0) + saturate(u.beatPhase);
    for (int k = 0; k < 4; k++) {
        float fk = float(k);
        float id = bar - fk;
        float age = (since + fk * 4.0) * 0.5;      // seconds at 120 BPM
        vec2 c = (hash22(vec2(id, 7.0)) - 0.5) * vec2(aspect * 0.9, 0.85);
        vec2 d = p - c;
        float r = length(d);
        float front = r - age * 0.11;
        float wave = sin(front * 70.0) * exp(-front * front * 180.0) * exp(-age * 0.45);
        float amp = mix(0.2, 1.0, u.param1) * (0.6 + 0.4 * sens);
        bend += d / max(r, 1e-3) * wave * 0.012 * amp;
        rings += wave * amp;
    }

    // the reflected sky: soft clouds sliding slowly, tilted by the rings
    vec2 q = p + bend;
    vec3 deep = osPalCalm(0.08, 16, u);
    vec3 mid = osPalCalm(0.4, 16, u);
    vec3 sky = osPalCalm(0.8, 16, u);
    float refl = mix(0.6, 1.4, u.param2) * (0.85 + 0.25 * breath);
    // the pale glow of the low sky lying on the water, crossed by slow streaks of cloud
    vec2 g = vec2(-0.25 * aspect, 0.12);
    float glow = exp(-dot(q - g, q - g) * 3.0);
    float streak = smoothstep(0.35, 0.8, fbm(vec2(q.x * 1.4, q.y * 4.0) + vec2(u.time * 0.012, 0.0)));
    vec3 col = deep * 0.03 + mid * 0.03 * (1.0 - length(p) * 0.6);
    col += sky * refl * (0.16 * glow * (0.6 + 0.4 * streak) + 0.03 * streak);
    col += sky * max(rings, 0.0) * 0.03 * (0.3 + glow);

    // lily pads: dark discs with a narrow notch, rim-lit on the side facing the
    // glow, slowly drifting and turning near the edges
    float pads = mix(3.0, 8.0, u.param0);
    vec3 leaf = osPalCalm(0.45, 16, u);
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        if (fi >= pads) break;
        vec2 h = hash22(vec2(fi, 3.0));
        // place on an ellipse round the frame edge
        float ang = h.x * 6.2832 + u.time * 0.006 * (h.y - 0.5);
        vec2 c = vec2(cos(ang) * aspect * 0.48, sin(ang) * 0.46);
        c += 0.05 * vec2(sin(u.time * 0.03 + fi), cos(u.time * 0.025 + fi * 2.0));
        vec2 d = p - c;
        float rad = mix(0.06, 0.11, h.y);
        float a = atan2_(d.y, d.x) - u.time * 0.02 * (h.x - 0.5) - fi;
        float w = mod(a + 3.1416, 6.2832) - 3.1416;   // angle in [-pi, pi)
        float r = length(d);
        float disc = smoothstep(rad, rad - 0.006, r);
        // the notch: a thin wedge from the rim to the centre
        disc *= 1.0 - smoothstep(0.09, 0.05, abs(w)) * smoothstep(0.0, rad * 0.15, r);
        float vein = 0.9 + 0.1 * sin(w * 9.0);
        vec3 padC = leaf * 0.03 * vein * (0.7 + 0.3 * smoothstep(rad, 0.0, r));
        float face = saturate(dot(d / max(r, 1e-3), normalize(g - c)));
        padC += sky * smoothstep(rad - 0.014, rad - 0.003, r) * face * 0.07 * refl;
        col = mix(col, padC, disc);
    }
    // darker toward the banks
    col *= 1.0 - 0.5 * smoothstep(0.35, 0.75, length(p / vec2(aspect, 1.0)) * 1.2);
    return col; // LINEAR HDR — post chain tonemaps
}
