// SPDX-License-Identifier: AGPL-3.0-only
// Comets — frequency + beat.
//
// Orbital comet trails crossing a dark stage.
// 56 analytic comets with short tails.
// param0 Count, param1 Orbit Spread, param2 Tail Length
//
// Flash budget (CORE-2659): the music moves the comets (a surge along the orbit on each beat, a
// slow breath of the orbits) and colours them; it does not flash them. Every audio term that
// reaches brightness or position is continuous across the beat wrap and eased (>= ~150 ms
// attack), heads are small so a passing comet lights few pixels, comets fade in and out over
// their life instead of jumping back along the orbit, and no colour is left saturated red.

// Lifts green over a red-dominant colour so nothing reads as saturated red (linear R share of
// R+G+B stays under 0.75 after the tonemap toe); orange becomes amber, magenta and the rest are unchanged.
vec3 cometNoRed(vec3 c) {
    c = max(c, vec3(0.0));
    c.g = max(c.g, c.r * 0.55 - c.b);
    return c;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float count  = mix(24.0, 56.0, u.param0);
    float spread = mix(0.42, 1.20, u.param1);
    float tail   = mix(0.10, 0.34, u.param2);
    float ph = u.beatPhase;
    // beat count that surges, eased, over the first part of each beat and is continuous at the wrap
    float beatSurge = floor(u.beatCount) + smoothstep(0.0, 0.55, ph);
    // a breath on the beat: rises over ~35% of the beat, releases over the rest, 0 at the wrap
    float swell = smoothstep(0.0, 0.35, ph) * (1.0 - smoothstep(0.35, 1.0, ph));
    float energy = saturate(u.level);
    vec3 glow = vec3(0.0);
    // orbit space: the orbits are ellipses squashed 0.62 in y, circles here, so a tail can follow
    // its orbit back from the head instead of leaving it along a straight tangent
    vec2 q = vec2(p.x, p.y / 0.62);
    float qr = length(q);
    float qa = atan(q.y, q.x);

    for (int i = 0; i < 56; i++) {
        if (float(i) >= count) break;
        float fi = float(i);
        vec2 h = hash22(vec2(fi * 1.73, 3.0));
        float bandv = bandAtWrapped(u, h.x);
        float run = h.y + u.time * (0.025 + 0.10 * h.x) + beatSurge * (0.010 + h.x * 0.020);
        float life = fract(run);
        // born and gone gradually over each lap of life, so the wrap never shows
        float alive = smoothstep(0.0, 0.12, life) * (1.0 - smoothstep(0.80, 1.0, life));
        float a = h.x * 6.2831853 + life * 6.2831853 * (0.35 + h.y);
        float rr = mix(0.16, spread, h.y) * (0.93 + 0.035 * swell * (0.5 + energy) + 0.04 * h.x);
        vec2 pos = vec2(cos(a) * rr, sin(a) * rr * 0.62);

        vec2 v = p - pos;
        float d2 = dot(v, v);
        float head = exp(-d2 * 9000.0) + 0.10 * exp(-d2 * 900.0);
        // the tail: arc length back along the orbit behind the head, thinning as it fades
        float tl = tail * (0.75 + 0.35 * bandv);
        float back = mod(a - qa, 6.2831853) * rr / tl;
        float across = (qr - rr) * (1.0 + 1.2 * back);
        float trail = exp(-across * across * 1800.0) * pow(1.0 - smoothstep(0.0, 1.0, back), 1.5);
        vec3 c = palVisual(h.x + 0.16 * u.spectralCentroid + 0.004 * u.time, u);
        glow += c * alive * (head * (1.30 + 0.55 * bandv + 0.25 * swell) + trail * (0.45 + 0.55 * bandv));
    }

    float core = aaLine(length(p) - (0.22 + 0.012 * swell), 0.003);
    glow += palRoleFog(0.58 + 0.1 * u.spectralCentroid, u) * core * (0.40 + 0.20 * swell);

    // a dim night floor: keeps green and blue off zero, so a warm edge fading into the dark is
    // never quantised to pure red
    glow = cometNoRed(glow) + vec3(0.006, 0.008, 0.014);
    vec3 col = feedbackTrail(glow, uv,
                             min(u.trailDecay, 0.82),
                             0.0015,
                             0.0);
    return col; // LINEAR HDR — post chain tonemaps
}
