// SPDX-License-Identifier: AGPL-3.0-only
// Murmuration — "Flock of Light"
// Analytic starling flock: 3 band-driven sub-flocks of point sprites on
// noise-perturbed orbits over a dark reflective floor. bassImpact = predator
// rupture (radial displacement, exp falloff). Feedback trails give the flock
// its smoke-like body; a dimmed mirror pass is the reflection.
// param0 = Flock Spread ; param1 = Rupture ; param2 = Wind

// Band energies as the flock reads them. Raw bass jumps in one frame on every
// kick, which moved and brightened the whole bass flock at once; the kick's
// motion lives in swell() instead, so the bass flock rides the level.
float flockEnergy(int f, VisualUniforms u) {
    if (f == 0) return u.level;
    return f == 1 ? u.mid : u.treble;
}

// Beat swell: 0 at the beat, rising over ~37% of the beat (185 ms at 120 bpm),
// easing back to 0 by the next one. Periodic in beatPhase with zero slope at
// both ends, so the wrap never jumps; bass scales it, and because the swell is
// 0 at the hit, bass's own jump on the kick never shows as a step.
float swell(VisualUniforms u) {
    float s = sin(3.14159265 * pow(u.beatPhase, 0.7));
    return s * s * saturate(u.bass * 1.3);
}

// Palette colour kept out of the saturated-red corner (R / (R+G+B) >= 0.8):
// a changing red area is a red flash even when it is dim.
vec3 notRed(vec3 c) {
    c.g = max(c.g, 0.34 * c.r);
    c.b = max(c.b, 0.06 * c.r);
    return c;
}

