// SPDX-License-Identifier: AGPL-3.0-only
// Oscillo ring.
// A long-exposure light-painting session in an empty concrete hall with a
// wet floor. A ring of LEDs swung on a cord paints an open lattice of cool
// glowing rings in the air, one ring after another, so the figure is always
// being drawn: the newest stroke is white hot at its head and older strokes
// fade to a dim afterglow within the second. Each ring is a closed
// oscilloscope trace whose radius wobbles with the spectrum on integer
// harmonics. Every eight beats the painter changes the figure (a meridian
// sphere, a torus, a gyroscope rosette, a stacked spectrum vase) and paints it
// over the old one ring by ring. Two more painters swing pixel sticks round
// the orb on wide tilted orbits, a full turn every two beats, so broad
// twisting ribbons of gold, amber, red and rose light sweep across the frame
// and fade behind their heads. Warm beats throw steel-wool sparks that arc
// down and bounce off the floor; cool beats flare the fresh rings. The orb
// and the moving stick heads are the only lights: they glow in the haze,
// pool on the floor and catch the wet sheen of the columns, and the puddles
// mirror it all while the camera circles slowly on the shared speed profile.
// Rings and orbits are found analytically in screen space (a first guess
// refined by Gauss-Newton on the exact projection), so there is no ray march.
// param0 = Orb Size ; param1 = Trace Swing ; param2 = Sparks

const float OR_TAU = 6.2831853;

struct OrPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

// cyclic blend over the four cool stops; c4 is kept for the warm accent
vec3 orCool(OrPal P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c2, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c3, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c1, smoothstep(2.0, 3.0, t));
    return mix(c, P.c0, smoothstep(3.0, 4.0, t));
}

// the warm family the pixel stick paints in: gold, amber, the palette's red, rose
vec3 orWarm(OrPal P, float t) {
    t = fract(t) * 4.0;
    vec3 g = vec3(1.0, 0.7, 0.2);
    vec3 am = vec3(1.0, 0.38, 0.06);
    vec3 re = vec3(1.0, 0.14, 0.06);
    vec3 ro = vec3(1.0, 0.2, 0.38);
    vec3 c = mix(g, am, smoothstep(0.0, 1.0, t));
    c = mix(c, re, smoothstep(1.0, 2.0, t));
    c = mix(c, ro, smoothstep(2.0, 3.0, t));
    return mix(c, g, smoothstep(3.0, 4.0, t));
}

struct OrCam { vec3 ro; vec3 fw; vec3 rt; vec3 cu; float f; };
struct OrRing { vec3 C; vec3 A; vec3 B; };

// x, y = screen position, z = depth along the view axis
vec3 orProj(OrCam c, vec3 X) {
    vec3 d = X - c.ro;
    float z = max(dot(d, c.fw), 0.05);
    return vec3(c.f * vec2(dot(d, c.rt), dot(d, c.cu)) / z, z);
}

vec2 orCm(vec2 a, vec2 b) { return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }

// phases of ring k's four trace harmonics, as unit complex numbers
struct OrPh { vec4 q0; vec4 q1; };
OrPh orPhase(float k, float t) {
    vec4 a = vec4(t * 1.3 + k, -t * 1.7 + 2.0 * k, t * 2.3 + 0.5 * k, -t * 3.1 + 0.7 * k);
    OrPh h;
    h.q0 = vec4(cos(a.x), sin(a.x), cos(a.y), sin(a.y));
    h.q1 = vec4(cos(a.z), sin(a.z), cos(a.w), sin(a.w));
    return h;
}

// Point X and tangent dX of the ring at angle s. The radius wobbles with the
// spectrum on integer harmonics 3, 5, 9 and 14, so the trace always closes;
// the harmonics are powers of e^(is), so one sin/cos pair serves them all.
void orEval(OrRing r, float s, OrPh h, vec4 sw, out vec3 X, out vec3 dX) {
    vec2 z = vec2(cos(s), sin(s));
    vec2 z2 = orCm(z, z);
    vec2 z3 = orCm(z2, z);
    vec2 z5 = orCm(z3, z2);
    vec2 z9 = orCm(orCm(z5, z2), z2);
    vec2 z14 = orCm(z9, z5);
    vec2 w3 = orCm(z3, h.q0.xy);
    vec2 w5 = orCm(z5, h.q0.zw);
    vec2 w9 = orCm(z9, h.q1.xy);
    vec2 w14 = orCm(z14, h.q1.zw);
    vec4 amp = sw * vec4(0.10, 0.07, 0.045, 0.03);
    float tr = amp.x * w3.y + amp.y * w5.y + amp.z * w9.y + amp.w * w14.y;
    float dtr = 3.0 * amp.x * w3.x + 5.0 * amp.y * w5.x + 9.0 * amp.z * w9.x + 14.0 * amp.w * w14.x;
    vec3 rad = r.A * z.x + r.B * z.y;
    X = r.C + (1.0 + tr) * rad;
    dX = dtr * rad + (1.0 + tr) * (r.B * z.x - r.A * z.y);
}

