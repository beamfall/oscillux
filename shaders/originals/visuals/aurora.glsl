// SPDX-License-Identifier: AGPL-3.0-only
// Aurora.
// A slow glide down a mountain lake at night under a sky-filling aurora. The
// curtains are a stack of thin luminous sheets, folded by a drifting warp,
// striated by vertical rays, hot at their lower rim and fading violet toward
// the top. Snow on the valley walls takes the curtains' light, and the calm
// lake mirrors the whole sky with a soft ripple. The camera rises and settles
// over a long, eased cycle; its speed follows the shared beat profile. Audio
// drives the light and the curtain shape only: each band of the spectrum sets
// how far its rays reach up the sheet, the bass heats the rim and ripples the
// folds, each beat sends a violet front climbing every curtain, build-ups
// quicken the sway, and the treble sparks the rim and the stars.
// param0 = Curtains (fold count) ; param1 = Sway (warp and drift) ; param2 = Altitude (curtain height)

// Spectrum at eight stops, read once per frame and blended locally.
float auSpec(float x, vec4 sa, vec4 sb) {
    float k = saturate(x) * 7.0;
    vec4 i0 = vec4(0.0, 1.0, 2.0, 3.0);
    return dot(max(1.0 - abs(vec4(k) - i0), 0.0), sa) + dot(max(1.0 - abs(vec4(k) - i0 - 4.0), 0.0), sb);
}

float auPath(float z) { return 24.0 * sin(z * 0.0085) + 11.0 * sin(z * 0.021 + 1.7); }

// Crags: fine ridged octaves cut gullies and ledges into the slopes. The
// first is part of the marched shape; the second only shades.
float auCrag(vec2 p, float fine) {
    // stretched across the valley, so ribs and gullies run down the walls
    vec2 q = p * vec2(0.045, 0.16) + vec2(1.9, 4.2);
    q.y += 0.9 * sin(p.x * 0.06 + p.y * 0.023);
    float n1 = 1.0 - abs(2.0 * vnoise(q) - 1.0);
    float c = 5.5 * n1 * n1;
    if (fine > 0.0) {
        vec2 q2 = p * vec2(0.09, 0.42) + vec2(7.3, 2.6);
        float n2 = 1.0 - abs(2.0 * vnoise(q2) - 1.0);
        c += fine * 2.2 * n2 * n2 * (0.4 + n1);
        // a third, sharper octave of chutes and broken ledges, shading only
        vec2 q3 = p * vec2(0.23, 0.95) + vec2(2.1, 9.4) + 0.6 * vec2(n2, n1);
        float n3 = 1.0 - abs(2.0 * vnoise(q3) - 1.0);
        c += fine * 0.9 * n3 * n3 * n3 * (0.3 + n2);
    }
    return c;
}

// Valley walls rise beyond the lake shore into ridged, snow-capped peaks.
float auTerrainBase(vec2 p, int oct, float fine) {
    float dx = abs(p.x - auPath(p.y));
    float wall = min(max(dx - 50.0, 0.0) * 0.42, 30.0);
    float r = 0.0;
    float a = 1.0;
    float wgt = 1.0;
    vec2 q = p * 0.010 + vec2(3.7, 1.3);
    for (int i = 0; i < 6; i++) {
        if (i >= oct) break;
        float n = 1.0 - abs(2.0 * vnoise(q) - 1.0);
        n *= n;
        // finer octaves only where the coarser ones made a ridge: sharp
        // arêtes and smooth cirques instead of uniform lumps
        r += a * n * wgt;
        wgt = saturate(n * 1.7);
        q = FBM_OCTAVE * q;
        a *= 0.52;
    }
    float env = smoothstep(30.0, 110.0, dx);
    float crag = dx > 40.0 && fine >= 0.0 ? auCrag(p, fine) * smoothstep(40.0, 70.0, dx) : 0.0;
    return osSmin(wall - 4.0 + r * 52.0 * env + crag, 70.0, 6.0);
}

// the march skips the crags (a few units at most): they only shape the normals
float auTerrain(vec2 p, int oct) { return auTerrainBase(p, oct, -1.0); }

