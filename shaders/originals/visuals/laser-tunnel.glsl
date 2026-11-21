// SPDX-License-Identifier: AGPL-3.0-only
// Laser tunnel.
// A flight down a hazed black-glass shaft rigged like a laser show. Fixtures
// set into the walls throw laser planes across the shaft: some are solid
// "liquid sky" sheets whose smoke drifts and curls through the light, others
// are fans of discrete beams. Every plane leans, yaws and sweeps on its own
// slow cycle, scribes a crisp line (or a row of beam dots) where it cuts the
// glass, and the glass mirrors those lines. Sheets burn in a warm family that
// drifts through the palette with the bars and the builds; beam fans and the
// scanner beams thrown from deep in the shaft burn in the cool complement.
// Every eight beats the rig slowly re-patches over about five beats (sheets
// fade into fans and back), and each
// beat the next fixture down the shaft swells softly while a faint shock plane
// drifts away. Calm under loud music: the camera flies at a slow, steady cruise
// with no beat surges, drifts slowly off axis with a gentle roll, and planes
// and the lines they scribe fade before they reach the lens, so nothing flashes the frame. Audio drives
// only light: the smoothed level plus a faint band term per fixture, with
// small soft beat accents on the chase and the shock plane; the scanner beams
// sweep slowly and their dashes crawl gently.
// Reds are kept just off saturated red.
// The shaft and every plane are solved analytically, so it costs little.
// param0 = Speed ; param1 = Sides ; param2 = Rail Glow

// The palette read without osPalVisual's per-beat and spectral-centroid hue
// nudge (common.glsl), so the whole frame never shifts colour with the beat or
// the timbre (manifest mode has no nudge).
vec3 ltPalStill(float t, VisualUniforms u) {
    if (u.palette.x >= 0.0) return palVisual(t, u);
    return palVisual(t - 0.015 * u.beatPhase - 0.08 * u.spectralCentroid, u);
}

const float LT_R = 2.4;      // apothem of the polygonal shaft
const float LT_SP = 4.0;     // fixture pitch along the shaft
const float LT_WRAP = 512.0; // distance wrap: a multiple of every z pattern below

// Nearest wall of the shaft along a ray: returns (t, face index).
vec2 ltTrace(vec3 ro, vec3 rd, float sides) {
    float best = 1e4;
    float face = 0.0;
    for (int i = 0; i < 8; i++) {
        if (float(i) >= sides) break;
        float th = (float(i) + 0.5) * 6.2831853 / sides;
        vec2 n = vec2(cos(th), sin(th));
        float dn = dot(rd.xy, n);
        if (dn > 1e-4) {
            float t = (LT_R - dot(ro.xy, n)) / dn;
            if (t < best) { best = t; face = float(i); }
        }
    }
    return vec2(best, face);
}

// Distance from a cross-section point to the shaft wall (> 0 inside).
float ltInside(vec2 q, float sides) {
    float m = -1e4;
    for (int i = 0; i < 8; i++) {
        if (float(i) >= sides) break;
        float th = (float(i) + 0.5) * 6.2831853 / sides;
        m = max(m, dot(q, vec2(cos(th), sin(th))));
    }
    return LT_R - m;
}

// Repeating line at fract(x) == 0.5 with half width hw and footprint w (x
// units per pixel): a crisp core when resolved, fading to its average
// coverage when not, so distant lines never alias.
float ltLine(float x, float hw, float w) {
    float d = abs(fract(x) - 0.5);
    w = max(w, 1e-4);
    return saturate((hw - d) / w + 0.5) * min(1.0, 2.0 * hw / w + 0.15);
}

// Single line at d == 0, same footprint rule.
float ltBar(float d, float hw, float w) {
    w = max(w, 1e-4);
    return saturate((hw - abs(d)) / w + 0.5) * min(1.0, 2.0 * hw / w + 0.15);
}

// Keep reds just off saturated red (judged after the filmic curve).
float ltTone(float x) { return x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14); }
float ltToneInv(float y) { y = clamp(y, 0.0, 0.999); float a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y; return (-b + sqrt(b * b + 0.56 * a * y)) / (2.0 * a); }
vec3 ltOffRed(vec3 c) { float r = ltTone(c.r), g = ltTone(c.g), b = ltTone(c.b); float need = 0.3 * r - g - b; if (need <= 0.0) return c; if (c.g > c.b) c.g = max(c.g, ltToneInv(g + need)); else c.b = max(c.b, ltToneInv(b + need)); return c; }