// projected point (xy) and depth (z), with the screen tangent in de
vec3 orProjD(OrCam c, vec3 X, vec3 dX, out vec2 de) {
    vec3 d = X - c.ro;
    float z = max(dot(d, c.fw), 0.05);
    vec2 sxy = vec2(dot(d, c.rt), dot(d, c.cu));
    vec2 dxy = vec2(dot(dX, c.rt), dot(dX, c.cu));
    de = c.f * (dxy * z - sxy * dot(dX, c.fw)) / (z * z);
    return vec3(c.f * sxy / z, z);
}

// Closest point of ring r's projection to screen point p: x = distance,
// y = ring angle there, z = depth. A weak-perspective ellipse inverse gives
// the first guess (and culls pixels far from the curve); Gauss-Newton steps
// on the exact projection refine it. wob bounds the trace wobble.
vec3 orRingDist(vec2 p, vec2 stretch, OrCam cam, OrRing r, OrPh h, vec4 sw, float wob, int iters) {
    vec3 c3 = orProj(cam, r.C);
    vec2 a2 = cam.f * vec2(dot(r.A, cam.rt), dot(r.A, cam.cu)) / c3.z;
    vec2 b2 = cam.f * vec2(dot(r.B, cam.rt), dot(r.B, cam.cu)) / c3.z;
    vec2 q = p - c3.xy;
    float rmax = max(length(a2), length(b2));
    float reach = wob * rmax + 0.07;
    float ext = rmax + reach;
    if (dot(q, q) > ext * ext) return vec3(1e3, 0.0, c3.z);
    float det = a2.x * b2.y - a2.y * b2.x;
    det = det >= 0.0 ? max(det, 1e-4) : min(det, -1e-4);
    vec2 m = vec2(b2.y * q.x - b2.x * q.y, a2.x * q.y - a2.y * q.x) / det;
    float lm = length(m);
    vec2 mh = lm > 1e-6 ? m / lm : vec2(1.0, 0.0);
    vec2 gr = vec2(b2.y * mh.x - a2.y * mh.y, a2.x * mh.y - b2.x * mh.x) / det;
    if (abs(lm - 1.0) > 1.3 * reach * length(gr)) return vec3(1e3, 0.0, c3.z);
    float s = atan2_(mh.y, mh.x);
    vec3 X;
    vec3 dX;
    vec2 de;
    vec3 e = vec3(0.0);
    for (int i = 0; i < 3; i++) {
        orEval(r, s, h, sw, X, dX);
        e = orProjD(cam, X, dX, de);
        if (i >= iters) break;
        s += clamp(dot(p - e.xy, de) / max(dot(de, de), 1e-6), -0.5, 0.5);
    }
    return vec3(length((p - e.xy) * stretch), s, e.z);
}

// Ring k of n in figure f around centre O with radius R.
OrRing orForm(float f, float k, float n, vec3 O, float R, float lvl, float spin) {
    float u = k / n;
    OrRing r;
    if (f < 0.5) {            // meridian sphere
        float th = 3.14159265 * u + spin;
        r.C = O;
        r.A = R * vec3(cos(th), 0.0, sin(th));
        r.B = vec3(0.0, R, 0.0);
    } else if (f < 1.5) {     // torus of vertical sections
        float ph = OR_TAU * u + spin;
        vec3 e = vec3(cos(ph), 0.0, sin(ph));
        float rr = R * (0.5 + 0.12 * lvl);
        r.C = O + 0.72 * R * e;
        r.A = rr * e;
        r.B = vec3(0.0, rr, 0.0);
    } else if (f < 2.5) {     // gyroscope rosette: great circles on a cone of normals
        float ph = OR_TAU * u + spin;
        float al = 1.05;
        vec3 nn = vec3(sin(al) * cos(ph), cos(al), sin(al) * sin(ph));
        vec3 a = vec3(-sin(ph), 0.0, cos(ph));
        r.C = O;
        r.A = R * a;
        r.B = R * cross(nn, a);
    } else {                  // spectrum vase: stacked latitude rings
        float uu = (k + 0.5) / n;
        float rr = R * (0.26 + 0.58 * pow(sin(3.14159265 * uu), 0.8) + 0.34 * lvl);
        float cs = cos(spin), sn = sin(spin);
        r.C = O + vec3(0.0, (2.0 * uu - 1.0) * 1.02 * R, 0.0);
        r.A = rr * vec3(cs, 0.0, sn);
        r.B = rr * vec3(-sn, 0.0, cs);
    }
    return r;
}

