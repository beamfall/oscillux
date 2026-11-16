// SPDX-License-Identifier: AGPL-3.0-only
// Ripple.
// High-speed drop photography, in motion. A macro camera skims a black
// mirror of liquid in a studio: two coloured gels light the backdrop, a
// softbox hangs overhead and a string of out-of-focus lamps glows along the
// horizon, one spectrum band each. A drop falls through the frame before every
// beat and strikes on it: a crown splashes up, a Worthington jet climbs out of
// the crater, necks and throws a bead into the air, and the rings spread out
// across the surface, bending every reflection into bands of warm and cool.
// Every eight beats the rig changes its pattern: a single drop, twin drops
// whose rings interfere, or a line of drops walking across the frame. A small
// strobe behind the splash fires on each beat, warm and cool in turn. The camera
// creeps forward on the shared 32-beat speed profile and banks gently; audio
// drives the light only, never the camera.
// param0 = Ring Width ; param1 = Expansion ; param2 = Persistence

const float RP_AHEAD = 2.6;   // how far ahead of the camera each drop lands
const float RP_RUNK = 0.30;   // world units per beat of travel at cruise

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float RP_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);

// Beats' worth of travel at the start of beat m.
float rpBeatRun(float m) {
    return floor(m / 32.0) * RP_RUN[32] + RP_RUN[int(mod(m, 32.0))];
}

// x: beats' worth of travel now, y: current speed.
vec2 rpFlight(VisualUniforms u) {
    float n = floor(u.beatCount);
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    return vec2(rpBeatRun(n) + v0 * ph + 0.5 * (v1 - v0) * ph * ph, mix(v0, v1, ph));
}

float rpPathX(float z) { return 0.5 * sin(z * 0.23) + 0.25 * sin(z * 0.51 + 1.3); }

