// SPDX-License-Identifier: AGPL-3.0-only
// Rain.
// A slow walk at ankle height down a rain-soaked street at night. Both walls
// carry rows of upright neon tubes whose height breathes with their band,
// so the street is a spectrum running low to high and back; neon gates span
// the street overhead and a strip line runs along each wall. The black floor
// is wet: puddles mirror everything in long vertical smears, every drop rings
// the puddles and throws a crown of droplets near the camera, and the falling
// rain is lit by whichever neon it passes, nearest drops dimmest. The camera
// keeps a slow steady pace with no roll. Audio drives the light, gently: the
// smoothed level with a trace of each band sets the tubes and the tower
// meter, a beat sends a faint pulse down the street, and nothing flashes or
// jumps with the kick, so the neon glows and fades instead of strobing.
// param0 = Density ; param1 = Fall Speed ; param2 = Reflection

const float RN_W = 4.2;      // street half-width
const float RN_BAR = 1.6;    // tube spacing along each wall
const float RN_GATE = 14.0;  // spacing of the gates over the street
const float RN_GY = 3.9;     // gate height
const float RN_STRIP = 3.3;  // wall strip height
const float RN_CELL = 0.6;   // ripple / splash cell
const float RN_FOG = 0.042;

float rnHash(vec2 c) { return hash21(mod(c, 1024.0) + 0.5); }

// Keeps every red just off saturated red once tonemapped: green and blue
// rise together until they make 0.27 of red, so no red area can strobe.
float rnTone(float x) { return x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14); }
float rnToneInv(float y) {
    y = clamp(y, 0.0, 0.999);
    float a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y;
    return (-b + sqrt(b * b + 0.56 * a * y)) / (2.0 * a);
}
vec3 rnOffRed(vec3 c) {
    float r = rnTone(c.r), g = rnTone(c.g), b = rnTone(c.b);
    float need = 0.27 * r - g - b;
    if (need <= 0.0) return c;
    c.g = rnToneInv(g + 0.5 * need);
    c.b = rnToneInv(b + 0.5 * need);
    return c;
}

// Spectrum position of a tube: along each wall the bars run low to high and back.
float rnBarF(float cz, float side) {
    float f = fract(cz * (1.0 / 24.0) + side * 0.25);
    return abs(f * 2.0 - 1.0);
}

float rnPulse(float z, float zb, VisualUniforms u) {
    float ph = saturate(u.beatPhase);
    return exp(-(z - zb) * (z - zb) * 0.03) * smoothstep(0.0, 0.04, ph) * (1.0 - ph);
}

