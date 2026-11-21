// SPDX-License-Identifier: AGPL-3.0-only
// Bloom.
// A petal storm. Far away a giant flower of light opens and breathes: two
// whorls of overlapping, cupped, backlit petals around a crown of glowing
// stamens, with light beams escaping through the gaps between the petals.
// Its petals tear loose and stream past the camera in a slow vortex. Each one
// is a curved, translucent shell lit from behind by the flower (warm light
// through the pigment) and from the front by the cool sky (an iridescent
// sheen that sweeps across it as it tumbles), sharp in the middle distance
// and soft as it drifts by. The stream flows at a slow, steady speed, so the
// petals never rush past fast enough to flash, and near petals fade out as
// they pass the lens. Audio drives light gently: the smoothed level with a
// light band term lights the petals, stamens, beams and veins, and each beat
// sends only a faint swell along the rims; no beat flares the beams or the
// heart, and petals turning edge-on no longer switch their sky fill.
// The palette is read without its per-frame centroid nudge and held at one
// mean luma, so the palette tour recolours the scene without brightening or
// darkening the whole frame.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 = Flow ; param1 = Color Spread ; param2 = Veins

// The palette read: the visual's own palette (8) with no beat or spectral
// nudge and no palette tour, so the host's vivid tour never swells the light;
// a host's manifest palette still replaces it. The fog tint is rebuilt on it.
vec3 blPalSteady(float t, VisualUniforms u) { return osPalCalm(t, 8, u); }
vec3 blPalSteadyFog(float t, VisualUniforms u) {
    vec3 c = blPalSteady(t, u);
    return mix(vec3(luma(c) * 0.62), c, 0.42);
}

// The palette without the per-frame centroid nudge (the raw centroid jumps
// from hop to hop and would flicker every petal at once), scaled by gk.
vec3 blPal(float t, VisualUniforms u, float gk) {
    return blPalSteady(t, u) * gk;
}

// One gain for the whole palette that holds its mean luma fixed, so the
// palette tour's crossfades change the colours but never brighten or darken
// the whole frame.
float blGain(VisualUniforms u) {
    float l = 0.25 * (luma(blPalSteady(0.125, u)) + luma(blPalSteady(0.375, u))
                    + luma(blPalSteady(0.625, u)) + luma(blPalSteady(0.875, u)));
    return clamp(0.32 / max(l, 1e-3), 0.4, 3.0);
}

// Petal in local units: base at y = -0.5, notched tip at y = 0.5.
// Returns an approximate signed distance.
float blPetal(vec2 q) {
    float y = q.y + 0.5;
    float yc = clamp(y, 0.0, 1.0);
    float w = 0.40 * sqrt(max(sin(3.14159265 * yc * sqrt(yc)), 0.0));
    float d = max(abs(q.x) - w, max(-y, y - 1.0));
    // the cherry-blossom notch at the tip
    d = max(d, 0.13 - length(q - vec2(0.0, 0.56)));
    return d;
}

// Value-noise fbm with a caller-chosen octave count (at most 4).
float blFbm(vec2 p, int oct) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; ++i) {
        if (i >= oct) break;
        v += a * vnoise(p);
        p = FBM_OCTAVE * p;
        a *= 0.5;
    }
    return v;
}

// A soft swell that rises just after each beat and fades before the next.
float blSwell(VisualUniforms u) {
    float bp = saturate(u.beatPhase);
    return smoothstep(0.0, 0.3, bp) * (1.0 - bp) * (1.0 - bp) * 0.6;
}

// Bass light: the level, with a soft swell on the beat.
float blBass(VisualUniforms u) {
    return 0.3 * u.level + 0.02 * blSwell(u);
}

// A spectrum band, held close to the overall level so single bands glow
// rather than flicker.
float blBand(VisualUniforms u, int i) {
    return mix(u.level, band(u, i), 0.12);
}

// Precomputed whorl colours and light, so the per-petal work stays small.
struct BlLook { vec3 warm; vec3 plum; vec2 key; float gk; };

