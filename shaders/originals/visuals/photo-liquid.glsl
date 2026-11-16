// SPDX-License-Identifier: AGPL-3.0-only
// Photo liquid.
// The photo lies under a sheet of liquid glass. Heavy glossy drops slide
// across it, merge and part, each one a lens that magnifies the photo with
// spectral fringes at its meniscus, a dark refracted rim, a specular highlight
// and a caustic focused onto the photo below. Between the drops the photo
// slowly melts in a marbled flow while neon ink blooms through it. Each drop
// is a jewel of coloured glass: the palette tints most of them and every
// third takes the palette's complement, and each one changes colour on its
// own 8-beat step. The drops travel on the 32-beat speed profile; audio swells
// them and lights the ink and the highlights.
// param0 = Flow ; param1 = Ink ; param2 = Bloom

vec3 pqPhoto(vec2 s, VisualUniforms u) {
    return max(IMG(photoCover(clamp(s, 0.0, 1.0), u.resolution, IMGSIZE)).rgb, vec3(0.0));
}

// cyclic blend of four palette samples read once per pixel (each palette
// read is costly, so the visual reads four and interpolates)
vec3 pqPal(float t, vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
    float x = fract(t) * 4.0;
    float i = floor(x);
    float f = smoothstep(0.0, 1.0, x - i);
    vec3 a = i < 1.0 ? c0 : (i < 2.0 ? c1 : (i < 3.0 ? c2 : c3));
    vec3 b = i < 1.0 ? c1 : (i < 2.0 ? c2 : (i < 3.0 ? c3 : c0));
    return mix(a, b, f);
}
#define PQPAL(t) pqPal(t, pc0, pc1, pc2, pc3)

// a colour at full brightness, and its complement (hue turned half way)
vec3 pqNorm(vec3 c) { return c / max(max(c.r, max(c.g, c.b)), 1e-3); }
vec3 pqComp(vec3 c) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    return vec3(mx + mn) - c;
}

// cheap three-octave noise for the fine ripple on the liquid film
float pqNoise3(vec2 p) {
    float v = 0.5 * vnoise(p);
    p = FBM_OCTAVE * p;
    v += 0.25 * vnoise(p);
    p = FBM_OCTAVE * p;
    v += 0.125 * vnoise(p);
    return v;
}