// Emission of the wall at w = (z, y). blur widens every edge (vertically
// stretched for the wet-floor reflection, and with distance against aliasing).
vec3 rnWall(vec2 w, float side, float blur, float zb, VisualUniforms u) {
    float bs = 1.0 + blur * 3.0;
    // upright spectrum tubes
    float qz = w.x / RN_BAR + side * 0.37;
    float cz = floor(qz);
    float lz = (qz - cz - 0.5) * RN_BAR;
    float f = rnBarF(cz, side);
    float lv = 0.45 * saturate(u.level) + 0.3 * bandAt(u, 0.03 + 0.9 * f);
    float top = 0.9 + 1.6 * lv;
    float dxb = max(abs(lz) - 0.04, 0.0);
    float dyb = max(max(0.15 - w.y, w.y - top), 0.0) / bs;
    float d = length(vec2(dxb, dyb));
    vec3 bc = palVisual(0.05 + 0.85 * f, u);
    bc = peakWhite(bc, 0.25 * smoothstep(top - 0.35, top, w.y) * lv);
    float core = 1.0 - smoothstep(0.0, 0.012 + 0.05 * blur, d);
    float halo = exp(-d * 5.0 / (1.0 + blur * 2.0));
    vec3 e = bc * (core * 3.2 + halo * 0.45) * (0.5 + 0.5 * lv);
    // storefront segments: a sign line at its own height, lifted by the bass and
    // swept by the beat pulse, over a softly lit shop window
    float qs = w.x / 7.0 + side * 0.31;
    float sg = floor(qs);
    float ls = (qs - sg) * 7.0;
    float h1 = rnHash(vec2(sg, side * 5.0 + 1.0));
    float h2 = rnHash(vec2(sg, side * 5.0 + 2.0));
    float hy = RN_STRIP - 0.9 + 1.3 * h1;
    float sl = 1.6 + 2.2 * h2;
    float dzs = max(abs(ls - 3.5) - sl, 0.0);
    float dys = length(vec2(dzs, (w.y - hy) / bs));
    vec3 sc = palVisual(fract(0.3 + 0.55 * h1 + 0.25 * side), u);
    float drive = 0.85 + 0.1 * u.level + 0.08 * rnPulse(w.x, zb, u);
    e += sc * ((1.0 - smoothstep(0.0, 0.02 + 0.06 * blur, dys)) * 2.2 + exp(-dys * 8.0) * 0.3) * drive;
    if (h2 > 0.35) {
        vec2 sd = vec2(max(abs(ls - 3.5) - 2.2, 0.0), max(abs(w.y - 1.05) - 0.8, 0.0) / bs);
        float shop = exp(-dot(sd, sd) * 60.0 / (1.0 + blur * 4.0));
        vec3 shc = mix(vec3(0.9, 0.55, 0.35), palVisual(fract(h1 * 3.0), u), 0.5);
        e += shc * shop * (0.03 + 0.05 * smoothstep(1.85, 0.25, w.y)) * (0.7 + 0.6 * h1);
    }
    // tall signboards high on the walls: a neon outline around rows of
    // glyph blocks that change slowly, lit by their own spectrum band
    if (w.y > 4.2) {
        float qg = w.x / 9.0 + side * 0.23;
        float gs = floor(qg);
        float lg = (qg - gs) * 9.0;
        float g1 = rnHash(vec2(gs, side * 7.0 + 3.0));
        float g2 = rnHash(vec2(gs, side * 7.0 + 4.0));
        if (g1 > 0.2) {
            float hwid = 0.5 + 0.45 * g1;
            float cx = 1.2 + hwid + (6.6 - 2.0 * hwid) * g2;
            float y0 = 4.6 + 1.4 * g2;
            float hh = 1.4 + 1.6 * g1;
            vec2 lp = vec2(lg - cx, (w.y - y0 - hh) / bs);
            vec2 hb = vec2(hwid, hh / bs);
            vec2 dq = abs(lp) - hb;
            float box = length(max(dq, 0.0)) + min(max(dq.x, dq.y), 0.0);
            float bd = abs(box);
            vec3 gcA = palVisual(fract(0.12 + 0.62 * g2 + 0.5 * side), u);
            vec3 gcB = palVisual(fract(0.62 + 0.62 * g2 + 0.5 * side), u);
            float glv = bandAt(u, 0.1 + 0.8 * g1);
            float gdrive = 0.7 + 0.3 * u.level + 0.2 * glv + 0.12 * rnPulse(w.x, zb, u);
            e += gcA * ((1.0 - smoothstep(0.0, 0.025 + 0.06 * blur, bd)) * 2.6 + exp(-bd * 7.0) * 0.25) * gdrive;
            if (box < 0.0) {
                // glyph grid: two columns of blocks, each a stack of strokes
                vec2 gq = (vec2(lg - cx, w.y - y0 - hh) + vec2(hwid, hh)) / vec2(hwid, 0.62);
                vec2 gc = floor(gq);
                vec2 gl = fract(gq) - 0.5;
                float gt = floor(mod(u.time, 600.0) * 0.35 + rnHash(gc + gs));
                float on = step(0.3, rnHash(gc + vec2(gs * 3.1, side + mod(gt, 97.0))));
                float st = rnHash(gc + vec2(gs, 9.0 + mod(gt, 97.0)));
                // a stroke pattern per block: bars or a box
                float bar = st > 0.5 ? abs(gl.y) - 0.08 : max(abs(gl.x), abs(gl.y)) - 0.24;
                float blk = max(max(abs(gl.x) - 0.3, abs(gl.y) - 0.34), st > 0.5 ? bar : abs(bar) - 0.06);
                float gd = max(blk, 0.0);
                float gly = (1.0 - smoothstep(0.0, 0.05 + 0.1 * blur, gd)) * on;
                e += gcB * gly * 1.6 * gdrive + gcA * 0.025;
            }
        }
    }
    // dim windows high above
    if (w.y > 4.4) {
        vec2 wq = vec2(w.x / 0.75 + side * 0.5, (w.y - 4.4) / 0.95);
        vec2 wc = floor(wq);
        vec2 wl = abs(fract(wq) - 0.5);
        float hw = rnHash(wc + side * 41.0);
        float lit = step(0.6, hw);
        float win = (1.0 - smoothstep(0.26, 0.3 + 0.2 * blur, wl.x)) * (1.0 - smoothstep(0.24, 0.28 + 0.2 * blur, wl.y));
        vec3 wcol = mix(vec3(0.9, 0.55, 0.3), vec3(0.35, 0.5, 0.9), rnHash(wc + 7.0));
        e += wcol * win * lit * (0.015 + 0.08 * rnHash(wc + 3.0) * rnHash(wc + 3.0));
    }
    return e;
}

