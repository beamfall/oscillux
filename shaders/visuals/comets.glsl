// SPDX-License-Identifier: AGPL-3.0-only
// Comets — frequency + beat.
//
// Orbital comet trails crossing a dark stage.
// 56 analytic comets with tails that follow their orbits over a glowing disc.
// param0 Count, param1 Orbit Spread, param2 Tail Length
//
// Flash budget (CORE-2659): the music moves the comets (an eased surge along the orbit on each
// beat, tails that stretch with their band) and colours them; it does not flash them. The swirl's
// size and brightness are steady: a glowing disc under the swarm and long tails cost nothing in
// flashes, because a pixel transitions only where something bright arrives or leaves. What does
// cost is the bright front each head sweeps, so heads keep a bright core with a modest halo,
// orbits stay put on the beat and the swarm moves at an unhurried pace. Every audio term is
// continuous across the beat wrap, comets fade in and out over their life instead of jumping
// back along the orbit, and no colour is left saturated red.

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
    // beat count that surges, eased, over most of each beat and is continuous at the wrap
    float beatSurge = floor(u.beatCount) + smoothstep(0.0, 0.80, ph);
    // a breath on the beat: rises over ~35% of the beat, releases over the rest, 0 at the wrap
    float swell = smoothstep(0.0, 0.35, ph) * (1.0 - smoothstep(0.35, 1.0, ph));
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
        float run = h.y + u.time * (0.014 + 0.06 * h.x) + beatSurge * (0.004 + h.x * 0.008);
        float life = fract(run);
        // born and gone gradually over each lap of life, so the wrap never shows
        float alive = smoothstep(0.0, 0.08, life) * (1.0 - smoothstep(0.86, 1.0, life));
        float a = h.x * 6.2831853 + life * 6.2831853 * (0.35 + h.y);
        // orbits do not breathe on the beat: every tail shifting at once is a large-area flash
        float rr = mix(0.18, spread, h.y) * (1.08 + 0.06 * h.x);
        vec2 pos = vec2(cos(a) * rr, sin(a) * rr * 0.62);

        vec2 v = p - pos;
        float d2 = dot(v, v);
        // a hot core, a halo and a faint wide glow too dim to count as a flash where it sweeps
        float head = exp(-d2 * 3200.0) + 0.45 * exp(-d2 * 420.0) + 0.05 * exp(-d2 * 90.0);
        // the tail: arc length back along the orbit behind the head, thinning as it fades
        float tl = tail * (2.5 + 0.5 * bandv);
        float back = mod(a - qa, 6.2831853) * rr / tl;
        float across = (qr - rr) * (1.0 + 1.2 * back);
        float trail = (exp(-across * across * 700.0) + 0.15 * exp(-across * across * 120.0))
                    * pow(1.0 - smoothstep(0.0, 1.0, back), 1.2);
        vec3 c = palVisual(h.x + 0.16 * u.spectralCentroid + 0.004 * u.time, u);
        glow += c * alive * (head * (2.1 + 0.20 * swell) + trail * 1.3);
    }

    // the disc the comets orbit: a steady glow under the swarm, so the swirl stays large and bright
    // without anything flashing; its spiral arms turn slowly and only shade it
    float disc = smoothstep(0.10, 0.34, qr) * (1.0 - smoothstep(spread * 0.70, spread * 1.25, qr));
    float arms = 0.5 + 0.5 * cos(2.0 * qa - 7.0 * qr + 0.30 * u.time);
    vec3 bed = palVisual(0.30 * cos(qa - 0.12 * u.time) + 0.45 * qr + 0.004 * u.time, u);
    glow += bed * disc * (0.07 + 0.10 * arms);

    float core = aaLine(length(p) - 0.22, 0.003);
    glow += palRoleFog(0.58 + 0.1 * u.spectralCentroid, u) * core * (0.40 + 0.20 * swell);

    // a dim night floor: keeps green and blue off zero, so a warm edge fading into the dark is
    // never quantised to pure red
    glow = cometNoRed(glow) + vec3(0.006, 0.008, 0.014);
    vec3 col = feedbackTrail(glow, uv,
                             min(u.trailDecay, 0.88),
                             0.002,
                             0.0);
    return col; // LINEAR HDR — post chain tonemaps
}