// Warm family: a smooth cycle through the palette's first three stops.
vec3 ltWarm(float h, vec3 a, vec3 b, vec3 c) {
    float x = fract(h) * 3.0;
    vec3 r = mix(a, b, smoothstep(0.0, 1.0, x));
    r = mix(r, c, smoothstep(1.0, 2.0, x));
    return mix(r, a, smoothstep(2.0, 3.0, x));
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);

    float sides = floor(mix(4.0, 8.0, u.param1) + 0.5);
    float railGlow = mix(0.3, 1.2, u.param2);
    float cruise = mix(0.7, 2.0, u.param0);
    float surge = -0.4 * cruise;                   // cancels the beat profile
    vec2 fl = osFlight(u, cruise, surge);
    float z = mod(fl.x, LT_WRAP);
    float speed = 1.0;
    float rush = saturate((speed - 1.0) / 3.0);
    float lull = saturate(1.0 - speed);
    // distance covered in about one frame at a 120 bpm reference tempo: the
    // motion-blur length of everything fixed to the shaft
    float mb = (cruise * 0.2 + 2.0 * speed * (cruise * 0.4 + surge)) * 0.75 / 60.0;

    float tt = mod(u.time, 600.0);
    float bp = saturate(u.beatPhase);
    float beats = mod(u.beatCount, 512.0) + bp;
    float lev = saturate(u.level);
    float bass = 0.0;

    // palette read once at fixed stops, blended locally
    vec3 cA = ltPalStill(0.02, u);
    vec3 cB = ltPalStill(0.25, u);
    vec3 cC = ltPalStill(0.50, u);
    vec3 cD = ltPalStill(0.77, u);
    vec3 cE = ltPalStill(0.97, u);
    vec3 cool = mix(cD, mix(cD, cE, 0.5) + 0.15 * cC, 0.25 + 0.25 * sin(tt * 0.13));
    float hue = beats / 32.0 + 0.25 * rush;

    // slow off-axis drift and look-around: time only, never audio
    vec2 off = vec2(sin(tt * 0.19), sin(tt * 0.13 + 1.1)) * 0.6;
    vec2 look = vec2(sin(tt * 0.19 - 0.9), sin(tt * 0.13 + 0.3)) * 0.4;
    vec3 ro = vec3(off, z);
    vec3 ta = vec3(look, z + 8.0);
    float roll = osBank(u, 0.01) + 0.12 * sin(tt * 0.07);
    float fov = 1.15 - 0.22 * rush + 0.08 * lull;
    vec3 rd = osCamera(ro, ta, roll, fov, p);
    float px = 2.0 / (u.resolution.y * fov);
    vec3 cf = normalize(ta - ro);
    vec3 cr = normalize(cross(cf, vec3(sin(roll), cos(roll), 0.0)));
    vec3 cu = cross(cr, cf);

    vec2 hit = ltTrace(ro, rd, sides);
    float t = hit.x;
    vec3 h = ro + rd * t;
    float th = (hit.y + 0.5) * 6.2831853 / sides;
    vec3 n = -vec3(cos(th), sin(th), 0.0);
    float cosi = saturate(-dot(rd, n));
    float fres = 0.06 + 0.6 * pow(1.0 - cosi, 5.0);

    // glossy reflection: where the reflected ray lands on the glass
    bool doRefl = detail > 0.3;
    vec3 rr = reflect(rd, n);
    vec3 o2 = h + n * 0.01;
    vec2 hit2 = ltTrace(o2, rr, sides);
    vec3 h2 = o2 + rr * hit2.x;
    float reflK = fres * exp(-hit2.x * 0.06) * (doRefl ? mix(0.5, 1.0, detail) : 0.0);

    float fogK = 0.04;
    float rdz = max(rd.z, 1e-3);
    float smokeT = tt * 0.25;
    float fixture = floor(beats);                  // which fixture the chase is on
    float phrase = beats / 8.0;
    float pk = floor(phrase);
    float pBlend = smoothstep(0.0, 0.6, fract(phrase));

    vec3 air = vec3(0.0);   // laser planes seen in the haze
    vec3 wall = vec3(0.0);  // lines scribed on the glass
    vec3 refl = vec3(0.0);  // the same lines in the reflection
    vec3 flare = vec3(0.0); // fixture lenses
    vec3 hazeE = vec3(0.0); // light the fixtures pour into the smoke
    float k0 = floor(z / LT_SP);
    int nSheets = osSteps(6.0, 12.0, detail);
    for (int k = 0; k < 12; k++) {
        if (k >= nSheets) break;
        float seg = k0 + float(k);
        float sid = mod(seg, 64.0);
        float hs = hash11(sid * 7.31 + 0.17);
        float hs2 = hash11(sid * 3.17 + 5.3);

        // fixture on a face of the shaft, its plane leaning, yawing and sweeping
        float face = floor(hs * sides);
        float phi = (face + 0.5) * 6.2831853 / sides;
        vec2 rad = vec2(cos(phi), sin(phi));
        vec2 tg = vec2(-rad.y, rad.x);
        float hsd = LT_R * tan(3.14159265 / sides);
        vec3 E = vec3(rad * (LT_R - 0.03) + tg * (hs2 - 0.5) * hsd * 1.1, seg * LT_SP + 1.5 * hs2);
        float tilt = 0.6 * sin(tt * (0.07 + 0.03 * hs) + hs * 6.2831853);
        float yaw = 0.45 * sin(tt * (0.06 + 0.03 * hs2) + hs2 * 6.2831853);
        vec3 N = normalize(vec3(rad * sin(tilt) + tg * sin(yaw), cos(tilt)));
        vec3 D0 = vec3(-rad, 0.0);
        D0 = normalize(D0 - N * dot(D0, N));
        vec3 P0 = cross(N, D0);
        float sw = 0.7 * sin(tt * (0.09 + 0.06 * hs) + hs2 * 9.0);
        vec3 D = D0 * cos(sw) + P0 * sin(sw);
        vec3 P = cross(N, D);
        float open = 0.5 + 0.4 * (0.5 + 0.5 * sin(tt * 0.07 + hs * 5.0)) + 0.2 * rush;
        // the rig re-patches every eight beats: sheets turn to beam fans
        float fanM = mix(step(0.55, hash11(sid * 1.3 + pk * 7.7)), step(0.55, hash11(sid * 1.3 + (pk + 1.0) * 7.7)), pBlend);
        float nb = 7.0 + 2.0 * floor(hs2 * 4.0);

        // light level: one spectrum band per fixture, and a chase down the
        // shaft that hits the next fixture on every beat
        float bl = bandAt(u, fract(0.08 + hs * 0.8));
        float chase = (mod(seg - fixture, 4.0) < 0.5 ? 1.0 : 0.0) * sin(3.14159265 * bp) * sin(3.14159265 * bp) * (0.03 + 0.02 * lev);
        float lvl = 0.35 + 0.25 * lev + 0.05 * bl + chase;
        vec3 sc = mix(ltWarm(hue + 0.13 * hs, cA, cB, cC), cool, fanM);

        // ---- the plane in the haze ----
        float den = dot(rd, N);
        float dens = den >= 0.0 ? max(den, 1e-4) : min(den, -1e-4);
        float tk = dot(E - ro, N) / dens;
        vec3 X = ro + rd * tk;
        vec3 v = X - E;
        float yv = dot(v, D);
        float xv = dot(v, P);
        float L = length(vec2(xv, yv));
        float ang = atan2_(xv, yv);
        float j = (ang + open) / (2.0 * open) * nb;
        float jw = fwidth(j);
        float near = smoothstep(1.5, 8.0 + 9.0 * rush, tk);
        float vis = smoothstep(open, open - 0.07, abs(ang)) * smoothstep(0.0, 0.2, L)
                  * near * step(0.2, tk) * step(tk, t);
        if (vis > 0.001) {
            // liquid-sky smoke drifting through the sheet
            // (domain-warped, with ridged strands curling through the body)
            vec2 sq = X.xy * 1.2 + vec2(X.z * 0.3 + smokeT, -smokeT * 0.6);
            vec2 wq = sq + 1.7 * vec2(vnoise(sq * 0.6 + vec2(sid, 0.0)), vnoise(sq * 0.6 + vec2(3.1, sid))) - 0.85;
            float n1 = vnoise(wq);
            float n2 = vnoise(wq * 2.4 + vec2(-smokeT * 1.3, 1.7));
            float body = smoothstep(0.25, 0.85, n1 * 0.65 + n2 * 0.35);
            float strand = pow(1.0 - abs(2.0 * n2 - 1.0), 6.0);
            float wisp = saturate(body * (0.75 * body + 0.8 * strand));
            float aden = max(abs(den), 0.07);
            float sheet = (0.02 + 0.9 * wisp * wisp) * 0.5 / sqrt(den * den + 0.012);
            // discrete beams of a fan, kept to a pixel when far
            float bw = (0.012 + 0.003 * L) / max(aden, 0.15);
            float jsp = max(2.0 * open / nb * L, 1e-3);   // world spacing between beams here
            float beams = (ltLine(j, bw / jsp, jw) * 1.6 + exp(-abs(fract(j) - 0.5) * jsp * aden * 9.0) * 0.12) * (0.35 + 1.1 * wisp);
            float falloff = 1.0 / (1.0 + 0.15 * L) + 1.2 * exp(-L * 5.0);
            air += sc * mix(sheet, beams, fanM) * vis * falloff * lvl * exp(-tk * fogK);
        }
        hazeE += sc * lvl * exp(-abs(E.z - z - 6.0) * 0.12);

        // ---- the line it scribes on the glass, and on the mirrored glass ----
        float dw = dot(h - E, N);
        vec3 vw = h - E - N * dw;
        float angW = atan2_(dot(vw, P), dot(vw, D));
        float maskW = smoothstep(open + 0.02, open - 0.05, abs(angW));
        float jW = (angW + open) / (2.0 * open) * nb;
        float lw = 0.012 + min(0.12 * mb * abs(N.z), 0.04);
        float LW = length(vw);
        float dotW = min((lw * 1.5) / max(2.0 * open / nb * LW, 1e-3), 0.25);
        float dots = mix(1.0, ltLine(jW, dotW, fwidth(jW)) * 0.6 / max(dotW, 0.05) + 0.06, fanM);
        float keep = 0.012 / lw;
        float line = ltBar(dw, lw, fwidth(dw)) * keep;
        float nearW = smoothstep(0.8, 5.0 + 6.0 * rush, t);
        wall += sc * (line * 2.4 * dots + exp(-abs(dw) * 7.0) * 0.05) * maskW * lvl * nearW;

        float dr = dot(h2 - E, N);
        vec3 vr = h2 - E - N * dr;
        float angR = atan2_(dot(vr, P), dot(vr, D));
        float maskR = smoothstep(open + 0.02, open - 0.1, abs(angR));
        refl += sc * (ltBar(dr, lw * 2.5, fwidth(dr)) * keep * 1.6 + exp(-abs(dr) * 5.0) * 0.04) * maskR * lvl;

        // ---- the fixture lens: a hot core and a thin anamorphic streak ----
        float tE = dot(E - ro, rd);
        vec3 dv = (ro + rd * tE - E) / max(tE, 0.5);
        float fx = dot(dv, cr);
        float fy = dot(dv, cu);
        float r2 = fx * fx + fy * fy;
        float spot = exp(-r2 * 14000.0) * 1.3 + exp(-sqrt(r2) * 70.0) * 0.1
                   + exp(-abs(fy) * 1100.0 - abs(fx) * 9.0) * 0.22;
        flare += peakWhite(sc, 0.35) * spot * step(0.5, tE) * smoothstep(1.0, 3.5, tE) * (0.3 + 0.5 * lvl) * exp(-tE * fogK * 0.6);
    }

    // black glass: a dim engraved panel grid lit by the haze, then the lines
    vec3 hazeC = mix(ltWarm(hue, cA, cB, cC), cool, 0.4) * (0.75 + 0.25 * lev);
    float hsW = LT_R * tan(3.14159265 / sides);
    vec2 tgW = vec2(-sin(th), cos(th));
    float s = dot(h.xy, tgW);
    float sc2 = s * 2.0 / hsW + 0.5;
    float zc = h.z / 2.0;
    float seam = max(ltLine(sc2, 0.01, fwidth(sc2)), ltLine(zc, 0.006, fwidth(zc)));
    vec3 col = hazeC * (0.004 + 0.012 * seam);
    col += wall;
    col += refl * reflK;
    col += hazeC * 0.02 * reflK;

    // faint corner rails in the cool family, lit by the spectrum
    float ec = hsW - abs(s);
    float rail = ltBar(ec, 0.015, fwidth(ec));
    float corner = mod(hit.y + (s > 0.0 ? 1.0 : 0.0), sides);
    float rb = bandAt(u, fract(corner * 0.13 + 0.1));
    float pulse = 0.75 + 0.25 * sin(h.z * 0.7 - tt * 0.4 + corner * 1.7);
    col += cool * (rail * 0.3 + exp(-ec * 14.0) * 0.03) * railGlow * (0.6 + 0.3 * lev + 0.06 * rb) * pulse;

    // depth haze toward a deep throat
    col *= exp(-t * fogK);
    col += (hazeC * 0.02 + hazeE * 0.025) * (1.0 - exp(-t * fogK));
    col += air * (0.85 + 0.15 * lev);
    col += flare;

    // shock plane: a ring of light launched on each beat, racing down the shaft
    float ts = (0.4 + 30.0 * bp) / rdz;
    if (ts < t) {
        vec2 qs = ro.xy + rd.xy * ts;
        float dwS = max(ltInside(qs, sides), 0.0);
        float smS = vnoise(qs * 2.2 + vec2(smokeT, beats));
        float fade = sin(3.14159265 * bp) * (0.04 + 0.04 * lev + bass) * smoothstep(0.8, 4.0, ts);
        col += mix(cB, cA, 0.62) * (exp(-dwS * 20.0) * 2.2 + exp(-dwS * 3.0) * 0.25 * smS) * fade * exp(-ts * fogK);
    }

    // scanner beams: emitters deep in the throat throw cool beams up the shaft
    float sweep = 0.1 * tt + 0.4 * sin(tt * 0.07);
    int nBeams = osSteps(1.0, 2.0, detail);
    for (int b = 0; b < 4; b++) {
        if (b >= nBeams) break;
        float fb = float(b);
        float side = mod(fb, 2.0);
        float ae = sweep + 3.14159265 * side;
        vec3 em = vec3(vec2(cos(ae), sin(ae)) * LT_R * 0.9, z + 26.0 + 4.0 * side);
        float at = ae + 3.14159265 + 0.5 * sin(tt * (0.12 + 0.03 * fb) + fb * 1.7);
        float zEnd = z + 3.5 + 2.0 * sin(tt * 0.08 + fb * 2.3);
        vec3 tip = vec3(vec2(cos(at), sin(at)) * LT_R * 0.98, zEnd);
        vec3 Db = tip - em;
        float Lb = max(length(Db), 1e-3);
        Db /= Lb;
        vec3 w0 = ro - em;
        float bb = dot(rd, Db);
        float dd = dot(rd, w0);
        float ee = dot(Db, w0);
        float denb = max(1.0 - bb * bb, 1e-4);
        float sb = clamp((ee - bb * dd) / denb, 0.0, Lb);
        vec3 pb = em + Db * sb;
        float tb = max(dot(pb - ro, rd), 0.0);
        float d = length(ro + rd * tb - pb);
        float wcore = max(0.008, px * tb);
        float core = exp(-d * d / (wcore * wcore)) * (0.008 / wcore);
        float smB = 0.3 + 1.3 * vnoise(pb.xy * 2.0 + vec2(pb.z * 0.35 - smokeT * 2.0, fb * 5.0));
        float halo = (exp(-d * 7.0) * 0.06 + exp(-d * 34.0) * 0.3) * smB;
        float dash = smoothstep(0.6, 1.0, sin(sb * 0.8 + tt * 0.8 + fb * 2.0));
        float bandL = bandAt(u, fract(0.55 + fb * 0.11));
        vec3 bc = mix(cool, cE + 0.3 * cD, 0.25 * fb / 3.0);
        float vis = step(tb, t + 0.05) * exp(-tb * fogK * 0.7);
        col += (peakWhite(bc, 0.15) * core * 1.1 + bc * halo * 0.7) * (0.5 + 0.3 * lev + 0.05 * bandL + dash * (0.08 + 0.04 * lev)) * vis;
        float tTip = max(dot(tip - ro, rd), 0.0);
        vec3 dvt = (ro + rd * tTip - tip) / max(tTip, 0.5);
        float fxt = dot(dvt, cr);
        float fyt = dot(dvt, cu);
        float r2t = fxt * fxt + fyt * fyt;
        float spotT = exp(-r2t * 9000.0) * 1.2 + exp(-sqrt(r2t) * 60.0) * 0.1
                    + exp(-abs(fyt) * 900.0 - abs(fxt) * 7.0) * 0.3;
        col += peakWhite(bc, 0.4) * spotT * step(tTip, t + 0.2) * (0.7 + 0.3 * lev + 0.05 * bandL) * smoothstep(1.5, 4.0, tTip);
    }

    return ltOffRed(max(col, vec3(0.0))); // LINEAR HDR
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
