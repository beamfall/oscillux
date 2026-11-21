// SPDX-License-Identifier: AGPL-3.0-only
// Photo veil.
// The photo is printed on a sheet of sheer silk that billows in real 3D in
// front of the camera, with two more veils of aurora-coloured chiffon hanging
// in the dark behind it. Wind waves roll through every sheet, the folds shade
// and stretch the print, the fold flanks catch a thin-film sheen and the
// dark parts of the photo let the glowing veils behind shine through. Each
// fold flank glows with its own spectrum band and every beat sweeps a soft
// band of light along the fold flanks. A slow, steady wind moves the folds
// and the camera drift, the lens breathes with the shared 32-beat speed
// profile, and the camera banks gently; audio drives the light, rising and
// falling within each beat, never the folds or the camera.
// param0 = Ribbons (fold density) ; param1 = Sway ; param2 = Texture

const float PV_H = 2.25;      // half height of the printed photo in world units

// The palette read once at five fixed stops and blended locally, plus the
// photo's complementary accent.
struct PvPal { vec3 a; vec3 b; vec3 c; vec3 d; vec3 e; vec3 accent; };

vec3 pvPal(PvPal P, float t) {
    float x = fract(t) * 5.0;
    vec3 c = mix(P.a, P.b, smoothstep(0.5, 1.5, x));
    c = mix(c, P.c, smoothstep(1.5, 2.5, x));
    c = mix(c, P.d, smoothstep(2.5, 3.5, x));
    c = mix(c, P.e, smoothstep(3.5, 4.5, x));
    return mix(c, P.a, smoothstep(4.5, 5.0, x));
}

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float PV_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 pvFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * PV_RUN[32] + PV_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

// A swell that rises and falls within each beat: zero on the kick, so the
// bass lifts the rims and the haze without a jump on the beat.
float pvSwell(VisualUniforms u) {
    float s = sin(3.14159265 * saturate(u.beatPhase));
    return s * s;
}

vec2 pvMirror(vec2 x) { return 1.0 - abs(1.0 - mod(x, 2.0)); }

// The print: the photo across the front sheet, mirrored past its edges and
// graded for deep blacks.
vec3 pvPhoto(vec2 q, VisualUniforms u) {
    float scrA = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 s = vec2(0.5 + 0.5 * q.x / (PV_H * scrA), 0.5 - 0.5 * q.y / PV_H);
    vec3 c = max(IMG(photoCover(pvMirror(s), u.resolution, IMGSIZE)).rgb, vec3(0.0));
    c = c * c * (0.5 + 0.9 * c) * 1.25;
    // a soft shoulder so a bright sky keeps its colour instead of glaring white
    c = c / (1.0 + 0.45 * c);
    return max(mix(vec3(luma(c)), c, 1.3), vec3(0.0));
}

// Sheet displacement and its gradient: (h, dh/dx, dh/dy). A long billow, a
// cross swell, a fine ripple and hanging pleats. Their depth stays steady:
// audio deepening the folds flashes the whole sheet's shading.
// Wind phases use multiples of 0.05 so they stay continuous at the wrap.
vec3 pvWave(vec2 q, float w, float s, float pk, float amp, VisualUniforms u) {
    vec3 r = vec3(0.0);
    float a = 0.42 * amp;
    float g = 1.1 * q.x + 0.45 * q.y - w * 0.6 + s;
    r += a * vec3(sin(g), 1.1 * cos(g), 0.45 * cos(g));
    a = 0.18 * amp * 1.4;
    g = -1.7 * q.x + 1.1 * q.y - w + s * 1.7 + 1.0;
    r += a * vec3(sin(g), -1.7 * cos(g), 1.1 * cos(g));
    a = 0.04 * amp * 1.6;
    g = 3.9 * q.x + 2.2 * q.y - w * 1.55 + s * 2.3 + 2.0;
    r += a * vec3(sin(g), 3.9 * cos(g), 2.2 * cos(g));
    float m = 1.3 * q.y + w * 0.35 + s;
    a = 0.025 * amp;
    g = pk * q.x + 0.8 * sin(m) - w * 0.25;
    r += a * vec3(sin(g), pk * cos(g), 0.8 * 1.3 * cos(g) * cos(m));
    return r;
}

