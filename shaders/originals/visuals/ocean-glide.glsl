// SPDX-License-Identifier: AGPL-3.0-only
// Ocean glide.
// A low glide over a choppy sunset ocean toward ridged sea mountains. A layered
// sky scatters the low sun through the palette, with backlit clouds that pass
// overhead and soft shafts around the sun. The water mirrors it with a sun
// glitter path, light shining through the crests, whitecaps and wind-blown
// spray; the mountains stand as hazy, rim-lit silhouettes. Bass swells the
// waves, onsets raise the whitecaps, treble sparkles the glitter. The camera's
// speed follows a 32-beat profile of cruise, build, burst, brake and drift,
// and the roll eases to a new side every eight beats.
// param0 = Glide Speed ; param1 = Banking ; param2 = Wave Height

float ogLane(float z) { return 30.0 * sin(z * 0.004); }

// One choppy swell octave: sharp crests over broad troughs, in [0, 1].
float ogOctave(vec2 uv, float choppy) {
    uv += vnoise(uv);
    vec2 wv = 1.0 - abs(sin(uv));
    vec2 swv = abs(cos(uv));
    wv = mix(wv, swv, wv);
    return pow(max(1.0 - pow(max(wv.x * wv.y, 1e-6), 0.65), 1e-6), choppy);
}

// Sea surface height, in [0, 2.6 amp].
float ogSea(vec2 p, float wt, float amp, int oct) {
    vec2 uv = p * vec2(0.75, 1.0);
    float freq = 0.16;
    float a = amp;
    float choppy = 4.0;
    float h = 0.0;
    for (int i = 0; i < 5; i++) {
        if (i >= oct) break;
        float d = ogOctave((uv + wt) * freq, choppy) + ogOctave((uv - wt) * freq, choppy);
        h += d * a;
        uv = FBM_OCTAVE * uv;
        freq *= 1.9;
        a *= 0.22;
        choppy = mix(choppy, 1.0, 0.2);
    }
    return h;
}

// Sea mountains: ridged noise that rises out of the water far from the lane.
float ogMountain(vec2 p, int oct) {
    float away = smoothstep(28.0, 110.0, abs(p.x - ogLane(p.y)));
    if (away <= 0.0) return -20.0;
    vec2 q = p * 0.011 + 3.0;
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        if (i >= oct) break;
        float n = 1.0 - abs(2.0 * vnoise(q) - 1.0);
        v += a * n * n;
        q = FBM_OCTAVE * q;
        a *= 0.5;
    }
    return away * (v * 100.0 - 18.0);
}

float ogFbm(vec2 p, int oct) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        if (i >= oct) break;
        v += a * vnoise(p);
        p = FBM_OCTAVE * p;
        a *= 0.5;
    }
    return v;
}

vec3 ogSunColour(VisualUniforms u) { return mix(vec3(1.0, 0.62, 0.26), palVisual(0.76, u), 0.4); }

