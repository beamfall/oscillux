// SPDX-License-Identifier: AGPL-3.0-only
// Cube Turn: the outgoing frame is the front face of a glossy box whose side
// face holds the incoming one. The box is cut into four horizontal layers,
// like a puzzle cube: as the camera eases back and rises a little, the layers
// part by a hair and turn a quarter turn one after another (order and
// direction seeded), light glowing from inside through the seams, then close
// up again on the new face. It floats over a dark mirror floor: key-lit
// faces with a sliding softbox and a faint reflection of the new frame
// (Fresnel), beat-pulsed palette rims on the edges, a floor reflection and a
// soft contact shadow. Each pixel ray-casts the layers analytically;
// silhouette edges are anti-aliased from the pixel footprint.
bool ctBox(vec3 ro, vec3 rd, vec3 h, out float t0, out vec3 nl) {
    vec3 sg = vec3(rd.x >= 0.0 ? 1.0 : -1.0, rd.y >= 0.0 ? 1.0 : -1.0, rd.z >= 0.0 ? 1.0 : -1.0);
    vec3 inv = sg / max(abs(rd), vec3(1e-6));
    vec3 ta = (-h - ro) * inv, tb = (h - ro) * inv;
    vec3 tn = min(ta, tb), tf = max(ta, tb);
    t0 = max(max(tn.x, tn.y), tn.z);
    float t1 = min(min(tf.x, tf.y), tf.z);
    nl = tn.x >= max(tn.y, tn.z) ? vec3(-sg.x, 0.0, 0.0)
       : (tn.y >= tn.z ? vec3(0.0, -sg.y, 0.0) : vec3(0.0, 0.0, -sg.z));
    return t1 > max(t0, 0.0);
}

// world <-> box-local rotation about y
vec3 ctToLocal(vec3 v, float c, float s) { return vec3(v.x * c - v.z * s, v.y, v.x * s + v.z * c); }
vec3 ctToWorld(vec3 v, float c, float s) { return vec3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c); }

// softbox environment seen in a reflected direction
vec3 ctEnv(vec3 r, vec3 keyC, vec3 fillC) {
    vec3 col = vec3(0.0);
    if (r.z < -0.05) {
        vec2 q = r.xy / -r.z;
        vec2 b = abs(q - vec2(-0.55, 0.5)) - vec2(0.42, 0.2);
        col += keyC * (1.0 - smoothstep(-0.06, 0.08, max(b.x, b.y)));
        vec2 b2 = abs(q - vec2(0.75, 0.05)) - vec2(0.05, 0.6);
        col += fillC * 0.5 * (1.0 - smoothstep(-0.04, 0.1, max(b2.x, b2.y)));
    }
    return col + keyC * 0.05 * smoothstep(-0.2, 0.6, r.y);
}

// screen-space rate (per unit length) of a face tangent t at camera-relative point q
float ctRate(vec3 q, vec3 t, vec3 up, vec3 fw, float f) {
    float z = max(dot(q, fw), 1e-3);
    vec2 qp = vec2(q.x, dot(q, up)), tp = vec2(t.x, dot(t, up));
    return f * length(tp * z - qp * dot(t, fw)) / (z * z);
}

// the turn of layer i: staggered, each eased
float ctLayerTurn(float i, float p, float sd) {
    float o = fract(sd * 5.3) > 0.5 ? i : 3.0 - i;            // top-first or bottom-first
    float q = clamp((p - 0.075 * o) / (1.0 - 0.075 * 3.0), 0.0, 1.0);
    return q * q * q * (q * (q * 6.0 - 15.0) + 10.0);
}

