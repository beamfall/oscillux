// SPDX-License-Identifier: AGPL-3.0-only
// Volumetric light.
// A slow dolly down a dark, hazy hall. Low warm sunlight pours through a row
// of tall leaded windows along one wall, while cold light from round
// clerestory windows high on the other wall falls steeply the other way, so
// warm and cold shafts cross in the middle of the nave. The haze turns every
// pane into a solid shaft, broken by the shadows of two rows of fluted
// pillars and by clouds drifting past outside; the deep haze down the nave
// glows with the light it has gathered. Dust hangs in the air and only shows
// where it crosses a shaft. The polished stone floor catches the pools of
// light and mirrors the windows. Calm under loud music: each window brightens
// a little with the smoothed level plus its own band, a faint swell rolls
// down the row on the beat, the clerestory warms with the level, clouds drift
// slowly past and the dust glints softly. Beats never jump the light of the
// whole hall. The camera dollies slowly and steadily with no beat surges,
// never following the audio. Reds stay just off saturated red. The shafts are prefiltered by the march step, so they stay smooth
// instead of grainy at every detail level.
// param0 = Haze ; param1 = Beam Count (panes per window) ; param2 = Dust

const float VL_HW = 5.0;     // half width of the hall (walls at x = -+5)
const float VL_SP = 4.0;     // pillar and window spacing along the hall
const float VL_PX = 3.0;     // pillar rows at x = -+3
const float VL_PR = 0.36;    // pillar radius
const float VL_CEIL = 9.0;
const float VL_OY = 7.35;    // clerestory oculus centre height
const float VL_OR = 0.8;    // oculus radius

struct VLLight {
    vec3 sun;     // clear-glass sunlight
    vec3 paneA;   // three stained-glass colours
    vec3 paneB;
    vec3 paneC;
    vec3 cool;    // clerestory light
    vec4 eA;      // spectrum energy for windows 0..3 and 4..7 of each run of eight
    vec4 eB;
    vec3 L;       // direction the sunlight travels (+x)
    vec3 L2;      // direction the clerestory light travels (-x)
    float cols;
    float tw;
    float wave;
    float bass;
    float flare;  // clerestory beat flare
    float pen;    // penumbra growth per unit travelled
    vec3 avgT;    // mean glass tint, for shafts blurred past the pane size
};

// Keeps every red just off saturated red once tonemapped: green (for warm
// reds) or blue (for pink ones) rises to at least 0.3 of red, so no red area
// can strobe, while the hue barely moves.
float vlTone(float x) { return x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14); }
float vlToneInv(float y) {
    y = clamp(y, 0.0, 0.999);
    float a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y;
    return (-b + sqrt(b * b + 0.56 * a * y)) / (2.0 * a);
}
vec3 vlOffRed(vec3 c) {
    float r = vlTone(c.r), g = vlTone(c.g), b = vlTone(c.b);
    float need = 0.3 * r - g - b;
    if (need <= 0.0) return c;
    if (c.g > c.b) c.g = max(c.g, vlToneInv(g + need));
    else c.b = max(c.b, vlToneInv(b + need));
    return c;
}

// Interleaved gradient noise: a well spread per-pixel offset, so the march
// jitter reads as a fine, even dither instead of white grain.
float vlIGN(vec2 px) { return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715)))); }

// Tint of one pane: clear glass with deep stained panes in three colours;
// the tracery head of every window is stained.
vec3 vlPane(vec2 pid, float top, VLLight lt) {
    float hp = hash21(pid * vec2(1.31, 2.17) + 0.7);
    float hs = fract(hp * 7.13);
    vec3 st = hs < 0.4 ? lt.paneA : (hs < 0.75 ? lt.paneB : lt.paneC);
    return step(0.5, hp) + top > 0.5 ? st * (1.2 + 0.5 * hs) : lt.sun * (0.75 + 0.4 * hp);
}

