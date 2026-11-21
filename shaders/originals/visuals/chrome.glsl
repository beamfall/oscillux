// SPDX-License-Identifier: AGPL-3.0-only
// Chrome.
// Liquid chrome: a cluster of mirror-metal bodies drifts slowly, merges and splits in
// a dark studio rigged with tall coloured light strips, an overhead ring light
// and a sunset horizon, floating over a black glass floor of neon rings that
// mirrors them. Every body mirrors the rig, the floor and its neighbours (one
// extra bounce), so the light wraps round the liquid; grazing edges carry a
// thin-film sheen. Calm under loud music: the rig brightens with the smoothed
// level plus a faint spectrum term, each beat swells only a faint ring across
// the floor and a soft band down the rig, the bodies breathe with the smoothed
// level alone, light chases gently up the LED
// strips and slow swells roll through the liquid. The camera orbits at a slow
// steady cruise with no beat surges; reds are kept just off saturated red.
// Audio drives the light rig, the body sizes and a fine shimmer gently, never
// the camera.
// param0 = Blob Count ; param1 = Reflection ; param2 = Surface Ripple

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float CH_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 chFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * CH_RUN[32] + CH_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

// Centre and radius of body i at time ph: a large central body and smaller
// ones on crossing orbits that dive into it and pull away again.
vec4 chBody(int i, float ph, VisualUniforms u) {
    float fi = float(i);
    float e = saturate(u.level);
    if (i == 0) {
        vec3 c = 0.18 * vec3(sin(ph * 0.13), sin(ph * 0.11 + 1.0), cos(ph * 0.09));
        return vec4(c, 0.78 * (0.98 + 0.03 * e));
    }
    float w = (mod(fi, 2.0) < 0.5 ? 1.0 : -1.0) * (0.16 + 0.035 * fi);
    float a = ph * w + fi * 2.39996;
    float rr = 1.25 + 0.45 * sin(ph * (0.07 + 0.013 * fi) + fi * 1.7);
    vec3 c = vec3(rr * cos(a), 0.55 * sin(ph * (0.09 + 0.02 * fi) + fi * 2.1), rr * sin(a));
    float r = (0.5 - 0.045 * fi) * (0.97 + 0.05 * e);
    return vec4(c, r);
}

float chMap(vec3 p, vec4 b0, vec4 b1, vec4 b2, vec4 b3, vec4 b4, vec4 b5, vec4 b6, float nb, float rip, vec4 wob) {
    float k = 0.36;
    float d = length(p - b0.xyz) - b0.w;
    d = osSmin(d, length(p - b1.xyz) - b1.w, k);
    d = osSmin(d, length(p - b2.xyz) - b2.w, k);
    d = osSmin(d, length(p - b3.xyz) - b3.w, k);
    if (nb > 4.5) d = osSmin(d, length(p - b4.xyz) - b4.w, k);
    if (nb > 5.5) d = osSmin(d, length(p - b5.xyz) - b5.w, k);
    // a small satellite droplet that stays separate most of the time
    d = osSmin(d, length(p - b6.xyz) - b6.w, 0.18);
    // slow travelling swells keep the liquid moving between beats, and a fine
    // shimmer rides on top; both bounded so the march stays safe
    d += wob.w * sin(p.x * 2.7 + wob.x) * sin(p.y * 3.1 - wob.y) * sin(p.z * 2.9 + wob.z);
    d += rip * sin(p.x * 13.0 + p.y * 7.0) * sin(p.z * 11.0 - p.y * 9.0);
    return d;
}

// A soft rectangular panel centred on direction c (unit), of angular half
// size h, in the frame of right vector rt; soft is the edge falloff.
// Returns (mask, position along its long side -1..1); sharp reflections see
// fine LED slats across it.
vec2 chPanel(vec3 d, vec3 c, vec3 rt, vec2 h, float soft, float slat) {
    float f = dot(d, c);
    if (f <= 0.0) return vec2(0.0);
    vec3 up = cross(c, rt);
    vec2 q = vec2(dot(d, rt), dot(d, up)) / f;
    vec2 e = abs(q) - h;
    float m = smoothstep(soft, 0.0, max(e.x, e.y));
    float hv = h.y > h.x ? q.y / h.y : q.x / h.x;
    float hx = h.y > h.x ? q.x / h.x : q.y / h.y;
    // brighter down the spine, falling off to the coloured edges
    m *= 1.0 - 0.55 * hx * hx;
    m *= 1.0 - slat * 0.6 * smoothstep(0.25, 0.45, abs(fract(hv * 9.0) - 0.5));
    return vec2(m, clamp(hv, -1.0, 1.0));
}

