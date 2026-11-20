// SPDX-License-Identifier: AGPL-3.0-only
// Tunnel "Event Horizon".
// A tilted polar tunnel: concentric rings fly toward a black core, a circular
// spectrum equalizer rings the void, the beat throws radial spikes, embers
// stream outward, feedback zoom makes warp trails.
// param0 = Flight Speed ; param1 = Twist ; param2 = Ring Detail
//
// Flash budget (CORE-2659): under loud audio the visual keeps within the
// general flash limit on its own. The pastel equalizer disc and the ray burst
// are bright but steady; the music moves things (ring surge, tick tips, ray
// reach, embers) instead of switching large areas bright and dark,
// beat-driven reach has a ~200 ms attack, and palette reads stay off the red
// end of the ramp so nothing large turns red and back.

// Mirror the palette coordinate into [0, 0.74]: continuous, and clear of the
// red stop at the top of the default ramp.
vec3 tunnelPal(float t, VisualUniforms u) {
    return palVisual(0.74 * abs(fract(t) * 2.0 - 1.0), u);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    p = rot2(0.20) * p;     // tilt the disc
    p.y /= 0.80;            // perspective squash

    float r = length(p);
    float a = atan2_(p.y, p.x);
    float ang01 = a / 6.2831853 + 0.5;        // 0..1 around the ring

    float speed  = mix(0.3, 1.8, u.param0);
    float twist  = mix(0.0, 2.5, u.param1);
    // integer cell count: ang01 wraps 1->0 on the -x axis, so a non-integer
    // angular multiplier leaves one malformed cell there (contract rule 13).
    float detail = floor(mix(8.0, 28.0, u.param2) + 0.5);

    vec3 col = vec3(0.0);

    // beat count that surges after each beat and never jumps back at the wrap;
    // the surge takes 40% of a beat (200 ms at 120 BPM), so it reads as a push
    float beatSurge = floor(u.beatCount) + smoothstep(0.0, 0.4, u.beatPhase);
    // beat envelope for the spikes: ~200 ms rise, release over the rest of the beat
    float beatEnv = smoothstep(0.0, 0.4, u.beatPhase) * (1.0 - smoothstep(0.4, 1.0, u.beatPhase));

    // radius window: keep the action in a ring band, fade to black elsewhere
    float band01 = smoothstep(0.12, 0.22, r) * (1.0 - smoothstep(0.85, 1.25, r));

    // ---- flythrough concentric rings ----
    // Thin in screen space at every radius (depth changes as 1/r^2), so the
    // outer rings sweep past as lines rather than wide bands. Every pixel sees
    // a ring pass about once a second, so the rings stay bright only in the
    // small throat inside the equalizer and fade to faint guides beyond it:
    // bright rings over the whole band were ~30 large-area flashes a second.
    float depth = 1.0 / max(r, 0.05) + u.time * speed + beatSurge * 0.12;
    float ringD = abs(fract(depth) - 0.5) * r * r;
    float ringLine = aaLine(ringD, 0.0035) * band01;
    vec3 ringCol = tunnelPal(floor(depth) * 0.17 + ang01 * 0.1 + 0.02 * u.time, u);
    col += ringCol * ringLine * mix(0.9, 0.06, smoothstep(0.2, 0.36, r));

    // ---- circular spectrum equalizer around a base radius ----
    float baseR = 0.40;
    int   bi = int(ang01 * float(NBANDS)) % NBANDS;
    float bandH = band(u, bi);
    // A wide, steady pastel disc: the inner part of every tick is always lit
    // at a constant HDR level (bright is fine, it is change that flashes);
    // the music only moves the soft tip in and out a little.
    float tickOuter = baseR + 0.20 + bandH * 0.16;
    float h = r - baseR;
    float cell = fract(ang01 * detail * 2.0);
    float cellMask = smoothstep(0.0, 0.10, cell) * smoothstep(1.0, 0.90, cell);
    float body = smoothstep(-0.004, 0.004, h) * (1.0 - smoothstep(tickOuter - 0.05, tickOuter, r));
    vec3 tickCol = tunnelPal(ang01 + 0.1 * u.spectralCentroid, u);
    tickCol = accentize(tickCol, u.accent, 0.15);
    // pastel: lift toward white, brightest at the inner edge
    vec3 discCol = mix(tickCol, vec3(1.0), 0.18);
    col += discCol * body * mix(0.55, 1.0, cellMask) * (0.95 + 1.1 * exp(-h * 7.0));
    float cap = aaLine(r - (tickOuter - 0.012), 0.008) * cellMask;
    col += mix(tickCol, vec3(1.0), 0.25) * cap * 1.2;

    // base rim line at the equalizer radius
    col += tunnelPal(ang01, u) * aaLine(r - baseR, 0.004) * 2.0;

    // ---- radial ray burst: long thin rays, always out; the beat stretches them ----
    float spikeCell = fract(ang01 * 24.0);
    // screen-space width, so the rays stay thin lines out to the edge
    float spikeArc = abs(spikeCell - 0.5) * (6.2831853 / 24.0) * r;
    float spike = aaLine(spikeArc, 0.005) * step(baseR, r);
    float reach = 1.45 + 0.25 * beatEnv * (0.4 + 0.6 * u.bass);
    float spikeFade = 1.0 - smoothstep(baseR + 0.2, reach, r);
    col += tunnelPal(ang01 + 0.25, u) * spike * spikeFade * 1.3;

    // ---- ember sparks streaming outward ----
    for (int i = 0; i < 44; i++) {
        float fi = float(i);
        vec2 hh = hash22(vec2(fi, 7.0));
        float sa = hh.x * 6.2831853 + 0.3 * sin(u.time * 0.2 + fi);
        float life = fract(hh.y + u.time * (0.15 + 0.45 * hh.x) + beatSurge * 0.07);
        float sr = mix(baseR, 1.7, life);
        vec2 sp = vec2(cos(sa), sin(sa)) * sr;
        float d = length(p - sp);
        float spark = min(2.0, 0.0003 / (d * d + 3e-4));
        vec3 sparkCol = tunnelPal(hh.x, u);
        sparkCol = peakWhite(sparkCol, u.treble * (1.0 - life) * 0.18);
        col += sparkCol * spark * (1.0 - life) * (0.5 + u.treble * 1.5);
    }

    // ---- black event-horizon core + inner rim glow ----
    col *= smoothstep(0.0, 0.18, r);
    col += tunnelPal(0.72, u) * aaLine(r - 0.16, 0.012) * (1.2 + 0.4 * u.level);

    // ---- stable feedback warp trails (subtle zoom -> content flies outward) ----
    // Constant zoom and twist: a kick-driven zoom moved the whole trail field at once.
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.86), 0.004, 0.003 * twist);

    return col; // LINEAR HDR — post chain tonemaps
}