// Window glass seen at q = (z, y) on the left wall: tint times light, zero
// on stone and lead. pen widens the edges: the sun's penumbra plus the
// march's own footprint, so the shafts are filtered rather than sampled.
vec3 vlWindow(vec2 q, float pen, VLLight lt) {
    float k = floor(q.x / VL_SP);
    float lz = q.x - (k + 0.5) * VL_SP;
    float hw = 0.66;
    float y0 = 1.8, y1 = 6.1;
    float ar = length(vec2(lz, max(q.y - y1, 0.0)));
    float inside = (1.0 - smoothstep(hw - 0.03 - pen, hw + pen, ar)) * smoothstep(y0 - pen, y0 + 0.03 + pen, q.y);
    if (inside <= 0.0) return vec3(0.0);
    // lead: vertical bars between panes, horizontal bars every 0.72
    float cw = 2.0 * hw / lt.cols;
    float cx = (lz + hw) / cw;
    float ry = (q.y - y0) / 0.72;
    float dv = abs(fract(cx) - 0.5) * cw;
    float dh = abs(fract(ry) - 0.5) * 0.72;
    float lead = smoothstep(0.0, 1.0, (0.5 * cw - dv) / (0.05 + pen)) * smoothstep(0.0, 1.0, (0.36 - dh) / (0.04 + pen));
    lead = mix(lead, 0.7, saturate(pen * 6.0 - 0.3));
    vec2 pid = vec2(mod(k, 61.0) * 7.0 + floor(cx), floor(ry));
    float top = step(y1 - 0.2, q.y);
    vec3 tint = vlPane(pid, top, lt);
    // a blurred sample straddles the panes beside it: blend in the nearer
    // neighbour in each direction, so the mosaic is filtered, not sampled
    vec2 fq = vec2(fract(cx), fract(ry));
    vec2 bw = vec2(pen / cw, pen / 0.72);
    if (bw.x + bw.y > 0.06) {
        vec2 dn = vec2(fq.x < 0.5 ? -1.0 : 1.0, fq.y < 0.5 ? -1.0 : 1.0);
        vec2 eb = min(fq, 1.0 - fq);
        vec2 wb = 0.5 * (1.0 - smoothstep(vec2(0.0), max(bw, vec2(1e-3)), eb));
        vec3 tx = vlPane(pid + vec2(dn.x, 0.0), top, lt);
        vec3 ty = vlPane(pid + vec2(0.0, dn.y), top, lt);
        vec3 txy = vlPane(pid + dn, top, lt);
        tint = mix(mix(tint, tx, wb.x), mix(ty, txy, wb.x), wb.y);
    }
    // hand-made glass is thicker at the edges of each pane: brighter centres
    vec2 pc = fq - 0.5;
    tint *= mix(1.25 - 1.3 * dot(pc, pc), 1.03, saturate(2.0 * (bw.x + bw.y)));
    // once the blur spans whole panes, use their mean so the pane mosaic
    // never aliases into grain inside a wide, far shaft
    tint = mix(tint, lt.avgT, saturate(pen * 0.7 - 1.1));
    // clouds drifting past outside
    float cx0 = q.x * 0.09 - lt.tw * 0.2;
    float cl = sin(cx0) * sin(cx0 * 0.61 + q.y * 0.11 + 1.3) + 0.4 * sin(cx0 * 1.7 - q.y * 0.07 + 0.4);
    cl = 0.15 + 0.85 * smoothstep(-0.75, 0.25, cl);
    float k8 = mod(k, 8.0);
    vec4 sel = step(abs(vec4(k8) - vec4(0.0, 1.0, 2.0, 3.0)), vec4(0.5));
    vec4 selB = step(abs(vec4(k8) - vec4(4.0, 5.0, 6.0, 7.0)), vec4(0.5));
    float e = dot(lt.eA, sel) + dot(lt.eB, selB);
    float sw = exp(-abs(k * VL_SP - lt.wave) * 0.15);
    float lvl = 0.8 + 0.15 * e + 0.12 * sw * lt.bass;
    return tint * (inside * lead * cl * lvl);
}

// Round clerestory window on the right wall at q = (z, y): a rose of eight
// petals in cold glass with a warm centre.
vec3 vlOculus(vec2 q, float pen, VLLight lt) {
    float k = floor(q.x / VL_SP + 0.5);
    vec2 o = vec2(q.x - k * VL_SP, q.y - VL_OY);
    float r = length(o);
    float inside = 1.0 - smoothstep(VL_OR - 0.04 - pen, VL_OR + pen, r);
    if (inside <= 0.0) return vec3(0.0);
    float a = atan2_(o.y, o.x + 1e-5);
    float spoke = abs(fract(a * 1.2732395 + 0.5) - 0.5) * r * 0.785;   // 8 spokes
    float ring = abs(r - 0.42);
    float tr = smoothstep(0.0, 1.0, (spoke - 0.025) / (0.035 + pen)) * smoothstep(0.0, 1.0, (ring - 0.02) / (0.03 + pen));
    tr = max(tr, 1.0 - smoothstep(0.17, 0.2 + pen, r));
    tr = mix(tr, 0.75, saturate(pen * 5.0 - 0.3));
    vec3 c = r < 0.42 ? mix(lt.paneC, lt.cool, 0.5) : lt.cool;
    float pet = fract(floor(a * 1.2732395 + 0.5) * 0.37 + k * 0.21);
    c = mix(c, lt.paneB, step(0.72, pet) * step(0.42, r));
    return c * (inside * tr * (0.4 + 0.9 * lt.flare));
}

