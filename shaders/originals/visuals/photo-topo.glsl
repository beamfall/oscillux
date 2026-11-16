// SPDX-License-Identifier: AGPL-3.0-only
// Photo topography.
// A low dusk flight over a landscape made from the photo. The photo's
// brightness raises real relief and its colours paint the land, tiled in
// mirror so the map runs on forever; a lake fills the low ground and mirrors
// the sky and a low sun. Luminous contour lines trace every level of the
// relief like a living survey map, each level tuned to its own spectrum band,
// and every beat rolls a survey pulse out across the land. Haze lifts the
// distance into the glow of the horizon. The camera follows the shared
// 32-beat speed profile and banks into its curves; audio drives the light
// and the contours, never the camera.
// param0 = Speed ; param1 = Height ; param2 = Contours

const float PT_L = 11.0;     // photo tile length in world units

// The palette, read at four of its stops per pixel and interpolated round a
// colour wheel (the music turns the wheel).
// Each palette read copies the palette table on some targets, so every colour
// below comes from these four samples instead of its own read.
vec3 ptPal(float t, vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
    float x = fract(t) * 4.0;
    float i = floor(x);
    float f = smoothstep(0.0, 1.0, x - i);
    vec3 a = i < 1.0 ? c0 : (i < 2.0 ? c1 : (i < 3.0 ? c2 : c3));
    vec3 b = i < 1.0 ? c1 : (i < 2.0 ? c2 : (i < 3.0 ? c3 : c0));
    return mix(a, b, f);
}
#define PTPAL(t) ptPal(t, pc0, pc1, pc2, pc3)

vec2 ptMirror(vec2 x) { return 1.0 - abs(1.0 - mod(x, 2.0)); }

// The photo's own key colour: nine fixed taps averaged. The taps do not
// depend on the pixel, so every pixel agrees and the cost is tiny.
vec3 ptKey(VisualUniforms u) {
    vec3 s = vec3(0.0);
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        vec2 g = vec2(mod(fi, 3.0), floor(fi / 3.0)) * 0.3 + 0.2;
        s += max(IMG(g).rgb, vec3(0.0));
    }
    return s / 9.0;
}

