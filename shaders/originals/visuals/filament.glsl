// SPDX-License-Identifier: AGPL-3.0-only
// Filament.
// A macro product shot of a showcase bulb: one long coiled tungsten filament
// strung inside a clear glass tube, seen so close that every turn of the coil
// is a glowing wire with a lit front and a darker back. The coil's axis is a
// plucked string: band energies weight its standing-wave harmonics (bass the
// fundamental, treble the high harmonics) in two planes, and each beat plucks
// a kink that runs out to the lead-in wires. Temperature carries the music:
// the coil smoulders deep red in a breakdown, runs orange at cruise and goes
// white-hot in a burst, with hot spots racing along it and a warm/cool rim
// accent that alternates each beat. A shallow lens melts the far coil into a
// soft tube and the studio behind into palette bokeh; studio softboxes slide
// across the glass as long curved highlights. The camera glides along the
// tube on the shared cruise/build/burst/brake profile; audio drives heat,
// light and the string's shape, never the camera.
// param0 = Tension ; param1 = Glow ; param2 = Heat
const float FL_L = 6.0;        // half length of the string
const float FL_FLOOR = -1.15;  // floor height
const float FL_RC = 1.15;      // radius that bounds the string's motion

// Band energies at the eight harmonic positions (bins 0, 9, ..., 63, the same
// points bandAt(n / 7) samples), read with constant indices.
void flBands(VisualUniforms u, out vec4 w0, out vec4 w1) {
    w0 = vec4(u.spectrum[0].x, u.spectrum[2].y, u.spectrum[4].z, u.spectrum[6].w);
    w1 = vec4(u.spectrum[9].x, u.spectrum[11].y, u.spectrum[13].z, u.spectrum[15].w);
}

