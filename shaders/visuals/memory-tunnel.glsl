// SPDX-License-Identifier: AGPL-3.0-only
// Memory Tunnel — flying down a corridor whose floor and ceiling are paved
// with framed photo prints. Each tile shows the whole photo, lit by a pulsing
// horizon; beats send a wave of colour racing down the corridor.
// param0 = Flight ; param1 = Depth ; param2 = Pulse

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    p.x *= 0.92;
    float far = mix(4.2, 7.0, u.param1);
    float pulseAmt = mix(0.4, 1.5, u.param2);

    // beat count that glides forward over each beat and never jumps back at the
    // wrap; an eased glide (not a kick) so the whole lattice of high-contrast
    // prints never lurches at once under loud music
    float beatSurge = floor(u.beatCount) + smoothstep(0.0, 1.0, u.beatPhase);
    // beat swell: ~180 ms attack, released to zero by the wrap, so nothing
    // steps on the beat
    float swell = smoothstep(0.0, 0.36, u.beatPhase)
                * (1.0 - smoothstep(0.36, 1.0, u.beatPhase));

    float z = 1.0 / max(0.13, abs(p.y) + 0.22);
    float lane = p.x * z;
    float depth = z + u.time * (0.38 + u.param0) + beatSurge * 0.15;

    // tile lattice — slim frames around each photo print
    float cellPhaseX = lane * 1.6 + 0.5;
    float cellX = fract(cellPhaseX);
    float cellPhaseZ = depth * 0.55;
    float cellZ = fract(cellPhaseZ);
    // frames keep a slim on-screen width: near the camera a cell spans a big
    // slice of the screen, so a fixed cell-space width became thick bands that
    // swept the frame edges as the corridor flowed
    float frameX = aaLineCyclic(cellPhaseX, 0.012 * clamp(z / 2.5, 0.3, 1.0));
    float frameZ = aaLineCyclic(cellPhaseZ, 0.016 * clamp(z * z / 5.0, 0.15, 1.0));
    float frame = max(frameX, frameZ);

    // fog window: fade in near camera, out toward the horizon
    float fog = smoothstep(0.0, 0.9, z) * smoothstep(far, 1.0, z);

    // each tile carries the full photo (small inset margin)
    vec2 tileUV = clamp((vec2(cellX, cellZ) - 0.06) / 0.88, 0.0, 1.0);
    // ceiling tiles flip so prints hang the right way up
    if (p.y > 0.0) { tileUV.y = 1.0 - tileUV.y; }
    vec3 photo = max(IMG(photoCover(clamp(tileUV, 0.001, 0.999), u.resolution, IMGSIZE)).rgb, vec3(0.0));
    // richer prints: push saturation and contrast so the corridor stays vivid
    float photoLum = dot(photo, vec3(0.2126, 0.7152, 0.0722));
    photo = max(mix(vec3(photoLum), photo, 1.35), vec3(0.0));
    photo = photo * photo * 1.6;

    // beat pulse: a bright wave races down the corridor from the horizon
    float wave = fract(depth * 0.15 - u.beatPhase);
    float pulse = exp(-wave * wave * 18.0) * (0.45 + 0.30 * swell) * pulseAmt;

    // the wave sweeps every print once a beat, so it shifts their hue, not
    // their brightness; the slim frames carry a little of its light
    float interior = (1.0 - frame);
    vec3 waveTint = palVisual(fract(0.30 + depth * 0.05), u);
    waveTint /= max(dot(waveTint, vec3(0.2126, 0.7152, 0.0722)), 0.05);
    vec3 lit = mix(vec3(1.0), clamp(waveTint, 0.0, 3.0), clamp(pulse * 0.45, 0.0, 0.6));
    vec3 col = photo * lit * interior * fog * (0.30 + 0.05 * u.level);

    // slim glowing frames between prints — never louder than the prints
    col += palVisual(fract(depth * 0.07 + lane * 0.05 + 0.12 * pulse), u) * frame * fog
         * (0.22 + 0.08 * u.bass + 0.14 * pulse);

    // luminous horizon at the vanishing line; it spans the frame, so the kick
    // only nudges it
    float horizon = exp(-abs(p.y) * 20.0) * (0.5 + 0.3 * u.bassImpact) * pulseAmt;
    col += palVisual(0.58 + u.spectralCentroid * 0.2, u) * horizon * 0.35;
    // hot core right at the vanishing point
    col += peakWhite(palVisual(0.62, u), 0.3 + 0.2 * u.bassImpact)
         * exp(-(p.x * p.x * 6.0 + p.y * p.y * 90.0) * 2.5) * (0.35 + 0.4 * u.bassImpact);

    col *= 0.22 + 0.78 * smoothstep(1.55, 0.30, length(p));
    // colour floor: dim red stripes and gold frame tails keep some green and
    // blue, so nothing settles into pure saturated red
    col.g = max(col.g, col.r * 0.15);
    col.b = max(col.b, col.r * 0.20);
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.68),
                        0.003 + 0.002 * u.bassImpact, 0.001);
    return col; // LINEAR HDR — post chain tonemaps
}
