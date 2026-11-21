// SPDX-License-Identifier: AGPL-3.0-only
// Lumen field.
// A low glide down an open aisle through a field of glowing light stems
// under an aurora. Each stem carries an HDR orb at its tip; the rows recede
// into coloured fog, the aisle is lined with floor lamps, and a wet, slowly
// rippled mirror floor doubles everything, the aurora included; the water
// lies stiller toward the horizon. The glide is
// slow and near-steady (the shared 32-beat profile barely moves it), level
// with no beat roll, and the aurora rays and the wind crawl gently. Audio
// drives the light, softly: stem brightness and
// height follow the music's smoothed level with a gentle tilt of the spectrum
// outward from the aisle, the aurora curtains follow it across the sky
// (cyan and blue hems over a magenta fringe, climbing into violet and a high
// red veil; the stems run cyan by the aisle to rose at the edges and warm
// with level and through the build),
// every beat sends a faint ring of light out across the field from a point
// ahead, lifting the stems a little as it passes, and a slow wind combs the
// field. No beat flashes the orbs or the floor.
// param0 = Stem Density ; param1 = Bloom ; param2 = Sway

// Spectrum cache: twelve stops read once per pixel, blended locally, so the
// many per-post reads skip the uniform-array select.
float lfB(mat3x4 B, float f) {
    float x = saturate(f) * 11.0;
    return dot(max(1.0 - abs(x - vec4(0.0, 1.0, 2.0, 3.0)), 0.0), B[0]) +
           dot(max(1.0 - abs(x - vec4(4.0, 5.0, 6.0, 7.0)), 0.0), B[1]) +
           dot(max(1.0 - abs(x - vec4(8.0, 9.0, 10.0, 11.0)), 0.0), B[2]);
}

// Post hue: cool cyan beside the aisle, through violet and magenta to rose at
// the edges of the field; slow warm drifts roll through the rows, loud posts
// and the build both push warmer. Kept clear of the palette's green stretch.
float lfHue(vec2 c, float ax, float e, float tw, float hs) {
    float f = saturate((ax - 1.0) / 4.0);
    return 0.58 - 0.4 * f + 0.06 * hash21(c + 4.4) + 0.12 * sin(c.y * 0.11 + tw * 0.08) - 0.22 * e * e - hs;
}

// Post for grid cell c (x = column, y = row) at spacing sp: base xz, then the
// tip (xyz) and the post's hue and band energy.
void lfPost(vec2 c, float sp, float sway, float tw, float hs, mat3x4 B,
            out vec2 base, out vec3 tip, out float hue, out float e) {
    vec2 j = hash22(c * vec2(1.37, 0.71) + 3.1) - 0.5;
    base = (c + j * vec2(0.4, 0.5)) * sp;
    float f = saturate((abs(c.x) - 1.0) / 8.0);       // 0 next to the aisle
    float hr = hash21(c * 1.91 + 2.3);
    e = lfB(B, 0.03 + f * 0.75 + 0.08 * (hr - 0.5));
    float h = (0.5 + 2.8 * hr * hr) * (0.75 + 0.55 * e);
    // wind: a slow gust front travelling across the field
    float g = sin(dot(base, vec2(0.23, 0.11)) - tw * 0.5) + 0.5 * sin(dot(base, vec2(-0.13, 0.31)) - tw * 0.35 + 1.7);
    vec2 lean = vec2(0.9, 0.35) * g * sway * h;
    tip = vec3(base.x + lean.x, h, base.y + lean.y);
    hue = lfHue(c, abs(c.x), e, tw, hs);
}

// The beat ring: a front of light racing out from wc to radius wr.
float lfRing(vec2 p, vec2 wc, float wr) {
    float d = length(p - wc) - wr;
    return exp(-d * d * 0.4) + 0.12 * exp(-d * d * 0.04) * step(d, 0.0);
}