// The painter's swing axis wanders, so every pass over the figure lays its
// rings at a slightly new tilt and the lattice weaves as it is repainted.
OrRing orTilt(OrRing r, vec3 O, float drawn) {
    float ax = 0.32 * sin(drawn * 0.61);
    float az = 0.24 * sin(drawn * 0.43 + 1.0);
    float cx = cos(ax), sx = sin(ax), cz = cos(az), sz = sin(az);
    mat3 m = mat3(cz, sz, 0.0, -sz, cz, 0.0, 0.0, 0.0, 1.0) * mat3(1.0, 0.0, 0.0, 0.0, cx, sx, 0.0, -sx, cx);
    r.C = O + m * (r.C - O);
    r.A = m * r.A;
    r.B = m * r.B;
    return r;
}

struct OrSt {
    float bc; float head; float nR; int n; float R; vec3 O; float t; vec4 sw;
    float zc; float pix; float coolKick; float wob; float sb[8];
};

// The painted orb seen at screen point p (also used, mirrored, for the floor).
vec3 orOrb(vec2 p, vec2 stretch, float wAdd, float mirror, int iters, OrCam cam, OrSt S, OrPal P) {
    vec3 col = vec3(0.0);
    // the whole figure stays inside a sphere round the centre: skip the rest
    vec3 o3 = orProj(cam, vec3(S.O.x, S.O.y * mirror, S.O.z));
    float rb = cam.f * S.R * (1.3 + S.wob) / o3.z + 0.08;
    vec2 dq = (p - o3.xy) * stretch;
    if (dot(dq, dq) > rb * rb) return col;
    float headK = floor(S.head);
    float headS = fract(S.head) * OR_TAU;
    // harmonic phases advance by a fixed rotation from ring to ring
    OrPh ph = orPhase(0.0, S.t);
    const vec4 st0 = vec4(0.5403023, 0.8414710, -0.4161468, 0.9092974);
    const vec4 st1 = vec4(0.8775826, 0.4794255, 0.7648422, 0.6442177);
    for (int i = 0; i < 12; i++) {
        if (i >= S.n) break;
        if (i > 0) {
            ph.q0 = vec4(orCm(ph.q0.xy, st0.xy), orCm(ph.q0.zw, st0.zw));
            ph.q1 = vec4(orCm(ph.q1.xy, st1.xy), orCm(ph.q1.zw, st1.zw));
        }
        float k = float(i);
        float lvl = S.sb[i - 8 * (i / 8)];
        bool isHead = k == headK;
        for (int v = 0; v < 2; v++) {
            if (v == 1 && !isHead) break;
            // cycles since this version of the ring was painted
            float age = isHead ? (v == 0 ? 0.0 : (S.nR - 1.0) / S.nR) : fract((S.head - k - 1.0) / S.nR);
            // start time of that stroke, in beats
            float drawn = isHead ? S.bc - fract(S.head) * 2.0 / S.nR - 2.0 * float(v)
                                 : S.bc - 2.0 * age - 2.0 / S.nR;
            float sect = floor(drawn / 8.0);
            OrRing r = orForm(mod(sect, 4.0), k, S.nR, S.O, S.R, lvl, hash11(sect * 1.37 + 0.3) * OR_TAU + 0.12 * drawn);
            r = orTilt(r, S.O, drawn);
            r.C.y *= mirror; r.A.y *= mirror; r.B.y *= mirror;
            vec3 rd3 = orRingDist(p, stretch, cam, r, ph, S.sw, S.wob, iters);
            if (rd3.x > 0.4) continue;
            float sm = mod(rd3.y, OR_TAU);
            float mask = 1.0;
            float comet = 0.0;
            if (isHead) {
                float m = smoothstep(0.0, 0.06, sm) * smoothstep(0.0, 0.06, headS - sm);
                mask = v == 0 ? m : 1.0 - m;
                comet = v == 0 ? exp(-(headS - sm) * 1.4) : 0.0;
            }
            float bri = 0.12 + 0.88 * exp(-age * 3.6);
            float coc = abs(rd3.z - S.zc) * 0.008 + wAdd;
            float w = sqrt(S.pix * S.pix + coc * coc);
            float d = rd3.x;
            float core = exp(-d * d / (w * w)) * min(1.0, 1.4 * S.pix / w);
            // windowed, so the culls never show as edges against the haze
            float hwin = saturate(1.0 - d / (0.05 + 3.0 * coc));
            float halo = hwin * hwin / (1.0 + d * d / (0.00025 + 4.0 * coc * coc));
            float led = 0.7 + 0.3 * cos(sm * 36.0 + k * 2.1 + S.t * 3.0);
            vec3 c = orCool(P, sm / OR_TAU + k * 0.23 + sect * 0.27 + S.t * 0.03);
            c = mix(c, P.c3, 0.4 * exp(-age * 2.0));   // fresh strokes lean to the cool end
            float cf = S.coolKick * exp(-age * 5.0);
            c = mix(c, P.c3 + 0.3, cf * 0.45) * (1.0 + 0.9 * cf);
            c = mix(c, vec3(1.0), comet * 0.6) * (1.0 + 1.6 * comet);
            col += c * (bri * mask * led) * (1.7 * core + 0.10 * halo);
        }
    }
    return col;
}

