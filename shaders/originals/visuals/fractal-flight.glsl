// SPDX-License-Identifier: AGPL-3.0-only
// Fractal flight.
// A raymarched flight down the open galleries of an endless Apollonian
// fractal, treated as a cathedral: far overhead the sun reaches the galleries
// through a drifting vault of stained-glass panes, so every shaft through the
// lace carries its pane's colour, pools of tinted light slide over the bone-
// dark walls, and the panes turn through the palette with the bars. The
// fractal's inversion strength drifts slowly along the path, so the lace
// thickens, opens and morphs as the flight goes on and the gallery never
// repeats. The pace follows a 32-beat profile of cruise, build, burst, brake
// and drift, kept under twice cruise; the field of view widens a little with
// it and the roll eases to a new side every eight beats. Audio recolours the
// light at a steady brightness, never the camera: a colour wave runs down the
// lace on each beat, spectrum bands light the orbit-trap veins and each beat
// swings the vault toward the complementary colour, a fresh handful of panes
// all the way. Every pane
// passes the same luminance, so the flight changes the frame's colour rather
// than flashing its brightness, which the frame limiter would hold as ghosting.
// param0 = Flight Speed ; param1 = Banking ; param2 = Glow

// The path and every drift along z are periodic over FF_LOOP world units (a
// multiple of the fractal's 4-unit period), so the flight distance can be
// wrapped without a seam.
const float FF_LOOP = 400.0;
const float FF_W = 6.2831853 / FF_LOOP;

vec3 ffPath(float z) {
    // weave inside the open gallery centred on world (2, 2)
    return vec3(2.0 + 0.36 * sin(z * FF_W * 13.0) + 0.12 * sin(z * FF_W * 30.0 + 1.7),
                2.0 + 0.28 * sin(z * FF_W * 11.0 + 0.6),
                z);
}

// Inversion strength along the path: from heavy, fused lace near 1.05 to
// fine open filigree near 1.45. Every value keeps the gallery axis clear.
float ffS(float z) {
    return 1.25 + 0.14 * sin(z * FF_W * 6.0) + 0.06 * sin(z * FF_W * 17.0 + 1.3);
}

// Lace thickness along the path, out of step with the strength: from open
// filigree to heavy, porous bone. At most 0.32 keeps 0.35 units of clearance.
float ffTh(float z) {
    return 0.17 + 0.15 * sin(z * FF_W * 4.0 + 0.7);
}

// Distance in world units; it iterations (fewer for shadow probes).
float ffMap(vec3 p, int it) {
    float s = ffS(p.z);
    float th = ffTh(p.z);
    p *= 0.5;
    float scale = 1.0;
    for (int i = 0; i < 7; i++) {
        if (i >= it) break;
        p = -1.0 + 2.0 * fract(0.5 * p + 0.5);
        float k = s / max(dot(p, p), 1e-4);
        p *= k;
        scale *= k;
    }
    return 0.5 * (length(p) - th) / scale;
}

// Orbit trap at the hit point. scaleLog is log2 of the accumulated inversion
// scale: high on the fine lace, low across the broad sphere faces.
vec4 ffTrap(vec3 p, out float scaleLog) {
    float s = ffS(p.z);
    p *= 0.5;
    vec4 orb = vec4(1000.0);
    float scale = 1.0;
    for (int i = 0; i < 7; i++) {
        p = -1.0 + 2.0 * fract(0.5 * p + 0.5);
        float r2 = dot(p, p);
        orb = min(orb, vec4(abs(p), r2));
        float k = s / max(r2, 1e-4);
        p *= k;
        scale *= k;
    }
    scaleLog = log2(max(scale, 1e-6));
    return orb;
}


// Interleaved gradient noise: a fine, unstructured dither for the shaft
// integral (an ordered matrix showed as a cross-hatch at the low levels).
float ffIgn(vec2 px) {
    return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));
}

// Cyclic blend through four colours read once per frame.
vec3 ffCyc(float h, vec3 a, vec3 b, vec3 c, vec3 d) {
    float x = fract(h) * 4.0;
    vec3 r = mix(a, b, smoothstep(0.0, 1.0, x));
    r = mix(r, c, smoothstep(1.0, 2.0, x));
    r = mix(r, d, smoothstep(2.0, 3.0, x));
    return mix(r, a, smoothstep(3.0, 4.0, x));
}

// c recoloured to the luminance of ref: a beat changes the colour of the
// light, not its brightness, so no large area flashes
vec3 ffAtLuma(vec3 c, vec3 ref) {
    return c * (luma(ref) / max(luma(c), 1e-4));
}

