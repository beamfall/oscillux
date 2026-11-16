// SPDX-License-Identifier: AGPL-3.0-only
// Prism room.
// A slow drift above a triangular mirror room. Its three walls, floor and
// ceiling are mirrors, so the room repeats as a kaleidoscope lattice that
// recedes into the dark in every direction. A tall glass prism stands in the
// middle, a ring of small ones around it; each bends the room behind it into
// red, green and blue fringes, and its edges burn as thin filaments. A white
// beam enters through a slot, strikes the central prism and leaves as a
// fanned spectrum sheet that lands on the walls and floor as rainbows, which
// the mirrors multiply into a star. The prism turns a step on every beat, so
// the spectrum sweeps the room in time; bass brightens the beam and the fan,
// and every beat sends a rainbow caustic ring across the floor. Spectrum bars
// rise along the foot of the walls, sparse LED points stud the ceiling and a
// few lamps hang in the air, all on the spectrum bands. The camera's drift
// follows the shared speed profile, never the audio; its rush brightens the
// fan.
// param0 = Facets (prism count) ; param1 = Sweep (drift pace, hue chase) ;
// param2 = Edge Glow

const float PR_RI = 3.6;   // inradius of the triangular room
const float PR_H = 4.4;    // room height
const float PR_BEAMY = 1.05;
const float PR_HS = 6.235; // half a wall's length: PR_RI * sqrt(3)

// Smoothly saturated version of a palette colour: kills the pastel, keeps hue.
vec3 prDeep(vec3 c) {
    c = clamp(mix(vec3(luma(c)), c, 1.5), vec3(0.0), vec3(4.0));
    return c * c * 1.5;
}

// A visible-spectrum ramp for dispersed light, t in [0, 1] red to violet.
vec3 prSpectrum(float t) {
    vec3 c = vec3(1.0 - smoothstep(0.0, 0.45, abs(t - 0.12) * 1.6),
                  1.0 - smoothstep(0.0, 0.42, abs(t - 0.45) * 1.7),
                  1.0 - smoothstep(0.0, 0.45, abs(t - 0.8) * 1.6));
    c.r += 0.35 * (1.0 - smoothstep(0.0, 0.2, abs(t - 0.95)));
    return c;
}

struct PrScene {
    float count;     // satellite prisms
    float tw;
    vec3 bs;         // beam start (the slot)
    vec3 bd;         // beam direction
    float bl;        // beam length to the central prism
    vec2 fanDir;
    float fanE;
    float ringR;     // floor caustic ring radius and strength
    float ringA;
    float edgeGlow;
    float chase;     // hue chase along the LED strips
    float pix;
    vec3 cornerC;    // per-frame colours, hoisted out of the bounce loop
    vec3 tint0;
    vec3 tint1;
    vec3 tint2;
};

// Outward normal of wall k (in xz).
vec2 prWallN(int k) {
    float a = 1.5707963 + float(k) * 2.0943951;
    return vec2(cos(a), sin(a));
}

// Fan of dispersed light leaving the central prism: unit direction from the
// prism centre within the fan, mapped to spectrum position, or -1 outside.
float prFanT(vec2 d, vec2 dir0) {
    float c = dot(d, dir0);
    float sn = d.x * dir0.y - d.y * dir0.x;
    float a = atan2_(sn, c);
    float t = (a + 0.3) / 0.6;
    return (c > 0.0 && t > 0.0 && t < 1.0) ? t : -1.0;
}