const float CH_FLOOR = 1.45;

// Keep reds just off saturated red (judged after the filmic curve).
float chTone(float x) { return x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14); }
float chToneInv(float y) { y = clamp(y, 0.0, 0.999); float a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y; return (-b + sqrt(b * b + 0.56 * a * y)) / (2.0 * a); }
vec3 chOffRed(vec3 c) { float r = chTone(c.r), g = chTone(c.g), b = chTone(c.b); float need = 0.3 * r - g - b; if (need <= 0.0) return c; if (c.g > c.b) c.g = max(c.g, chToneInv(g + need)); else c.b = max(c.b, chToneInv(b + need)); return c; }

// The rig's colours and levels, read from the palette and spectrum once per
// pixel; the environment is sampled up to three times per pixel.
struct ChRig {
    vec3 base, wa, wb, fa, fb, k18, k92, k55, k62, k80, s0, s1, s2, s3, s4, acc;
    float e1, e2, e3, es0, es1, es2, es3, es4, ringE, flE, beatPh, beatE, pool, chase;
};

ChRig chRigMake(VisualUniforms u) {
    ChRig k;
    // five fixed palette stops; the rig is two families (hot rose and cool
    // sea-glass) with the third stop as the beat accent
    vec3 c0 = palVisual(0.02, u), c1 = palVisual(0.24, u), c2 = palVisual(0.48, u);
    vec3 c3 = palVisual(0.72, u), c4 = palVisual(0.97, u);
    k.base = c0; k.wa = mix(c0, c1, 0.5); k.wb = c4;
    k.fa = c4; k.fb = c1; k.k18 = c1;
    k.k92 = c4; k.k55 = mix(c0, c1, 0.35); k.k62 = c2; k.k80 = c3;
    k.s0 = c1; k.s1 = c4; k.s2 = c3; k.s3 = c1; k.s4 = c4;
    // beats alternate the accent between warm gold and an icy cool light
    float odd = mod(floor(u.beatCount), 2.0);
    k.acc = mix(c3 * vec3(1.3, 0.95, 0.6) + vec3(0.25, 0.08, 0.0), mix(c4, vec3(0.8, 0.95, 1.0), 0.4) * 1.2, odd);
    float lv = saturate(u.level);
    k.e1 = 0.8 + 0.2 * lv + 0.05 * bandRange(u, 0, 8);
    k.e2 = 0.8 + 0.2 * lv + 0.05 * bandRange(u, 16, 30);
    k.e3 = 0.8 + 0.2 * lv + 0.05 * bandRange(u, 34, 54);
    float es = 0.5 + 0.3 * lv;
    k.es0 = es + 0.05 * band(u, 4); k.es1 = es + 0.05 * band(u, 15); k.es2 = es + 0.05 * band(u, 26);
    k.es3 = es + 0.05 * band(u, 37); k.es4 = es + 0.05 * band(u, 48);
    k.ringE = 1.5 + 0.15 * lv;
    k.flE = 0.38 + 0.12 * lv + 0.03 * bandRange(u, 8, 24);
    k.beatPh = u.beatPhase;
    float sw = sin(3.14159265 * saturate(u.beatPhase));
    k.beatE = 0.03 * (0.5 + 0.5 * lv) * sw * sw;
    k.pool = 0.8 + 0.3 * lv;
    k.chase = 0.0;
    return k;
}

