// SPDX-License-Identifier: AGPL-3.0-only
// Ink.
// Luminous ink in dark water, shot macro. The feedback buffer is the fluid:
// each frame it is carried along a velocity field, sharpened against the
// blur of resampling, and fed fresh dye. The field is multi-scale curl noise
// plus the analytic vortex pairs of rising plumes: every beat a warm charge
// eases in from the floor and mushrooms upward, small crowns of dye open
// twice a beat, and two pens draw a second, cool ink in thin wisps which the
// turbulence frays. The dye and the flow follow the music's smoothed level,
// with only a trace of kick and onset, so ink fades in rather than popping;
// the water swirls slowly, the pens draw at a gentle pace and the soft
// caustic light drifts slowly. Thin, old ink cools and darkens as it
// spreads, dense fresh ink glows, and soft light shafts fall through the
// water behind it all. No camera: the motion is the fluid.
// param0 = Flow ; param1 = Ink Budget ; param2 = Buoyancy

// Value noise with its analytic gradient.
float inkNoise(vec2 p, out vec2 g) {
    vec2 i = floor(p), f = fract(p);
    vec2 w = f * f * (3.0 - 2.0 * f);
    vec2 dw = 6.0 * f * (1.0 - f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    float k = a - b - c + d;
    g = dw * vec2(b - a + k * w.y, c - a + k * w.x);
    return a + (b - a) * w.x + (c - a) * w.y + k * w.x * w.y;
}

// Curl of a few noise octaves: divergence-free swirl.
vec2 inkCurl(vec2 p, int oct, float fine) {
    vec2 v = vec2(0.0);
    float amp = 1.0;
    for (int i = 0; i < 4; i++) {
        if (i >= oct) break;
        vec2 g;
        inkNoise(p, g);
        v += vec2(g.y, -g.x) * amp;
        p = p * 2.07 + vec2(17.3, 9.1);
        amp *= i == 0 ? 0.55 * fine : 0.5;
    }
    return v;
}

// Sunlight through the surface, a function of position and time only: a
// warped network of caustic ridges that is brightest near the top and fades
// with depth. The picture is ink * light + motes, and the next frame divides
// the light back out (and subtracts the motes) before advecting, so the
// light plays over the ink without ever being stored in it. Every rate is a
// whole number of turns per 600 s, so the time wrap is seamless.
float inkLight(vec2 uv, vec2 asp, float t) {
    const float W = 0.010471976;                  // 2pi / 600
    float c = 0.0;
    for (int L = 0; L < 2; L++) {
        float fl = float(L);
        vec2 q = rot2(0.6 + 0.9 * fl) * (uv * asp * (5.5 + 3.0 * fl)) + fl * 7.3;
        for (int n = 0; n < 3; n++) {
            float fn = float(n) + fl * 3.0;
            q += 0.85 * vec2(sin(q.y * 1.3 + t * W * (5.0 + 1.0 * fn) + fn * 1.7),
                            sin(q.x * 1.1 - t * W * (4.0 + 1.0 * fn) + fn * 2.3));
        }
        float v = sin(q.x * 2.1) * sin(q.y * 1.9);
        float ridge = 1.0 - abs(v);
        float r2 = ridge * ridge;
        r2 *= r2;
        r2 *= r2;                                  // ridge^8: thin bright lines
        c += r2 * (1.0 - 0.4 * fl);
    }
    float depth = 1.0 - smoothstep(-0.15, 1.1, uv.y);
    // broad sun patches so the light also moves at large scale
    float sun = 0.5 + 0.5 * sin(uv.x * asp.x * 2.3 + t * W * 5.0) * sin(uv.y * 1.7 - t * W * 4.0 + 1.0);
    return 0.3 + depth * (0.16 * sun + 0.4 * c * (0.35 + 0.65 * sun));
}

// Out-of-focus motes drifting in front of the ink, also time-only: big soft
// discs with a brighter rim, as a macro lens renders specks off the focal plane.
vec3 inkMotes(vec2 uv, vec2 asp, float t, vec3 tintA, vec3 tintB) {
    const float W = 0.010471976;
    vec3 acc = vec3(0.0);
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        vec2 c = vec2(0.5 + 0.48 * sin(t * W * (5.0 + fi * 2.0) + fi * 2.4),
                      0.5 + 0.46 * sin(t * W * (4.0 + fi * 3.0) + fi * 1.3 + 0.7));
        float r = 0.05 + 0.025 * fi;
        float d = length((uv - c) * asp) / r;
        float disc = 1.0 - smoothstep(0.82, 1.0, d);
        float rim = smoothstep(0.55, 0.95, d) * disc;
        float pulse = 0.8 + 0.2 * sin(t * W * (8.0 + 1.0 * fi) + fi);
        acc += mix(tintA, tintB, fract(fi * 0.618)) * (disc * 0.012 + rim * 0.02) * pulse;
    }
    return acc;
}

