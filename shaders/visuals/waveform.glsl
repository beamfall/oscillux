// SPDX-License-Identifier: AGPL-3.0-only
// Waveform / prismatic oscilloscope threads.
// param0 Thickness ; param1 Trail Length ; param2 Trace Stack
//
// Flash budget: a stack of bright threads covers much of the band it sits in, so anything that
// moves or brightens every thread at once in a few frames is a large-area flash. The music drives
// the threads through a beat envelope with a ~170 ms attack and a long release, slow drift and the
// spectrum's shape; per-frame levels (kick, onset, flux) and beatPhase's wrap drive nothing.

// Smooth beat swell: 0 at the beat wrap, rising over ~0.35 beat to its peak just after the beat,
// releasing over the rest. Continuous across beatPhase's 1 -> 0 wrap.
float waveformSwell(float beatPhase) {
    float t = fract(beatPhase + 0.30);
    return smoothstep(0.0, 0.35, t) * (1.0 - smoothstep(0.35, 1.0, t));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);

    float thickness = mix(0.0015, 0.0050, u.param0);
    int traces = int(mix(7.0, 17.0, u.param2) + 0.5);
    float trailDec = clamp(mix(0.70, 0.88, u.param1), 0.0, 0.88);
    float swell = waveformSwell(u.beatPhase);
    float level = saturate(u.level);

    vec3 glow = vec3(0.0);

    for (int ti = 0; ti < 17; ti++) {
        if (ti >= traces) break;
        float fi = float(ti);
        float layer = (fi - float(traces - 1) * 0.5) / max(float(traces), 1.0);
        float yOff = layer * mix(0.30, 0.70, u.param2);

        float x01 = uv.x;
        float bandA = bandAt(u, fract(x01 * 0.78 + fi * 0.037));
        float bandB = bandAt(u, fract(x01 * 0.33 + 0.22 + fi * 0.051));
        // Loudness sets the swing; the beat swell adds a gentle breath on top. The spectrum only
        // shapes the swing along x, at a weight that keeps a kick's jump under a pixel or two.
        float amp = (0.10 + 0.22 * level) * (0.88 + 0.12 * bandA) * (0.96 + 0.06 * swell);

        float wave = sin(x01 * (7.0 + fi * 0.9) + u.time * (0.22 + fi * 0.014)) * 0.36;
        wave += sin(x01 * (19.0 + fi * 0.6) - u.time * 0.40 + bandB * 0.6) * 0.16;
        wave += sin(x01 * 31.0 + u.time * 0.8) * 0.025 * u.treble;

        float y = yOff + wave * amp;
        float d = p.y - y;
        bool centre = ti == traces / 2;
        float line = aaLine(d, thickness * (centre ? 1.7 : 1.0));
        float halo = aaLine(d, thickness * 5.5) * 0.18;

        // The beat travels as colour: hue drifts with the spectrum and the swell, at one brightness.
        float hue = fract(x01 * 0.86 + fi / 17.0 * 0.35 + 0.12 * u.spectralCentroid + 0.03 * swell);
        // palVisual, not palRoleTrace: its beatPhase hue offset snaps back at every beat.
        vec3 c = palVisual(hue, u);
        c = accentize(c, u.accent, 0.08);

        float focus = 1.0 - min(1.0, abs(layer) * 1.9);
        float bright = 1.5 + 0.6 * level;
        glow += c * (line * bright + halo * (0.45 + 0.4 * level)) * (0.28 + 0.72 * focus);

        // Beat pulse: a short bright bead riding the centre thread, fading in and out with the swell.
        if (centre) {
            float bx = uv.x - u.beatPhase;
            float bead = exp(-bx * bx * 260.0) * sin(3.14159265 * u.beatPhase);
            glow += palVisual(0.12, u) * bead * (line * 1.6 + halo * 2.0) * (0.5 + 0.5 * level);
        }
    }

    // Spectral needles: slim vertical pins that live a few seconds each, fade in and out, drift,
    // and stretch with the treble and the beat swell. Each has its own phase, so they never pop
    // together, and a pin only moves its tip from frame to frame.
    for (int i = 0; i < 14; i++) {
        float fi = float(i);
        float life = u.time / 3.2 + hash11(fi * 7.13);
        float cycle = floor(life);
        float age = life - cycle;
        float fade = sin(3.14159265 * age);
        fade *= fade;
        vec2 h = hash22(vec2(fi, cycle + 3.0));
        float x = fract(h.x + 0.015 * age);
        float dx = abs(uv.x - x);
        float stretch = 0.65 + 0.35 * waveformSwell(u.beatPhase + 0.18 * h.y);
        float len = (0.04 + 0.12 * h.y) * (0.55 + 0.45 * u.treble) * stretch;
        float y0 = 0.5 + 0.12 * sin(x * 8.0 + u.time * 0.4);
        float inY = smoothstep(y0 - len - 0.01, y0 - len, uv.y) * (1.0 - smoothstep(y0 + len * 0.2, y0 + len * 0.2 + 0.01, uv.y));
        float pin = (1.0 - smoothstep(0.0008, 0.0035, dx)) * inY;
        glow += palVisual(x + 0.62 + 0.18 * u.spectralCentroid, u) * pin * fade * (0.55 + 0.35 * level);
    }

    vec3 col = feedbackTrail(glow, uv,
                             trailDec,
                             0.0025 + 0.0015 * swell,
                             0.0);

    // The palette's warm end reaches orange-red, which reads as saturated red (linear R > 4 (G + B))
    // as a thread sweeps across black, and a fading trail drops its green before its red, leaving a
    // dim red residue that turns the next gold or pink thread over it into a red transition. Lift
    // green under red, after the trail so the residue is caught too, until linear G + B is at least
    // 0.65 R: warm threads read gold, and the limiter sees no red to track.
    vec3 lin = pow(max(col, vec3(0.0)), vec3(2.2));
    float need = 0.65 * lin.r - lin.g - lin.b;
    if (need > 0.0) col.g = pow(lin.g + need, 1.0 / 2.2);
    // Below a few codes the 8-bit frame rounds green to zero before red, so the last of a trail is
    // pure dim red; end trails at black instead.
    col *= smoothstep(0.012, 0.035, max(col.r, max(col.g, col.b)));
    return col;
}