// Neon gates over the street, crossed by a ray up to tmax.
vec3 rnGates(vec3 ro, vec3 rd, float tmax, float blur, VisualUniforms u, float zb) {
    vec3 e = vec3(0.0);
    if (rd.z < 0.02) return e;
    float g0 = floor(ro.z / RN_GATE) + 1.0;
    float drive = 0.95 + 0.1 * u.level;
    vec3 acc = mod(floor(u.beatCount), 2.0) < 0.5 ? vec3(1.0, 0.5, 0.12) : vec3(0.1, 0.65, 1.0);
    for (int k = 0; k < 4; k++) {
        float gi = g0 + float(k);
        float t = (gi * RN_GATE - ro.z) / rd.z;
        if (t > tmax) break;
        vec3 q = ro + rd * t;
        float dy = abs(q.y - RN_GY) / (1.0 + blur * 3.0);
        float dx = max(abs(q.x) - RN_W, 0.0);
        float d = length(vec2(dx, dy)) / (1.0 + 0.004 * t);
        vec3 gc = palVisual(0.55 + 0.4 * rnHash(vec2(gi, 2.0)), u);
        float pls = rnPulse(gi * RN_GATE, zb, u);
        gc = mix(gc, acc, 0.15 * pls);
        float pz = 1.0 + 0.15 * pls;
        e += gc * ((1.0 - smoothstep(0.0, 0.035 + 0.08 * blur, d)) * 3.0 + exp(-d * 4.5) * 0.35)
             * drive * pz * exp(-t * RN_FOG);
    }
    return e;
}

vec3 rnHaze(vec3 rd, vec3 ha, vec3 hb) {
    return mix(ha, hb, 0.5 + 0.4 * rd.x);
}

// Roofline of the buildings along one wall.
float rnRoof(float z, float side) {
    return 12.6 + 8.0 * rnHash(vec2(floor(z / 11.0 + side * 0.4), side * 3.0 + 21.0));
}