// One whorl of the far flower, composited over col. n petals of length len,
// turned by rot; ring 0 is the outer whorl. Each pixel looks at its two
// nearest petals, so neighbours overlap and shade each other.
vec3 blWhorl(vec3 col, vec2 p, float r, float a0, VisualUniforms u, BlLook lk, float n,
             float len, float rot, float ring, float spread, float pix, float T) {
    if (r > len * 1.02) return col;
    float sa = (a0 - rot) * n / 6.2831853;
    float k0 = floor(sa);
    for (int s = 0; s < 2; s++) {
        float k = k0 + float(s);
        float th = (k + 0.5) * 6.2831853 / n + rot;
        // petal axis along +y, base at the centre
        vec2 ex = vec2(sin(th), -cos(th));
        vec2 q = vec2(dot(p, ex), dot(p, vec2(-ex.y, ex.x)));
        vec2 lq = vec2(q.x / (len * 0.95), q.y / len - 0.5);
        float d = blPetal(lq) * len;
        float cov = 1.0 - smoothstep(-pix, pix, d);
        if (cov < 0.002) continue;
        float yv = saturate(lq.y + 0.5);
        float xn = clamp(lq.x / 0.4, -1.0, 1.0);
        // a cupped shell lit from one side: one flank catches the key light,
        // the other falls into shade, with a dark crease down the middle
        float side = xn * dot(ex, lk.key);
        float cup = (0.55 + 0.45 * side) * (1.0 - 0.35 * xn * xn) + 0.15;
        float crease = 1.0 - 0.45 * exp(-xn * xn * 60.0) * smoothstep(0.9, 0.2, yv);
        // fanning veins, faded where they would alias
        float vf = q.x / max(q.y, 0.02);
        float vfreq = 34.0 / max(len, 0.1);
        float vAA = saturate(1.0 - vfreq * pix / max(q.y, 0.02) * 1.6);
        float vein = (0.5 + 0.5 * cos(vf * vfreq)) * vAA;
        // pigment: deep at the base, the palette's body, a pale glowing tip
        float hue = fract(0.12 + 0.12 * ring + 0.28 * spread * yv + 0.05 * sin(k * 2.4 + 0.02 * T));
        vec3 body = blPal(hue, u, lk.gk);
        vec3 pig = mix(lk.plum, body, smoothstep(0.0, 0.55, yv));
        pig = mix(pig, mix(body, vec3(1.0), 0.45), smoothstep(0.55, 1.0, yv) * 0.6);
        // light through the petal: hot at the base by the stamens, glowing
        // where the petal thins at its edge, brightest on the lit flank
        float thin = exp(d / (0.04 * len));
        float base = exp(-yv * 3.0) * (0.7 + 0.15 * blBass(u));
        vec3 pc = pig * pig * cup * crease * (0.7 + 0.4 * vein * yv) * 0.75;
        pc += pig * base * 0.9;
        pc += mix(body, lk.warm, 0.55) * thin * (0.3 + 0.35 * side + 0.04 * blSwell(u)) * (0.55 + 0.45 * ring);
        // each beat sends a ring of light out along the petals
        float wv = (r / len - saturate(u.beatPhase) * 1.3) * 7.0;
        pc *= 1.0 + 0.03 * blSwell(u) * exp(-wv * wv);
        // the next whorl in casts a soft contact shadow on this one
        col *= 1.0 - 0.45 * cov * smoothstep(len * 0.55, len * 0.1, r) * (1.0 - ring);
        col = mix(col, pc, cov * 0.96);
    }
    return col;
}

