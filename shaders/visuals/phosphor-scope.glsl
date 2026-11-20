// SPDX-License-Identifier: AGPL-3.0-only
// Phosphor Scope — vintage CRT oscilloscope in a dark room:
// a Lissajous figure held in phosphor memory, slowly morphing, re-written by a
// white-hot beam that laps the figure once a bar; the beat breathes the glow, the
// kick lands on the beam head, treble puts HF fuzz on the beam.
// param0 Persistence ; param1 Figure Complexity ; param2 Beam Fuzz
//
// Flash budget (CORE-2659): the figure is dense, so anything that moves every line at
// once (a size jump on the kick, a timbre-driven phase jump, a fast morph) flips a large
// area of the tube on each change. The figure therefore only drifts slowly, the beat
// works through a smooth swell (continuous across the beat wrap) kept within one
// brightness band, and the music's punch goes into the travelling beam head, a small area.
// Density and glow come from a steady phosphor smear: each trace carries a wide, soft band of
// strands toward where the figure was a moment ago, so the tube stays full and bright while
// only the slow drift changes it (soft band edges keep that drift from flipping pixels).

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);

    // CRT face: gentle barrel bulge
    float r2 = dot(p, p);
    vec2 pc = p * (1.0 + 0.055 * r2);

    // screen rectangle (rounded-ish via soft edges)
    vec2 scr = vec2(0.86, 0.62);
    vec2 q = abs(pc) - scr;
    float dScreen = max(q.x, q.y);
    float inScreen = 1.0 - smoothstep(-0.006, 0.004, dScreen);
    // corner-darkening shade inside the tube
    float shade = 1.0 - smoothstep(0.35, 1.05, max(abs(pc.x) / scr.x, abs(pc.y) / scr.y)) * 0.55;

    // beat swell: peaks on the beat, 250 ms rise and fall at 120 bpm, no step at the wrap
    float swell = 0.5 + 0.5 * cos(6.2831853 * u.beatPhase);
    swell *= swell;

    vec3 col = vec3(0.0);

    // ---- dark room + bezel rim ----
    float bezel = exp(-max(dScreen, 0.0) * 9.0);
    col += palRoleFog(0.72, u) * bezel * (1.0 - inScreen) * (0.06 + 0.012 * swell);

    // ---- faint phosphor idle glow + graticule ----
    vec3 fog = palRoleFog(0.40 + 0.04 * sin(u.time * 0.05), u);
    col += fog * inScreen * shade * 0.028;

    float gx = abs(fract(pc.x / 0.215 + 0.5) - 0.5) * 0.215;
    float gy = abs(fract(pc.y / 0.215 + 0.5) - 0.5) * 0.215;
    float grid = max(aaLine(gx, 0.0011), aaLine(gy, 0.0011));
    float axis = max(aaLine(pc.x, 0.0016), aaLine(pc.y, 0.0016));
    col += fog * inScreen * shade * (grid * 0.055 + axis * 0.10);

    // ---- Lissajous figure ----
    // complexity from param1; the frequencies and phase drift slowly with time only
    float comp = mix(1.0, 3.0, u.param1);
    float fx = 1.0 + comp + 0.85 * sin(u.time * 0.017);
    float fy = 2.0 + comp * 0.7 + 0.85 * sin(u.time * 0.0113 + 1.9);
    float phX = u.time * 0.06;

    float ax = scr.x * 0.74;
    float ay = scr.y * 0.72;

    float fuzz = u.param2 * (0.3 + 1.4 * u.treble);

    // the beam writes the figure once a bar; the head position is continuous in beat time
    float head01 = fract((u.beatCount + u.beatPhase) * 0.25);

    vec3 beamCol = palVisual(0.34 + 0.05 * sin(u.time * 0.07), u);
    vec3 haloCol = palVisual(0.30 + 0.05 * sin(u.time * 0.07), u);
    float core = 0.0;
    float halo = 0.0;
    float hot = 0.0;
    float ribbon = 0.0;
    vec2 prev = vec2(ax * sin(phX), 0.0);
    // phosphor memory of the drifting figure: each point leaves a smear toward where the
    // figure was a moment ago (its phase drift), a fixed-width band that only morphs slowly
    float smear = 0.2;
    vec2 ePrev = vec2(-ax * cos(phX) * smear, 0.0);

    // continuous beam: distance to 96 chained segments of the Lissajous curve
    for (int i = 1; i <= 96; ++i) {
        float fi = float(i);
        float s = fi / 96.0;
        float a = s * 6.2831853;
        float thX = fx * a + phX;
        vec2 pos = vec2(ax * sin(thX), ay * sin(fy * a));
        vec2 eCur = vec2(-ax * cos(thX) * smear, 0.0);
        // treble HF fuzz: smooth micro-ripple along the sweep, not per-dot hash
        pos += vec2(sin(a * 61.0 + u.time * 9.3), cos(a * 73.0 - u.time * 7.1))
             * 0.0048 * fuzz;

        vec2 ab = pos - prev;
        float h = clamp(dot(pc - prev, ab) / (dot(ab, ab) + 1e-6), 0.0, 1.0);
        vec2 d = pc - prev - ab * h;
        float d2 = dot(d, d);
        // distance behind the writing head along the figure, 0 at the head
        float behind = fract(head01 - (fi - 1.0 + h) / 96.0);
        // the phosphor tail decays behind the head
        float tail = exp(-behind * 4.0);
        float tip = exp(-behind * 150.0);
        core += 2.0e-5 / (d2 + 2.5e-5) * (0.6 + 0.6 * tail);
        halo += 1.0e-4 / (d2 + 1.0e-3) * (0.9 + 0.3 * tail);
        hot += tip * 4.0e-5 / (d2 + 2.0e-5);
        // the smear band: a few strands across it, fading into the past
        // solve pc = prev + ab*hb + e*t for the band (e is horizontal)
        vec2 rel = pc - prev;
        // (a near-level segment has no y to solve with: use the trace projection there)
        float hb = clamp(rel.y * ab.y / (ab.y * ab.y + 1e-7), 0.0, 1.0);
        hb = mix(h, hb, smoothstep(0.15, 0.4, abs(ab.y) * inversesqrt(dot(ab, ab) + 1e-9)));
        vec2 e = mix(ePrev, eCur, hb);
        float t = clamp((rel.x - ab.x * hb) * e.x / (e.x * e.x + 1e-7), 0.0, 1.0);
        vec2 db = rel - ab * hb - e * t;
        float rib = exp(-dot(db, db) * 1800.0) * exp(-t * 1.1) * (0.8 + 0.2 * cos(t * 22.0));
        ribbon = max(ribbon, rib);
        ePrev = eCur;
        prev = pos;
    }

    // level sets the glow; the beat swell stays inside one brightness band
    float energy = 1.28 + 0.2 * u.level + 0.12 * swell * u.level;
    col += beamCol * core * energy * 1.1 * inScreen * shade;
    col += haloCol * halo * energy * 0.2 * inScreen * shade;
    col += beamCol * ribbon * energy * 0.85 * inScreen * shade;

    // white-hot write head: the kick lands here, on a small area
    col += peakWhite(beamCol, 0.6) * hot * (0.5 + 0.2 * swell) * inScreen;

    // subtle scanline shimmer of the tube glass
    col *= 1.0 - 0.045 * inScreen * (0.5 + 0.5 * sin(pc.y * 320.0));

    // ---- phosphor persistence ----
    float persist = clamp(mix(0.74, 0.93, u.param0), 0.0, 0.93);
    col = feedbackTrail(col, uv, persist, 0.0006, 0.0);
    return col; // LINEAR HDR
}
