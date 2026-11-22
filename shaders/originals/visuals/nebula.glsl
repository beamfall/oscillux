// SPDX-License-Identifier: AGPL-3.0-only
// Nebula.
// A slow push into an emission nebula toward its blazing heart: a young star
// cluster whose light carves the gas. Seven depth layers of warped gas drift
// past at different scales, lit from the core, so every cloud edge that faces
// the core burns with an ionisation rim while the near dust stands dark
// against it. Soft light shafts stream out of the core through the gas, their
// strength around the circle following the spectrum. Each cloud is shaded
// from the core, so its lit face glows warm and its far side falls into
// shadow; the near layers stand as dark dust with burning rims, the ionised
// gas close to the core glows cyan. Every bar an ionisation wave rolls out of
// the core and sets the cloud edges alight as it passes. Stars sit on every
// layer, the brightest with six-point diffraction spikes, and stretch into
// short streaks when the push surges. The push follows the 32-beat speed profile
// (cruise, build, burst, brake, drift) and the roll eases to a new side every
// eight beats; audio drives light, never the camera. The push stays slow, the
// beat light swells smoothly and faintly, the core barely lifts with the bass and
// the colours never shimmer with the music, so the gas never flashes across
// large areas.
// param0 = Density ; param1 = Swirl ; param2 = Emission

// The palette read without the library's per-beat and spectral-centroid hue
// nudge, so large lit areas never shimmer with the music; under the host's
// palette tour the cross-fade between palettes is spread over the whole tour
// step, so the colours change slowly.
vec3 nbPalStill(float t, VisualUniforms u) {
    if (u.palette.x >= 0.0) return palByIndex(t, int(floor(u.palette.x + 0.5)));
    int a = int(mod(floor(u.palette.z), OS_PAL_COUNT));
    int b = int(mod(float(a + 1), OS_PAL_COUNT));
    float blend = smoothstep(0.0, 1.0, fract(u.palette.z));
    return mix(palByIndex(t, a), palByIndex(t, b), blend);
}

// The palette is read once per pixel at its five stops and blended locally:
// each library palette read walks the whole stop table, and this visual needs
// dozens of colours per pixel. nbPal follows the library blend closely.
struct NbPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

NbPal nbPalLoad(VisualUniforms u) {
    NbPal P;
    P.c0 = nbPalStill(0.0, u);
    P.c1 = nbPalStill(0.26, u);
    P.c2 = nbPalStill(0.52, u);
    P.c3 = nbPalStill(0.78, u);
    P.c4 = nbPalStill(0.999, u);
    return P;
}

vec3 nbPal(NbPal P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}


// fbm returning (all octaves, the first three octaves) so the broad shape is free
vec2 nbFbm(vec2 p, int oct) {
    float v = 0.0, a = 0.5, lo = 0.0;
    for (int i = 0; i < 6; ++i) {
        if (i >= oct) break;
        v += a * vnoise(p);
        if (i == 2) lo = v;
        p = FBM_OCTAVE * p;
        a *= 0.55;
    }
    return vec2(v, oct < 3 ? v : lo);
}

float nbFbm3(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; ++i) {
        v += a * vnoise(p);
        p = FBM_OCTAVE * p;
        a *= 0.5;
    }
    return v;
}