// Triangular prism at c (base on the floor), face normals at ang + k*120deg,
// inradius rin, height h. Returns entry/exit distances and their normals.
bool prPrism(vec3 ro, vec3 rd, vec3 c, float ang, float rin, float h,
             out float tN, out float tF, out vec3 nN, out vec3 nF) {
    vec3 o = ro - c;
    tN = -1e4; tF = 1e4;
    nN = vec3(0.0, 1.0, 0.0); nF = vec3(0.0, 1.0, 0.0);
    // cheap reject: the ray's ground track misses the prism's circumcircle
    vec2 rxz = rd.xz;
    float r2 = dot(rxz, rxz);
    if (r2 > 1e-8) {
        float tc = -dot(o.xz, rxz) / r2;
        vec2 q = o.xz + rxz * max(tc, 0.0);
        if (dot(q, q) > 4.0 * rin * rin) return false;
    }
    vec2 fn = vec2(cos(ang), sin(ang));
    for (int k = 0; k < 5; k++) {
        vec3 n;
        float off;
        if (k < 3) {
            n = vec3(fn.x, 0.0, fn.y);
            fn = vec2(-0.5 * fn.x - 0.8660254 * fn.y, 0.8660254 * fn.x - 0.5 * fn.y); // +120deg
            off = rin;
        } else if (k == 3) {
            n = vec3(0.0, 1.0, 0.0); off = h;
        } else {
            n = vec3(0.0, -1.0, 0.0); off = 0.0;
        }
        float dn = dot(rd, n);
        float on = dot(o, n);
        if (abs(dn) < 1e-6) {
            if (on > off) return false;
            continue;
        }
        float t = (off - on) / dn;
        if (dn < 0.0) { if (t > tN) { tN = t; nN = n; } }
        else { if (t < tF) { tF = t; nF = n; } }
    }
    return tN < tF && tF > 0.0;
}

void prPrismParams(int i, PrScene sc, out vec3 c, out float ang, out float rin, out float h) {
    if (i == 0) {
        c = vec3(0.0); ang = 0.4 + sc.tw * 0.02; rin = 0.33; h = 1.75;
        return;
    }
    float fi = float(i - 1);
    float a = sc.tw * 0.012 + fi * 6.2831853 / sc.count;
    float hr = hash11(fi * 3.7 + 1.3);
    float rr = 1.45 + 0.35 * hash11(fi * 1.9 + 0.4);
    c = vec3(cos(a) * rr, 0.0, sin(a) * rr);
    ang = a * 1.7 + hr * 6.28 + sc.tw * (0.03 + 0.02 * hr);
    rin = 0.12 + 0.05 * hr;
    h = 0.35 + 0.55 * hr;
}

// Distance from o (a point on the prism, relative to its base centre) to its
// vertical edges (x) and to the rims of its top and base triangles (y).
vec2 prEdgeDist(vec3 o, float ang, float rin, float h) {
    float dv = 1e4;
    float tb = 1e4;
    vec2 fn = vec2(cos(ang), sin(ang));
    for (int k = 0; k < 3; k++) {
        // the vertex between faces k and k+1 lies at +60deg from face k
        vec2 vn = vec2(0.5 * fn.x - 0.8660254 * fn.y, 0.8660254 * fn.x + 0.5 * fn.y);
        dv = min(dv, length(o.xz - 2.0 * rin * vn));
        tb = min(tb, rin - dot(o.xz, fn));
        fn = vec2(-0.5 * fn.x - 0.8660254 * fn.y, 0.8660254 * fn.x - 0.5 * fn.y);
    }
    tb = max(tb, 0.0);
    float dr = min(length(vec2(o.y - h, tb)), length(vec2(o.y, tb)));
    return vec2(dv, dr);
}

// Hanging lamp i: position (xyz) and its band (w).
vec4 prLamp(int i, float tw) {
    float fi = float(i);
    float a = fi * 2.3999632 + 0.7;
    float r = 0.7 + 1.7 * fract(fi * 0.618 + 0.21);
    float y = 2.25 + 0.8 * hash11(fi * 5.1 + 2.0) + 0.08 * sin(tw * 0.3 + fi);
    return vec4(cos(a) * r, y, sin(a) * r, fract(fi * 0.381966 + 0.05));
}