// Pillar shadow on the way from the window to p for light travelling along
// L: 1 lit, 0 shadowed. blur widens the shadow edge.
float vlPillarRow(vec3 p, vec3 L, float xr, float blur) {
    float s = (p.x - xr) / L.x;
    if (s <= 0.0) return 1.0;
    float z = p.z - L.z * s;
    float dz = z - (floor(z / VL_SP + 0.5)) * VL_SP;
    float perp = abs(dz) * abs(L.x) * inversesqrt(L.x * L.x + L.z * L.z);
    return smoothstep(VL_PR - 0.02 - blur, VL_PR + 0.06 + blur, perp);
}

// Sunlight arriving at p through the left windows and past the pillars.
vec3 vlSunA(vec3 p, float blur, VLLight lt) {
    float s = (p.x + VL_HW) / lt.L.x;
    vec3 q = p - lt.L * s;
    vec3 c = vlWindow(q.zy, lt.pen * s + blur, lt);
    if (c.r + c.g + c.b <= 0.0) return c;
    return c * (vlPillarRow(p, lt.L, -VL_PX, blur) * vlPillarRow(p, lt.L, VL_PX, blur));
}

// Cold light arriving at p through the clerestory oculi on the right wall.
vec3 vlSunB(vec3 p, float blur, VLLight lt) {
    float s = (p.x - VL_HW) / lt.L2.x;
    vec3 q = p - lt.L2 * s;
    vec3 c = vlOculus(q.zy, lt.pen * 1.5 * s + blur, lt);
    if (c.r + c.g + c.b <= 0.0) return c;
    return c * (vlPillarRow(p, lt.L2, VL_PX, blur) * vlPillarRow(p, lt.L2, -VL_PX, blur));
}

// Smoke density: two noise lookups, sheared with height so it reads as 3D.
float vlHaze(vec3 p, float tw) {
    float a = vnoise(p.xz * vec2(0.7, 0.45) + vec2(tw * 0.07, -tw * 0.12));
    float b = vnoise(p.zy * vec2(0.5, 0.8) + vec2(-tw * 0.09, tw * 0.05) + 5.0);
    float s = a * b;
    return (0.25 + 3.0 * s * s) * exp(-p.y * 0.05);
}

// Front-most pillar the pixel touches, either row, and how much of the pixel
// it covers: 1 inside, falling to 0 across one pixel at the silhouette, so
// the edges are antialiased. skip leaves out one pillar (to find what lies
// behind a silhouette). 1e4 if none.
float vlPillars(vec3 ro, vec3 rd, float tmax, float pix, vec2 skip, out vec2 nrm, out vec2 cen, out float cov) {
    float best = tmax;
    nrm = vec2(0.0);
    cen = vec2(1e4);
    cov = 0.0;
    float k0 = floor(ro.z / VL_SP) - 1.0;
    float a = dot(rd.xz, rd.xz);
    if (a < 1e-6) return 1e4;
    float ia = 1.0 / a;
    for (int i = 0; i < 14; i++) {
        float cz = (k0 + float(i)) * VL_SP;
        if (rd.z > 0.0 && cz > ro.z + best * rd.z + 1.0) break;
        for (int sd = 0; sd < 2; sd++) {
            vec2 c0 = vec2(sd == 0 ? -VL_PX : VL_PX, cz);
            if (abs(c0.x - skip.x) + abs(c0.y - skip.y) < 0.01) continue;
            vec2 o = ro.xz - c0;
            float b = dot(o, rd.xz);
            float tc = -b * ia;                       // closest approach
            if (tc <= 0.0 || tc > best + VL_PR) continue;
            float oo = dot(o, o);
            float dd = sqrt(max(oo - b * b * ia, 0.0));
            float cv = saturate(0.5 + (VL_PR - dd) / max(tc * pix, 1e-4));
            if (cv <= 0.0) continue;
            float disc = b * b - a * (oo - VL_PR * VL_PR);
            float t = disc > 0.0 ? (-b - sqrt(disc)) * ia : tc;
            if (t > 0.0 && t < best) {
                best = t;
                cen = c0;
                cov = cv;
                vec2 e = o + rd.xz * t;
                nrm = e / max(length(e), 1e-4);
            }
        }
    }
    return best < tmax ? best : 1e4;
}

