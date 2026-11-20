// SPDX-License-Identifier: AGPL-3.0-only
// Laser Tunnel — hard-vector wireframe flythrough.
// Identity: polygonal laser frames and
// corner rails rushing past — pure vector lines with HDR cores, faint
// band-lit wall fill, a rotating sweep beam. Deliberately distinct from
// Tunnel/Event Horizon: no volumetric disc, no circular equalizer.
// param0 = Speed ; param1 = Sides ; param2 = Rail Glow

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float speed = mix(0.25, 1.1, u.param0);   // capped: frame passes are what flicker
    float sidesF = floor(mix(4.0, 8.0, u.param1) + 0.5);
    float railGlow = mix(0.8, 3.0, u.param2);

    // a slight flight-path wobble, and no spin: the rails' bright edges are
    // long lines, and moving them sideways made every edge pixel flicker
    p += vec2(sin(u.time * 0.37), cos(u.time * 0.29)) * 0.03;
    p = rot2(0.06 * sin(u.time * 0.22)) * p;

    float a = atan2_(p.y, p.x);
    float sector = 6.2831853 / sidesF;
    float faceId = floor((a + 3.14159265) / sector);
    float am = a + 3.14159265 - (faceId + 0.5) * sector; // wedge-local angle

    // polygon-metric radius (flat walls)
    float rPoly = length(p) * cos(am);
    float rp = max(rPoly, 0.035);

    float z = 1.0 / rp;                 // depth down the tunnel
    // The beat swell: 0 on the beat, rising over ~a third of the beat (~150 ms
    // at 120 bpm) and easing out by the next one, so it never steps. The raw
    // kick (bassImpact) jumps to full on the onset frame; anything it drove
    // over an area flashed the walls twice a beat.
    float swell = smoothstep(0.0, 0.3, u.beatPhase) * (1.0 - smoothstep(0.3, 1.0, u.beatPhase));
    swell *= saturate(0.35 + u.bassImpact + 0.5 * u.level);
    // constant flight speed: a surge on the beat jumped every frame line
    // forward at once, and the limiter held the old lines as ghost edges
    float zt = z + u.time * speed * 2.2;
    float fog = exp(-z * 0.11);         // distance haze -> deep black throat

    vec3 col = vec3(0.0);

    // ---- polygonal laser frames ----
    float cell = fract(zt);
    float seg = floor(zt);
    float dz = cell - 0.5;
    // crisp core; the width uses fwidth(zt), not of the fract: at the cell
    // wrap that read a full cell and drew a half-bright dashed ghost line that
    // crawled along every wall
    float frameLine = 1.0 - smoothstep(0.0035, 0.0035 + max(fwidth(zt) * rp * 2.2, 1e-4), abs(dz) * rp * 2.2);
    // The swell turns the frames' hue a little; it never changes their level.
    float hueF = fract(seg * 0.061 + 0.02 * u.time + 0.08 * u.spectralCentroid + 0.05 * swell);
    vec3 fc = palVisual(hueF, u);
    fc = accentize(fc, u.accent, 0.12);
    // Every frame is the same dim, thin line at a fixed luminance, so frames
    // recede down the tunnel and scroll toward the viewer while staying in one
    // brightness band: a pixel a frame crosses changes by less than one flash
    // step. Bright frames (and a beat heat on them) swept every pixel they
    // crossed and left the limiter holding doubled ghost edges. Every 4th
    // frame (the "checkpoint") is a touch brighter and whiter.
    float major = step(mod(seg, 4.0), 0.5);
    vec3 fcW = mix(fc, vec3(1.0), 0.35 * major);
    float fcLum = max(dot(fcW, vec3(0.2126, 0.7152, 0.0722)), 1e-3);
    float frameE = mix(0.07, 0.088, major) / fcLum * fog;
    // fade in from the throat, where frames crowd into a shimmering moire
    frameE *= smoothstep(0.07, 0.22, rp);
    col += fcW * frameLine * frameE;

    // ---- corner rails running to the vanishing point ----
    float dCorner = (abs(am) - sector * 0.5) * length(p);   // signed screen distance
    float rail = aaLine(dCorner, 0.0026);
    float railHalo = exp(-abs(dCorner) * 55.0) * 0.5;
    int rb = int(mod(faceId, sidesF));
    float railBand = band(u, (rb * 7 + 8) % 64);
    // the rails' halos cover the walls near the throat, so their level stays
    // steady: only a lean on the (instant) band, and not the treble role's
    // onset whitening, which lifted every halo on the onset frame
    vec3 rc = palVisual(0.62 + fract(faceId * 0.13 + 0.03 * u.time) * 0.28 + 0.10 * u.spectralCentroid, u);
    col += rc * (rail + railHalo) * railGlow * (1.0 + 0.3 * railBand + 0.7 * u.level) * fog;

    // ---- faint band-lit wall fill (gives the frames a room to live in) ----
    // steady per face (no per-frame sawtooth or hue step: those blinked whole walls),
    // and on the loudness, not a band: a band jumps on the kick, and a wall is a large area
    float wallBand = band(u, (rb * 9 + 4) % 64);
    float wallShade = 0.025 + 0.035 * u.level + 0.008 * wallBand;
    // a slight lift at each frame ring, scrolling with them (depth, not a flash)
    wallShade *= 1.0 + 0.3 * cos(6.2831853 * zt) * smoothstep(0.1, 0.3, rp);
    col += palVisual(fract(zt * 0.015 + 0.02 * u.time) + 0.35, u) * wallShade * fog;

    // ---- rotating sweep laser (radar arm) ----
    float sweepA = a - u.time * 0.4;   // one turn in ~16 s
    // a laser line of constant screen width: the soft white wedge it was took
    // every pixel it crossed through ten luminance steps up and back down
    float sweepD = abs(sin(sweepA * 0.5)) * 2.0 * length(p);   // screen distance from the arm
    float sweep = exp(-sweepD * sweepD * 9000.0) + 0.12 * exp(-sweepD * 60.0);
    // its colour skips the peak role's onset/kick whitening (a step over the
    // whole beam); the core warms with the swell instead
    vec3 sweepC = peakWhite(palVisual(0.65 + 0.08 * u.spectralCentroid, u), 0.3 * swell);
    col += sweepC * sweep * fog * (0.25 + 0.6 * u.treble) * smoothstep(0.05, 0.4, rp);

    // ---- beat shock frame racing down the tunnel ----
    // a thin frame, not a wall-wide band: the band lit a ring of wall at full
    // strength on the onset frame. It races off from the lens with the beat,
    // so keep it out of the near field where it sweeps the most screen.
    float shockPh = zt * 0.25 - u.beatPhase;
    float shockD = (fract(shockPh) - 0.5) * 4.0 * rp * 2.2;
    float shock = 1.0 - smoothstep(0.003, 0.003 + max(fwidth(shockPh) * 4.0 * rp * 2.2, 1e-4), abs(shockD));
    shock *= (1.0 - smoothstep(0.45, 1.0, rp)) * smoothstep(0.07, 0.2, rp);
    // a steady level (the bass role whitens on the kick): the beat shows as
    // the line racing away, not as a brightness pulse
    vec3 shockC = palVisual(0.1 + 0.08 * u.spectralCentroid, u);
    shockC *= 0.16 / max(dot(shockC, vec3(0.2126, 0.7152, 0.0722)), 1e-3);
    col += shockC * shock * fog;

    // vanishing-point black core + outer falloff
    col *= smoothstep(0.03, 0.14, rp);
    col *= 1.0 - smoothstep(1.15, 1.7, length(p)) * 0.9;

    // only a trace of still persistence (it softens line aliasing): a long,
    // zoomed trail ghosted every frame ring and the sweep into copies that
    // flickered the tunnel, and even a 0.15 hold fired its own transitions
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.06), 0.0, 0.0);
    return col; // LINEAR HDR
}
