// SPDX-License-Identifier: AGPL-3.0-only
// Photo prism.
// A glass iris hangs in front of the photo like a macro product shot. Twelve
// thick wedge prisms ring a crystal ball lens, each at its own depth and each
// turning on its own radial axis, so waves of turning glass run round the
// ring. Through every prism the photo is shifted, magnified and split into a
// spectral rainbow, so the frame fractures into displaced copies that slide as
// the glass turns; between the prisms the photo sits dark and deep behind.
// The ball lens shows the photo inverted and magnified with chromatic edges,
// ringed by a glowing circular waveform. Softbox reflections sweep across the
// faces and the bevels catch light. The turning wave and the slow ring spin
// follow the shared 32-beat speed profile; audio drives the light, the
// waveform ring and the dispersion.
// param0 = Shard Spin ; param1 = Refraction ; param2 = Glow

const float PP_TAU = 6.2831853;
const float PP_K = 12.0;     // prisms in the ring
const float PP_ZP = 1.6;     // photo plane depth behind the ring
const float PP_RB = 0.80;    // crystal ball radius
const float PP_R0 = 1.30;    // inner end of the prisms
const float PP_R1 = 8.0;     // outer end of the prisms
const float PP_TH = 0.045;    // prism half thickness

// The palette, read at four of its stops per pixel and interpolated round a
// colour wheel (the music turns the wheel).
// Each palette read copies the palette table on some targets, so every colour
// below comes from these four samples instead of its own read.
vec3 ppPal(float t, vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
    float x = fract(t) * 4.0;
    float i = floor(x);
    float f = smoothstep(0.0, 1.0, x - i);
    vec3 a = i < 1.0 ? c0 : (i < 2.0 ? c1 : (i < 3.0 ? c2 : c3));
    vec3 b = i < 1.0 ? c1 : (i < 2.0 ? c2 : (i < 3.0 ? c3 : c0));
    return mix(a, b, f);
}
#define PPAL(t) ppPal(t, pc0, pc1, pc2, pc3)
// the rim role (a palette hue lifted toward its peak on hits)
#define PPRIM(t) mix(PPAL(t), peakWhite(PPAL((t) + 0.18), saturate(u.onset * 0.18 + u.bassImpact * 0.10)), 0.35 + 0.35 * u.flux)

// mirrored repeat, so refracted samples never hit a hard image edge
vec2 ppMirror(vec2 x) { return 1.0 - abs(1.0 - mod(x, 2.0)); }

// The photo's own key colour: nine fixed taps averaged. The taps do not
// depend on the pixel, so every pixel agrees and the cost is tiny.
vec3 ppKey(VisualUniforms u) {
    vec3 s = vec3(0.0);
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        vec2 g = vec2(mod(fi, 3.0), floor(fi / 3.0)) * 0.3 + 0.2;
        s += max(IMG(photoCover(g, u.resolution, IMGSIZE)).rgb, vec3(0.0));
    }
    return s / 9.0;
}

// An accent complementary to the photo: the palette stop whose hue sits
// furthest from the photo's key, pushed toward the key's true complement
// (the more colourful the photo, the harder the push).
vec3 ppAccent(vec3 key, vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
    vec3 kc = key - vec3(luma(key));
    float ks = length(kc);
    vec3 kn = kc / max(ks, 1e-4);
    vec3 best = c0;
    float bd = dot(c0 - vec3(luma(c0)), kn) / max(length(c0 - vec3(luma(c0))), 1e-4);
    float d1 = dot(c1 - vec3(luma(c1)), kn) / max(length(c1 - vec3(luma(c1))), 1e-4);
    float d2 = dot(c2 - vec3(luma(c2)), kn) / max(length(c2 - vec3(luma(c2))), 1e-4);
    float d3 = dot(c3 - vec3(luma(c3)), kn) / max(length(c3 - vec3(luma(c3))), 1e-4);
    if (d1 < bd) { best = c1; bd = d1; }
    if (d2 < bd) { best = c2; bd = d2; }
    if (d3 < bd) { best = c3; bd = d3; }
    vec3 comp = max(vec3(0.33) - kn * 0.75, vec3(0.0));
    vec3 a = mix(best, comp * 1.6, saturate(ks * 6.0) * 0.6);
    return a / max(max(a.r, max(a.g, a.b)), 0.05);
}

