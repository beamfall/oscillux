// SPDX-License-Identifier: AGPL-3.0-only
// Neon Photo Topography — the photo laid over a terrain flyover seen in true
// perspective: photo color fills the land with slope lighting, luminous
// contour lines trace its heightfield, aerial haze fades to a glowing horizon.
// param0 = Speed ; param1 = Height ; param2 = Contours

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    p.y = -p.y; // y-up world (raw +p.y is down-screen)
    // slow enough that contour lines pass a pixel well under 3 times a second:
    // faster, the whole field strobes as the lines sweep over it
    float speed    = mix(0.08, 0.40, u.param0);
    float hAmt     = mix(0.22, 0.55, u.param1);
    float contours = mix(5.0, 12.0, u.param2);

    // ground plane: horizon high in frame, near field at the bottom
    float horizonY = 0.62;
    float z = 1.0 / max(0.09, horizonY - p.y); // depth: small near, huge at horizon
    vec2 world = vec2(p.x * z * 1.45, z * 0.85 + u.time * speed);
    vec2 wUV = fract(world * 0.22 + 0.5);

    vec3 photoC = max(IMG(photoCover(wUV, u.resolution, IMGSIZE)).rgb, vec3(0.0));
    float lum = luma(photoC);
    // slope shade from a second luminance tap slightly "north"
    float lum2 = luma(max(IMG(photoCover(fract(wUV + vec2(0.0, 0.03)), u.resolution, IMGSIZE)).rgb, vec3(0.0)));
    float shade = clamp(0.62 + (lum - lum2) * 5.0, 0.25, 1.35);

    float h = lum * hAmt + bandAt(u, fract(world.x * 0.22 + 0.5)) * 0.28;
    // contours lurch forward on each beat (eased, continuous across beats):
    // the beat moves the lines instead of pumping their brightness
    float beatT = u.beatCount + 1.0 - pow(1.0 - saturate(u.beatPhase), 3.0);
    float contour = aaLineCyclic((world.y + h) * contours - beatT * 0.15,
                                 0.045);
    float cross = aaLineCyclic(world.x * 6.0, 0.020) * 0.30;

    // aerial perspective: terrain fades with distance and dies at the horizon.
    // Past the point where one pixel spans several world units the contour
    // and photo frequencies alias into moire, so the haze takes over there.
    float fw = length(fwidth(world));
    float aliasFade = 1.0 - smoothstep(0.06, 0.30, fw);
    contour *= aliasFade;
    cross *= aliasFade;
    shade = mix(0.62, shade, aliasFade);
    float farFade = mix(0.35, 1.0, aliasFade) / (1.0 + z * 0.30);
    float mask = (1.0 - smoothstep(horizonY - 0.20, horizonY, p.y))
               * smoothstep(-1.15, -0.80, p.y) * farFade;

    // terrain: photo colors the land, slope lighting gives it relief
    vec3 col = photoC * shade * mask * (0.34 + 0.10 * u.level);
    // glowing contours trace the photo's heightfield
    vec3 lineCol = mix(photoC * 1.6,
                       palVisual(fract(world.x * 0.10 + lum * 0.8), u), 0.45);
    col += lineCol * (contour + cross) * mask * (0.18 + 0.08 * u.bass);

    // glowing horizon line, breathing with the bass
    float horizon = exp(-abs(p.y - horizonY) * 9.0);
    col += palVisual(0.60 + 0.10 * u.spectralCentroid, u) * horizon
         * (0.16 + 0.14 * u.bass);
    // dim photo haze in the sky above the horizon keeps the frame alive
    float sky = smoothstep(horizonY - 0.02, 1.05, p.y);
    vec3 skyPhoto = max(IMG(photoCover(clamp(vec2(uv.x, 0.10 + uv.y * 0.35), 0.0, 1.0), u.resolution, IMGSIZE)).rgb, vec3(0.0));
    col += skyPhoto * sky * (0.14 + 0.08 * u.level);

    col *= 0.40 + 0.60 * smoothstep(1.75, 0.50, length(p));
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.62), 0.003, 0.001);
    return col; // LINEAR HDR — post chain tonemaps
}