// Steel-wool sparks thrown off the orb on the warm beats, in screen space
// round the orb's image: ballistic arcs whose long-exposure trails cool from
// gold to red and end in a bounce on the floor. All sparks of a burst share
// one launch speed, so a pixel can undo gravity once, find its direction
// sector and test only the three sparks that can reach it.
vec3 orSparks(vec2 p, vec2 o, float Rs, float yFloor, float bc, float beats, float nS, float pix, OrPal P, float power) {
    vec3 col = vec3(0.0);
    vec3 hotC = vec3(1.0, 0.62, 0.2);
    vec3 coolC = mix(vec3(1.0, 0.22, 0.02), P.c4, 0.3);
    float g = 1.1;
    vec2 q = p - o;
    float w = pix * 0.9 + 0.0005;
    for (int bb = 0; bb < 4; bb++) {
        // two bursts, each with a fast and a slow layer of sparks
        float b = floor(beats * 0.5) - float(bb / 2);
        float layer = float(bb - 2 * (bb / 2));
        float age = bc - 2.0 * b;
        if (age > 3.4) continue;
        float v = (0.8 + 0.35 * hash11(b * 5.3 + 1.0)) * (layer > 0.5 ? 0.55 : 1.0);
        float nL = layer > 0.5 ? floor(nS * 0.6) : nS;
        // undo gravity: the launch time at which a spark passes this pixel
        float tau = max(length(q) - Rs, 0.0) / v;
        for (int it = 0; it < 2; it++) tau = max(length(q + vec2(0.0, 0.5 * g * tau * tau)) - Rs, 0.0) / v;
        // nothing of this layer is near this pixel's flight time
        if (tau > age + 0.05 || tau < age - 1.6) continue;
        vec2 qu = q + vec2(0.0, 0.5 * g * tau * tau);
        float sec = (atan2_(qu.y, qu.x) / OR_TAU + 0.5) * nL;
        float c0 = floor(sec);
        for (int j = -1; j < 2; j++) {
            float ci = mod(c0 + float(j), nL);
            float id = b * 57.0 + ci * 1.618 + layer * 311.0;
            float h1 = hash11(id), h2 = hash11(id + 3.7), h3 = hash11(id + 9.1), h4 = hash11(id + 15.3);
            if (h3 > 0.85) continue;
            float th = ((ci + 0.1 + 0.8 * h1) / nL - 0.5) * OR_TAU;
            vec2 dir = vec2(cos(th), sin(th));
            float delay = 0.8 * h2;
            float life = 0.8 + 1.3 * h4;
            float sa = age - delay;
            if (sa <= 0.0) continue;
            // floor contact: a little lower for sparks that land nearer the camera
            float yf = yFloor - 0.38 * hash11(id + 21.9) * hash11(id + 27.1);
            float cc = max(o.y + Rs * dir.y - yf, 0.0);
            float tf = (v * dir.y + sqrt(v * v * dir.y * dir.y + 2.0 * g * cc)) / g;
            float tb = min(sa, min(life, tf));
            float ta = max(0.0, tb - 0.2 - 0.35 * fract(h1 * 7.3));
            float tc = clamp(tau, ta, tb);
            vec2 pt = (Rs + v * tc) * dir - vec2(0.0, 0.5 * g * tc * tc);
            float d = length(q - pt);
            float fade = exp(-(sa - tc) * 3.0) * sqrt(saturate(1.0 - tc / life));
            float glow = exp(-d * d / (w * w)) * 1.8 + 0.07 / (1.0 + d * d / 0.00015);
            glow *= 0.65 + 0.35 * sin(tc * 47.0 + h2 * 40.0);
            col += mix(coolC, hotC, exp(-(sa - tc) * 2.2)) * glow * fade * (tb > ta ? 1.0 : 0.0);
            // bounce on the floor
            if (tf < life && sa > tf) {
                vec2 hp = (Rs + v * tf) * dir - vec2(0.0, 0.5 * g * tf * tf);
                vec2 dv = q - hp;
                col += hotC * exp(-dot(dv, dv) / (w * w * 9.0)) * exp(-(sa - tf) * 3.0) * 1.5;
            }
        }
    }
    return col * power;
}

// The orbit of pixel stick j: a big tilted ring round the orb whose tilt and
// heading precess slowly, so each sweep lays its ribbon on a new path.
OrRing orStickRing(OrSt S, float j) {
    float ph = S.t * 0.11 + j * 2.4;
    float al = 0.42 + 0.22 * sin(S.t * 0.07 + j * 1.7);
    vec3 nn = vec3(sin(al) * cos(ph), cos(al), sin(al) * sin(ph));
    vec3 a = normalize(cross(nn, vec3(0.0, 0.0, 1.0)));
    float Rr = S.R * (1.32 + 0.26 * j);
    OrRing r;
    r.C = S.O + vec3(0.0, 0.12 - 0.26 * j, 0.0);
    r.A = Rr * a;
    r.B = Rr * cross(nn, a);
    return r;
}