// Light in the haze along one straight path segment: the white beam, the
// slot it enters by, the spectrum fan sheet and the hanging lamps.
vec3 prVolume(vec3 ro, vec3 rd, float seg, float dist, PrScene sc, int lamps, float bk, VisualUniforms u) {
    vec3 col = vec3(0.0);
    // the white beam: closest approach between the segment and the beam
    vec3 w0 = ro - sc.bs;
    float b = dot(rd, sc.bd);
    float dd = 1.0 - b * b;
    if (dd > 1e-5) {
        float tc = (b * dot(sc.bd, w0) - dot(rd, w0)) / dd;
        tc = clamp(tc, 0.0, seg);
        float sb = clamp(dot(ro + rd * tc - sc.bs, sc.bd), 0.0, sc.bl - 0.45);
        tc = clamp(dot(sc.bs + sc.bd * sb - ro, rd), 0.0, seg);
        float dist2 = length(ro + rd * tc - sc.bs - sc.bd * sb);
        float bw = max(0.008, (dist + tc) * sc.pix * 1.3);
        col += vec3(2.0, 1.9, 1.75) * exp(-dist2 * dist2 / (bw * bw)) * (0.014 / max(bw, 0.014)) * (0.7 + 0.6 * u.bassImpact) * bk *
               smoothstep(0.4, 1.4, dist + tc);
        col += vec3(0.6, 0.58, 0.55) * exp(-dist2 * 6.0) * 0.05 * (1.0 + 0.8 * u.bassImpact);
    }
    // the slot where the beam enters, a hot point on the wall
    vec3 ap = sc.bs - ro;
    float tap = clamp(dot(ap, rd), 0.0, seg);
    float da = length(ap - rd * tap);
    col += vec3(1.5, 1.42, 1.3) * (exp(-da * da * 60.0) * 0.7 + exp(-da * 2.5) * 0.03) * bk;
    // fan: a thin sheet at beam height, crossed by the segment
    if (abs(rd.y) > 1e-4) {
        float tp = (PR_BEAMY - ro.y) / rd.y;
        if (tp > 0.0 && tp < seg) {
            vec3 fp = ro + rd * tp;
            float r = length(fp.xz);
            float ft = prFanT(fp.xz / max(r, 1e-4), sc.fanDir);
            if (ft >= 0.0) {
                float sheet = min((0.04 + 0.03 * r) / abs(rd.y), 2.0) * 0.55;
                col += prSpectrum(ft) * sheet * sc.fanE * smoothstep(0.5, 1.0, r) * exp(-r * 0.1);
            }
        }
    }
    // hanging lamps
    for (int i = 0; i < 7; i++) {
        if (i >= lamps) break;
        vec4 lp = prLamp(i, sc.tw);
        vec3 to = lp.xyz - ro;
        float tt = clamp(dot(to, rd), 0.0, seg);
        vec3 ov = to - rd * tt;
        float o2 = dot(ov, ov);
        float e = bandAt(u, 0.05 + 0.85 * lp.w);
        float w = max(0.05, (dist + tt) * sc.pix * 1.4);
        float k = 0.05 / w;
        vec3 lc = prSpectrum(fract(lp.w + sc.chase * 0.3)) * 1.2;
        col += (peakWhite(lc, 0.15) * k * k * exp(-o2 / (w * w)) * 1.4 + lc * exp(-sqrt(o2) * 9.0) * 0.05) *
               (0.25 + 1.6 * e * e + 0.5 * e);
    }
    return col;
}