// Stained-glass light cookie: the sun reaches the galleries through a slowly
// drifting vault of panes far overhead. c is the position across the beams,
// in the plane square to the sun. Returns the pane's tinted transmission.
// pane.x = hue offset, pane.y = beat flare seed.
// The shafts read only the broad octave (smoother integral, fewer samples
// needed); the light pools on the walls add the fine one (oct = 1).
vec3 ffCookie(vec2 c, float tm, float soft, float oct, float hue, float flare, float fseed,
              vec3 ca, vec3 cb, vec3 cc, vec3 cd) {
    vec2 q = c * 1.05 + vec2(tm * 0.03, tm * 0.017);
    float n = vnoise(q);
    if (oct > 0.5) n = n * 0.65 + vnoise(q * 2.3 + 5.1) * 0.35;
    float open = smoothstep(0.64 - soft, 0.7 + 0.04 * (1.0 - oct), n);
    // leaded panes: a cell grid sheared off the noise lattice
    vec2 cell = floor(q * 1.1 + vec2(0.37 * q.y, 0.0));
    float hp = hash21(cell + 17.0);
    // every pane passes the same luminance in its own colour, so flying
    // through the beams changes their colour, not the frame's brightness
    vec3 tint = ffAtLuma(ffCyc(hue + 0.7 * hp, ca, cb, cc, cd),
                         vec3(0.25 * (luma(ca) + luma(cb) + luma(cc) + luma(cd))));
    // each beat the vault swings toward the complementary colour and eases
    // back, a different few panes all the way
    float pick = mix(0.6, 1.0, step(fract(hp * 7.31 + fseed), 0.24));
    vec3 flareC = ffAtLuma(ffCyc(hue + 0.7 * hp + 0.4, ca, cb, cc, cd), tint);
    return mix(tint, flareC, flare * pick) * open;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);

    float speed = mix(0.25, 1.4, u.param0);
    // the 32-beat profile shapes the pace, but a burst runs under twice cruise:
    // a fast pass through bright lace changes most of the frame's luminance
    // every frame, which the frame limiter has to hold back as ghosting
    vec2 fl = osFlight(u, 0.0, 1.0);
    float z = mod(u.time * speed * 1.3 + fl.x * speed * 0.19, FF_LOOP);
    float rush = saturate((fl.y - 1.0) / 3.5);
    float lull = saturate(1.0 - fl.y);
    vec3 ro = ffPath(z);
    vec3 ahead = ffPath(z + 0.9);

    vec3 fw = normalize(ahead - ro);
    float roll = osBank(u, mix(0.0, 0.35, u.param1)) + 1.6 * (ahead.x - ffPath(z + 0.45).x);
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(fw, up));
    vec3 cu = cross(rt, fw);
    float fov = 1.05 - 0.1 * rush + 0.05 * lull;
    vec3 rd = normalize(p.x * rt + p.y * cu + fov * fw);

    float tm = mod(u.time, 600.0);
    float bassL = 0.5 * u.bass + 0.5 * u.bassImpact;
    float glowAmt = mix(0.5, 1.6, u.param2);

    // the palette, read once at four fixed stops and blended locally
    vec3 cA = palVisual(0.02, u);
    vec3 cB = palVisual(0.25, u);
    vec3 cC = palVisual(0.50, u);
    vec3 cD = palVisual(0.77, u);
    // pane hues turn slowly with the bar
    float bars = mod(u.beatCount + saturate(u.beatPhase), 512.0);
    float hue = bars / 48.0;
    float bp = saturate(u.beatPhase);
    float flare = (1.0 - bp) * (1.0 - bp);
    float fseed = fract(floor(mod(u.beatCount, 512.0)) * 0.618034);

    // the sun: high above and ahead, fixed in the world; the panes tint it
    vec3 L = normalize(vec3(0.3, 0.78, 0.55));
    vec3 sunC = vec3(1.25, 1.05, 0.85);
    vec3 hazeC = mix(vec3(luma(cD)), cD, 0.55) * 0.8 + 0.05 * cC;
    float mu = dot(rd, L);
    float pixAng = 2.0 / max(u.resolution.y, 1.0) / fov;

    // primary march
    float t = 0.02;
    float hit = 0.0;
    float glow = 0.0;
    int nMax = osSteps(36.0, 70.0, detail);
    float tMax = mix(9.0, 13.0, detail);
    for (int i = 0; i < 70; i++) {
        if (i >= nMax) break;
        float d = ffMap(ro + rd * t, 7);
        glow += exp(-d * 160.0) / (1.0 + 0.4 * t);
        if (d < 0.8 * pixAng * t + 0.0002) { hit = 1.0; break; }
        t += d;
        if (t > tMax) break;
    }
    float tEnd = hit > 0.5 ? t : tMax;

    // volumetric light: a few dithered samples along the ray, each probing
    // toward the sun for the lace that shadows it, so shafts stream in
    // through the holes
    vec2 px = floor(uv * u.resolution);
    // the four pixels of each 2x2 quad take interleaved offsets and are
    // averaged below, so the shafts get four times the samples at no cost
    vec2 qd = mod(px, 2.0);
    float dith = fract(ffIgn(floor(px * 0.5)) + 0.25 * (qd.x + 2.0 * qd.y));
    vec3 e1 = normalize(cross(L, vec3(0.0, 0.0, 1.0)));
    vec3 e2 = cross(L, e1);
    int nv = osSteps(16.0, 28.0, detail);
    // fewer samples get softer beam edges, so the low levels stay smooth
    float soft = 0.07 + 0.08 * (1.0 - detail);
    float tv = min(tEnd, 9.0);
    float dv = tv / float(nv);
    float sigma = 0.2;
    vec3 shafts = vec3(0.0);
    for (int i = 0; i < 28; i++) {
        if (i >= nv) break;
        float ts = (float(i) + dith) * dv;
        vec3 x = ro + rd * ts;
        vec3 sh = ffCookie(vec2(dot(x, e1), dot(x, e2)), tm, soft, 0.0, hue, flare, fseed, cA, cB, cC, cD);
        // the air at the camera is shared by every pixel: a beam crossing it
        // would brighten the whole frame at once, so the shafts start ahead
        shafts += sh * exp(-sigma * ts) * smoothstep(0.3, 3.0, ts) * dv;
    }
    // quad average: the partner's value is v +/- dFdx(v); the sign comes from
    // the parity's own derivative, so it holds whatever way a target orients
    // the window, and falls back to no averaging (sign 0) if quads misalign
    float sx = (1.0 - 2.0 * qd.x) * dFdx(qd.x);
    shafts += 0.5 * dFdx(shafts) * sx;
    float sy = (1.0 - 2.0 * qd.y) * dFdy(qd.y);
    shafts += 0.5 * dFdy(shafts) * sy;
    shafts = max(shafts, vec3(0.0));
    // forward-scattering phase: shafts glow brightest looking toward the sun
    float phase = 0.08 + 0.9 * pow(saturate(mu * 0.5 + 0.5), 8.0) + 2.5 * pow(saturate(mu), 24.0);
    // the beams keep their contrast low, since flying through them sweeps it
    // across the frame; a steady sunlit haze in the turning palette colour
    // carries the brightness instead
    vec3 hazeT = ffAtLuma(ffCyc(hue + 0.3, cA, cB, cC, cD), 0.25 * (cA + cB + cC + cD));
    vec3 inscatter = sunC * (shafts * 0.15 + hazeT * 0.18) * phase;
    vec3 fogCol = hazeC * 0.03 + cB * 0.002 * phase;

    vec3 col = fogCol;
    if (hit > 0.5) {
        vec3 pos = ro + rd * t;
        float e = 0.0006 + 0.0006 * t;
        vec2 k = vec2(1.0, -1.0);
        vec3 ng = k.xyy * ffMap(pos + k.xyy * e, 7) + k.yyx * ffMap(pos + k.yyx * e, 7) +
                  k.yxy * ffMap(pos + k.yxy * e, 7) + k.xxx * ffMap(pos + k.xxx * e, 7);
        vec3 n = ng / max(length(ng), 1e-6);

        float occ = 0.0;
        float wgt = 1.0;
        int nAo = osSteps(2.0, 3.0, detail);
        for (int j = 0; j < 3; j++) {
            if (j >= nAo) break;
            float hh = 0.03 + 0.07 * float(j * j);
            occ += max(hh - 2.0 * ffMap(pos + n * hh, 6), 0.0) * wgt;
            wgt *= 0.6;
        }
        float ao = saturate(1.0 - 2.5 * occ);

        // soft sun shadow
        float sh = 1.0;
        float hs = 0.02;
        int nSh = osSteps(4.0, 8.0, detail);
        for (int j = 0; j < 8; j++) {
            if (j >= nSh) break;
            float d = ffMap(pos + n * 0.004 + L * hs, 6);
            sh = min(sh, 8.0 * d / hs);
            hs += clamp(d, 0.03, 0.3);
        }
        vec3 pane = ffCookie(vec2(dot(pos, e1), dot(pos, e2)), tm, soft, 1.0, hue, flare, fseed, cA, cB, cC, cD);
        vec3 sunT = sunC * pane * saturate(sh) * 1.5;

        float sl;
        vec4 orb = ffTrap(pos, sl);
        float lace = smoothstep(6.0, 11.0, sl);
        float lw = log2(orb.w + 1e-3);
        float tone = fract(0.6 + 0.12 * lw + 0.08 * orb.x + 0.004 * z);
        // bone-dark stone, faintly tinted, so the coloured light paints it
        vec3 base = mix(vec3(0.16, 0.15, 0.14), ffCyc(tone, cA, cB, cC, cD), 0.3);
        base = base * base * 1.6 + 0.012;
        // shading LOD: lace finer than the pixel footprint loses its sparkle
        float fine = saturate((sl + log2(max(pixAng * t, 1e-6)) + 4.5) * 0.7);
        float crisp = 1.0 - 0.85 * fine;

        float dif = saturate(dot(n, L));
        vec3 hv = normalize(L - rd);
        float spec = pow(saturate(dot(n, hv)), 40.0);
        float ndv = saturate(-dot(n, rd));
        float fres = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
        vec3 refl = reflect(rd, n);
        float rs = saturate(dot(refl, L));

        // warm sun key through the beams, a cool lamp riding with the camera,
        // a cool rim and a glossy coat that mirrors the sun
        float lamp = ndv / (1.0 + t * t * 0.35);
        col = base * sunT * (2.4 * dif);
        col += base * hazeC * (2.3 * lamp + 0.1) * ao;
        col += sunT * spec * 2.0 * (0.2 + 0.8 * dif) * crisp;
        col += hazeC * pow(1.0 - ndv, 3.0) * 0.35 * ao / (1.0 + 0.3 * t);
        col += (hazeC * 0.15 + sunT * pow(rs, 6.0) * 1.2) * fres * ao * crisp;

        // spectrum veins: each trap shell carries one frequency as a thin
        // glowing line that brightens with its bin
        float shell = lw * 2.4 + 0.03 * z;
        float sf = fract(shell);
        float vein = pow(saturate(1.0 - abs(2.0 * sf - 1.0) * 1.15), 18.0);
        float bin = fract(floor(shell) * 0.618034);
        float lv = bandAt(u, bin);
        // veins glow opposite the panes' current hue: the complementary accent
        vec3 veinC = ffCyc(hue + 0.5 + 0.2 * bin, cA, cB, cC, cD);
        col += veinC * vein * (0.06 + 2.6 * lv * lv) * (1.0 - 0.6 * lace) * ao * crisp;

        // a glow wave runs ahead down the lace on each beat
        float wz = z + 1.0 + 9.0 * saturate(u.beatPhase);
        float wave = exp(-abs(pos.z - wz) * 2.5) * (1.0 - saturate(u.beatPhase)) * (0.4 + 0.8 * bassL);
        vec3 laceCol = ffCyc(hue + 0.5 + 0.15 * tone, cA, cB, cC, cD);
        // the wave recolours the lace at its own luminance
        vec3 waveC = ffAtLuma(ffCyc(hue + 0.85 + 0.15 * tone, cA, cB, cC, cD), laceCol);
        laceCol = mix(laceCol, waveC, saturate(wave));
        col += laceCol * lace * lace * glowAmt * (0.4 + 0.15 * u.treble) * (0.3 + 0.7 * ao) * (1.0 - 0.6 * fine);

        col = mix(col, fogCol, 1.0 - exp(-t * sigma));
    }
    col += inscatter;

    // the sun disc itself where the ray escapes
    col += sunC * pow(saturate(mu), 900.0) * 6.0 * (hit > 0.5 ? 0.0 : 1.0);

    // emissive glow from near misses
    vec3 gc = ffCyc(hue + 0.5, cA, cB, cC, cD);
    col += gc * glow * 0.0015 * glowAmt * (0.75 + 0.15 * u.amplitude);

    // break 8-bit banding in the dim haze gradients with a tiny dither
    float gn = ffIgn(px + vec2(17.0, 29.0)) - 0.5;
    col = max(col * (1.0 + 0.012 * gn) + vec3(0.0005 * gn), vec3(0.0));

    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