float auMarch(vec3 ro, vec3 rd, float tmax, int n, int oct) {
    float t = 0.5;
    float tPrev = t;
    float hit = 0.0;
    for (int i = 0; i < 110; i++) {
        if (i >= n) break;
        vec3 p = ro + rd * t;
        // above every peak and climbing: nothing left to hit
        if (p.y > 72.0 && rd.y > 0.0) break;
        float dh = p.y - auTerrain(p.xz, oct);
        if (dh < 0.003 * t) { hit = 1.0; break; }
        tPrev = t;
        // the lake bed is flat within 30 of the path, which bends at most
        // 0.43 per unit: a safe horizontal stride across it
        float open = (30.0 - abs(p.x - auPath(p.z))) * 0.69;
        t += max(max(dh * 0.45, open), 0.05 + 0.0075 * t);
        if (t > tmax) break;
    }
    if (hit < 0.5) return -1.0;
    for (int i = 0; i < 4; i++) {
        float tm = 0.5 * (t + tPrev);
        vec3 p = ro + rd * tm;
        if (p.y - auTerrain(p.xz, oct) < 0.0) t = tm; else tPrev = tm;
    }
    return t;
}

// Curtain sheet density at a ground position for the normalised height hn,
// given the pixel's fold warp w. Writes the along-fold coordinate and the
// rim proximity.
float auCurtain(vec2 xz, float hn, float flow, vec2 w, float folds, float sway, vec4 sa, vec4 sb, float shim,
                float kick, out float along, out float rim) {
    vec2 q = xz * (0.0045 * folds) + (w - 0.5) * 2.6 * sway;
    along = q.x;
    // ripples run along the folds, quick enough to read second by second;
    // the bass deepens them
    q.y += (0.05 + 0.12 * kick) * sin(q.x * 3.1 - shim * 1.7) + 0.03 * sin(q.x * 7.3 + shim * 2.3);
    float n = vnoise(q * vec2(0.7, 2.2) + vec2(0.0, flow * 0.012));
    float ridge = 1.0 - abs(2.0 * n - 1.0);
    float sheet = ridge * ridge;
    sheet *= sheet;
    sheet *= sheet;                       // ridge^8: a thin folded sheet
    // the lower rim undulates along the fold
    float hl = hn - 0.24 * w.y - 0.05 * sin(along * 2.3 + flow * 0.05);
    rim = exp(-hl * hl * 900.0);
    // the rays reach up by the spectrum, which repeats along every fold, so
    // the curtains draw the music across the sky as rays of light
    float bnd = auSpec(abs(fract(along * 0.16) * 2.0 - 1.0), sa, sb);
    float reach = 0.45 + 1.3 * bnd;
    float vert = smoothstep(-0.015, 0.02, hl) * exp(-max(hl, 0.0) * 2.4 / reach);
    // vertical rays: the same striation at every height, shimmering
    float rays = vnoise(vec2(along * 24.0, flow * 0.25 + shim));
    rays = 0.15 + 1.1 * rays * rays;
    return sheet * vert * rays;
}

vec2 auWarp(vec2 xz, float flow, float folds) {
    vec2 q = xz * (0.0027 * folds);
    return vec2(vnoise(q + vec2(flow * 0.045, 1.3)),
                vnoise(q + vec2(5.2, 7.7) - vec2(0.0, flow * 0.035)));
}

