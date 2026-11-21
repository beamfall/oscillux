// SPDX-License-Identifier: AGPL-3.0-only
// Wave Cascade: a live glass ribbon of the spectrum runs along the lip of a
// dark waterfall of light. The curtain below is made of fine falling strands
// whose clumps stretch as they accelerate; the flow runs at a slow, steady rate and
// the smoothed level, with a trace of spectrum, sets how brightly the water
// pours, so the curtain glows and fades rather than flickering. On each beat a
// sheet of the ribbon shears off as a faint veil, falls, breaks into rivulets
// and lights up slowly as it settles into glowing strata on a mirror pool.
// Every beat a dim torrent runs down one column of the falls; where it
// lands, a small crown of spray, a soft mist bloom and a faint ring across the
// slowly rippling pool, all fading out before the next one is due. No onset flashes.
// The palette never shifts with the beat or the timbre, and under the vivid
// palette tour the colours change hue but keep their brightness.
// param0 Fall Speed ; param1 Sheet Life ; param2 Spray

#define WC_TOP 0.17
#define WC_FLOOR 0.80
#define WC_LAND 0.9

// The palette read without osPalVisual's per-beat and spectral-centroid hue
// nudge (common.glsl), and with its brightness evened out, so the falls never
// shifts colour with the beat or the timbre and the vivid palette tour's
// cross-fades change hue, not brightness (manifest mode has no nudge or tour).
vec3 wcPalStill(float t, VisualUniforms u) {
    if (u.palette.x >= 0.0) return palVisual(t, u);
    vec3 c = palVisual(t - 0.015 * u.beatPhase - 0.08 * u.spectralCentroid, u);
    return c * pow(0.3 / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 0.02), 0.75);
}

// The palette is read once per pixel at its five stops and blended locally,
// and the spectrum once at 32 points (each the mean of two neighbouring
// bands) and read back with linear weights: library palette and band reads
// walk the whole stop table or uniform array every call, and the scene is
// drawn twice per pool pixel.
struct WcPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

WcPal wcPalLoad(VisualUniforms u) {
    WcPal P;
    P.c0 = wcPalStill(0.0, u);
    P.c1 = wcPalStill(0.26, u);
    P.c2 = wcPalStill(0.52, u);
    P.c3 = wcPalStill(0.78, u);
    P.c4 = wcPalStill(0.999, u);
    return P;
}

