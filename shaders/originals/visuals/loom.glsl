// SPDX-License-Identifier: AGPL-3.0-only
// Loom.
// A slow glide over an endless loom at night. Fibre-bright warp threads stretch
// to a fog-lit vanishing point and glow with the spectrum, bass in the middle,
// treble at the selvedges. Ahead of the camera a softly glowing spindle
// shuttle makes one unhurried pass across the cloth every four seconds at the
// loom's own steady tempo, laying fresh weft that glows warm and cools into a
// dark dyed twill as it passes beneath. Both sides are lined with tall loom
// frames strung with heddle wires; each bay glows steadily and lifts only a
// little with the music's level and its band. Ripples travel away through the
// satin sheen. The glide is slow and level so the fine wires never strobe;
// audio drives light gently, never the camera, and no large area brightens on
// the kick. Reds stay just off saturated red.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 = Weave Density ; param1 = Flight Speed ; param2 = Ripple

// The palette read: the visual's own palette (3) with no beat or spectral
// nudge and no palette tour, so the host's vivid tour never swells the light;
// a host's manifest palette still replaces it. The fog tint is rebuilt on it.
vec3 lmPalSteady(float t, VisualUniforms u) { return osPalCalm(t, 3, u); }
vec3 lmPalSteadyFog(float t, VisualUniforms u) {
    vec3 c = lmPalSteady(t, u);
    return mix(vec3(luma(c) * 0.62), c, 0.42);
}

const float LM_HALF = 9.0;    // half cloth width
const float LM_CELL = 9.0;    // loom frame spacing along z
const float LM_POSTX = 11.5;  // post centre offset from the cloth centre
const float LM_H = 9.0;       // frame height
const float LM_ROW = 0.12;    // weft row pitch
const float LM_WRAP = 1260.0; // the whole scene repeats every LM_WRAP along z
const float LM_LEAD = 6.5;    // shuttle lead ahead of the camera
const float LM_SHED = 7.5;    // height of the raised warp sheet
const float LM_RISE = 12.0;   // length over which it rises from the fell

float lmMap(vec3 p) {
    float ax = abs(p.x);
    float cz = floor(p.z / LM_CELL);
    float lz = p.z - (cz + 0.5) * LM_CELL;
    float d = osBox(vec3(ax - LM_POSTX, p.y - LM_H * 0.5, lz), vec3(0.3, LM_H * 0.5, 0.3));
    // the top rails and the cloth-edge rails run the whole length
    d = min(d, length(vec2(ax - LM_POSTX, p.y - LM_H)) - 0.16);
    d = min(d, length(vec2(ax - LM_HALF - 0.5, p.y - 0.16)) - 0.11);
    // the cell boundary bounds the step so neighbours are never jumped over
    float zb = (cz + 1.0) * LM_CELL - p.z;
    float za = p.z - cz * LM_CELL;
    return min(d, max(min(za, zb), 0.0) + 0.3);
}

vec3 lmNormal(vec3 p) {
    vec2 e = vec2(0.003, -0.003);
    vec3 n = e.xyy * lmMap(p + e.xyy) + e.yyx * lmMap(p + e.yyx) +
             e.yxy * lmMap(p + e.yxy) + e.xxx * lmMap(p + e.xxx);
    return n / max(length(n), 1e-6);
}

float lmMarch(vec3 ro, vec3 rd, float t0, float tmax, int n) {
    float t = t0;
    for (int i = 0; i < 96; i++) {
        if (i >= n) break;
        float d = lmMap(ro + rd * t);
        if (d < 0.0015 * t) return t;
        t += d * 0.9;
        if (t > tmax) break;
    }
    return -1.0;
}

// Closest approach between a ray and the segment a0 + ba*h, h in [0, 1]:
// returns the distance, with the ray depth and segment parameter.
float lmSegDist(vec3 ro, vec3 rd, vec3 a0, vec3 ba, out float tr, out float hs) {
    vec3 oa = ro - a0;
    float bb = dot(ba, ba), rb = dot(rd, ba), orr = dot(oa, rd), ob = dot(oa, ba);
    hs = clamp((ob - rb * orr) / max(bb - rb * rb, 1e-4), 0.0, 1.0);
    tr = max(rb * hs - orr, 0.0);
    return length(oa + rd * tr - ba * hs);
}