// angle of the stick head on orbit j: a full turn every two beats
float orStickHead(OrSt S, float j) { return fract(S.bc * 0.5 + j * 0.37) * OR_TAU; }

// The pixel stick: a second painter swings a bar of five LEDs round the orb,
// so a broad twisting ribbon of warm light is drawn across the frame within
// each second and fades behind its head. orStickAt refines one angle guess
// by Gauss-Newton on the exact projection and shades the ribbon there.
vec3 orStickAt(vec2 p, vec2 stretch, float wAdd, float mirror, OrCam cam, OrSt S, OrPal P, float j, OrRing r, OrPh h, float s) {
    vec4 sw = S.sw * 0.45;
    vec3 X;
    vec3 dX;
    vec2 de;
    vec3 e = vec3(0.0);
    for (int i = 0; i < 3; i++) {
        orEval(r, s, h, sw, X, dX);
        e = orProjD(cam, X, dX, de);
        if (i == 2) break;
        s += clamp(dot(p - e.xy, de) / max(dot(de, de), 1e-6), -0.6, 0.6);
    }
    vec2 dv = (p - e.xy) * stretch;
    float dist = length(dv);
    float hwMax = cam.f * 0.085 * S.R / e.z;
    float reach = hwMax * 3.5 + 0.012;
    if (dist > reach) return vec3(0.0);
    vec2 tn = de / max(length(de), 1e-6);
    float across = dot(dv, vec2(-tn.y, tn.x));
    // a guess that has not settled onto the stroke shows nothing
    float settled = smoothstep(4.0, 2.5, abs(dot(dv, tn)) / (hwMax + 3.0 * S.pix));
    // the trail behind the head, one turn long
    float sm = mod(s, OR_TAU);
    float dth = mod(orStickHead(S, j) - sm, OR_TAU);
    float trail = exp(-dth * 0.75) * smoothstep(0.0, 0.04, dth);
    // the stick turns in the hand, so the ribbon twists
    float tw = abs(cos(sm * 2.0 + S.t * 0.8 + j * 1.3));
    float hw = hwMax * (0.18 + 0.82 * tw);
    float coc = abs(e.z - S.zc) * 0.008 + wAdd;
    float aa = sqrt(S.pix * S.pix + coc * coc);
    float band = smoothstep(hw + aa, hw - aa, dist);
    float x = clamp(across / max(hw, 1e-5), -1.0, 1.0);
    float lf = fract((x * 0.5 + 0.5) * 4.999) - 0.5;
    float res = saturate(hw / (7.0 * aa) - 0.4);
    float leds = mix(0.55, 0.25 + 1.6 * exp(-lf * lf * 40.0), res);
    // pixel-stick pattern: the LEDs chase colour along the stroke
    float chase = 0.7 + 0.3 * cos(sm * 22.0 - S.t * 2.0 + x * 2.0);
    vec3 c = orWarm(P, x * 0.2 + sm * 0.16 + j * 0.45 + S.t * 0.02);
    float hot = exp(-dth * 9.0);
    c = mix(c, vec3(1.0, 0.92, 0.8), 0.6 * hot) * (1.0 + 2.5 * hot);
    float fall = saturate(1.0 - dist / reach);
    float halo = 0.06 * fall * fall / (1.0 + dist * dist / (hw * hw * 2.0 + 0.0001));
    // the stick never passes through the floor
    float above = smoothstep(0.0, 0.06, X.y * mirror);
    return c * (band * leds * chase * 1.3 + halo) * trail * above * settled;
}

// Two guesses: where the eye ray meets the orbit's plane, and the nearest of
// eight coarse samples of the projected orbit; the brighter result wins, so
// a fold of the orbit seen near edge-on never drops a stroke.
vec3 orRibbon(vec2 p, vec2 stretch, float wAdd, float mirror, OrCam cam, OrSt S, OrPal P, float j) {
    OrRing r = orStickRing(S, j);
    r.C.y *= mirror; r.A.y *= mirror; r.B.y *= mirror;
    vec3 c3 = orProj(cam, r.C);
    float ext = cam.f * length(r.A) * 1.6 / max(c3.z - length(r.A), 0.6) + 0.2;
    vec2 qc = p - c3.xy;
    if (dot(qc, qc) > ext * ext) return vec3(0.0);
    vec3 rd = normalize(p.x * cam.rt + p.y * cam.cu + cam.f * cam.fw);
    vec3 nP = cross(r.A, r.B);
    float dn = dot(rd, nP);
    dn = abs(dn) > 1e-5 ? dn : 1e-5;
    vec3 q = cam.ro + rd * (dot(r.C - cam.ro, nP) / dn) - r.C;
    float s0 = atan2_(dot(q, r.B), dot(q, r.A));
    float s1 = 0.0;
    float best = 1e9;
    for (int k = 0; k < 8; k++) {
        float sk = float(k) * (OR_TAU / 8.0);
        vec2 d2 = p - orProj(cam, r.C + r.A * cos(sk) + r.B * sin(sk)).xy;
        float dd = dot(d2, d2);
        if (dd < best) { best = dd; s1 = sk; }
    }
    OrPh h = orPhase(j * 3.0 + 5.0, S.t * 0.6);
    vec3 a = orStickAt(p, stretch, wAdd, mirror, cam, S, P, j, r, h, s0);
    vec3 b = orStickAt(p, stretch, wAdd, mirror, cam, S, P, j, r, h, s1);
    return max(a, b);
}

