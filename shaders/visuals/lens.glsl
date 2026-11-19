// SPDX-License-Identifier: AGPL-3.0-only
// Lens — "Sound as Mass" (image-capable)
// Gravitational lensing: three band-driven masses on Lissajous orbits bend a
// procedural nebula + starfield (album artwork blended in when it has detail).
// Iterative 2D geodesic deflection with three gravity constants = chromatic
// dispersion. Sustained level drives inspiral/merge: event horizon, photon
// ring, redshifted afterglow. Each beat sends an accretion ripple out from each
// free mass. Flash budget (CORE-2659): instant band levels never drive large-area
// brightness or the lens geometry; the beat arrives as a ~150 ms swell from
// beatPhase and as motion, and red-dominant colours keep a green/blue floor.
// param0 = Gravity ; param1 = Merge Eagerness ; param2 = Background Richness

// Red-dominant colours round to saturated red in 8 bit; keep G + B >= 0.5 R.
vec3 lensNoRed(vec3 c) {
    float lift = max(0.0, c.r * 0.5 - c.g - c.b);
    return c + vec3(0.0, 0.65, 0.35) * lift;
}

vec3 lensNebula(vec2 q, VisualUniforms u, float rich, float starDamp, float hi) {
    // dim wispy nebula: deep space stays black, filaments carry the color
    float n = fbm(q * 1.5 + vec2(3.1, 7.2));
    float n2 = fbm(q * 2.9 - vec2(1.7, 2.2) + n * 1.2);
    float wisp = pow(saturate(n2), 5.0);
    vec3 neb = palVisual(n2 * 0.85 + 0.12 + u.spectralCentroid * 0.08, u)
             * wisp * (0.35 + rich * 0.95);

    // sparse jittered pin stars (HDR points, tiny coverage)
    vec2 g = floor(q * 30.0);
    vec2 fr = fract(q * 30.0) - 0.5;
    vec2 j = hash22(g) - 0.5;
    float s = hash21(g + 17.0);
    float d = length(fr - j * 0.7);
    float star = smoothstep(0.962, 1.0, s) * exp(-d * d * 700.0);
    float tw = 0.65 + 0.35 * sin(u.time * 3.0 + s * 40.0);
    vec3 sc = mix(vec3(1.1, 1.05, 1.0), palVisual(s * 3.0, u), 0.5);
    return neb + sc * star * tw * (1.6 + hi * 2.0) * (0.4 + rich) * starDamp;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    float gravity = mix(0.55, 1.60, u.param0);
    float eager = mix(-0.06, 0.10, u.param1);
    float rich = mix(0.2, 1.0, u.param2);

    // Music drive without strobing: band levels lean on the sustained level
    // (instant bands only nudge), and the beat is a swell that rises over
    // ~150 ms (0.3 beat at 120 bpm) and falls back to zero before the wrap.
    float lvl = saturate(u.level);
    float bp = u.beatPhase;
    float swell = smoothstep(0.0, 0.30, bp) * (1.0 - smoothstep(0.30, 1.0, bp)) * saturate(lvl * 1.4);
    float lo = mix(lvl, u.bass, 0.25);
    float md = mix(lvl, u.mid, 0.25);
    float hi = mix(lvl, u.treble, 0.25);

    // merge state: sustained level approximated with a slow accumulator fake
    float sustain = lvl * (0.55 + 0.45 * sin(u.time * 0.045)) + 0.06;
    float merge = smoothstep(0.50 - eager, 0.68 - eager, sustain);

    // masses on Lissajous orbits, spiraling in as merge rises
    float shrink = 1.0 - merge * 0.85;
    vec2 M0 = vec2(sin(u.time * 0.40) * 0.65,        cos(u.time * 0.31) * 0.39) * shrink;
    vec2 M1 = vec2(sin(u.time * 0.40 + 2.4) * 0.80,  cos(u.time * 0.31 + 2.4) * 0.48) * shrink;
    vec2 M2 = vec2(sin(u.time * 0.40 + 4.6) * 0.50,  cos(u.time * 0.31 + 4.6) * 0.30) * shrink;
    float S0 = (0.05 + lo * 0.30 + swell * 0.04) * gravity;
    float S1 = (0.02 + md * 0.13) * gravity;
    float S2 = (0.008 + hi * 0.06) * gravity;

    vec2 bh = (M0 + M1 + M2) / 3.0;
    float bhS = merge * (0.35 + lo * 0.30 + swell * 0.025) * gravity;

    // artwork detail estimate (blend art into the nebula only if it has detail)
    vec3 imA = IMG(photoCover(vec2(0.25, 0.30), u.resolution, IMGSIZE)).rgb;
    vec3 imB = IMG(photoCover(vec2(0.75, 0.62), u.resolution, IMGSIZE)).rgb;
    vec3 imC = IMG(photoCover(vec2(0.50, 0.85), u.resolution, IMGSIZE)).rgb;
    float detail = length(imA - imB) + length(imB - imC);
    float artAmt = smoothstep(0.10, 0.45, detail) * 0.30 * rich;

    vec3 col = vec3(0.0);
    float stretch = 0.0;
    // One gravitational integration (G = 1); the chromatic channels are the
    // same deflection scaled by +-4.5%, which is indistinguishable from
    // integrating three times and costs a third of the force evaluations.
    vec2 q = p;
    for (int i = 0; i < 26; ++i) {
        vec2 acc = vec2(0.0);
        vec2 d0 = q - M0; float r0 = dot(d0, d0) + 0.004;
        acc -= d0 * (S0 * (1.0 - merge)) / (r0 * sqrt(r0)) * 0.016;
        vec2 d1 = q - M1; float r1 = dot(d1, d1) + 0.004;
        acc -= d1 * (S1 * (1.0 - merge)) / (r1 * sqrt(r1)) * 0.016;
        vec2 d2 = q - M2; float r2 = dot(d2, d2) + 0.004;
        acc -= d2 * (S2 * (1.0 - merge)) / (r2 * sqrt(r2)) * 0.016;
        vec2 db = q - bh; float rb2 = dot(db, db) + 0.002;
        acc -= db * (bhS) / (rb2 * sqrt(rb2)) * 0.016;
        q += acc;
    }
    vec2 defl = q - p;
    stretch = length(defl);
    // Screen-space magnification of the lensed coordinate: where one pixel
    // spans many source texels, point stars and artwork would alias into
    // speckle, so fade them by the gradient ratio instead of drawing noise.
    float magn = length(fwidth(q)) / max(length(fwidth(p)), 1e-6);
    float aliasDamp = 1.0 - smoothstep(1.15, 2.4, magn);
    float dm = min(length(p - M0), min(length(p - M1), length(p - M2)));
    // stars also die where the lens magnifies (magn << 1): blown-up grid cells
    // read as blocks, not points
    float starDamp = exp(-stretch * 28.0) * smoothstep(0.06, 0.55, dm) * aliasDamp
                   * smoothstep(0.25, 0.7, magn);
    float core = mix(1.0, 0.18, smoothstep(0.10, 0.40, stretch));

    for (int ch = 0; ch < 3; ++ch) {
        float G = 1.0 + (float(ch) - 1.0) * 0.045; // chromatic gravity dispersion
        vec2 qc = p + defl * G;
        vec3 b = lensNebula(qc, u, rich, starDamp, hi);
        // deep lens interior demagnifies: light bends away, the core darkens;
        // and where the nebula's own detail passes the pixel rate it fades
        // instead of aliasing into dust
        b *= core * mix(0.12, 1.0, aliasDamp);
        vec3 art = IMG(photoCover(clamp(qc * 0.30 + 0.5, vec2(0.0), vec2(1.0)), u.resolution, IMGSIZE)).rgb;
        b += art * art * art * artAmt * 1.4 * aliasDamp * smoothstep(0.2, 0.5, magn); // cubed: keep blacks black, lift lights
        col[ch] = b[ch];
    }

    // gravitational magnification: a gentle lift right at the onset of
    // deflection (the arc annulus), fading again inside the lens
    float crit = exp(-((stretch - 0.055) * 26.0)*((stretch - 0.055) * 26.0));
    col *= 1.0 + crit * (0.5 + lo * 0.5 + swell * 0.2);

    // photon rings hugging each free mass — the lens made visible
    float pr0 = exp(-abs(length(p - M0) - (0.050 + S0 * 0.55)) * 90.0);
    float pr1 = exp(-abs(length(p - M1) - (0.040 + S1 * 0.75)) * 110.0);
    float pr2 = exp(-abs(length(p - M2) - (0.032 + S2 * 0.95)) * 130.0);
    // dim neon halo under each thin ring (well under a flash step)
    pr0 += 0.14 * exp(-abs(length(p - M0) - (0.050 + S0 * 0.55)) * 24.0);
    pr1 += 0.14 * exp(-abs(length(p - M1) - (0.040 + S1 * 0.75)) * 28.0);
    pr2 += 0.16 * exp(-abs(length(p - M2) - (0.032 + S2 * 0.95)) * 32.0);
    float free = 1.0 - merge;
    // (soft, below clip: thin rings driven past white pop on and off)
    col += palVisual(0.20, u) * pr0 * free * (0.7 + lo * 0.6 + swell * 0.35);
    col += palVisual(0.42 + 0.08 * u.spectralCentroid, u) * pr1 * free * (0.5 + md * 0.6);
    col += palVisual(0.70, u) * pr2 * free * (0.6 + hi * 0.6);

    // event horizon swallows light; photon ring blazes just outside it
    float rb = length(p - bh);
    float horizon = bhS * 0.55;
    col *= smoothstep(horizon * 0.85, horizon * 1.05, rb);
    float ring = exp(-abs(rb - horizon * 1.35) * 60.0) * merge;
    col += vec3(2.2, 1.7, 1.0) * ring * (2.6 + lo * 0.8 + swell * 0.9);

    // accretion ripples: each beat a soft ring leaves each free mass and fades
    // out as it expands (attack ~150 ms, gone before the next beat)
    float rr = 0.06 + 0.14 * bp;
    float fl0 = exp(-abs(length(p - M0) - rr) * 45.0);
    float fl1 = exp(-abs(length(p - M1) - rr) * 45.0);
    float fl2 = exp(-abs(length(p - M2) - rr) * 45.0);
    float flAmt = smoothstep(0.0, 0.30, bp) * (1.0 - bp) * (1.0 - bp) * lvl * free * 0.9;
    col += palVisual(0.20, u) * fl0 * flAmt;
    col += palVisual(0.45, u) * fl1 * flAmt * 0.7;
    col += palVisual(0.68, u) * fl2 * flAmt * 0.5;

    // merge flash lifts toward peak white, gently
    col = peakWhite(col, ring * 0.10);

    // deep-space vignette: the frame edge falls to true black
    col *= exp(-dot(p, p) * 0.85);
    col = lensNoRed(max(col, vec3(0.0)));

    // faint afterglow trail: redshifted persistence
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.62) * 0.72, 0.004, 0.0);

    return col; // LINEAR HDR
}
