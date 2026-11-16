// SPDX-License-Identifier: AGPL-3.0-only
// Ember Glow.
// The last of a fire late at night, seen from close by in the dark. A low bed
// of embers glows along the bottom of the frame, slowly brightening and
// dimming as air reaches it; thin smoke curls up from it, warmed from below,
// and a few sparks drift upward and fade long before the middle of the
// frame. Everything is slow and warm. Audio breathes the fire: the loudness
// brightens the ember bed and the level thickens the warm haze.
// param0 = Sparks (count) ; param1 = Rise (spark and smoke speed) ; param2 = Heat (colour)

vec3 visual(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float x = (uv.x - 0.5) * aspect;
    float y = 1.0 - uv.y;
    float breath = osCalmBreath(u);
    float rise = u.time * mix(0.02, 0.07, u.param1);

    vec3 cool = osPalCalm(0.15, 12, u);
    vec3 warm = mix(osPalCalm(0.3, 12, u), osPalCalm(0.5, 12, u), u.param2);
    vec3 hot = mix(osPalCalm(0.7, 12, u), vec3(1.0, 0.8, 0.5), 0.25);

    // the room: dark, warm near the fire
    vec3 col = cool * 0.008 + warm * 0.03 * exp(-y * 3.5) * (0.8 + 0.25 * saturate(u.level));

    // the ember bed: dark charcoal crazed with glowing cracks that breathe
    // slowly, hotter deeper in the pile
    float bed = 0.1 + 0.04 * fbm(vec2(x * 2.5, 0.0));
    float emb = fbm(vec2(x * 5.0, y * 14.0) + vec2(0.0, u.time * 0.03));
    float crack = pow(1.0 - abs(emb * 2.0 - 1.0), 8.0);
    float pulse = 0.75 + 0.25 * sin(u.time * 0.4 + emb * 6.0);
    float depth = smoothstep(bed, 0.0, y);
    float inBed = smoothstep(bed + 0.02, bed - 0.02, y);
    vec3 glow = cool * 0.006 + warm * 0.05 * depth + hot * 0.45 * crack * pulse * (0.4 + 0.6 * depth);
    col = mix(col, glow * (0.85 + 0.30 * breath), inBed);
    col += warm * 0.06 * exp(-max(y - bed, 0.0) * 12.0) * (0.85 + 0.3 * breath);

    // smoke: warped wisps rising and thinning
    vec2 sq = vec2(x * 2.0, y * 1.5 - rise * 3.0);
    float smoke = fbm(sq + 0.8 * vec2(fbm(sq + 1.7), fbm(sq + 5.2)));
    float wisp = smoothstep(0.55, 0.8, smoke) * smoothstep(0.85, 0.15, y) * smoothstep(bed, bed + 0.12, y);
    col += mix(cool, warm, 0.5) * wisp * 0.025;

    // sparks: a few small points rising on a lazy zigzag, fading with height
    float n = mix(6.0, 18.0, u.param0);
    for (int i = 0; i < 18; i++) {
        float fi = float(i);
        if (fi >= n) break;
        float life = fract(rise * (0.8 + 0.4 * hash11(fi * 3.7)) + hash11(fi * 9.1));
        float sx = (hash11(fi * 1.3) - 0.5) * aspect * 0.9 + 0.05 * sin(life * 9.0 + fi);
        float sy = bed + life * 0.45;
        float d = length(vec2(x - sx, y - sy));
        float fade = (1.0 - life) * smoothstep(0.0, 0.08, life);
        col += hot * exp(-d * d * 30000.0) * fade * 0.6 + warm * exp(-d * 60.0) * fade * 0.01;
    }
    return col; // LINEAR HDR — post chain tonemaps
}
