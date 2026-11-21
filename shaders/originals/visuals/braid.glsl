// SPDX-License-Identifier: AGPL-3.0-only
// Braid.
// A flight down the inside of a braided sleeve: 24 satin cords, twelve
// winding each way, weave over and under one another around the camera, and
// light streams past through the gaps in the weave. Each cord carries a
// luminous fibre that glows with the music's level and brightens a little
// with its band (bass, mid or treble). One family is warm (red, gold,
// magenta), the other its cool complement (cyan, ice blue, sea green), and
// the two slowly trade the lead every four beats. Packets of light run along
// the fibres, every beat sends a soft cyan hoop racing ahead down the tunnel,
// a few crossings glint, and the far weave sinks into black. The camera glides
// at a near-steady pace (the shared 32-beat profile barely moves it) and leans
// only into the sleeve's own curves; audio drives the light, never the camera,
// and beats never jump the light over large areas. Reds are kept just off
// saturated red.
// param0 = Twist ; param1 = Core Heat ; param2 = Sparks

const float BD_TAU = 6.2831853;
const float BD_SP = 0.5235988;    // 2 pi / 12 cords per family
const float BD_R = 2.0;          // sleeve radius

// Keeps every red just off saturated red once tonemapped: green (for warm
// reds) or blue (for pink ones) rises to at least 0.3 of red, so no red area
// can strobe, while the hue barely moves.
float bdTone(float x) { return x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14); }
float bdToneInv(float y) {
    y = clamp(y, 0.0, 0.999);
    float a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y;
    return (-b + sqrt(b * b + 0.56 * a * y)) / (2.0 * a);
}
vec3 bdOffRed(vec3 c) {
    float r = bdTone(c.r), g = bdTone(c.g), b = bdTone(c.b);
    float need = 0.3 * r - g - b;
    if (need <= 0.0) return c;
    if (c.g > c.b) c.g = max(c.g, bdToneInv(g + need));
    else c.b = max(c.b, bdToneInv(b + need));
    return c;
}

vec2 bdPath(float z) {
    return vec2(1.7 * sin(z * 0.043) + 0.9 * sin(z * 0.021 + 1.0), 1.2 * sin(z * 0.031 + 2.0));
}

// One braided shell around the path. Returns (distance, lane 0..5: group
// 0..2 plus 3 for the second family, coordinate along the cord, angle around
// the cord) for the nearest cord.
vec4 bdShell(vec2 q, float z, float R, float k, float spin, float rc, float h) {
    float r = length(q);
    float a = atan2_(q.y, q.x) + spin;
    float kz = mod(k * z, BD_TAU);
    float uu = a - kz;
    float vv = a + kz;
    float iu = floor(uu / BD_SP + 0.5);
    float iv = floor(vv / BD_SP + 0.5);
    float slope = inversesqrt(1.0 + k * k * R * R);
    // plain weave: at crossing (i, j) the + cord is outside when i + j is even
    float su = 1.0 - 2.0 * mod(iu, 2.0);
    float sv = 1.0 - 2.0 * mod(iv, 2.0);
    vec2 eu = vec2((uu - iu * BD_SP) * r * slope, r - (R + h * su * cos(6.0 * vv)));
    vec2 ev = vec2((vv - iv * BD_SP) * r * slope, r - (R - h * sv * cos(6.0 * uu)));
    float du = length(eu) - rc;
    float dv = length(ev) - rc;
    if (du < dv) return vec4(du, mod(iu, 3.0), vv, atan2_(eu.y, eu.x));
    return vec4(dv, 3.0 + mod(iv, 3.0), uu, atan2_(ev.y, ev.x));
}

vec4 bdMap(vec3 p, float k, float spin) {
    return bdShell(p.xy - bdPath(p.z), p.z, BD_R, k, spin, 0.115, 0.115);
}

vec3 bdNormal(vec3 p, float k, float spin) {
    vec2 e = vec2(0.004, -0.004);
    return normalize(e.xyy * bdMap(p + e.xyy, k, spin).x + e.yyx * bdMap(p + e.yyx, k, spin).x +
                     e.yxy * bdMap(p + e.yxy, k, spin).x + e.xxx * bdMap(p + e.xxx, k, spin).x);
}

