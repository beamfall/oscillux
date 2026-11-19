// SPDX-License-Identifier: AGPL-3.0-only
// Ink — "Luminous Ink in Dark Water"
// No fluid sim: the feedback buffer IS the fluid. Each frame samples PREV
// through a curl-noise displaced uv (advection), decays it (energy bleed),
// and injects analytic dye splats on onsets whose color follows the spectral
// centroid. bassImpact adds an upward advection bias (buoyancy plume).
// param0 = Flow ; param1 = Ink Budget ; param2 = Buoyancy

float inkNs(vec2 p) {
    return vnoise(p) + 0.5 * vnoise(p * 2.13 + 7.7);
}

vec2 inkCurl(vec2 p) {
    float e = 0.05;
    float a = inkNs(p + vec2(0.0, e)) - inkNs(p - vec2(0.0, e));
    float b = inkNs(p + vec2(e, 0.0)) - inkNs(p - vec2(e, 0.0));
    return vec2(a, -b) / (2.0 * e);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float flow   = mix(0.45, 1.70, u.param0);
    float budget = mix(0.55, 1.90, u.param1);
    float buoy   = mix(0.25, 1.30, u.param2);
    // Advection, bleed and injection are authored per 60 Hz frame; n = dt*60
    // keeps them the same per second at 30/60/120 Hz (one step without a clock).
    float n = u.dt > 0.0 ? min(u.dt * 60.0, 4.0) : 1.0;

    // ---- advection: curl-noise velocity field in uv space (y-down screen) ----
    vec2 q = uv * vec2(aspect, 1.0) * 3.1 + vec2(0.0, u.time * 0.045);
    vec2 vel = inkCurl(q) * (0.55 + u.mid * 1.1);
    vel += inkCurl(q * 2.7 + 31.4) * 0.35 * (0.3 + u.treble);

    // beat swirl around center (vorticity "turns over" on the beat)
    vec2 rc = (uv - 0.5) * vec2(aspect, 1.0);
    vel += vec2(-rc.y, rc.x) * (u.beat * 1.4 + 0.15) * phasePulse(u, 0.0, 0.25);

    // buoyancy: sample from below => dye rises (uv.y grows downward)
    float rise = (0.0022 + 0.0060 * u.bassImpact + 0.0018 * u.bass) * buoy;

    vec2 sampleUV = uv + (vel * 0.0040 * flow + vec2(0.0, rise)) * n;
    // Water outside the frame is empty: fade history sampled past the edge
    // instead of repeating the edge texel, which advection drags inward.
    vec2 outside = max(-sampleUV, sampleUV - 1.0);
    float inside = clamp(1.0 - 32.0 * max(max(outside.x, outside.y), 0.0), 0.0, 1.0);
    vec3 prev = PREV(sampleUV).rgb * inside;

    // energy must decay: base bleed + whiteout guard. The guard must bite
    // inside the tonemapped range (ACES is ~white by luma 2), or dye stacks
    // into flat white blobs and the color is lost.
    float pl = luma(prev);
    float keep = 0.989 - 0.10 * smoothstep(0.7, 2.2, pl);
    prev = max(prev * pow(keep, n) - 0.0008 * n, vec3(0.0));

    // ---- dye injection ----
    // Dye is poured, not dropped: each beat's three charges flow in one after
    // another along bells (about 90 ms attack, longer release at 120 BPM)
    // instead of on the onset impulse, so a charge blooms rather than pops and
    // the frame stays within the general flash limit before the limiter. The
    // fluid also bleeds slower, so less ink keeps the water as full.
    // Loudness sets how much ink a beat pours; the timbre still sets its colour.
    // Splats are sized against the frame's short side, so on a portrait frame
    // they cover the same share of it as at 16:9 instead of stacking into white.
    vec2 splatScale = vec2(aspect, 1.0) / min(aspect, 1.0);
    float ph = u.beatPhase;
    float loud = 0.35 + 0.65 * saturate(u.level * 0.6 + u.amplitude * 0.4);
    vec3 dye = vec3(0.0);
    float k = u.beatCount; // splat site key, one set of sites per beat
    for (int j = 0; j < 3; ++j) {
        float fj = float(j);
        // the three charges pour one after another across the beat
        float p0 = 0.08 + 0.26 * fj;
        float pour = smoothstep(p0, p0 + 0.18, ph) * (1.0 - smoothstep(p0 + 0.18, p0 + 0.40, ph));
        vec2 h = hash22(vec2(k * 0.371 + fj * 13.7, fj * 5.13 + 2.7));
        // one site per third of the width, so a beat's charges never pile up
        vec2 c = vec2((fj + 0.2 + 0.6 * h.x) / 3.0, 0.24 + 0.46 * h.y);
        vec2 d = (uv - c) * splatScale;
        float g = exp(-dot(d, d) / (0.0045 + 0.0025 * saturate(u.flux)));
        vec3 dcol = palVisual(u.spectralCentroid * 0.85 + fj * 0.14 + h.y * 0.10, u);
        // vivid rather than bright: chroma reads as glow without luma steps
        dcol = max(mix(vec3(luma(dcol)), dcol, 1.6), vec3(0.0));
        dye += dcol * g * pour * loud * budget * 0.04;
    }

    // kick plume: charge near the floor that the buoyancy carries up, poured on
    // the same slow bell, scaled by the bass.
    vec2 db = (uv - vec2(0.5 + 0.12 * sin(u.time * 0.7), 0.90)) * splatScale;
    vec3 bassCol = palRoleBass(0.06 + 0.05 * u.spectralCentroid, u);
    dye += bassCol * exp(-dot(db, db) / 0.0045) * smoothstep(0.0, 0.3, ph) * (1.0 - smoothstep(0.3, 0.7, ph)) * u.bass * budget * 0.055;

    vec3 col = prev + dye * n;

    // faint caustic floor light in the empty water (self-limiting)
    float caustic = fbm(uv * vec2(aspect, 1.0) * 6.0 + u.time * 0.03);
    col += palRoleFog(0.62, u) * caustic * 0.002 * (1.0 - saturate(pl * 1.5)) * (0.4 + u.amplitude) * n;

    return col; // LINEAR HDR — this exact value is next frame's fluid state
}
