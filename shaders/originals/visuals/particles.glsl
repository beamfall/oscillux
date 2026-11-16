// SPDX-License-Identifier: AGPL-3.0-only
// Particles: a rising vortex of embers. Thousands of glowing particles
// spiral up through nested spectral attractor shells round a molten light
// column, above a black mirror floor. Embers leave the floor hot gold and
// cool to pink and cyan as they climb; every beat sends an ignition front up
// the column that flashes the embers it passes white-hot. A shallow depth
// of field turns near and far particles into soft bokeh, the floor reflects
// the whole column, and the swirl surges and brakes with the beat-locked
// speed profile while the camera drifts round it.
//
// Each shell is a flared cylinder whose surface is tiled into cells that
// rotate and rise with the flow; a pixel's ray meets each shell at most
// twice and checks the six nearest cells there, so the swarm is dense but
// cheap.
//
// param0 Density      -> how many cells hold a particle
// param1 Burst        -> how far the bass impact flings the shells outward
// param2 Trail Length -> length of each particle's motion streak

const float PT_FLOOR = -1.45;
const float PT_TOP = 2.3;

vec4 ptHash41(float p) {
    uint h = hashMix(hashBits(p) ^ 0xbe633942u);
    return vec4(hashUnit(h), hashUnit(hashMix(h ^ 0x6294a626u)), hashUnit(hashMix(h ^ 0xa97a7369u)),
                hashUnit(hashMix(h ^ 0xed81fd3au)));
}

// A bokeh disc of radius r at distance d: flat body, a slightly bright rim
// when defocused, and a hot centre while it is still sharp.
float ptBokeh(float d, float r, float sharp) {
    float aa = 0.12 * r;
    float body = 1.0 - smoothstep(r - aa, r + aa, d);
    float rim = exp(-pow((d - r * 0.84) / max(r * 0.13, 1e-4), 2.0)) * body;
    float hot = exp(-d * d / max(r * r * 0.08, 1e-8));
    float halo = exp(-d * d / max(r * r * 2.5, 1e-8)) * 0.12;
    return body * (0.5 + 0.3 * sharp) + rim * 0.4 * (1.0 - sharp) + hot * sharp * 2.0 + halo;
}

