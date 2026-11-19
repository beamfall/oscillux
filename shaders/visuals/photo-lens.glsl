// SPDX-License-Identifier: AGPL-3.0-only
// Shattered Lens Kaleidoscope — the photo folded through a mirrored lens with
// chromatic dispersion at the fold lines; a dim unfolded photo sits behind the
// glass so the subject never disappears. Glints spark on the shard seams.
// param0 = Segments ; param1 = Spin ; param2 = Glints
//
// Flash budget (CORE-2659): the music moves the lens (a beat-eased turn, zoom
// breath and ring swell) instead of flashing it. Nothing follows the instant
// kick (bass, bassImpact, onset): the beat swell rises over ~170 ms and falls
// over the rest of the beat, the rings drift slowly on time rather than sweep a
// ring a beat, and the seams are a tint within the photo's brightness band, so
// no large area changes luminance faster than the source flash limit allows.

float ringLine(float r, float target, float w) {
    return aaLine(r - target, w);
}

// Beat swell: 0 at the beat, eased up over the first 35 % of it, eased back
// down by the next beat. Continuous across the beatPhase wrap.
float lensSwell(VisualUniforms u) {
    float x = u.beatPhase;
    return smoothstep(0.0, 0.35, x) * (1.0 - smoothstep(0.35, 1.0, x));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float r = length(p);
    float sw = lensSwell(u);
    float a = atan2_(p.y, p.x) + u.time * (0.05 + u.param1 * 0.12) + sw * 0.04;
    float segs = 8.0 + floor(u.param0 * 8.0);
    float glints = mix(0.4, 1.8, u.param2);

    float sector = 6.2831853 / segs;
    float ma = abs(fract(a / sector + 0.5) - 0.5) * sector;
    vec2 q = vec2(cos(ma), sin(ma)) * r;

    // kaleidoscope sample with chromatic dispersion along the fold direction
    float zoomB = 0.62 + 0.14 * sin(u.time * 0.10) + 0.05 * sw;
    vec2 base = q * zoomB + 0.5;
    vec2 cdir = q / max(r, 1e-3) * (0.006 + 0.010 * u.treble);
    float cr = IMG(photoCover(fract(base + cdir), u.resolution, IMGSIZE)).r;
    float cg = IMG(photoCover(fract(base), u.resolution, IMGSIZE)).g;
    float cb = IMG(photoCover(fract(base - cdir), u.resolution, IMGSIZE)).b;
    vec3 photo = max(vec3(cr, cg, cb), vec3(0.0));

    float lens = smoothstep(0.98, 0.25, r);
    // dim untouched photo behind the glass keeps the subject present
    vec3 back = max(IMG(photoCover(clamp(uv, 0.0, 1.0), u.resolution, IMGSIZE)).rgb, vec3(0.0));
    vec3 col = back * 0.11 * (1.0 - lens);
    col += photo * lens * (0.48 + 0.16 * u.level + 0.10 * sw);

    // shard seams + slow-drifting rings: a palette tint over the glass, kept
    // within the photo's brightness band so their motion never strobes
    float seam = aaLineCyclic(a * segs / 6.2831853, 0.03);
    float ring = aaLineCyclic(r * 5.0 - u.time * 0.06, 0.04);
    float shard = max(seam, ring * 0.7);
    vec3 tint = palVisual(fract(a / 6.2831853 + 0.5 + 0.08 * sw), u);
    col = mix(col, tint * (0.55 + 0.10 * sw), shard * lens * 0.45 * min(glints, 1.2));
    col += tint * shard * lens * glints * (0.05 + 0.06 * u.treble);

    // the lens rim breathes with the beat; sparks where seams cross it
    float ringD = ringLine(r, 0.58 + 0.015 * sw, 0.005);
    col += palVisual(0.6 + 0.1 * sw, u) * ringD * (0.55 + 0.6 * sw) * glints;
    col += vec3(1.0, 0.97, 0.92) * seam * ringD * glints * (0.35 + 0.30 * u.treble);

    col *= 1.0 - smoothstep(1.02, 1.45, r) * 0.75;
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.72), 0.004, 0.006);
    return col; // LINEAR HDR — post chain tonemaps
}