// light scattered toward the eye by the hall's haze from a point light at L
float orHaze(vec3 ro, vec3 rd, vec3 L, float tMax) {
    vec3 d = L - ro;
    float b = dot(d, rd);
    float hh = sqrt(max(dot(d, d) - b * b, 1e-4));
    return (atan((tMax - b) / hh) + atan(b / hh)) / hh;
}

// diffuse plus a broad wet sheen, times the light distance (l unnormalised)
float orLamb(vec3 n, vec3 v, vec3 l) {
    vec3 ln = normalize(l);
    float sp = pow(max(dot(normalize(ln + v), n), 0.0), 24.0);
    return (max(dot(n, ln), 0.0) + 6.0 * sp) * length(l);
}

// Concrete columns of the empty hall, lit only by the painting: the orb's
// cool light, the two warm stick heads and the spark bursts. x = distance
// along the ray to the nearest column hit (1e4 if none), yzw = its colour.
vec4 orColumns(vec3 ro, vec3 rd, vec3 O, vec3 cO, vec3 h0, vec3 c0, vec3 h1, vec3 c1) {
    float tb = 1e4;
    vec3 nb = vec3(0.0);
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        vec2 cc = vec2((mod(fi, 4.0) < 2.0 ? -1.0 : 1.0) * (3.1 + 3.0 * mod(fi, 2.0)), i < 4 ? 1.9 : 5.6);
        vec2 oc = ro.xz - cc;
        vec2 dz = rd.xz;
        float a = dot(dz, dz);
        float b = dot(oc, dz);
        float c = dot(oc, oc) - 0.34 * 0.34;
        float disc = b * b - a * c;
        if (disc < 0.0 || a < 1e-6) continue;
        float th = (-b - sqrt(disc)) / a;
        if (th > 0.0 && th < tb) {
            tb = th;
            nb = vec3((oc + dz * th) / 0.34, 0.0).xzy;
        }
    }
    if (tb > 9e3) return vec4(1e4, vec3(0.0));
    vec3 X = ro + rd * tb;
    float alb = 0.04 * (0.7 + 0.6 * vnoise(vec2(atan2_(nb.z, nb.x) * 3.0, X.y * 4.0)));
    // wet concrete: a soft sheen of each light along the column
    vec3 v = -rd;
    vec3 l = O - X;
    float dl = dot(l, l);
    vec3 col = cO * orLamb(nb, v, l) / (dl * sqrt(dl));
    l = h0 - X; dl = dot(l, l);
    col += c0 * orLamb(nb, v, l) / (dl * sqrt(dl) + 0.05);
    l = h1 - X; dl = dot(l, l);
    col += c1 * orLamb(nb, v, l) / (dl * sqrt(dl) + 0.05);
    return vec4(tb, col * alb);
}