// nearest hit among the four layers: returns the layer index or -1
float ctLayers(vec3 ro, vec3 rd, vec4 cA, vec4 sA, float hy, float hh, float aw, out float tb, out vec3 nb, out vec3 lpb, out vec2 csb) {
    tb = 1e9; nb = vec3(0.0); lpb = vec3(0.0); csb = vec2(1.0, 0.0);
    float li = -1.0;
    for (int i = 0; i < 4; ++i) {
        float yc = -0.5 + (2.0 * float(i) + 1.0) * hy;
        float c = cA[i], s = sA[i];
        vec3 lro = ctToLocal(ro - vec3(0.0, yc, 0.0), c, s), lrd = ctToLocal(rd, c, s);
        float t0;
        vec3 nl;
        if (ctBox(lro, lrd, vec3(aw, hh, aw), t0, nl) && t0 < tb) {
            tb = t0; nb = nl; lpb = lro + lrd * t0; csb = vec2(c, s); li = float(i);
        }
    }
    return li;
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    float e = p * p * p * (p * (p * 6.0 - 15.0) + 10.0);
    float w = sin(3.14159265 * e);
    float ww = w * w;
    float dirS = sd < 0.5 ? 1.0 : -1.0;
    float aw = 0.5 * asp, ah = 0.5;
    float f = 1.7;
    float D = aw + f + 1.15 * w;
    float pit = (0.13 + 0.08 * fract(sd * 7.3)) * ww;
    float sp = sin(pit), cp = cos(pit);
    vec3 ro = vec3(0.0, sp, -cp) * D;
    vec3 fw = vec3(0.0, -sp, cp), up = vec3(0.0, cp, sp);
    vec2 s = vec2((uv.x - 0.5) * asp, 0.5 - uv.y);
    vec3 rd = vec3(s.x, 0.0, 0.0) + up * s.y + fw * f;
    rd /= length(rd);

    // four layers, each turning in its own time, parted by a hair mid-switch
    float hy = ah / 4.0;
    float gap = 0.012 * ww;
    float hh = hy - 0.5 * gap;
    vec4 cA, sA;
    for (int i = 0; i < 4; ++i) {
        float th = dirS * 1.57079633 * ctLayerTurn(float(i), p, sd);
        cA[i] = cos(th); sA[i] = sin(th);
    }

    float beat = 0.6 + 0.8 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    vec3 keyC = suppressGreenCast(palRoleRim(0.25 + 0.3 * sd, u));
    float mx = max(keyC.r, max(keyC.g, keyC.b)), mn = min(keyC.r, min(keyC.g, keyC.b));
    vec3 fillC = vec3(mx + mn) - keyC;               // complementary accent
    keyC = mix(keyC, vec3(mx), 0.35);
    vec3 L = normalize(vec3(-0.5, 0.65, -0.6));

    // backdrop: dark, palette-tinted glow behind the box, mirror floor below
    vec2 hq = s - vec2(0.0, 0.12);
    vec3 bg = keyC * (0.004 + 0.045 * exp(-dot(hq, hq) * 2.6)) + fillC * 0.008 * exp(-dot(s, s) * 0.8);
    vec3 col = bg;
    float t0;
    vec3 nl, lp;
    vec2 csb;
    float li = ctLayers(ro, rd, cA, sA, hy, hh, aw, t0, nl, lp, csb);
    float cov = 0.0;
    vec3 fc = vec3(0.0);
    if (li >= 0.0) {
        float cs = csb.x, sn = csb.y;
        float yc = -0.5 + (2.0 * li + 1.0) * hy;
        float gy = lp.y + yc;                         // height on the whole box
        vec3 nw = ctToWorld(nl, cs, sn);
        float ci = max(-dot(nw, rd), 0.02);
        vec2 fq, fh;                                  // face coordinates and half extents
        if (abs(nl.z) > 0.5) { fq = lp.xy; fh = vec2(aw, hh); }
        else if (abs(nl.x) > 0.5) { fq = lp.zy; fh = vec2(aw, hh); }
        else { fq = lp.xz; fh = vec2(aw, aw); }
        vec2 bd = fh - abs(fq);
        // fade only silhouette borders: those whose neighbouring face looks away
        vec3 nA = abs(nl.z) > 0.5 ? vec3(sign(fq.x), 0.0, 0.0) : (abs(nl.x) > 0.5 ? vec3(0.0, 0.0, sign(fq.x)) : vec3(sign(fq.x), 0.0, 0.0));
        vec3 nB = abs(nl.y) > 0.5 ? vec3(0.0, 0.0, sign(fq.y)) : vec3(0.0, sign(fq.y), 0.0);
        bool shA = dot(ctToWorld(nA, cs, sn), rd) < 0.0;
        bool shB = dot(ctToWorld(nB, cs, sn), rd) < 0.0;
        vec3 tA = abs(nl.x) > 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
        vec3 tB = abs(nl.y) > 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
        vec3 qc = rd * t0;
        float dA = bd.x * ctRate(qc, ctToWorld(tA, cs, sn), up, fw, f) / px;
        float dB = bd.y * ctRate(qc, ctToWorld(tB, cs, sn), up, fw, f) / px;
        // a seam between two layers only fades once the layers have parted
        bool seam = abs(nl.y) < 0.5 && ((fq.y > 0.0 && li < 3.0) || (fq.y < 0.0 && li > 0.0));
        float cB = shB ? 1.0 : clamp(dB + 0.5, 0.0, 1.0);
        if (seam) cB = mix(1.0, cB, clamp(gap / (2.0 * px), 0.0, 1.0));
        cov = (shA ? 1.0 : clamp(dA + 0.5, 0.0, 1.0)) * cB;

        vec3 base;
        vec3 seamC = mix(keyC, fillC, 0.5 + 0.5 * sin(6.2831853 * (li * 0.25 + sd)));
        if (nl.z < -0.5) base = FROM(vec2(lp.x / asp + 0.5, 0.5 - gy));
        else if (abs(nl.x) > 0.5 && nl.x * dirS > 0.0) base = TO(vec2(nl.x * lp.z / asp + 0.5, 0.5 - gy));
        else if (abs(nl.y) > 0.5) {
            // the layer faces inside the seams glow from within
            base = palRoleFog(0.3, u) * 0.03 + seamC * (0.15 + 0.35 * exp(-length(fq) * 2.5)) * ww * (0.7 + 0.3 * beat);
        }
        else base = palRoleFog(0.3, u) * 0.03;          // the box's back faces: dark lacquer
        float n0L = 0.6 * 0.6 + 0.4;
        float lam = (0.4 + 0.6 * max(dot(nw, L), 0.0)) / n0L;
        fc = base * mix(1.0, lam, w);
        float fr = 0.04 + 0.96 * pow(1.0 - ci, 5.0);
        vec3 rr = reflect(rd, nw);
        fc += ctEnv(rr, keyC, fillC) * (0.12 + 0.88 * fr) * (abs(nl.y) > 0.5 ? 0.45 : 0.8) * w;
        // a faint reflection of the new frame in the gloss
        vec2 rq = rr.xy / max(abs(rr.z), 0.3);
        fc += TO(clamp(vec2(0.5 + 0.32 * rq.x, 0.5 - 0.32 * rq.y), 0.0, 1.0)) * (0.05 + 0.4 * fr) * ww;
        // bevelled edges catch a beat-pulsed rim; the seams glow
        float ed = min(dA, dB);
        float rim = exp(-ed / 1.6) + 0.35 * exp(-ed / 9.0);
        fc += mix(keyC, fillC, 0.5 + 0.5 * nw.x) * rim * 0.5 * beat * w;
        if (seam) fc += seamC * exp(-max(dB, 0.0) / 3.0) * 0.5 * ww * beat;
    }
    if (cov < 1.0 && rd.y < 0.0) {
        // mirror floor at the box's base
        float tf = (-ah - ro.y) / rd.y;
        vec3 hp = ro + rd * tf;
        vec3 hl = ctToLocal(hp, cA[0], sA[0]);
        vec2 q = abs(hl.xz) - vec2(aw);
        float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        vec3 rr = vec3(rd.x, -rd.y, rd.z);
        float t2;
        vec3 n2, rp;
        vec2 cs2;
        vec3 refl = vec3(0.0);
        float l2 = ctLayers(hp, rr, cA, sA, hy, hh, aw, t2, n2, rp, cs2);
        if (l2 >= 0.0) {
            float gy2 = rp.y - 0.5 + (2.0 * l2 + 1.0) * hy;
            vec3 rb;
            if (n2.z < -0.5) rb = FROM(vec2(rp.x / asp + 0.5, 0.5 - gy2));
            else if (abs(n2.x) > 0.5 && n2.x * dirS > 0.0) rb = TO(vec2(n2.x * rp.z / asp + 0.5, 0.5 - gy2));
            else rb = vec3(0.0);
            refl = rb * 0.42 * exp(-1.6 * (gy2 + ah));
        }
        float ao = 1.0 - 0.85 * exp(-max(sdf, 0.0) * 5.0);
        vec2 so = hl.xz - vec2(0.18, 0.25);                  // key light shadow, offset away
        vec2 q2 = abs(so) - vec2(aw);
        float sd2 = length(max(q2, 0.0)) + min(max(q2.x, q2.y), 0.0);
        float shd = 1.0 - 0.6 * (1.0 - smoothstep(-0.05, 0.35, sd2));
        float fade = exp(-0.12 * tf);
        vec3 floorC = (bg * 0.5 + refl + keyC * 0.05 * exp(-max(sdf, 0.0) * 2.5) * beat) * ao * shd;
        col = mix(bg, floorC, fade);
    }
    return mix(col, fc, cov);
}