// The palette read once per pixel at its five stops and blended locally; the
// library read walks the whole stop table on every call.
struct FlPalette { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

FlPalette flPalLoad(VisualUniforms u) {
    FlPalette P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 flPal(FlPalette P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float FL_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 flFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * FL_RUN[32] + FL_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

// Linear interpolation of those eight energies at span position s in [0, 1].
float flBand8(float s, vec4 w0, vec4 w1) {
    float x = saturate(s) * 7.0;
    vec4 h0 = max(1.0 - abs(x - vec4(0.0, 1.0, 2.0, 3.0)), 0.0);
    vec4 h1 = max(1.0 - abs(x - vec4(4.0, 5.0, 6.0, 7.0)), 0.0);
    return dot(w0, h0) + dot(w1, h1);
}

// Harmonic weights for one string: y and z coefficients of harmonics 1..8 in
// vec4 pairs, plus their magnitudes (the envelope). ph offsets the phase so
// the sister strings differ.
void flCoefs(VisualUniforms u, vec4 w0, vec4 w1, float tension, float pluck, float ph,
             out vec4 y0, out vec4 y1, out vec4 z0, out vec4 z1, out vec4 e0, out vec4 e1) {
    float t = mod(u.time, 600.0);
    vec4 fa = vec4(1.0, 2.0, 3.0, 4.0);
    vec4 fb = vec4(5.0, 6.0, 7.0, 8.0);
    float drive = pluck * (0.45 + 0.95 * u.amplitude);
    // 0.80 / sqrt(n)
    vec4 aa = w0 * (1.25 - 0.09 * fa) * vec4(0.8, 0.5656854, 0.4618802, 0.4) * drive;
    vec4 ab = w1 * (1.25 - 0.09 * fb) * vec4(0.3577709, 0.3265986, 0.3023716, 0.2828427) * drive;
    vec4 pa = tension * (2.0 + 1.35 * fa) * t + fa * 1.7 + ph;
    vec4 pb = tension * (2.0 + 1.35 * fb) * t + fb * 1.7 + ph;
    float sum = dot(aa, vec4(1.0)) + dot(ab, vec4(1.0));
    // keep the whole motion inside the bounding cylinder
    float k = min(1.0, 0.75 / max(sum, 1e-4));
    y0 = aa * cos(pa) * k;
    y1 = ab * cos(pb) * k;
    z0 = aa * 0.75 * sin(pa + 0.9 * fa) * k;
    z1 = ab * 0.75 * sin(pb + 0.9 * fb) * k;
    e0 = aa * k;
    e1 = ab * k;
}

// sin(n th) for n = 1..8 by the Chebyshev recurrence
void flSines(float s, out vec4 a, out vec4 b) {
    float th = 3.14159265 * s;
    float s1 = sin(th);
    float c2 = 2.0 * cos(th);
    float s2 = c2 * s1;
    float s3 = c2 * s2 - s1;
    float s4 = c2 * s3 - s2;
    float s5 = c2 * s4 - s3;
    float s6 = c2 * s5 - s4;
    float s7 = c2 * s6 - s5;
    float s8 = c2 * s7 - s6;
    a = vec4(s1, s2, s3, s4);
    b = vec4(s5, s6, s7, s8);
}

// Point on a string at span position s in [0, 1].
vec3 flPoint(float s, vec4 y0, vec4 y1, vec4 z0, vec4 z1, float bow, vec3 kink) {
    vec4 a, b;
    flSines(s, a, b);
    float y = dot(y0, a) + dot(y1, b) + bow * a.x;
    float z = dot(z0, a) + dot(z1, b);
    // the pluck kinks: two packets running out from the pluck point
    float g = exp(-(s - kink.x) * (s - kink.x) * 600.0) + exp(-(s - kink.y) * (s - kink.y) * 600.0);
    y += g * kink.z;
    z += g * kink.z * 0.4;
    return vec3(-FL_L + 2.0 * FL_L * s, y, z);
}

// Closest approach of the ray to segment ab: (distance, ray t, segment h).
vec3 flRaySeg(vec3 ro, vec3 rd, vec3 a, vec3 b) {
    vec3 ba = b - a;
    vec3 oa = ro - a;
    float baba = dot(ba, ba);
    float bard = dot(ba, rd);
    float baoa = dot(ba, oa);
    float rdoa = dot(rd, oa);
    float h = saturate((baoa - bard * rdoa) / max(baba - bard * bard, 1e-6));
    float t = max(bard * h - rdoa, 0.0);
    return vec3(length(oa + rd * t - ba * h), t, h);
}

// Closest approach of the ray to a string around the x axis, in the string's
// frame: (distance, ray t, span s). Only the span the ray passes within FL_RC
// of the axis is walked; elsewhere the axis distance stands in (halo only).
vec3 flTrace(vec3 ro, vec3 rd, vec4 y0, vec4 y1, vec4 z0, vec4 z1, float bow, vec3 kink, int nseg) {
    float A = rd.y * rd.y + rd.z * rd.z;
    float B = ro.y * rd.y + ro.z * rd.z;
    float C = ro.y * ro.y + ro.z * ro.z;
    float Ai = 1.0 / max(A, 1e-6);
    float tAx = max(-B * Ai, 0.0);
    vec3 pa0 = ro + rd * tAx;
    float sAx = saturate((pa0.x + FL_L) / (2.0 * FL_L));
    float over = max(abs(pa0.x) - FL_L, 0.0);
    vec3 best = vec3(sqrt(max(C - B * B * Ai, 0.0) + over * over), tAx, sAx);
    float disc = B * B - A * (C - FL_RC * FL_RC);
    if (disc > 0.0 && A > 1e-6) {
        float sq = sqrt(disc);
        float t0 = max((-B - sq) * Ai, 0.0);
        float t1 = (-B + sq) * Ai;
        if (t1 > 0.0) {
            float xa = ro.x + rd.x * t0;
            float xb = ro.x + rd.x * t1;
            float fn = float(nseg);
            float sLo = (min(xa, xb) + FL_L) / (2.0 * FL_L);
            float sHi = (max(xa, xb) + FL_L) / (2.0 * FL_L);
            int i0 = int(clamp(floor(sLo * fn), 0.0, fn));
            int i1 = int(clamp(ceil(sHi * fn), 0.0, fn));
            vec3 a = flPoint(float(i0) / fn, y0, y1, z0, z1, bow, kink);
            for (int k = 0; k < 64; k++) {
                int i = i0 + k;
                if (i >= i1) break;
                float s = float(i + 1) / fn;
                vec3 b = flPoint(s, y0, y1, z0, z1, bow, kink);
                vec3 r = flRaySeg(ro, rd, a, b);
                if (r.x < best.x) best = vec3(r.x, r.y, s - (1.0 - r.z) / fn);
                a = b;
            }
        }
    }
    return best;
}

// Glow of a line of radius r at distance d, depth t, defocused around focus tf.
// The cross-section integral is conserved, so blurred parts get wide and dim.
float flLens(float d, float t, float r, float tf, float pix, float aperture) {
    float coc = aperture * abs(t - tf) / max(t, 0.2);
    float w = max(r + coc * t, t * pix);
    float peak = (r + 0.004) / (w + 0.004);
    float x = d / w;
    float gauss = exp(-x * x * 2.0);
    float disk = 1.0 - smoothstep(0.75, 1.0, x);
    return peak * mix(gauss, disk, smoothstep(0.02, 0.10, coc));
}

const float FL_R = 0.15;      // coil radius
const float FL_PITCH = 0.085; // coil pitch (one turn)
const float FL_WR = 0.022;    // wire radius
const float FL_RG = 1.3;      // radius of the glass tube round the string

// Tungsten glow for heat x (0 cold, 1 white-hot): the hue climbs from deep
// red through orange to warm white while the power climbs much faster.
// Below orange heat the glow leans toward the palette's own hot stop.
vec3 flHeat(float x, vec3 tint) {
    x = max(x, 0.0);
    vec3 c = vec3(1.0, 0.30 * x + 0.55 * x * x, 0.04 * x + 0.62 * x * x * x);
    c = mix(tint, c, 0.82 + 0.18 * smoothstep(0.30, 0.85, x));
    return c * (0.10 + 3.6 * x * x * sqrt(x));
}

// Coverage of the coil's wire at a point P on the coil cylinder, in the coil's
// local frame (x along the axis), for axis position s. soft widens the edge
// for pixel size and defocus; lim returns the wire's cross-section shading.
float flWire(vec3 P, float s, float soft, float blur, out float lim) {
    float ang = atan2_(P.z, P.y) * 0.15915494;
    float k = (s * 2.0 * FL_L + P.x) / FL_PITCH - ang;
    float d = abs(fract(k + 0.5) - 0.5) * FL_PITCH;
    lim = sqrt(saturate(1.0 - d * d / (FL_WR * FL_WR)));
    return smoothstep(-soft, soft, FL_WR - d) * FL_WR / (FL_WR + blur);
}

// A softbox: the reflected ray r from P hits the plane axis = at (n = 0, 1, 2
// for x, y, z) inside the rectangle lo..hi of the other two axes. Soft-edged,
// brighter in its middle.
float flBox(vec3 P, vec3 r, int n, float at, vec2 lo, vec2 hi) {
    float rn = n == 0 ? r.x : n == 1 ? r.y : r.z;
    float pn = n == 0 ? P.x : n == 1 ? P.y : P.z;
    float t = (at - pn) / (abs(rn) > 1e-4 ? rn : 1e-4);
    if (t <= 0.0) return 0.0;
    vec3 H = P + r * t;
    vec2 q = n == 0 ? H.yz : n == 1 ? H.xz : H.xy;
    vec2 c = 0.5 * (lo + hi);
    vec2 h = 0.5 * (hi - lo);
    vec2 e = abs(q - c) / h;
    float m = (1.0 - smoothstep(0.55, 1.0, e.x)) * (1.0 - smoothstep(0.25, 1.0, e.y));
    return m * (0.55 + 0.45 * (1.0 - e.x * e.x));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float tension = mix(0.7, 2.0, u.param0);
    float glowAmt = mix(0.6, 1.6, u.param1);
    float heatAmt = mix(0.75, 1.25, u.param2);
    float t = mod(u.time, 600.0);
    FlPalette P = flPalLoad(u);
    float bp = saturate(u.beatPhase);
    float cen = u.spectralCentroid;
    float bn = mod(floor(u.beatCount), 64.0);
    float odd = mod(bn, 2.0);

    // ---- camera: a glide along the tube on the shared speed profile ----
    vec2 fl = flFlight(u, 0.32, 0.06);
    float surge = smoothstep(1.0, 4.0, fl.y);
    float ph = fl.x * 0.42;
    float xc = 3.4 * sin(ph * 0.5);
    float rad = 1.95 + 0.35 * sin(ph * 0.53 + 0.4);
    float el = 0.10 + 0.30 * sin(ph * 0.77 + 1.3);
    vec3 ro = vec3(xc, rad * sin(el), -rad * cos(el));
    vec3 ta = vec3(xc + 1.7 * sin(ph * 0.61 + 2.0), -0.05, 0.0);
    float roll = osBank(u, 0.08);
    float fov = 1.85;
    vec3 rd = osCamera(ro, ta, roll, fov, p);
    float tf = length(ta - ro);
    float pix = 2.0 / (u.resolution.y * fov);
    float aperture = 0.055;

    // ---- the string's state: the coil's axis ----
    float pluck = (exp(-2.4 * u.beatPhase) * (0.40 + 0.60 * saturate(u.onset)) + 0.32 + 0.22 * surge) * 0.62;
    float bow = 0.12 * u.bassImpact;
    vec4 bw0, bw1;
    flBands(u, bw0, bw1);
    vec4 y0, y1, z0, z1, e0, e1;
    flCoefs(u, bw0, bw1, tension, pluck, 0.0, y0, y1, z0, z1, e0, e1);
    float sp = 0.25 + 0.5 * hash11(bn + 3.0);
    float kinkA = sp + bp * 0.9;
    float kinkB = abs(sp - bp * 0.9);
    kinkA = kinkA > 1.0 ? 2.0 - kinkA : kinkA;
    float kinkAmp = 0.10 * smoothstep(0.0, 0.05, bp) * exp(-2.8 * bp) * (0.3 + 0.7 * saturate(u.onset));
    vec3 kink = vec3(kinkA, kinkB, kinkAmp);

    // ---- colours ----
    vec3 tint = flPal(P, 0.06 + 0.04 * cen);
    tint *= 1.0 / max(max(tint.r, max(tint.g, tint.b)), 0.05);
    vec3 cCool = flPal(P, 0.80 + 0.06 * cen);
    vec3 cMid = flPal(P, 0.45);
    vec3 cHi = flPal(P, 0.999);
    vec3 amber = vec3(1.0, 0.52, 0.16);
    // the beat accent alternates cool and warm, easing out over the beat
    float acc = exp(-3.0 * bp);
    vec3 cAcc = mix(cCool * 1.4 + 0.1, amber * 1.3, odd);
    // base heat follows the flight: smoulder in a drift, white in a burst
    float heat0 = heatAmt * (0.30 + 0.36 * surge + 0.16 * u.amplitude + 0.08 * u.bassImpact);

    // ---- glass tube: where the ray meets it, for the reflections at the end ----
    float gA = rd.y * rd.y + rd.z * rd.z;
    float gB = ro.y * rd.y + ro.z * rd.z;
    float gC = ro.y * ro.y + ro.z * ro.z - FL_RG * FL_RG;
    float gD = gB * gB - gA * gC;

    // ---- the studio behind the bulb: dark sweep and palette bokeh ----
    // a cool seamless backdrop with two soft light pools that drift slowly,
    // so the hot coil always sits on its complement
    vec3 col = cCool * (0.006 + 0.010 * exp(-abs(rd.y + 0.10) * 2.5));
    {
        float az = atan2_(rd.x, rd.z);
        vec2 q0 = vec2(az - 0.35 * sin(t * 0.05 + ph * 0.3), rd.y + 0.05);
        vec2 q1 = vec2(az + 0.9 + 0.3 * sin(t * 0.04), rd.y - 0.25);
        float pool0 = exp(-dot(q0, q0) * 3.0);
        float pool1 = exp(-dot(q1, q1) * 5.0);
        col += cCool * pool0 * (0.050 + 0.040 * u.bass + 0.03 * surge);
        col += mix(cMid, cHi, 0.4) * pool1 * (0.030 + 0.030 * u.mid);
    }
    int nlay = osSteps(1.0, 3.0, detail);
    float trebW = u.treble * u.onset * 0.14;
    for (int j = 0; j < 3; j++) {
        if (j >= nlay) break;
        float fj = float(j);
        vec2 q = p * (1.0 + 0.45 * fj) + vec2(-xc * (0.30 - 0.08 * fj) + t * 0.010, t * 0.006 + fj * 7.3);
        q *= 1.25;
        vec2 cell = floor(q);
        vec2 f = fract(q) - 0.5;
        vec2 h = hash22(cell + fj * 31.0);
        vec2 c = (h - 0.5) * 0.36;
        float rr = 0.10 + 0.16 * h.y * h.y;
        // six-bladed aperture: hexagonal bokeh, turned a little per layer
        vec2 g = rot2(0.3 + 0.7 * fj) * (f - c);
        vec2 ga = abs(g);
        float dd = max(ga.x * 0.8660254 + ga.y * 0.5, ga.y) / rr;
        float on = step(0.55, h.x);
        float edge = 1.0 - smoothstep(0.80, 1.0, dd);
        float rim = exp(-(dd - 0.88) * (dd - 0.88) * 90.0);
        float disk = edge * (0.55 + 0.30 * dd * dd) + rim * 0.35;
        float pick = fract(h.y * 7.3 + fj * 0.37);
        vec3 cm = pick < 0.45 ? cCool : pick < 0.75 ? cMid : pick < 0.90 ? cHi : amber;
        cm = peakWhite(cm, trebW);
        float twinkle = 0.75 + 0.25 * sin(t * (0.6 + h.x) + h.y * 40.0);
        float bandK = bandAt(u, pick);
        col += cm * disk * on * (0.030 + 0.070 * bandK) * twinkle * (1.0 - 0.25 * fj);
    }

    int nseg = osSteps(24.0, 56.0, detail);

    // ---- sister filaments of the squirrel cage, behind and soft ----
    int nsis = osSteps(10.0, 20.0, detail);
    for (int j = 0; j < 2; j++) {
        float fj = float(j);
        vec3 off = vec3(0.0, j == 0 ? 0.55 : -0.50, 0.75 + 0.45 * fj);
        vec4 q0, q1, w0, w1, g0, g1;
        flCoefs(u, bw0, bw1, tension * (1.13 + 0.21 * fj), pluck * 0.8, 2.1 + 1.7 * fj, q0, q1, w0, w1, g0, g1);
        vec3 sb = flTrace(ro - off, rd, q0, q1, w0, w1, 0.0, vec3(0.0), nsis);
        float hs = heat0 * 0.85 + 0.25 * flBand8(0.2 + 0.3 * fj + 0.5 * sb.z, bw0, bw1);
        vec3 cs = flHeat(hs, tint);
        float ls = flLens(sb.x, sb.y, FL_R * 0.9, tf, pix, aperture);
        col += cs * (ls * 0.22 + exp(-sb.x * 4.0) * 0.003) * glowAmt;
    }

    // ---- the coil ----
    vec3 best = flTrace(ro, rd, y0, y1, z0, z1, bow, kink, nseg);
    float sC = best.z;
    float pph = sC * 3.0 - 2.0 * fract(fl.x * 0.175);
    float pk = 0.5 + 0.5 * sin(6.2831853 * pph);
    float packet = pk * pk * pk * pk;
    packet *= packet;
    float kf = exp(-(sC - kinkA) * (sC - kinkA) * 160.0) + exp(-(sC - kinkB) * (sC - kinkB) * 160.0);
    float eC = flBand8(sC, bw0, bw1);
    float heat = heat0 + 0.26 * eC + 0.20 * packet + kf * kinkAmp * 5.0;
    // the coil cools toward its anchors, where the lead-in wires sink the heat
    heat *= 0.55 + 0.45 * smoothstep(0.0, 0.06, sC) * smoothstep(1.0, 0.94, sC);
    vec3 E = flHeat(heat, tint) * glowAmt;
    float fogS = exp(-best.y * 0.03);

    // defocused coil: a soft glowing tube; sharp coil: the wire itself
    float blurC = aperture * abs(best.y - tf);
    float sharp = 1.0 - smoothstep(0.30 * FL_PITCH, 0.90 * FL_PITCH, blurC);
    col += E * flLens(best.x, best.y, FL_R, tf, pix, aperture) * 0.55 * (1.0 - sharp) * fogS;
    if (sharp > 0.001 && best.x < FL_R * 1.5) {
        float sA = clamp(sC, 0.0, 0.996);
        vec3 A = flPoint(sA, y0, y1, z0, z1, bow, kink);
        vec3 Tg = normalize(flPoint(sA + 0.004, y0, y1, z0, z1, bow, kink) - A);
        vec3 N1 = normalize(cross(Tg, vec3(0.0, 0.0, 1.0)));
        vec3 N2 = cross(Tg, N1);
        vec3 o = ro - A;
        vec3 ol = vec3(dot(o, Tg), dot(o, N1), dot(o, N2));
        vec3 dl = vec3(dot(rd, Tg), dot(rd, N1), dot(rd, N2));
        float qa = dl.y * dl.y + dl.z * dl.z;
        float qb = ol.y * dl.y + ol.z * dl.z;
        float qc = ol.y * ol.y + ol.z * ol.z - FL_R * FL_R;
        float disc = qb * qb - qa * qc;
        if (disc > 0.0 && qa > 1e-6) {
            float sq = sqrt(disc);
            float t0 = (-qb - sq) / qa;
            float t1 = (-qb + sq) / qa;
            if (t0 > 0.0) {
                float soft = t0 * pix * 0.8 + blurC;
                float l0, l1;
                float c0 = flWire(ol + dl * t0, sA, soft, blurC, l0);
                float c1 = flWire(ol + dl * t1, sA, soft, blurC, l1);
                float a = c0 + (1.0 - c0) * c1;
                // the near face is lit by the far turns behind it, the far face
                // is seen through the gaps; a dark core edge outlines each turn
                vec3 wire = E * c0 * (0.35 + 0.75 * l0) + E * 0.62 * c1 * (1.0 - c0) * (0.40 + 0.60 * l1);
                // hot vapour inside the coil
                vec3 inner = E * 0.05 * saturate((t1 - t0) / (2.0 * FL_R));
                col = mix(col, wire + inner, sharp * a * fogS) + inner * sharp * (1.0 - a) * fogS;
            }
        }
    }
    // the glow the hot wire throws into the gas
    col += E * (exp(-max(best.x - FL_R, 0.0) * 16.0) * 0.08 + exp(-best.x * 4.0) * 0.010) * fogS;

    // ---- lead-in wires and their clamps, lit by the coil ----
    for (int k = 0; k < 2; k++) {
        float sx = k == 0 ? -1.0 : 1.0;
        vec3 a0 = vec3(sx * FL_L, 0.0, 0.0);
        vec3 a1 = vec3(sx * (FL_L - 0.35), -1.55, 0.25);
        vec3 oa = a0 - ro;
        float tq = max(dot(oa, rd), 0.0);
        float da = length(oa - rd * tq);
        float wa = 0.035 + aperture * abs(tq - tf);
        col += flHeat(heat0 * 0.8, tint) * exp(-da * da / (wa * wa)) * (0.035 / wa) * 0.5 * glowAmt;
    }

    // ---- pluck sparks: tungsten glints thrown off the pluck point ----
    int nspk = osSteps(4.0, 10.0, detail);
    float spkLife = (1.0 - bp) * (1.0 - bp) * saturate(u.onset * 1.4 + 0.15);
    vec3 sp0 = flPoint(sp, y0, y1, z0, z1, bow, kink);
    vec3 cPkA = flHeat(1.05, tint) * 0.9;
    vec3 cPkB = cAcc * 2.0;
    for (int i = 0; i < 10; i++) {
        if (i >= nspk) break;
        float fi = float(i);
        vec2 h = hash22(vec2(fi * 1.37 + 0.5, bn + 11.0));
        float h3 = hash11(fi * 7.1 + bn * 3.3);
        float ang = 6.2831853 * h.x;
        vec3 v = vec3((h3 - 0.5) * 1.4, 0.5 + 1.0 * h.y * abs(sin(ang)), 0.9 * cos(ang)) * (0.7 + 0.7 * h.y);
        float tau = bp * 1.0;
        vec3 sa = sp0 + v * tau - vec3(0.0, 1.2, 0.0) * tau * tau;
        float tb = max(tau - 0.05, 0.0);
        vec3 sbb = sp0 + v * tb - vec3(0.0, 1.2, 0.0) * tb * tb;
        vec3 r = flRaySeg(ro, rd, sbb, sa);
        col += mix(cPkA, cPkB, step(0.6, h.y)) * flLens(r.x, r.y, 0.005, tf, pix, aperture) * spkLife * 3.0;
    }

    // ---- glass: softboxes sliding across the curved tube ----
    if (gD > 0.0 && gA > 1e-6 && gC > 0.0) {
        float sq = sqrt(gD);
        float tg = (-gB - sq) / gA;
        if (tg > 0.0) {
            vec3 Pg = ro + rd * tg;
            vec3 n = normalize(vec3(0.0, Pg.y, Pg.z));
            float cosI = saturate(-dot(rd, n));
            float F = 0.04 + 0.96 * pow(1.0 - cosI, 5.0);
            vec3 r = reflect(rd, n);
            // a long softbox overhead, a strip low behind the camera, a small kicker
            float sA = flBox(Pg, r, 1, 3.2, vec2(-5.0, -1.6), vec2(4.0, -0.9));
            float sB = flBox(Pg, r, 2, -4.0, vec2(-7.0, -1.35), vec2(7.0, -0.95)) * 0.5;
            float sK = flBox(Pg, r, 1, 3.2, vec2(4.6, -2.6), vec2(7.5, -2.1));
            vec3 env = (vec3(1.0, 0.97, 0.93) * 0.6 + cCool * 0.6) * sA * (5.0 + 3.0 * (1.0 - odd) * acc)
                     + mix(amber, cHi, 0.3) * sB * (3.5 + 3.0 * odd * acc)
                     + cAcc * sK * (2.0 + 4.0 * acc);
            // the glass carries a faint mirror of the hot coil and a cool rim
            env += E * 0.25 * exp(-best.x * 1.5);
            // the tube's edges, seen through the most glass, carry the coil's
            // light along them and a cool rim
            float edgeG = pow(1.0 - cosI, 6.0);
            env += (flHeat(heat0, tint) * 0.35 * glowAmt + cCool * 0.35) * edgeG;
            // the hot gas inside the tube glows with the heat
            float chord = 2.0 * sq / gA;
            col += flHeat(heat0, tint) * 0.0012 * chord * glowAmt;
            col = col * (1.0 - F) * vec3(0.98, 0.97, 0.95) + env * F;
        }
    }

    // ---- anamorphic streaks: each pluck kink throws a thin horizontal flare ----
    {
        vec3 fw = normalize(ta - ro);
        vec3 rt = normalize(cross(fw, vec3(sin(roll), cos(roll), 0.0)));
        vec3 cu = cross(rt, fw);
        vec3 cS = mix(flHeat(1.0, tint), cAcc, 0.5);
        for (int k = 0; k < 2; k++) {
            vec3 X = flPoint(k == 0 ? kinkA : kinkB, y0, y1, z0, z1, bow, kink) - ro;
            float zz = dot(X, fw);
            if (zz > 0.3) {
                vec2 sp2 = fov * vec2(dot(X, rt), dot(X, cu)) / zz;
                vec2 dq = p - sp2;
                float st = (exp(-abs(dq.y) * 260.0) + 0.18 * exp(-abs(dq.y) * 55.0)) * exp(-abs(dq.x) * 1.6) + exp(-dot(dq, dq) * 900.0) * 0.6;
                col += cS * st * kinkAmp * 6.0 * glowAmt;
            }
        }
    }

    // interleaved-gradient dither keeps the dark gradients from banding
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col = max(col * (1.0 + (ign - 0.5) * 0.05) + (ign - 0.5) * 0.0008, vec3(0.0));
    return col; // linear HDR; the host tone-maps
}