vec3 auAurora(vec3 ro, vec3 rd, VisualUniforms u, float flow, int n, float dither, float energy, vec4 sa, vec4 sb,
              float shim, float rush) {
    if (rd.y <= 0.0) return vec3(0.0);
    float folds = mix(0.7, 1.6, u.param0);
    float sway = mix(0.4, 1.2, u.param1) * (1.0 + 0.5 * rush);
    float span = mix(45.0, 120.0, u.param2);
    float rdy = max(rd.y, 0.035);
    // one fold warp per pixel, taken at the rim height
    vec2 w = auWarp(ro.xz + rd.xz * ((60.0 - ro.y) / rdy), flow, folds);
    vec3 acc = vec3(0.0);
    float beat = u.bassImpact;
    float bc = floor(mod(u.beatCount, 64.0)) + saturate(u.beatPhase);
    vec3 fringe = peakWhite(palVisual(0.97, u), 0.15 + 0.3 * u.treble) * (0.5 + 2.2 * beat + 1.2 * u.bass);
    // green rim to violet crown: three palette reads per pixel, not per layer
    vec3 cLow = palVisual(0.72, u);
    vec3 cMid = palVisual(0.47, u);
    vec3 cTop = palVisual(0.02, u);
    float bp = saturate(u.beatPhase);
    float front = 1.15 * pow(bp, 0.7);
    float bAmp = (0.5 + 2.0 * beat) * (1.0 - bp);
    for (int i = 0; i < 56; i++) {
        if (i >= n) break;
        float hn = (float(i) + dither) / float(n);
        float h = 55.0 + span * hn * hn;      // layers bunch at the rim
        float t = (h - ro.y) / rdy;
        vec2 xz = ro.xz + rd.xz * t;
        float along, rim;
        float d = auCurtain(xz, hn, flow, w, folds, sway, sa, sb, shim, beat + 0.5 * u.bass, along, rim);
        if (d < 0.002) continue;
        float fade = exp(-t * 0.0016);
        // beats run as pulses along the folds
        float pd = fract(along * 0.12 - bc * 0.25) - 0.5;
        float pulse = exp(-pd * pd * 60.0);
        float hs = sqrt(hn);
        // each beat sends a bright front climbing the curtains from the rim
        float fd = hs - front;
        float climb = exp(-fd * fd * 45.0) * bAmp;
        float lit = (0.35 + 1.6 * energy) * (1.0 + pulse * (0.4 + 1.2 * beat)) * (1.0 + 1.5 * hn) * (1.0 + 0.5 * rush);
        vec3 c = mix(mix(cLow, cMid, saturate(hs * 2.2)), cTop, saturate(hs * 1.6 - 0.6));
        // hot magenta-white lower fringe, heated by the bass
        c += fringe * rim;
        // the climbing front glows in the crown colour, so every beat runs a
        // violet wave up through the green
        c += cTop * climb * 2.4;
        acc += c * d * lit * fade;
    }
    // looking straight up through the sheets saturates; ease it
    return acc * (5.0 / float(n)) / (1.0 + 1.6 * rd.y * rd.y);
}

vec3 auSky(vec3 ro, vec3 rd, VisualUniforms u, float flow, int n, float dither, float energy, vec4 sa, vec4 sb,
           float shim, float rush) {
    float h = saturate(rd.y);
    vec3 col = mix(palVisual(0.56, u) * 0.035 + vec3(0.004, 0.006, 0.012),
                   vec3(0.002, 0.003, 0.010), pow(h, 0.45));
    // stars, twinkling with the treble
    vec2 sp = vec2(atan2_(rd.x, rd.z), rd.y) * 140.0;
    vec2 cell = floor(sp);
    vec2 sh = hash22(cell);
    float sd = length(fract(sp) - 0.2 - 0.6 * sh);
    float mag = pow(hash21(cell + 17.0), 24.0);
    float tw = 0.7 + 0.3 * sin(mod(u.time, 600.0) * (3.0 + 4.0 * sh.x) + sh.y * 30.0);
    col += vec3(0.8, 0.88, 1.0) * mag * exp(-sd * sd * 90.0) * 6.0 * tw * (0.6 + 0.8 * u.treble)
         * smoothstep(0.0, 0.08, rd.y);
    // a faint milky band
    float md = rd.y - 0.45 * rd.x - 0.35;
    float mw = exp(-md * md * 18.0);
    col += palVisual(0.2, u) * 0.03 * mw * fbm(sp * 0.04);
    col += auAurora(ro, rd, u, flow, n, dither, energy, sa, sb, shim, rush);
    return col;
}