// The far city beyond the street: low cloud lit from below by the neon, and
// at the end of the street a tower whose facade is a spectrum meter, its
// spine flaring warm or cool on alternate beats.
vec3 rnSky(vec3 rd, vec3 ha, vec3 hb, float blur, float open, VisualUniforms u) {
    float tm = mod(u.time, 600.0);
    float hz = max(length(rd.xz), 1e-3);
    float e = rd.y / hz;
    float az = rd.x / max(rd.z, 0.05);
    vec3 base = rnHaze(rd, ha, hb);
    float glow = exp(-max(e, 0.0) * 4.0);
    vec2 cq = rd.xz / max(rd.y, 0.06) * 0.5 + vec2(0.0, tm * 0.35);
    float cn = vnoise(cq * 0.6) + 0.5 * vnoise(cq * 1.7 + 3.0);
    vec3 under = mix(palVisual(0.62, u), vec3(0.55, 0.1, 0.9), 0.4);
    float hi = smoothstep(0.06, 0.35, e) * open;
    vec3 c = base * (1.0 - 0.5 * hi)
           + under * smoothstep(0.6, 1.3, cn) * hi * (0.035 + 0.05 * glow);
    // side towers: dark, with sparse warm windows and a thin neon crown
    for (int k = 0; k < 2; k++) {
        float cx = k == 0 ? -0.15 : 0.13;
        float hw = k == 0 ? 0.045 : 0.035;
        float top = k == 0 ? 0.26 : 0.33;
        float dx = abs(az - cx) - hw;
        if (dx < 0.0 && e < top) {
            vec2 wc = floor(vec2(az * 260.0, e * 150.0));
            float wl = step(0.82, rnHash(wc + float(k) * 17.0));
            c = base * 0.45 + vec3(0.9, 0.55, 0.3) * wl * 0.05;
            c += palVisual(k == 0 ? 0.3 : 0.8, u) * exp(-abs(e - top) * 400.0) * 1.2;
        }
    }
    // the spectrum tower
    float tdx = abs(az) - 0.075;
    float ttop = 0.5;
    if (tdx < 0.0 && e < ttop) {
        float f = saturate((az + 0.075) / 0.15);
        float colI = floor(f * 12.0);
        float fb = (colI + 0.5) / 12.0;
        float lv = 0.45 * saturate(u.level) + 0.3 * bandAt(u, 0.03 + 0.9 * abs(fb * 2.0 - 1.0));
        float fill = ttop * (0.12 + 0.82 * lv);
        vec2 wq = vec2(f * 12.0, e / 0.011);
        vec2 wl = abs(fract(wq) - 0.5);
        float win = (1.0 - smoothstep(0.3, 0.36 + blur * 0.2, wl.x)) * (1.0 - smoothstep(0.28, 0.34 + blur * 0.2, wl.y));
        vec3 wcol = palVisual(0.05 + 0.85 * abs(fb * 2.0 - 1.0), u);
        float on = smoothstep(fill + 0.004, fill - 0.004, e);
        float topRow = exp(-abs(e - fill) * 300.0);
        c = base * 0.3 + wcol * win * (on * (0.9 + 0.5 * lv) + topRow * 1.2 + 0.03);
        // the spine
        float par = mod(floor(u.beatCount), 2.0);
        vec3 acc = par < 0.5 ? vec3(1.0, 0.5, 0.12) : vec3(0.1, 0.65, 1.0);
        float sp = exp(-az * az * 90000.0 / (1.0 + blur * 6.0));
        float pulse = exp(-abs(e - ttop * saturate(u.beatPhase)) * 40.0) * (1.0 - saturate(u.beatPhase));
        c += acc * sp * (0.6 + 0.2 * pulse);
    }
    // the crown of the tower and its slow warning beacon
    float bd = length(vec2(az, (e - ttop - 0.012) * 0.6));
    float blink = 0.5 - 0.5 * cos(tm * 3.14159265);
    c += vec3(1.0, 0.15, 0.08) * exp(-bd * bd * 4e5 / (1.0 + blur * 8.0)) * (0.3 + 1.0 * blink);
    c += mix(palVisual(0.9, u), vec3(1.0), 0.3) * exp(-abs(e - ttop) * 500.0) * step(abs(az), 0.075) * 0.8;
    return c;
}

// Everything a ray that leaves the floor sees: a wall, the gates, the haze,
// and the city above the rooftops.
vec3 rnTrace(vec3 ro, vec3 rd, float blur, float zb, vec3 ha, vec3 hb, VisualUniforms u) {
    float side = rd.x >= 0.0 ? 1.0 : -1.0;
    float tw = abs(rd.x) > 1e-4 ? (side * RN_W - ro.x) / rd.x : 400.0;
    tw = clamp(tw, 0.0, 400.0);
    vec3 pw = ro + rd * tw;
    float fog = exp(-tw * RN_FOG);
    vec3 c = vec3(0.0);
    float roof = rnRoof(pw.z, side);
    if (pw.y > roof) {
        c = rnSky(rd, ha, hb, blur, 1.0, u);
    } else {
        // the fog in front of a wall hides the clouds, not the far towers
        vec3 far = fog < 0.99 ? rnSky(rd, ha, hb, blur, 0.0, u) : vec3(0.0);
        if (fog > 0.01) c = rnWall(pw.zy, side, blur + tw * 0.004, zb, u) * fog;
        // a neon line along the parapet
        float pe = exp(-abs(pw.y - roof) * 14.0 / (1.0 + blur * 3.0 + tw * 0.01));
        c += palVisual(side > 0.0 ? 0.82 : 0.28, u) * pe * 0.6 * fog * (0.8 + 0.2 * u.level);
        c += far * (1.0 - fog);
    }
    c += rnGates(ro, rd, tw, blur, u, zb);
    return c;
}