// Emission on wall k at p, seen with footprint w: corner filaments, a hue
// wash along the foot, spectrum bars and the fan band.
vec3 prWallLight(vec3 p, int k, float w, PrScene sc, VisualUniforms u) {
    vec2 n = prWallN(k);
    float s = dot(p.xz, vec2(-n.y, n.x));
    vec3 col = vec3(0.0);
    // vertical corner filaments
    float dv = PR_HS - abs(s);
    col += sc.cornerC * (exp(-dv * dv / (w * w)) * 0.45 + exp(-dv * 6.0) * 0.03) * sc.edgeGlow *
           (0.2 + 0.8 * smoothstep(3.4, 1.0, p.y));
    // a soft wash of chasing hue along the foot of the wall
    float hs = s * 0.08 + float(k) * 0.33 + sc.chase;
    col += prDeep(palVisual(fract(hs), u)) * exp(-p.y * 4.0) * 0.035;
    // spectrum bars rising from the floor
    float bw = 0.95;
    float bi = floor(s / bw);
    float ls = s - (bi + 0.5) * bw;
    float f = abs(bi + 0.5) * bw / PR_HS;
    float e = bandAt(u, saturate(0.03 + 0.9 * f));
    float hgt = 0.15 + 1.9 * e;
    if (p.y < hgt + 0.3) {
        float cw = max(0.022, w);
        float core = (1.0 - smoothstep(cw, cw + max(w, 0.02), abs(ls))) * (0.03 / cw);
        float seg = 0.4 + 0.6 * smoothstep(0.02, 0.045, fract(p.y / 0.13) * 0.13);
        float lit = (1.0 - smoothstep(hgt - 0.04, hgt, p.y)) * smoothstep(0.08, 0.14, p.y);
        vec3 bc = prDeep(palVisual(fract(0.06 + 0.1 * p.y + 0.4 * f + 0.27 * float(k)), u));
        col += bc * core * lit * seg * 2.2;
        float cap = exp(-(p.y - hgt - 0.07) * (p.y - hgt - 0.07) / 0.0012) * core;
        col += peakWhite(bc, 0.5) * cap * 1.4;
        col += bc * exp(-abs(ls) * 12.0) * lit * 0.05;
    }
    // the dispersed fan lands here as a rainbow band
    float ft = prFanT(normalize(p.xz + 1e-5), sc.fanDir);
    if (ft >= 0.0) {
        // a tall rainbow patch with a hot centre line, so the mirrors
        // multiply it into a kaleidoscope of spectra
        float dy = (p.y - PR_BEAMY) / (0.2 + 0.04 * length(p.xz));
        float edgeT = smoothstep(0.0, 0.08, ft) * smoothstep(1.0, 0.92, ft);
        col += prSpectrum(ft) * (exp(-dy * dy) * 0.9 + exp(-dy * dy * 30.0) * 1.2) * edgeT * sc.fanE;
    }
    return col;
}

// Floor emission: the beat caustic ring, a caustic pool and the fan's trace.
vec3 prFloorLight(vec3 p, float w, PrScene sc, VisualUniforms u) {
    vec3 col = vec3(0.0);
    float r = length(p.xz);
    float a = atan2_(p.z, p.x + 1e-5);
    // the caustic ring: rainbow by angle, a soft net of light inside it
    float rq = (r - sc.ringR) / max(0.08, w);
    vec3 rc = prSpectrum(fract(a * 0.477 + sc.chase * 2.0));
    col += rc * exp(-rq * rq) * sc.ringA * 1.4;
    float net = sin(p.x * 9.0 + sc.tw * 0.7) * sin(p.z * 9.0 - sc.tw * 0.9) +
                sin((p.x + p.z) * 6.0 - sc.tw * 0.5);
    net = pow(saturate(0.5 + 0.35 * net), 6.0);
    col += rc * net * sc.ringA * 0.5 * smoothstep(sc.ringR, sc.ringR - 1.2, r) * smoothstep(0.4, 0.8, r);
    // a steady caustic pool around the central prism's foot
    col += prSpectrum(fract(a * 0.159 + sc.tw * 0.02)) * net * 0.08 * exp(-r * 1.6) * smoothstep(0.45, 0.6, r);
    // the fan's trace across the floor
    float ft = prFanT(p.xz / max(r, 1e-4), sc.fanDir);
    // the fan's trace across the floor: a rainbow wedge that the mirrors
    // repeat into a star
    if (ft >= 0.0) {
        float eT = smoothstep(0.0, 0.1, ft) * smoothstep(1.0, 0.9, ft);
        col += prSpectrum(ft) * sc.fanE * eT * 0.16 * smoothstep(0.4, 1.2, r) * exp(-r * 0.25);
    }
    return col;
}

// Ceiling emission: a lattice of LED points, each on a band.
vec3 prCeilLight(vec3 p, float w, PrScene sc, VisualUniforms u) {
    vec2 g = p.xz / 0.55;
    vec2 ci = floor(g);
    vec2 cf = fract(g) - 0.5;
    float hsh = hash21(ci + 7.0);
    float d = length(cf) * 0.55;
    float ww = max(0.015, w);
    float k = 0.015 / ww;
    float e = bandAt(u, hsh);
    vec3 c = prDeep(palVisual(fract(hsh * 0.7 + sc.chase), u));
    return peakWhite(c, 0.3) * k * k * exp(-d * d / (ww * ww)) * (0.2 + 1.4 * e * e) * step(0.8, hsh);
}