// Emission of the glass floor at plane point xz: fine neon rings round the
// centre, slow radial spokes, and the beat ring racing outwards.
vec3 chFloor(vec2 xz, float ph, ChRig k) {
    float r = length(xz);
    float a = atan2_(xz.y, xz.x);
    float rg = abs(fract(r * 1.1 - ph * 0.004) - 0.5);
    float ring = smoothstep(0.04 + 0.015 * r, 0.0, rg) * k.flE;
    float sp = smoothstep(0.03, 0.0, abs(fract(a * 1.909859 + ph * 0.003) - 0.5) * r * 0.5);
    float fall = smoothstep(9.0, 3.5, r) / (1.0 + r * r * 0.05);
    vec3 c = mix(k.fa, k.fb, saturate(r * 0.12)) * ring * fall * 0.5;
    c += k.k18 * sp * fall * smoothstep(1.0, 3.0, r) * 0.25;
    // the beat ring: born under the bodies, racing out with a fading wake
    float x = r - (0.6 + k.beatPh * 9.0);
    float bw = exp(-x * x * 30.0) + 0.07 * exp(x * 2.5) * step(x, 0.0);
    c += k.acc * 1.4 * bw * k.beatE;
    // a soft pool of light under the cluster
    c += k.k92 * exp(-r * r * 0.3) * 0.03 * k.pool;
    return c;
}