// Glow of the stems and orbs near a ray, row by row along +z. blur widens the
// glow with distance (rough reflections), tmax stops at the floor.
vec3 lfField(vec3 ro, vec3 rd, float tmax, float pix, float blur, int rows, float sp,
             float sway, float tw, float bloom, float fogK, vec4 wv4, float hs, mat3x4 B,
             VisualUniforms u) {
    vec3 acc = vec3(0.0);
    float rz = max(rd.z, 1e-3);
    float r0 = floor(ro.z / sp) + 1.0;
    float reach = float(rows) * sp;
    vec2 dxz = rd.xz / max(length(rd.xz), 1e-4);
    float reject = 0.45 * sp + sway * 1.6;
    for (int i = 0; i < 30; i++) {
        if (i >= rows) break;
        float row = r0 + float(i);
        float tz = (row * sp - ro.z) / rz;
        if (tz > tmax + 2.0 * sp) break;
        float xr = (ro.x + rd.x * tz) / sp;
        float cx = floor(xr);
        for (int k = 0; k < 2; k++) {
            vec2 c = vec2(cx + float(k), row);
            if (abs(c.x) < 0.5) continue;              // the open aisle
            // cheap reject: the post's base is far from the ray's ground track
            vec2 bj = (c + (hash22(c * vec2(1.37, 0.71) + 3.1) - 0.5) * vec2(0.4, 0.5)) * sp - ro.xz;
            if (abs(bj.x * dxz.y - bj.y * dxz.x) > reject) continue;
            vec2 b2; vec3 tip; float hue; float e;
            lfPost(c, sp, sway, tw, hs, B, b2, tip, hue, e);
            vec3 base = vec3(b2.x, 0.0, b2.y);
            // closest approach between the ray and the stem segment
            vec3 ab = tip - base;
            vec3 w0 = ro - base;
            float b = dot(rd, ab);
            float cc = dot(ab, ab);
            float d0 = dot(rd, w0);
            float e0 = dot(ab, w0);
            float s = saturate((e0 - b * d0) / max(cc - b * b, 1e-4));
            float t = max(b * s - d0, 0.0);
            vec3 dv = w0 + rd * t - ab * s;
            float d2 = dot(dv, dv);
            float fog = exp(-t * fogK) * (1.0 - smoothstep(reach - 3.0 * sp, reach, b2.y - ro.z));
            float wv = lfRing(b2, wv4.xy, wv4.z);
            float lit = (0.14 + 0.75 * e * e + 0.4 * e) * fog;

            // stem: thin hot core and a soft halo, never thinner than a pixel;
            // widening keeps the energy, so far stems do not shimmer
            float pw = t * (pix + blur);
            float wc = max(0.007, pw);
            float wh = max(0.045 * bloom, 2.0 * pw);
            float stem = (0.007 / wc) * exp(-d2 / (wc * wc)) * 1.8 +
                         (0.045 * bloom / wh) * exp(-d2 / (wh * wh)) * 0.35;
            // energy pulses climbing the stem after each beat
            float ps = fract(u.beatPhase * 1.15 - hash21(c) * 0.15);
            float pq = (s - ps) * 8.0;
            float pulse = exp(-pq * pq) * (1.0 - smoothstep(0.75, 1.0, ps));
            stem *= (0.15 + 0.85 * s * s) * (1.0 + 0.15 * pulse * (0.3 + e));
            stem *= step(t, tmax);

            // tip orb: a hot core in a coloured bloom
            vec3 to = tip - ro;
            float tt = max(dot(to, rd), 0.0);
            vec3 ov = to - rd * tt;
            float o2 = dot(ov, ov);
            float r0o = 0.028 + 0.03 * e + 0.02 * wv;
            // near orbs fall out of focus into soft bokeh discs
            float coc = 0.05 * abs(tt - 6.0) / 6.0;
            float ow = max(r0o + coc, tt * (pix * 1.2 + blur));
            float oh = max(0.13 * bloom, tt * (pix * 3.0 + 2.0 * blur));
            float k1 = r0o / ow;
            float k2 = 0.13 * bloom / oh;
            float disc = 1.0 - smoothstep(0.7 * ow * ow, ow * ow, o2);
            float orb = k1 * k1 * mix(exp(-o2 / (ow * ow)), disc * 0.8, smoothstep(r0o, 2.5 * r0o, ow)) * 4.5;
            float bl = k2 * k2 * exp(-o2 / (oh * oh)) * 0.45;
            // most posts near the ray only add a faint tail: skip their colour work
            if ((stem + orb + bl) * (lit + fog * wv) < 2e-4) continue;
            vec3 c0 = palVisual(hue, u);
            vec3 cw = peakWhite(c0, 0.55);
            // the orbs flare on the beat itself
            vec3 tipc = (peakWhite(c0, 0.15 + 0.3 * e + 0.1 * wv) * orb + c0 * bl) * step(tt, tmax);

            // the ring flares the whole post toward white as it passes
            acc += (mix(c0, cw, 0.3 * wv) * stem + tipc) * lit * (1.0 + 0.8 * wv * wv4.w) +
                   c0 * stem * fog * wv * wv4.w * 0.5;
        }
    }
    return acc;
}

