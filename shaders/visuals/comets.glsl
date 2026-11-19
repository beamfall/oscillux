// SPDX-License-Identifier: AGPL-3.0-only
// Comets — frequency + beat.
//
// Orbital comet trails crossing a dark stage.
// 56 analytic comets with short tails.
// param0 Count, param1 Orbit Spread, param2 Tail Length

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float count  = mix(24.0, 56.0, u.param0);
    float spread = mix(0.42, 1.20, u.param1);
    float tail   = mix(0.10, 0.34, u.param2);
    vec3 glow = vec3(0.0);
    // beat count that surges after each beat and never jumps back at the wrap
    // (beatPhase alone snapped every comet back along its orbit once a beat)
    float beatSurge = floor(u.beatCount) + 1.0 - pow(1.0 - u.beatPhase, 3.0);

    for (int i = 0; i < 56; i++) {
        if (float(i) >= count) break;
        float fi = float(i);
        vec2 h = hash22(vec2(fi * 1.73, 3.0));
        float bandv = bandAtWrapped(u, h.x + u.beatPhase * 0.10);
        float phasePush = phasePulse(u, h.x, 0.20);
        float life = fract(h.y + u.time * (0.06 + 0.30 * h.x) + beatSurge * (0.02 + h.x * 0.04));
        float a = h.x * 6.2831853 + life * 6.2831853 * (0.35 + h.y) + sin(beatRadians(u, h.y)) * 0.08;
        float rr = mix(0.16, spread, h.y) * (0.75 + bandv * 0.42 + u.bassImpact * 0.08 + phasePush * 0.08);
        vec2 pos = vec2(cos(a) * rr, sin(a) * rr * 0.62);
        vec2 tangent = normalize(vec2(-sin(a), cos(a) * 0.62) + 1e-5);

        vec2 v = p - pos;
        float along = dot(v, tangent);
        float across = length(v - tangent * along);
        float head = min(1.6, 0.00022 / (dot(v, v) + 0.00022));
        float trail = exp(-across * across * 900.0) * smoothstep(-tail, 0.0, along) * (1.0 - smoothstep(0.0, 0.08, along));
        vec3 c = palRoleTrace(h.x + 0.16 * u.spectralCentroid + u.beatPhase * 0.10, u);
        glow += c * (head * (0.40 + bandv * 2.2 + phasePush * 0.28 + u.onset * 0.25) + trail * (0.10 + bandv * 1.25 + phasePush * 0.16 + u.beat * 0.10));
    }

    float core = aaLine(length(p) - (0.22 + u.bassImpact * 0.025), 0.003);
    glow += palRoleFog(0.58 + 0.1 * u.spectralCentroid, u) * core * (0.45 + u.bassImpact * 1.3 + u.onset * 0.5);

    vec3 col = feedbackTrail(glow, uv,
                             min(u.trailDecay, 0.90),
                             0.002 + 0.002 * u.bassImpact,
                             0.001 * u.beat);
    return col; // LINEAR HDR — post chain tonemaps
}