// The far flower: a light source that fills the middle of the frame.
vec3 blSource(vec2 p, VisualUniforms u, float T, float spread, float detail, float pix, vec3 sky, vec3 gold) {
    // the flower turns slowly toward and away from us: a gentle foreshortening
    float ta = 0.05 * T;
    vec2 ax = vec2(cos(ta), sin(ta));
    float fore = 0.84 + 0.16 * cos(0.13 * T);
    vec2 fp = p + ax * dot(p, ax) * (1.0 / fore - 1.0);
    float r = length(fp);
    float open = 0.68 + 0.08 * sin(T * 0.12) + 0.015 * u.level;


    // cool night sky: a veil of the palette's far end, slow and structured
    vec2 sw = rot2(0.03 * T + 0.4 / (r + 0.5)) * p;
    float veil = blFbm(sw * 1.3 + vec2(0.04 * T, -0.025 * T), osSteps(2.0, 4.0, detail));
    BlLook lk;
    lk.gk = blGain(u);
    lk.warm = blPal(0.62, u, lk.gk);
    lk.plum = blPal(0.02, u, lk.gk) * 0.6;
    lk.key = vec2(cos(0.6 + 0.04 * T), sin(0.6 + 0.04 * T));
    float rp = length(p);
    vec3 col = vec3(0.003, 0.002, 0.006);
    col += sky * 0.07 * smoothstep(0.35, 0.8, veil) * smoothstep(0.2, 1.3, rp);
    col += lk.plum * 0.1 * veil * exp(-rp * 1.2);
    // warm halo of the flower
    col += blPal(0.3, u, lk.gk) * 0.10 * exp(-r * 2.0);

    // light beams escaping through the gaps between the outer petals; each
    // beam rides its own band of the spectrum
    float a = atan2_(fp.y, fp.x);
    float rot0 = 0.05 * T + 0.02 * sin(T * 0.37);
    float gap = 0.5 + 0.5 * cos(5.0 * (a - rot0));
    float bid = mod(floor((a - rot0) * 5.0 / 6.2831853 + 0.5), 5.0);
    vec2 dir = p / max(rp, 1e-3);
    float rays = blFbm(dir * 3.0 + vec2(0.06 * T, -0.04 * T), 2);
    float g2 = gap * gap;
    float beam = (g2 * g2 * g2 * g2 * 0.6 + pow(gap, 40.0)) * (0.25 + rays * rays * 1.6) * smoothstep(open * 0.4, open * 0.9, r) * exp(-r * 0.9);
    col += mix(lk.warm, gold, 0.5) * beam * (0.35 + 0.15 * blBass(u) + 0.1 * blBand(u, int(bid) * 6 + 2));

    col = blWhorl(col, fp, r, a, u, lk, 5.0, open, rot0, 0.0, spread, pix, T);
    col = blWhorl(col, fp, r, a, u, lk, 5.0, open * 0.68, rot0 + 0.6283185 - 0.03 * T, 1.0, spread, pix, T);

    if (r < open * 0.32) {
        // a crown of stamens: thin filaments with glowing anthers
        float M = 22.0;
        float sm = (a + 3.14159265) * M / 6.2831853 + 0.01 * T;
        float sk = floor(sm);
        float sh = hash21(vec2(mod(sk, M), 3.7));
        float slen = open * (0.17 + 0.09 * sh) * (0.95 + 0.08 * blBass(u));
        float dl = abs(fract(sm) - 0.5) * r * 6.2831853 / M;
        float fil = exp(-dl * dl / (pix * pix * 1.5 + 2e-6)) * smoothstep(slen, slen * 0.5, r) * smoothstep(0.0, 0.03, r);
        float ta2 = (sk + 0.5 - 0.01 * T) * 6.2831853 / M - 3.14159265;
        vec2 tip = vec2(cos(ta2), sin(ta2)) * slen;
        float ad = length(fp - tip);
        float anth = exp(-ad * ad / (0.00004 + 0.00008 * sh + pix * pix));
        float flare = 0.9 + 0.2 * blBass(u) + 0.08 * blBand(u, int(sh * 31.0));
        col += gold * fil * 0.5 * (0.75 + 0.08 * blBass(u));
        col += gold * (1.2 + 0.8 * sh) * anth * flare;
    }
    // the small hot heart and its glow
    col += peakWhite(gold, 0.4) * exp(-r * r * 900.0) * (0.95 + 0.1 * blBass(u));

    col += gold * 0.25 * exp(-r * 9.0) * (0.75 + 0.08 * blBass(u));

    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    // every drift and spin runs on a slowed clock
    float T = mod(u.time, 600.0) * 0.6;
    float spread = mix(0.15, 0.9, u.param1);
    float veins = u.param2;
    float pix = 2.0 / u.resolution.y;

    float flow = mix(0.5, 1.6, u.param0);
    float travel = mod(u.time, 36000.0) * 0.12 * flow;


    // a slow sway of the whole view, never driven by audio
    p = rot2(0.1 * sin(mod(u.time, 628.31853) * 0.05)) * p;
    vec2 c = 0.07 * vec2(sin(T * 0.11), cos(T * 0.083));
    // lights for the free petals: warm behind (the flower), cool in front (the sky)
    float gk = blGain(u);
    vec3 warm = blPal(0.62, u, gk);
    vec3 cool = blPal(0.97, u, gk);
    vec3 gold = blPal(0.72, u, gk);
    vec3 col = blSource(p - c, u, T, spread, detail, pix, cool, gold);
    vec3 fogCol = cool * 0.025 + blPal(0.1, u, gk) * 0.03;
    vec3 Lf = normalize(vec3(-0.55, 0.6, 0.6));

    int N = osSteps(8.0, 14.0, detail);
    float fn = float(N);
    float zt = travel * 0.032 * fn;
    float fr = fract(zt);
    float fl0 = floor(zt);

    for (int j = 0; j < 14; j++) {
        if (j >= N) break;
        float t = (float(j) + fr) / fn;            // 0 far, 1 at the camera
        float lid = mod(float(j) - fl0, 509.0);     // stable layer identity
        float z = 1.0 - t;
        float dist = 0.08 + 2.6 * z;
        float dens = 1.9 * dist;
        float spin = lid * 1.71 + 0.02 * T + 0.3 * t * t;
        mat2 rm = rot2(spin);
        vec2 sp = p - c * z;
        vec2 q = rm * sp * dens + vec2(lid * 0.37, lid * 0.61);
        vec2 g = floor(q);
        vec2 f = fract(q) - 0.5;
        vec2 h = hash22(g + vec2(lid * 7.13, lid * 3.31));
        float h3 = hash21(g * 1.37 + lid);
        if (h3 > 0.17 + 0.13 * t) {
            // empty cells carry a speck of drifting pollen that glints with treble
            vec2 o = f - (h - 0.5) * 0.6;
            float sp2 = exp(-dot(o, o) / (0.0004 + 0.002 * t * t)) * step(0.88, h3);
            col += mix(warm, cool, h.x) * sp2 * (0.3 + 0.08 * u.level * h.y) * t;

            continue;
        }

        vec2 lp = f - (h - 0.5) * 0.2;        float sl = length(sp);

        float s = 0.22 + 0.2 * h.x * h.x;
        float ang = h.y * 6.2831853 + T * (0.06 + 0.1 * h.x) * (h3 > 0.2 ? 1.0 : -1.0);
        mat2 ra = rot2(ang);
        lp = ra * lp / s;
        // tumble about the petal's long axis: phi is the tilt angle
        float phi = T * (0.15 + 0.2 * h.y) + h.x * 6.2831853;
        float ct = cos(phi), st = sin(phi);
        lp.x /= 0.22 + 0.78 * abs(ct);
        float d = blPetal(lp);

        // depth of field: soft up close and far away, crisp in between
        float dof = 0.26 * smoothstep(0.62, 1.0, t) + 0.07 * smoothstep(0.35, 0.0, t);
        float aa = pix * dens / s * 1.5 + dof;
        float a = 1.0 - smoothstep(-aa, aa, d);
        if (a < 0.002) continue;

        float yv = saturate(lp.y + 0.5);
        float xn = clamp(lp.x / 0.4, -1.0, 1.0);
        // the cupped shell's normal, tilted by the tumble; flip to face us
        vec3 n0 = normalize(vec3(-0.9 * xn, 0.35 * (0.5 - yv), 1.0));
        vec3 nrm = vec3(n0.x * ct + n0.z * st, n0.y, n0.z * ct - n0.x * st);
        float front = nrm.z >= 0.0 ? 1.0 : 0.0;
        // the back face pales in gradually as the petal turns, never in one frame
        float backF = 1.0 - smoothstep(-0.3, 0.3, nrm.z);
        nrm *= front * 2.0 - 1.0;
        // light directions in the petal's frame
        vec2 toSrc = ra * (rm * (-sp / max(sl, 1e-3)));
        vec3 Lb = normalize(vec3(toSrc * 0.5, -1.0));
        vec2 lf2 = ra * (rm * Lf.xy);
        vec3 Lc = normalize(vec3(lf2, Lf.z));

        // pigment: each petal takes its own hue across the palette's warm half
        float hue = 0.08 + 0.6 * fract(spread * (0.9 * h.x + 0.13 * lid) + 0.015 * T);
        vec3 body = blPal(hue, u, gk);
        vec3 pig = body * body;                            // light through pigment
        float back = exp(-sl * 1.3);
        float lvl = blBand(u, int(h.x * 31.0));
        float illum = (0.35 + 1.2 * back) * (0.95 + 0.06 * lvl);
        // transmission: thin petal, lit from behind, brightest at the thin edges
        float thin = smoothstep(-0.2, 0.0, d);
        float tr = (0.35 + 0.65 * abs(dot(nrm, Lb))) * (0.35 + 0.65 * yv);
        vec3 pc = pig * tr * illum * 0.75;
        pc += mix(body, warm, 0.4) * thin * thin * (0.08 + 0.5 * back + 0.01 * blSwell(u)) * (0.95 + 0.05 * lvl);

        // front: cool sky fill and an iridescent sheen; the back face is paler
        float dif = saturate(dot(nrm, Lc));
        pc += mix(body, cool, 0.6) * dif * dif * 0.12 * (1.0 + 0.6 * backF);
        vec3 H = normalize(Lc + vec3(0.0, 0.0, 1.0));
        float spec = pow(saturate(dot(nrm, H)), 28.0);
        float fres = 0.3 + 0.7 * pow(1.0 - saturate(nrm.z), 3.0);
        vec3 film = mix(cool, gold, 0.5 + 0.5 * cos(phi * 2.0 + 3.0 * xn));
        pc += film * spec * fres * (0.5 + 0.8 * back);
        // the loudest bands make single petals burn
        pc += mix(body, warm, 0.5) * smoothstep(0.4, 1.0, lvl) * (0.3 + 1.4 * yv) * 0.03;
        // veins: a midrib and side veins, sparked by treble
        float inner = 1.0 - smoothstep(-0.12, -0.04, d);
        float vein = exp(-lp.x * lp.x * 900.0) * smoothstep(-0.5, 0.2, lp.y);
        vein += 0.5 * exp(-pow(abs(fract(lp.y * 4.0 - abs(lp.x) * 3.0) - 0.5), 2.0) * 120.0) *
                smoothstep(0.0, 0.2, abs(lp.x));
        pc += mix(body, warm, 0.5) * vein * inner * veins * (0.26 + 0.06 * u.level)
 * illum * 0.3 * (1.0 - saturate(dof * 3.0));


        // atmospheric depth: far petals sink into the cool night, near ones fade at the lens
        pc = mix(pc, fogCol, z * z * 0.8);
        // the big near petals thin out gradually as they pass the lens
        a *= smoothstep(0.0, 0.3, t) * (1.0 - smoothstep(0.72, 1.0, t)) * 0.95;

        col = mix(col, pc, a);
    }

    // soft vignette keeps the edges deep
    col *= 1.0 - 0.35 * smoothstep(0.7, 1.8, length(p));
    return col; // LINEAR HDR — post chain tonemaps
}