// defocused lamps across the far end of the hall
vec3 orBokeh(vec3 rd, float yScale, OrPal P, float t, float lift) {
    float az = atan2_(rd.x, rd.z);
    vec2 b = vec2(az * 7.0, (rd.y - 0.015) * 7.0 * yScale);
    vec2 id = floor(b);
    if (id.y < 0.0 || id.y > 2.0) return vec3(0.0);
    vec2 f = fract(b) - 0.5;
    float h = hash21(id);
    if (h > 0.32) return vec3(0.0);
    vec2 j = (vec2(hash21(id + 7.0), hash21(id + 13.0)) - 0.5) * 0.3;
    float r = 0.1 + 0.2 * hash21(id + 21.0);
    float dist = length(f - j);
    float disc = smoothstep(r, r - 0.05, dist) * (0.7 + 0.3 * smoothstep(r - 0.12, r - 0.02, dist));
    vec3 warm = mix(vec3(1.0, 0.55, 0.18), P.c4, 0.3);
    vec3 cool = mix(P.c2, P.c3, hash21(id + 3.0));
    vec3 c = hash21(id + 5.0) < 0.6 ? warm : cool;
    float row = 1.0 - 0.3 * id.y;
    return c * disc * row * (0.025 + 0.07 * h) * (0.8 + 0.5 * lift);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float t = mod(u.time, 600.0);
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));

    OrPal P = OrPal(palVisual(0.0, u), palVisual(0.2, u), palVisual(0.4, u), palVisual(0.6, u), palVisual(0.8, u));

    OrSt S;
    for (int i = 0; i < 8; i++) S.sb[i] = bandAt(u, (float(i) + 0.5) / 8.0);

    // ---- camera: a slow circle round the orb, low over the floor ----
    vec2 fl = osFlight(u, 0.3, 0.18);
    float s = fl.x;
    float yaw = 0.6 * sin(s * 0.041) + 0.25 * sin(s * 0.017 + 1.0);
    float camR = 3.0 + 0.3 * sin(s * 0.057 + 0.7);
    vec3 ro = vec3(camR * sin(yaw), 0.48 + 0.12 * sin(s * 0.049 + 2.0), -camR * cos(yaw));
    float R = mix(0.95, 1.35, u.param0) * (0.96 + 0.08 * u.amplitude);
    vec3 O = vec3(0.0, 1.45, 0.0);
    vec3 ta = vec3(0.0, 0.95, 0.0);
    float roll = osBank(u, 0.03);
    OrCam cam;
    cam.ro = ro;
    cam.fw = normalize(ta - ro);
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    cam.rt = normalize(cross(cam.fw, up));
    cam.cu = cross(cam.rt, cam.fw);
    cam.f = 1.45;
    vec3 rd = normalize(p.x * cam.rt + p.y * cam.cu + cam.f * cam.fw);

    // ---- beat clock and the painting state ----
    float bc = u.beatCount + saturate(u.beatPhase);
    float bph = saturate(u.beatPhase);
    float kick = (1.0 - bph) * (1.0 - bph);
    float warmBeat = mod(floor(u.beatCount), 2.0) < 0.5 ? 1.0 : 0.0;
    S.n = osSteps(7.0, 12.0, detail);
    S.nR = float(S.n);
    S.bc = bc;
    S.head = fract(bc / 2.0) * S.nR;      // one full figure every two beats
    S.R = R;
    S.O = O;
    S.t = t;
    float swing = mix(0.4, 1.7, u.param1);
    S.sw = swing * vec4(S.sb[1] + 0.25, S.sb[3] + 0.15, S.sb[5] + 0.1, S.sb[7] + 0.4 * u.treble);
    S.wob = dot(S.sw, vec4(0.10, 0.07, 0.045, 0.03));
    S.zc = orProj(cam, O).z;
    S.pix = 2.0 / u.resolution.y;
    S.coolKick = (1.0 - warmBeat) * kick * (0.6 + 0.6 * u.bassImpact);
    int iters = detail > 0.5 ? 2 : 1;
    float lift = saturate(u.level * 1.3);

    // the two pixel-stick heads, warm moving lights
    vec3 hPos[2];
    vec3 hCol[2];
    for (int j = 0; j < 2; j++) {
        vec3 hX;
        vec3 hdX;
        float hs = orStickHead(S, float(j));
        orEval(orStickRing(S, float(j)), hs, orPhase(float(j) * 3.0 + 5.0, t * 0.6), S.sw * 0.45, hX, hdX);
        hPos[j] = hX;
        hCol[j] = orWarm(P, hs * 0.16 + float(j) * 0.45 + t * 0.02) * 0.8;
    }

    // ---- the hall: near-black air, distant defocused lamps ----
    vec3 col = vec3(0.002, 0.0025, 0.005) * (1.0 + 1.5 * exp(-abs(rd.y) * 12.0));
    if (rd.y > 0.0) col += orBokeh(rd, 1.0, P, t, lift);
    col += mix(P.c0, P.c2, 0.5) * 0.01 * exp(-abs(rd.y) * 14.0);

    // the orb's own glow in the air, cool, with a warm surge on spark beats
    vec2 oc = orProj(cam, O).xy;
    vec3 coolAvg = (P.c0 + P.c2 + P.c3) / 3.0;
    float sparkPow = mix(0.0, 1.4, u.param2) * (0.55 + 0.7 * u.bassImpact + 0.3 * u.onset);
    vec3 warmLit = mix(vec3(1.0, 0.45, 0.1), P.c4, 0.3);
    float wAge = bc - 2.0 * floor(u.beatCount * 0.5);
    float warmGlow = exp(-wAge * 1.6) * sparkPow;
    vec3 cLight = coolAvg * (2.2 + 1.5 * lift + 2.0 * S.coolKick) + warmLit * 3.0 * warmGlow;
    vec4 colm = orColumns(ro, rd, O, cLight, hPos[0], hCol[0] * 2.0, hPos[1], hCol[1] * 2.0);
    float tFl = rd.y < -0.002 ? -ro.y / rd.y : 1e4;
    if (colm.x < tFl) col = colm.yzw * exp(-colm.x * 0.035);
    vec2 dq = p - oc;
    col += (coolAvg * (0.018 + 0.018 * lift) + warmLit * 0.03 * warmGlow) * exp(-dot(dq, dq) * 3.5);

    // ---- the wet floor ----
    if (rd.y < -0.002 && colm.x > tFl) {
        float tg = -ro.y / rd.y;
        vec3 gp = ro + rd * tg;
        float puddle = smoothstep(0.42, 0.6, vnoise(gp.xz * 0.55 + 3.0) * 0.65 + vnoise(gp.xz * 1.7) * 0.35);
        float fres = mix(0.22, 0.72, puddle);
        float rip = vnoise(gp.xz * vec2(2.5, 7.0) + vec2(t * 0.35, 0.0)) - 0.5;
        vec2 pr = p + vec2(0.0, rip * (0.003 + 0.01 * (1.0 - puddle)));
        vec2 str = vec2(1.0, mix(0.3, 1.0, puddle));
        vec3 refl = orOrb(pr, str, 0.002 + 0.006 * (1.0 - puddle), -1.0, 1, cam, S, P);
        vec4 cr = orColumns(gp, vec3(rd.x, -rd.y, rd.z), O, cLight, hPos[0], hCol[0] * 2.0, hPos[1], hCol[1] * 2.0);
        refl += cr.x < 1e3 ? cr.yzw : orBokeh(vec3(rd.x, -rd.y, rd.z), mix(0.4, 1.0, puddle), P, t, lift) * 1.5;
        for (int j = 0; j < 2; j++) refl += orRibbon(pr, str, 0.002 + 0.006 * (1.0 - puddle), -1.0, cam, S, P, float(j));
        // the orb and the sparks light the floor
        float r2 = dot(gp.xz, gp.xz);
        vec3 lit = (coolAvg * (0.5 + 0.4 * lift) + warmLit * 0.8 * warmGlow) * 0.05 / (1.0 + 0.8 * r2);
        for (int j = 0; j < 2; j++) {
            vec3 dl = hPos[j] - gp;
            float dl2 = dot(dl, dl);
            lit += hCol[j] * 0.05 * hPos[j].y / (dl2 * sqrt(dl2) + 0.02);
        }
        float rough = 0.8 + 0.4 * vnoise(gp.xz * 9.0);
        vec3 fl0 = refl * fres + lit * rough * (1.0 - 0.6 * puddle);
        col = mix(col, fl0, smoothstep(-0.002, -0.03, rd.y)) * exp(-tg * 0.035);
    }

    // ---- the painted orb and the sparks ----
    col += orOrb(p, vec2(1.0), 0.0, 1.0, iters, cam, S, P);
    for (int j = 0; j < 2; j++) col += orRibbon(p, vec2(1.0), 0.0, 1.0, cam, S, P, float(j));
    // haze lit by the orb and the two stick heads
    float tAir = rd.y < -0.002 ? -ro.y / rd.y : 30.0;
    vec3 hz = coolAvg * (0.5 + 0.5 * lift + 0.6 * S.coolKick) * orHaze(ro, rd, O, tAir);
    for (int j = 0; j < 2; j++) hz += hCol[j] * orHaze(ro, rd, hPos[j], tAir);
    col += hz * 0.006;
    // the LED head itself, a hot point
    {
        float headK = floor(S.head);
        float sect = floor((bc - fract(S.head) * 2.0 / S.nR) / 8.0);
        OrRing hr = orForm(mod(sect, 4.0), headK, S.nR, O, R, S.sb[int(headK) - 8 * (int(headK) / 8)], hash11(sect * 1.37 + 0.3) * OR_TAU + 0.12 * (bc - fract(S.head) * 2.0 / S.nR));
        hr = orTilt(hr, O, bc - fract(S.head) * 2.0 / S.nR);
        vec3 hX;
        vec3 hdX;
        orEval(hr, fract(S.head) * OR_TAU, orPhase(headK, t), S.sw, hX, hdX);
        vec2 hp = orProj(cam, hX).xy;
        vec2 dv = p - hp;
        float dd = dot(dv, dv);
        col += mix(orCool(P, headK * 0.23 + sect * 0.27), vec3(1.0), 0.6) * (exp(-dd / (S.pix * S.pix * 6.0)) * 2.5 + 0.0006 / (dd + 0.0004));
    }
    float Rs = cam.f * R / S.zc;
    float yFloor = orProj(cam, vec3(0.0)).y;
    col += orSparks(p, oc, Rs * 0.92, yFloor, bc, u.beatCount, floor(mix(22.0, 44.0, detail)), S.pix, P, sparkPow);

    // mild vignette, IGN dither against banding
    col *= 1.0 - 0.3 * dot(p * 0.5, p * 0.5);
    col += (ign - 0.5) * 0.004;
    return max(col, vec3(0.0));
}
