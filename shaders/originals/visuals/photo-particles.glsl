// SPDX-License-Identifier: AGPL-3.0-only
// Photo particles.
// The photo is a wall of tiny glossy beads, each one carrying its pixel's
// colour. A dissolve front eats into the wall with a glowing ember edge, and
// the freed beads break away and stream toward the camera in perspective,
// keeping their colour, stretching into streaks at speed and opening into soft
// bokeh as they pass the lens. The stream drifts at a slow, nearly steady
// pace, the wall dissolves a little further on the bursts and re-forms in the
// breakdown, and the level and spectrum softly light the particles in palette
// colour. The beads grade the photo through the palette wheel, which turns
// slowly with the beat count; a faint pulse runs out across the wall on each
// beat, and the ember edge and some of the particles burn in the palette's
// complement. Nothing flashes on the kick and the view never banks.
// param0 = Particle Size ; param1 = Scatter ; param2 = Color

vec3 ppPhoto(vec2 o, float aspect, VisualUniforms u) {
    vec2 s = (o / vec2(aspect, 1.0)) * 0.5 + 0.5;
    return max(IMG(photoCover(clamp(s, 0.0, 1.0), u.resolution, IMGSIZE)).rgb, vec3(0.0));
}

// cyclic blend of four palette samples read once per pixel (each palette
// read is costly, so the visual reads four and interpolates)
vec3 pkPal(float t, vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
    float x = fract(t) * 4.0;
    float i = floor(x);
    float f = smoothstep(0.0, 1.0, x - i);
    vec3 a = i < 1.0 ? c0 : (i < 2.0 ? c1 : (i < 3.0 ? c2 : c3));
    vec3 b = i < 1.0 ? c1 : (i < 2.0 ? c2 : (i < 3.0 ? c3 : c0));
    return mix(a, b, f);
}
#define PKPAL(t) pkPal(t, kc0, kc1, kc2, kc3)

// The photo's own key colour: nine fixed taps averaged. The taps do not
// depend on the pixel, so every pixel agrees and the cost is tiny.
vec3 pkKey(VisualUniforms u) {
    vec3 s = vec3(0.0);
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        vec2 g = vec2(mod(fi, 3.0), floor(fi / 3.0)) * 0.3 + 0.2;
        s += max(IMG(photoCover(g, u.resolution, IMGSIZE)).rgb, vec3(0.0));
    }
    return s / 9.0;
}

// An accent complementary to the photo: the palette stop whose hue sits
// furthest from the photo's key, pushed toward the key's true complement
// (the more colourful the photo, the harder the push).
vec3 pkAccent(vec3 key, vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
    vec3 kc = key - vec3(luma(key));
    float ks = length(kc);
    vec3 kn = kc / max(ks, 1e-4);
    vec3 best = c0;
    float bd = dot(c0 - vec3(luma(c0)), kn) / max(length(c0 - vec3(luma(c0))), 1e-4);
    float d1 = dot(c1 - vec3(luma(c1)), kn) / max(length(c1 - vec3(luma(c1))), 1e-4);
    float d2 = dot(c2 - vec3(luma(c2)), kn) / max(length(c2 - vec3(luma(c2))), 1e-4);
    float d3 = dot(c3 - vec3(luma(c3)), kn) / max(length(c3 - vec3(luma(c3))), 1e-4);
    if (d1 < bd) { best = c1; bd = d1; }
    if (d2 < bd) { best = c2; bd = d2; }
    if (d3 < bd) { best = c3; bd = d3; }
    vec3 comp = max(vec3(0.33) - kn * 0.75, vec3(0.0));
    vec3 a = mix(best, comp * 1.6, saturate(ks * 6.0) * 0.6);
    return a / max(max(a.r, max(a.g, a.b)), 0.05);
}

// three-octave value noise normalised to about [0, 1]
float ppNoise(vec2 p) {
    float v = 0.5 * vnoise(p);
    p = FBM_OCTAVE * p;
    v += 0.25 * vnoise(p);
    p = FBM_OCTAVE * p;
    v += 0.125 * vnoise(p);
    return v * 1.1428571;
}

