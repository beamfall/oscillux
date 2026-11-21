// SPDX-License-Identifier: AGPL-3.0-only
// Memory Tunnel.
// A flight down a long, dark gallery hall hung with backlit photo prints.
// The prints are staggered along both walls, each showing its own slowly
// drifting crop of the photo. Far away they are faded palette duotones, and
// they develop into full colour as they approach, like memories coming back.
// Every print spills its own colour onto the charcoal walls, the soft ceiling
// and the polished floor, which mirrors the whole hall; coloured haze hangs in
// the air. Calm under loud music: the flight runs at a slow, steady pace, the
// roll sways gently and prints dim as they pass beside the camera, so bright
// prints never sweep past fast enough to flash. Audio drives the light only:
// the smoothed level warms the lightboxes and breathes in the ceiling
// diffuser, a modest band term lights the slim ledge under each print, and
// the ledges swell only faintly after each beat.
// param0 = Flight ; param1 = Depth ; param2 = Pulse

const float MT_HW = 1.9;      // half width of the hall
const float MT_FLOOR = -1.1;  // floor height
const float MT_CEIL = 1.55;   // ceiling height
const float MT_PZ = 3.4;      // print pitch along each wall
const float MT_PW = 1.15;     // print half length along the wall
const float MT_PY0 = -0.5;    // print bottom
const float MT_PY1 = 0.98;    // print top

// The palette read once at five stops, blended locally.
struct MtPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