vec3 wcPal(WcPal P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

vec3 wcFog(WcPal P, float t, VisualUniforms u) {
    vec3 c = wcPal(P, t + 0.04 * u.spectralCentroid);
    return mix(vec3(luma(c) * 0.62), c, 0.42);
}

vec3 wcTreble(WcPal P, float t, VisualUniforms u) {
    return peakWhite(wcPal(P, 0.62 + t * 0.28 + 0.10 * u.spectralCentroid), 0.03);
}

struct WcBands { vec4 b0; vec4 b1; vec4 b2; vec4 b3; vec4 b4; vec4 b5; vec4 b6; vec4 b7; };

vec4 wcBands4(VisualUniforms u, int k) {
    return 0.5 * vec4(band(u, k) + band(u, k + 1), band(u, k + 2) + band(u, k + 3),
                      band(u, k + 4) + band(u, k + 5), band(u, k + 6) + band(u, k + 7));
}

WcBands wcBandsLoad(VisualUniforms u) {
    WcBands B;
    B.b0 = wcBands4(u, 0);
    B.b1 = wcBands4(u, 8);
    B.b2 = wcBands4(u, 16);
    B.b3 = wcBands4(u, 24);
    B.b4 = wcBands4(u, 32);
    B.b5 = wcBands4(u, 40);
    B.b6 = wcBands4(u, 48);
    B.b7 = wcBands4(u, 56);
    return B;
}

// f in 0..1 across the spectrum, as bandAt.
float wcBand(WcBands B, float f) {
    float x = clamp((saturate(f) * float(NBANDS - 1) - 0.5) * 0.5, 0.0, 31.0);
    vec4 k = vec4(0.0, 1.0, 2.0, 3.0);
    return dot(B.b0, max(1.0 - abs(x - k), 0.0)) + dot(B.b1, max(1.0 - abs(x - 4.0 - k), 0.0))
         + dot(B.b2, max(1.0 - abs(x - 8.0 - k), 0.0)) + dot(B.b3, max(1.0 - abs(x - 12.0 - k), 0.0))
         + dot(B.b4, max(1.0 - abs(x - 16.0 - k), 0.0)) + dot(B.b5, max(1.0 - abs(x - 20.0 - k), 0.0))
         + dot(B.b6, max(1.0 - abs(x - 24.0 - k), 0.0)) + dot(B.b7, max(1.0 - abs(x - 28.0 - k), 0.0));
}

// Shape of a sheet (screen units before amplitude) and its x-derivative from
// the sine terms. Frozen sheets read a noise pseudo-spectrum keyed by seed; the
// live trace blends in the real spectrum. phase drives the sine terms so the
// live trace morphs smoothly within a beat.
vec2 wcShape(float x, float seed, float phase, float live, float tw, WcBands B, VisualUniforms u) {
    float b = vnoise(vec2(x * 6.5, seed * 17.31)) * 1.3;
    if (live > 0.0) {
        float liveB = wcBand(B, fract(x * 0.82 + 0.03 * sin(tw * 0.31)));
        b = mix(b, liveB * 1.6, live);
    }
    float hi = 0.08 * (0.4 + live * 0.3);
    float a1 = x * 9.0 + phase * 2.7, a2 = x * 23.0 - phase * 5.1, a3 = x * 57.0 + phase * 9.3;
    float w = sin(a1) * 0.42 + sin(a2) * 0.22 + sin(a3) * hi;
    float dw = cos(a1) * 3.78 + cos(a2) * 5.06 + cos(a3) * 57.0 * hi;
    float k = 0.28 + 0.85 * b;
    return vec2(w * k, dw * k);
}

// Glossy ribbon of thickness th whose top edge is at signed distance d.
// slope is dy/dx of the edge and tilt how far the face is turned up or down
// by its twist; returns the lit colour for albedo sc.
vec3 wcRibbon(float d, float th, float slope, float tilt, vec3 sc, float px) {
    float inside = smoothstep(-px, px, d) * (1.0 - smoothstep(th - px, th + px, d));
    if (inside <= 0.0) return vec3(0.0);
    float v = clamp(d / max(th, 1e-4), 0.0, 1.0);
    // Screen y points down, so the top edge faces up (negative y).
    vec3 n = normalize(vec3(-slope * 1.4, (v - 0.5) * 1.4 + tilt, 1.0));
    vec3 L = vec3(-0.4246, -0.7077, 0.5662);   // upper-left key light
    vec3 H = vec3(-0.2309, -0.3849, 0.8937);   // normalize(L + view)
    float diff = max(dot(n, L), 0.0);
    float spec = pow(max(dot(n, H), 0.0), 42.0);
    float rim = pow(1.0 - n.z, 2.0);
    vec3 c = sc * (0.30 + 1.10 * diff) + mix(vec3(1.0), sc, 0.3) * spec * 3.2 + sc * rim * 1.2;
    return c * inside;
}

// One layer of falling strands: thin rivulets in jittered columns, carrying
// clumps of water that run down and stretch as they accelerate (the texture
// coordinate runs with the square root of the fall). wid is the line width in
// cell units: wide lines read as near, out-of-focus water.
float wcStrands(float xs, float fall, float run, float cols, float wid, float seed) {
    float cx = xs * cols + seed;
    float id = floor(cx);
    float h = hash21(vec2(id, seed * 7.1));
    float h2 = hash21(vec2(id * 1.7 + 3.0, seed + 1.0));
    float off = cx - id - (0.3 + 0.4 * h);
    float w = wid * (0.6 + 0.8 * h2);
    float line = exp(-off * off / (w * w));
    float v = sqrt(fall + 0.015) * (5.0 + 3.0 * h) - run * (0.9 + 0.6 * h2);
    float clump = smoothstep(0.32, 0.88, vnoise(vec2(id * 3.7 + seed, v * 2.4)));
    return line * (2.0 + 0.8 * clump) * (0.3 + 0.7 * h2);
}

// Torrent for the bass hit j beats ago: column x (aspect units), strength and
// age in beats. Bar downbeats are wider and stronger.
vec3 wcHero(float seedN, float j, float ph, VisualUniforms u) {
    float n = seedN - j;
    float down = 1.0 - step(0.5, mod(n, 4.0));
    float k = (0.75 + 0.25 * down) * (0.18 + 0.08 * u.level);
    float x = 0.18 + 0.64 * hash11(mod(n, 512.0) * 0.731 + 0.37);
    return vec3(x, k, ph + j);
}

// Each torrent takes its own colour from the warm end of the palette, so
// successive plunges read as different water.
vec3 wcHeroC(WcPal P, float seedN, float j) {
    return wcPal(P, 0.68 + 0.22 * hash11(mod(seedN - j, 512.0) * 0.531 + 0.11));
}

// Everything above the pool line: the dark backdrop, the strand curtain, the
// torrents, the falling sheets and the live trace. Called once per pixel, and
// for the pool with mirrored uv.
vec3 wcScene(vec2 uv, float g, float life, int nSheets, float detail, float aspect,
             float tw, float run, float flow, float px, WcPal P, WcBands B, VisualUniforms u) {
    float cbS = (0.3 + 0.4 * u.level) * (0.5 + vnoise(vec2(uv.x * 6.5, tw * 0.05)));
    float cb = mix(cbS, wcBand(B, uv.x), 0.1);
    float seedN = floor(u.beatCount);
    float ph = clamp(u.beatPhase, 0.0, 1.0);
    float xs = uv.x * aspect;

    // Live trace position here, for the curtain and the backlight.
    float mPhase = tw * 0.25;
    vec2 mShape = wcShape(uv.x, 0.0, mPhase, 0.15, tw, B, u);
    float mAmp = 0.10 * (0.85 + 0.2 * u.level);
    float yM = WC_TOP + wcShape(uv.x, 0.0, mPhase, 0.0, tw, B, u).x * mAmp;
    float below = uv.y - yM;
    float belowT = uv.y - (WC_TOP + mShape.x * mAmp);

    vec3 fogC = mix(wcFog(P, 0.55 + 0.10 * u.spectralCentroid, u), wcPal(P, 0.12 + 0.2 * uv.x), 0.5);
    vec3 col = fogC * (0.006 + 0.012 * smoothstep(0.0, 0.8, uv.y));

    // ---- the curtain: three depths of falling strands ----
    float riv = 0.0;
    vec3 heroLight = vec3(0.0);
    if (below > -0.01) {
        float fall = max(below, 0.0);
        float lip = smoothstep(-0.01, 0.02, below);
        float depthFade = exp(-fall * 1.3);
        float far = detail < -0.5 ? 0.0 : wcStrands(xs, fall, run * 0.55, 95.0, 0.08, 3.0);
        float mid = wcStrands(xs, fall, run * 0.8, 38.0, 0.06, 11.0);
        float near = 0.0;
        if (detail > 0.5) near = wcStrands(xs + 0.05 * sin(tw * 0.07), fall, run * 1.15, 11.0, 0.16, 23.0);
        else if (detail > -0.5) mid = mix(mid, wcStrands(xs, fall, run * 0.8, 17.0, 0.12, 5.0), 0.35);
        riv = mid;
        float pour = (0.6 + 0.3 * cb) * lip;
        vec3 farC = mix(fogC, wcPal(P, 0.02 + 0.12 * uv.x), 0.6);
        vec3 midC = mix(wcPal(P, 0.30 + 0.35 * uv.x), wcPal(P, 0.12), smoothstep(0.0, 0.6, fall));
        vec3 nearC = wcPal(P, 0.42 + 0.2 * uv.x);
        col += farC * far * pour * 0.055 * (0.5 + depthFade);
        col += midC * mid * pour * (0.04 + 0.08 * depthFade) * (0.7 + 0.3 * flow);
        col += nearC * near * pour * 0.05;
        // a soft sheen of the water body behind the strands
        col += midC * lip * exp(-fall * 3.0) * (0.03 + 0.05 * cb);

        // ---- torrents: each bass hit plunges down one column ----
        for (int j = 0; j < 2; ++j) {
            vec3 hh = wcHero(seedN, float(j), ph, u);
            vec3 heroC = wcHeroC(P, seedN, float(j));
            float a = hh.z;
            float dx = (xs - hh.x * aspect);
            float down = step(0.75, hh.y);
            float w = mix(0.035, 0.045, down);
            float colM = exp(-dx * dx / (w * w));
            if (a > 2.0) continue;
            float f = min(1.0, a / WC_LAND);
            // a ragged front: each rivulet's head runs a little ahead or behind
            float yF = yM + (WC_FLOOR - yM) * f
                     + (detail < -0.5 ? 0.0 : 0.05 * (vnoise(vec2(xs * 38.0, mod(seedN - float(j), 512.0) * 1.3)) - 0.5) * (1.0 - f * f));
            if (colM < 0.003) continue;
            float body = smoothstep(yF + 0.012, yF - 0.03, uv.y) * lip;
            float thin = 1.0 - smoothstep(WC_LAND, 2.0, a);
            float tor = hh.y * colM * body * thin;
            float crest = hh.y * colM * exp(-abs(uv.y - yF) * 45.0) * (1.0 - smoothstep(0.8, 1.0, f));
            // the torrent is the curtain's own strands running hot, with a white-hot core
            float rush = mid + 0.6 * far + near * 0.35;
            heroLight += heroC * (tor * (0.07 + 0.08 * rush) + crest * 0.15 * rush);
            heroLight += peakWhite(heroC, 0.55) * tor * exp(-dx * dx / (w * w * 0.04)) * (0.05 + 0.05 * mid);
            // volumetric spill: the torrent lights the mist around it
            heroLight += heroC * hh.y * exp(-dx * dx / (w * w * 5.0)) * body * thin * 0.035;
        }
        col += heroLight * 0.5;

        // backlit spray: slow clouds of palette light drifting behind the
        // strands, cool at the lip and deepening as the water falls
        float cn = vnoise(vec2(xs * 2.3 - tw * 0.04, fall * 2.6 - run * 0.30));
        float cn2 = vnoise(vec2(xs * 5.7 + 7.0, fall * 5.5 - run * 0.55));
        float cloud = smoothstep(0.32, 0.85, 0.65 * cn + 0.35 * cn2);
        vec3 cloudC = mix(wcPal(P, 0.36 + 0.22 * uv.x + 0.06 * sin(tw * 0.09)),
                          wcPal(P, 0.02 + 0.20 * uv.x + 0.06 * u.spectralCentroid), smoothstep(0.0, 0.5, fall));
        col += cloudC * cloud * lip * exp(-fall * 1.2)
             * (0.08 + 0.05 * u.level) * (0.7 + 0.4 * cb);
    } else {
        // Backlight haze over the lip of the falls.
        col += wcPal(P, 0.4 + 0.3 * uv.x) * exp(below * 18.0) * 0.07 * (0.8 + 0.3 * u.level);
    }

    // ---- falling sheets: one detaches per beat and breaks into rivulets ----
    vec3 spill = vec3(0.0);
    for (int j = 0; j < 7; ++j) {
        if (j >= nSheets) break;
        float fj = float(j);
        float age = ph + fj;
        float seed = mod(seedN - fj, 512.0);
        float yFall = WC_TOP + 0.15 * g * age * age;
        float yStack = WC_FLOOR - 0.006 - 0.075 / (1.0 + 0.5 * age * age);
        float yj = min(yFall, yStack);
        float settled = smoothstep(-0.02, 0.01, yFall - yStack);
        float d0 = uv.y - yj;
        float vel = 0.3 * g * age * (1.0 - settled);
        float veilLen = min(0.015 + vel * 0.5, 0.13);
        // falling sheets come toward the viewer: they widen with a slight drift
        float grow = 1.0 + 0.09 * age;
        float reach = 0.105 * grow * exp(-age * 0.30) * (0.85 + 0.2 * u.level);
        if (d0 < -reach - 0.04 - 3.0 * veilLen || d0 > reach + 0.13) continue;
        float xq = 0.5 + (uv.x - 0.5) / grow + age * 0.010;
        float live = 1.0 - smoothstep(0.0, 0.45, age);
        float amp = 0.085 * grow * exp(-age * 0.30) * (0.85 + 0.2 * u.level) * mix(1.0, 0.45, settled);
        vec2 sh = wcShape(xq, seed, seed + live * ph, live, tw, B, u);
        float ys = yj + sh.x * amp;
        float slope = sh.y * amp / (aspect * grow);
        float d = uv.y - ys;

        float fade = exp(-age * life) * (1.0 - 0.7 * settled)
                   * (1.0 - smoothstep(float(nSheets) - 2.2, float(nSheets), age));
        // sheets keep to the cool end of the palette; the warm accent belongs to the torrents
        vec3 sc = wcPal(P, fract(0.92 + 0.62 * fract(seed * 0.137 + 0.08 * xq)));
        sc = accentize(sc, u.accent, 0.08);
        // the sheet twists as it falls: face width and tilt follow a slow twist
        float tw0 = xq * 5.0 + seed * 1.37 + age * 1.1;
        float twc = cos(tw0);
        float opn = smoothstep(0.0, 2.0, age) * (1.0 - settled);
        float th = (mix(0.0045, 0.008 + 0.042 * abs(twc), opn) + 0.004 * settled) * grow;
        vec3 c = wcRibbon(d, th, slope, sin(tw0) * 0.9 * opn, sc, px) * 1.1;
        // soft glow and motion streaks trailing up toward where it came from
        float dm = d - th * 0.5;
        c += sc * (exp(-abs(dm) * 90.0) * 0.16 + exp(-abs(dm) * 30.0) * 0.06);
        if (d < 0.0 && vel > 0.0) {
            float st = vnoise(vec2(xq * aspect * 70.0, seed * 3.1));
            float st2 = detail < -0.5 ? 0.5 : vnoise(vec2(xq * aspect * 18.0 + 4.0, uv.y * 6.0 + seed));
            float veil = max(exp(d / veilLen) - 0.05, 0.0) * 1.05;
            c += sc * veil * (0.10 + 0.45 * st * st + 0.15 * st2) * smoothstep(0.0, 0.3, vel);
        }
        // mid-fall the sheet tears into the rivulets of the curtain
        float tear = smoothstep(0.7, 2.6, age) * (1.0 - settled);
        c *= mix(1.0, 0.12 + 1.3 * riv, tear);
        c *= fade * (0.75 + 0.25 * cb);
        // while it drops fast the sheet is a faint veil, then it lights up again
        // slowly once it has settled on the pool
        float lit = smoothstep(0.0, 2.0, yFall - yStack);
        float capL = mix(0.02, 0.3, lit);
        float lc = dot(c, vec3(0.2126, 0.7152, 0.0722));
        col += c * min(1.0, capL / max(lc, 1e-4));
        spill += sc * exp(-abs(d0) * 9.0) * (1.0 - smoothstep(0.08, 0.12, abs(d0))) * fade * mix(0.25, 1.0, settled);
    }
    // sheets light the falling curtain behind them
    col += spill * (0.03 + 0.5 * riv) * 0.22;

    // ---- live trace: hot glass tube ----
    float mSlope = mShape.y * mAmp / aspect;
    vec3 mc = wcPal(P, fract(uv.x * 0.7 + 0.10 * u.spectralCentroid));
    float hot = 1.0 + 0.5 * cb;
    float mth = 0.0065;
    col += wcRibbon(belowT + mth * 0.5, mth, mSlope, 0.0, mc, px) * 1.5 * hot;
    col += mc * exp(-abs(belowT) * 50.0) * (0.25 + 0.15 * u.level);
    // the torrent's source flares white-gold on the lip
    vec3 h0 = wcHero(seedN, 0.0, ph, u);
    float lx = (xs - h0.x * aspect);
    col += peakWhite(wcHeroC(P, seedN, 0.0), 0.5) * h0.y * exp(-lx * lx * 60.0) * exp(-abs(below) * 120.0)
         * smoothstep(0.0, 0.4, ph) * exp(-ph * 1.5) * 0.3;
    return col;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    float g = mix(0.22, 0.62, u.param0);
    float life = mix(0.55, 0.30, u.param1); // decay rate (lower = longer life)
    float sprayAmt = mix(0.3, 1.4, u.param2);
    float detail = osDetail(u);
    WcPal P = wcPalLoad(u);
    WcBands B = wcBandsLoad(u);
    int nSheets = osSteps(4.0, 6.0, detail);
    // uv.y increases down the frame: the trace lives at small y, the pool at large y.
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float px = 1.2 / max(u.resolution.y, 1.0);
    float tw = mod(u.time, 628.31853);
    float seedN = floor(u.beatCount);
    float ph = clamp(u.beatPhase, 0.0, 1.0);
    // Flow of the curtain: cruise, build, surge, brake, drift with the beat profile.
    float run = mod(tw * 0.13, 1024.0);
    float flow = 0.5;
    vec3 h0 = wcHero(seedN, 0.0, ph, u);
    vec3 h1 = wcHero(seedN, 1.0, ph, u);
    vec3 hc0 = wcHeroC(P, seedN, 0.0);
    vec3 hc1 = wcHeroC(P, seedN, 1.0);

    vec3 col;
    if (uv.y < WC_FLOOR) {
        col = wcScene(uv, g, life, nSheets, detail, aspect, tw, run, flow, px, P, B, u);
    } else {
        // ---- mirror pool: rippled reflection of the cascade ----
        float pz = (uv.y - WC_FLOOR) / (1.0 - WC_FLOOR);
        float rip = vnoise(vec2(uv.x * aspect * 7.0, 3.0 / (pz + 0.08) - tw * 0.12)) - 0.5;
        float rip2 = vnoise(vec2(uv.x * aspect * 23.0 + 5.0, 6.0 / (pz + 0.08) - tw * 0.16)) - 0.5;
        float wob = (rip + 0.5 * rip2) * (0.25 + pz) * 1.0;
        // rings spreading from where the torrents land
        float ring = 0.0;
        vec3 ringC = vec3(0.0);
        for (int j = 0; j < 2; ++j) {
            vec3 hh = j == 0 ? h0 : h1;
            float ts = hh.z - WC_LAND;
            if (ts <= 0.0) continue;
            vec2 rp = vec2((uv.x - hh.x) * aspect, pz * 0.55);
            float rr = length(rp);
            float rad = 0.04 + 0.62 * sqrt(ts);
            float wv = exp(-abs(rr - rad) * (70.0 - 30.0 * pz)) * hh.y * exp(-ts * 1.7) * (1.0 - smoothstep(0.3, 1.1, ts));
            float rw = wv * (0.7 + 0.6 * sin((rr - rad) * 160.0));
            ring += rw;
            ringC += (j == 0 ? hc0 : hc1) * rw;
        }
        wob += ring * 0.5;
        vec2 q = vec2(uv.x + wob * 0.006, WC_FLOOR - (uv.y - WC_FLOOR) * 2.2 + wob * 0.015 * pz);
        float fres = mix(0.5, 0.2, sqrt(pz));
        col = wcScene(q, g, life, nSheets - 2, -1.0, aspect, tw, run, flow, px * (1.0 + 4.0 * pz), P, B, u) * fres;
        // glossy pool body lit by the bass
        float pool = exp(-pz * 5.0);
        float pm = vnoise(vec2(uv.x * aspect * 3.0, pz * 4.0 - tw * 0.2));
        col += wcPal(P, fract(0.18 + tw * 0.004)) * pool * (0.05 + 0.06 * u.level) * (0.4 + 0.8 * pm);
        col += mix(ringC, wcPal(P, 0.95) * ring, 0.35 + 0.4 * pz) * 0.08 * (1.0 - 0.5 * pz);
        col += wcPal(P, 0.6) * 0.004;
    }

    // ---- impact mist where the water meets the pool, blooming at each landing ----
    float my = (uv.y - WC_FLOOR) * 16.0;
    float mistBand = exp(-my * my);
    float bloom = 0.0;
    vec3 bloomC = vec3(0.0);
    for (int j = 0; j < 2; ++j) {
        vec3 hh = j == 0 ? h0 : h1;
        float ts = hh.z - WC_LAND;
        if (ts <= -0.05) continue;
        float dx = (uv.x - hh.x) * aspect;
        float sz = 0.05 + 0.16 * smoothstep(0.0, 1.0, ts);
        float dy = (uv.y - WC_FLOOR + 0.035 + 0.07 * ts) / (sz * 0.9);
        float m = exp(-dx * dx / (sz * sz * 1.6) - dy * dy);
        float bm = m * hh.y * smoothstep(-0.05, 0.4, ts) * exp(-max(ts, 0.0) * 1.2) * (1.0 - smoothstep(0.4, 1.1, ts));
        bloom += bm;
        bloomC += (j == 0 ? hc0 : hc1) * bm;
    }
    if (mistBand + bloom > 0.01) {
        float mn = vnoise(vec2(uv.x * aspect * 9.0, uv.y * 16.0 + tw * 0.2));
        float mn2 = vnoise(vec2(uv.x * aspect * 4.0 - tw * 0.1, uv.y * 7.0 + tw * 0.25));
        col += wcPal(P, 0.45) * mistBand * (0.06 + 0.12 * mn) * (0.8 + 0.2 * u.level);
        col += mix(bloomC, vec3(bloom), 0.2) * (0.25 + 0.65 * mn2 * mn2) * 0.08;
    }

    // ---- splash crowns: droplets thrown up where each torrent lands ----
    int nDrop = osSteps(10.0, 20.0, detail);
    for (int j = 0; j < 2; ++j) {
        vec3 hh = j == 0 ? h0 : h1;
        vec3 heroC = j == 0 ? hc0 : hc1;
        float ts = hh.z - WC_LAND;
        if (ts <= 0.0) continue;
        float nk = mod(seedN - float(j), 512.0);
        float gain = hh.y * (0.6 + 0.4 * sprayAmt) * (1.0 - smoothstep(0.45, 0.95, ts));
        vec2 base = vec2(hh.x * aspect, WC_FLOOR - 0.004);
        // the crown never leaves this box, so most pixels skip the droplets
        if (gain < 0.01 || abs(uv.x * aspect - base.x) > 0.62 * ts + 0.03 || uv.y < WC_FLOOR - 0.42 || uv.y > WC_FLOOR + 0.02) continue;
        for (int i = 0; i < 20; ++i) {
            if (i >= nDrop) break;
            float fi = float(i);
            vec2 h = hash22(vec2(fi * 2.31 + 0.7, nk * 1.37));
            float vx = (h.x - 0.5) * (0.6 + 0.5 * hh.y);
            float vy = (0.32 + 0.6 * h.y * h.y) * (0.7 + 0.45 * hh.y);
            float G = 1.5;
            float tl = 2.0 * vy / G;
            if (ts > tl) continue;
            float t0 = max(ts - 0.022, 0.0);
            vec2 p1 = base + vec2(vx * ts, -vy * ts + 0.5 * G * ts * ts);
            vec2 p0 = base + vec2(vx * t0, -vy * t0 + 0.5 * G * t0 * t0);
            vec2 pa = vec2(uv.x * aspect, uv.y) - p0;
            vec2 ba = p1 - p0;
            float hb = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
            float dist = length(pa - ba * hb);
            if (dist > 0.02) continue;
            float r = 0.0018 + 0.0034 * fract(h.x * 7.3);
            float life01 = ts / tl;
            float e = (1.0 - life01 * life01) * gain;
            col += peakWhite(heroC, 0.35 + 0.4 * hb) * (smoothstep(r, r * 0.3, dist) * 0.5
                 + exp(-dist * 260.0) * 0.18) * e;
        }
    }

    // ---- onset spray: droplets flung off the newest detachment, with depth of field ----
    int nSpray = osSteps(10.0, 24.0, detail);
    float sprayFade = exp(-ph * 2.2) * (1.0 - smoothstep(0.7, 1.0, ph));
    float sprayGain = (0.1 + 0.1 * u.level + 0.04 * u.onset) * sprayAmt * sprayFade;
    if (sprayGain > 0.002) {
        float sk = mod(seedN, 512.0);
        for (int i = 0; i < 24; ++i) {
            if (i >= nSpray) break;
            float fi = float(i);
            vec2 h = hash22(vec2(fi * 1.91, sk * 3.7));
            float hz = hash21(vec2(fi * 5.3 + 1.0, sk * 1.3));
            float sx = h.x + (h.y - 0.5) * 0.35 * ph;
            float sy = WC_TOP - 0.02 - (0.28 * h.y) * ph + 0.42 * ph * ph;
            vec2 dv = uv - vec2(sx, sy);
            dv.x *= aspect;
            float r = mix(0.0025, 0.016, hz * hz * hz);
            float dist = length(dv);
            if (dist > r * 1.6) continue;
            float disc = 1.0 - smoothstep(r * 0.55, r, dist);
            float ring = exp(-abs(dist - r * 0.8) / (r * 0.12)) * 0.3 * step(0.006, r);
            float e = (0.0025 / r);
            col += wcTreble(P, fract(fi * 0.083), u) * (disc + ring) * e * e * sprayGain * 1.4;
        }
    }

    // ---- near layer: slow, soft bokeh drifting in front ----
    int nBokeh = osSteps(3.0, 7.0, detail);
    for (int i = 0; i < 7; ++i) {
        if (i >= nBokeh) break;
        float fi = float(i);
        vec2 h = hash22(vec2(fi * 7.13 + 2.0, 11.7));
        float yb = fract(h.y - tw * 0.006 * (0.5 + h.x));
        vec2 bc = vec2(h.x + 0.04 * sin(tw * 0.05 + fi * 1.7), yb * 1.2 - 0.1);
        vec2 dv = uv - bc;
        dv.x *= aspect;
        float r = 0.05 + 0.06 * fract(h.x * 13.1);
        float dist = length(dv);
        if (dist > r * 1.1) continue;
        float disc = 1.0 - smoothstep(r * 0.86, r, dist);
        float edge = exp(-abs(dist - r * 0.93) * 120.0) * 0.6;
        float win = sin(3.14159 * clamp(yb, 0.0, 1.0));
        col += wcPal(P, fract(0.5 + fi * 0.137)) * (disc * 0.5 + edge) * win
             * 0.018 * (1.0 + 0.2 * u.level);
    }

    // mist rising off the lip into the dark above, thicker while the falls run hard
    if (uv.y < WC_TOP) {
        float above = (WC_TOP - uv.y) / WC_TOP;
        float mn = vnoise(vec2(uv.x * aspect * 3.0 + tw * 0.05, uv.y * 6.0 + tw * 0.35));
        col += mix(wcPal(P, 0.55), wcPal(P, 0.95), above) * exp(-above * 2.2)
             * (0.03 + 0.06 * mn * mn) * (0.6 + 0.7 * flow);
    }

    // frame falloff
    vec2 c = uv - vec2(0.5, 0.46);
    col *= 1.0 - dot(c, c) * 0.7;

    return col; // LINEAR HDR
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