// The gradient of the fine ripple and the pleats alone, as in pvWave: the
// front sheet's shading leans on these so the silk reads by its creases
// rather than by broad soft glows across the billow.
vec2 pvFine(vec2 q, float w, float s, float pk, float amp, VisualUniforms u) {
    float a = 0.04 * amp * 1.6;
    float g = 3.9 * q.x + 2.2 * q.y - w * 1.55 + s * 2.3 + 2.0;
    vec2 r = a * cos(g) * vec2(3.9, 2.2);
    float m = 1.3 * q.y + w * 0.35 + s;
    a = 0.025 * amp;
    g = pk * q.x + 0.8 * sin(m) - w * 0.25;
    return r + a * cos(g) * vec2(pk, 0.8 * 1.3 * cos(m));
}

// Ray against the sheet z = z0 + h(x, y): march its bounding slab, then
// bisect the first crossing. The sheet is endless, so every ray hits it.
float pvHit(vec3 ro, vec3 rd, float z0, float s, float w, float pk, float amp,
            int n, VisualUniforms u) {
    float A = 0.78 * amp;
    float rz = max(rd.z, 0.05);
    float t0 = (z0 - A - ro.z) / rz;
    float t1 = (z0 + A - ro.z) / rz;
    float dt = (t1 - t0) / float(n);
    float a = t0, b = t1;
    for (int i = 0; i < 16; i++) {
        if (i >= n) break;
        float tt = t0 + dt * float(i + 1);
        vec3 pp = ro + rd * tt;
        if (pp.z - z0 - pvWave(pp.xy, w, s, pk, amp, u).x > 0.0) { a = tt - dt; b = tt; break; }
    }
    for (int i = 0; i < 5; i++) {
        float m = 0.5 * (a + b);
        vec3 pm = ro + rd * m;
        if (pm.z - z0 - pvWave(pm.xy, w, s, pk, amp, u).x > 0.0) b = m; else a = m;
    }
    return 0.5 * (a + b);
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    float detail = osDetail(u);
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;

    float pk = mix(4.0, 8.0, u.param0);          // pleats per unit: Ribbons
    float amp = mix(0.55, 1.35, u.param1);       // billow height: Sway
    float print = mix(0.55, 1.0, u.param2);      // print strength: Texture

    // ---- a steady, slow wind (faster folds flash across the whole print);
    // the lens breathes with the speed profile; roll eased, no audio ----
    vec2 fl = pvFlight(u, 0.45, 0.4 + 0.3 * u.param1);
    float dw = mod(0.35 * u.time, 6.2831853 * 20.0);
    float rush = saturate((fl.y - 1.0) / 3.5);
    vec3 ro = vec3(1.30 * sin(dw * 0.05 + 0.4), -0.35 + 0.30 * sin(dw * 0.10 + 1.1),
                   -3.0 + 0.30 * sin(dw * 0.05 + 2.6));
    vec3 ta = vec3(0.20 * sin(dw * 0.05 + 2.0), 0.10 * sin(dw * 0.15), 1.0);
    vec3 rd = osCamera(ro, ta, osBank(u, 0.06), 1.6 + 0.03 * rush, p);
    vec3 v = -rd;
    vec3 L = normalize(vec3(-0.85, 0.35, -0.40));     // raking key light from the left
    vec3 Lb = normalize(vec3(0.3, 0.2, 1.0));         // aurora glow from behind
    vec3 hv = normalize(L + v);
    int n = osSteps(5.0, 12.0, detail);

    // the photo's key colour from nine fixed taps, weighted toward saturated
    // pixels; the accent is its complement, kept saturated
    vec3 kAcc = vec3(0.0);
    float kW = 0.0;
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        vec2 tuv = vec2(0.18 + 0.32 * mod(fi, 3.0), 0.18 + 0.32 * floor(fi / 3.0));
        vec3 kc = max(IMG(tuv).rgb, vec3(0.0));
        float w = 0.04 + max(kc.r, max(kc.g, kc.b)) - min(kc.r, min(kc.g, kc.b));
        kAcc += kc * w;
        kW += w;
    }
    vec3 keyC = kAcc / max(kW, 1e-4);
    float kHi = max(keyC.r, max(keyC.g, keyC.b));
    float kLo = min(keyC.r, min(keyC.g, keyC.b));
    float kSat = (kHi - kLo) / max(kHi, 1e-3);
    vec3 keyHue = (keyC - kLo) / max(kHi - kLo, 1e-3);
    PvPal Q = PvPal(palVisual(0.1, u), palVisual(0.3, u), palVisual(0.5, u), palVisual(0.7, u), palVisual(0.9, u), vec3(0.0));
    Q.accent = mix(Q.d, (vec3(1.0) - keyHue) * 1.25, smoothstep(0.08, 0.3, kSat));
    float rimMix = 0.4 + 0.1 * saturate(u.level);
    float rimPk = 0.04 * pvSwell(u) * saturate(u.level);
    float lv = saturate(u.level);

    // beat sweep: a soft diagonal band of light crosses the silk each beat
    float sweepPos = -3.2 + 6.4 * smoothstep(0.0, 1.0, u.beatPhase);
    float sweepAmt = sin(3.14159 * saturate(u.beatPhase)) * 0.1;

    // ---- the dark beyond: a faint aurora haze ----
    vec3 col = Q.a * 0.012 + vec3(0.0, 0.0, 0.004);
    col += pvPal(Q, 0.45) * exp(-abs(rd.y + 0.05) * 6.0) * (0.012 + 0.006 * lv);

    // ---- two veils of aurora chiffon behind, back to front ----
    for (int k = 0; k < 2; k++) {
        if (k == 0 && detail < 0.5) continue;     // the farthest veil drops at low detail
        float fk = float(1 - k);                   // 1 = far, 0 = near
        float z0 = 1.6 + 1.8 * fk;
        float s = 2.1 + 3.7 * fk;
        float pkk = pk * (0.75 - 0.15 * fk);
        float t = pvHit(ro, rd, z0, s, dw, pkk, amp * 1.2, n, u);
        vec3 P = ro + rd * t;
        vec3 g = pvWave(P.xy, dw, s, pkk, amp * 1.2, u);
        vec3 nr = normalize(vec3(g.y, g.z, -1.0));
        float ndv = abs(dot(nr, v));
        float flank = pow(1.0 - ndv, 2.0);
        float bnd = mix(lv, bandAt(u, saturate(0.5 + P.x * 0.16)), 0.25);
        // the curtains of light: brightest on fold flanks, rising toward the hem
        float curtain = smoothstep(-3.0, 0.2, -P.y) * 0.6 + 0.4;
        vec3 hue = pvPal(Q, 0.30 + 0.38 * fk + 0.06 * P.y + 0.05 * g.x);
        // the near veil leans toward the photo's complementary accent
        hue = mix(hue, Q.accent, 0.3 * (1.0 - fk));
        float back = pow(saturate(dot(-nr, Lb) * 0.5 + 0.5), 3.0);
        vec3 c = hue * (0.03 + flank * (0.75 + 0.8 * bnd) * curtain + back * 0.10);
        c += hue * pow(saturate(dot(nr, hv)), 30.0) * 0.30;
        float sw = P.x * 0.55 + P.y * 0.35 - sweepPos;
        c += hue * flank * exp(-sw * sw * 9.0) * sweepAmt * 1.6;
        c *= exp(-(t - 3.0) * 0.10);
        float a = 0.55 + 0.35 * flank;
        col = mix(col, c, a);
    }

    // ---- the printed front veil ----
    float t = pvHit(ro, rd, 0.0, 0.0, dw, pk, amp, n, u);
    vec3 P = ro + rd * t;
    vec3 g = pvWave(P.xy, dw, 0.0, pk, amp, u);
    vec3 nr = normalize(vec3(g.y, g.z, -1.0));
    vec3 ns = normalize(vec3(g.yz * 0.55 + pvFine(P.xy, dw, 0.0, pk, amp, u) * 1.1, -1.0));
    float ndv = abs(dot(nr, v));
    float flank = pow(1.0 - ndv, 2.5);
    vec3 ph = pvPhoto(P.xy, u);
    float lp = luma(ph);
    // folds read by contrast, not by gain: the lit side holds the print's own
    // level and the shadowed side drops deep
    float dif = mix(0.16, 1.0, pow(saturate(dot(ns, L) * 0.85 + 0.15), 1.4));
    float ao = 0.35 + 0.65 * smoothstep(0.7 * amp, -0.5 * amp, g.x);   // folds that fall away darken
    vec3 c = ph * dif * ao * 1.05 * print;
    // thin-film sheen on the fold flanks, its hue sliding with the angle
    float bnd = mix(lv, bandAt(u, saturate(0.5 + P.x * 0.16)), 0.25);
    vec3 film = hsv2rgb(vec3(fract(0.55 + 1.1 * (1.0 - ndv) + 0.05 * P.x), 0.75, 1.0));
    float rt = 0.55 + 0.1 * P.y;
    vec3 rim = mix(mix(pvPal(Q, rt), peakWhite(pvPal(Q, rt + 0.18), rimPk), rimMix), film, 0.45);
    rim = mix(rim, Q.accent, 0.3);
    c += rim * flank * (0.2 + 0.5 * bnd);
    // silk specular and the beat sweep
    // silk satin: a crisp highlight held off the bright print so it never glares
    float hiL = smoothstep(0.15, 0.8, lp);
    float spec = pow(saturate(dot(ns, hv)), 160.0);
    c += (rim * 0.35 + 0.12) * spec * 0.35 * (1.0 - 0.7 * hiL);
    float sw = P.x * 0.55 + P.y * 0.35 - sweepPos;
    c += rim * exp(-sw * sw * 10.0) * sweepAmt * flank * (1.0 - 0.6 * hiL);
    // sheer where the print is dark, nearly opaque where it is bright or folded edge-on
    float a = clamp(0.66 + 0.55 * sqrt(lp) + 0.3 * flank, 0.0, 0.985) * mix(0.85, 1.0, print);
    // the free hem: below it the aurora veils show, and the hem edge glows
    float hemY = -1.72 + 0.22 * sin(0.8 * P.x - dw * 0.6 + 0.5) + 0.10 * sin(2.3 * P.x + dw * 0.35)
               + 0.30 * g.x;
    float hd = P.y - hemY;
    a *= smoothstep(-0.012, 0.012, hd);
    col = mix(col, c, a);
    float hemB = mix(lv, bandAt(u, saturate(0.5 + P.x * 0.16)), 0.25);
    float ht = 0.62 + 0.06 * P.x;
    vec3 hemC = mix(mix(pvPal(Q, ht), peakWhite(pvPal(Q, ht + 0.18), rimPk), rimMix), Q.accent, 0.35);
    col += mix(hemC, film, 0.35)
         * (exp(-abs(hd) * 60.0) * (0.35 + 0.7 * flank + 0.7 * hemB)
            + exp(-abs(hd) * 10.0) * (0.06 + 0.1 * hemB));


    col *= 0.45 + 0.55 * smoothstep(2.3, 0.7, length(p));
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