// The palette read once per pixel at its five stops and blended locally.
struct RpPalette { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

RpPalette rpPalLoad(VisualUniforms u) {
    RpPalette P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 rpPal(RpPalette P, float t) {
    t = saturate(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// A gel colour: peak-normalised and pushed a little more saturated.
vec3 rpVivid(vec3 c, float s) {
    c = c / max(max(c.r, max(c.g, c.b)), 0.05);
    return max(mix(vec3(luma(c)), c, s), 0.0);
}

// The studio's lights, the same for the whole frame.
struct RpLight {
    vec3 warm; vec3 cool;   // the two gels
    vec3 soft;              // the overhead softbox
    vec3 acc;               // this beat's strobe colour
    float accA;             // its level
    float gel;              // gel level
    float gx;               // how far apart the gel pools sit
    vec3 b0; vec3 b1;       // six cached spectrum bands
};

float rpBand(RpLight L, float j) {
    float i = mod(j, 6.0);
    return i < 3.0 ? L.b0[int(i)] : L.b1[int(i - 3.0)];
}

// The studio seen along d (directions only: the backdrop is far away).
vec3 rpEnv(vec3 d, RpLight L) {
    float e = d.y;
    float ax = atan(d.x, max(d.z, 0.05));
    vec3 col = vec3(0.003, 0.003, 0.004) * smoothstep(-0.05, 0.2, e);
    // the two gel pools on the backdrop, kept apart so they never mix to grey
    vec2 gA = vec2(ax + L.gx, e - 0.2);
    vec2 gB = vec2(ax - L.gx, e - 0.2);
    col += L.warm * exp(-dot(gA * gA, vec2(16.0, 48.0))) * L.gel;
    col += L.cool * exp(-dot(gB * gB, vec2(16.0, 48.0))) * L.gel;
    // a string of out-of-focus lamps along the horizon, one band each
    float bx = (ax + 1.3) / 0.2;
    float bj = floor(bx);
    if (bj >= 0.0 && bj <= 12.0) {
        vec2 bq = vec2((fract(bx) - 0.5) * 0.2, e - 0.07 - 0.02 * sin(bj * 1.7));
        float br = length(bq);
        float disc = (1.0 - smoothstep(0.026, 0.031, br)) * (0.5 + 0.5 * smoothstep(0.01, 0.028, br));
        vec3 bc = mod(bj, 2.0) < 1.0 ? L.warm : L.cool;
        col += mix(bc, vec3(1.0), 0.25) * disc * (0.08 + 1.6 * rpBand(L, bj));
    }
    // the overhead softbox: two panels with a seam
    vec2 sb = vec2(ax / 0.42, (e - 0.74) / 0.24);
    float box = 1.0 - smoothstep(0.9, 1.0, max(abs(sb.x), abs(sb.y)));
    box *= 0.45 + 0.55 * smoothstep(0.02, 0.06, abs(sb.x));
    col += L.soft * box * 2.6;
    // two kicker strips at the sides, one per gel
    float ks = exp(-(abs(ax) - 1.12) * (abs(ax) - 1.12) * 500.0)
             * smoothstep(-0.02, 0.06, e) * (1.0 - smoothstep(0.35, 0.6, e));
    col += (ax < 0.0 ? L.warm : L.cool) * ks * 1.6;
    // the beat strobe low behind the splash
    vec2 st = vec2(ax, e - 0.1);
    col += L.acc * L.accA * (exp(-dot(st, st) * 140.0) * 2.5 + exp(-dot(st, st) * 20.0) * 0.06);
    return col;
}

// Which of the three patterns the rig drops in the eight-beat block holding
// beat m, never the same twice running.
float rpForm(float m) {
    float k = floor(m / 8.0);
    float a = floor(hash11(k * 1.37 + 0.21) * 2.999);
    float b = floor(hash11((k - 1.0) * 1.37 + 0.21) * 2.999);
    return a == b ? mod(a + 1.0, 3.0) : a;
}

// Where drop j of beat m lands (xz), and its size scale (w).
vec3 rpDrop(float m, float j) {
    float z = rpBeatRun(m) * RP_RUNK + RP_AHEAD;
    float f = rpForm(m);
    float h = hash11(mod(m, 251.0) * 0.618 + j * 0.31);
    float x = f < 0.5 ? (h - 0.5) * 0.3
            : f < 1.5 ? (j * 2.0 - 1.0) * 0.4 + (h - 0.5) * 0.08
            : (mod(m, 8.0) - 3.5) * 0.17;
    float sc = f > 0.5 && f < 1.5 ? 0.72 : 0.9 + 0.25 * h;
    return vec3(rpPathX(z) + x, z + (h - 0.5) * 0.3, sc);
}

float rpDrops(float m) { return abs(rpForm(m) - 1.0) < 0.5 ? 2.0 : 1.0; }

// One splash at c, a beats after impact: crown, jet and the bead it throws.
float rpSplash(vec3 p, vec3 c, float a) {
    vec3 q = vec3(p.x - c.x, p.y, p.z - c.y);
    float sc = c.z;
    float rq = length(q.xz);
    float d = 1e3;
    if (a < 0.3) {
        // the crown: a thin flared sheet with a scalloped rim
        float tc = a / 0.3;
        float rc = (0.08 + 0.3 * tc) * sc + 0.45 * max(q.y, 0.0);
        float hc = 0.15 * sc * sin(3.14159 * tc);
        float rim = hc * (0.72 + 0.28 * cos(atan(q.z, q.x) * 13.0));
        d = max(abs(rq - rc) - 0.011 * (1.0 - 0.5 * tc), max(q.y - rim, -q.y - 0.02));
    }
    if (a > 0.17 && a < 0.62) {
        // droplets flung from the crown's points, one per scallop
        const float SECTOR = 0.48332194;   // 2 pi / 13
        float la = mod(atan(q.z, q.x) + 0.5 * SECTOR, SECTOR) - 0.5 * SECTOR;
        float ts = a - 0.17;
        vec3 dq = vec3(rq * cos(la) - (0.23 * sc + 0.55 * ts), q.y - (0.14 * sc + 0.7 * ts - 3.0 * ts * ts), rq * sin(la));
        d = min(d, length(dq) - 0.011 * sc);
    }
    float tj = (a - 0.1) / 1.0;
    if (tj > 0.0 && tj < 1.0) {
        // the Worthington jet: a tapering column that necks and pinches off
        float hj = 0.6 * sc * pow(sin(3.14159 * tj), 0.75);
        float sep = smoothstep(0.34, 0.4, a);
        float y = clamp(q.y, 0.0, hj);
        float rad = (0.028 + 0.1 * exp(-y * 8.0)) * sc * (1.0 - 0.35 * tj);
        float neck = exp(-(y - hj + 0.06) * (y - hj + 0.06) * 600.0);
        rad *= 1.0 - 0.6 * neck * smoothstep(0.2, 0.34, a) * (1.0 - sep);
        float jet = max(rq - rad, q.y - hj);
        jet = min(jet, length(vec3(q.x, q.y - hj, q.z)) - mix(0.045, 0.026, sep) * sc);
        d = min(d, jet);
    }
    float tb = a - 0.37;
    if (tb > 0.0) {
        // the bead, thrown clear and falling back
        float h0 = 0.6 * sc * pow(sin(3.14159 * 0.27), 0.75);
        float yb = h0 + 0.06 + 0.9 * tb - 2.1 * tb * tb;
        if (yb > -0.05) d = min(d, length(vec3(q.x, (q.y - yb) * 0.9, q.z)) - 0.04 * sc);
    }
    return d;
}

// Everything in the air: the falling drops, the newest splashes, the last ones.
struct RpAir {
    vec3 f0; vec3 f1; float nf;   // drops falling toward the next beat
    vec3 a0; vec3 a1; float na;   // this beat's splashes
    vec3 o0; vec3 o1; float no;   // the last beat's
    float ph;
};

float rpMap(vec3 p, RpAir A) {
    float yf = 0.065 + 2.6 * (1.0 - A.ph * A.ph);
    float d = length(vec3(p.x - A.f0.x, (p.y - yf) * 0.8, p.z - A.f0.y)) - 0.06 * A.f0.z;
    if (A.nf > 1.5) d = min(d, length(vec3(p.x - A.f1.x, (p.y - yf) * 0.8, p.z - A.f1.y)) - 0.06 * A.f1.z);
    d = min(d, rpSplash(p, A.a0, A.ph));
    if (A.na > 1.5) d = min(d, rpSplash(p, A.a1, A.ph));
    d = min(d, rpSplash(p, A.o0, 1.0 + A.ph));
    if (A.no > 1.5) d = min(d, rpSplash(p, A.o1, 1.0 + A.ph));
    return d;
}

// The ray's span through the vertical column around c, as (enter, exit).
vec2 rpColumn(vec3 ro, vec3 rd, vec2 c, float r, vec2 span) {
    vec2 oc = ro.xz - c;
    float a = max(dot(rd.xz, rd.xz), 1e-5);
    float b = dot(oc, rd.xz);
    float h = b * b - a * (dot(oc, oc) - r * r);
    if (h < 0.0) return span;
    h = sqrt(h);
    vec2 t = vec2(-b - h, -b + h) / a;
    // clip to the height of the action
    float y0 = ro.y + rd.y * t.x, y1 = ro.y + rd.y * t.y;
    if (max(y0, y1) < -0.02 || min(y0, y1) > 2.8) return span;
    return vec2(min(span.x, max(t.x, 0.0)), max(span.y, t.y));
}

vec2 rpBounds(vec3 ro, vec3 rd, RpAir A) {
    vec2 s = vec2(1e4, -1.0);
    s = rpColumn(ro, rd, A.f0.xy, 0.1, s);
    s = rpColumn(ro, rd, A.a0.xy, 0.6, s);
    s = rpColumn(ro, rd, A.o0.xy, 0.25, s);
    if (A.nf > 1.5) s = rpColumn(ro, rd, A.f1.xy, 0.1, s);
    if (A.na > 1.5) s = rpColumn(ro, rd, A.a1.xy, 0.6, s);
    if (A.no > 1.5) s = rpColumn(ro, rd, A.o1.xy, 0.25, s);
    return s;
}

// March the liquid in the air between t0 and t1; returns the hit distance or -1.
float rpMarch(vec3 ro, vec3 rd, vec2 span, RpAir A, int steps) {
    float t = span.x;
    for (int i = 0; i < 64; i++) {
        if (i >= steps) break;
        float d = rpMap(ro + rd * t, A);
        if (d < 0.0006 * t + 0.0003) return t;
        t += d * 0.85;
        if (t > span.y) break;
    }
    return -1.0;
}

vec3 rpNormal(vec3 p, RpAir A) {
    const vec2 k = vec2(1.0, -1.0);
    const float h = 0.0015;
    return normalize(k.xyy * rpMap(p + k.xyy * h, A) + k.yyx * rpMap(p + k.yyx * h, A)
                   + k.yxy * rpMap(p + k.yxy * h, A) + k.xxx * rpMap(p + k.xxx * h, A));
}

// What a direction below the horizon sees: the black mirror, roughly.
vec3 rpEnvAny(vec3 d, RpLight L) {
    return d.y >= 0.0 ? rpEnv(d, L) : rpEnv(vec3(d.x, -d.y, d.z), L) * 0.45;
}

// A body of clear liquid: the studio mirrored in it, and seen through it
// upside down, as a drop is a lens.
vec3 rpLiquid(vec3 rd, vec3 n, RpLight L) {
    float cosi = saturate(-dot(rd, n));
    float fr = 0.03 + 0.97 * pow(1.0 - cosi, 5.0);
    vec3 c1 = rpEnvAny(reflect(rd, n), L);
    vec3 ex = normalize(rd - 1.5 * (n - rd * dot(n, rd)));
    vec3 c2 = rpEnvAny(ex, L);
    // the gels rim the liquid from either side, the strobe from behind
    float rim = pow(1.0 - cosi, 3.0);
    vec3 side = n.x < 0.0 ? L.warm : L.cool;
    return c1 * fr + c2 * (1.0 - fr) * 0.85 + side * rim * L.gel * 1.2 + L.acc * L.accA * rim * 0.8;
}

// Lens falloff and a touch of interleaved-gradient dither.
vec3 rpFinish(vec3 col, vec2 p, vec2 uv, VisualUniforms u) {
    col *= 1.0 - 0.25 * smoothstep(0.9, 2.0, length(p));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    return max(col, 0.0); // LINEAR HDR — post chain tonemaps
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float tw = mod(u.time, 600.0);
    RpPalette P = rpPalLoad(u);

    float ringW = mix(0.6, 1.6, u.param0);        // packet width scale
    float expansion = mix(0.3, 0.85, u.param1);   // ring speed, units per beat
    float persist = mix(0.75, 0.3, u.param2);     // decay per beat

    float n = floor(u.beatCount);
    float ph = saturate(u.beatPhase);

    // ---- the lights ----
    float chorus = step(2.0, mod(floor(u.beatCount / 16.0), 4.0));
    RpLight L;
    L.warm = rpVivid(rpPal(P, mix(0.93, 0.99, chorus)) * vec3(1.0, 0.62, 0.34), 1.6);
    L.cool = rpVivid(rpPal(P, mix(0.48, 0.4, chorus)) * vec3(0.7, 0.9, 1.0), 1.3);
    L.soft = mix(vec3(1.0, 0.97, 0.92), L.warm, 0.1);
    L.acc = mod(n, 2.0) < 1.0 ? L.warm : L.cool;
    L.accA = exp(-ph * 5.0) * (0.6 + 0.6 * saturate(u.bassImpact));
    L.gx = 0.48 + 0.12 * sin(tw * 0.11);
    L.gel = 0.2 + 0.14 * u.level + 0.08 * u.mid;
    L.b0 = vec3(bandAt(u, 0.04), bandAt(u, 0.16), bandAt(u, 0.3));
    L.b1 = vec3(bandAt(u, 0.46), bandAt(u, 0.62), bandAt(u, 0.8));

    // ---- camera: creeps forward on the speed profile ----
    vec2 fl = rpFlight(u);
    float zc = fl.x * RP_RUNK;
    float rush = saturate((fl.y - 1.0) / 2.5);
    // a breakdown dims the gels to the lamps alone; a burst opens them up
    L.gel *= mix(0.45, 1.35, smoothstep(0.5, 3.0, fl.y));
    vec3 ro = vec3(rpPathX(zc) + 0.2 * sin(tw * 0.05), 0.42 + 0.06 * sin(tw * 0.07), zc);
    float zt = zc + RP_AHEAD;
    vec3 ta = vec3(rpPathX(zt) + 0.1 * sin(tw * 0.031), 0.2 + 0.05 * sin(tw * 0.043), zt);
    float fov = 2.1 - 0.2 * rush;
    vec3 rd = osCamera(ro, ta, osBank(u, 0.04), fov, p);
    float pa = 2.0 / (u.resolution.y * fov);

    // ---- the drops in the air ----
    RpAir A;
    A.ph = ph;
    A.f0 = rpDrop(n + 1.0, 0.0); A.f1 = rpDrop(n + 1.0, 1.0); A.nf = rpDrops(n + 1.0);
    A.a0 = rpDrop(n, 0.0);       A.a1 = rpDrop(n, 1.0);       A.na = rpDrops(n);
    A.o0 = rpDrop(n - 1.0, 0.0); A.o1 = rpDrop(n - 1.0, 1.0); A.no = rpDrops(n - 1.0);
    int airSteps = osSteps(20.0, 56.0, detail);

    float tS = rd.y < -1e-4 ? -ro.y / rd.y : 1e4;
    vec2 span = rpBounds(ro, rd, A);
    span.y = min(span.y, tS);
    float tA = span.y > span.x ? rpMarch(ro, rd, span, A, airSteps) : -1.0;
    if (tA > 0.0) {
        vec3 hp = ro + rd * tA;
        return rpFinish(rpLiquid(rd, rpNormal(hp, A), L), p, uv, u);
    }
    if (rd.y > -1e-4) return rpFinish(rpEnv(rd, L), p, uv, u);

    // ---- the liquid surface: rings from the last few drops, a faint swell ----
    vec3 sp = ro + rd * tS;
    float pfw = tS * pa / max(-rd.y, 0.04);
    vec2 grad = vec2(0.0);
    vec3 glow = vec3(0.0);
    float kf = 52.0 + 14.0 * u.spectralCentroid;
    float aaR = exp(-kf * kf * pfw * pfw * 0.6);
    int nSlots = osSteps(4.0, 7.0, detail);
    for (int k = 0; k < 7; k++) {
        if (k >= nSlots) break;
        float m = n - float(k);
        float age = float(k) + ph;
        float nd = rpDrops(m);
        for (int j = 0; j < 2; j++) {
            if (float(j) >= nd) break;
            vec3 c = rpDrop(m, float(j));
            vec2 dv = sp.xz - c.xy;
            float r = length(dv);
            vec2 dir = dv / max(r, 1e-4);
            // the crater the drop punches, closing as the jet climbs
            float sg = (0.07 + 0.25 * age) * c.z;
            float cd = 0.035 * c.z * sin(3.14159 * saturate(age / 0.45)) * step(age, 0.45);
            grad += dir * cd * 2.0 * r / (sg * sg) * exp(-r * r / (sg * sg));
            // the ring packet, ringing longer behind its front
            float R = 0.1 * c.z + age * expansion;
            float s = r - R;
            float w = (0.05 + 0.035 * age) * ringW;
            float wb = s < 0.0 ? w * 2.4 : w;
            if (abs(s) < wb * 3.5) {
                float env = exp(-s * s / (wb * wb));
                float amp = 0.0085 * c.z * exp(-age * persist) / (1.0 + 1.5 * r) * smoothstep(0.0, 0.1, age);
                float cs = cos(kf * s), sn = sin(kf * s);
                float dh = amp * (-2.0 * s / (wb * wb) * cs * exp(-pfw * pfw / (wb * wb)) - kf * sn * aaR) * env;
                grad += dh * dir;
            }
            // the strobe flash glows through the water at the impact
            glow += L.acc * exp(-r * r * 30.0) * exp(-age * 6.0) * 0.5;
        }
    }
    float swell = 0.0016 + 0.003 * u.mid;
    int nSwell = osSteps(2.0, 3.0, detail);
    for (int i = 0; i < 3; i++) {
        if (i >= nSwell) break;
        float fi = float(i);
        float ang = fi * 2.1 + 0.4;
        vec2 dir = vec2(cos(ang), sin(ang));
        float fk = 6.0 + 4.0 * fi;
        float ph2 = dot(sp.xz, dir) * fk + tw * (1.1 + 0.3 * fi);
        float aaS = exp(-fk * fk * pfw * pfw * 0.6);
        grad += dir * swell / (1.0 + fi) * fk * cos(ph2) * aaS * 0.3;
    }
    vec3 nrm = normalize(vec3(-grad.x, 1.0, -grad.y));
    float cosi = saturate(-dot(rd, nrm));
    float fres = 0.02 + 0.98 * pow(1.0 - cosi, 5.0);
    vec3 rr = reflect(rd, nrm);
    rr.y = abs(rr.y);
    vec3 refl = rpEnv(rr, L);
    // the splashes stand in the mirror too
    if (detail > 0.0) {
        vec3 sp2 = sp + nrm * 0.002;
        vec2 span2 = rpBounds(sp2, rr, A);
        if (span2.y > span2.x) {
            float t2 = rpMarch(sp2, rr, span2, A, osSteps(0.0, 40.0, detail));
            if (t2 > 0.0) refl = rpLiquid(rr, rpNormal(sp2 + rr * t2, A), L);
        }
    }
    // dark dyed liquid below the surface, faintly lit by the gels
    vec3 under = (L.warm + L.cool) * 0.004 + glow;
    vec3 col = refl * fres * 1.4 + under * (1.0 - fres);
    return rpFinish(col, p, uv, u);
}
