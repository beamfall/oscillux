// SPDX-License-Identifier: AGPL-3.0-only
// Braid — three luminous threads (bass / mid / treble) braiding
// around a shared horizontal axis in pseudo-3D. Each thread's radial
// displacement is its own band trace; the beat clock turns the braid;
// crossings emit sparks timed to beats; depth-sorted occlusion with HDR
// thread cores and a silk afterglow ribbon swept behind each thread.
// Flash budget (Makefile visual-flash-check): only the thin cores are bright.
// Glow and silk stay in one dim luminance band, the braid turns at a steady
// beat-locked rate and no colour sits at saturated red, so the moving threads
// make no large-area flashes under loud audio.
// param0 Twist ; param1 Core Heat ; param2 Sparks

// c scaled down so that, once a filmic display curve (ACES fit) has shown
// it, its Rec.709 luminance is at most cap: the curve lifts mid tones, so the
// cap is judged on screen, not on the HDR value.
vec3 braidDisplayCap(vec3 c, float cap) {
    for (int k = 0; k < 2; ++k) {
        vec3 shown = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);
        c *= pow(min(1.0, cap / max(luma(shown), 1e-6)), 0.7);
    }
    return c;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float x01 = saturate(uv.x);

    float twist = mix(0.9, 2.6, u.param0);
    float heat = mix(1.4, 3.6, u.param1);
    float sparkAmt = mix(0.4, 2.4, u.param2);
    // silk afterglow: how far back along the turn the ribbon reaches (radians)
    float silkLen = mix(0.25, 0.95, saturate(u.trailDecay / 0.9));

    // continuous beat-time: the braid turns at a steady beat-locked rate
    float tt = u.beatCount + u.beatPhase;
    float spin = tt * 0.60 + u.time * 0.10;
    float theta = x01 * twist * 6.2831853 + spin;

    // per-thread band traces (radial displacement is the thread's own band)
    float trace0 = bandAt(u, x01 * 0.22);                 // bass
    float trace1 = bandAt(u, 0.30 + x01 * 0.30);          // mid
    float trace2 = bandAt(u, 0.66 + x01 * 0.30);          // treble

    float baseR = 0.20 + 0.06 * u.amplitude;

    float zs[3];
    float rads[3];
    rads[0] = baseR * (0.70 + 0.45 * trace0);
    rads[1] = baseR * (0.70 + 0.45 * trace1);
    rads[2] = baseR * (0.70 + 0.45 * trace2);

    vec3 silk = vec3(0.0);
    vec4 frag[3]; // rgb = premultiplied-ish color, w = coverage
    float px = max(fwidth(p.y), 1e-5);
    for (int i = 0; i < 3; ++i) {
        float ph = theta + float(i) * 2.0943951;          // 2pi/3 apart
        float waver = sin(x01 * 9.0 + u.time * 0.8 + float(i) * 2.1) * 0.012;
        zs[i] = cos(ph);                                   // -1 far .. +1 near
        float persp = 1.0 / (1.75 - 0.62 * zs[i]);         // pseudo-3D scale
        float y = (sin(ph) * rads[i] + waver) * persp;
        float d = p.y - y;

        float band = (i == 0) ? trace0 : ((i == 1) ? trace1 : trace2);
        vec3 c;
        if (i == 0) c = palRoleBass(x01 * 0.30, u) * (0.8 + 2.0 * trace0);
        else if (i == 1) c = palRoleTrace(0.35 + x01 * 0.30, u) * (0.8 + 2.0 * trace1);
        else c = palRoleTreble(x01 * 0.5, u) * (0.8 + 2.2 * trace2);
        c = accentize(c, u.accent, 0.08);
        float lum = persp * persp;                         // near = brighter

        // ---- thread: thin white-hot core, dim glow ----
        float wgt = (i == 0) ? 1.45 : ((i == 1) ? 1.0 : 0.7);  // bass fat, treble fine
        float w = 0.0042 * wgt * persp * (1.25 + 0.35 * band);
        float core = aaLine(d, w * 0.55) * 1.8 + aaLine(d, w) * 0.6;
        float halo = aaLine(d, w * 4.0) * 0.12;
        float sheen = exp(-d * d / (0.0035 * persp + 1e-5)) * 0.08;
        vec3 glow = braidDisplayCap(c * (halo + sheen) * lum * 0.45, 0.06);
        frag[i] = vec4(c * core * heat * lum + glow,
                       saturate(aaLine(d, w) * 0.95 + halo * 0.4));

        // ---- silk: the band the thread swept over the last silkLen radians ----
        float phL = ph - silkLen;
        float perspL = 1.0 / (1.75 - 0.62 * cos(phL));
        float yL = (sin(phL) * rads[i] + waver) * perspL;
        float lo = min(y, yL), hi = max(y, yL);
        float inside = clamp((p.y - lo) / px + 0.5, 0.0, 1.0)
                     * clamp((hi - p.y) / px + 0.5, 0.0, 1.0);
        float s = clamp((p.y - yL) / (y - yL + ((y >= yL) ? 1e-4 : -1e-4)), 0.0, 1.0);
        silk += c * inside * s * s * lum * 0.5;
    }
    vec3 col = braidDisplayCap(silk, 0.06);

    // ---- depth sort far -> near (3-element bubble) and composite ----
    for (int pass = 0; pass < 2; ++pass) {
        for (int i = 0; i < 2; ++i) {
            if (zs[i] > zs[i + 1]) {
                float tz = zs[i]; zs[i] = zs[i + 1]; zs[i + 1] = tz;
                vec4 tf = frag[i]; frag[i] = frag[i + 1]; frag[i + 1] = tf;
            }
        }
    }
    for (int i = 0; i < 3; ++i) {
        col = col * (1.0 - frag[i].w * 0.92) + frag[i].rgb;  // near occludes far
    }

    // ---- crossing sparks, timed to beats (small points only) ----
    float gate = phasePulse(u, 0.0, 0.14) * (0.4 + 0.8 * u.beat) + u.onset * 0.4;
    for (int i = 0; i < 3; ++i) {
        int j = (i + 1) % 3;
        float pi_ = theta + float(i) * 2.0943951;
        float pj_ = theta + float(j) * 2.0943951;
        float yi = sin(pi_) * rads[i];
        float yj = sin(pj_) * rads[j];
        float cross_ = exp(-((yi - yj) * 22.0)*((yi - yj) * 22.0));    // threads meeting
        float dpix = p.y - (yi + yj) * 0.5;
        float hot = exp(-dpix * dpix / 0.0003);
        // spark scatter around the crossing point
        float n = hash21(vec2(floor(x01 * 48.0), floor(u.beatCount)));
        float sparkle = step(0.72, n) * exp(-dpix * dpix / 0.00015);
        vec3 sc = palRolePeak(0.5 + 0.2 * u.spectralCentroid, u);
        col += sc * (hot * 0.5 + sparkle * 4.2) * cross_ * cross_ * gate * sparkAmt;
    }
    // axis ghost: the shared axis the braid winds around
    col += palRoleFog(0.5, u) * exp(-p.y * p.y / 0.002) * 0.05 * (0.4 + 0.6 * u.amplitude);

    // keep clear of saturated red on screen: green + blue at least 0.8 of red
    // (the display curve's toe darkens the weaker channels further)
    float deficit = max(0.0, 0.8 * col.r - col.g - col.b);
    col.g += 0.6 * deficit;
    col.b += 0.4 * deficit;
    return col;
}