// The photo plane: q in world units, the frame spans about +-2.9 vertically.
// Graded for deep blacks: a contrast curve and a touch more saturation.
vec3 ppPhoto(vec2 q, float aspect, VisualUniforms u) {
    vec2 s = vec2(0.5 + 0.5 * q.x / (2.9 * aspect), 0.5 - 0.5 * q.y / 2.9);
    vec3 c = max(IMG(photoCover(ppMirror(s), u.resolution, IMGSIZE)).rgb, vec3(0.0));
    c = c * c * 1.25;
    return max(mix(vec3(luma(c)), c, 1.3), vec3(0.0));
}

// spectral weight of wavelength position w (0 red .. 1 violet)
vec3 ppSpectrum(float w) {
    return max(vec3(1.0 - abs(w - 0.10) * 2.4, 1.0 - abs(w - 0.5) * 2.6, 1.0 - abs(w - 0.90) * 2.4), vec3(0.0));
}

// Studio environment seen in reflections: a key softbox, a thin strip light
// and a coloured floor bounce, all crisp so they read as specular streaks.
vec3 ppEnv(vec3 r, float turn, vec3 top, vec3 floorA, vec3 floorB) {
    vec2 q = rot2(turn) * (r.xy / max(-r.z, 0.25));   // light cards, slowly orbiting
    float s1 = (q.x + 0.62) * 9.0;
    float s2 = (q.x - 0.70) * 12.0;
    float s3 = (q.y - 0.68) * 10.0;
    float tall = smoothstep(1.6, 0.6, abs(q.y));
    float wide = smoothstep(1.8, 0.8, abs(q.x));
    vec3 c = vec3(1.0, 0.95, 0.88) * exp(-s1 * s1) * tall * 3.2
           + vec3(0.82, 0.90, 1.0) * exp(-s2 * s2) * tall * 2.6
           + vec3(1.0, 0.97, 0.93) * exp(-s3 * s3 * 2.0) * wide * 1.4;
    c *= vec3(1.0, 1.0, 1.0) * 0.8;
    c += top * 0.05 * smoothstep(-0.2, 1.2, q.y);
    c += mix(floorA, floorB, saturate(0.5 + 0.5 * q.x)) * smoothstep(-0.2, -1.0, q.y) * 0.55;
    return c;
}

