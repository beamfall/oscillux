// SPDX-License-Identifier: AGPL-3.0-only
// Bloom.
// A petal storm. Far away a giant flower of light opens and breathes: two
// whorls of overlapping, cupped, backlit petals around a crown of glowing
// stamens, with light beams escaping through the gaps between the petals.
// Its petals tear loose and stream past the camera in a slow vortex. Each one
// is a curved, translucent shell lit from behind by the flower (warm light
// through the pigment) and from the front by the cool sky (an iridescent
// sheen that sweeps across it as it tumbles), sharp in the middle distance
// and soft as it rushes by. The stream's speed follows the shared 32-beat
// profile, so it cruises, surges into motion-streaked bursts, brakes and
// drifts. Audio drives light: the spectrum lights single petals, bass flares
// the stamens and the beams, treble sparks the veins and the pollen, and the
// beat brightens the petal rims.
// param0 = Flow ; param1 = Color Spread ; param2 = Veins

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

// Precomputed whorl colours and light, so the per-petal work stays small.
struct BlLook { vec3 warm; vec3 plum; vec2 key; };

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float BL_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 blFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * BL_RUN[32] + BL_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

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
        vec3 body = palVisual(hue, u);
        vec3 pig = mix(lk.plum, body, smoothstep(0.0, 0.55, yv));
        pig = mix(pig, mix(body, vec3(1.0), 0.45), smoothstep(0.55, 1.0, yv) * 0.6);
        // light through the petal: hot at the base by the stamens, glowing
        // where the petal thins at its edge, brightest on the lit flank
        float thin = exp(d / (0.04 * len));
        float base = exp(-yv * 3.0) * (0.5 + 1.2 * u.bassImpact);
        vec3 pc = pig * pig * cup * crease * (0.7 + 0.4 * vein * yv) * 0.75;
        pc += pig * base * 0.9;
        pc += mix(body, lk.warm, 0.55) * thin * (0.3 + 0.35 * side + 0.5 * u.beat) * (0.55 + 0.45 * ring);
        // each beat sends a ring of light out along the petals
        float wv = (r / len - saturate(u.beatPhase) * 1.3) * 7.0;
        pc *= 1.0 + 0.6 * u.beat * exp(-wv * wv);
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
    float open = 0.68 + 0.10 * sin(T * 0.21) + 0.10 * u.level;

    // cool night sky: a veil of the palette's far end, slow and structured
    vec2 sw = rot2(0.03 * T + 0.4 / (r + 0.5)) * p;
    float veil = blFbm(sw * 1.3 + vec2(0.04 * T, -0.025 * T), osSteps(2.0, 4.0, detail));
    BlLook lk;
    lk.warm = palVisual(0.62, u);
    lk.plum = palVisual(0.02, u) * 0.6;
    lk.key = vec2(cos(0.6 + 0.04 * T), sin(0.6 + 0.04 * T));
    float rp = length(p);
    vec3 col = vec3(0.003, 0.002, 0.006);
    col += sky * 0.07 * smoothstep(0.35, 0.8, veil) * smoothstep(0.2, 1.3, rp);
    col += lk.plum * 0.1 * veil * exp(-rp * 1.2);
    // warm halo of the flower
    col += palVisual(0.3, u) * 0.10 * exp(-r * 2.0);

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
    col += mix(lk.warm, gold, 0.5) * beam * (0.15 + 0.6 * u.bassImpact + 1.1 * band(u, int(bid) * 6 + 2));

    col = blWhorl(col, fp, r, a, u, lk, 5.0, open, rot0, 0.0, spread, pix, T);
    col = blWhorl(col, fp, r, a, u, lk, 5.0, open * 0.68, rot0 + 0.6283185 - 0.03 * T, 1.0, spread, pix, T);

    if (r < open * 0.32) {
        // a crown of stamens: thin filaments with glowing anthers
        float M = 22.0;
        float sm = (a + 3.14159265) * M / 6.2831853 + 0.01 * T;
        float sk = floor(sm);
        float sh = hash21(vec2(mod(sk, M), 3.7));
        float slen = open * (0.17 + 0.09 * sh) * (0.9 + 0.25 * u.bassImpact);
        float dl = abs(fract(sm) - 0.5) * r * 6.2831853 / M;
        float fil = exp(-dl * dl / (pix * pix * 1.5 + 2e-6)) * smoothstep(slen, slen * 0.5, r) * smoothstep(0.0, 0.03, r);
        float ta2 = (sk + 0.5 - 0.01 * T) * 6.2831853 / M - 3.14159265;
        vec2 tip = vec2(cos(ta2), sin(ta2)) * slen;
        float ad = length(fp - tip);
        float anth = exp(-ad * ad / (0.00004 + 0.00008 * sh + pix * pix));
        float flare = 0.7 + 2.2 * u.bassImpact + 0.8 * band(u, int(sh * 31.0));
        col += gold * fil * 0.5 * (0.6 + 0.6 * u.bassImpact);
        col += gold * (1.2 + 0.8 * sh) * anth * flare;
    }
    // the small hot heart and its glow
    col += peakWhite(gold, 0.4) * exp(-r * r * 900.0) * (0.8 + 1.2 * u.bassImpact);
    col += gold * 0.25 * exp(-r * 9.0) * (0.6 + 0.8 * u.bassImpact);
    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float T = mod(u.time, 600.0);
    float spread = mix(0.15, 0.9, u.param1);
    float veins = u.param2;
    float pix = 2.0 / u.resolution.y;

    float flow = mix(0.5, 1.6, u.param0);
    vec2 fl = blFlight(u, flow, 0.45 * flow);
    float rush = saturate((fl.y - 1.0) / 3.5);

    // eased roll of the whole view, never driven by audio
    p = rot2(osBank(u, 0.22)) * p;
    vec2 c = 0.07 * vec2(sin(T * 0.11), cos(T * 0.083));
    // lights for the free petals: warm behind (the flower), cool in front (the sky)
    vec3 warm = palVisual(0.62, u);
    vec3 cool = palVisual(0.97, u);
    vec3 gold = palVisual(0.72, u);
    vec3 col = blSource(p - c, u, T, spread, detail, pix, cool, gold);
    vec3 fogCol = cool * 0.025 + palVisual(0.1, u) * 0.03;
    vec3 Lf = normalize(vec3(-0.55, 0.6, 0.6));

    int N = osSteps(8.0, 14.0, detail);
    float fn = float(N);
    float zt = fl.x * 0.032 * fn;
    float fr = fract(zt);
    float fl0 = floor(zt);

    for (int j = 0; j < 14; j++) {
        if (j >= N) break;
        float t = (float(j) + fr) / fn;            // 0 far, 1 at the camera
        float lid = mod(float(j) - fl0, 509.0);     // stable layer identity
        float z = 1.0 - t;
        float dist = 0.08 + 2.6 * z;
        float dens = 1.9 * dist;
        float spin = lid * 1.71 + 0.035 * T + 0.5 * t * t;
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
            col += mix(warm, cool, h.x) * sp2 * (0.3 + 2.0 * u.treble * h.y) * t;
            continue;
        }

        vec2 lp = f - (h - 0.5) * 0.2;
        // motion streak: stretch along the outward direction while rushing
        float sl = length(sp);
        vec2 radial = rm * (sp / max(sl, 1e-3));
        float k = rush * t * 0.8 * smoothstep(0.05, 0.4, sl);
        lp -= radial * dot(lp, radial) * (k / (1.0 + k));

        float s = 0.22 + 0.2 * h.x * h.x;
        float ang = h.y * 6.2831853 + T * (0.15 + 0.25 * h.x) * (h3 > 0.2 ? 1.0 : -1.0);
        mat2 ra = rot2(ang);
        lp = ra * lp / s;
        // tumble about the petal's long axis: phi is the tilt angle
        float phi = T * (0.4 + 0.6 * h.y) + h.x * 6.2831853;
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
        nrm *= front * 2.0 - 1.0;
        // light directions in the petal's frame
        vec2 toSrc = ra * (rm * (-sp / max(sl, 1e-3)));
        vec3 Lb = normalize(vec3(toSrc * 0.5, -1.0));
        vec2 lf2 = ra * (rm * Lf.xy);
        vec3 Lc = normalize(vec3(lf2, Lf.z));

        // pigment: each petal takes its own hue across the palette's warm half
        float hue = 0.08 + 0.6 * fract(spread * (0.9 * h.x + 0.13 * lid) + 0.015 * T);
        vec3 body = palVisual(hue, u);
        vec3 pig = body * body;                            // light through pigment
        float back = exp(-sl * 1.3);
        float lvl = band(u, int(h.x * 31.0));
        float illum = (0.35 + 1.4 * back) * (0.6 + 1.4 * lvl);
        // transmission: thin petal, lit from behind, brightest at the thin edges
        float thin = smoothstep(-0.2, 0.0, d);
        float tr = (0.35 + 0.65 * abs(dot(nrm, Lb))) * (0.35 + 0.65 * yv);
        vec3 pc = pig * tr * illum * 0.75;
        pc += mix(body, warm, 0.4) * thin * thin * (0.08 + 0.6 * back + 0.5 * u.beat) * (0.6 + lvl);
        // front: cool sky fill and an iridescent sheen; the back face is paler
        float dif = saturate(dot(nrm, Lc));
        pc += mix(body, cool, 0.6) * dif * dif * 0.12 * (1.0 + 0.6 * (1.0 - front));
        vec3 H = normalize(Lc + vec3(0.0, 0.0, 1.0));
        float spec = pow(saturate(dot(nrm, H)), 28.0);
        float fres = 0.3 + 0.7 * pow(1.0 - saturate(nrm.z), 3.0);
        vec3 film = mix(cool, gold, 0.5 + 0.5 * cos(phi * 2.0 + 3.0 * xn));
        pc += film * spec * fres * (0.5 + 0.8 * back);
        // the loudest bands make single petals burn
        pc += mix(body, warm, 0.5) * smoothstep(0.5, 0.95, lvl) * (0.3 + 1.4 * yv) * 0.8;
        // veins: a midrib and side veins, sparked by treble
        float inner = 1.0 - smoothstep(-0.12, -0.04, d);
        float vein = exp(-lp.x * lp.x * 900.0) * smoothstep(-0.5, 0.2, lp.y);
        vein += 0.5 * exp(-pow(abs(fract(lp.y * 4.0 - abs(lp.x) * 3.0) - 0.5), 2.0) * 120.0) *
                smoothstep(0.0, 0.2, abs(lp.x));
        pc += mix(body, warm, 0.5) * vein * inner * veins * (0.1 + 1.6 * u.treble) * illum * 0.3 * (1.0 - saturate(dof * 3.0));

        // atmospheric depth: far petals sink into the cool night, near ones fade at the lens
        pc = mix(pc, fogCol, z * z * 0.8);
        a *= smoothstep(0.0, 0.3, t) * (1.0 - smoothstep(0.9, 1.0, t)) * 0.95;
        col = mix(col, pc, a);
    }

    // soft vignette keeps the edges deep
    col *= 1.0 - 0.35 * smoothstep(0.7, 1.8, length(p));
    return col; // LINEAR HDR — post chain tonemaps
}