// One bright star with six-point diffraction spikes, d = offset from it.
float nbSpikes(vec2 d, float px, float len) {
    float s = 0.0;
    for (int k = 0; k < 3; ++k) {
        float a = float(k) * 1.0471976 + 0.5236;
        vec2 dir = vec2(cos(a), sin(a));
        float along = abs(dot(d, dir));
        float across = abs(dot(d, vec2(-dir.y, dir.x)));
        s += exp(-across / px * 1.3) * exp(-along / len * 3.0);
    }
    float r = length(d);
    return s * 0.6 + 2.0 * exp(-r * r / (px * px * 2.0)) + 0.4 * exp(-r / (px * 6.0));
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float px = 2.0 / max(u.resolution.y, 1.0);
    float detail = osDetail(u);
    // all seven layers at every level, so level 0 keeps the composition; the
    // ladder trims octaves instead
    int nl = 7;
    NbPal P = nbPalLoad(u);
    int oct = osSteps(3.0, 5.0, detail);
    float t = mod(u.time, 600.0);

    float densAmt = mix(0.45, 1.0, u.param0);
    float swirl = mix(0.2, 1.3, u.param1);
    float emit = mix(0.6, 1.7, u.param2);

    vec2 fl = osFlight(u, 0.38, 0.08);
    float camZ = mod(fl.x, 4096.0);
    float rush = saturate((fl.y - 1.0) / 3.5);
    p = rot2(osBank(u, 0.14)) * p;
    p *= 1.0 - 0.06 * rush;   // the view widens a touch as the push surges

    // the core: a star cluster deep in the cloud, drifting slowly in frame
    vec2 c = vec2(0.30 + 0.14 * sin(t * 0.021), 0.06 + 0.09 * sin(t * 0.029 + 1.0));
    vec2 pc = p - c;
    float r = length(pc);
    vec2 toC = -pc / max(r, 1e-4);

    // ionisation wave: every bar it leaves the core, slowing as it spreads
    float bp = saturate(u.beatPhase);
    float b4 = (mod(u.beatCount, 4.0) + bp) * 0.25;
    // each beat the rims swell and settle on a smooth bell (accents only, never
    // the whole frame; a sharp kick flare sets large areas flashing)
    float kick = (0.5 - 0.5 * cos(6.2831853 * bp)) * (0.2 + 0.3 * u.bass);
    float waveR = 0.04 + 1.5 * (1.0 - (1.0 - b4) * (1.0 - b4));
    float waveA = (1.0 - b4) * (1.0 - b4) * smoothstep(0.0, 0.25, b4) * (0.45 + 0.25 * u.bass);
    float waveW = 0.05 + 0.12 * b4;

    float bassLift = 0.97 + 0.06 * u.bass;
    vec3 hot = nbPal(P, 0.70);
    vec3 white = peakWhite(hot, 0.75);
    vec3 cyan = nbPal(P, 0.97);
    vec3 warm = nbPal(P, 0.66);

    // deep background, the ionised cyan glow round the core, the core itself
    vec3 col = P.c0 * 0.006 + nbPal(P, 0.08) * 0.035 * exp(-r * 1.2);
    col += white * (3.0 * exp(-r * r * 300.0) + 0.35 * exp(-r * 12.0)) * bassLift;
    col += cyan * 0.2 * exp(-r * 3.2) * bassLift;
    // the cluster: a knot of hot young stars around the core
    for (int k = 0; k < 9; ++k) {
        vec2 hk = hash22(vec2(float(k), 17.3)) - 0.5;
        vec2 d = pc - hk * vec2(0.16, 0.11) * (0.4 + float(k) * 0.08);
        float tw = 0.8 + 0.2 * sin(t * (1.3 + float(k) * 0.37) + float(k));
        vec3 sc = mix(white, vec3(1.3, 1.7, 2.4), hash11(float(k) + 3.0));
        col += sc * nbSpikes(d, px, 0.025 + 0.015 * hash11(float(k))) * 0.3 * tw * bassLift;
    }

    // gas layers, far to near; each layer keeps its identity as it moves forward
    float fz = fract(camZ);
    float iz = floor(camZ);
    float n = float(nl);
    float nearDust = 0.0;
    for (int j = 0; j < 7; ++j) {
        if (j >= nl) break;
        float z = (float(j) + fz) / n;                 // 0 far .. 1 near
        float id = mod(float(j) - iz, 256.0);
        vec2 seed = hash22(vec2(id, 3.7)) * 40.0;
        float dist = 1.3 - z;
        float fade = smoothstep(0.0, 0.22, z) * (1.0 - smoothstep(0.74, 1.0, z));
        mat2 lr = rot2(id * 1.9 + swirl * 0.25 * sin(t * 0.04 + id));
        vec2 lp = lr * (pc * dist * 1.25) + seed;
        vec2 wq = vec2(vnoise(lp * 0.6 + 3.1), vnoise(lp * 0.6 + 8.3)) - 0.5;
        lp += wq * swirl * 0.9;
        vec2 g = nbFbm(lp, oct);
        // broad voids keep deep black space between the clouds
        float voids = smoothstep(0.38, 0.68, vnoise(lp * 0.22 + 5.7));
        // fine ridged filaments threading the gas; they also fray the cloud edges
        float fil = 1.0 - abs(vnoise(lp * 3.6 + wq * 2.0) * 2.0 - 1.0);
        fil = fil * fil * fil;
        float ero = vnoise(lp * 8.5 - wq * 3.0) - 0.5;
        float gx = g.x + ero * (0.05 + 0.06 * z) + fil * 0.035;
        // light from the core: the broad density falling toward the core means
        // a face turned to it (lit), rising means a face turned away (shadow)
        float g2 = nbFbm3(lp + lr * toC * 0.16);
        float edge = g.y - g2;
        float facing = saturate(0.45 + edge * 7.0);
        float lit = exp(-r * (1.5 + 1.8 * z)) * (1.0 - 0.5 * z);
        // the wave front is bent by the gas it runs through, so it reads as a
        // ragged shock rather than a circle
        float wd = (r - waveR + (g.x - 0.5) * 0.5 + (fil - 0.3) * 0.06) / waveW;
        float wave = exp(-wd * wd) * waveA;
        lit = lit / (1.0 + 0.7 * lit);
        float midE = bandAt(u, 0.15 + 0.6 * hash11(id + 1.0));
        float far = 1.0 - 0.75 * z;

        // 1. glowing gas: broad, soft and translucent, added over what lies behind.
        // Violet and magenta far out, warm where a face turns to the core, cyan
        // where the gas is ionised close to it.
        float glow = smoothstep(0.36, 0.78, g.x) * voids * (0.55 + 0.9 * fil);
        float ion = exp(-r * 3.0) * (1.0 - 0.6 * z);
        vec3 gas = mix(nbPal(P, 0.08 + 0.2 * hash11(id) + 0.1 * rush), warm, 0.55 * smoothstep(0.15, 0.7, lit * facing));
        gas = mix(gas, cyan, saturate(ion * 1.5));
        vec3 em = gas * glow * (0.025 + 0.9 * lit * (0.3 + 0.9 * facing) + 0.15 * wave * fil) * far;

        // 2. dust: crisp, frayed and dark, it swallows the light behind it; its
        // edge facing the core burns with an ionisation rim
        float dust = smoothstep(0.507, 0.537, gx) * voids;
        float dustA = dust * fade * densAmt * mix(0.35, 0.96, z);
        // a thin burning front at the dust edge that fades into the dust behind it
        float rim = smoothstep(0.0, 0.05, edge) * smoothstep(0.483, 0.505, gx) * exp(-max(gx - 0.505, 0.0) * 60.0) * voids;
        vec3 rimCol = mix(hash11(id + 4.0) < 0.5 ? cyan : warm, white, 0.25 * lit + 0.4 * wave);
        em += rimCol * rim * (0.05 + 3.2 * lit + 0.4 * wave) * (1.3 + 0.25 * midE + 0.2 * kick) * (0.5 + 0.9 * fil);
        em += nbPal(P, 0.1) * dust * (0.006 + 0.05 * facing * lit);   // faint lit face of the dust
        col = col * (1.0 - dustA) + em * fade * emit;
        float alpha = dustA;
        nearDust = max(nearDust, alpha * z);

        // stars on this layer, a few with diffraction spikes; they stretch
        // away from the core as the push surges
        float sd = 1.04 - z;
        vec2 sg = (pc * sd * 1.5 + seed) * 3.5;
        vec2 si = floor(sg);
        vec2 h = hash22(si + id * 7.0);
        if (h.x > 0.72) {
            vec2 sp = (si + 0.3 + 0.4 * hash22(si + 1.3 + id)) / 3.5 - seed;
            vec2 q = sp / (sd * 1.5);                    // star position from the core
            vec2 d = pc - q;
            float ql = length(q);
            vec2 qd = q / max(ql, 1e-3);
            float stretch = 1.0 + 4.0 * rush * z * z * min(ql, 1.2);
            float dr = dot(d, qd);
            d -= qd * dr * (1.0 - 1.0 / stretch);
            float big = step(0.972, h.x);
            float tw = 0.75 + 0.25 * sin(t * (2.0 + 3.0 * h.y) + h.y * 30.0);
            float br = (0.25 + 1.2 * h.y) * fade * (0.6 + 1.4 * z) * tw * (1.0 + 1.5 * u.treble * big) / sqrt(stretch);
            vec3 sc = mix(P.c4, vec3(1.0, 0.92, 0.85), 0.6);
            float shape = big > 0.5 ? nbSpikes(d, px, 0.05 + 0.08 * z) : 2.0 * exp(-dot(d, d) / (px * px * 1.5));
            // fade the glare out before the cell border so it never shows a seam
            vec2 cf = fract(sg);
            float win = smoothstep(0.0, 0.22, min(min(cf.x, 1.0 - cf.x), min(cf.y, 1.0 - cf.y)));
            col += sc * shape * br * win;
        }
    }

    // fine light shafts streaming out of the core, strength by spectrum around
    // the circle, held back where near dust stands in front
    float a = atan2_(pc.y, pc.x) / 6.2831853;
    float spec = bandAtWrapped(u, a + 0.5);
    float sh = vnoise(toC * 5.0 + vec2(t * 0.04, 0.0)) * 0.6 + vnoise(toC * 17.0 - vec2(0.0, t * 0.06)) * 0.4;
    float shafts = smoothstep(0.55, 0.95, sh) * (0.3 + 1.4 * spec);
    col += mix(warm, white, 0.4) * shafts * exp(-r * 2.6) * 0.12 * (1.0 - 0.85 * nearDust) * emit;

    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
