// SPDX-License-Identifier: AGPL-3.0-only
// Kaleidoscope.
// Looking down a real mirror kaleidoscope. Radial mirrors fold the view into
// segments and a lattice of three mirrors repeats it to the edges of the
// frame. Inside the object chamber a stream of 3D pieces (glass marbles, cut
// cubes, dichroic rings and neon rods) tumbles toward the eyepiece on the
// shared speed profile, so the mirrored mandala blooms outward from every
// cell, cruising, surging and drifting. The pieces are raymarched and lit:
// glass refracts the oil wheel behind it with a little dispersion and darkens
// at its grazing rim, rods burn, dichroic rings shift colour as they turn,
// and every mirror bounce costs a little light, so the pattern dims toward
// the edges as in a real tube. The end of the tube is a backlit oil wheel,
// coloured liquid slowly folding through dark ink, so no mirror cell is ever
// an empty hole. Audio drives light only: the
// spectrum lights single pieces, bass the tube's end light and the rods,
// treble the glints, the beat the glass rims.
// param0 = Segments (radial mirror count, 2..16) ; param1 = Spin ; param2 = Vortex

// Fold into the three-mirror lattice: hexagonal cells of inradius 0.5, each
// folded into twelve mirrored wedges. Returns the point in the base triangle.
// z is the cell centre's distance from the axis, in cells: roughly how many
// mirror bounces the light took to get there.
vec3 kaFold(vec2 q) {
    const vec2 r = vec2(1.0, 1.7320508);
    vec2 a = mod(q, r) - 0.5 * r;
    vec2 b = mod(q - 0.5 * r, r) - 0.5 * r;
    vec2 g = dot(a, a) < dot(b, b) ? a : b;
    float ang = atan2_(g.y, g.x);
    ang = abs(mod(ang + 0.5235988, 1.0471976) - 0.5235988);
    return vec3(length(g) * vec2(cos(ang), sin(ang)), length(q - g));
}

// One chamber piece in its local frame. kind: 0 marble, 1 cut cube,
// 2 dichroic ring, 3 neon rod.
float kaPiece(vec3 q, float kind, float s) {
    if (kind < 0.5) return length(q) - s;
    if (kind < 1.5) {
        vec3 b = abs(q) - vec3(s * 0.62);
        float box = length(max(b, 0.0)) + min(max(b.x, max(b.y, b.z)), 0.0) - s * 0.06;
        // chamfered corners, like a cut stone
        return max(box, (abs(q.x) + abs(q.y) + abs(q.z)) * 0.57735 - s * 0.82);
    }
    if (kind < 2.5) {
        vec2 t = vec2(length(q.xz) - s * 0.7, q.y);
        return length(t) - s * 0.2;
    }
    vec3 c = q;
    c.y -= clamp(c.y, -s * 1.3, s * 1.3);
    return length(c) - s * 0.12;
}

const int KA_N = 12;