// Ray against a thick wedge prism, in the prism's local frame (x radial,
// y across, z through). Returns the entry distance or -1, and the local
// entry normal.
float ppWedge(vec3 o, vec3 d, float a, float r0, out vec3 nl) {
    float tn = -1e9, tf = 1e9;
    nl = vec3(0.0, 0.0, -1.0);
    float na = inversesqrt(1.0 + a * a);
    for (int i = 0; i < 6; i++) {
        vec3 N; float c;
        if (i == 0) { N = vec3(0.0, 0.0, 1.0); c = -PP_TH; }
        else if (i == 1) { N = vec3(0.0, 0.0, -1.0); c = -PP_TH; }
        else if (i == 2) { N = vec3(-a, 1.0, 0.0) * na; c = 0.0; }
        else if (i == 3) { N = vec3(-a, -1.0, 0.0) * na; c = 0.0; }
        else if (i == 4) { N = vec3(-1.0, 0.0, 0.0); c = r0; }
        else { N = vec3(1.0, 0.0, 0.0); c = -PP_R1; }
        float f = dot(N, o) + c;
        float g = dot(N, d);
        if (abs(g) < 1e-6) {
            if (f > 0.0) return -1.0;
            continue;
        }
        float t = -f / g;
        if (g < 0.0) {
            if (t > tn) { tn = t; nl = N; }
        } else {
            tf = min(tf, t);
        }
    }
    if (tn > tf || tf <= 0.0 || tn <= 0.0) return -1.0;
    return tn;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    float detail = osDetail(u);
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;                                  // y up
    float t = mod(u.time, 600.0);

    float spinAmt = mix(0.35, 1.5, u.param0);
    float refr = mix(0.4, 1.5, u.param1);
    float glow = mix(0.5, 1.6, u.param2);

    // turning wave and ring spin follow the speed profile; wrapped so every
    // use below is periodic over the wrap
    vec2 fl = osFlight(u, spinAmt, 0.25 * spinAmt);
    float dw = mod(fl.x, PP_TAU * 20.0);
    float rush = saturate((fl.y - 1.0) / 3.5);
    float spin = dw * 0.07;
    // the iris opens on builds and breathes with the bass
    float irisR = PP_R0 + 0.45 * rush + 0.12 * u.bassImpact;
    // the palette walks round the wheel with the music and jumps ahead on builds
    float bc = u.beatCount + saturate(u.beatPhase);
    float hueOff = mod(bc, 256.0) * (0.137 / 16.0) + 0.12 * rush;
    // a light chase runs round the ring, a prism and a half per beat
    float cpos = mod(bc * 1.5, PP_K);
    float kick = exp(-4.0 * saturate(u.beatPhase));
    vec3 pc0 = palVisual(0.02, u);
    vec3 pc1 = palVisual(0.34, u);
    vec3 pc2 = palVisual(0.62, u);
    vec3 pc3 = palVisual(0.97, u);
    // the photo's key and an accent complementary to it
    vec3 key = ppKey(u);
    vec3 accent = ppAccent(key, pc0, pc1, pc2, pc3);
    vec3 envTop = PPAL(hueOff + 0.6);
    vec3 envA = accent;
    vec3 envB = PPRIM(0.50 + hueOff);
    float lightTurn = -dw * 0.1;

    // camera: slow drift for parallax between glass and photo, never audio
    float w1 = PP_TAU * 9.0 / 600.0;
    float w2 = PP_TAU * 7.0 / 600.0;
    float w3 = PP_TAU * 5.0 / 600.0;
    vec3 ro = vec3(0.75 * sin(t * w1), 0.45 * sin(t * w2 + 1.3), -3.3 + 0.35 * sin(t * w3 + 0.4));
    vec3 rd = osCamera(ro, vec3(0.0), osBank(u, 0.07), 1.65, p);

    // the ring plane z = 0 picks the candidate prisms
    float tz = -ro.z / max(rd.z, 1e-3);
    vec3 h0 = ro + rd * tz;
    float r0 = length(h0.xy);
    float ang = atan2_(h0.y, h0.x);
    float sector = floor((ang - spin) / PP_TAU * PP_K);
    float wa = tan(3.14159265 / PP_K) * 0.97;

    float bestT = 1e9;
    vec3 bN = vec3(0.0), bW = vec3(0.0), bH = vec3(0.0), bNL = vec3(0.0);
    float bS = 0.0, bR = 0.0, bTh = 0.0, bId = 0.0;
    for (int j = -1; j <= 1; j++) {
        float idx = mod(sector + float(j), PP_K);
        float phi0 = (idx + 0.5) * PP_TAU / PP_K;
        float phi = phi0 + spin;
        float hb = hash11(idx * 7.13 + 1.7);
        // a two-lobed wave runs round the ring; each prism turns on its radial axis
        float th = (0.60 + 0.35 * rush) * sin(dw - phi0 * 2.0 + hb * 0.6)
                 + 0.22 * sin(dw * 0.35 + idx * 2.1);
        vec3 er = vec3(cos(phi), sin(phi), 0.0);
        vec3 et = vec3(-sin(phi), cos(phi), 0.0);
        vec3 wv = cos(th) * et + vec3(0.0, 0.0, sin(th));
        vec3 n = cos(th) * vec3(0.0, 0.0, 1.0) - sin(th) * et;
        vec3 c = vec3(0.0, 0.0, 0.9 * (hb - 0.5));
        vec3 o = ro - c;
        vec3 ol = vec3(dot(o, er), dot(o, wv), dot(o, n));
        vec3 dl = vec3(dot(rd, er), dot(rd, wv), dot(rd, n));
        vec3 nl;
        float tt = ppWedge(ol, dl, wa, irisR, nl);
        if (tt > 0.0 && tt < bestT) {
            vec3 hl = ol + dl * tt;
            bestT = tt;
            bNL = nl;
            bN = nl.x * er + nl.y * wv + nl.z * n;
            bW = wv; bH = ro + rd * tt; bS = hl.y / max(hl.x * wa, 1e-3);
            bR = hl.x; bTh = th; bId = idx;
        }
    }

    int ns = osSteps(3.0, 7.0, detail);
    float fns = float(ns);
    vec3 col;
    float tp = (PP_ZP - ro.z) / max(rd.z, 1e-3);
    vec2 qDirect = (ro + rd * tp).xy;

    // crystal ball
    float bb = dot(ro, rd);
    float bh = bb * bb - (dot(ro, ro) - PP_RB * PP_RB);
    float tBall = bh > 0.0 ? -bb - sqrt(bh) : -1.0;

    if (bestT < 1e8 && (tBall < 0.0 || bestT < tBall)) {
        // ---- through a prism: shifted, magnified, dispersed ----
        float hb = hash11(bId * 3.71 + 0.3);
        float sgn = mod(bId, 2.0) < 0.5 ? 1.0 : -1.0;
        float bnd = bandAt(u, bId / (PP_K - 1.0));
        bool side = abs(bNL.z) < 0.5;            // entered through a bevel face
        vec2 off = bW.xy * refr * (sgn * (0.35 + 0.30 * hb) + 0.30 * bS)
                 + normalize(bH.xy + vec2(1e-4)) * refr * 0.20 * sin(bTh);
        float disp = refr * (0.12 + 0.12 * u.bassImpact + 0.08 * rush) * (side ? 4.0 : 1.0);
        float tq = (PP_ZP - bH.z) / max(rd.z, 1e-3);
        vec2 qb = (bH + rd * tq).xy;
        vec3 acc = vec3(0.0), ws = vec3(0.0);
        for (int i = 0; i < 7; i++) {
            if (i >= ns) break;
            float wl = (float(i) + 0.5) / fns;
            vec3 sw = ppSpectrum(wl);
            vec2 q = qb + off * (1.0 + disp * (wl - 0.5) * 2.0);
            acc += ppPhoto(q, aspect, u) * sw;
            ws += sw;
        }
        vec3 trans = acc / max(ws, vec3(1e-4));
        // each prism grades the photo into its own duotone: shadows in one
        // palette hue, highlights in the opposite one, so the ring reads as a
        // colour wheel of glass and every copy of the photo has its own light
        float hk = bId / PP_K + hueOff;
        float L = luma(trans);
        // a light split-tone keeps the photo itself readable: shadows sink
        // to black, highlights take the prism's palette hue
        vec3 duo = L * (0.2 + 1.7 * L) * mix(PPAL(hk), PPAL(hk + 0.17) * 1.15, smoothstep(0.04, 0.5, L));
        float dc = abs(mod(bId - cpos + 0.5 * PP_K, PP_K) - 0.5 * PP_K);
        float chase = exp(-dc * dc * 0.9);
        // the chased prism clears to the true photo
        trans = mix(trans, duo, (0.42 + 0.2 * rush) * (1.0 - 0.8 * chase));
        trans = max(mix(vec3(luma(trans)), trans, 1.45), vec3(0.0)) * smoothstep(0.0, 0.16, L);
        trans /= 1.0 + 0.45 * luma(trans);     // soft shoulder keeps highlights coloured
        trans *= 0.70 + chase * (0.45 + 0.8 * kick * u.beat + 0.4 * u.bass);

        vec3 n = bN * (dot(rd, bN) > 0.0 ? -1.0 : 1.0);
        float ci = saturate(-dot(rd, n));
        float fres = 0.04 + 0.96 * pow(1.0 - ci, 5.0);
        vec3 refl = ppEnv(reflect(rd, n), lightTurn, envTop, envA, envB);
        col = trans * (1.0 - fres) * (0.70 + 0.30 * abs(cos(bTh))) + refl * fres * 0.55;

        vec3 rim = mix(PPAL(bId / PP_K + hueOff + 0.5 + 0.2 * bS), accent * 1.4, 0.45 + 0.45 * chase);
        float lit = 0.06 + 1.2 * bnd + 0.4 * u.bassImpact + 1.6 * chase;
        if (side) {
            // the slab's thickness: a lit, rainbow-split glass edge
            col = col * 0.35 + rim * glow * min(lit, 1.4);
        } else {
            // light from the iris piped down the glass: an inner glow that
            // fades along the prism and a bright caustic band that slides
            // outward with every beat
            float rr = bR - irisR;
            float band = exp(-pow((rr - 6.5 * saturate(u.beatPhase)) * 1.6, 2.0)) * u.beat;
            vec3 pipe = PPAL(hk + 0.5);
            col += pipe * pipe * glow * (exp(-rr * 1.1) * (0.05 + 0.45 * bnd + 0.6 * chase)
                                       + band * (0.25 + 0.6 * chase) * (1.0 - 0.5 * abs(bS)));
            // a fine lit line where the face meets the bevel
            float e = min((1.0 - abs(bS)) * bR * wa, (bR - irisR));
            float line = 1.0 - smoothstep(0.0, 0.010 + 0.004 * bR, e);
            col += mix(rim, vec3(1.0), 0.3) * line * glow * (0.3 + lit);
            // spectral fringe just inside the edge
            float fr = exp(-e * 34.0) * (1.0 - line);
            col += ppSpectrum(fract(e * 6.0 + bId * 0.13)) * fr * glow * (0.15 + 0.8 * bnd) * refr;
        }
    } else if (tBall > 0.0) {
        // ---- the crystal ball: the photo inverted and magnified ----
        vec3 p1 = ro + rd * tBall;
        vec3 n1 = p1 / PP_RB;
        int nl = osSteps(3.0, 5.0, detail);
        vec3 acc = vec3(0.0), ws = vec3(0.0);
        for (int i = 0; i < 5; i++) {
            if (i >= nl) break;
            float wl = (float(i) + 0.5) / float(nl);
            vec3 sw = ppSpectrum(wl);
            float eta = 1.52 + (0.5 - wl) * 0.05 * refr;
            vec3 d1 = refract(rd, n1, 1.0 / eta);
            float t2 = -2.0 * dot(p1, d1);
            vec3 p2 = p1 + d1 * max(t2, 0.0);
            vec3 d2 = refract(d1, -p2 / PP_RB, eta);
            vec3 c = vec3(0.0);
            if (d2.z > 0.05) {
                // the ball looks at a deeper virtual plane, so it shows a
                // wide inverted view of the photo rather than a blur
                vec3 p3 = p2 + d2 * ((5.0 - p2.z) / d2.z);
                c = ppPhoto(p3.xy * 0.62, aspect, u);
            }
            acc += c * sw;
            ws += sw;
        }
        vec3 ball = acc / max(ws, vec3(1e-4));
        ball = ball * 0.85 / (1.0 + 0.6 * ball);
        float Lb = luma(ball);
        ball = mix(ball, Lb * (0.2 + 1.6 * Lb) * mix(PPAL(hueOff + 0.62), PPAL(hueOff + 0.80) * 1.8, smoothstep(0.05, 0.5, Lb)), 0.3);
        ball = max(mix(vec3(luma(ball)), ball, 1.25), vec3(0.0)) * smoothstep(0.0, 0.14, Lb);
        float ci = saturate(-dot(rd, n1));
        float fres = 0.04 + 0.96 * pow(1.0 - ci, 5.0);
        ball = ball * (1.0 - fres) + ppEnv(reflect(rd, n1), lightTurn, envTop, envA, envB) * fres * 1.4;
        ball += accent * pow(1.0 - ci, 3.0) * glow * (0.35 + 0.7 * u.bass + 0.8 * kick * u.beat);
        col = ball;
    } else {
        // ---- the photo deep behind, seen between the prisms ----
        col = luma(ppPhoto(qDirect, aspect, u)) * mix(PPAL(hueOff + 0.62), accent, 0.5) * 0.03;
        // light split by the prisms fans across the dark gaps as rainbow rays
        float g = fract((ang - spin) / PP_TAU * PP_K + 0.5) - 0.5;
        float gi = mod(floor((ang - spin) / PP_TAU * PP_K + 0.5), PP_K);
        float gb = bandAt(u, gi / (PP_K - 1.0));
        vec2 dirn = h0.xy / max(r0, 1e-3);
        float rays = 0.35 + 0.65 * vnoise(dirn * 13.0 + 3.0 * vec2(sin(dw * 0.05), cos(dw * 0.05)));
        float fan = smoothstep(irisR, irisR + 0.6, r0) * exp(-max(r0 - irisR, 0.0) * 0.35);
        vec3 spec = mix(hsv2rgb(vec3(0.78 * saturate(g * 5.0 + 0.5), 0.80, 1.0)), accent, 0.45);
        col += spec * rays * rays * fan * exp(-g * g * 70.0) * glow * refr
             * (0.06 + 0.40 * gb + 0.20 * u.bassImpact + 0.9 * kick * u.beat + 0.3 * rush);
    }

    // ---- the circular waveform ring round the ball ----
    float tw = abs(fract((ang - spin * 0.5) / PP_TAU + 0.25) * 2.0 - 1.0);
    float b = (bandAt(u, tw) * 2.0 + bandAt(u, tw + 0.03) + bandAt(u, tw - 0.03)) * 0.25;
    float ringR = PP_RB + 0.10 + 0.22 * b;
    float occl = (bestT < 1e8 || tBall > 0.0) ? 0.0 : 1.0;
    float rd0 = r0 - ringR;
    vec3 ringCol = peakWhite(mix(PPAL(tw * 0.8 + 0.1 + hueOff), accent, 0.6) * 1.6, 0.4 * u.onset);
    col += ringCol * occl * glow * (aaLine(rd0, 0.005 + 0.008 * b) * (1.0 + 2.6 * b + 1.0 * u.onset)
                                  + exp(-abs(rd0) * 24.0) * (0.10 + 0.50 * b));

    // ---- on each beat a dispersed shock ring leaves the lens and runs out
    // across the glass: red, accent and violet edges slightly apart ----
    float bp = saturate(u.beatPhase);
    float rs = PP_RB + 0.2 + 6.5 * bp;
    float sw = (1.0 - bp) * (1.0 - bp) * u.beat * glow * (1.0 + 0.6 * rush);
    float sx = (r0 - rs) * (16.0 - 9.0 * bp);
    vec3 shock = vec3(1.0, 0.2, 0.05) * 0.45 * exp(-(sx - 0.9) * (sx - 0.9) * 4.0)
               + accent * 1.5 * exp(-sx * sx * 3.0)
               + vec3(0.4, 0.1, 1.0) * 0.45 * exp(-(sx + 0.9) * (sx + 0.9) * 4.0);
    col += shock * sw * (tBall > 0.0 && (bestT > 1e8 || tBall < bestT) ? 0.0 : 0.9);

    col *= 0.30 + 0.70 * smoothstep(2.3, 0.5, length(p));
    return col; // LINEAR HDR — post chain tonemaps
}