// Keeps every red just off saturated red once tonemapped: green (for warm
// reds) or blue (for pink ones) rises to at least 0.3 of red, so no red area
// can strobe, while the hue barely moves.
float lmTone(float x) { return x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14); }
float lmToneInv(float y) {
    y = clamp(y, 0.0, 0.999);
    float a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y;
    return (-b + sqrt(b * b + 0.56 * a * y)) / (2.0 * a);
}
vec3 lmOffRed(vec3 c) {
    float r = lmTone(c.r), g = lmTone(c.g), b = lmTone(c.b);
    float need = 0.3 * r - g - b;
    if (need <= 0.0) return c;
    if (c.g > c.b) c.g = max(c.g, lmToneInv(g + need));
    else c.b = max(c.b, lmToneInv(b + need));
    return c;
}

// Peak and rim tints without the shared roles' onset/flux whitening, which
// would flash the vanishing-point glow and every post on the kick.
// The library nudges every palette read with the beat phase and the spectral
// centroid; that is undone here, so the whole frame never shifts colour with
// the music's timbre or snaps back on each beat (manifest mode has no nudge).
vec3 lmPal(float t, VisualUniforms u) {
    return lmPalSteady(t, u);
}

vec3 lmFog(float t, VisualUniforms u) {
    vec3 c = lmPal(t, u);
    return mix(vec3(luma(c) * 0.62), c, 0.42);
}
vec3 lmPeak(float t, VisualUniforms u) { return lmPal(t + 0.028, u); }
vec3 lmRim(float t, VisualUniforms u) { return mix(lmPal(t, u), lmPeak(t + 0.18, u), 0.5); }

// Band shown by the frame bay starting at cell cz.
float lmBayBand(VisualUniforms u, float cz) {
    return bandAt(u, fract(mod(cz, 12.0) / 12.0 + 0.04));
}

// Light emitted by a post or rail.
vec3 lmFrameGlow(vec3 pos, vec3 n, VisualUniforms u) {
    float ax = abs(pos.x);
    float cz = floor(pos.z / LM_CELL);
    float lz = pos.z - (cz + 0.5) * LM_CELL;
    float onPost = step(abs(ax - LM_POSTX), 0.38) * step(abs(lz), 0.38) * step(pos.y, LM_H - 0.2);
    // thin edges up the post corners and a hot cap
    float corner = 1.0 - smoothstep(0.0, 0.035, max(abs(abs(ax - LM_POSTX) - 0.3), abs(abs(lz) - 0.3)));
    vec3 col = onPost * corner * lmRim(0.62, u) * 1.6;
    float cap = exp(-abs(pos.y - LM_H + 0.25) * 30.0) * onPost;
    col += cap * lmPeak(0.3, u) * (1.0 + 0.1 * u.level);
    // rails: the top ones glow steadily, the cloth-edge ones carry dashes fixed
    // to the world so they stream past at the glide speed
    float railTop = step(LM_H - 0.2, pos.y) * (1.0 - onPost);
    col += railTop * lmPal(0.55, u) * 1.6;
    float railEdge = step(pos.y, 0.32) * step(abs(ax - LM_HALF - 0.5), 0.16);
    float dash = smoothstep(0.55, 0.8, abs(fract(pos.z * 0.2) - 0.5) * 2.0);
    col += railEdge * lmPal(0.2, u) * (0.25 + 1.6 * dash);
    return col;
}