// The palette is read once per pixel at its five stops and blended here:
// each library read walks the whole stop table, and a pixel needs a dozen
// colours. kaComp is the hue opposite a colour at the same lightness, the
// warm counterweight to a cool palette (and the reverse).
struct KaPalette { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

KaPalette kaPalLoad(VisualUniforms u) {
    KaPalette P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 kaPal(KaPalette P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

vec3 kaComp(vec3 c) {
    float hi = max(c.r, max(c.g, c.b));
    float lo = min(c.r, min(c.g, c.b));
    return max(vec3(hi + lo) - c, vec3(0.0));
}

// The palette's warmest stop, pushed richer: amber glass and the light in
// the mirror joints. A palette with no warm stop uses the complement of its
// middle stop instead.
vec3 kaWarm(KaPalette P) {
    vec3 w = P.c0;
    if (P.c1.r - P.c1.b > w.r - w.b) w = P.c1;
    if (P.c2.r - P.c2.b > w.r - w.b) w = P.c2;
    if (P.c3.r - P.c3.b > w.r - w.b) w = P.c3;
    if (P.c4.r - P.c4.b > w.r - w.b) w = P.c4;
    w = w.r - w.b > 0.15 ? w : kaComp(P.c2);
    float m = (w.r + w.g + w.b) * 0.3333333;
    return max(vec3(m) + (w - vec3(m)) * 1.6, vec3(0.0));
}

vec3 kaRot(vec3 q, vec4 r) {
    q.xy = vec2(r.x * q.x - r.y * q.y, r.y * q.x + r.x * q.y);
    q.yz = vec2(r.z * q.y - r.w * q.z, r.w * q.y + r.z * q.z);
    return q;
}

// What the chamber looks like in direction d. The end of the tube is a
// backlit oil wheel: coloured liquid folding slowly through dark ink, with
// bright filaments where two colours meet, bass lit and brightest on the
// axis. Glitter sand twinkles on it; coloured light bounces off the walls.
vec3 kaEnv(vec3 d, VisualUniforms u, float T, vec3 ec, KaPalette P, vec3 warm, float detail) {
    vec2 g = d.xy / max(d.z, 0.25);
    float ax = dot(g, g);
    vec2 w = g * 2.6 + vec2(0.035 * T, -0.025 * T);
    float n1 = vnoise(w * 1.2);
    // the second warp axis is a smooth wave at the lowest levels, where the
    // oil fold detail is below a pixel anyway
    float nw = detail > 0.4 ? vnoise(w * 1.1 + vec2(5.2, 1.3) - 0.02 * T)
                            : 0.5 + 0.5 * sin(w.x * 1.9 - w.y * 1.4 + 2.0 * n1 - 0.02 * T);
    vec2 wp = w * 2.0 + 1.5 * vec2(n1, nw);
    float n2 = vnoise(wp);
    float ink = smoothstep(0.5, 0.68, n2);
    float fil = 1.0 - abs(2.0 * n2 - 1.0);
    fil *= fil; fil *= fil; fil *= fil;
    vec3 hc = kaPal(P, 0.1 + 1.3 * n1 + 0.012 * T);
    float back = (0.0015 + 0.022 * exp(-ax * 2.0)) * (0.75 + 0.5 * u.bassImpact);
    // the ink in the cool palette, the filaments where two inks meet in the
    // warm complement, so the backdrop of every cell holds two hue families
    vec3 col = (hc * hc * ink * 1.2 + warm * fil * 0.5) * back;
    // the lamp behind the frosted end: a small white-hot heart in the warm
    // colour inside a tighter cool halo, so each cell centre reads as a
    // light source rather than a haze
    col += (peakWhite(warm, 0.5) * exp(-ax * 500.0) * 1.1 + ec * (exp(-ax * 60.0) * 0.16 + exp(-ax * 14.0) * 0.008)) * (0.6 + 0.8 * u.bassImpact);
    col *= smoothstep(-0.1, 0.4, d.z);
    // glitter sand lying on the frosted glass, twinkling with the treble
    vec2 gq = g * 14.0;
    vec2 gi = floor(gq);
    vec2 gh = hash22(gi + 17.0);
    vec2 go = gq - gi - 0.2 - 0.6 * gh;
    float gl = exp(-dot(go, go) * 600.0) * step(0.6, gh.y) * smoothstep(0.2, 0.6, d.z);
    if (gl > 0.002) {
        float tw = 0.5 + 0.5 * sin(T * (1.0 + 2.0 * gh.x) + gh.y * 6.2831853);
        col += mix(kaPal(P, gh.x), warm, step(0.8, gh.y)) * gl * (0.2 + 1.6 * u.treble) * tw;
    }
    float wa = atan2_(d.y, d.x) * 0.4774648 + 0.02 * T;
    float wk = exp(-max(d.z, 0.0) * 6.0) * smoothstep(-1.0, 0.0, d.z);
    if (wk > 0.003 && detail > 0.3) {
        vec3 wall = kaPal(P, wa) * (0.5 + 0.5 * cos(wa * 18.8495559));
        col += wall * wall * 0.3 * wk;
    }
    return col;
}

// The same chamber reduced to its light: the end glow and the walls, for
// the faint mirror images in the glass where the oil detail is lost anyway.
vec3 kaEnvLite(vec3 d, vec3 ec, VisualUniforms u) {
    vec2 g = d.xy / max(d.z, 0.25);
    float ax = dot(g, g);
    vec3 col = ec * (exp(-ax * 80.0) * 0.4 + exp(-ax * 12.0) * 0.015) * (0.6 + 0.8 * u.bassImpact);
    col *= smoothstep(-0.1, 0.4, d.z);
    float wa = atan2_(d.y, d.x) * 0.4774648;
    float wk = 0.5 + 0.5 * cos(wa * 18.8495559);
    col += ec * ec * wk * wk * 0.3 * exp(-max(d.z, 0.0) * 6.0) * smoothstep(-1.0, 0.0, d.z);
    return col;
}

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float KA_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 kaFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * KA_RUN[32] + KA_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float T = mod(u.time, 600.0);
    float nSeg = max(floor(mix(2.0, 16.0, u.param0) + 0.5), 2.0);
    float spin = mix(0.2, 1.8, u.param1);
    float vortex = u.param2;
    float pix = 2.0 / u.resolution.y;
    KaPalette P = kaPalLoad(u);
    vec3 ec = P.c2;
    // the warm counterweight drifts between the complements of two stops
    vec3 warm = kaWarm(P);

    vec2 fl = kaFlight(u, 1.0, 0.5);

    // slow eased turn of the whole tube, never driven by audio
    p = rot2(0.012 * spin * T + osBank(u, 0.15)) * p;
    float r = length(p);
    p *= 1.0 + 0.04 * r * r;                            // a touch of lens barrel
    p = rot2(vortex * 0.5 * log(1.0 + 1.6 * r)) * p;    // the vortex twist

    // radial mirrors, then the three-mirror lattice
    float wedge = 3.14159265 / nSeg;
    float pa = atan2_(p.y, p.x);
    pa = abs(mod(pa + wedge, 2.0 * wedge) - wedge);
    vec2 pm = length(p) * vec2(cos(pa), sin(pa));
    vec3 fz = kaFold(pm * 0.8);
    vec2 f = fz.xy;

    // a ray into the object chamber through this point of the base triangle
    // the cell centre looks straight down the tube axis, at the end light
    vec3 rd = normalize(vec3(f * 1.05, 1.0));

    // the stream of pieces: each slot flies from the far end to the lens,
    // then returns far away in a new place
    float flow = fl.x * 0.08;
    vec4 pc[KA_N];     // centre, size
    vec4 pr[KA_N];     // two rotations as cos/sin pairs
    vec4 pk[KA_N];     // kind, hue, spectrum position, grow
    int hl[4];          // the pieces in this ray's way, at most four
    vec2 hs[4];         // and where along the ray each one's bounds lie
    hl[0] = 0; hl[1] = 0; hl[2] = 0; hl[3] = 0;
    hs[0] = vec2(0.0); hs[1] = vec2(0.0); hs[2] = vec2(0.0); hs[3] = vec2(0.0);
    int nh = 0;
    float t0 = 9.0, t1 = 0.0;
    vec3 glow = vec3(0.0);
    float rodLvl = 0.3 + 0.7 * u.level;
    float cr = spin * (0.05 * T + 0.02 * fl.x);
    for (int i = 0; i < KA_N; i++) {
        float fi = float(i);
        float cyc = flow + fi / float(KA_N);
        float ph = fract(cyc);
        float pass = mod(floor(cyc), 61.0);
        vec2 h = hash22(vec2(fi * 7.13 + pass * 1.37, fi * 3.1 + pass * 0.71));
        float z = mix(6.0, 0.9, ph);
        // turning about the axis, folded into the mirrors' 30-degree wedge
        // (only what lies inside it is seen, mirrored into the whole cell);
        // a piece crossing a mirror meets its own image there; the vortex
        // makes them spiral in
        float ang = h.x * 6.2831853 + cr + vortex * 0.3 * z;
        ang = abs(mod(ang + 0.5235988, 1.0471976) - 0.5235988);
        float rad = z * 0.6 * sqrt(0.02 + 0.98 * h.y);
        float s = (0.12 + 0.12 * hash11(fi * 1.7 + pass)) * (0.55 + 0.12 * z);
        pc[i] = vec4(rad * cos(ang), rad * sin(ang), z, s);
        float kind = mod(fi + pass, 4.0);
        float hue = fract(h.x * 0.5 + fi * 0.137 + 0.01 * T);
        // grow in out of the dark, and slip away before reaching the lens
        pk[i] = vec4(kind, hue, fract(0.06 + fi * 0.103 + 0.3 * h.y), smoothstep(0.0, 0.12, ph) * (1.0 - smoothstep(0.8, 1.0, ph)));
        pr[i] = vec4(1.0, 0.0, 1.0, 0.0);

        // can this ray meet the piece at all? Bounding spheres keep the
        // march to the one or two pieces in its way; the neon rods' halos
        // are taken from the ray's closest approach
        float b = dot(pc[i].xyz, rd);
        float d2 = max(dot(pc[i].xyz, pc[i].xyz) - b * b, 0.0);
        float R = pc[i].w * 1.45;
        if (d2 < R * R && b > 0.0) {
            float hc = sqrt(R * R - d2);
            t0 = min(t0, b - hc);
            t1 = max(t1, b + hc);
            float a1 = T * (0.25 + 0.2 * h.y) + h.x * 6.0;
            float a2 = T * (0.18 + 0.15 * h.x) + h.y * 6.0;
            pr[i] = vec4(cos(a1), sin(a1), cos(a2), sin(a2));
            if (nh < 4) { hl[nh] = i; hs[nh] = vec2(b - hc, b + hc); nh++; }
        }
        float gk = exp(-d2 / (pc[i].w * pc[i].w) * 6.0) * pk[i].w * step(0.0, b);
        if (pk[i].x > 2.5 && gk > 0.002) {
            glow += kaPal(P, pk[i].y) * (0.05 + 0.25 * rodLvl + 0.1 * u.bassImpact) * gk;
        }
    }

    // march only the pieces whose bounds hold the current point, and jump
    // the gaps between them, so no step is spent on empty chamber
    int steps = osSteps(12.0, 24.0, detail);
    float t = max(t0, 0.3);
    float dm = 1e3;
    int hid = -1;
    if (t1 > t) {
        for (int sI = 0; sI < 24; sI++) {
            if (sI >= steps) break;
            vec3 pos = rd * t;
            dm = 1e3;
            float nxt = 1e3;
            for (int j = 0; j < 4; j++) {
                if (j >= nh) break;
                vec2 iv = hs[j];
                if (t < iv.x) { nxt = min(nxt, iv.x); continue; }
                if (t > iv.y) continue;
                int i = hl[j];
                float d = kaPiece(kaRot(pos - pc[i].xyz, pr[i]), pk[i].x, pc[i].w * pk[i].w);
                if (d < dm) { dm = d; hid = i; }
            }
            if (dm > 1e2) {
                if (nxt > 1e2) break;
                t = nxt;
                continue;
            }
            if (dm < 0.0015 * t) break;
            t = min(t + dm * 0.9, max(nxt, t + 1e-4));
            if (t > t1) break;
        }
    }

    float la = 0.09 * T;
    vec3 L = normalize(vec3(cos(la), sin(la), -0.7));
    vec3 col = vec3(0.0);
    vec3 fogCol = mix(P.c1, P.c2, 0.7) * 0.01;

    bool onPiece = dm < 0.0015 * t + 0.003 && hid >= 0;
    if (!onPiece) col = kaEnv(rd, u, T, ec, P, warm, detail);
    if (onPiece) {
        vec3 pos = rd * t;
        vec4 c0 = vec4(0.0, 0.0, 1.0, 0.3), r0 = vec4(1.0, 0.0, 1.0, 0.0), m0 = vec4(0.0);
        for (int i = 0; i < KA_N; i++) {
            if (i == hid) { c0 = pc[i]; r0 = pr[i]; m0 = pk[i]; }
        }
        // normal of the hit piece from a four-tap tetrahedron in its local frame
        vec3 q = kaRot(pos - c0.xyz, r0);
        float sz = c0.w * m0.w;
        const vec2 e = vec2(0.002, -0.002);
        vec3 nl = e.xyy * kaPiece(q + e.xyy, m0.x, sz) + e.yyx * kaPiece(q + e.yyx, m0.x, sz)
                + e.yxy * kaPiece(q + e.yxy, m0.x, sz) + e.xxx * kaPiece(q + e.xxx, m0.x, sz);
        nl /= max(length(nl), 1e-6);
        // back to the chamber frame (inverse rotations, in reverse order)
        nl.yz = vec2(r0.z * nl.y + r0.w * nl.z, -r0.w * nl.y + r0.z * nl.z);
        vec3 n = vec3(r0.x * nl.x + r0.y * nl.y, -r0.y * nl.x + r0.x * nl.y, nl.z);

        // every fourth slot turns warm: amber glass among the cool pieces
        vec3 gc = mod(float(hid), 4.0) > 2.5 ? warm : kaPal(P, m0.y);
        float lvl = bandAt(u, m0.z);
        float light = 0.6 + 1.4 * lvl;
        float ndv = saturate(-dot(n, rd));
        float fres = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
        vec3 rf = reflect(rd, n);
        float spec = pow(saturate(dot(rf, L)), 120.0);
        // the mirror walls fold reflections back toward the end light
        vec3 env = kaEnvLite(vec3(rf.xy, abs(rf.z)), ec, u);
        vec3 sc;
        if (m0.x < 1.5) {
            // glass: the oil wheel seen through it, bent, split a little by
            // dispersion and tinted by the glass, deeper where it is thick;
            // the grazing rim turns dark as it mirrors the tube wall
            // Beer absorption: the longer the path, the deeper the colour
            vec3 tint = exp(-(1.0 - min(gc, vec3(0.97))) * (1.6 + 1.4 / max(ndv, 0.25))) * 1.7;
            // the scene behind sits close, so it shifts across the face
            vec2 par = (pos.xy - c0.xy) / max(c0.w, 1e-3) * 0.4;
            vec3 rr = refract(rd, n, 0.66);
            rr = dot(rr, rr) > 0.01 ? rr : rf;
            vec3 rrd = normalize(vec3(rr.xy * 1.3 + par, rr.z));
            vec3 back = kaEnv(rrd, u, T, ec, P, warm, detail) * 7.0;
            float rim = smoothstep(0.0, 0.35, ndv);
            // the frosted end glows behind every piece of glass, focused
            // to a bright heart where the face looks down the axis; blue
            // bends more than red, so the heart splits into a fringe
            float bl = exp(-dot(rrd.xy, rrd.xy) / max(rrd.z * rrd.z, 0.05) * 3.5);
            vec3 blc = vec3(bl);
            if (detail > 0.5) {
                vec3 rb = refract(rd, n, 0.62);
                rb = dot(rb, rb) > 0.01 ? rb : rf;
                vec3 rbd = normalize(vec3(rb.xy * 1.3 + par * 1.06, rb.z));
                float bb = exp(-dot(rbd.xy, rbd.xy) / max(rbd.z * rbd.z, 0.05) * 3.5);
                blc = vec3(bl, 0.5 * (bl + bb), bb);
            }
            back += 0.11 * blc * blc + 0.006;
            sc = tint * (back * 3.2 + 0.03) * light * (1.0 - fres) * (0.25 + 0.75 * rim);
            sc += env * fres * 1.2 + peakWhite(gc, 0.85) * spec * (1.5 + 3.0 * u.treble);
            // the backlight focused through the glass: a soft caustic heart
            sc += tint * pow(ndv, 6.0) * (0.08 + 0.25 * u.beat) * light;
            vec3 aq = abs(q) / max(sz * 0.62, 1e-3);
            if (m0.x > 0.5) {
                // cut stone: light gathers in the edges and the chamfers
                float mid = max(min(aq.x, aq.y), min(max(aq.x, aq.y), aq.z));
                float edge = smoothstep(0.8, 0.97, mid);
                sc += peakWhite(gc, 0.4) * edge * (0.25 + 1.0 * lvl + 0.6 * u.beat) * (0.3 + 0.7 * fres + 0.4 * ndv);
            } else {
                // marble: a twisted ribbon of colour glows inside
                float w = q.x * 0.8 + q.z * 0.6 + 0.35 * sin(q.y / max(sz, 1e-3) * 3.0);
                float rib = exp(-w * w / max(sz * sz, 1e-4) * 22.0);
                vec3 rc = kaPal(P, m0.y + 0.5);
                sc += rc * rc * rib * (0.3 + 1.6 * lvl) * (0.3 + 0.7 * ndv) * rim;
            }
        } else if (m0.x < 2.5) {
            // dichroic glass: its colour shifts with the viewing angle
            vec3 dc = kaPal(P, m0.y + 0.35 * ndv + 0.4 * fres);

            dc *= dc * 1.3;
            sc = dc * (0.06 + 0.3 * ndv * ndv + 1.4 * fres) * light + env * dc * 1.5
               + peakWhite(dc, 0.9) * spec * (1.5 + 3.0 * u.treble);
        } else {
            // neon rod: emissive, hotter in its core
            sc = gc * gc * (1.2 + 2.6 * lvl + 0.8 * u.bassImpact) * (0.4 + 0.6 * ndv) + peakWhite(gc, 0.3) * ndv * ndv * 0.6;
        }
        float fogA = 1.0 - exp(-t * 0.18);
        col = mix(sc, fogCol, fogA);
    }
    col += glow;
    // every mirror bounce loses a little light; the joints between the
    // mirrors show as faint dark seams
    col *= pow(0.9, fz.z);
    float seam = min(f.y, 0.5 - f.x);
    seam = min(seam, abs(f.y - f.x * 0.5773503) * 0.8660254);
    col *= 0.82 + 0.18 * smoothstep(0.0, pix * 1.6 + 0.002, seam);
    // the mirror joints catch light: each beat sends a warm front out from
    // the axis across the cells, lighting the joints as it passes, and the
    // bass keeps a faint glow in them between beats. Thin lines only, so
    // the frame as a whole never flashes.
    float bp = saturate(u.beatPhase);
    float front = 0.1 + 2.0 * sqrt(bp);
    float wave = exp(-(r - front) * (r - front) * 40.0) * (1.0 - bp) * (1.0 - bp) * (0.5 + 0.7 * u.amplitude);
    float line = exp(-seam / (pix * 1.2 + 1e-4)) + 0.15 * exp(-seam * 60.0);
    col += warm * line * (0.006 + 0.03 * u.bassImpact + 0.9 * wave);


    col *= 1.0 - 0.4 * smoothstep(0.7, 1.8, r);
    return col; // LINEAR HDR — post chain tonemaps
}