// One shell. R(y) = r0 * (1 + flare * (y - floor)). Cells are cw wide (at
// r0) and cw tall; the shell turns at om and rises at vy per unit of flow.
// geo = (r0, flare, cw, density), mot = (om, vy, flow, seed),
// lens = (focus, aperture, energy, sizeScale).
vec3 ptShell(vec3 ro, vec3 rd, vec3 fw, vec4 geo, vec4 mot, vec4 lens, vec3 c0, vec3 c1, float lag,
             vec2 wave, vec3 cHot) {
    float r0 = geo.x, flare = geo.y, cw = geo.z, dens = geo.w;
    float A = r0 * (1.0 - flare * PT_FLOOR), B = r0 * flare;
    float qa = dot(rd.xz, rd.xz) - B * B * rd.y * rd.y;
    float k0 = A + B * ro.y;
    float qb = dot(ro.xz, rd.xz) - B * rd.y * k0;
    float qc = dot(ro.xz, ro.xz) - k0 * k0;
    float disc = qb * qb - qa * qc;
    vec3 acc = vec3(0.0);
    if (disc <= 0.0 || abs(qa) < 1e-4) return acc;
    float sq = sqrt(disc);
    float nsec = floor(6.2831853 * r0 / cw + 0.5);
    for (int root = 0; root < 2; root++) {
        float t = (-qb + (root == 0 ? -sq : sq)) / qa;
        if (t < 0.05) continue;
        vec3 hp = ro + rd * t;
        if (hp.y < PT_FLOOR || hp.y > PT_TOP) continue;
        float th = atan2_(hp.z, hp.x) - mot.z * mot.x;
        // discs must stay inside the cells checked; at grazing angles
        // the surface stretches, so the allowance shrinks with incidence
        float inc = abs(dot(rd.xz, hp.xz)) / max(length(hp.xz), 1e-4);
        float rcap = cw * (0.08 + 0.5 * inc);
        // near the silhouette rays miss the shell, so fade out before discs clip
        float edge = smoothstep(0.05, 0.4, inc);
        float sx = th / 6.2831853 * nsec;
        float sy = (hp.y - mot.z * mot.y) / cw;
        // the trail runs behind each particle, so one extra column of cells
        // ahead of the pixel is checked to catch the heads of long streaks
        vec2 base = floor(vec2(sx, sy) - 0.5);
        for (int c = 0; c < 6; c++) {
            vec2 cell = base + vec2(float(c - 3 * (c / 3)), float(c / 3));
            float ci = mod(cell.x, nsec);
            float cj = mod(cell.y, 509.0);
            vec4 h = ptHash41(ci * 7.13 + cj * 113.71 + mot.w);
            // particle centre inside the cell
            float pth = (cell.x + 0.2 + 0.6 * h.y) / nsec * 6.2831853 + mot.z * mot.x;
            float py = (cell.y + 0.2 + 0.6 * h.z) * cw + mot.z * mot.y;
            float fade = smoothstep(PT_FLOOR, PT_FLOOR + 0.5, py) * smoothstep(PT_TOP, PT_TOP - 1.3, py);
            // streams: density runs in slow spiral bands up the shell
            float band = 0.5 + 0.5 * sin(pth * 3.0 - py * 2.2 + mot.w);
            float keep = dens * fade * (0.35 + 0.65 * band);
            if (h.x > keep) continue;
            float pr = r0 * (1.0 + flare * (py - PT_FLOOR)) + (h.w - 0.5) * 0.08;
            vec3 P = vec3(cos(pth) * pr, py, sin(pth) * pr);
            vec3 rel = P - ro;
            // streak back along the particle's motion (turn plus rise)
            vec3 v = -vec3(-sin(pth) * pr * mot.x, mot.y, cos(pth) * pr * mot.x) * lag;
            float z = max(dot(rel, fw), 0.05);
            float sz = (0.010 + 0.014 * h.w * h.w) * lens.w;
            float rw = min(sz + lens.y * abs(z - lens.x), rcap);
            float sharp = sz / rw;
            // sharp embers draw thin streaks; defocused ones stay round discs
            float lv = length(v);
            v *= min(1.0, max(1.1 * cw - rw, 0.0) * sharp * sharp / max(lv, 1e-5));
            vec3 relp = rel - rd * dot(rel, rd);
            vec3 vp = v - rd * dot(v, rd);
            float sv = saturate(dot(relp, vp) / max(dot(vp, vp), 1e-8));
            float d = length(relp - vp * sv);
            float hotP = step(0.92, fract(h.y * 9.7));
            // embers leave the base hot and cool as they climb
            float hy = saturate((py - PT_FLOOR) / (PT_TOP - PT_FLOOR) + (fract(h.z * 5.3) - 0.5) * 0.35);
            vec3 pc = mix(c0, c1, smoothstep(0.1, 0.9, hy));
            pc = mix(pc, vec3(2.4, 2.1, 1.8) * luma(pc) + pc, hotP * 0.6);
            // the beat's ignition front sweeping up the column
            float wv = exp(-pow((py - wave.x) * 3.2, 2.0)) * wave.y;
            pc = mix(pc, cHot, saturate(wv * 0.4));
            float gain = lens.z * edge * (0.6 + 0.8 * h.w) * sz * sz / (rw * rw) * (1.0 + 2.2 * wv);
            // the tail fades behind the head
            acc += pc * ptBokeh(d, rw, sharp) * gain * (1.0 - 0.65 * sv) / (1.0 + length(vp) / rw * 0.5);
        }
    }
    return acc;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float tm = mod(u.time, 600.0);

    // ---- camera: slow drift round the column on the speed profile ----
    vec2 fc = osFlight(u, 0.035, 0.012);
    float cang = mod(fc.x, 600.0) * 0.9 + 0.6;
    float camR = 3.9 + 0.35 * sin(tm * 0.037);
    float camH = 0.55 + 0.40 * sin(tm * 0.029 + 1.3);
    vec3 ro = vec3(sin(cang) * camR, camH, cos(cang) * camR);
    vec3 ta = vec3(0.0, 0.15, 0.0);
    float roll = osBank(u, 0.06);
    float fov = 1.15;
    vec3 fw = normalize(ta - ro);
    vec3 upv = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(fw, upv));
    vec3 cu = cross(rt, fw);
    vec3 rd = normalize(p.x * rt + p.y * cu + fov * fw);

    // focus on the column's near face, breathing slowly
    float focus = camR - 1.0 + 0.5 * sin(tm * 0.083);
    float apW = 0.038;

    // ---- flow: the swirl surges and brakes with the beat ----
    vec2 ff = osFlight(u, 0.16, 0.07);
    float flow = mod(ff.x, 600.0);
    float burst = 1.0 + u.bassImpact * mix(0.05, 0.3, saturate(u.param1));
    float pulse = 1.0 + 0.25 * u.beat;
    float dens = mix(0.35, 0.85, saturate(u.param0));
    float spark = 1.0 + 0.8 * u.onset + 0.3 * u.flux;
    float lag = mix(0.05, 0.6, saturate(u.param2)) * (0.5 + 0.5 * ff.y);
    // every beat an ignition front races up the vortex from the floor
    float bp = saturate(u.beatPhase);
    vec2 wave = vec2(PT_FLOOR - 0.3 + bp * (PT_TOP - PT_FLOOR + 1.0), (0.45 + 1.1 * u.bass) * sqrt(1.0 - bp));
    vec3 cHot = peakWhite(palRolePeak(0.5, u), 0.2) * 1.3;

    // ---- floor: black mirror with a faint ripple ----
    float tf = rd.y < -1e-3 ? (PT_FLOOR - ro.y) / rd.y : -1.0;
    bool onFloor = tf > 0.0;
    vec3 fpos = ro + rd * max(tf, 0.0);
    vec3 rrd = rd;
    float fres = 0.0;
    if (onFloor) {
        vec2 rip = vec2(vnoise(fpos.xz * 1.9 + vec2(0.0, tm * 0.15)), vnoise(fpos.zx * 1.9 + 4.0)) - 0.5;
        rrd = normalize(vec3(rd.x + rip.x * 0.025, -rd.y, rd.z + rip.y * 0.025));
        fres = (0.32 + 0.55 * pow(1.0 - saturate(-rd.y), 4.0)) * exp(-tf * 0.05);
    }

    vec3 col = vec3(0.0);
    vec3 refl = vec3(0.0);
    int nShell = osSteps(3.0, 5.0, detail);
    int nRefl = osSteps(2.0, 5.0, detail);
    for (int k = 0; k < 5; k++) {
        if (k >= nShell) break;
        float fk = float(k) / 4.0;
        float r0 = (0.42 + 0.36 * float(k)) * burst;
        float e = (0.45 + 2.2 * bandAt(u, 0.04 + 0.8 * fk)) * pulse * (k == 4 ? spark : 1.0);
        // inner shells run hotter; every shell cools toward the top
        vec3 c0 = palVisual(0.02 + 0.22 * fk + 0.05 * u.spectralCentroid, u);
        vec3 c1 = palVisual(0.50 + 0.26 * fk, u);
        vec4 geo = vec4(r0, 0.14, 0.17 + 0.02 * float(k), dens * (1.0 - 0.12 * float(k)));
        vec4 mot = vec4(1.05 - 0.15 * float(k), 0.32 + 0.04 * float(k), flow, float(k) * 17.3);
        col += ptShell(ro, rd, fw, geo, mot, vec4(focus, apW, e, 1.0), c0, c1, lag, wave, cHot);
        if (onFloor && k < nRefl) {
            vec4 lensR = vec4(focus + tf, apW * 1.6, e * 0.8, 1.4);
            refl += ptShell(fpos, rrd, rrd, geo, mot, lensR, c0, c1, lag, wave, cHot);
        }
    }
    // sparse sparks in a wide outer shell and a backdrop of drifting motes
    {
        vec3 cs = palVisual(0.5, u);
        float es = (0.4 + 1.6 * bandAt(u, 0.85)) * spark;
        col += ptShell(ro, rd, fw, vec4(2.9, 0.08, 0.3, 0.22 * dens), vec4(0.35, 0.22, flow, 71.0),
                       vec4(focus, apW, es, 1.1), cs, palVisual(0.3, u), lag, wave, cHot);
        col += ptShell(ro, rd, fw, vec4(7.0, 0.0, 0.7, 0.45), vec4(0.04, 0.05, flow, 93.0),
                       vec4(focus, apW * 0.7, 0.35 + 0.6 * u.mid, 1.8), palVisual(0.62, u), cs, lag, vec2(0.0), cHot);
    }

    // ---- the vortex's luminous core and the haze around it ----
    vec3 coreCol = palRoleBass(0.1, u);
    {
        vec2 rxz = rd.xz;
        float l2 = max(dot(rxz, rxz), 1e-5);
        float tca = max(-dot(ro.xz, rxz) / l2, 0.0);
        float dax = length(ro.xz + rxz * tca);
        float yat = ro.y + rd.y * tca;
        float span = smoothstep(PT_FLOOR, PT_FLOOR + 0.6, yat) * smoothstep(PT_TOP + 0.4, 0.2, yat);
        float eb = bandAt(u, 0.05);
        if (!onFloor || tca < tf) {
            float rise = vnoise(vec2(yat * 2.6 - flow * 3.0, dax * 3.0 + 1.7));
            float lit = (0.6 + 1.2 * eb + 0.4 * u.bassImpact) * span * (0.55 + 0.9 * rise)
                      * (1.0 + 1.6 * wave.y * exp(-pow((yat - wave.x) * 2.5, 2.0)));
            col += peakWhite(coreCol, 0.25) * exp(-dax * dax * 45.0) * 0.22 * lit;
            col += coreCol * (exp(-dax * dax * 8.0) * 0.12 + exp(-dax * dax * 1.0) * 0.03) * lit;
        }
        // the haze of the chamber lit by the column, cut softly by the floor
        float hz = onFloor ? smoothstep(-1.5, 1.5, tf - tca) : 1.0;
        col += mix(coreCol, palVisual(0.6, u), 0.5) * exp(-dax * dax * 0.25) * span * hz * 0.010 * (1.0 + eb);
    }

    if (onFloor) {
        // light pooled round the base of the column
        float fr = length(fpos.xz);
        float eb = bandAt(u, 0.06);
        vec3 pool = coreCol * (0.4 + 1.4 * eb) / (fr * fr * 1.5 + 0.25)
                  + palVisual(0.45, u) * 0.3 / (pow(fr - 1.2 * burst, 2.0) * 3.0 + 0.4);
        float spec = 0.7 + 0.3 * vnoise(fpos.xz * 3.3);
        vec3 flo = pool * 0.03 * spec * exp(-tf * 0.06) * pulse + refl * fres * 2.4
                  + palVisual(0.6, u) * 0.006 * exp(-rrd.y * 9.0) * fres * 2.0;
        // a faint panel seam so the mirror reads as a surface (floor only:
        // everything already in col is in front of it)
        vec2 tile = abs(fract(fpos.xz * 0.5) - 0.5);
        float seam = 1.0 - smoothstep(0.0, 0.012, min(tile.x, tile.y));
        // the far floor dissolves into the same horizon as the backdrop
        vec3 flr = flo * (1.0 - 0.5 * seam) + pool * 0.01 * seam * exp(-tf * 0.08);
        col += mix(flr, palVisual(0.6, u) * 0.006, 1.0 - exp(-tf * 0.10));
    } else {
        // a faint cool gradient behind the column
        col += palVisual(0.6, u) * 0.006 * exp(-max(rd.y, 0.0) * 9.0);
    }

    col = accentize(col, u.accent, 0.10);
    return col; // LINEAR HDR — post chain tonemaps
}