// Heddle wires strung between the posts on the plane x = side * LM_POSTX: a
// level meter per bay, lit from the floor up to its band's level.
vec3 lmHeddles(vec3 ro, vec3 rd, float side, float tmax, VisualUniforms u, float detail) {
    // no early exits: fwidth below needs uniform control flow
    float t = (side * LM_POSTX - ro.x) / (abs(rd.x) > 1e-4 ? rd.x : 1e-4);
    t = clamp(t, -1.0, 1e3);
    vec3 q = ro + rd * t;
    float mask = step(0.0, t) * step(t, tmax) * step(0.0, q.y) * step(q.y, LM_H);
    float cz = floor(q.z / LM_CELL);
    float lz = q.z - cz * LM_CELL;
    float inBay = smoothstep(0.35, 0.6, lz) * (1.0 - smoothstep(LM_CELL - 0.6, LM_CELL - 0.35, lz));
    float wz = q.z / 0.3;
    float wire = 0.5 - 0.5 * cos(6.2831853 * wz);
    float fw = smoothstep(0.06, 0.3, fwidth(wz));
    wire = mix(pow(wire, 10.0), 0.176, fw);
    float lvl = saturate(0.45 + 0.1 * u.level + 0.02 * lmBayBand(u, cz));
    float h01 = q.y / LM_H;
    float lit = 1.0 - smoothstep(lvl - 0.03, lvl + 0.01, h01);
    float head = exp(-abs(h01 - lvl) * 60.0);
    vec3 c = lmPal(0.12 + 0.6 * h01 + 0.05 * 0.35, u);
    c = accentize(c, u.accent, 0.12);
    // the eyes of the heddles: a bright bead at mid height on every wire
    float eye = exp(-abs(h01 - 0.5) * 90.0) * wire * 1.5;
    vec3 col = c * inBay * (wire * (0.15 + 1.1 * lit) + head * (0.3 + 0.9 * wire)) + lmRim(0.6, u) * eye * inBay * 0.4;
    return col * mask * exp(-max(t, 0.0) * 0.02);
}