// Sky seen along rd from ro; cloudOct = 0 skips the clouds.
vec3 ogSky(vec3 rd, vec3 ro, vec3 sunDir, VisualUniforms u, int cloudOct) {
    float h = rd.y;
    float hh = max(h, 0.0);
    float sd = saturate(dot(rd, sunDir));
    vec3 hor = palVisual(0.80, u);
    vec3 low = palVisual(0.96, u);
    vec3 zen = palVisual(0.02, u) * 0.16 + vec3(0.002, 0.005, 0.03);
    vec3 sunCol = ogSunColour(u);

    // the horizon burns brightest under the sun and cools to rose away from it
    vec2 az = rd.xz / max(length(rd.xz), 1e-4);
    float toSun = saturate(dot(az, normalize(sunDir.xz)));
    hor *= 0.3 + 0.7 * toSun * toSun * toSun;
    // amber at the waterline, a burnt-orange band above it, deep teal overhead
    vec3 col = mix(hor * 0.9 + low * 0.15, low * 0.42, smoothstep(0.0, 0.1, hh));
    col = mix(col, low * 0.12 + zen, smoothstep(0.06, 0.3, hh));
    col = mix(col, zen, smoothstep(0.25, 0.6, hh));
    col += hor * exp(-abs(h) * 30.0) * 0.35;
    // a tight, saturated glow instead of a wide cream wash
    col += sunCol * (pow(sd, 28.0) * 0.32 + pow(sd, 120.0) * 1.3) + hor * pow(sd, 6.0) * 0.08;

    float shadeD = 0.0;
    if (cloudOct > 0 && h > 0.0) {
        // a deck of clouds 260 units up, passed under as the camera flies
        vec2 cp = (rd.xz * (260.0 / (h + 0.05)) + ro.xz) * 0.0035;
        float n = ogFbm(cp * vec2(0.55, 1.0) + vec2(u.time * 0.012, 0.0), cloudOct);
        // a single octave (the cheap reflected sky) keeps the two-octave range
        if (cloudOct == 1) n *= 1.5;
        float dens = smoothstep(0.42, 0.72, n) * smoothstep(0.0, 0.1, h);
        // undersides burn orange from the low sun, thick cores go dusky teal,
        // and the edges facing the sun take a gold lining
        float edge = saturate(1.0 - abs(n - 0.48) * 7.0);
        float core = smoothstep(0.6, 0.85, n);
        vec3 under = low * 0.75 * (0.3 + 0.7 * toSun) + hor * 0.18 * pow(sd, 3.0);
        vec3 lit = mix(under, zen * 1.4 + low * 0.05, core * 0.8 + saturate(h * 2.5) * 0.4);
        lit += sunCol * 0.75 * pow(sd, 10.0) * (1.0 - core);
        vec3 cc = lit + mix(low, hor, 0.6) * edge * (0.12 + 1.2 * pow(sd, 3.0));
        col = mix(col, cc, dens * 0.95);

        shadeD = dens;
    }
    // soft shafts fanning out from the sun through the clouds (also where the
    // clouds are skipped, so every path to the horizon agrees around the sun)
    if (h > 0.0 && sd > 0.6) {
        vec3 sr = normalize(cross(sunDir, vec3(0.0, 1.0, 0.0)));
        vec3 su = cross(sr, sunDir);
        float ang = atan2_(dot(rd, su), dot(rd, sr));
        float shaft = vnoise(vec2(ang * 7.0, u.time * 0.06)) * vnoise(vec2(ang * 15.0 + 3.0, -u.time * 0.04));
        col += sunCol * shaft * pow(sd, 10.0) * (0.24 + 0.08 * u.bassImpact) * (1.0 - shadeD * 0.6);
    }
    // the disc
    col += sunCol * 30.0 * smoothstep(0.9993, 0.9997, sd);
    return col;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);

    float ampBase = mix(0.35, 0.9, u.param2);
    float amp = ampBase * (0.85 + 0.3 * saturate(u.bass));
    float wt = 1.0 + mod(u.time, 600.0) * 0.8;
    float speed = mix(5.0, 20.0, u.param0);
    vec2 fl = osFlight(u, speed, 2.2 * mix(0.5, 1.5, u.param0));
    float z = fl.x;
    float rush = saturate((fl.y - 1.0) / 3.5);
    float lull = saturate(1.0 - fl.y);
    // glide above the crests on a gentle swell the audio never moves
    float camY = 1.3 + 2.6 * ampBase + 0.3 * sin(u.time * 0.3) + 0.15 * sin(z * 0.05 + u.time * 0.7);
    vec3 ro = vec3(ogLane(z), camY, z);
    vec3 ta = vec3(ogLane(z + 20.0), camY - 1.1, z + 20.0);

    vec3 fw = normalize(ta - ro);
    float roll = osBank(u, mix(0.0, 0.2, u.param1)) - 0.012 * (ogLane(z + 30.0) - ogLane(z));
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(fw, up));
    vec3 cu = cross(rt, fw);
    float fov = 1.3 - 0.18 * rush + 0.08 * lull;
    vec3 rd = normalize(p.x * rt + p.y * cu + fov * fw);

    vec3 sunDir = normalize(vec3(0.15 * sin(u.time * 0.02), 0.055, 1.0));
    vec3 sunCol = ogSunColour(u);
    float sd = saturate(dot(rd, sunDir));
    int cloudOct = detail < 0.5 ? 3 : 4;

    float tFar = 520.0;
    // where the ray meets the still water level, or the far plane
    float tLevel = rd.y < -0.0005 ? min(ro.y / -rd.y, tFar) : tFar;

    // ---- mountains: march only out of the lane and below their peaks ----
    float tMtn = -1.0;
    {
        int nMax = osSteps(18.0, 44.0, detail);
        int oct = detail < 0.5 ? 2 : 3;
        float t = 1.0;
        float tPrev = t;
        // the lane's offset changes along the ray no faster than this
        float drift = abs(rd.x) + 0.125 * abs(rd.z) + 1e-3;
        bool esc = false;   // the ray left the mountains' reach
        bool inLane = true; // the last sample was still over open water
        float stride = mix(2.2, 1.3, detail);
        // only steps over the slopes count against the ladder; crossing the open
        // lane is a cheap stride, so a ray never runs out of budget just getting there
        int used = 0;
        for (int i = 0; i < 64; i++) {
            if (used >= nMax) break;
            vec3 pos = ro + rd * t;
            if (pos.y > 48.0 && rd.y >= 0.0) { esc = true; break; }
            float zone = 28.0 - abs(pos.x - ogLane(pos.z));
            inLane = zone > 0.0;
            float stepLen;
            if (zone > 0.0) {
                stepLen = zone / drift + 1.0;
            } else {
                used++;
                float dh = pos.y - ogMountain(pos.xz, oct);
                if (dh < 0.0) { tMtn = t; break; }
                // the coarse ladder takes longer strides; the bisection below recovers the edge
                stepLen = max(dh * 0.45, 0.4 + 0.012 * t) * stride;
            }
            tPrev = t;
            t += stepLen;
            if (t > tLevel) { esc = true; break; }
        }
        // out of steps while still grazing the slopes: call it the far rock in the haze
        // (unless it was still over the open lane, which would leave a sliver of fake rock)
        if (tMtn < 0.0 && !esc && !inLane) { tMtn = t; tPrev = t; }
        if (tMtn > 0.0) {
            int nBis = detail < 0.5 ? 5 : 4;
            for (int i = 0; i < 5; i++) {
                if (i >= nBis) break;
                float tm = 0.5 * (tMtn + tPrev);
                vec3 pm = ro + rd * tm;
                if (pm.y - ogMountain(pm.xz, oct) < 0.0) tMtn = tm; else tPrev = tm;
            }
        }
    }

    // ---- sea: march the slab between the crest bound and y = 0, up to the mountains ----
    float tSea = tFar;
    bool seaHit = false;
    if (rd.y < -0.0005) {
        float yTop = 2.6 * amp;
        float t0 = max((ro.y - yTop) / -rd.y, 0.0);
        float t1 = tMtn > 0.0 ? min(tLevel, tMtn) : tLevel;
        int nMax = osSteps(10.0, 24.0, detail);
        int oct = detail < 0.5 ? 2 : 3;
        float minStep = max(t1 - t0, 0.0) / float(nMax);
        float t = t0;
        float tPrev = t0;
        bool crossed = false;
        for (int i = 0; i < 24; i++) {
            if (i >= nMax || t > t1) break;
            vec3 pos = ro + rd * t;
            float sh = ogSea(pos.xz, wt, amp, t > 150.0 ? 2 : oct);
            float f = pos.y - sh;
            if (f < 0.0) { crossed = true; break; }
            tPrev = t;
            t += max(f / (-rd.y + 0.35), minStep);
            if (t > t1) {
                t = t1;
                vec3 pe = ro + rd * t;
                crossed = t1 < tFar && pe.y - ogSea(pe.xz, wt, amp, 2) < 0.0;
                break;
            }
        }
        if (crossed) {
            for (int i = 0; i < 4; i++) {
                float tm = 0.5 * (t + tPrev);
                vec3 pm = ro + rd * tm;
                if (pm.y - ogSea(pm.xz, wt, amp, oct) < 0.0) t = tm; else tPrev = tm;
            }
            tSea = t;
            tMtn = -1.0;
        }
        // with no crossing and no mountain, the far sea is a flat mirror under the haze
        seaHit = tMtn < 0.0;
    }

    vec3 col;
    float tHit;
    vec3 hazeCol = mix(palVisual(0.86, u) * 0.24 + palVisual(0.05, u) * 0.05, sunCol * 1.2, pow(sd, 8.0));
    if (tMtn > 0.0) {
        tHit = tMtn;
        vec3 pos = ro + rd * tMtn;
        float e = 0.08 + 0.004 * tMtn;
        int oct = detail < 0.5 ? 3 : 4;
        float hc = ogMountain(pos.xz, oct);
        vec3 n = normalize(vec3(hc - ogMountain(pos.xz + vec2(e, 0.0), oct), e,
                                hc - ogMountain(pos.xz + vec2(0.0, e), oct)));
        // gullies and strata break the smooth slopes into weathered rock
        float gully = 0.0;
        if (tMtn < 380.0) {
            gully = vnoise(vec2(pos.x * 0.35 + pos.z * 0.1, pos.y * 0.9)) - 0.5;
            n = normalize(n + vec3(gully * 0.5, 0.0, gully * 0.25) * (1.0 - smoothstep(150.0, 380.0, tMtn)));
        }
        // backlit rock: cool teal-blue faces lit by the sky, warm light on the slopes facing the sun
        float dif = saturate(dot(n, sunDir));
        vec3 rock = palVisual(0.02, u) * 0.035 + vec3(0.004, 0.005, 0.012);
        col = rock * (0.45 + 0.55 * saturate(n.y)) * (0.7 + 0.6 * gully + 0.3) + palVisual(0.02, u) * 0.05 * saturate(n.y) * saturate(n.y);
        // alpenglow: the low sun reaches the upper slopes, the feet stay in shade
        col += sunCol * palVisual(0.86, u) * dif * dif * 0.7 * smoothstep(4.0, 40.0, pos.y);
        // snow on the high, gentler ledges: rose-gold where the sun reaches, blue in shade
        float snowN = vnoise(pos.xz * 0.16);
        float snow = smoothstep(0.55, 0.8, n.y + 0.25 * snowN) * smoothstep(26.0, 46.0, pos.y + 14.0 * snowN);
        vec3 snowCol = palVisual(0.1, u) * 0.07 + vec3(0.02, 0.03, 0.06) + sunCol * 0.9 * dif;
        col = mix(col, snowCol, snow);
        // rim light: the low sun behind the ridges outlines every silhouette
        float rim = pow(1.0 - saturate(abs(dot(n, rd))), 10.0) * (0.3 + 0.7 * pow(sd, 3.0)) * saturate(n.y * 2.0);
        col += sunCol * rim * 0.9 * smoothstep(2.0, 20.0, pos.y);
    } else if (seaHit) {
        tHit = tSea;
        vec3 pos = ro + rd * tSea;
        float e = 0.01 + 0.0016 * tSea;
        int oct = tSea < 120.0 ? 4 : 3;
        if (detail < 0.5) oct = max(oct - 1, 2);
        float hc = ogSea(pos.xz, wt, amp, oct);
        vec3 n = normalize(vec3(hc - ogSea(pos.xz + vec2(e, 0.0), wt, amp, oct), e,
                                hc - ogSea(pos.xz + vec2(0.0, e), wt, amp, oct)));
        // far water calms toward a mirror so the horizon never shimmers
        n = normalize(mix(n, vec3(0.0, 1.0, 0.0), smoothstep(80.0, tFar, tSea) * 0.7));
        if (tSea >= tFar) n = vec3(0.0, 1.0, 0.0);
        // fine ripples near the camera keep the glitter crisp
        float nearR = 1.0 - smoothstep(8.0, 50.0, tSea);
        if (nearR > 0.0) {
            vec2 rp = pos.xz * 3.5 + vec2(wt * 1.7, wt * 0.6);
            n = normalize(n + vec3(vnoise(rp) - 0.5, 0.0, vnoise(rp.yx + 7.0) - 0.5) * 0.22 * nearR);
        }

        vec3 rr = reflect(rd, n);
        rr.y = abs(rr.y) + 0.015 * smoothstep(100.0, tFar, tSea);
        float fres = 0.02 + 0.98 * pow(saturate(1.0 - dot(n, -rd)), 5.0);
        vec3 refl = ogSky(rr, ro, sunDir, u, detail < 0.5 ? 0 : 1);
        // the mountains' mirror images: a few coarse samples along the reflected ray
        if (rr.y < 0.25) {
            float occ = 0.0;
            float s = 6.0;
            int nOcc = osSteps(3.0, 4.0, detail);
            for (int i = 0; i < 6; i++) {
                if (i >= nOcc) break;
                vec3 q = pos + rr * s;
                occ = max(occ, smoothstep(-1.0, 3.0, ogMountain(q.xz, 2) - q.y));
                if (occ > 0.99) break;
                s *= 2.1;
            }
            vec3 rock = palVisual(0.02, u) * 0.02 + vec3(0.004, 0.004, 0.008);
            refl = mix(refl, mix(rock, hazeCol * 0.8, 1.0 - exp(-(tSea + s) * 0.004)), occ);
        }

        float crest = saturate(hc / max(2.0 * amp, 0.05));
        float peak = hc / max(2.6 * amp, 0.05);
        vec3 deep = palVisual(0.02, u) * 0.05 + vec3(0.0, 0.004, 0.01);
        // sunlight through the thin crests, strongest looking toward the sun
        vec3 sss = palVisual(0.22, u) * crest * crest * crest * (0.04 + 0.55 * pow(sd, 4.0)) * (1.0 - 0.6 * saturate(n.y * n.y));
        col = mix(deep + sss, refl, fres);

        // glitter path toward the sun, sparkling on the treble
        float gl = saturate(dot(rr, sunDir));
        float path = pow(sd, 3.0);
        col += sunCol * pow(gl, 80.0) * 0.5 * path;

        // whitecaps: a web of foam filaments over the sharpest crests, more on onsets
        float foamLine = mix(0.74, 0.64, saturate(u.onset * 0.7 + u.bassImpact * 0.5));
        // foam is patchy and torn along the wind: broad blotches with bubbly holes,
        // plus thin streaks of old foam left behind in the troughs
        vec2 fp = pos.xz * vec2(1.1, 0.7) + vec2(0.0, wt * 0.6);
        float fw = vnoise(fp * 0.5 + 11.0);
        fp += vec2(fw, 1.0 - fw) * 0.8;
        float blot = smoothstep(0.35, 0.7, vnoise(fp));
        float holes = smoothstep(0.25, 0.65, vnoise(pos.xz * vec2(7.0, 4.5) + vec2(0.0, wt * 1.3)));
        float capMask = smoothstep(foamLine, foamLine + 0.12, peak);
        float streak = 0.0;
        if (tSea < 60.0) {
            streak = smoothstep(0.68, 0.88, vnoise(pos.xz * vec2(3.0, 0.3) + vec2(0.0, wt * 0.1)))
                   * smoothstep(0.45, 0.75, vnoise(pos.xz * vec2(0.5, 0.2) + 4.0))
                   * (1.0 - crest) * 0.18 * (1.0 - smoothstep(10.0, 60.0, tSea));
        }
        float foam = (capMask * blot * (0.35 + 0.65 * holes) + streak) * (1.0 - smoothstep(60.0, 200.0, tSea)) * (0.5 + 0.5 * smoothstep(3.0, 12.0, tSea));
        vec3 foamCol = palVisual(0.5, u) * 0.18 + sunCol * 0.45 * (0.25 + pow(sd, 2.0));
        col = mix(col, foamCol, foam * 0.55);

        // spray: fine wind-blown droplets torn off the crest tips, backlit by the sun
        float tip = smoothstep(foamLine + 0.08, 1.0, peak) * (1.0 - smoothstep(20.0, 140.0, tSea));
        if (tip > 0.0) {
            vec2 sp = pos.xz * vec2(9.0, 5.0) + vec2(wt * 2.0, wt * 3.1);
            float drops = pow(vnoise(sp) * vnoise(sp * 1.7 + 3.0), 3.0) * 8.0;
            vec3 sprayCol = palVisual(0.5, u) * 0.1 + sunCol * (0.15 + 2.5 * pow(sd, 4.0));
            col += sprayCol * tip * (0.15 + drops) * (0.6 + 1.2 * u.onset);
        }

        // The water streams past the camera, and every facet that turns from the
        // dark deep to the bright sunset sky and back would flash its pixels. So
        // each pixel keeps its hue (amber where the sky shows, teal in the deep,
        // the foam and spray) but its brightness is pulled most of the way to
        // what a calm mirror shows there: the colour moves, the light holds.
        vec3 rf = vec3(rd.x, abs(rd.y) + 0.015 * smoothstep(100.0, tFar, tSea), rd.z);
        float fres0 = 0.02 + 0.98 * pow(saturate(1.0 + rd.y), 5.0);
        float lm = luma(mix(deep, ogSky(rf, ro, sunDir, u, 0), fres0));
        col *= pow(max(lm, 1e-4) / max(luma(col), 1e-4), 0.85);
        // the sun's glints stay sparkling on top: each covers a pixel or two, too
        // little area to flash the frame
        col += sunCol * pow(gl, 1200.0) * 30.0 * (0.4 + 0.6 * path) * (1.0 + 2.0 * u.treble);
    } else {
        tHit = tFar;
        col = ogSky(rd, ro, sunDir, u, cloudOct);
    }

    // aerial perspective: warm haze toward the sun, thicker near the water
    if (tMtn > 0.0 || seaHit) {
        float fog = 1.0 - exp(-tHit * 0.0035);
        if (tMtn > 0.0) fog = saturate(fog * (1.3 - 0.85 * smoothstep(0.0, 50.0, (ro + rd * tHit).y)));
        fog = fog * fog * (3.0 - 2.0 * fog);
        col = mix(col, hazeCol, fog);
    }

    // a little lift around the sun on the beat
    col += sunCol * pow(sd, 30.0) * 0.5 * u.bassImpact;
    // a thin horizontal lens streak through the sun, teal at its tails
    float sz = dot(sunDir, fw);
    if (sz > 0.2) {
        vec2 sp = vec2(dot(sunDir, rt), dot(sunDir, cu)) * fov / sz;
        vec2 dq = p - sp;
        float streakL = exp(-abs(dq.y) * 160.0) * exp(-abs(dq.x) * 1.8);
        col += mix(sunCol, palVisual(0.2, u), saturate(abs(dq.x) * 1.5)) * streakL * (0.22 + 0.06 * u.bassImpact);
    }
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