// An accent complementary to the photo: the palette stop whose hue sits
// furthest from the photo's key, pushed toward the key's true complement
// (the more colourful the photo, the harder the push).
vec3 ptAccent(vec3 key, vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
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

float ptPath(float z) { return 7.0 * sin(z * 0.043) + 3.0 * sin(z * 0.097 + 1.3); }

vec3 ptAlbedo(vec2 xz, float imgA) {
    vec2 s = ptMirror(vec2(xz.x / (PT_L * imgA), 1.0 - xz.y / PT_L));
    return max(IMG(s).rgb, vec3(0.0));
}

// Relief from the photo's brightness, read on a coarse lattice and blended
// with a smooth cubic, so the photo's fine grain never turns into spikes,
// plus a little rolling ground.
float ptHeight(vec2 xz, float amp, float imgA) {
    const float C = 0.42;                    // lattice cell in world units
    vec2 g = xz / C;
    vec2 i = floor(g), f = fract(g);
    vec2 w = f * f * (3.0 - 2.0 * f);
    float a = luma(ptAlbedo(i * C, imgA));
    float b = luma(ptAlbedo((i + vec2(1.0, 0.0)) * C, imgA));
    float c = luma(ptAlbedo((i + vec2(0.0, 1.0)) * C, imgA));
    float d = luma(ptAlbedo((i + vec2(1.0, 1.0)) * C, imgA));
    float l = saturate(mix(mix(a, b, w.x), mix(c, d, w.x), w.y));
    return amp * (0.80 * l * l * (3.0 - 2.0 * l) + 0.20 * vnoise(xz * 0.42));
}

// The sky is the photo itself, hung on the dome ahead and graded down so the
// land and its contours read in front of it; a low sun warms the horizon.
vec3 ptSky(vec3 rd, vec3 sun, vec3 zenC, vec3 loC, vec3 hiC, vec3 hzC) {
    float az = atan2_(rd.x, max(rd.z, 0.05));
    vec2 s = vec2(0.5 + az * 0.55, clamp(0.52 - rd.y * 1.5, 0.0, 1.0));
    vec3 ph = max(IMG(ptMirror(s)).rgb, vec3(0.0));
    ph = max(mix(vec3(luma(ph)), ph, 1.3), vec3(0.0));
    ph = ph * ph * 0.95;
    float h = saturate(rd.y);
    // dusk grade: the photo's clouds keep their light, but the dome deepens
    // from a warm horizon to a cool zenith in the palette's own hues
    float L = luma(ph);
    vec3 zen = zenC * 0.035 + vec3(0.001, 0.002, 0.010);
    vec3 duo = mix(loC * 0.6, hiC * 1.6, smoothstep(0.05, 0.7, L)) * L;
    vec3 col = mix(ph, duo, 0.18 + 0.32 * smoothstep(0.0, 0.3, h)) * 0.85;
    col = mix(col, zen, smoothstep(0.06, 0.5, h) * 0.88) + vec3(0.001, 0.0015, 0.006);
    col += hzC * exp(-h * 22.0) * 0.20;
    float sd = saturate(dot(rd, sun));
    col += vec3(1.0, 0.45, 0.25) * pow(sd, 24.0) * 0.25;
    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    float detail = osDetail(u);
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float t = mod(u.time, 600.0);
    vec2 isz = IMGSIZE;
    float imgA = clamp(isz.x / max(isz.y, 1.0), 0.25, 4.0);

    float speed = mix(1.2, 4.5, u.param0);
    float amp = mix(1.4, 3.6, u.param1);
    float levels = floor(mix(8.0, 22.0, u.param2) + 0.5);

    // ---- camera: speed profile flight, eased bank, no audio ----
    vec2 fl = osFlight(u, speed, 0.5 * speed);
    float z = fl.x;
    float rush = saturate((fl.y - 1.0) / 3.5);
    // the palette walks with the music and leaps ahead on builds
    float bc = u.beatCount + saturate(u.beatPhase);
    float hueOff = mod(bc, 256.0) * (0.137 / 16.0) + 0.15 * rush;
    vec3 pc0 = palVisual(0.02, u);
    vec3 pc1 = palVisual(0.34, u);
    vec3 pc2 = palVisual(0.62, u);
    vec3 pc3 = palVisual(0.97, u);
    vec3 skyZ = PTPAL(hueOff + 0.02);
    vec3 skyL = PTPAL(hueOff + 0.98);
    vec3 skyH = PTPAL(hueOff + 0.70);
    vec3 skyG = PTPAL(hueOff + 0.12);
    vec3 key = ptKey(u);
    vec3 accent = ptAccent(key, pc0, pc1, pc2, pc3);
    float alt = amp * 1.05 + 1.0 + 0.35 * sin(t * 6.2831853 * 11.0 / 600.0);
    vec3 ro = vec3(ptPath(z), alt, z);
    vec3 ta = vec3(ptPath(z + 6.0), alt - 1.3, z + 6.0);
    float curve = ptPath(z + 9.0) - 2.0 * ptPath(z + 4.5) + ptPath(z);
    float roll = -0.06 * curve + osBank(u, 0.10);
    vec3 rd = osCamera(ro, ta, roll, 1.35 - 0.15 * rush, p);
    vec3 sun = normalize(vec3(0.25, 0.16, 1.0));

    // ---- heightfield march with a bisection refine ----
    float water = amp * 0.22;
    float tmax = 70.0;
    int n = osSteps(44.0, 120.0, detail);
    float tt = 0.05, lastT = 0.05;
    bool hit = false;
    for (int i = 0; i < 120; i++) {
        if (i >= n) break;
        vec3 pos = ro + rd * tt;
        float d = pos.y - ptHeight(pos.xz, amp, imgA);
        if (d < 0.0) { hit = true; break; }
        lastT = tt;
        tt += clamp(d * 0.45, 0.02 + 0.004 * tt, 1.6);
        if (tt > tmax) break;
    }
    if (hit) {
        float a = lastT, b = tt;
        for (int i = 0; i < 5; i++) {
            float m = 0.5 * (a + b);
            vec3 pm = ro + rd * m;
            if (pm.y - ptHeight(pm.xz, amp, imgA) < 0.0) b = m; else a = m;
        }
        tt = 0.5 * (a + b);
    } else {
        tt = tmax;
    }
    // the lake surface, when it comes first
    float tw = rd.y < -1e-3 ? (water - ro.y) / rd.y : 1e9;
    bool onWater = tw > 0.0 && tw < tt;

    vec3 col;
    float tHit = onWater ? tw : tt;
    vec3 pos = ro + rd * tHit;
    float fogAmt = 1.0 - exp(-tHit * 0.032);
    vec3 fogCol = mix(PTPAL(0.70 + hueOff) * 0.04 + vec3(0.004, 0.005, 0.014),
                      vec3(0.80, 0.38, 0.16), pow(saturate(dot(rd, sun)), 5.0) * 0.55);

    // contour field at the hit point (also drawn faintly under the water)
    float h = ptHeight(pos.xz, amp, imgA);
    float lev = h / amp * levels;
    float ci = floor(lev + 0.5);
    float bnd = bandAt(u, saturate(ci / levels));
    float fw = fwidth(lev);
    // fade lines where they alias in the distance, and on flats that sit
    // right on a level, where a line would flood the whole flat
    float lineFade = (1.0 - smoothstep(0.15, 0.45, fw)) * smoothstep(0.003, 0.012, fw);
    float fd = abs(fract(lev + 0.5) - 0.5) / max(fw, 1e-4);   // pixels to the nearest level
    // every fifth level is an index contour, as on a survey map: thicker,
    // brighter and drawn in the accent complementary to the photo
    float isIdx = 1.0 - step(0.5, mod(ci, 5.0));
    float line = (aaLineCyclic(lev + 0.5, 0.022 + 0.02 * isIdx) + (0.30 + 0.25 * isIdx) * exp(-fd * 0.6)) * lineFade;
    // survey pulse: a ring rolls out from under the camera each beat
    float ring = length(pos.xz - ro.xz) - (2.0 + 34.0 * u.beatPhase);
    float pulse = exp(-ring * ring * 0.5) * (1.0 - u.beatPhase) * (0.4 + u.beat);
    // minor contours stay in one warm palette family; index contours and the
    // beat's survey pulse carry the complementary accent
    vec3 minorCol = PTPAL(fract(ci * 0.37) * 0.22 + 0.05 + hueOff);
    vec3 lineCol = mix(minorCol * (0.22 + 2.2 * bnd), accent * (0.7 + 3.4 * bnd + 0.8 * rush), isIdx);
    vec3 pulseCol = peakWhite(accent * 1.4, 0.25 * u.onset);
    vec3 glowC = (lineCol + pulseCol * 3.2 * pulse) * line * (0.7 + 0.5 * u.level)
               + pulseCol * pulse * 0.10;

    if (!hit && !onWater) {
        col = ptSky(rd, sun, skyZ, skyL, skyH, skyG);
    } else if (onWater) {
        // still lake: sky mirror with a soft ripple, the drowned contours below
        vec2 rip = vec2(vnoise(pos.xz * 2.2 + vec2(0.0, t * 0.6)), vnoise(pos.zx * 2.2 - vec2(t * 0.5, 0.0))) - 0.5;
        vec3 wn = normalize(vec3(rip.x * 0.07, 1.0, rip.y * 0.07));
        vec3 rr = reflect(rd, wn);
        float fres = 0.04 + 0.96 * pow(1.0 - saturate(-dot(rd, wn)), 5.0);
        vec3 deep = ptAlbedo(pos.xz, imgA);
        deep = deep * deep * 0.10;
        col = deep + ptSky(rr, sun, skyZ, skyL, skyH, skyG) * (0.25 + 0.75 * fres) + glowC * 0.22;
    } else {
        // land: the photo's colours, low sun, sky fill, glowing contours
        float e = 0.025 + 0.0015 * tHit;
        float hx = ptHeight(pos.xz + vec2(e, 0.0), amp, imgA);
        float hz = ptHeight(pos.xz + vec2(0.0, e), amp, imgA);
        vec3 nrm = normalize(vec3(h - hx, e, h - hz));
        vec3 alb = ptAlbedo(pos.xz, imgA);
        alb = max(mix(vec3(luma(alb)), alb, 1.35), vec3(0.0));
        alb = alb * alb * 1.3;
        float dif = saturate(dot(nrm, sun));
        float back = pow(saturate(1.0 - dot(nrm, -rd)), 3.0);
        // warm low key, cool sky fill from the opposite side
        vec3 fillCol = mix(vec3(0.10, 0.20, 0.75), accent, 0.55);
        float fill = saturate(dot(nrm, normalize(vec3(-0.5, 0.8, -0.4))));
        vec3 lit = vec3(1.0, 0.66, 0.40) * dif * 1.25
                 + fillCol * (0.04 + 0.48 * fill * fill)
                 + PTPAL(hueOff + 0.9) * back * 0.45;
        alb = mix(vec3(luma(alb)), alb, 0.9) * 0.62;
        col = alb * lit;
        // the low ground near the lake takes a wet sheen
        col += vec3(0.9, 0.55, 0.3) * pow(saturate(dot(reflect(rd, nrm), sun)), 24.0)
             * smoothstep(water + 0.4, water, h) * 0.6;
        col += glowC;
    }

    if (hit || onWater) col = mix(col, fogCol, fogAmt);
    // the horizon breathes with the bass
    col += mix(PTPAL(0.4 + hueOff), PTPAL(0.08 + hueOff), 0.62 + 0.25 * u.bassImpact) * exp(-abs(rd.y + 0.02) * 30.0) * (0.04 + 0.12 * u.bass);
    col *= 0.45 + 0.55 * smoothstep(2.2, 0.6, length(p));
    return col; // LINEAR HDR — post chain tonemaps
}