// Air glow: dark night with a bright vanishing point and faint shafts fanning
// out from it.
vec3 lmHaze(vec3 rd, VisualUniforms u, float withShafts) {
    float a = max(1.0 - rd.z, 0.0);           // about half the squared angle
    float vp = exp(-a * 900.0);
    float near = exp(-a * 60.0);
    float wide = exp(-a * 8.0);
    float band = exp(-abs(rd.y + 0.01) * 30.0);
    vec3 glow = lmPeak(0.34 + 0.06 * 0.35, u);
    vec3 col = lmFog(0.8, u) * (0.002 + 0.05 * wide * band);
    col += glow * (1.5 * vp + 0.32 * near + 0.18 * wide * band) * (0.95 + 0.05 * u.level);
    if (withShafts > 0.5 && rd.y > -0.01) {
        float ang = atan2_(rd.y + 0.02, rd.x);
        float shafts = vnoise(vec2(ang * 9.0, mod(u.time * 0.15, 400.0))) * vnoise(vec2(ang * 23.0 + 5.0, 1.0));
        col += lmPal(0.7, u) * shafts * near * 0.2;
    }
    return col;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);

    float density = mix(90.0, 200.0, u.param0);
    float speed = mix(0.04, 0.1, u.param1);
    float rippleAmt = mix(0.2, 1.6, u.param2);

    float z = mod(140.0 + u.time * speed, LM_WRAP);
    float w = 6.2831853 / LM_WRAP;
    float sway = 2.2 * sin(z * w * 7.0) + 0.8 * sin(z * w * 17.0 + 1.0);
    float alt = 2.3 + 0.5 * sin(z * w * 9.0 + 2.0);
    vec3 ro = vec3(sway, alt, z);
    vec3 ta = vec3(0.5 * sway, 1.1, z + 14.0);
    float roll = -0.025 * sway;
    vec3 rd = osCamera(ro, ta, roll, 1.15, p);

    // the cloth plane, computed in uniform control flow for fwidth
    float tp = rd.y < -1e-4 ? ro.y / -rd.y : 1e4;
    tp = min(tp, 1e4);
    vec3 hp = ro + rd * tp;
    float s = (hp.x + LM_HALF) / (2.0 * LM_HALF) * density;
    float r = hp.z / LM_ROW;
    float fs = smoothstep(0.06, 0.3, fwidth(s));
    float fr = smoothstep(0.12, 0.5, fwidth(r));

    // shuttle: one unhurried pass across the cloth every four seconds, easing at
    // the edges. It keeps the loom's own steady tempo (two picks a second): the
    // beat counter can jump when the beat tracker re-locks, which would throw
    // the shuttle and its light across the cloth in one frame.
    float sb = mod(u.time * 2.0, 64.0);
    float xS = LM_HALF * 0.94 * cos(0.39269908 * sb);
    float dirS = -sin(0.39269908 * sb);
    float zS = z + LM_LEAD;
    vec3 Ls = vec3(xS, 0.35, zS);
    // the shuttle burns in the palette's far hue (amber in deepSea) so it stands apart
    vec3 shCol = mix(lmPal(0.93, u), vec3(1.0), 0.2);
    float shPow = 0.85;
    // each reversal at a selvedge (every four seconds) beats up the pick: a soft glow
    // of light at that edge that dies away over the next beat
    float rev = floor(sb * 0.125 + 0.5) * 8.0;
    float since = sb - rev;
    float pick = since >= 0.0 ? smoothstep(0.0, 0.3, since) * exp(-since * 2.0) : 0.0;
    vec3 Lf = vec3(LM_HALF * 0.94 * (mod(rev, 16.0) < 1.0 ? 1.0 : -1.0), 0.3, zS);

    vec3 col;
    float tHit = tp;
    // structure lives only in the side slabs |x| in [HALF+0.35, POSTX+0.35]
    // below the top rail: march just the stretch of the ray inside them
    float sx = rd.x < 0.0 ? -1.0 : 1.0;
    float rdx = max(abs(rd.x), 1e-4);
    float tIn = max((LM_HALF + 0.35 - ro.x * sx) / rdx - 0.05, 0.05);
    float tOut = (LM_POSTX + 0.35 - ro.x * sx) / rdx;
    if (rd.y > 1e-4) tOut = min(tOut, (LM_H + 0.25 - ro.y) / rd.y);
    tOut = min(min(tOut, tp), 140.0);
    float t = tIn < tOut ? lmMarch(ro, rd, tIn, tOut, 44) : -1.0;
    if (t > 0.0) {
        tHit = t;
        vec3 pos = ro + rd * t;
        vec3 n = lmNormal(pos);
        vec3 l = Ls - pos;
        float ld = dot(l, l);
        float dif = saturate(dot(n, l * inversesqrt(max(ld, 1e-4))));
        col = lmFrameGlow(pos, n, u);
        col += shCol * shPow * dif * 0.9 / (1.0 + ld);
        col += lmHaze(reflect(rd, n), u, 0.0) * 0.3 * pow(1.0 - saturate(-dot(rd, n)), 3.0);
        col += vec3(0.004, 0.004, 0.007);
    } else if (tp < 1e3) {
        float ax = abs(hp.x);
        float behind = zS - hp.z;   // > 0 where the cloth is already woven
        float wovenM = smoothstep(-0.1, 0.1, behind);
        float onCloth = 1.0 - smoothstep(LM_HALF - 0.05, LM_HALF + 0.05, ax);

        float sid = floor(s);
        float rid = floor(r);
        float acr = abs((sid + 0.5) / density * 2.0 - 1.0);
        float bnd = bandAt(u, acr);

        // thread profiles fade to their mean where the weave is finer than a pixel
        float warpP = 0.5 - 0.5 * cos(6.2831853 * s);
        float weftP = 0.5 - 0.5 * cos(6.2831853 * r);
        float fibre = mix(pow(warpP, 16.0), 0.1399, fs);
        warpP = mix(warpP, 0.5, fs);
        weftP = mix(weftP, 0.5, fr);
        float fsr = max(fs, fr);
        float twill = mix(step(mod(sid + rid, 4.0), 1.5), 0.5, fsr);

        vec3 warpCol = lmPal(0.05 + 0.55 * acr + 0.06 * 0.35, u);
        warpCol = accentize(warpCol, u.accent, 0.12);
        float warpE = 0.7 + 0.12 * u.level + 0.04 * bnd;

        // weft: dark dyed stripes with a diamond motif, hot where freshly laid
        float grp = floor(mod(rid, 10500.0) / 14.0);
        vec3 dye = lmPal(0.15 + 0.7 * hash11(grp * 1.37 + 0.5), u) * 0.012;
        float dm = abs(mod(s, 20.0) - 10.0) + abs(mod(r, 20.0) - 10.0);
        float motif = mix(1.0 - smoothstep(0.5, 1.0, abs(dm - 7.0)), 0.1, fsr);
        dye += lmPal(0.6 + 0.25 * hash11(grp * 3.1), u) * motif * (0.12 + 0.04 * u.level);
        float fresh = exp(-max(behind, 0.0) / 0.9);
        vec3 hot = lmPal(0.62 + 0.3 * fract(rid * 0.137), u) * (1.5 + 0.12 * u.level);
        vec3 weftCol = mix(dye, hot, fresh) * (0.35 + 0.65 * weftP);

        // woven: the warp glows where it floats over the weft; bare: free fibres
        vec3 warpGlow = warpCol * warpE * fibre;
        vec3 woven = mix(weftCol, warpGlow * 1.4 + warpCol * 0.02 * warpP, twill);
        vec3 bare = warpGlow * 1.8;
        vec3 cloth = mix(bare, woven, wovenM);

        // the shuttle lights a pool on the cloth and trails a hot weft line
        vec3 l = Ls - hp;
        float ld = dot(l, l);
        cloth += shCol * shPow * (0.03 + 0.2 * wovenM * weftP) * 1.0 / (1.0 + 3.0 * ld);
        float line = exp(-abs(hp.z - zS) * 16.0) * exp(-max((xS - hp.x) * dirS, 0.0) * 0.35)
                   * step(0.0, (xS - hp.x) * dirS + 0.2);
        cloth += mix(shCol, vec3(1.0), 0.25) * line * 1.5;
        cloth += shCol * exp(-abs(hp.z - zS) * 3.5) * exp(-abs(xS - hp.x) * 0.6) * 0.12 * shPow;
        vec3 lf = hp - Lf;
        cloth += mix(shCol, vec3(1.0), 0.3) * pick * 0.25 / (1.0 + 2.5 * dot(lf, lf));

        // satin sheen of the vanishing-point glow, rippled by the bass
        float ph = mod(u.time * 0.8, 6.2831853);
        float rip = sin((hp.z - z) * 1.1 - ph) * (0.12 + 0.04 * u.level) * rippleAmt * exp(-(hp.z - z) * 0.03);
        float graze = pow(1.0 - saturate(-rd.y), 6.0);
        vec3 sheenC = lmHaze(vec3(rd.x, -rd.y, rd.z), u, 0.0);
        cloth += sheenC * graze * (0.22 + 0.5 * max(rip, -0.4)) * (0.5 + 0.5 * wovenM * weftP);

        // beyond the selvedges: black lacquer floor mirroring the air and rails
        vec3 floorC = sheenC * graze * 0.9 + vec3(0.002, 0.002, 0.004);
        floorC += lmPal(0.2, u) * exp(-abs(ax - LM_HALF - 0.5) * 4.0) * 0.18;
        col = mix(floorC, cloth, onCloth);
    } else {
        col = vec3(0.0);
        tHit = 400.0;
    }

    // the heddle meters mirrored in the satin and the lacquer floor
    // (outside the branches: lmHeddles takes derivatives)
    vec3 rr = vec3(rd.x, -rd.y, rd.z);
    // only the side the ray travels toward can be reached from inside the loom
    float side = rd.x < 0.0 ? -1.0 : 1.0;
    vec3 mir = lmHeddles(hp, rr, side, 60.0, u, detail);
    float onFloor = step(t, 0.0) * step(tp, 1e3);
    float clothM = 1.0 - smoothstep(LM_HALF - 0.05, LM_HALF + 0.05, abs(hp.x));
    col += mir * onFloor * mix(0.45, 0.16, clothM) * (0.3 + 0.7 * pow(1.0 - saturate(-rd.y), 6.0));

    // distance fog toward the bright vanishing point
    float fog = 1.0 - exp(-tHit * 0.02);
    col = mix(col, lmHaze(rd, u, 1.0), fog);

    // heddle curtains on both sides, in front of whatever the ray hit
    col += lmHeddles(ro, rd, side, tHit, u, detail);

    // the shed: beyond the fell the raised half of the warp climbs away from
    // the shuttle line, a sheet of fibres seen from below
    float k = LM_SHED / LM_RISE;
    float den = rd.y - k * rd.z;
    float t1 = (k * (ro.z - zS) - ro.y) / (abs(den) > 1e-4 ? den : 1e-4);
    float t2 = (LM_SHED - ro.y) / max(rd.y, 1e-4);
    float zt1 = ro.z + rd.z * t1;
    float ts = zt1 < zS + LM_RISE ? t1 : t2;
    ts = clamp(ts, -1.0, 1e3);
    vec3 sp = ro + rd * ts;
    float ss = (sp.x + LM_HALF) / (2.0 * LM_HALF) * density * 0.5;
    float sfw = smoothstep(0.06, 0.3, fwidth(ss));
    float sf = mix(pow(0.5 - 0.5 * cos(6.2831853 * ss), 16.0), 0.1399, sfw);
    float sacr = abs((floor(ss) + 0.5) / (density * 0.5) * 2.0 - 1.0);
    float sb2 = bandAt(u, sacr);
    float sheetM = step(0.0, ts) * step(ts, tHit) * step(zS, sp.z) * (1.0 - smoothstep(LM_HALF - 0.3, LM_HALF, abs(sp.x)));
    vec3 sheetC = lmPal(0.05 + 0.55 * sacr + 0.06 * 0.35 + 0.5, u);
    float fellGlow = exp(-(sp.z - zS) * 0.25);
    col += sheetM * sheetC * sf * (0.28 + 0.08 * u.level + 0.02 * sb2 + 0.15 * fellGlow) * (1.0 - 0.7 * sfw) * exp(-max(ts, 0.0) * 0.022);

    // the shuttle's light scattering in the air along the ray
    vec3 wv = Ls - ro;
    float t0 = dot(wv, rd);
    float h = sqrt(max(dot(wv, wv) - t0 * t0, 1e-4));
    float scat = (atan((min(tHit, 400.0) - t0) / h) - atan(-t0 / h)) / h;
    col += shCol * shPow * min(scat, 30.0) * 0.008 * exp(-h * 0.7);
    // a thin anamorphic streak through the shuttle
    vec3 fw = normalize(ta - ro);
    vec3 rt = normalize(cross(fw, vec3(sin(roll), cos(roll), 0.0)));
    vec3 cu = cross(rt, fw);
    vec3 dS = normalize(wv);
    float vis = step(0.0, dot(dS, fw)) * step(length(wv), tHit + 0.5);
    float dv = dot(rd - dS, cu), dh = dot(rd - dS, rt);
    col += shCol * vis * shPow * exp(-abs(dv) * 500.0) * exp(-abs(dh) * 2.5) * 0.35;

    // the shuttle body: a white-hot spindle pointing the way it flies
    // and a comet wake of light streaming behind it, longer the faster it flies
    float dsg = dirS < 0.0 ? -1.0 : 1.0;
    float tb, hs;
    float ds = lmSegDist(ro, rd, Ls - vec3(1.1 * dsg, 0.0, 0.0), vec3(1.75 * dsg, 0.0, 0.0), tb, hs);
    float rad = 0.15 * (1.0 - (2.0 * hs - 1.0) * (2.0 * hs - 1.0));
    float pix = max(tb * 2.0 / max(u.resolution.y, 1.0), 1e-3);
    float body = (1.0 - smoothstep(rad - pix, rad + pix, ds)) * step(tb, tHit);
    float halo = 0.006 / (ds * ds + 0.012) * step(tb, tHit + 0.5);
    // a dark lacquered hull with a neon rim, hot metal tips and the glowing
    // bobbin of weft along its back
    float x01 = ds / max(rad, 1e-3);
    float rim = smoothstep(0.6, 1.0, x01);
    float tips = exp(-min(hs, 1.0 - hs) * 10.0);
    float bob = exp(-x01 * x01 * 3.0) * smoothstep(0.18, 0.3, hs) * smoothstep(0.82, 0.7, hs);
    vec3 hull = vec3(0.01, 0.008, 0.02) + shCol * (0.3 * (1.0 - x01) + 1.6 * rim)
              + mix(shCol, vec3(1.3), 0.35) * (tips * 2.6 + bob * 2.2);
    col = mix(col, hull * shPow, body);
    col += shCol * halo * shPow * 0.6;
    float tw, hw;
    float wl = 1.5 + 6.0 * abs(dirS);
    float dw = lmSegDist(ro, rd, Ls - vec3((1.1 + wl) * dsg, 0.05, 0.0), vec3(wl * dsg, 0.05, 0.0), tw, hw);
    col += mix(shCol, lmPal(0.5, u), 1.0 - hw) * exp(-dw * mix(30.0, 9.0, hw)) * hw * hw * step(tw, tHit) * 1.4 * shPow;

    return lmOffRed(max(col, vec3(0.0))); // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