// Velocity of a point vortex of strength s at c (aspect-corrected space).
vec2 inkVortex(vec2 d, float s, float core) {
    return s * vec2(-d.y, d.x) / (dot(d, d) + core * core);
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 asp = vec2(aspect, 1.0);
    float detail = osDetail(u);
    float t = mod(u.time, 600.0);
    float flow = mix(0.45, 1.70, u.param0);
    float budget = mix(0.55, 1.90, u.param1) * 0.8;
    float buoy = mix(0.25, 1.30, u.param2);
    float step60 = clamp(u.dt * 60.0, 0.25, 3.0);
    if (u.dt <= 0.0) step60 = 1.0;
    float beats = u.beatCount + saturate(u.beatPhase);
    float bc = floor(u.beatCount);

    // ---- velocity field (uv units per 60 Hz frame, y down) ----
    vec2 q = uv * asp * 2.8;
    q = rot2(0.07 * sin(t * 0.05)) * q + vec2(0.0, t * 0.025);
    int oct = osSteps(2.0, 4.0, detail);
    vec2 vel = inkCurl(q, oct, 0.9) * (0.0006 + 0.0003 * u.level) * flow;

    // fresh dye is grainy, so the flow stretches it into filaments
    float grain = 0.45 + 0.55 * smoothstep(0.2, 0.9, vnoise(rot2(0.6) * uv * asp * 17.0 + vec2(t * 0.2, 0.0)));

    // warm water rises: a slow buoyant drift carries old ink upward
    vel.y -= (0.0005 + 0.0002 * u.level) * buoy;

    // kick plumes: a vortex pair per plume, rising from the floor
    vec3 warmA = palVisual(0.22 + 0.08 * u.spectralCentroid, u);
    vec3 warmB = palVisual(0.97, u);
    vec3 dye = vec3(0.0);
    for (int j = 0; j < 3; j++) {
        float born = bc - float(j);
        float hb = hash21(vec2(mod(born, 512.0), 3.7));
        float age = beats - born;
        float hero = mod(born, 8.0) < 0.5 ? 1.0 : 0.0;
        float x0 = mix(0.18 + 0.64 * hb, 0.38 + 0.24 * hb, hero);
        float y0 = 1.05 - age * 0.16 * (0.6 + 0.6 * buoy);
        vec2 c = vec2(x0 + 0.03 * sin(age * 1.3 + hb * 6.0), y0);
        float life = smoothstep(0.0, 0.6, age) * (1.0 - smoothstep(2.0, 3.0, age));
        float s = 0.0006 * life * (0.6 + 0.3 * u.level) * buoy * flow * (1.0 + 0.5 * hero);
        float R = (0.06 + 0.03 * age) * (1.0 + 0.6 * hero);
        vec2 d = (uv - c) * asp;
        vel += (inkVortex(d - vec2(R, 0.0), s, 0.05) - inkVortex(d + vec2(R, 0.0), s, 0.05)) / asp;
        // the youngest plume carries the kick's dye up from the floor
        float g = exp(-dot(d, d) / (0.006 * (1.0 + 1.2 * hero)));
        // the charge is shaded as a lit billow: a hot crown toward the light
        // above, a deeper body below, so the advected sheets keep their form
        float lit = 0.55 + 0.75 * saturate(0.5 - d.y * 9.0 - d.x * 3.0) + 0.6 * exp(-dot(d + vec2(0.012, 0.03), d + vec2(0.012, 0.03)) / 0.0008);
        vec3 pc = mix(mix(warmB, warmA, hb), palVisual(0.985, u) * 1.2, hero * 0.6);
        dye += pc * g * lit * (1.0 + 0.2 * hero) * 0.8 * (0.08 + 0.08 * u.level + 0.03 * u.bassImpact)
             * smoothstep(0.0, 0.4, age) * (1.0 - smoothstep(0.5, 1.2, age)) * budget * 0.7 * grain;
    }

    // onset bursts: dye blooms open where it lands
    float k = u.beatCount * 2.0 + step(0.5, u.beatPhase);
    float kAge = fract(beats * 2.0);
    for (int j = 0; j < 2; j++) {
        float fj = float(j);
        vec2 h = hash22(vec2(mod(floor(k), 997.0) * 0.371 + fj * 13.7, fj * 5.13 + 2.7));
        vec2 c = vec2(0.14 + 0.72 * h.x, 0.18 + 0.5 * h.y);
        vec2 d = (uv - c) * asp;
        float r2 = dot(d, d);
        vel += d / asp / (r2 + 0.004) * 0.00003 * smoothstep(0.0, 0.2, kAge) * exp(-kAge * 3.0) * flow;
        // a burst lands as a crown: a thin expanding ring of dye with a
        // small dense core, which the outward flow then frays
        float rr = sqrt(r2);
        float rx = (rr - 0.012 - 0.06 * kAge) / (0.006 + 0.004 * u.flux);
        float g = exp(-rx * rx) * (0.6 + 0.4 * grain) + 0.5 * exp(-r2 / 0.0004);
        // the first burst takes the palette's far end, the accent opposite the
        // cool pens (red-coral on the default palette)
        vec3 dc = j == 0 ? palVisual(0.975 + 0.02 * h.y, u) * 1.25
                         : palVisual(0.05 + 0.2 * u.spectralCentroid + h.y * 0.08, u);
        dye += dc * g * smoothstep(0.0, 0.3, kAge) * (1.0 - kAge) * (0.03 + 0.04 * u.level + 0.03 * u.onset) * budget * 0.35 * grain;
    }

    // treble pens: a second, cool ink in thin drawn wisps
    vec3 cool = palVisual(0.74 + 0.06 * u.spectralCentroid, u);
    for (int j = 0; j < 2; j++) {
        float fj = float(j);
        vec2 pen = vec2(0.5 + 0.36 * sin(t * 0.1 + fj * 3.1) + 0.08 * sin(t * 0.25 + fj),
                        0.48 + 0.28 * sin(t * 0.08 + fj * 1.9 + 1.0));
        vec2 d = (uv - pen) * asp;
        float g = exp(-dot(d, d) / 0.00022);
        float tr = 0.025 + 0.04 * u.level + 0.01 * u.treble;
        dye += mix(cool, vec3(0.9, 1.0, 1.0), 0.1) * g * tr * budget * 1.3;
    }

    // ---- advect: sample upstream ----
    // stay inside the frame, so the light divided out is the light stored there
    vec2 hp = 0.5 / max(u.resolution, vec2(1.0));
    vec2 su = clamp(uv - vel * step60, hp, 1.0 - hp);
    float tPrev = mod(u.time - max(u.dt, 0.0), 600.0);
    vec3 moteA = palVisual(0.7, u), moteB = palVisual(0.2, u);
    float lightP = inkLight(su, asp, tPrev);
    vec3 motesP = inkMotes(su, asp, tPrev, moteA, moteB);
    vec3 prev = max(PREV(su).rgb - motesP, vec3(0.0)) / lightP;
    // anti-diffusion: bilinear resampling blurs the ink a little every
    // frame; a small, clamped unsharp step keeps filaments knife-crisp
    if (detail > 0.3) {
        vec2 px = 1.5 / max(u.resolution, vec2(1.0));
        vec3 nb = 0.25 * (PREV(su + vec2(px.x, 0.0)).rgb + PREV(su - vec2(px.x, 0.0)).rgb
                        + PREV(su + vec2(0.0, px.y)).rgb + PREV(su - vec2(0.0, px.y)).rgb);
        nb = max(nb - motesP, vec3(0.0)) / lightP;
        vec3 sharp = clamp(prev - nb, -0.3 * prev, 0.3 * prev);
        prev = max(prev + sharp * 0.14 * min(step60, 1.5), vec3(0.0));
    }

    // ---- decay: thin ink cools and darkens, dense ink is guarded from
    // stacking into white ----
    float pl = luma(prev);
    vec3 tintKeep = mix(vec3(1.0), normalize(palVisual(0.5, u) + 0.05) * 1.7, 0.012);
    float keep = 0.99 - 0.12 * smoothstep(0.3, 1.0, pl);
    vec3 kv = min(tintKeep * keep, vec3(0.995));
    kv = pow(kv, vec3(step60));
    prev = max(prev * kv - 0.0011 * step60, vec3(0.0));

    vec3 col = prev + dye * step60;
    // a hot rim where fresh dye meets the water
    float dl = luma(dye);
    col += dye * dl * 0.12;

    // ---- the water behind: never accumulates, only shows where ink is thin
    vec2 wp = uv * asp;
    float sh = vnoise(vec2((wp.x + wp.y * 0.35) * 7.0 + t * 0.06, t * 0.05));
    sh = sh * sh * sh * (1.0 - uv.y) * (1.0 - uv.y);
    vec3 deep = palVisual(0.5, u);
    vec3 water = deep * (0.010 + 0.012 * (1.0 - uv.y)) + palRoleFog(0.55, u) * sh * 0.08 * (0.8 + 0.1 * u.level);
    // light the ink, keep the water behind mostly out of the caustics, and
    // float the motes in front; the next frame removes the light and motes
    float light = inkLight(uv, asp, t);
    col = max(col * light, water * (0.55 + 0.25 * light));
    return col + inkMotes(uv, asp, t, moteA, moteB); // LINEAR HDR fluid state
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