// The palette read once per pixel at its five stops and blended here; the
// library read walks the whole stop table on every call.
struct BdPalette { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

BdPalette bdPalLoad(VisualUniforms u) {
    BdPalette P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 bdPal(BdPalette P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float BD_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 bdFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * BD_RUN[32] + BD_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

vec3 bdGroupColor(float g, VisualUniforms u, BdPalette P) {
    if (g < 0.5) return mix(bdPal(P, 0.15), bdPal(P, 0.05), 0.65 + 0.05 * u.bass);
    if (g < 1.5) return bdPal(P, 0.435);
    return peakWhite(bdPal(P, 0.72 + 0.10 * u.spectralCentroid), u.treble * u.onset * 0.14);
}

float bdGroupLevel(float g, VisualUniforms u) {
    if (g < 0.5) return saturate(0.6 * u.level + 0.35 * bandRange(u, 0, 6));
    if (g < 1.5) return saturate(0.6 * u.level + 0.35 * bandRange(u, 10, 28));
    return saturate(0.6 * u.level + 0.35 * bandRange(u, 30, 60) + 0.05 * u.onset);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);

    float k = mix(0.1, 0.3, u.param0);
    float heat = mix(0.6, 1.8, u.param1);
    float sparkAmt = mix(0.2, 1.6, u.param2);

    vec2 fl = bdFlight(u, 0.7, -0.25);
    BdPalette P = bdPalLoad(u);
    float z = fl.x;
    float rush = saturate((fl.y - 1.0) / 3.5);
    float lull = saturate(1.0 - fl.y);
    float spin = mod(u.time * 0.03 + z * 0.012, BD_TAU);
    // the two cord families trade the lead every four beats: the warm family
    // glows on one bar, the cool family on the next
    float bar = mod(u.beatCount, 256.0) + saturate(u.beatPhase);
    float lead = 0.5 + 0.5 * cos(bar * 0.7853982);
    float cyc = fract(bar / 32.0);
    // the hue walks over the 32-beat cycle and leans hot through the bursts
    float hs = 0.09 * sin(cyc * BD_TAU) - 0.02 * rush;
    // every bar a surge of charge runs up the sleeve from the far end toward
    // the camera, lighting each cord as it passes, harder on a burst
    float barPh = fract(bar / 4.0);
    float sRun = saturate(barPh * 1.6);
    float surgeZ = z - 1.0 + 30.0 * (1.0 - sRun * (2.0 - sRun));
    float surgeAmp = smoothstep(0.0, 0.06, barPh) * (1.0 - smoothstep(0.5, 0.78, barPh)) * (0.5 + 0.2 * rush + 0.2 * u.level);

    vec3 ro = vec3(bdPath(z), z);
    vec3 ta = vec3(bdPath(z + 6.0), z + 6.0);
    float curve = bdPath(z + 9.0).x - 2.0 * bdPath(z + 4.5).x + bdPath(z).x;
    float roll = -0.35 * curve;
    float fov = 0.9 - 0.03 * rush + 0.02 * lull;
    vec3 rd = osCamera(ro, ta, roll, fov, p);

    vec3 cG0 = bdGroupColor(0.0, u, P), cG1 = bdGroupColor(1.0, u, P), cG2 = bdGroupColor(2.0, u, P);
    // the second family is the cool complement: cyan, ice blue and sea green
    vec3 cC0 = mix(P.c3, P.c4, 0.95);
    vec3 cC1 = cC0 * vec3(0.35, 0.75, 1.35), cC2 = cC0 * vec3(0.25, 1.1, 0.75);
    float wA = 0.45 + 0.55 * lead, wB = 1.0 - 0.55 * lead;
    float l0 = bdGroupLevel(0.0, u), l1 = bdGroupLevel(1.0, u), l2 = bdGroupLevel(2.0, u);

    // the light at the end of the tunnel
    vec3 far = vec3(bdPath(z + 60.0), z + 60.0);
    vec3 farDir = normalize(far - ro);
    vec3 fogCol = bdPal(P, 0.8 + hs) * 0.004;
    vec3 endCol = peakWhite(bdPal(P, 0.55 + hs + 0.08 * u.spectralCentroid), saturate(u.onset * 0.04 + u.bass * 0.03));

    // beat ring racing ahead of the camera
    float bp = saturate(u.beatPhase);
    // it is born a few units ahead and fades in, so it never washes the whole view
    float ringZ = z + 5.0 + 22.0 * (1.0 - (1.0 - bp) * (1.0 - bp));
    float ringAmp = smoothstep(0.0, 0.15, bp) * (1.0 - bp) * (0.3 + 0.1 * u.level);
    vec3 ringCol = mix(cC0, vec3(1.0), 0.2);
    vec3 surgeCol = peakWhite(mix(cC0, cG1, lead), 0.25);

    // the far weave is lost in fog, so the lower levels stop sooner
    int steps = osSteps(26.0, 90.0, detail);
    float t = 0.05;
    float tmax = mix(26.0, 40.0, detail);
    vec4 hit = vec4(0.0);
    int state = 0;            // 0 down the tunnel, 1 hit a cord, 2 out through a gap
    vec3 glow = vec3(0.0);
    float glowB = 0.0, glowR = 0.0;
    for (int i = 0; i < 96; i++) {
        if (i >= steps) break;
        vec3 pos = ro + rd * t;
        vec2 q = pos.xy - bdPath(pos.z);
        if (dot(q, q) > 6.3) { state = 2; break; }   // past the sleeve (r > ~2.5)
        vec4 m = bdShell(q, pos.z, BD_R, k, spin, 0.115, 0.115);
        float g = mod(m.y, 3.0);
        float lvl = g < 0.5 ? l0 : (g < 1.5 ? l1 : l2);
        vec3 gc = g < 0.5 ? cG0 : (g < 1.5 ? cG1 : cG2);
        float ring = exp(-(pos.z - ringZ) * (pos.z - ringZ) * 0.6) * ringAmp;
        float w = exp(-max(m.x, 0.0) * 14.0 - t * 0.06);
        if (m.y > 2.5) glowB += (0.25 + 0.45 * lvl) * w; else glow += gc * (0.25 + 0.45 * lvl) * w;
        glowR += ring * w;
        if (m.x < 0.0015 * t) { hit = m; state = 1; break; }
        t += m.x * (t > 8.0 ? 0.9 : 0.8);
        if (t > tmax) break;
    }
    glow = (glow * wA + cC0 * glowB * wB + ringCol * 1.2 * glowR) * 0.005 * heat;

    float endGlow = pow(saturate(dot(rd, farDir)), 24.0);
    vec3 bg = fogCol + endCol * (0.12 * endGlow + 1.2 * pow(saturate(dot(rd, farDir)), 400.0));
    vec3 col = bg;
    if (state == 2) {
        // light behind the weave: the spectrum laid round the sleeve, mirrored
        // left and right, drawn out into streaks that stream past
        vec3 pos = ro + rd * t;
        vec2 q = pos.xy - bdPath(pos.z);
        float f = abs(atan2_(q.y, q.x)) / 3.1415927;
        float lv = bandAt(u, 0.04 + 0.9 * f);
        float sz = mod(pos.z * 0.05, 400.0);
        float streak = fbm(vec2(f * 16.0, sz)) * (0.6 + 0.4 * vnoise(vec2(f * 40.0, sz * 3.0)));
        streak = smoothstep(0.45, 0.85, streak);
        streak *= streak;
        vec3 lc = bdPal(P, 0.55 + 0.45 * f + 0.06 * u.spectralCentroid + hs);
        // the outer light is never quite dark: a dim coloured haze with the
        // streaks running through it, so the gaps glow instead of punching holes
        col = lc * (0.0025 + 0.004 * u.level + streak * (0.2 + 0.3 * u.level + 0.3 * lv * lv)) * heat;
        // (the surge lights only the cords, never the open gaps)
        float ring = exp(-(pos.z - ringZ) * (pos.z - ringZ) * 0.4) * ringAmp;
        col += ringCol * ring * 0.25;
        col = mix(col, bg, 1.0 - exp(-t * 0.11));
    } else if (state == 1) {
        vec3 pos = ro + rd * t;
        vec3 n = bdNormal(pos, k, spin);
        float lane = hit.y;
        float g = mod(lane, 3.0);
        bool famB = lane > 2.5;
        vec3 gc = famB ? (g < 0.5 ? cC0 : (g < 1.5 ? cC1 : cC2)) : (g < 0.5 ? cG0 : (g < 1.5 ? cG1 : cG2));
        float lvl = g < 0.5 ? l0 : (g < 1.5 ? l1 : l2);
        float wF = famB ? wB : wA;

        // one luminous fibre wound round each cord
        float along = hit.z * 2.0 * BD_R;
        float fib = 0.5 + 0.5 * cos(hit.w + along * 2.5);
        float fibre = smoothstep(0.9, 0.99, fib);

        // light packets running along each fibre
        // light packets running along each fibre: a sharp head and a tail
        float pk = fract(along * 0.12 - mod(u.time, 600.0) * (0.25 + 0.1 * rush) + hash11(lane * 7.3 + 1.0));
        float packet = (exp(-pk * 14.0) + 0.25 * exp(-pk * 4.0)) * (0.35 + 0.15 * u.flux + 0.35 * lvl);

        float ring = exp(-(pos.z - ringZ) * (pos.z - ringZ) * 0.6) * ringAmp;
        float sg = exp(-(pos.z - surgeZ) * (pos.z - surgeZ) * 0.15) * surgeAmp;

        // glossy dark satin: base, coloured sheen at grazing angles, a tight
        // highlight from the headlight, and back-light from the gaps behind
        vec3 v = -rd;
        float nv = saturate(dot(n, v));
        float spec = pow(saturate(dot(n, normalize(v + 0.3 * farDir))), 70.0);
        float sheen = pow(1.0 - nv, 3.0);
        vec2 qq = pos.xy - bdPath(pos.z);
        float outward = dot(n.xy, qq) / max(length(qq), 1e-3);
        float back = saturate(outward) * (1.0 - nv);
        float ao = saturate(0.3 + 0.7 * bdMap(pos + n * 0.1, k, spin).x / 0.1);

        float f = abs(atan2_(qq.y, qq.x)) / 3.1415927;
        vec3 lc = bdPal(P, 0.55 + 0.45 * f + 0.06 * u.spectralCentroid + hs);
        float lv = bandAt(u, 0.04 + 0.9 * f);

        col = vec3(0.004, 0.003, 0.006) * (0.5 + nv) * ao;
        col += gc * sheen * 0.12 * ao;
        col += mix(vec3(1.0), gc, 0.65) * spec * 0.4 * ao;
        col += lc * back * (0.14 + 0.08 * u.level + 0.1 * lv * lv) * heat;
        float emit = fibre * (0.55 + 0.6 * lvl + 1.0 * packet) * wF * exp(-t * 0.05);
        // the colour of the packet heads is pushed white-hot, the tails stay coloured
        col += mix(gc, peakWhite(gc, 0.3), saturate(packet * 0.5)) * emit * heat;
        // the bar's surge lights the satin and the fibre as it runs past
        col += surgeCol * sg * (0.05 * sheen + 1.0 * fibre) * ao * exp(-t * 0.05);
        // the beat ring lights the whole cord as it passes
        col += ringCol * ring * (0.3 + 1.0 * fibre) * (0.4 + 0.6 * nv);
        // crossings glint on the beat
        float glint = pow(abs(cos(6.0 * hit.z)), 40.0) * nv;
        float gate = (phasePulse(u, 0.0, 0.12) * (0.3 + 0.3 * u.beat) + 0.15 * u.onset) * sparkAmt;
        float pick = step(0.85, hash21(vec2(floor(hit.z / BD_SP + 0.5) + 13.0 * lane, mod(floor(u.beatCount), 64.0))));
        col += peakWhite(endCol, 0.5) * glint * gate * pick * 0.7;

        col = mix(col, bg, 1.0 - exp(-t * 0.11));
    }
    col += glow;
    return bdOffRed(max(col, vec3(0.0))); // LINEAR HDR — post chain tonemaps
}