// Cheap neon light falling on a point in the street (rain, splashes, floor).
vec3 rnLight(vec3 q, VisualUniforms u) {
    vec3 l = vec3(0.0);
    for (int s = 0; s < 2; s++) {
        float side = s == 0 ? -1.0 : 1.0;
        float dw = max(RN_W - side * q.x, 0.05);
        float qz = q.z / RN_BAR + side * 0.37;
        float f = rnBarF(floor(qz), side);
        l += palVisual(0.05 + 0.85 * f, u) * (0.5 + 0.5 * u.level) / (1.0 + dw * dw * 0.35);
    }
    float gz = q.z - RN_GATE * floor(q.z / RN_GATE + 0.5);
    float gy = q.y - RN_GY;
    l += palVisual(0.75, u) * 0.6 / (1.0 + (gz * gz + gy * gy) * 0.25);
    return l;
}

// One rain cycle of a floor cell: x = age (s), y = 1 when the cell drops this cycle,
// z = the impact's x offset in the cell.
vec3 rnDrop(vec2 c, float tm, float dens) {
    float per = 0.9 + 0.8 * rnHash(c + 17.3);
    float k = tm / per + rnHash(c);
    float ci = floor(k);
    float h = rnHash(c + vec2(mod(ci, 509.0) * 1.37, 5.0));
    return vec3((k - ci) * per, step(h, dens), (rnHash(c + vec2(3.1, mod(ci, 509.0))) - 0.5) * 0.16);
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float tm = mod(u.time, 600.0);
    float dens = mix(0.25, 0.85, u.param0);
    float fall = mix(2.5, 6.5, u.param1);
    float wet = u.param2;

    // camera: ankle height, a slow walk with a gentle weave; the audio never moves it
    vec2 fl = osFlight(u, 0.0, 0.0);
    fl.x += 0.22 * u.time;
    float z = fl.x;
    vec3 ro = vec3(1.1 * sin(z * 0.045) + 0.4 * sin(z * 0.11 + 1.0), 0.5 + 0.08 * sin(z * 0.07), z);
    vec3 ta = vec3(0.6 * sin((z + 7.0) * 0.045) + 0.3 * sin(z * 0.03 + 2.0), 1.35, z + 7.0);
    float roll = 0.0;
    vec3 rd = osCamera(ro, ta, roll, 1.2, p);
    float zb = z + 3.0 + 34.0 * saturate(u.beatPhase);
    float hl = 0.03 + 0.05 * u.level;
    vec3 ha = palVisual(0.2, u) * hl + vec3(0.004, 0.005, 0.012);
    vec3 hb = palVisual(0.62, u) * hl + vec3(0.004, 0.005, 0.012);

    vec3 col;
    float tHit;
    float tf = rd.y < -1e-4 ? -ro.y / rd.y : 1e4;
    float side = rd.x >= 0.0 ? 1.0 : -1.0;
    float tw = abs(rd.x) > 1e-4 ? (side * RN_W - ro.x) / rd.x : 1e4;
    if (tf < tw) {
        // the wet floor
        tHit = tf;
        vec3 q = ro + rd * tf;
        float pn = vnoise(q.xz * 0.32) + 0.3 * vnoise(q.xz * 1.4 + 9.0);
        float pm = smoothstep(0.62 - 0.45 * wet, 0.72 - 0.45 * wet, pn);
        vec3 n = vec3(0.0, 1.0, 0.0);
        // asphalt grain where it is not pooled
        float gr = vnoise(q.xz * vec2(16.0, 7.0)) - 0.5;
        n.xz += vec2(gr, vnoise(q.xz * vec2(7.0, 16.0) + 4.0) - 0.5) * 0.035 * (1.0 - pm);
        // ripple rings from the drops, near the camera
        float near = saturate(1.0 - tf / 16.0);
        if (near > 0.0) {
            vec2 c = floor(q.xz / RN_CELL);
            vec3 dr = rnDrop(c, tm, dens);
            vec2 l = q.xz - (c + 0.5) * RN_CELL - vec2(dr.z, 0.0);
            float r = length(l);
            float ph = dr.x / 1.7;
            float rr = 0.01 + 0.15 * sqrt(saturate(ph));
            float x = r - rr;
            float wave = sin(x * 90.0) * exp(-x * x * 2500.0) * (1.0 - ph) * (1.0 - ph) * dr.y;
            n.xz += l / max(r, 1e-3) * wave * (0.05 + 0.2 * pm) * near;
        }
        n = normalize(n);
        vec3 rr = reflect(rd, n);
        rr.y = max(rr.y, 0.015);
        rr = normalize(rr);
        float fres = 0.06 + 0.94 * pow(1.0 - saturate(dot(n, -rd)), 3.0);
        float blur = mix(1.3, 0.05, pm) + tf * 0.01;
        vec3 refl = rnTrace(q, rr, blur, zb, ha, hb, u);
        float strength = mix(0.25, 1.0, pm) * mix(0.5, 1.2, wet);
        // neon pooling on the floor beside each wall
        vec3 pool = rnLight(q + vec3(0.0, 0.5, 0.0), u) * 0.03;
        col = pool + refl * fres * strength;
        float fog = exp(-tf * RN_FOG);
        col = col * fog + rnHaze(rd, ha, hb) * (1.0 - fog);
    } else {
        tHit = tw;
        col = rnTrace(ro, rd, 0.0, zb, ha, hb, u);
    }

    // light columns under the lamps on each gate, with the rain glittering in them
    vec2 rxz = rd.xz;
    float rl2 = max(dot(rxz, rxz), 1e-4);
    float lg0 = floor(ro.z / RN_GATE);
    for (int k = 0; k < 6; k++) {
        float gi = lg0 + 1.0 + float(k / 2);
        float lx = (k - 2 * (k / 2)) == 0 ? -1.9 : 1.9;
        vec2 lp = vec2(lx, gi * RN_GATE + 0.6);
        float sc = dot(lp - ro.xz, rxz) / rl2;
        if (sc < 0.0 || sc > tHit) continue;
        vec2 dd = ro.xz + rxz * sc - lp;
        float y = ro.y + rd.y * sc;
        float below = RN_GY - 0.1 - y;
        vec3 lc = palVisual(0.55 + 0.4 * rnHash(vec2(gi, 2.0)), u);
        // the lamp head itself
        float hd = dot(dd, dd) + below * below;
        col += (lc + 0.6) * exp(-hd * 260.0 / (1.0 + sc * 0.08)) * 2.5 * exp(-sc * RN_FOG);
        if (below < 0.0) continue;
        float r = 0.12 + 0.3 * below;
        float cone = exp(-dot(dd, dd) / (r * r)) * smoothstep(0.0, 0.4, below);
        float grain = 0.7 + 0.6 * vnoise(vec2(p.x * 60.0, p.y * 6.0 + tm * fall * 0.6));
        col += lc * cone * grain * (0.7 / (1.0 + 0.5 * below)) * (0.85 + 0.15 * u.level)
               * exp(-sc * RN_FOG) * inversesqrt(rl2);
    }

    // neon-tinted mist in the air
    col += rnLight(ro + rd * min(tHit, 5.0), u) * 0.03 * (1.0 - exp(-min(tHit, 30.0) * 0.08));

    // crowns of droplets where drops hit the floor near the camera
    if (rd.z > 0.05) {
        vec3 sp = vec3(0.0);
        float cz0 = floor((ro.z + 0.8) / RN_CELL);
        int ns = osSteps(4.0, 14.0, detail);
        for (int k = 0; k < 14; k++) {
            if (k >= ns) break;
            float cz = cz0 + float(k);
            float t = ((cz + 0.5) * RN_CELL - ro.z) / rd.z;
            if (t > tHit) break;
            vec3 q = ro + rd * t;
            if (q.y > 0.6) continue;
            float cx = floor(q.x / RN_CELL);
            vec2 c = vec2(cx, cz);
            vec3 dr = rnDrop(c, tm, dens);
            float age = dr.x;
            if (dr.y < 0.5 || age > 0.34) continue;
            vec2 l = vec2(q.x - (cx + 0.5) * RN_CELL - dr.z, q.y);
            float fade = 1.0 - age / 0.34;
            float a = 0.0;
            for (int j = 0; j < 6; j++) {
                float hj = rnHash(c + vec2(float(j) * 3.3, 11.0));
                float ang = (float(j) + 0.5) / 6.0 * 3.14159;
                vec2 v = vec2(cos(ang) * (0.25 + 0.35 * hj), 0.8 + 0.8 * hj);
                vec2 p1 = v * age - vec2(0.0, 4.9 * age * age);
                vec2 p0 = v * max(age - 0.025, 0.0) - vec2(0.0, 4.9 * max(age - 0.025, 0.0) * max(age - 0.025, 0.0));
                vec2 sg = p1 - p0;
                float hseg = saturate(dot(l - p0, sg) / max(dot(sg, sg), 1e-6));
                vec2 dd = l - p0 - sg * hseg;
                float w = 0.0042 + 0.0018 * t;
                a += exp(-dot(dd, dd) / (w * w)) * step(0.0, p1.y) * 1.3;
            }
            // the crown's base flash right at impact
            vec2 b = vec2(l.x * 0.5, l.y - 0.01);
            a += exp(-dot(b, b) * 9000.0) * saturate(1.0 - age * 8.0) * 1.5;
            if (a > 0.002) sp += (rnLight(vec3(q.x, 0.3, q.z), u) + vec3(0.05, 0.06, 0.09)) * a * fade * exp(-t * RN_FOG);
        }
        col += sp * (0.9 + 0.2 * u.level);
    }

    // falling rain in parallax layers, each streak lit by the neon it passes
    vec3 rain = vec3(0.0);
    float dl = 0.45;
    int nl = osSteps(3.0, 7.0, detail);
    for (int k = 0; k < 7; k++) {
        if (k >= nl) break;
        float fk = float(k);
        float t = dl / max(rd.z, 0.25);
        dl *= 2.0;
        if (t > tHit) break;
        vec3 q = ro + rd * t;
        vec2 sq = vec2(q.x + q.y * 0.1 + fk * 0.37, q.y + fall * (1.0 + 0.08 * fk) * tm + fk * 3.7);
        vec2 cs = vec2(0.13, 0.9);
        vec2 cl = floor(sq / cs);
        vec2 lq = sq - cl * cs;
        vec2 cid = cl + vec2(fk * 131.0, 0.0);
        float h = rnHash(cid);
        if (h > dens) continue;
        float ox = (0.15 + 0.7 * rnHash(cid + 7.7)) * cs.x;
        float len = 0.22 + 0.3 * rnHash(cid + 1.9);
        float oy = rnHash(cid + 3.3) * (cs.y - len);
        float w = 0.0035 + t * 0.0016 + 0.012 * exp(-t * 2.5);
        float sx = 1.0 - smoothstep(0.0, w, abs(lq.x - ox));
        float sy = smoothstep(oy, oy + len * 0.6, lq.y) * (1.0 - smoothstep(oy + len * 0.85, oy + len, lq.y));
        float a = sx * sy * (0.0035 / w) * (0.35 + 0.65 * smoothstep(0.5, 2.5, t));
        if (a > 0.001) rain += rnLight(q, u) * a * exp(-t * RN_FOG);
    }
    col += rain * (0.35 + 0.15 * u.level);
    return rnOffRed(max(col, vec3(0.0))); // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