MtPal mtPalLoad(VisualUniforms u) {
    MtPal P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

// Clamped, not wrapped: an offset never snaps across the palette's ends.
vec3 mtPal(MtPal P, float t) {
    t = clamp(t, 0.0, 1.0) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// Distance to the nearest surface of the hall from inside, and which one:
// 0 the wall at -x, 1 the wall at +x, 2 the ceiling, 3 the floor.
float mtHit(vec3 ro, vec3 rd, out float face) {
    float rx = rd.x >= 0.0 ? max(rd.x, 1e-4) : min(rd.x, -1e-4);
    float tx = ((rx > 0.0 ? MT_HW : -MT_HW) - ro.x) / rx;
    float ty = rd.y > 0.0 ? (MT_CEIL - ro.y) / max(rd.y, 1e-4) : (MT_FLOOR - ro.y) / min(rd.y, -1e-4);
    face = tx < ty ? (rx < 0.0 ? 0.0 : 1.0) : (rd.y > 0.0 ? 2.0 : 3.0);
    return min(tx, ty);
}

// Per-print crop: span and offset of the drifting cover-fit window.
void mtCrop(vec2 cell, out vec2 span, out vec2 off, VisualUniforms u) {
    float h1 = hash21(cell + 1.3);
    float h2 = hash21(cell + 7.7);
    float h3 = hash21(cell + 3.1);
    vec2 isz = max(IMGSIZE, vec2(1.0));
    float ai = isz.x / isz.y;
    float at = (2.0 * MT_PW) / (MT_PY1 - MT_PY0);
    vec2 cov = at > ai ? vec2(1.0, ai / at) : vec2(at / ai, 1.0);
    span = cov * mix(0.5, 0.95, h1);
    float ph = mod(u.time, 600.0) * 0.05 + h3 * 6.2832;
    off = (1.0 - span) * (0.5 + 0.5 * vec2(sin(ph + h2 * 6.2832), cos(ph * 0.8 + h1 * 6.2832)));
}

// The average colour a print throws into the room, in linear light.
vec3 mtPrintAvg(vec2 cell, VisualUniforms u) {
    vec2 span, off;
    mtCrop(cell, span, off, u);
    vec3 c = IMG(clamp(off + 0.5 * span, vec2(0.001), vec2(0.999))).rgb;
    c = max(c, vec3(0.0));
    return c * c + 0.02;
}

// Print centre z for wall w at row index i (the walls are staggered).
float mtPrintZ(float i, float w) { return (i + 0.5 * w) * MT_PZ; }

// Light leaving a wall point. w is 0 for the wall at -x and 1 for +x.
// lk: x = camera z, y = pulse, z = the accent hue offset, w = how much the
// prints passing close to the camera dim.
vec3 mtWall(vec3 pos, float w, float t, vec4 lk, float detail,
            bool cheap, MtPal P, VisualUniforms u) {
    float zl = pos.z / MT_PZ - 0.5 * w;
    float row = floor(zl + 0.5);
    float zr = (zl - row) * MT_PZ;              // along the wall from the print centre
    vec2 cell = vec2(w, mod(row, 512.0));
    float y = pos.y;

    // charcoal wall, lit by the spill of this print and the ceiling
    vec2 dq = vec2(max(abs(zr) - MT_PW, 0.0), max(max(MT_PY0 - y, y - MT_PY1), 0.0));
    float dp = length(dq);
    vec3 avg = mtPrintAvg(cell, u);
    float bassW = 1.0 + 0.15 * saturate(u.level);
    // the spill is the print's own colour pushed toward the hall's accent, so
    // the walls between prints carry colour rather than a grey wash
    vec3 spill = mix(avg, luma(avg) * mtPal(P, 0.04 + lk.z) * 2.2, 0.45);
    vec3 col = spill * exp(-dp * 4.0) * 0.13 * bassW + mtPal(P, 0.0) * 0.012;
    col += mtPal(P, 0.97 + 0.5 * lk.z) * 0.012 * smoothstep(0.2, 1.55, y);
    // a faint vertical panel joint between prints
    float jz = abs(abs(zr) - 0.5 * MT_PZ);
    col *= 1.0 - 0.6 * (1.0 - smoothstep(0.0, 0.01 + fwidth(zr) * 1.5, jz));
    col += mtPal(P, 0.0) * 0.004;

    // slim ledge under the print, lit by a spectrum band (eased toward the
    // level) and swelling softly just after each beat
    float ledge = (1.0 - smoothstep(0.0, 0.012 + fwidth(y) * 1.5, abs(y - (MT_PY0 - 0.08))))
                * step(abs(zr), MT_PW);
    float bp = saturate(u.beatPhase);
    float lift = 0.9 + 0.1 * lk.y * smoothstep(0.0, 0.3, bp) * (1.0 - bp) * (1.0 - bp) * 2.0;
    float lvl = mix(saturate(u.level), band(u, int(mod(row * 5.0 + w * 23.0, 48.0)) + 4), 0.2) * lift;
    vec3 ledgeCol = mtPal(P, (mod(row + w, 2.0) < 1.0 ? 0.97 : 0.27) + lk.z);
    col += peakWhite(ledgeCol, 0.15) * ledge * (0.5 + 0.8 * lvl);
    // the ledge washes the wall below it in its colour
    col += ledgeCol * exp(-max(MT_PY0 - 0.08 - y, 0.0) * 5.0) * step(y, MT_PY0 - 0.08)
         * smoothstep(MT_PW + 0.3, MT_PW - 0.3, abs(zr)) * 0.05 * (0.5 + 0.7 * lvl);

    // the print itself: a thin bright frame around a backlit image
    vec2 pr = vec2(zr / (2.0 * MT_PW) + 0.5, (y - MT_PY0) / (MT_PY1 - MT_PY0));
    vec2 fw = max(vec2(fwidth(pr.x), fwidth(pr.y)), vec2(1e-4));
    vec2 box = smoothstep(vec2(0.0), fw * 1.5, pr) * smoothstep(vec2(1.0), vec2(1.0) - fw * 1.5, pr);
    float inside = box.x * box.y;
    vec2 fd = min(pr, 1.0 - pr) * vec2(2.0 * MT_PW, MT_PY1 - MT_PY0);
    float frame = inside * (1.0 - smoothstep(0.0, 0.025 + 1.5 * max(fwidth(fd.x), fwidth(fd.y)), min(fd.x, fd.y)));
    float halo = (1.0 - inside) * exp(-dp * 30.0);
    if (inside < 0.001 && halo < 0.002) return col;

    vec2 span, off;
    mtCrop(cell, span, off, u);
    vec2 iv = clamp(pr, 0.0, 1.0);
    vec2 pv = w < 0.5 ? vec2(1.0 - iv.x, 1.0 - iv.y) : vec2(iv.x, 1.0 - iv.y);
    vec2 iuv = clamp(off + pv * span, vec2(0.001), vec2(0.999));
    vec3 photo;
    float far = smoothstep(5.0, 16.0, t);
    if (cheap) {
        photo = avg;
    } else {
        vec3 ph0 = max(IMG(iuv).rgb, vec3(0.0));
        photo = mix(ph0 * ph0, avg, far * mix(0.85, 1.0, 1.0 - detail));
    }
    // develop: far prints are palette duotones, near ones their true colour
    float lg = luma(photo);
    float h2 = hash21(cell + 7.7);
    float hl = h2 < 0.35 ? 0.27 : (h2 < 0.7 ? 0.75 : 0.5);
    hl = h2 > 0.88 ? 0.97 : hl;
    vec3 duo = mix(mtPal(P, 0.0) * 0.05, mtPal(P, hl + lk.z) * 1.2, smoothstep(0.01, 0.6, lg));
    float develop = smoothstep(14.0, 4.0, t);
    // split tone: the shadows of a developed print keep the palette's violet
    // end, the highlights their own colour
    vec3 near = photo * 1.2;
    near = mix(near, lg * mtPal(P, 0.1 + 0.5 * lk.z) * 2.4, 0.45 * (1.0 - smoothstep(0.05, 0.5, lg)));
    near = mix(near, duo, 0.14) + mtPal(P, 0.0) * 0.012;
    photo = mix(duo, near, develop);
    // backlight falls off toward the frame; every print has its own exposure
    vec2 cq = pr - 0.5;
    float back = 1.0 - 0.4 * dot(cq, cq) * 2.0;
    float expo = mix(0.7, 1.15, hash21(cell + 3.1));
    // the prints passing at the edge of view dim, so the frame's brightness
    // swings less as they go by
    float nearDim = mix(1.0, 0.25 + 0.75 * smoothstep(2.0, 12.0, t), lk.w);
    vec3 lit = photo * back * expo * bassW * nearDim;
    col = mix(col, lit, inside);
    col += peakWhite(mix(avg * 2.0, ledgeCol, 0.45), 0.15) * (frame * 0.35 + halo * 0.2) * nearDim;
    // glass cover: the ceiling diffuser glides over it at grazing angles
    col += mtPal(P, 0.74) * inside * 0.02;
    return col;
}

// Ceiling: a long soft diffuser between dark coffers, tinted by the prints.
vec3 mtCeil(vec3 pos, vec4 lk, MtPal P, VisualUniforms u) {
    float x = pos.x;
    float zl = pos.z / MT_PZ;
    float cz = fract(zl) - 0.5;
    // a frosted lamp between each pair of prints: bright core, soft falloff
    float pane = smoothstep(0.9, 0.82, abs(x)) * smoothstep(0.2, 0.17, abs(cz));
    float core = exp(-(x * x * 1.6 + cz * cz * 60.0));
    float diff = pane * (0.35 + 0.65 * core);
    float breath = 0.9 + 0.2 * saturate(u.level);
    // the lamps alternate between two of the palette's colours down the hall
    float lc = mod(floor(zl), 2.0);
    vec3 lamp = mtPal(P, (lc < 0.5 ? 0.76 : 0.97) + lk.z);
    vec3 c = peakWhite(lamp, 0.25 * core) * diff * 0.13 * breath + mtPal(P, 0.0) * 0.008;
    c += mtPal(P, 0.27 + lk.z) * pane * (1.0 - core) * 0.03;
    c += lamp * exp(-abs(cz) * 10.0) * smoothstep(1.4, 0.5, abs(x)) * 0.014 * breath;
    // spill from the nearest print on each wall
    float r0 = floor(zl + 0.5);
    float r1 = floor(zl);
    vec3 s0 = mtPrintAvg(vec2(0.0, mod(r0, 512.0)), u);
    vec3 s1 = mtPrintAvg(vec2(1.0, mod(r1, 512.0)), u);
    c += s0 * exp(-(MT_HW + x) * 2.5) * 0.07 + s1 * exp(-(MT_HW - x) * 2.5) * 0.07;
    return c;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float pulse = mix(0.4, 1.6, u.param2);
    float tt = mod(u.time, 600.0);

    // a slow, steady flight: bright prints sweeping past fast would flash
    float cruise = mix(1.6, 6.0, u.param0);
    float zc = mod(10.08 + mod(u.time, 36000.0) * cruise * 0.15, MT_PZ * 512.0);
    // every eight beats the hall's accent eases to a new place on the palette
    MtPal P = mtPalLoad(u);
    float b8 = (u.beatCount + saturate(u.beatPhase)) / 8.0;
    float k8 = floor(b8);
    float acc = 0.1 * mix(sin(k8 * 2.39996), sin((k8 + 1.0) * 2.39996), smoothstep(0.0, 1.0, b8 - k8));
    vec4 lk = vec4(zc, pulse, acc, 0.7);

    // slow eased drift off the axis; audio never moves the camera
    vec3 ro = vec3(0.4 * sin(tt * 0.13), 0.15 + 0.15 * sin(tt * 0.093 + 1.1), zc);
    vec3 ta = vec3(0.55 * sin(tt * 0.13 + 0.9), 0.05 + 0.1 * sin(tt * 0.07), zc + 7.0);
    float fov = 1.05;
    vec3 rd = osCamera(ro, ta, 0.1 * sin(mod(u.time, 628.31853) * 0.05), fov, p);

    float face;
    float t = mtHit(ro, rd, face);
    vec3 pos = ro + rd * t;
    float tAll = t;
    vec3 col;
    if (face < 1.5) {
        col = mtWall(pos, face, t, lk, detail, false, P, u);
    } else if (face < 2.5) {
        col = mtCeil(pos, lk, P, u);
    } else {
        // polished floor: a soft mirror of the hall, rippled by faint tile seams
        vec2 tile = pos.xz / vec2(0.95, 0.95);
        vec2 tf = abs(fract(tile) - 0.5);
        float seam = 1.0 - smoothstep(0.47, 0.49, max(tf.x, tf.y)) ;
        vec3 rr = vec3(rd.x, -rd.y, rd.z);
        float f2;
        float t2 = mtHit(pos, rr, f2);
        vec3 p2 = pos + rr * t2;
        vec3 refl;
        bool cheap = detail < 0.5;
        if (f2 < 1.5) refl = mtWall(p2, f2, t + t2, lk, detail, cheap, P, u);
        else refl = mtCeil(p2, lk, P, u);
        float fres = 0.22 + 0.6 * pow(1.0 - saturate(-rd.y), 5.0);
        refl *= exp(-t2 * 0.06);
        // colour spill pooling on the floor below each print
        float zl = pos.z / MT_PZ;
        float r0 = floor(zl + 0.5);
        float r1 = floor(zl);
        float z0 = abs(pos.z - mtPrintZ(r0, 0.0));
        float z1 = abs(pos.z - mtPrintZ(r1, 1.0));
        vec3 s0 = mtPrintAvg(vec2(0.0, mod(r0, 512.0)), u);
        vec3 s1 = mtPrintAvg(vec2(1.0, mod(r1, 512.0)), u);
        vec3 spill = s0 * exp(-(MT_HW + pos.x) * 2.2) * smoothstep(MT_PW + 0.8, 0.0, z0)
                   + s1 * exp(-(MT_HW - pos.x) * 2.2) * smoothstep(MT_PW + 0.8, 0.0, z1);
        col = refl * fres * mix(0.55, 1.0, seam) + spill * 0.12 + mtPal(P, 0.0) * 0.006;
        tAll = t + 0.4 * t2;
    }

    // coloured haze: palette fog, warmed by the spill of the prints around the camera
    float fogK = mix(0.085, 0.035, u.param1);
    float fog = 1.0 - exp(-tAll * fogK);
    float zl = ro.z / MT_PZ;
    vec3 hz = mtPrintAvg(vec2(0.0, mod(floor(zl + 1.5), 512.0)), u) + mtPrintAvg(vec2(1.0, mod(floor(zl + 1.0), 512.0)), u);
    vec3 fogCol = mtPal(P, 0.02 + 0.08 * u.spectralCentroid + acc) * 0.05 + hz * 0.012;
    col = mix(col, fogCol, fog);
    // dust motes drifting in the air, catching the light of the prints
    int nM = osSteps(3.0, 8.0, detail);
    float mz0 = floor(zc / 1.3) + 1.0;
    for (int k = 0; k < 8; k++) {
        if (k >= nM) break;
        float mid = mz0 + float(k);
        float tm = (mid * 1.3 - ro.z) / max(rd.z, 0.05);
        if (tm > tAll) break;
        vec2 mp = ro.xy + rd.xy * tm;
        vec2 g = mp * 2.2 + vec2(0.0, tt * 0.05) + hash22(vec2(mod(mid, 256.0), 1.0)) * 7.0;
        vec2 c = floor(g);
        vec2 h = hash22(c + mod(mid, 256.0) * 3.7);
        vec2 dv = (g - c - 0.15 - 0.7 * h) / 2.2;
        float px = tm * 2.0 / (u.resolution.y * fov);
        float mw = max(0.006, px) * (1.0 + 2.5 * smoothstep(2.5, 0.4, tm));
        float mote = exp(-dot(dv, dv) / (mw * mw)) * (0.006 / mw) * step(0.8, h.x);
        float side = smoothstep(0.0, MT_HW, abs(mp.x));
        vec3 mc = mix(mtPal(P, 0.74), mtPal(P, h.y < 0.5 ? 0.27 : 0.97), 0.5 * h.y);
        col += mc * mote * (0.3 + 0.9 * side) * (0.85 + 0.15 * sin(tt * 0.6 + h.y * 30.0)) * exp(-tm * 0.12)
             * smoothstep(0.2, 0.8, tm);
    }

    // light at the end of the hall
    float exitDot = saturate(rd.z);
    vec3 exitCol = peakWhite(mtPal(P, 0.75 + acc), 0.3);
    col += exitCol * (pow(exitDot, 300.0) * 0.6 + pow(exitDot, 30.0) * 0.06) * (0.9 + 0.15 * saturate(u.level));

    col *= 1.0 - 0.3 * smoothstep(0.9, 2.0, length(p));
    return col; // LINEAR HDR
}