// fbm with an octave count on the detail ladder, rescaled to fbm's range
float pqFbm(vec2 p, int oct) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        if (i >= oct) break;
        v += a * vnoise(p);
        p = FBM_OCTAVE * p;
        a *= 0.5;
    }
    return v * 0.96875 / max(1.0 - 2.0 * a, 0.5);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    float detail = osDetail(u);
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = centered(uv, u.resolution);   // y grows downward
    float t = mod(u.time, 600.0);

    float flowAmt  = mix(0.4, 1.4, u.param0);
    float veinAmt  = mix(0.3, 1.6, u.param1);
    float bloomAmt = mix(0.5, 1.4, u.param2);

    vec2 fl = osFlight(u, 0.35 * flowAmt, 0.10 * flowAmt);
    float d = mod(fl.x, 62.831853);          // drop paths: frequencies are tenths
    float dm = mod(fl.x, 400.0);             // melt flow offset
    float rush = saturate((fl.y - 1.0) / 3.5);
    float bc = u.beatCount + saturate(u.beatPhase);
    float kick = exp(-4.0 * saturate(u.beatPhase));
    // the colour wheel turns a little every beat and leans further in a rush
    float hueOff = mod(bc, 256.0) * (0.137 / 16.0) + 0.12 * rush;
    vec3 pc0 = palVisual(0.02, u);
    vec3 pc1 = palVisual(0.34, u);
    vec3 pc2 = palVisual(0.62, u);
    vec3 pc3 = palVisual(0.97, u);
    vec3 acc = pqNorm(pqComp(pqNorm(PQPAL(hueOff + 0.62))));   // complementary accent

    // ---- the drops: a metaball field with an analytic gradient ----
    int nd = osSteps(4.0, 8.0, detail);
    float phi = 0.0;
    float phiS = 0.0;                         // the field shifted for the drop shadow
    vec2 so = vec2(0.07, 0.10);
    vec2 gphi = vec2(0.0);
    vec3 tintAcc = vec3(0.0);
    float tintW = 1e-4;
    for (int i = 0; i < 8; i++) {
        if (i >= nd) break;
        float fi = float(i);
        vec2 h = hash22(vec2(fi * 3.7, 1.9));
        vec2 c = vec2(1.45 * sin(d * (0.3 + 0.1 * floor(h.x * 3.0)) + 6.2831853 * h.y),
                      0.78 * sin(d * (0.4 + 0.1 * floor(h.y * 3.0)) + 6.2831853 * h.x + fi));
        float sz = 0.20 + 0.16 * hash11(fi * 7.3 + 0.4) + 0.06 * bandAt(u, fi / 8.0)
                 + 0.04 * u.bassImpact + 0.04 * kick * u.beat;
        vec2 dv = p - c;
        float e = exp(-dot(dv, dv) / (sz * sz));
        phi += e;
        // each drop's glass colour steps on its own 8-beat cycle; every third
        // drop takes the complement. Blended by field weight so merged drops
        // mix their colours smoothly
        float qd = (bc + fi * 2.0) / 8.0;
        float dh = hash11(fi * 2.1 + 0.3) * 0.5 + hueOff + 0.25 * (floor(qd) + smoothstep(0.75, 1.0, fract(qd)));
        vec3 ti = pqNorm(PQPAL(dh));
        ti = mod(fi, 3.0) < 1.0 ? pqNorm(pqComp(ti)) : ti;
        float wt = e * e + 1e-6;
        tintAcc += ti * wt;
        tintW += wt;
        vec2 ds = dv - so;
        phiS += exp(-dot(ds, ds) / (sz * sz));
        gphi += -2.0 * dv / (sz * sz) * e;
    }
    float th = 0.45;
    float kx = 0.55;
    float x = saturate((phi - th) / kx);
    float hDrop = 1.0 - (1.0 - x) * (1.0 - x);          // domed profile
    vec2 gDrop = (x > 0.0 && x < 1.0) ? 2.0 * (1.0 - x) * gphi / kx : vec2(0.0);
    float inDrop = smoothstep(th - 0.02, th + 0.02, phi);
    vec3 tint = pqNorm(tintAcc / tintW);

    // ---- fine ripple on the liquid film everywhere ----
    vec2 rq = p * 3.0 + vec2(0.0, dm * 0.08);
    float r0 = pqNoise3(rq);
    float re = 0.06;
    vec2 gRip = vec2(pqNoise3(rq + vec2(re, 0.0)) - r0, pqNoise3(rq + vec2(0.0, re)) - r0) / re;

    vec2 grad = gDrop * 0.28 + gRip * (0.010 + 0.012 * u.mid);
    vec3 n = normalize(vec3(-grad, 1.0));

    // ---- the melting photo: a marbled domain warp ----
    vec2 mq = p * 1.1;
    int oct = osSteps(2.0, 5.0, detail);
    vec2 w1 = vec2(pqFbm(mq + vec2(0.0, dm * 0.05), oct), pqFbm(mq + vec2(5.2, 1.3 - dm * 0.04), oct)) - 0.5;
    vec2 w2 = vec2(pqFbm(mq + 2.0 * w1 + vec2(1.7, 9.2), oct), pqFbm(mq + 2.0 * w1 + vec2(8.3, 2.8), oct)) - 0.5;
    vec2 melt = w2 * 0.075 * flowAmt * (1.0 + 0.6 * rush);

    // refraction: thick glass in the drops, a thin film elsewhere
    // the sample bends toward each drop's crest, so the drops magnify
    float thick = 0.03 + 0.17 * hDrop;
    vec2 refr = -n.xy * thick;
    vec2 su = uv + melt * (1.0 - 0.7 * inDrop) + refr * vec2(1.0 / aspect, 1.0) * 0.5;
    float disp = (0.004 + 0.018 * (1.0 - hDrop) * inDrop + 0.006 * u.treble);
    vec2 dd = n.xy * disp;
    vec3 photo = vec3(pqPhoto(su + dd, u).r, pqPhoto(su, u).g, pqPhoto(su - dd, u).b);

    // grade: the photo between the drops sinks into the palette's deep end,
    // its highlights rise through the wheel and the brightest catch the accent
    float pl = luma(photo);
    float pt = smoothstep(0.1, 0.8, pl);
    vec3 duo = pl * pl * 1.6 * PQPAL(hueOff + 0.02 + 0.93 * pt);
    photo = mix(photo * photo, duo, 0.75);
    photo = max(mix(vec3(luma(photo)), photo, 1.3), vec3(0.0));
    // exposure: deep between the drops, brighter inside them
    vec3 col = photo * mix(0.55, 0.80 + 0.3 * u.level, inDrop);
    // the glass absorbs a little toward the palette as it thickens
    // thick glass: more contrast and a deep teal body tint toward the crest
    col = mix(col, col * col * 2.2, 0.55 * hDrop * inDrop);

    // caustic: the drop focuses light onto the photo below, offset from the key
    float caus = smoothstep(0.97, 1.0, hDrop) * (1.0 - 0.6 * saturate(length(gDrop) * 0.4));
    col += (photo + 0.05) * tint * caus * (0.12 + 0.35 * u.bass) * bloomAmt;
    // Beer-Lambert absorption: the thick glass deepens toward its own colour
    col *= exp(-(0.35 + 0.65 * hDrop) * inDrop * (vec3(1.0) - tint) * 3.2);
    col += tint * tint * hDrop * inDrop * (0.04 + 0.10 * u.bass);
    // outside the drops: their soft shadow, with light focused into its core
    float shadow = smoothstep(th - 0.15, th + 0.1, phiS) * (1.0 - inDrop);
    float core = smoothstep(th + 0.25, th + 0.9, phiS) * (1.0 - inDrop);
    col *= 1.0 - 0.45 * shadow;
    col += (photo + 0.3) * tint * core * (0.6 + 0.8 * u.bass + 0.6 * kick * u.beat) * bloomAmt;
    // dark refracted rim inside the meniscus
    float rimIn = inDrop * smoothstep(0.6, 0.0, hDrop);
    col *= 1.0 - 0.85 * rimIn;

    // ---- neon ink blooming through the melt, bent under the drops ----
    vec2 vq = (p + refr * 0.8) * 1.15 + 2.4 * w2 + vec2(dm * 0.025, -dm * 0.015);
    float ink = pqFbm(vq, oct + 1);
    float vmask = smoothstep(0.42, 0.66, pqNoise3(p * 0.55 + vec2(-dm * 0.02, 3.0)) * 1.15);
    float dens = smoothstep(0.52, 0.74, ink) * vmask;
    float fil = exp(-abs(ink - 0.50 - 0.03 * sin(1.5707963 * bc)) * 55.0) * vmask;   // bright leading edge
    float vb = bandAt(u, fract(ink * 1.7 + 0.2 * w1.x));
    vec3 inkCol = PQPAL(hueOff + 0.30 + 0.5 * smoothstep(0.45, 0.9, ink));
    float inkVis = veinAmt * (1.0 - 0.55 * inDrop);
    col = mix(col, col * 0.45 + inkCol * inkCol * (0.12 + 1.1 * vb), saturate(dens * 0.65 * inkVis));
    vec3 filCol = mix(inkCol, acc, smoothstep(0.35, 0.9, vb));   // loud bands flare to the accent
    col += filCol * fil * (0.25 + 1.6 * vb + 0.5 * u.onset) * inkVis;

    // ---- lighting on the liquid surface ----
    vec3 v = vec3(0.0, 0.0, 1.0);
    vec3 l1 = normalize(vec3(-0.45, -0.65, 0.62));
    vec3 l2 = normalize(vec3(0.70, 0.35, 0.60));
    float s1 = pow(saturate(dot(n, normalize(l1 + v))), 120.0);
    float s2 = pow(saturate(dot(n, normalize(l2 + v))), 60.0);
    col += vec3(2.6, 2.5, 2.35) * s1 * (0.5 + 0.8 * u.treble + 0.4 * u.onset) * bloomAmt;
    col += PQPAL(hueOff + 0.62) * s2 * (0.8 + 1.4 * u.bassImpact) * bloomAmt;
    // Fresnel: the meniscus reflects a soft, tinted copy of the photo
    float fres = pow(1.0 - saturate(n.z), 3.0) * inDrop;
    vec3 env = pqPhoto(uv - n.xy * 0.25, u);
    col += mix(env * env, tint * 0.5, 0.5) * fres * 0.9;
    // thin-film iridescence on the meniscus
    float film = hDrop * 2.2 + 0.4 * r0;
    vec3 irid = 0.5 + 0.5 * cos(6.2831853 * (film + vec3(0.0, 0.33, 0.67)));
    irid *= irid;    // saturated, not pastel
    col += irid * inDrop * pow(1.0 - hDrop, 3.0) * (0.35 + 0.6 * u.treble) * bloomAmt;
    // a hairline of light on the drop edge
    col += tint * exp(-abs(phi - th) * 60.0) * (0.35 + 0.6 * u.mid + 0.5 * kick * u.beat);

    // vignette
    col *= 1.0 - 0.5 * smoothstep(0.8, 2.0, length(p));
    return col; // LINEAR HDR — post chain tonemaps
}