// The light rig, seen in a direction. Everything here is what the chrome
// mirrors; direct is the softened version the camera sees as the backdrop.
vec3 chEnv(vec3 d, float ph, ChRig k, float direct) {
    float y = d.y;
    float phi = atan2_(d.z, d.x);
    float soft = mix(0.03, 1.6, direct);
    vec3 c = k.base * 0.004;
    // a faint coloured wash in the dark dome, so the black reads as depth
    c += mix(k.wa, k.wb, 0.5 + 0.5 * sin(phi * 2.0 + ph * 0.01)) * smoothstep(0.0, 0.7, y) * mix(0.04, 0.012, direct);
    // below the horizon the glass floor's rings, so each body carries the
    // floor's pattern on its lower half
    float fl = smoothstep(-0.02, -0.12, y);
    if (fl > 0.0) {
        vec2 fxz = d.xz * (CH_FLOOR / max(-y, 0.03));
        c += (chFloor(fxz, ph, k) * 3.0 + k.s4 * 0.004) * fl * mix(1.0, 0.25, direct);
    }
    // a hot band drops down the rig on every beat
    float ys = mix(0.95, -0.02, sqrt(k.beatPh));
    float yb = (y - ys) * mix(28.0, 6.0, direct);
    c += k.acc * exp(-yb * yb) * k.beatE * mix(2.0, 0.04, direct) * step(-0.05, y);
    c += k.k62 * exp(-abs(y + 0.02) * 70.0) * mix(1.4, 0.10, direct) * 0.9;
    // three big coloured softboxes; the third sweeps slowly round the rig
    float sw = ph * 0.02;
    vec3 c1 = vec3(-0.8963, 0.2490, 0.2988);
    vec3 c2 = vec3(0.9228, 0.1086, -0.3800);
    vec3 c3 = normalize(vec3(sin(sw) * 0.8, 0.55, cos(sw) * 0.8));
    float pk = mix(2.1, 0.03, direct);
    float sl = 1.0 - direct;
    // each softbox runs a gradient between the two families along its length
    vec2 P1 = chPanel(d, c1, vec3(0.3162, 0.0, 0.9487), vec2(0.22, 0.75), soft, sl);
    vec2 P2 = chPanel(d, c2, vec3(-0.3807, 0.0, -0.9247), vec2(0.18, 0.9), soft, sl);
    vec2 P3 = chPanel(d, c3, vec3(cos(sw), 0.0, -sin(sw)), vec2(0.6, 0.10), soft, sl);
    c += mix(k.k18, k.base * 1.6, 0.5 + 0.5 * P1.y) * P1.x * pk * k.e1;
    c += mix(k.k92, k.wa, 0.5 - 0.5 * P2.y) * P2.x * pk * k.e2;
    c += mix(k.k55, k.k92, 0.5 + 0.5 * P3.y) * P3.x * pk * k.e3;
    // thin strip lights between them, each on its own band
    float sv = smoothstep(-0.5, -0.2, y) * smoothstep(0.9, 0.6, y);
    if (sv > 0.0) {
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float a = fi * 1.2566371 + ph * 0.012 + 0.9;
            float ad = abs(atan2_(sin(phi - a), cos(phi - a)));
            float w = 0.012 + 0.008 * fract(fi * 0.618) + direct * 0.04;
            float strip = smoothstep(w, w * 0.3, ad) * sv;
            // light chases up each strip, faster when the profile surges
            float cy = fract(y * 1.3 - k.chase * (1.0 + 0.37 * fi) + fi * 0.31) - 0.5;
            strip *= 0.45 + 0.45 * exp(-cy * cy * mix(60.0, 8.0, direct));
            vec3 sc = i == 0 ? k.s0 * k.es0 : i == 1 ? k.s1 * k.es1 : i == 2 ? k.s2 * k.es2 : i == 3 ? k.s3 * k.es3 : k.s4 * k.es4;
            c += sc * strip * mix(4.0, 0.12, direct);
        }
    }
    // overhead ring light
    float yr = (y - 0.86) * mix(30.0, 8.0, direct);
    c += mix(vec3(1.0), k.k80, 0.55) * exp(-yr * yr) * k.ringE * mix(0.8, 0.04, direct);
    return c;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    ChRig k = chRigMake(u);

    vec2 fl = chFlight(u, 0.6, -0.24);
    float ph = mod(fl.x, 2400.0);
    k.chase = mod(fl.x * 0.12, 64.0);
    float tb = mod(u.time, 600.0);
    float nb = floor(mix(4.0, 6.0, u.param0) + 0.5);
    float refl = mix(0.6, 1.25, u.param1);
    float rip = mix(0.0, 0.012, u.param2) * (0.3 + 0.2 * saturate(u.level));

    // bodies drift on their own clock; the speed profile only turns the camera
    float bt = tb * 0.11 + ph * 0.11;
    vec4 b0 = chBody(0, bt, u), b1 = chBody(1, bt, u), b2 = chBody(2, bt, u), b3 = chBody(3, bt, u);
    vec4 b4 = chBody(4, bt, u), b5 = chBody(5, bt, u);
    vec4 b6 = vec4(1.7 * sin(bt * 0.21), 0.9 * sin(bt * 0.17 + 1.0), 1.4 * cos(bt * 0.21), 0.16);
    vec4 wob = vec4(bt * 0.55, bt * 0.43, bt * 0.61, 0.030 * (0.8 + 0.3 * saturate(u.level)));

    float orb = ph * 0.035;
    float yaw = orb + 0.3 * sin(orb * 0.6);
    float pitch = 0.1 + 0.1 * sin(orb * 0.5 + 1.0);
    float dist = 2.75 - 0.3 * sin(orb * 0.41);
    vec3 ro = dist * vec3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch));
    vec3 rd = osCamera(ro, vec3(0.0), osBank(u, 0.01), 1.62, p);

    int n = osSteps(36.0, 80.0, detail);
    float t = 0.5;
    bool hit = false;
    for (int i = 0; i < 80; i++) {
        if (i >= n) break;
        float d = chMap(ro + rd * t, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob);
        if (d < 0.001 * t) { hit = true; break; }
        t += d * 0.9;
        if (t > 9.0) break;
    }

    vec3 col;
    if (!hit) {
        // the rig itself, defocused, as the backdrop, with out-of-focus
        // droplets drifting far behind the bodies
        col = chEnv(rd, ph, k, 1.0);
        for (int i = 0; i < 7; i++) {
            float fi = float(i);
            vec2 h = hash22(vec2(fi * 3.7, 1.3));
            vec2 bc = vec2(h.x * 4.0 - 2.0 + 0.25 * sin(tb * 0.05 + fi), h.y * 2.2 - 1.1)
                    + vec2(-yaw * 0.6, 0.0);
            bc.x = mod(bc.x + 2.4, 4.8) - 2.4;
            float br = 0.05 + 0.1 * fract(fi * 0.618);
            float dd = length(p - bc) - br;
            float disc = smoothstep(0.02, -0.01, dd) * (0.6 + 0.4 * smoothstep(-br, 0.0, dd));
            vec3 dc = i % 3 == 0 ? k.k18 : i % 3 == 1 ? k.k92 : k.k80;
            col += dc * disc * (0.05 + 0.04 * saturate(u.level));
        }
        // the black glass floor: its own neon rings plus a soft mirror of the
        // bodies (as spheres, blurred with height) and the rig
        if (rd.y < -0.01) {
            float tf = (-CH_FLOOR - ro.y) / rd.y;
            vec3 fp = ro + rd * tf;
            vec3 rr = vec3(rd.x, -rd.y, rd.z);
            float best = 1e4; vec3 bn = vec3(0.0, 1.0, 0.0); float cov = 0.0;
            for (int i = 0; i < 7; i++) {
                vec4 b = i == 0 ? b0 : i == 1 ? b1 : i == 2 ? b2 : i == 3 ? b3 : i == 4 ? b4 : i == 5 ? b5 : b6;
                if ((i == 4 && nb < 4.5) || (i == 5 && nb < 5.5)) continue;
                vec3 oc = b.xyz - fp;
                float tc = dot(oc, rr);
                if (tc <= 0.0) continue;
                float dd = length(oc - rr * tc);
                float blur = 0.03 + 0.12 * tc;
                cov = max(cov, smoothstep(b.w + blur, b.w - blur, dd));
                if (dd < b.w && tc < best) {
                    best = tc;
                    vec3 hp = fp + rr * (tc - sqrt(max(b.w * b.w - dd * dd, 0.0)));
                    bn = (hp - b.xyz) / b.w;
                }
            }
            vec3 mir = chEnv(best < 1e3 ? reflect(rr, bn) : rr, ph, k, best < 1e3 ? 0.35 : 0.85);
            mir = mix(mir * (1.0 - cov), mir, best < 1e3 ? cov : 0.0);
            float ff = 0.05 + 0.4 * pow(1.0 - abs(rd.y), 4.0);
            vec3 fc = chFloor(fp.xz, ph, k) + mir * ff * refl;
            col = mix(col, fc, exp(-tf * 0.08) * smoothstep(-0.01, -0.06, rd.y));
        }
    } else {
        vec3 pos = ro + rd * t;
        vec2 e = vec2(0.0015, -0.0015);
        vec3 nor = e.xyy * chMap(pos + e.xyy, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob) +
                   e.yyx * chMap(pos + e.yyx, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob) +
                   e.yxy * chMap(pos + e.yxy, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob) +
                   e.xxx * chMap(pos + e.xxx, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob);
        float nl = length(nor);
        nor = nl > 1e-6 ? nor / nl : vec3(0.0, 1.0, 0.0);
        vec3 r = reflect(rd, nor);
        // one more bounce: the bodies mirror each other
        int n2 = osSteps(10.0, 32.0, detail);
        float t2 = 0.02;
        bool hit2 = false;
        for (int i = 0; i < 32; i++) {
            if (i >= n2) break;
            float d = chMap(pos + r * t2, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob);
            if (d < 0.002) { hit2 = true; break; }
            t2 += d;
            if (t2 > 5.0) break;
        }
        vec3 rc;
        if (hit2) {
            // the neighbour mirrors the rig in turn, a little darker
            vec3 p2 = pos + r * t2;
            vec3 m2 = e.xyy * chMap(p2 + e.xyy, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob) +
                      e.yyx * chMap(p2 + e.yyx, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob) +
                      e.yxy * chMap(p2 + e.yxy, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob) +
                      e.xxx * chMap(p2 + e.xxx, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob);
            float ml = length(m2);
            m2 = ml > 1e-6 ? m2 / ml : nor;
            rc = chEnv(reflect(r, m2), ph, k, 0.0) * 0.6;
        } else {
            rc = chEnv(r, ph, k, 0.0);
        }
        // chrome: a high, slightly tinted reflectance with a Schlick rise
        float ndv = saturate(dot(nor, -rd));
        float fr = 0.72 + 0.28 * pow(1.0 - ndv, 5.0);
        vec3 tint = mix(vec3(1.0), k.s2, 0.10);
        // a thin-film sheen on the grazing edges
        vec3 film = 0.55 + 0.55 * cos(6.2831853 * (ndv * 1.7 + vec3(0.0, 0.33, 0.67) + ph * 0.002));
        tint = mix(tint, film, pow(1.0 - ndv, 2.0) * 0.6);
        // cheap occlusion in the creases where bodies merge
        float ao = saturate(0.4 + 0.6 * chMap(pos + nor * 0.15, b0, b1, b2, b3, b4, b5, b6, nb, rip, wob) / 0.15);
        col = rc * fr * tint * refl * ao;
    }

    return chOffRed(max(col, vec3(0.0))); // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