// Far field: beyond the stem rows, orbs on two height layers stand in for
// the stems, one nearest-cell lookup each, fading in where the rows fade out.
vec3 lfFar(vec3 ro, vec3 rd, float tmax, float sp, float pix, float reach, float fogK,
           vec4 wv4, float tw, float hs, mat3x4 B, VisualUniforms u) {
    vec3 acc = vec3(0.0);
    for (int l = 0; l < 2; l++) {
        float hy = l == 0 ? 0.8 : 2.2;
        if (abs(rd.y) < 1e-4) continue;
        float t = (hy - ro.y) / rd.y;
        if (t <= 0.0 || t > tmax) continue;
        vec2 xz = ro.xz + rd.xz * t;
        vec2 c = floor(xz / sp + 0.5);
        if (abs(c.x) < 0.5) continue;
        vec2 cl = c + float(l) * 31.0;
        vec2 j = hash22(cl * vec2(1.37, 0.71) + 3.1) - 0.5;
        vec2 oxz = (c + j * vec2(0.4, 0.5)) * sp;
        vec3 to = vec3(oxz.x, hy, oxz.y) - ro;
        float tt = max(dot(to, rd), 0.0);
        float o2 = max(dot(to, to) - tt * tt, 0.0);
        float f = saturate((abs(c.x) - 1.0) / 8.0);
        float hr = hash21(cl * 1.91 + 2.3);
        float e = lfB(B, 0.03 + f * 0.75 + 0.08 * (hr - 0.5));
        float w = max(0.04, tt * pix * 1.3);
        float k = 0.04 / w;
        // a cell seen edge-on is thinner than the orb: fade rather than clip it
        float orb = k * k * exp(-o2 / (w * w)) * saturate(0.3 * sp * abs(rd.y) / w - 0.5);
        float hue = lfHue(cl, abs(c.x), e, tw, hs);
        float fade = smoothstep(reach - 3.0 * sp, reach, xz.y - ro.z) * exp(-t * fogK);
        float wv = lfRing(oxz, wv4.xy, wv4.z);
        acc += peakWhite(palVisual(hue, u), 0.3 + 0.1 * wv) * orb * 3.0 * fade *
               (0.14 + 1.1 * e * e + 0.5 * e) * (1.0 + 0.8 * wv * wv4.w) * step(0.35, hr);
    }
    return acc;
}

// Deepens a palette colour's saturation, keeping its brightest channel.
vec3 lfSat(vec3 c) {
    float m = max(max(c.r, c.g), max(c.b, 1e-4));
    vec3 n = c / m;
    return n * n * m;
}

// Sky colours, read once per pixel: cyan, blue, violet, magenta, red.
struct LfSkyPal { vec3 c; vec3 b; vec3 v; vec3 m; vec3 r; vec3 fog; };