vec2 leaderPos(int f, float t, VisualUniforms u) {
    float e = flockEnergy(f, u);
    if (f == 0) return vec2(sin(t * 0.31) * 0.95,        -0.16 + e * 0.45 + sin(t * 0.70) * 0.08);
    if (f == 1) return vec2(sin(t * 0.23 + 2.1) * 1.05,   0.12 + e * 0.35 + cos(t * 0.50) * 0.13);
    return           vec2(sin(t * 0.41 + 4.2) * 0.80,     0.32 + e * 0.32 + sin(t * 0.90 + 1.0) * 0.10);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y; // y-up world
    float floorY = -0.62;

    float spread = mix(0.12, 0.36, u.param0);
    float rupAmt = mix(0.15, 0.85, u.param1);
    float wind   = mix(0.45, 1.60, u.param2);

    float t = u.time;

    // chorus-ish merge: slow LFO gated by level pulls flocks into one organism
    float merge = smoothstep(0.30, 0.85, 0.5 + 0.5 * sin(t * 0.045 + 1.2)) * saturate(u.level * 1.5);

    vec2 c0 = leaderPos(0, t, u);
    vec2 c1 = mix(leaderPos(1, t, u), c0, merge * 0.72);
    vec2 c2 = mix(leaderPos(2, t, u), c0, merge * 0.72);
    vec2 rupC = (c0 + c1 + c2) / 3.0;

    vec3 col = vec3(0.0);
    vec3 glow = vec3(0.0);
    float wing = u.beatPhase * 6.2831853;
    // soft-attack kick: bassImpact's instant attack made every bird jump and
    // brighten in one frame.
    float kickSoft = swell(u);
    // bird core: at least ~1.4 px wide so a moving bird glides across pixels
    // instead of popping on and off between them; the glow and reflection go
    // to their own sum so only the halo is compressed, not the bright heads
    float px = 2.0 / max(u.resolution.y, 1.0);
    float core2 = max(2.2e-5, (1.4 * px) * (1.4 * px));

    for (int f = 0; f < 3; ++f) {
        vec2 cf = f == 0 ? c0 : (f == 1 ? c1 : c2);
        float bandE = flockEnergy(f, u);
        // smooth palette reads: the library's bass/treble roles whiten on the
        // instant onset and bassImpact, flashing every bird on the hit
        vec3 flockCol;
        if (f == 0)      flockCol = mix(palVisual(0.20, u), palVisual(0.06, u), 0.62);
        else if (f == 1) flockCol = palVisual(0.40 + 0.12 * u.spectralCentroid, u);
        else             flockCol = palVisual(0.81 + 0.10 * u.spectralCentroid, u);
        flockCol = notRed(accentize(flockCol, u.accent, 0.10));
        float ff = float(f);

        for (int i = 0; i < 40; ++i) {
            float fi = float(i);
            vec2 h = hash22(vec2(fi * 1.71 + ff * 61.3, ff * 7.7 + 3.1));

            // orbit around the sub-flock leader; radius breathes with noise so
            // birds drift between shells instead of tracing clean rings
            float radN = vnoise(vec2(fi * 0.73 + ff * 9.1, t * 0.16));
            float rad = spread * (0.30 + 1.35 * h.x) * (0.55 + 0.9 * radN) * (1.0 + bandE * 0.9);
            float sp  = (0.35 + h.y * 0.8) * wind;
            float dir = h.x > 0.5 ? 1.0 : -1.0;
            float ang = h.y * 6.2831853 + t * sp * dir + radN * 2.4;
            vec2 bp = cf + vec2(cos(ang), sin(ang) * 0.62) * rad;

            // curl-ish turbulence (two decorrelated value-noise reads)
            vec2 q = bp * 2.3 + vec2(t * 0.25 * wind, -t * 0.18 * wind) + ff * 17.0;
            bp += vec2(vnoise(q) - 0.5, vnoise(q + vec2(7.31, 3.7)) - 0.5) * (0.30 + u.mid * 0.34);

            // wingbeat shimmer, phase-locked to the beat
            bp.y += 0.014 * sin(wing + fi * 1.3 + ff * 2.1);

            // predator rupture: displace along (bird - center), exp falloff
            vec2 rv = bp - rupC;
            float rl = length(rv) + 1e-3;
            bp += (rv / rl) * kickSoft * rupAmt * 0.30 * (0.4 + 0.8 * h.x) * exp(-rl * 1.7);
            bp.y = max(bp.y, floorY + 0.015);

            // the beat lives in the rupture motion; brightness only leans on it
            float bright = 0.55 + bandE * 0.8 + kickSoft * 0.12;
            float flick = 0.85 + 0.15 * sin(t * 3.0 + fi * 2.7 + ff * 5.0);

            // main sprite: a bright, tight core (gaussian cut at ~1.2 core
            // radii, so the bright area a moving head sweeps stays small) plus
            // a faint Lorentzian glow. The glow's 1/d^2 tail never reaches zero
            // and 120 tails summed fill the frame with haze -- gate it with a
            // gaussian so the room beyond ~0.15 stays black.
            vec2 d = p - bp;
            float d2 = dot(d, d);
            float tailCut = exp(-d2 * 60.0);
            col  += flockCol * (1.9 * core2 / (d2 + core2) * exp(-d2 / (core2 * 1.5))) * bright * flick;
            glow += flockCol * (2.0e-5 / (d2 + core2) * tailCut) * bright * flick;

            // reflection under the floor, dimmed + softened
            vec2 dm = p - vec2(bp.x, 2.0 * floorY - bp.y);
            float dm2 = dot(dm, dm);
            float refCut = exp(-dm2 * 40.0);
            glow += flockCol * (5.0e-5 / (dm2 + 3.0e-4)) * refCut * bright * 0.28;
        }
    }

    // Soft-knee the heads above 0.7 luma toward 1.2, so bunched birds read as
    // white sparks rather than a blown-out patch; the summed glow is
    // compressed harder, since its broad haze is what bunches into area.
    float Lc = dot(col, vec3(0.2126, 0.7152, 0.0722));
    float kn = 0.7, lm = 1.2;
    if (Lc > kn) col *= (kn + (Lc - kn) / (1.0 + (Lc - kn) / (lm - kn))) / Lc;
    col += glow / (1.0 + 3.0 * dot(glow, vec3(0.2126, 0.7152, 0.0722)));

    // faint reflective floor line + haze below horizon
    float floorGlow = exp(-abs(p.y - floorY) * 26.0);
    col += palRoleFog(0.5 + 0.1 * u.spectralCentroid, u) * floorGlow * (0.10 + 0.22 * u.level);
    float below = smoothstep(floorY, floorY - 0.5, p.y);
    col *= 1.0 - below * 0.45;

    // Trails = the murmuration's smoky body, held below 0.075 luma. A trail
    // brighter than one 0.1 luminance step flashes again as it decays, after
    // the head has gone; at full head brightness every streak in the dense
    // core did, which was most of the 27 large-area luma transitions/s under
    // loud audio. Capped, the decay never makes a step of its own: the heads
    // sparkle and the trails stay dimmer, in the flock's colours.
    float decay = min(0.90, u.trailDecay + 0.07);
    float zoom = 0.0015 + 0.002 * kickSoft;
    vec3 tr = feedbackTrail(vec3(0.0), uv, decay, zoom, 0.0025 * sin(t * 0.21));
    float Lt = dot(tr, vec3(0.2126, 0.7152, 0.0722));
    tr *= min(1.0, 0.075 / max(Lt, 1e-6));
    col = max(col, tr);

    // Fade the very last of each trail to grey: amber decaying to near black
    // quantises to pure red codes, which counts as a red flash.
    float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col = mix(vec3(l), col, smoothstep(0.0, 0.012, l));
    return col; // LINEAR HDR
}
