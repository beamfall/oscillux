// SPDX-License-Identifier: AGPL-3.0-only
// Plasma — a domain-warped, self-folding colour field of ionized gas.
// Two nested warps of a rotated-octave fbm fold the field into flowing lobes,
// shaded on a temperature ramp (cool sheath -> vivid body -> hot crest). Bass
// deepens the fold, mids steer the flow, treble frays crests into fine glints,
// and beats/onsets discharge along crests and sheath only (never a full-frame pulse).
// param0 = Scale ; param1 = Turbulence ; param2 = Filaments

float plz_noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// Rotated octaves: no axis-aligned grain.
float plz_fbm(vec2 p) {
    const mat2 R = mat2(0.80, 0.60, -0.60, 0.80);
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; ++i) {
        v += a * plz_noise(p);
        p = R * p * 2.03 + vec2(1.7, 9.2);
        a *= 0.5;
    }
    return v / 0.9375;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float scale = mix(0.62, 1.45, u.param0);
    float turb = mix(0.6, 1.4, u.param1);
    float filGain = mix(0.4, 1.6, u.param2);

    float bass = clamp(u.bass, 0.0, 1.0);
    float mid = clamp(u.mid, 0.0, 1.0);
    float treble = clamp(u.treble, 0.0, 1.0);
    float level = clamp(u.level, 0.0, 1.0);

    // Slow drift in silence; the field never freezes.
    float t = u.time * 0.045;
    vec2 sp = p * scale * 0.9;

    // First warp: large lobes. Mids steer them sideways (bounded offset).
    vec2 steer = vec2(0.35, -0.22) * mid;
    vec2 q = vec2(plz_fbm(sp + vec2(t, -0.6 * t) + steer),
                  plz_fbm(sp + vec2(5.2, 1.3) + vec2(-0.7 * t, t) - steer));

    // Second warp folds the lobes; bass deepens the fold.
    float warp = (2.1 + 0.55 * bass) * turb;
    vec2 r = vec2(plz_fbm(sp + warp * q + vec2(1.7, 9.2) + 0.8 * t),
                  plz_fbm(sp + warp * q + vec2(8.3, 2.8) - 0.9 * t));
    float f = plz_fbm(sp + warp * r);

    // Treble adds a fine turbulent fbm to the field (ragged, lacy crests),
    // faded by the field's screen rate so it never aliases.
    float grain = plz_fbm(sp * (5.5 + 2.0 * turb) + r * 3.0 + vec2(u.time * 0.3, -u.time * 0.2));
    float aa = clamp(1.0 - fwidth(f) * 14.0, 0.2, 1.0);
    float fd = f + (grain - 0.5) * (0.03 + 0.16 * treble) * aa;

    // Temperature ramp by density: cool sheath -> vivid body -> hot core.
    // r and q shift the ramp so neighbouring lobes differ in hue.
    float dens = smoothstep(0.30, 0.86, fd);
    vec3 cool = palVisual(0.93 - 0.12 * q.y, u);
    vec3 vivid = palVisual(0.66 + 0.08 * r.x + 0.06 * mid, u);
    vec3 warm = palVisual(0.24 + 0.05 * r.y, u);
    float shift = 0.22 * (r.x - 0.5);
    vec3 tint = mix(cool, vivid, smoothstep(0.08, 0.50, dens + shift));
    tint = mix(tint, warm, smoothstep(0.62, 1.0, dens - shift) * 0.75);
    // Shadowed folds where the first warp is strongest.
    float shadow = clamp(length(q) * 1.3 - 0.55, 0.0, 0.7);
    vec3 col = tint * (0.018 + 0.09 * dens + 0.48 * dens * dens * dens) * (1.0 - shadow);
    // Ionized sheath: a thin cool glow where the gas thins into the void.
    float sheath = smoothstep(0.02, 0.16, dens) * (1.0 - smoothstep(0.16, 0.40, dens));
    // Beats and onsets discharge along crests and the sheath only, and each beat lights a
    // different patch of the field (zone re-seeded per beat): the synchronous change stays
    // far under the WCAG 2.3.1 25% area, whatever the palette or loudness.
    float accent = clamp(max(u.onset * 0.7, u.beat), 0.0, 1.0);
    float zone = smoothstep(0.52, 0.78, plz_noise(sp * 0.7 + vec2(u.beatCount * 3.17, u.beatCount * 1.71)));
    float hit = accent * zone;
    col += cool * sheath * (0.07 + 0.05 * mid) * (1.0 + 0.8 * hit) * (1.0 - shadow);
    float crest = smoothstep(0.74 - 0.03 * hit, 0.92, fd);

    // Hot crest colour: palette warm end lifted toward white.
    vec3 hot = mix(palVisual(0.30 + 0.08 * r.y, u), vec3(1.0, 0.94, 0.86), 0.3);
    // Discharge gain is normalised by the crest's own luminance so near-white palettes
    // (Porcelain) get the same luminance step as saturated ones.
    float heat = 0.6 + 0.2 * level + 0.1 * accent + 0.45 * hit / (0.15 + luma(hot));
    col += hot * crest * crest * crest * heat * filGain;

    // Treble glints: the fine turbulence catches light inside the lobes.
    float glint = smoothstep(0.62, 0.80, grain) * dens * dens * aa;
    col += mix(vivid, hot, 0.7) * glint * treble * 0.6 * filGain;

    // Faint cold haze in the voids so silence is never black.
    col += cool * 0.018 * (1.0 - dens);

    // Calm-but-alive in silence, gentle lift with level.
    col *= 0.75 + 0.25 * level;

    return col; // LINEAR HDR — post chain tonemaps
}
