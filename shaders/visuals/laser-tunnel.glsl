// SPDX-License-Identifier: AGPL-3.0-only
// Laser Tunnel — hard-vector wireframe flythrough.
// Identity: polygonal laser frames and
// corner rails rushing past — pure vector lines with HDR cores, faint
// band-lit wall fill, a rotating sweep beam. Deliberately distinct from
// Tunnel/Event Horizon: no volumetric disc, no circular equalizer.
// param0 = Speed ; param1 = Sides ; param2 = Rail Glow

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float speed = mix(0.35, 1.5, u.param0);   // capped: frame passes are what flicker
    float sidesF = floor(mix(4.0, 8.0, u.param1) + 0.5);
    float railGlow = mix(0.8, 3.0, u.param2);

    // gentle flight-path wobble
    p += vec2(sin(u.time * 0.37), cos(u.time * 0.29)) * 0.07;
    p = rot2(0.06 * sin(u.time * 0.22)) * p;

    float a = atan2_(p.y, p.x) + u.time * 0.05;
    float sector = 6.2831853 / sidesF;
    float faceId = floor((a + 3.14159265) / sector);
    float am = a + 3.14159265 - (faceId + 0.5) * sector; // wedge-local angle

    // polygon-metric radius (flat walls)
    float rPoly = length(p) * cos(am);
    float rp = max(rPoly, 0.035);

    float z = 1.0 / rp;                 // depth down the tunnel
    // a small forward lunge on the kick: the full 0.35 jumped every frame at
    // once, a full-screen flash; with only every 4th frame bright this moves
    // the tunnel on the beat without flashing it
    float zt = z + u.time * speed * 2.2 + u.bassImpact * 0.12;
    float fog = exp(-z * 0.11);         // distance haze -> deep black throat

    vec3 col = vec3(0.0);

    // ---- polygonal laser frames ----
    float cell = fract(zt);
    float seg = floor(zt);
    float dz = cell - 0.5;
    float frameLine = aaLine(dz * rp * 2.2, 0.0035);         // crisp core
    float hueF = fract(seg * 0.061 + 0.02 * u.time + 0.08 * u.spectralCentroid);
    vec3 fc = palVisual(hueF, u);
    fc = accentize(fc, u.accent, 0.12);
    // Only every 4th frame (the "checkpoint") burns bright; the frames between
    // are dim ghosts. Every frame sweeps every pixel as it rushes past, so
    // bright frames at full rate flickered the whole tunnel ~7 times a second.
    float major = step(mod(seg, 4.0), 0.5);
    float frameHalo = exp(-abs(dz) * 14.0) * 0.07 * major;    // soft spill
    float frameE = mix(0.04, 2.0 + 1.2 * u.amplitude, major) * fog;
    // frames rushing past the lens sweep huge areas: let them fade out first
    frameE *= smoothstep(1.35, 0.6, rp);
    // and the throat, where frames crowd into a shimmering moire
    frameE *= smoothstep(0.07, 0.22, rp);
    col += fc * (frameLine + frameHalo) * frameE;
    // the checkpoint's core slams on the beat (a thin line, not an area)
    col += peakWhite(fc, 0.5) * frameLine * major * u.bassImpact * fog * 2.0;

    // ---- corner rails running to the vanishing point ----
    float dCorner = (abs(am) - sector * 0.5) * length(p);   // signed screen distance
    float rail = aaLine(dCorner, 0.0026);
    float railHalo = exp(-abs(dCorner) * 55.0) * 0.5;
    int rb = int(mod(faceId, sidesF));
    float railBand = band(u, (rb * 7 + 8) % 64);
    vec3 rc = palRoleTreble(fract(faceId * 0.13 + 0.03 * u.time), u);
    col += rc * (rail + railHalo) * railGlow * (1.2 + 3.0 * railBand) * fog;

    // ---- faint band-lit wall fill (gives the frames a room to live in) ----
    // steady per face (no per-frame sawtooth or hue step: those blinked whole walls)
    float wallBand = band(u, (rb * 9 + 4) % 64);
    float wallShade = 0.025 + 0.05 * wallBand * wallBand;
    col += palVisual(fract(zt * 0.015 + 0.02 * u.time) + 0.35, u) * wallShade * fog;

    // ---- rotating sweep laser (radar arm) ----
    float sweepA = a - u.time * 0.8;
    // a narrow, moderate beam: a wide bright wedge wiping the frame flickers
    float sweep = exp(-(sin(sweepA * 0.5))*(sin(sweepA * 0.5)) * 600.0);
    col += palRolePeak(0.65, u) * sweep * fog * (0.4 + 1.2 * u.treble) * smoothstep(0.05, 0.4, rp);

    // ---- beat shock frame racing down the tunnel ----
    float waveZ = fract(zt * 0.25 - u.beatPhase);
    float shock = exp(-waveZ * waveZ * 90.0);
    col += palRoleBass(0.1, u) * shock * fog * u.bassImpact * 0.5;

    // vanishing-point black core + outer falloff
    col *= smoothstep(0.015, 0.06, rp);
    col *= 1.0 - smoothstep(1.15, 1.7, length(p)) * 0.9;

    // warp streaks, short and nearly still: a zoomed, rotated trail ghosted
    // every frame ring into moire that flickered the whole tunnel
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.45),
                        0.002 + 0.002 * u.bassImpact, 0.0);
    return col; // LINEAR HDR
}