// Aurora: three curtains hanging over the field, each a folded ribbon in
// azimuth with a hot lower hem over a magenta fringe, fine vertical rays,
// and a glow that climbs from cyan or blue into violet, magenta and red; the
// mix slides along each curtain so the sky never sits on one hue. Each
// curtain's light follows the spectrum band under it, folds seen edge-on burn
// brighter, every beat sends a kink running along the hems and flares them,
// and the curtains churn faster through the build. Above them a high red veil
// with long rays fills the zenith.
vec3 lfAurora(vec3 rd, float zc, float tw, float detail, float rush, float bass, float bph,
              LfSkyPal sk, mat3x4 B) {
    float el = rd.y;
    if (el <= -0.04) return vec3(0.0);
    float az = atan2_(rd.x, max(rd.z, 1e-3) + abs(rd.x) * 0.2);
    vec3 acc = vec3(0.0);
    float chn = 1.0 + 0.3 * rush;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        // curtains drift sideways as the glide carries the camera on
        float x = az * (2.6 + 0.9 * fi) + fi * 2.3 + zc * 0.003 * (1.0 + 0.5 * fi) + tw * 0.03;
        float w1 = x * 1.3 + tw * (0.13 + 0.04 * fi) * chn;
        float w2 = x * 3.7 - tw * (0.21 + 0.05 * fi) * chn;
        float w3 = x * 9.0 + tw * 0.45 * chn;
        float kink = 0.02 * bass * sin(x * 6.0 - bph * 12.0 + fi * 2.0);
        // hems hang in festoons: rounded bottoms between sharp folds, so the
        // dark sky under them never reads as a line of hills
        // the arcs run across the sky at a slant, each its own way
        float s1 = sin(w1), s2 = sin(w2);
        float slant = (0.09 - 0.07 * fi) * az + 0.03 * sin(tw * 0.05 + fi * 2.0) * az;
        float bse = 0.1 + 0.08 * fi + slant + 0.018 * s1 - 0.022 * abs(s2) + 0.006 * sin(w3) + kink;
        float db = abs(0.0234 * cos(w1) + 0.054 * cos(w3)) + 0.081 * abs(cos(w2));
        // each curtain comes and goes along the sky, leaving dark gaps
        float env = smoothstep(0.05, 0.8, sin(x * 0.9 + fi * 2.1 + tw * 0.02));
        env *= 0.35 + 0.65 * vnoise(vec2(x * 2.3 - tw * 0.08, fi * 5.0));
        float fold = 0.6 + 2.2 * smoothstep(0.02, 0.12, abs(db));
        float h = 0.06 + 0.035 * fi;
        float y = el - bse;
        float hem = smoothstep(-0.012, 0.004, y);
        float yp = max(y, 0.0);
        float body = hem * exp(-yp / h) * (1.0 + 0.9 * exp(-yp * 22.0));
        float tall = hem * exp(-yp / (4.0 * h)) * 0.5;
        // fine rays: a stretched noise along the curtain, crawling
        float rays = vnoise(vec2(x * 26.0 + tw * 0.4 * (1.0 + fi) * chn, fi * 7.0));
        if (detail > 0.4) rays = 0.6 * rays + 0.4 * vnoise(vec2(x * 71.0 - tw * 0.6, fi * 3.0 + 1.0));
        rays = 0.15 + 0.85 * rays * rays;
        body += tall * rays * rays;
        float e = lfB(B, 0.1 + 0.28 * fi + 0.18 * sin(x * 0.7));
        float sh = 0.5 + 0.5 * sin(x * 0.45 + fi * 1.9 + tw * 0.04);
        vec3 lo = i == 0 ? mix(sk.c, sk.b, sh) : i == 1 ? mix(sk.b, sk.v, sh) : mix(sk.c, sk.v, sh);
        vec3 hi = i == 0 ? mix(sk.v, sk.m, sh) : i == 1 ? mix(sk.m, sk.r, sh) : mix(sk.r, sk.m, sh);
        hi = mix(hi, sk.r, rush * 0.5);
        vec3 c = mix(lo, hi, smoothstep(0.0, 2.5 * h, yp));
        // a hot line at the hem
        c = mix(c, peakWhite(lo, 0.4), exp(-yp * 70.0) * hem * 0.7);
        float gain = env * (0.5 + 2.0 * e * e + 0.6 * e) * (0.85 - 0.2 * fi) * (1.0 + 1.6 * bass * exp(-yp * 12.0));
        acc += c * body * rays * fold * gain;
        // magenta fringe hanging just under the hem
        float fr = smoothstep(-0.035, -0.004, y) * (1.0 - hem);
        acc += sk.m * fr * fr * rays * fold * gain * 0.9;
    }
    // high veil: a diffuse red and magenta glow with long rays toward the zenith
    float vx = az * 1.6 + tw * 0.015;
    float vn = vnoise(vec2(vx * 2.0 - tw * 0.03, el * 3.0 - tw * 0.04));
    float vr = vnoise(vec2(vx * 17.0 + tw * 0.12, 0.5));
    float veil = smoothstep(0.14, 0.45, el) * vn * vn * vn * (0.3 + 0.7 * vr);
    acc += mix(sk.v, mix(sk.m, sk.r, 0.4), smoothstep(0.15, 0.45, el + 0.1 * vn)) * veil * (0.08 + 0.25 * lfB(B, 0.6) + 0.2 * rush);
    // stars where the sky is clear, a few tinted
    vec2 sg = vec2(az * 0.55, el) * 70.0;
    vec2 sc = floor(sg);
    float sh = hash21(mod(sc, 509.0));
    vec2 sf = fract(sg) - 0.5 - 0.3 * (hash22(sc + 1.7) - 0.5);
    float star = step(0.9, sh) * exp(-dot(sf, sf) * 90.0) * smoothstep(0.0, 0.05, el);
    vec3 stc = mix(vec3(0.75, 0.8, 1.0), sk.m + 0.3, step(0.975, sh));
    acc += stc * star * 0.4 * (0.6 + 0.4 * sin(tw * 1.7 + sh * 40.0));
    return acc;
}

