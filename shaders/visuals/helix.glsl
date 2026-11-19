// SPDX-License-Identifier: AGPL-3.0-only
// Helix — frequency + beat.
//
// Continuous spectral double-helix ribbons. Screen-space analytic strand
// fields; cheap and light on low-power GPUs.
// param0 Twist, param1 Depth, param2 Sparkle

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    p = rot2(-0.08) * p;

    float t = clamp((p.x + 1.55) / 3.10, 0.0, 1.0);
    float twist   = mix(2.0, 5.2, u.param0);
    float depth   = mix(0.28, 0.72, u.param1);
    float sparkle = mix(0.35, 1.5, u.param2);
    float bandv = bandAt(u, t);
    // Steady drift plus a beat-locked surge that is zero at both ends of the beat, so the helix
    // never jumps when beatPhase wraps. Beats move the strands; they do not flash them: the visual
    // keeps within the source flash budget (Makefile visual-flash-check) under loud audio.
    float phase = t * 6.2831853 * twist + u.time * 0.55
                + 0.4 * (smoothstep(0.0, 1.0, u.beatPhase) - u.beatPhase);

    float env = smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(0.88, 1.0, t));
    float amp = (0.17 + bandv * depth * 0.20) * env;
    float y1 = sin(phase) * amp;
    float y2 = -y1;
    float z1 = 0.55 + 0.45 * cos(phase);
    float z2 = 1.0 - z1;

    // Each strand is a flat tape wound on the helix: its edges are the same curve shifted along
    // the axis, so it is broad on the diagonals and pinches at the crests. The width is steady;
    // the music moves it rather than flashing it.
    float tape = (amp * abs(cos(phase)) * 0.42 + 0.010 * env) + 0.004;
    float d1 = abs(p.y - y1);
    float d2 = abs(p.y - y2);
    float fill1 = aaLine(d1, tape);
    float fill2 = aaLine(d2, tape);
    float core1 = aaLine(p.y - y1, 0.005 + bandv * 0.003);
    float core2 = aaLine(p.y - y2, 0.005 + bandv * 0.003);
    float halo1 = exp(-max(d1 - tape, 0.0) * 34.0);
    float halo2 = exp(-max(d2 - tape, 0.0) * 34.0);

    // The centroid only nudges the palette: a fast-moving white/cyan seam flips large cells.
    vec3 c1 = palRoleTrace(t + 0.04 * u.spectralCentroid, u);
    vec3 c2 = palRoleTrace(t + 0.50 + 0.04 * u.spectralCentroid, u);
    // Tape edges catch more light than its face, and the tapered tips fade out softly.
    float rim1 = fill1 * smoothstep(0.45, 1.0, d1 / tape);
    float rim2 = fill2 * smoothstep(0.45, 1.0, d2 / tape);
    float tip = 1.0 - 0.45 * (1.0 - smoothstep(0.06, 0.18, t)) - 0.45 * smoothstep(0.82, 0.95, t);
    float drive = 1.25 + bandv * 0.9 + (u.beat * 0.6 + u.bassImpact * 0.4) * 0.3;
    vec3 glow = c1 * ((fill1 * (0.45 + 0.65 * z1) + rim1 * 0.35) * drive * tip + core1 * 0.8 * z1 + halo1 * 0.42 * (0.4 + 0.6 * z1))
              + c2 * ((fill2 * (0.45 + 0.65 * z2) + rim2 * 0.35) * drive * tip + core2 * 0.8 * z2 + halo2 * 0.42 * (0.4 + 0.6 * z2));

    // Rungs: short segments between strands at discrete x cells.
    float cell = t * 28.0;
    float rungGate = aaLineCyclic(cell, 0.050);
    float between = step(min(y1, y2), p.y) * step(p.y, max(y1, y2));
    glow += palRoleFog(t + 0.2, u) * rungGate * between * (0.35 + bandv * 0.9 + u.beat * 0.2);

    // Spark nodes on beat/flux.
    float sparkCell = floor(t * 28.0);
    float sparkSeed = hash11(sparkCell + floor(u.beatCount));
    float sparkY = mix(y1, y2, step(0.5, sparkSeed));
    float spark = aaLineCyclic(cell, 0.040) * aaLine(p.y - sparkY, 0.025) * step(0.82, sparkSeed);
    glow += palRoleTreble(t + 0.08 * u.spectralCentroid, u) * spark * (u.onset + u.beat * 0.7 + u.bassImpact * 0.5) * sparkle * 4.0;

    vec3 col = feedbackTrail(glow, uv, min(u.trailDecay, 0.84), 0.002, 0.0);
    return col; // LINEAR HDR — post chain tonemaps
}