// how far the wall at o has dissolved: 0 intact, 1 gone
float ppGone(vec2 o, float diss, float drift) {
    float n = ppNoise(o * 1.3 + vec2(drift, 0.4 * drift));
    // the front starts at the frame edges and works inward
    n = n * 0.6 + 0.4 * saturate(1.0 - length(o) * 0.42);
    return smoothstep(n - 0.035, n + 0.035, diss);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    float detail = osDetail(u);
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = centered(uv, u.resolution);   // y grows downward
    float t = mod(u.time, 600.0);

    float sizeAmt = mix(1.35, 0.75, u.param0);   // larger param -> bigger particles
    float scatter = mix(0.4, 1.5, u.param1);
    float chroma  = mix(0.15, 0.75, u.param2);

    vec2 fl = osFlight(u, 2.4, -0.6);
    float dz = mod(fl.x, 1000.0);
    float rush = saturate((fl.y - 1.0) / 3.5);

    // the dissolve follows the 32-beat cycle: deepest on the two bursts
    float cyc = mod(u.beatCount + saturate(u.beatPhase), 32.0);
    float burst = max(smoothstep(8.0, 0.0, abs(cyc - 10.0)), smoothstep(6.0, 0.0, abs(cyc - 29.5)));
    burst = max(burst, smoothstep(4.0, 0.0, abs(cyc + 2.5)));
    float diss = (0.38 + 0.08 * burst) * (0.55 + 0.45 * scatter);
    float drift = 0.03 * t;
    // the colour wheel turns a little every beat and leans further in a rush
    float bcount = u.beatCount + saturate(u.beatPhase);
    float hueOff = mod(bcount, 256.0) * (0.137 / 16.0) + 0.02 * rush;
    vec3 kc0 = palVisual(0.04, u);
    vec3 kc1 = palVisual(0.34, u);
    vec3 kc2 = palVisual(0.64, u);
    vec3 kc3 = palVisual(0.80, u);
    // complementary accent: the hue opposite the palette's lead colour
    vec3 lead = PKPAL(hueOff + 0.80);
    float lmx = max(lead.r, max(lead.g, lead.b));
    float lmn = min(lead.r, min(lead.g, lead.b));
    vec3 acc = (vec3(lmx + lmn) - lead) / max(lmx, 1e-3);
    // the accent that answers the photo itself
    vec3 accent = pkAccent(pkKey(u), kc0, kc1, kc2, kc3);
    acc = mix(acc, accent, 0.7);

    // the wall sits in gentle perspective that eases from side to side
    vec2 tilt = vec2(0.06 * sin(t * 0.031), 0.04 * sin(t * 0.023 + 1.0));
    vec2 P = p / (1.0 + dot(tilt, p)) * 0.96;

    // ---- the bead wall ----
    float nb = 24.0 * sizeAmt;
    vec2 bg = P * nb;
    vec2 bc = floor(bg);
    vec2 bf = bg - bc - 0.5;
    vec2 bo = (bc + 0.5) / nb;
    vec3 pc0 = ppPhoto(bo, aspect, u);
    float lum = luma(pc0);
    vec3 pc = pc0 * pc0 * 1.5;
    float gone = ppGone(bo, diss, drift);
    // beads at the front swell as they lift off toward the camera, then go
    float lift = smoothstep(0.0, 0.5, gone) * (1.0 - smoothstep(0.5, 1.0, gone));
    float br = min((0.40 + 0.06 * lum) * (1.0 + 0.25 * lift), 0.49) * (1.0 - smoothstep(0.55, 1.0, gone));
    float bd = length(bf);
    float bead = smoothstep(br, br - 0.06, bd);
    // each bead is a tiny glossy sphere lit from the upper left
    vec2 bn2 = bf / max(br, 1e-3);
    float bz = sqrt(max(1.0 - dot(bn2, bn2), 0.0));
    vec3 bn = vec3(bn2, bz);
    float lam = 0.30 + 0.95 * saturate(dot(bn, normalize(vec3(-0.5, -0.6, 0.65))));
    float spec = pow(saturate(dot(bn, normalize(vec3(-0.25, -0.3, 1.0)))), 40.0);
    float hb = hash21(bc);
    float shimmer = bandAt(u, hb);
    // a pulse runs out across the wall on every beat, swinging the hue
    float bph = saturate(u.beatPhase);
    float pulse = exp(-pow((length(bo) - 2.4 * bph) / 0.18, 2.0)) * (1.0 - bph);
    // the bead grades its pixel through the palette wheel: dark pixels sink to
    // the deep end, bright ones climb into the lead colours
    vec3 tintB = PKPAL(hueOff + 0.20 + 0.62 * lum + 0.10 * hb + 0.06 * pulse);
    vec3 tn = tintB / max(max(tintB.r, max(tintB.g, tintB.b)), 0.05);
    vec3 duoB = tn * tn * lum * (0.15 + 0.85 * lum);
    // the beads keep the photo's own colour; the palette only grades them
    // matched to the photo's own value so the grade shifts hue, never brightness
    vec3 tq = tn * tn;
    duoB = tq * (luma(pc) * 0.62 / max(max(tq.r, max(tq.g, tq.b)), 0.05));
    vec3 beadCol = mix(pc * 0.62, duoB, (0.1 + 0.5 * chroma) * (1.0 - smoothstep(0.1, 0.6, lum))) * lam * (0.88 + 0.12 * u.level + 0.12 * shimmer);
    beadCol *= 1.0 + pulse * 0.10;
    beadCol += accent * accent * pulse * 0.04 * lam;
    beadCol = max(mix(vec3(luma(beadCol)), beadCol, 1.7), vec3(0.0));
    beadCol += mix(vec3(1.1), tintB * 1.6, 0.5) * spec * (0.20 + 0.4 * lum) * (0.8 + 0.2 * u.level);
    // a soft light sweep crosses the wall on the flight clock
    float sw = bo.x * 0.55 + bo.y * 0.35 - (mod(dz * 0.06, 7.0) - 3.5);
    float sweep = exp(-sw * sw * 6.0);
    beadCol *= 1.0 + 0.2 * sweep;
    beadCol += PKPAL(hueOff + 0.62 + 0.2 * hb) * sweep * spec * 0.8;
    beadCol *= 1.0 + 1.2 * lift;
    vec3 col = beadCol * bead;

    // what lies behind the wall: a deep haze lit faintly by the photo
    float goneC = ppGone(P, diss, drift);
    // a distant duotone copy of the photo, graded into the palette
    vec3 far = ppPhoto(P * 0.7 + vec2(0.08 * tilt.x, 0.0), aspect, u);
    float fl2 = luma(far);
    vec3 duo = PKPAL(hueOff + 0.12 + 0.6 * fl2);
    vec3 deep = duo * duo * (0.06 + 0.5 * fl2 * fl2) + kc1 * 0.02;
    col += deep * (1.0 - bead) * (0.06 + 0.40 * goneC);

    // the ember edge of the dissolve front
    float edge = 1.0 - abs(2.0 * goneC - 1.0);
    float eGlow = smoothstep(0.0, 1.0, edge);
    // deep saturated halo outside, a thin complementary filament at the crest
    vec3 eOut = PKPAL(hueOff + 0.52);
    eOut /= max(max(eOut.r, max(eOut.g, eOut.b)), 0.05);
    eOut = mix(eOut * eOut, accent * accent, 0.6);
    vec3 eHot = acc * acc;
    float eAmp = 0.75 + 0.25 * u.level;
    col += (eOut * eGlow * eGlow * eGlow * 0.32 + eHot * pow(eGlow, 18.0) * 0.55) * eAmp;

    // ---- freed particles streaming toward the camera ----
    int nl = osSteps(3.0, 7.0, detail);
    float nf = 10.0 * sizeAmt;
    float pr = length(P);
    for (int i = 0; i < 7; i++) {
        if (i >= nl) break;
        float fi = float(i);
        float zt = fi / float(nl) + dz * 0.02;
        float z = fract(zt);
        float cycle = mod(floor(zt), 20.0);
        float s = 1.0 / (1.0 - 0.93 * z);           // perspective scale
        vec2 o = P / s;                               // where this point left the wall
        vec2 g = o * nf;
        vec2 c = floor(g);
        vec2 f = g - c - 0.5;
        vec2 id = c + vec2(37.0 * fi, 101.0 * cycle);
        float h = hash21(id);
        vec2 co = (c + 0.5) / nf;
        float freed = ppGone(co, diss, drift);
        float dens = 0.45;
        if (h > dens * (freed > 0.5 ? 1.0 : 0.10)) continue;

        vec2 hj = hash22(id + 3.3);
        vec2 cj = (hj - 0.5) * 0.58;
        vec2 df = f - cj;
        // stretch along the flight direction, more when fast and close
        vec2 rd = pr > 1e-3 ? P / pr : vec2(1.0, 0.0);
        float rad = 0.05 + 0.05 * fract(hj.x * 7.1);
        float st = min((0.5 + 0.6 * rush) * z, 0.20 / rad - 1.0);
        float dr = dot(df, rd);
        float dtg = dot(df, vec2(-rd.y, rd.x));
        float dist = length(vec2(dr / (1.0 + st), dtg));
        // near the camera the particle falls out of focus into a soft disc
        float soft = mix(0.25, 0.95, smoothstep(0.55, 1.0, z));
        float m = smoothstep(rad, rad * (1.0 - soft), dist);
        float fade = smoothstep(0.0, 0.08, z) * smoothstep(1.0, 0.86, z) * (1.0 - 0.55 * smoothstep(0.6, 1.0, z));

        vec3 src = ppPhoto(co, aspect, u);
        src *= src * 1.5;
        float bandL = bandAt(u, h / max(dens, 1e-3));
        vec3 spec2 = fract(h * 5.7) < 0.22 ? acc : PKPAL(hueOff + 0.38 + 0.42 * fract(h * 2.3) + 0.1 * z);
        spec2 *= spec2 * 1.4;
        vec3 pcol = mix(src * 1.3, spec2 * (0.5 + luma(src)), 0.25 + 0.45 * chroma) * (0.6 + 0.25 * u.level + 0.25 * bandL);
        pcol += mix(vec3(1.0), spec2, 0.5) * 1.2 * smoothstep(rad * 0.45, 0.0, dist) * (1.0 - soft) * 0.4;
        col += pcol * m * fade;
    }

    // vignette keeps the corners deep
    col *= 1.0 - 0.5 * smoothstep(0.9, 2.1, length(p));
    return col; // LINEAR HDR — post chain tonemaps
}