// Snow and rock lit from above by the curtains overhead.
vec3 auRock(vec3 p, vec3 rd, float dist, VisualUniforms u, float flow, float energy, int oct, vec4 sa, vec4 sb,
            float shim) {
    float e = 0.06 + 0.003 * dist;
    float fine = oct > 3 ? saturate(1.6 - dist * 0.006) : 0.0;
    float hc = auTerrainBase(p.xz, oct, fine);
    vec3 n = normalize(vec3(hc - auTerrainBase(p.xz + vec2(e, 0.0), oct, fine), e,
                            hc - auTerrainBase(p.xz + vec2(0.0, e), oct, fine)));
    // snow holds on ledges and gentle faces; steep rock stays bare
    // and the high ground is snowbound on all but the steepest faces
    float hs = 0.34 * smoothstep(14.0, 46.0, p.y);
    // ragged, crisp snow edges: two octaves of breakup and a narrow ramp
    float brk = 0.16 * (vnoise(p.xz * 0.35) - 0.5) + 0.09 * (vnoise(p.xz * vec2(1.4, 3.1) + 3.7) - 0.5);
    float snow = smoothstep(0.70 - hs, 0.78 - hs, n.y + brk)
               * smoothstep(5.0, 8.0, p.y + 4.0 * vnoise(p.xz * 0.04));
    // rock: dark strata bands warped down the slope, with lighter seams
    float sv = vnoise(p.xz * vec2(0.08, 0.3));
    float strata = 0.5 + 0.5 * sin(p.y * 1.5 + 7.0 * sv + 0.04 * p.x);
    float grit = vnoise(p.xz * vec2(0.6, 1.9) + p.y * 0.7);
    vec3 rock = vec3(0.085, 0.088, 0.105) * (0.72 + 0.28 * strata * strata) * (0.7 + 0.6 * grit)
              + vec3(0.012, 0.011, 0.01) * smoothstep(0.94, 1.0, strata);
    // wind-packed snow: faintly uneven albedo
    vec3 snowA = vec3(0.82, 0.88, 1.0) * (0.82 + 0.18 * vnoise(p.xz * vec2(0.5, 1.6)));
    vec3 alb = mix(rock, snowA, snow);
    float along, rim;
    float folds = mix(0.7, 1.6, u.param0);
    vec2 oxz = p.xz + vec2(0.0, 50.0);
    float over = auCurtain(oxz, 0.1, flow, auWarp(oxz, flow, folds), folds, mix(0.4, 1.2, u.param1), sa, sb, shim, u.bassImpact, along, rim);
    vec3 light = mix(vec3(0.45, 0.5, 0.6), palVisual(0.62, u), 0.6) * (0.2 + 0.55 * energy) * (0.45 + 3.2 * over) + vec3(0.02, 0.03, 0.065);
    // two-tone sky light: the curtains overhead key the upward faces in
    // green, the violet crowns and the night sky fill the rest
    vec3 ld = normalize(vec3(0.15, 1.0, -0.4));
    // crisp key: plain Lambert, so faces turn sharply from lit to shade
    float dif = saturate(dot(n, ld));
    // cavity: the shading-only crags darken the gullies they cut
    float cav = saturate(0.55 + 0.6 * n.y);
    // the whole sky is alight, so faces turned from the key still take a
    // cool fill from the crowns and a green one from the curtains ahead
    vec3 fill = palVisual(0.02, u) * (0.2 + 0.25 * energy) + palVisual(0.72, u) * (0.1 + 0.16 * energy) * (0.7 + 1.2 * over)
              + vec3(0.02, 0.026, 0.055);
    // the lit lake throws a soft green light up the steep lower walls
    vec3 bounce = palVisual(0.72, u) * (0.08 + 0.14 * energy) * saturate(1.0 - n.y) * exp(-max(p.y, 0.0) * 0.04);
    vec3 col = alb * (light * (0.1 + 1.3 * dif) + fill * (0.6 + 0.4 * n.y) + bounce) * cav;
    // snow facing the camera picks up a faint glossy sheen of the curtains
    col += light * pow(1.0 - saturate(dot(-rd, n)), 5.0) * (0.012 + 0.03 * snow);
    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);

    vec2 fl = osFlight(u, 3.2, 1.0);
    float z = fl.x;
    // a long, eased rise and settle, independent of the audio
    float cyc = 0.5 - 0.5 * cos(mod(u.time, 720.0) * 0.0873);
    float alt = mix(2.0, 16.0, cyc * cyc * (3.0 - 2.0 * cyc));
    vec3 ro = vec3(auPath(z), alt, z);
    vec3 ta = vec3(auPath(z + 45.0), alt * 0.5 + 17.0, z + 45.0);
    float roll = osBank(u, 0.05) - 0.004 * (auPath(z + 40.0) - auPath(z));
    vec3 rd = osCamera(ro, ta, roll, 1.25, p);

    // curtain drift: steady, with the flight's surges
    float flow = mod(u.time, 600.0) * mix(0.6, 1.6, u.param1) + fl.x * 0.15;
    int n = osSteps(14.0, 32.0, detail);
    vec4 sA = vec4(bandAt(u, 0.0), bandAt(u, 1.0 / 7.0), bandAt(u, 2.0 / 7.0), bandAt(u, 3.0 / 7.0));
    vec4 sB = vec4(bandAt(u, 4.0 / 7.0), bandAt(u, 5.0 / 7.0), bandAt(u, 6.0 / 7.0), bandAt(u, 1.0));
    float rush = saturate((fl.y - 1.0) / 3.5);
    // the rays shimmer about once a second, faster as a build gathers
    float shim = mod(u.time, 600.0) * 0.9 + fl.x * 0.25;
    float dither = hash21(floor(uv * u.resolution) + vec2(0.37, 0.71));
    float xb = saturate(0.5 + 0.42 * rd.x / max(abs(rd.z) + abs(rd.y), 0.2));
    float energy = bandAt(u, 0.04 + 0.7 * xb) * 0.7 + 0.3 * u.level;
    int oct = detail > 0.5 ? 4 : 3;
    int steps = osSteps(36.0, 66.0, detail);

    float tw = rd.y < 0.0 ? -ro.y / rd.y : 1e5;
    float t = auMarch(ro, rd, min(tw, 420.0), steps, oct);
    vec3 col;
    vec3 haze = palVisual(0.56, u) * 0.012 + vec3(0.002, 0.003, 0.008);
    float tt;
    if (t > 0.0) {
        col = auRock(ro + rd * t, rd, t, u, flow, energy, t < 160.0 ? oct + 1 : oct, sA, sB, shim);
        tt = t;
    } else if (tw < 420.0) {
        // calm lake: a softly rippled mirror of the sky and the walls
        vec3 pos = ro + rd * tw;
        float wt = mod(u.time, 600.0) * 0.6;
        // fine wavelets running across the view streak the mirror
        float wv = vnoise(pos.xz * vec2(0.05, 0.11) + vec2(0.0, wt * 0.2));
        float rip = sin(pos.z * 1.1 + wt * 2.0 + 6.0 * wv) * 0.6 + sin(pos.z * 2.7 - wt * 1.3 + pos.x * 0.35) * 0.3;
        vec3 wn = normalize(vec3(0.004 * sin(pos.x * 0.6 + wt), 1.0, 0.016 * rip * (0.4 + wv)));
        vec3 rr = reflect(rd, wn);
        rr.y = abs(rr.y);
        float fres = 0.2 + 0.8 * pow(1.0 - saturate(-rd.y), 4.0);
        float t2 = auMarch(pos + vec3(0.0, 0.01, 0.0), rr, 380.0, osSteps(16.0, 28.0, detail), 3);
        vec3 refl;
        if (t2 > 0.0) {
            refl = auRock(pos + rr * t2, rr, t2 + tw, u, flow, energy, 3, sA, sB, shim);
            refl = mix(refl, haze, 1.0 - exp(-t2 * 0.006));
        } else {
            refl = auSky(pos, rr, u, flow, max(n / 2, 10), dither, energy, sA, sB, shim, rush);
        }
        col = refl * fres + vec3(0.001, 0.002, 0.004);
        tt = tw * 0.5;
    } else {
        col = auSky(ro, rd, u, flow, n, dither, energy, sA, sB, shim, rush);
        tt = 0.0;
    }
    col = mix(col, haze, 1.0 - exp(-tt * 0.004));
    // low mist on the water, glowing with the curtains' light
    float tm = tt > 0.0 ? tt : 600.0;
    float ry = abs(rd.y) > 1e-3 ? rd.y : 1e-3;
    float mist = 2.5 * (exp(-ro.y / 2.5) - exp(-max(ro.y + ry * tm, 0.0) / 2.5)) / ry;
    col += palVisual(0.6, u) * (0.004 + 0.012 * energy) * (1.0 - exp(-0.05 * max(mist, 0.0)));
    return col; // LINEAR HDR — post chain tonemaps
}