// Fluted stone pillar at hp (normal pn), sunlit where a shaft lands, rim lit
// by the glow.
vec3 vlPillarCol(vec3 hp, vec2 pn, vec3 rd, VLLight lt, vec3 amb) {
    vec3 L = lt.L;
    float ang = atan2_(pn.y, pn.x);
    float fl16 = sin(ang * 18.0);
    vec3 n = normalize(vec3(pn.x, 0.0, pn.y) + 0.18 * fl16 * vec3(-pn.y, 0.0, pn.x));
    vec3 s = vlSunA(hp + n * 0.03, 0.0, lt);
    vec3 s2 = vlSunB(hp + n * 0.03, 0.0, lt);
    float dif = saturate(dot(n, -L));
    float dif2 = saturate(dot(n, -lt.L2));
    float rim = pow(1.0 - saturate(dot(n, -rd)), 3.0);
    float ao = 0.6 + 0.4 * fl16 * fl16;
    // a carved band near the base and the capital
    float mold = exp(-pow((hp.y - 0.45) * 9.0, 2.0)) + exp(-pow((hp.y - 6.6) * 7.0, 2.0));
    // the haze's glow bounces softly onto the side facing the windows
    float bounce = 0.5 + 0.5 * dot(n, vec3(-1.0, 0.0, 0.0));
    return (s * dif * 0.4 + s2 * dif2 * 0.45) * ao + amb * (2.0 + 2.0 * mold) +
          lt.sun * 0.006 * bounce * ao +
          (lt.sun * 0.015 + lt.cool * 0.012) * rim;
}