// Trace through the mirror room: up to maxB straight segments. Prisms
// refract the path with one index; walls, floor and ceiling reflect it.
// Reports the first surface hit so the caller can add dispersion and the
// glass reflection.
vec3 prTrace(vec3 ro, vec3 rd, vec3 thr0, float dist0, float ior, int maxB, int lamps,
             PrScene sc, VisualUniforms u, out int firstId, out vec3 fHit, out vec3 fN, out float fT) {
    vec3 col = vec3(0.0);
    vec3 thr = thr0;
    float dist = dist0;
    firstId = -1; fHit = ro; fN = vec3(0.0, 1.0, 0.0); fT = 0.0;
    for (int bnc = 0; bnc < 12; bnc++) {
        if (bnc >= maxB) break;
        // room: the three walls, floor and ceiling
        float tR = 1e4;
        int kind = 0;
        for (int k = 0; k < 3; k++) {
            vec2 n = prWallN(k);
            float dn = dot(rd.xz, n);
            if (dn > 1e-5) {
                float t = (PR_RI - dot(ro.xz, n)) / dn;
                if (t < tR) { tR = t; kind = k; }
            }
        }
        if (rd.y < -1e-5) { float t = -ro.y / rd.y; if (t < tR) { tR = t; kind = 3; } }
        if (rd.y > 1e-5) { float t = (PR_H - ro.y) / rd.y; if (t < tR) { tR = t; kind = 4; } }
        tR = max(tR, 0.0);
        // prisms
        int pid = -1;
        float tP = tR;
        vec3 nP = vec3(0.0, 1.0, 0.0);
        // satellites only near the eye; deeper in the mirror lattice only the
        // central prism repeats, which keeps the kaleidoscope legible
        float np = bnc < 3 ? sc.count : 0.0;
        for (int i = 0; i < 7; i++) {
            if (float(i) > np) break;
            vec3 c; float ang, rin, h;
            prPrismParams(i, sc, c, ang, rin, h);
            float tN, tF; vec3 nN, nF;
            if (prPrism(ro, rd, c, ang, rin, h, tN, tF, nN, nF) && tN > 1e-3 && tN < tP) {
                tP = tN; nP = nN; pid = i;
            }
        }
        float seg = min(tP, tR);
        col += thr * prVolume(ro, rd, seg, dist, sc, bnc < 2 ? lamps : 0, bnc == 0 ? 1.0 : 0.45, u);
        dist += seg;
        // haze: everything fades with path length into the deep lattice
        thr *= exp(-seg * 0.07);
        vec3 p = ro + rd * seg;
        float w = max(0.004, dist * sc.pix * 1.2);
        if (bnc == 0) { firstId = pid; fHit = p; fT = seg; }
        if (pid >= 0) {
            vec3 c; float ang, rin, h;
            prPrismParams(pid, sc, c, ang, rin, h);
            if (bnc == 0) fN = nP;
            // edge filaments and their spectral fringes
            vec2 de = prEdgeDist(p - c, ang, rin, h);
            float edge = exp(-de.x * de.x / (w * w)) + exp(-de.y * de.y / (w * w));
            float dm = min(de.x, de.y);
            vec3 fringe = prSpectrum(saturate(dm / (6.0 * w))) * exp(-dm / (4.0 * w)) * 0.3;
            vec3 rim = prDeep(palVisual(0.55 + 0.11 * float(pid), u));
            float eg = pid == 0 ? 1.0 : 0.45;
            col += thr * (peakWhite(rim, 0.3) * edge + fringe) * sc.edgeGlow * eg * (0.6 + 0.9 * u.bassImpact);
            float cosi = saturate(-dot(rd, nP));
            float fr = 0.04 + 0.96 * pow(1.0 - cosi, 5.0);
            vec3 d1 = refract(rd, nP, 1.0 / ior);
            if (dot(d1, d1) < 1e-6) d1 = reflect(rd, nP);
            vec3 p1 = p + d1 * 1e-3;
            float tN2, tF2; vec3 nN2, nF2;
            bool ok = prPrism(p1, d1, c, ang, rin, h, tN2, tF2, nN2, nF2);
            float tx = ok ? max(tF2, 0.0) : 0.0;
            vec3 p2 = p1 + d1 * tx;
            vec3 d2 = refract(d1, -nF2, ior);
            if (dot(d2, d2) < 1e-6) d2 = reflect(d1, -nF2);
            vec3 tint = mix(vec3(1.0), prDeep(palVisual(0.15 + 0.13 * float(pid), u)), 0.22);
            // a faint glow held inside the glass, rising towards the top
            col += thr * tint * (1.0 - fr) * 0.015 * (0.4 + 0.6 * saturate(p.y / h));
            if (pid == 0) {
                // the struck prism holds the beam: a white core where it
                // enters, opening into a spectrum wedge through the glass
                vec3 m = p + d1 * tx * 0.5;
                float sy = m.y - PR_BEAMY;
                float acr = dot(m.xz, vec2(-sc.fanDir.y, sc.fanDir.x)) / rin;
                float along = saturate(0.5 + 0.5 * dot(m.xz, sc.fanDir) / rin);
                vec3 wedge = mix(vec3(1.0), prSpectrum(saturate(0.5 + 0.7 * acr)) * 1.3, smoothstep(0.0, 0.4, along));
                float vy = exp(-sy * sy / (0.012 + 0.16 * along * along));
                col += thr * (1.0 - fr) * wedge * vy * tx * sc.fanE * 0.75;
            }
            thr *= (1.0 - fr) * tint * 0.95;
            dist += tx;
            ro = p2 + d2 * 1e-3;
            rd = d2;
            continue;
        }
        vec3 n;
        vec3 refl;
        if (kind < 3) {
            vec2 wn = prWallN(kind);
            n = vec3(-wn.x, 0.0, -wn.y);
            col += thr * prWallLight(p, kind, w, sc, u);
            // each wall's silvering is faintly tinted, so the lattice drifts
            // in colour as it recedes
            refl = kind == 0 ? sc.tint0 : (kind == 1 ? sc.tint1 : sc.tint2);
        } else if (kind == 3) {
            n = vec3(0.0, 1.0, 0.0);
            col += thr * prFloorLight(p, w, sc, u);
            refl = vec3(0.4);
        } else {
            n = vec3(0.0, -1.0, 0.0);
            col += thr * prCeilLight(p, w, sc, u);
            refl = vec3(0.14);
        }
        if (bnc == 0) fN = n;
        thr *= refl;
        if (max(thr.r, max(thr.g, thr.b)) < 0.02) break;
        rd = reflect(rd, n);
        ro = p + n * 1e-3;
    }
    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float tw = mod(u.time, 600.0);

    PrScene sc;
    sc.count = floor(mix(1.0, 5.0, u.param0) + 0.5);
    sc.tw = tw;
    // the shared speed profile: drift pace, and the rush that brightens the fan
    vec2 fl = osFlight(u, mix(0.1, 0.32, u.param1), mix(0.03, 0.12, u.param1));
    float rush = saturate((fl.y - 1.0) / 3.5);
    sc.edgeGlow = mix(0.5, 2.0, u.param2);
    sc.chase = tw * mix(0.01, 0.05, u.param1);
    // the beam enters through a slot high on wall 0 and strikes the central
    // prism; the fan leaves turned away by the glass
    vec2 n0 = prWallN(0);
    vec2 sxz = n0 * (PR_RI - 0.01) + vec2(-n0.y, n0.x) * 1.4;
    sc.bs = vec3(sxz.x, 2.6, sxz.y);
    vec3 be = vec3(0.0, PR_BEAMY, 0.0);
    sc.bd = be - sc.bs;
    sc.bl = length(sc.bd);
    sc.bd /= sc.bl;
    vec2 inc = normalize(sc.bd.xz);
    // the central prism turns a step on every beat, so the spectrum sweeps
    // across the walls in time
    float kb = u.beatCount + smoothstep(0.0, 0.4, saturate(u.beatPhase));
    float dev = 0.7 + 0.12 * sin(tw * 0.023) + 0.1 * sin(kb * 2.39996);
    sc.fanDir = vec2(inc.x * cos(dev) - inc.y * sin(dev), inc.x * sin(dev) + inc.y * cos(dev));
    sc.fanE = (0.6 + 0.3 * u.bass + 0.4 * u.bassImpact) * (1.0 + 0.6 * rush);
    float bp = saturate(u.beatPhase);
    sc.ringR = 0.5 + 3.2 * pow(bp, 0.6);
    sc.ringA = (1.0 - bp) * (1.0 - bp) * (0.3 + 0.9 * u.bassImpact);

    // ---- camera: a slow drift around the prisms, gazing in and out ----
    float oa = fl.x * 0.09;
    float orad = 2.75 + 0.2 * sin(oa * 0.7 + 1.0);
    vec3 ro = vec3(cos(oa) * orad, 1.8 + 0.3 * sin(tw * 0.043) + 0.12 * sin(oa * 1.3), sin(oa) * orad);
    // the gaze swings between the central prism and the lattice beyond it
    float gz = 0.5 + 0.5 * sin(tw * 0.021);
    vec3 side = vec3(-sin(oa), 0.0, cos(oa));
    vec3 ta = mix(vec3(0.0, 0.95, 0.0), ro + side * 3.0 + vec3(0.0, 0.4 * sin(tw * 0.017), 0.0), gz * 0.4);
    float roll = osBank(u, 0.05);
    float fov = 1.2;
    vec3 rd = osCamera(ro, ta, roll, fov, p);
    sc.pix = 2.0 / (u.resolution.y * fov);

    sc.cornerC = peakWhite(prDeep(palVisual(0.55, u)), 0.4);
    sc.tint0 = mix(vec3(0.44), prDeep(palVisual(0.5, u)) * 0.44, 0.16);
    sc.tint1 = mix(vec3(0.44), prDeep(palVisual(0.7, u)) * 0.44, 0.16);
    sc.tint2 = mix(vec3(0.44), prDeep(palVisual(0.9, u)) * 0.44, 0.16);

    int maxB = osSteps(3.0, 5.0, detail);
    int lamps = osSteps(2.0, 4.0, detail);
    // passes: the eye's path; then, where it first meets glass, one path per
    // colour channel's index (dispersion) and the reflection off the face.
    // One loop keeps a single copy of the trace in the compiled shader.
    vec3 col = vec3(0.0);
    int fid = -1; vec3 fh = ro; vec3 fn = vec3(0.0, 1.0, 0.0); float ft = 0.0;
    int passes = 1;
    bool disperse = false;
    for (int ps = 0; ps < 4; ps++) {
        if (ps >= passes) break;
        int role = (ps == 1 && !disperse) ? 3 : ps;
        vec3 pro = ro;
        vec3 prd = rd;
        vec3 thr = vec3(1.0);
        float d0 = 0.0;
        int mb = role == 0 ? maxB : maxB - 2;
        float ior = role == 1 ? 1.46 : (role == 2 ? 1.54 : 1.5);
        if (role == 3) {
            prd = reflect(rd, fn);
            pro = fh + prd * 1e-3;
            thr = vec3(0.04 + 0.96 * pow(1.0 - saturate(-dot(rd, fn)), 5.0));
            d0 = ft;
            mb = 1;
        }
        int qid; vec3 qh; vec3 qn; float qt;
        vec3 c = prTrace(pro, prd, thr, d0, ior, mb, role == 3 ? 0 : lamps, sc, u, qid, qh, qn, qt);
        if (role == 0) {
            col = c;
            fid = qid; fh = qh; fn = qn; ft = qt;
            if (fid >= 0) passes = disperse ? 4 : 2;
        } else if (role == 1) {
            col.r = c.r;
        } else if (role == 2) {
            col.b = c.b;
        } else {
            col += c;
        }
    }
    return max(col, vec3(0.0)); // LINEAR HDR; the post chain tonemaps
}