// Sky: deep indigo overhead, a violet band over the horizon with a rose glow
// at its foot, then the aurora.
vec3 lfSky(vec3 rd, float zc, float tw, float detail, float rush, float bass, float bph,
           LfSkyPal sk, mat3x4 B) {
    float h = max(rd.y, 0.0);
    vec3 col = sk.fog * (exp(-h * 16.0) * 1.2 + exp(-h * 3.0) * 0.4) +
               mix(sk.m, sk.r, 0.3) * 0.045 * exp(-h * 26.0) + sk.v * 0.01 * exp(-h * 6.0) + vec3(0.001, 0.0008, 0.004);
    return col + 0.55 * lfAurora(rd, zc, 0.5 * tw, detail, rush, bass, bph, sk, B);
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);

    float sp = mix(1.7, 1.05, u.param0);
    float bloom = mix(0.5, 1.6, u.param1);
    float sway = mix(0.03, 0.22, u.param2);
    float tw = mod(u.time, 600.0) * 0.9;

    vec2 fl = osFlight(u, 0.32, -0.12);
    float z = fl.x;
    float rush = 0.4 * saturate((fl.y - 1.0) / 3.5);
    float x = 0.2 * sp * sin(z * 0.045) + 0.1 * sp * sin(u.time * 0.07);
    float alt = 1.0 + 0.06 * sin(u.time * 0.11);
    vec3 ro = vec3(x, alt, z);
    vec3 ta = vec3(0.25 * sp * sin((z + 8.0) * 0.045), 1.25, z + 8.0);
    float roll = -0.25 * (ta.x - ro.x) / 8.0;
    float fov = 1.25;
    vec3 rd = osCamera(ro, ta, roll, fov, p);
    float pix = 2.0 / (u.resolution.y * fov);

    int rows = osSteps(4.0, 8.0, detail);
    float reach = float(rows) * sp;
    float fogK = 0.07;
    // the spectrum, read once
    mat3x4 B;
    for (int i = 0; i < 3; i++) {
        float f0 = float(i * 4) / 11.0;
        B[i] = 0.5 * u.level + 0.15 * vec4(bandAt(u, f0), bandAt(u, f0 + 1.0 / 11.0), bandAt(u, f0 + 2.0 / 11.0), bandAt(u, f0 + 3.0 / 11.0));
    }
    // sky colours, five palette reads drifting slowly
    LfSkyPal sk;
    float sd = 0.03 * sin(u.time * 0.03);
    sk.c = lfSat(palVisual(0.61 + sd, u));
    sk.b = lfSat(palVisual(0.5 - sd, u));
    sk.v = lfSat(palVisual(0.38 + sd, u));
    sk.m = lfSat(palVisual(0.28 - sd, u));
    sk.r = lfSat(palVisual(0.17 + sd, u));
    sk.fog = mix(palVisual(0.42, u), sk.m, 0.25 + 0.15 * sin(u.time * 0.05)) * 0.04;
    vec3 fogCol = sk.fog;
    float hs = 0.04 * rush;
    float bass = 0.15 * u.level;
    float bph = saturate(u.beatPhase);
    // the beat ring: born on the beat a little ahead of the camera and racing
    // outward across the field; centre, radius and strength
    float bp = saturate(u.beatPhase);
    vec2 wc = vec2(0.0, ro.z + 12.0);
    float wAmp = smoothstep(0.0, 0.25, bp) * (1.0 - bp) * (1.0 - bp) * (0.045 + 0.02 * u.level);
    vec4 wv = vec4(wc, 1.0 + 28.0 * pow(bp, 0.7), wAmp);
    vec3 ringC = lfSat(palVisual(0.27 + 0.05 * sin(u.time * 0.07), u));

    // aisle lamps: two lines of low beads along the open aisle
    float lx = 0.42 * sp;
    float ls = 0.5 * sp;
    float lampE = lfB(B, 0.04);
    vec3 lampC = lfSat(palVisual(0.12 + 0.03 * sin(u.time * 0.04), u));

    float tf = rd.y < -1e-3 ? -ro.y / rd.y : 1e4;
    vec3 col;
    float tEnd;
    if (tf < 1e3) {
        vec3 fp = ro + rd * tf;
        // wet floor: a rippled mirror; ripples run mostly across the view, so
        // reflections stretch into streaks toward the viewer
        vec2 n2 = vec2(vnoise(fp.xz * vec2(3.0, 1.2) + vec2(0.0, tw * 0.06)) - 0.5,
                       vnoise(fp.zx * vec2(2.2, 4.0) + 3.0 - tw * 0.04) - 0.5);
        // the ring rolls a swell through the water as it passes
        float rq = length(fp.xz - wc) - wv.z;
        float swell = exp(-rq * rq * 0.5) * wAmp;
        vec2 rdir = normalize(fp.xz - wc + 1e-4);
        // far water calms toward the horizon so distant reflections do not shimmer
        float calm = 1.0 / (1.0 + 0.08 * tf);
        vec3 rn = normalize(vec3(n2.x * 0.03 * calm + rdir.x * swell * 0.12, 1.0,
                                 n2.y * 0.12 * calm + rdir.y * swell * 0.12));
        vec3 rr = reflect(rd, rn);
        rr.y = abs(rr.y);
        float fres = 0.3 + 0.7 * pow(1.0 - saturate(-rd.y), 5.0);
        int rrows = osSteps(2.0, 4.0, detail);
        vec3 refl = lfField(fp, rr, 60.0, pix, 0.004, rrows, sp, sway, tw, bloom * 1.3, fogK, wv, hs, B, u);
        refl += lfSky(rr, ro.z, tw, 0.0, rush, bass, bph, sk, B) * 0.6;
        col = refl * fres * 0.85;
        // light pools around the nearest stems' feet
        vec2 cc = floor(fp.xz / sp);
        for (int i = 0; i < 4; i++) {
            vec2 c = cc + vec2(float(i & 1), float(i >> 1));
            if (abs(c.x) < 0.5) continue;
            vec2 b2; vec3 tip; float hue; float e;
            lfPost(c, sp, sway, tw, hs, B, b2, tip, hue, e);
            float pd = length(fp.xz - b2) / (0.5 * sp);
            float pool = saturate(1.0 - pd);
            col += palVisual(hue, u) * pool * pool * (0.05 + 0.5 * e * e) * bloom;
        }
        // lamp pools along the aisle, a warm runway in the dark water
        float lz = (floor(fp.z / ls) + 0.5) * ls;
        vec2 ld = vec2(abs(fp.x) - lx, (fp.z - lz) * 0.5) / (0.1 * sp);
        col += lampC * exp(-dot(ld, ld) * 2.0) * (0.05 + 0.2 * lampE) * exp(-tf * 0.06);
        // the ring of light itself, skimming the water
        float rq2 = length(fp.xz - wc) - wv.z;
        col += ringC * exp(-rq2 * rq2 * 3.0) * wAmp * 0.3 * exp(-tf * 0.04);
        tEnd = tf;
    } else {
        col = lfSky(rd, ro.z, tw, detail, rush, bass, bph, sk, B);
        tEnd = 80.0;
    }
    col += lfField(ro, rd, tEnd, pix, 0.0, rows, sp, sway, tw, bloom, fogK, wv, hs, B, u);
    col += lfFar(ro, rd, tEnd, sp, pix, reach, fogK, wv, tw, hs, B, u);

    // aisle lamp beads, seen directly: the closest bead on each line
    for (int sd = 0; sd < 2; sd++) {
        vec2 lp = vec2(sd == 0 ? -lx : lx, 0.07);
        vec2 dxy = ro.xy - lp;
        float a = dot(rd.xy, rd.xy);
        float tl = a > 1e-6 ? -dot(dxy, rd.xy) / a : 0.0;
        tl = clamp(tl, 0.0, tEnd);
        float zc = ro.z + rd.z * tl;
        for (int k = -1; k <= 1; k++) {
            float bz = (floor(zc / ls) + 0.5 + float(k)) * ls;
            vec3 to = vec3(lp.x, lp.y, bz) - ro;
            float tt = dot(to, rd);
            if (tt <= 0.0 || tt > tEnd + 0.2) continue;
            float o2 = max(dot(to, to) - tt * tt, 0.0);
            float w = max(0.018, tt * pix * 1.2);
            float kk = 0.018 / w;
            col += peakWhite(lampC, 0.4) * kk * kk * exp(-o2 / (w * w)) * 2.5 * exp(-tt * 0.05) * (0.5 + lampE);
        }
    }

    // fog over the floor and a glowing band at the horizon
    // the sky keeps its own gradient: only a low haze over the horizon
    float fog = 1.0 - exp(-min(tEnd, 80.0) * fogK);
    if (tf >= 1e3) fog *= exp(-max(rd.y, 0.0) * 8.0);
    col = mix(col, fogCol, fog * 0.8);
    // the haze over the field glows with the spectrum: bass dead ahead,
    // treble out toward the sides
    float ha = abs(atan2_(rd.x, max(rd.z, 1e-3)));
    float hb = lfB(B, ha * 0.9);
    vec3 hc = palVisual(0.3 + 0.35 * saturate(ha * 0.9) + 0.05 * u.spectralCentroid, u);
    col += hc * 0.05 * (exp(-abs(rd.y) * 14.0) + 0.25 * exp(-abs(rd.y) * 4.0)) * (0.35 + 1.6 * hb * hb);

    return col; // LINEAR HDR; the post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