// Surface colour at distance tHit: a pillar (normal pn) or the floor,
// walls or vault, whichever plane tHit matches.
vec3 vlShade(vec3 ro, vec3 rd, float tHit, bool isPillar, vec2 pn, vec4 tPl, float pix,
             VLLight lt, vec3 amb, float tw) {
    vec3 L = lt.L;
    float tF = tPl.x, tC = tPl.y, tL = tPl.z, tR = tPl.w;
    vec3 col = vec3(0.0);
    vec3 hp = ro + rd * tHit;
    float gw = max(0.004, tHit * pix);
    if (isPillar) {
        col = vlPillarCol(hp, pn, rd, lt, amb);
    } else if (tHit == tF) {
        // polished stone floor: marble tiles, light pools and a soft mirror of the windows
        vec2 cell = floor(hp.xz * 0.5);
        float chk = mod(cell.x + cell.y, 2.0);
        float tile = 0.55 + 0.25 * chk + 0.2 * hash21(mod(cell, 97.0));
        vec2 gl = abs(fract(hp.xz * 0.5) - 0.5);
        float grout = smoothstep(0.0, 0.03 + gw, 0.5 - max(gl.x, gl.y));
        float vein = smoothstep(0.55, 0.75, fbm(hp.xz * 0.9 + 3.0));
        tile *= grout * (0.85 + 0.3 * vein);
        vec3 s = vlSunA(hp, 0.0, lt) + vlSunB(hp, 0.0, lt);
        col = s * (0.13 * tile) + amb * tile;
        vec3 rr = vec3(rd.x, -rd.y, rd.z);
        float rough = 0.35 + 0.65 * vnoise(hp.xz * 1.7);
        float fres = 0.04 + 0.96 * pow(1.0 - saturate(-rd.y), 5.0);
        if (rr.x < -1e-3) {
            float tw2 = (-VL_HW - hp.x) / rr.x;
            vec3 wp = hp + rr * tw2;
            vec3 g = vlWindow(wp.zy + vec2(0.0, 0.18 * rough), 0.12, lt);
            col += g * 2.0 * fres * rough * grout * exp(-tw2 * 0.06);
        } else if (rr.x > 1e-3) {
            float tw2 = (VL_HW - hp.x) / rr.x;
            vec3 wp = hp + rr * tw2;
            vec3 g = vlOculus(wp.zy + vec2(0.0, 0.2 * rough), 0.12, lt);
            col += g * 2.0 * fres * rough * grout * exp(-tw2 * 0.06);
        }
    } else if (tHit == tL) {
        // window wall: glowing glass, the sun glaring through clear panes,
        // stone around the frames lit by the glass's own glow
        vec3 g = vlWindow(hp.zy, gw, lt);
        float stone = 0.6 + 0.4 * vnoise(hp.zy * vec2(2.0, 3.0));
        float rip = 0.6 + 0.8 * vnoise(hp.zy * vec2(5.0, 3.0) + vec2(0.0, tw * 0.02));
        rip *= 0.85 + 0.3 * vnoise(hp.zy * vec2(23.0, 17.0));
        float glare = pow(saturate(-dot(rd, L)), 12.0);
        float lz = hp.z - (floor(hp.z / VL_SP) + 0.5) * VL_SP;
        float halo = exp(-max(abs(lz) - 0.66, 0.0) * 3.0) * smoothstep(1.2, 2.2, hp.y) * smoothstep(7.4, 5.8, hp.y);
        col = g * (1.5 * rip + 6.0 * glare) + amb * stone * 1.5 + lt.sun * halo * stone * 0.02;
    } else if (tHit == tR) {
        // far wall: the oculi glowing cold, shaded windows below, and the
        // warm shafts where they land
        vec3 s = vlSunA(hp, 0.0, lt);
        float stone = 0.7 + 0.3 * vnoise(hp.zy * vec2(1.5, 2.5));
        vec3 g = vlWindow(vec2(hp.z + 1.3, hp.y), gw, lt);
        float rip = 0.5 + 0.8 * vnoise(hp.zy * vec2(4.0, 2.6));
        vec3 oc = vlOculus(hp.zy, gw, lt);
        float glare2 = pow(saturate(-dot(rd, lt.L2)), 10.0);
        float oz = hp.z - floor(hp.z / VL_SP + 0.5) * VL_SP;
        float halo = exp(-max(length(vec2(oz, hp.y - VL_OY)) - VL_OR, 0.0) * 2.5);
        col = s * 0.1 * stone + amb * stone + g * lt.cool * 0.03 * rip +
              oc * (2.0 * rip + 5.0 * glare2) + lt.cool * halo * stone * 0.03 * (1.0 + lt.flare);
    } else if (tHit == tC) {
        // ribbed vault catching a little of the light below
        float beam = smoothstep(0.3, 0.05, abs(fract(hp.z / VL_SP) - 0.5) * VL_SP);
        float side = smoothstep(0.0, 4.0, abs(hp.x));
        col = amb * (0.6 + beam) * 1.5 + (lt.sun * 0.012 + lt.cool * 0.01) * beam * side;
    }
    return col;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float haze = mix(0.45, 1.6, u.param0);
    float dustAmt = mix(0.2, 1.4, u.param2);
    float tw = mod(u.time, 600.0);

    // ---- camera: slow dolly down the nave, looking up toward the windows ----
    vec2 fl = osFlight(u, 0.3, -0.12);
    float rush = saturate((fl.y - 1.0) / 3.5);
    // the gaze wanders slowly between the windows, the nave and the vault
    float gz = sin(tw * 0.031) + 0.5 * sin(tw * 0.017 + 2.0);
    vec3 ro = vec3(0.7 + 0.7 * sin(tw * 0.023), 1.7 + 0.35 * sin(tw * 0.047 + 1.0), fl.x);
    vec3 ta = ro + vec3(-0.15 + 0.45 * gz, 0.2 + 0.14 * sin(tw * 0.026 + 0.5), 1.0);
    float roll = osBank(u, 0.035);
    vec3 rd = osCamera(ro, ta, roll, 1.2, p);
    float pix = 2.0 / (u.resolution.y * 1.2);

    VLLight lt;
    float boost = 1.0;
    lt.sun = palVisual(0.22, u) * vec3(1.0, 0.95, 0.85) * 1.3 * boost;
    // the stained glass shifts hue as the flight builds and bursts
    lt.paneA = palVisual(0.04 + 0.08 * rush, u) * boost;
    lt.paneB = palVisual(0.62 - 0.1 * rush, u) * boost;
    lt.paneC = palVisual(0.86 - 0.06 * rush, u) * boost;
    lt.cool = palVisual(0.84 + 0.05 * sin(tw * 0.03) - 0.08 * rush, u) * 1.1;
    float lev = saturate(u.level);
    lt.eA = 0.6 * lev + 0.4 * vec4(bandAt(u, 0.04), bandAt(u, 0.30), bandAt(u, 0.12), bandAt(u, 0.46));
    lt.eB = 0.6 * lev + 0.4 * vec4(bandAt(u, 0.21), bandAt(u, 0.55), bandAt(u, 0.08), bandAt(u, 0.38));
    // sunlight direction (travel), swinging slowly over minutes
    lt.L = normalize(vec3(0.7, -0.6 + 0.05 * sin(tw * 0.011), -0.15 + 0.2 * sin(tw * 0.013)));
    lt.L2 = normalize(vec3(-0.55, -0.78, 0.22 + 0.12 * sin(tw * 0.017 + 1.0)));
    lt.cols = floor(mix(2.0, 4.0, u.param1) + 0.5);
    lt.tw = tw;
    lt.wave = ro.z - 6.0 + saturate(u.beatPhase) * 40.0;
    lt.bass = 0.15 + 0.15 * lev;
    lt.flare = 0.12 * lev + 0.05 * bandAt(u, 0.7);
    lt.pen = 0.012;
    lt.avgT = (lt.sun * 0.49 + (lt.paneA * 0.4 + lt.paneB * 0.35 + lt.paneC * 0.25) * 0.75) * 1.03;
    vec3 L = lt.L;
    vec3 amb = palVisual(0.97, u) * 0.012;

    // ---- geometry: floor, ceiling, walls, pillars ----
    float tF = rd.y < -1e-4 ? -ro.y / rd.y : 1e4;
    float tC = rd.y > 1e-4 ? (VL_CEIL - ro.y) / rd.y : 1e4;
    float tL = rd.x < -1e-4 ? (-VL_HW - ro.x) / rd.x : 1e4;
    float tR = rd.x > 1e-4 ? (VL_HW - ro.x) / rd.x : 1e4;
    float tmax = min(min(tF, tC), min(min(tL, tR), 70.0));

    vec4 tPl = vec4(tF, tC, tL, tR);
    vec2 pn, pc;
    float pcov;
    float tP = vlPillars(ro, rd, tmax, pix, vec2(1e4), pn, pc, pcov);
    bool edge = tP < tmax && pcov < 1.0;
    // the surface seen behind a pillar silhouette, or the pillar or plane hit
    float tEnd = min(tP, tmax);
    bool bgPillar = tP < tmax && !edge;
    vec2 pnB = pn;
    if (edge) {
        vec2 pcB;
        float covB;
        float tB = vlPillars(ro, rd, tmax, pix, pc, pnB, pcB, covB);
        bgPillar = tB < tmax && covB >= 0.5;
        tEnd = bgPillar ? tB : tmax;
    }
    vec3 col = vlShade(ro, rd, tEnd, bgPillar, pnB, tPl, pix, lt, amb, tw);
    vec3 colP = vec3(0.0);
    if (edge) colP = vlPillarCol(ro + rd * tP, pn, rd, lt, amb);
    float tHit = tEnd;
    // ---- volumetric march through the haze ----
    // The window footprint of one march step is prefiltered into the shaft
    // edges: q moves by dq per unit t, so each sample blurs by its own span.
    float sx = rd.x / L.x;
    float dq1 = length((rd - L * sx).zy);
    float sx2 = rd.x / lt.L2.x;
    float dq2 = length((rd - lt.L2 * sx2).zy);
    float span = min(tHit, 26.0);
    // short rays (a near wall or the floor) need fewer samples for the same
    // spacing, so the budget goes to the long looks down the nave
    int steps = int(mix(18.0, 46.0, detail) * (0.45 + 0.55 * saturate(span / 18.0)) + 0.5);
    // the dither pattern steps on each frame, so the trail feedback averages
    // it into smooth shafts
    float jit = 0.5 + 0.5 * (fract(vlIGN(floor(uv * u.resolution)) + 0.618034 * mod(floor(u.time * 60.0), 977.0)) - 0.5);
    float g = 0.55;
    float cth = -dot(rd, L);
    float ph = (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cth, 1.5);
    ph = 0.35 + 0.3 * ph;
    float cth2 = -dot(rd, lt.L2);
    float ph2 = (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cth2, 1.5);
    ph2 = 0.35 + 0.3 * ph2;
    vec3 scat = vec3(0.0);
    float T = 1.0;
    float sig = 0.035 * haze;
    float fs = float(steps);
    float bk = mix(1.0, 2.0, detail);
    float d = 0.0;
    float tFront = edge ? tP : 1e9;
    vec3 scatP = vec3(0.0);
    float TP = 1.0;
    for (int i = 0; i < 56; i++) {
        if (i >= steps) break;
        // samples crowd near the camera, where shafts are widest on screen
        float f = (float(i) + jit) / fs;
        float t = span * f * sqrt(f);
        float fn = f + 1.0 / fs;
        float dt = span * fn * sqrt(fn) - t;
        vec3 sp = ro + rd * t;
        // the smoke is low frequency: one lookup serves two samples
        if (i == (i / 2) * 2) d = vlHaze(ro + rd * (t + dt), tw) * haze;
        vec3 sa = vlSunA(sp, dt * dq1 * bk, lt);
        vec3 sb = vlSunB(sp, dt * dq2 * bk, lt);
        // haze right at the lens is faded out, so a shaft through the camera
        // never veils the frame
        float near = smoothstep(0.4, 2.8, t);
        scat += T * ((sa * ph * 0.42 + sb * ph2 * 0.45) * near + amb * 0.6) * d * dt;
        T *= exp(-sig * d * dt);
        if (t < tFront) { scatP = scat; TP = T; }
    }
    // beyond the march: haze glowing with the light it has gathered down
    // the nave, so the far end is luminous rather than black
    float rest = max(tHit - span, 0.0);
    float Tr = exp(-sig * 0.6 * rest);
    vec3 farGlow = (lt.sun * 0.045 * 1.0 + lt.cool * 0.012 * (1.0 + lt.flare)) * haze + amb * 3.0;
    col = col * T * Tr + scat + farGlow * (1.0 - Tr) * T;
    if (edge) {
        float TrP = exp(-sig * 0.6 * max(tP - span, 0.0));
        col = mix(col, colP * TP * TrP + scatP + farGlow * (1.0 - TrP) * TP, pcov);
        tHit = pcov >= 0.5 ? tP : tHit;
    }

    // ---- dust: motes on planes across the hall, lit only in the shafts ----
    int planes = osSteps(6.0, 22.0, detail);
    if (rd.z > 0.05) {
        float dz = 0.45;
        float j0 = floor(ro.z / dz) + 2.0;
        float focus = 3.5;
        float keep = 0.06 + 0.2 * dustAmt;
        for (int i = 0; i < 22; i++) {
            if (i >= planes) break;
            float pz = (j0 + float(i)) * dz;
            float t = (pz - ro.z) / rd.z;
            if (t > tHit) break;
            if (t < 0.9) continue;
            vec3 q = ro + rd * t;
            float jid = mod(j0 + float(i), 257.0);
            vec2 drift = vec2(0.12 * sin(tw * 0.07 + jid), -0.025 * tw);
            vec2 gq = (q.xy - drift) / 0.42;
            vec2 c = floor(gq);
            vec2 h = hash22(mod(c, 251.0) + jid * vec2(0.37, 1.91));
            if (h.x > keep) continue;
            vec2 wob = 0.05 * vec2(sin(tw * (0.3 + h.y) + h.x * 20.0), cos(tw * (0.23 + h.x) + h.y * 17.0));
            vec2 mp = (c + 0.3 + 0.4 * hash22(c + jid)) * 0.42 + drift + wob;
            vec3 mpos = vec3(mp, pz);
            vec3 s = vlSunA(mpos, 0.0, lt) * ph + vlSunB(mpos, 0.0, lt) * ph2;
            if (s.r + s.g + s.b <= 0.0) continue;
            float r = 0.003 + 0.003 * h.y;
            float coc = min(0.03 * abs(t - focus) / max(t, 0.5), 0.05);
            float w = max(max(r, t * pix * 0.8), coc);
            float dd = length(q.xy - mp);
            float k = exp(-dd * dd / (w * w)) * (r * r) / (w * w);
            float tws = 0.5 + 0.5 * sin(tw * (0.7 + 1.0 * h.y) + h.x * 90.0);
            vec3 mc = peakWhite(s, 0.08 + 0.1 * lev * tws);
            float br = 0.25 + 1.5 * h.y * h.y;
            col += mc * k * br * (0.7 + 0.3 * lev * tws) * 34.0;
        }
    }
    return vlOffRed(max(col, vec3(0.0)));
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
