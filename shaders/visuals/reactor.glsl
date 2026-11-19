// SPDX-License-Identifier: AGPL-3.0-only
// Reactor — central fusion core with orbiting spectrum arcs.
// Analytic polar geometry; no raymarch.
// param0 = Core ; param1 = Orbit Count ; param2 = Sparks
//
// Flash budget: the visual keeps within the general flash limit itself under loud audio. Brightness
// follows a slow beat swell (about 150 ms rise, the rest of the beat to fall) and the spectrum's
// level, never the instant-attack kick, onset or beat envelopes, nor the palette roles that follow
// them or the wrapping beatPhase. The spectrum (kick included) shows as ring wobble and dash
// length. The rings keep their radius when the core swells, their dashes keep a lit line under
// them and counter-rotate slowly, so no large area flips between dark and bright.

// Beat swell: 0 on the beat, up over the first 30% of the beat, back down by the next one.
float reactorSwell(VisualUniforms u) {
    float x = u.beatPhase;
    return smoothstep(0.0, 0.3, x) * (1.0 - smoothstep(0.3, 1.0, x));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    const float SPOKE_COUNT = 8.0;
    // Continuous beat clock for everything that scrolls with the beat:
    // beatPhase alone wraps each beat and jumped every arc cell at once.
    float beatClock = u.beatCount + u.beatPhase;
    float swell = reactorSwell(u) * clamp(u.level * 1.2, 0.0, 1.0);

    vec2 p = motionCentered(uv, u);
    p = rot2(0.18 + sin(beatClock * 0.7854) * 0.03) * p;
    p.y /= 0.86;
    float r = length(p);
    float a = atan2_(p.y, p.x);
    float ang = a / 6.2831853 + 0.5;

    float core0 = mix(0.12, 0.25, u.param0);
    float core = core0 + swell * 0.008;
    float orbitCount = mix(3.0, 8.0, u.param1);
    float sparkAmt = mix(0.4, 1.7, u.param2);

    vec3 glow = vec3(0.0);

    float coreFill = exp(-r * r / max(core * core, 1e-4));
    vec3 fog = palVisual(0.62, u);
    fog = mix(vec3(luma(fog) * 0.62), fog, 0.42);
    glow += fog * coreFill * (0.14 + u.level * 0.34 + swell * 0.06);
    vec3 rim = mix(palVisual(0.65, u), palVisual(0.13, u), 0.7);
    glow += rim * aaLine(r - core, 0.006) * (1.1 + 0.5 * swell);

    for (int k = 0; k < 8; k++) {
        if (float(k) >= orbitCount) break;
        float fk = float(k);
        float dir = mod(fk, 2.0) < 0.5 ? 1.0 : -1.0;
        float rr = core0 + 0.08 + fk * 0.085;
        float bandv = bandAtWrapped(u, fk / 8.0 + ang * SPOKE_COUNT + beatClock * 0.05);
        // The kick shows as the ring's wobble, not its brightness.
        float wobble = sin(a * (3.0 + fk) + u.time * (0.5 + fk * 0.07) * dir) * (0.003 + 0.007 * bandv);
        float line = aaLine(r - rr - wobble, 0.0042);
        float cell = fract(ang * (18.0 + fk * 2.0) - dir * (u.time * 0.03 + beatClock * (0.09 + fk * 0.015)) - fk * 0.13);
        // Spectrum arcs: louder bands draw longer dashes.
        float dashEnd = mix(0.38, 0.82, clamp(bandv, 0.0, 1.0));
        float dash = smoothstep(0.02, 0.10, cell) * smoothstep(dashEnd, dashEnd - 0.14, cell);
        float arc = mix(0.24, 1.0, dash);
        float lift = 0.45 + 0.75 * sqrt(clamp(u.level, 0.0, 1.0)) + 0.3 * swell;
        vec3 c = palVisual(ang + fk * 0.09 + beatClock * 0.02, u);
        glow += c * line * arc * lift * (0.7 + 0.3 * smoothstep(0.0, 1.0, bandv));
    }

    for (int i = 0; i < 34; i++) {
        float fi = float(i);
        float h = hash11(fi * 1.73);
        float life = fract(h + u.time * (0.12 + h * 0.3) + beatClock * 0.04);
        float aa = h * 6.2831853 + life * 0.8;
        float sr = mix(core0, 1.45, life);
        vec2 sp = vec2(cos(aa), sin(aa) * 0.86) * sr;
        float d = length(p - sp);
        float spark = min(1.2, 0.00018 / (d * d + 0.00035));
        float fade = smoothstep(0.0, 0.08, life) * (1.0 - life);
        glow += palVisual(0.62 + h * 0.28, u) * spark * fade
              * (0.25 + 0.45 * u.level + 0.35 * swell) * sparkAmt;
    }

    glow = accentize(glow, u.accent, 0.12);
    vec3 col = feedbackTrail(glow, uv,
                             min(u.trailDecay, 0.86),
                             0.0025 + 0.0012 * swell,
                             0.0015 + 0.0008 * swell);
    return col; // LINEAR HDR — post chain tonemaps
}
