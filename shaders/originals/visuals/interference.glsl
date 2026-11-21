// SPDX-License-Identifier: AGPL-3.0-only
// Interference.
// Three luminous orbs hover over a black, glass-smooth liquid: bass, mid and
// treble each own one. Every orb radiates circular wavefronts shaped by its
// band's trace; the rings cross and interfere, and the surface is lit by the
// orbs themselves, so their reflections smear into coloured glitter across
// the crests while a ring light overhead traces the wave pattern in silver.
// Where crests align the liquid glows warm with a moire shimmer, and every
// beat sends only a faint shockwave out from each orb. Calm under loud music:
// the orbs and the ring light brighten with the smoothed level plus a modest
// band term, the camera circles at a slow steady cruise with no beat surges,
// and the ripples and glitter spread slowly, so bright crests never sweep
// large areas; audio drives the light and the waves, never the camera. The
// palette never shifts with the beat or the timbre, and under the vivid
// palette tour the colours change hue but keep their brightness. Reds are
// kept just off pure red.
// param0 = Ring Density ; param1 = Drift ; param2 = Heat

const float IF_ORB_H = 0.55;   // orb height above the liquid
const float IF_ORB_R = 0.17;   // orb radius

// Orb i: a fixed triangle of homes, wandering slowly by the Drift amount.
vec3 ifOrb(float fi, float drift, float t) {
    float a = fi * 2.0944 + 0.65;
    vec2 home = vec2(cos(a), sin(a)) * 1.45;
    vec2 wander = vec2(sin(t * 0.13 + fi * 2.09) + 0.4 * sin(t * 0.071 + fi * 4.1),
                       cos(t * 0.11 + fi * 1.37) + 0.4 * cos(t * 0.053 + fi * 3.3));
    vec2 xz = home + wander * 0.55 * drift;
    return vec3(xz.x, IF_ORB_H + 0.06 * sin(t * 0.37 + fi * 2.0), xz.y);
}

// The palette read without osPalVisual's per-beat and spectral-centroid hue
// nudge (common.glsl), and with its brightness evened out, so the sky and the
// orbs never shift colour with the beat or the timbre and the vivid palette
// tour's cross-fades change hue, not brightness (manifest mode has no nudge or
// tour).
vec3 ifPalStill(float t, VisualUniforms u) {
    if (u.palette.x >= 0.0) return palVisual(t, u);
    vec3 c = palVisual(t - 0.015 * u.beatPhase - 0.08 * u.spectralCentroid, u);
    return c * pow(0.3 / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 0.02), 0.75);
}

// Light from an orb seen along the ray (ro, rd) up to distance tmax: a
// white-hot core and a long coloured halo.
vec3 ifOrbLight(vec3 ro, vec3 rd, float tmax, vec3 c, vec3 tint, float e) {
    float tc = clamp(dot(c - ro, rd), 0.0, tmax);
    vec3 dv = ro + rd * tc - c;
    float d2 = dot(dv, dv);
    float r2 = IF_ORB_R * IF_ORB_R;
    float core = exp(-d2 / (r2 * 0.35));
    float halo = r2 / (d2 + r2 * 0.6);
    return (vec3(1.0, 0.95, 0.9) * core * 3.0 + tint * (core * 2.0 + halo * 0.55)) * e;
}

// The orb as the camera sees it: a glass sphere with a white-hot filament
// core, a tinted Fresnel rim, a slow inner swirl and a thin anamorphic
// streak along the camera's horizontal (rt, cu are the camera's axes).
vec3 ifOrbView(vec3 ro, vec3 rd, float tmax, vec3 c, vec3 tint, float e,
               vec3 rt, vec3 cu, float t, float fi) {
    vec3 oc = c - ro;
    float tc = dot(oc, rd);
    if (tc <= 0.0 || tc > tmax + IF_ORB_R) return vec3(0.0);
    vec3 dv = ro + rd * tc - c;
    float d2 = dot(dv, dv);
    float r2 = IF_ORB_R * IF_ORB_R;
    float halo = r2 / (d2 + r2 * 0.5);
    // sphere disc
    float x = sqrt(d2) / IF_ORB_R;
    float disc = 1.0 - smoothstep(0.92, 1.0, x);
    float mu = sqrt(max(1.0 - min(x * x, 1.0), 0.0));      // view cosine on the sphere
    float rim = pow(1.0 - mu, 3.0) * disc;
    vec2 sp = vec2(dot(dv, rt), dot(dv, cu)) / IF_ORB_R;
    float swirl = 0.5 + 0.5 * sin(atan(sp.y, sp.x) * 3.0 + x * 7.0 - t * (1.3 + 0.4 * fi));
    float inner = disc * (0.25 + 0.75 * swirl * smoothstep(0.95, 0.2, x)) * mu;
    float fil = exp(-d2 / (r2 * 0.05));
    // anamorphic streak in screen space
    float sy = dot(dv, cu) / max(tc, 0.1);
    float sx = dot(dv, rt) / max(tc, 0.1);
    float streak = exp(-sy * sy * 26000.0) * exp(-abs(sx) * 11.0);
    vec3 col = vec3(1.0, 0.96, 0.9) * fil * 4.0
             + tint * (inner * 1.6 + rim * 3.0 + halo * 0.5)
             + mix(tint, vec3(1.0), 0.35) * streak * 0.55;
    return col * e;
}

// Environment over the pool: a dark studio with a segmented ring light high
// up and a faint horizon glow.
vec3 ifSky(vec3 rd, vec3 ringCol, vec3 horCol, vec3 lowCol, float lift, float rough, VisualUniforms u) {
    float el = rd.y;
    vec3 col = mix(horCol * 0.035, vec3(0.001, 0.001, 0.003), saturate(el * 4.0));
    col += horCol * (exp(-abs(el) * 9.0) * 0.04 + exp(-abs(el) * 30.0) * 0.08);
    float az = atan(rd.z, rd.x);
    // segmented LED ring high up: crisp bars with a soft halo
    // 96 bars around; each one is a spectrum bin, mirrored, so the ring is
    // an equaliser whose reflection glitters across the ripples
    float ab = az * 15.278875;                             // 96 / 2pi
    float segs = fract(ab);
    float bar = smoothstep(0.0, 0.12, segs) * smoothstep(1.0, 0.8, segs);
    float bi = mod(floor(ab), 48.0);
    float eq = bandAt(u, abs(bi - 23.5) / 24.0);
    float haze = smoothstep(0.01, 0.05, rough);            // the fog layer sees no bars
    float seg = mix((0.6 + 0.4 * saturate(u.level) + 0.35 * eq) * bar, 0.6 + 0.3 * saturate(u.level), haze);
    float x = (el - 0.36) / (0.0045 + rough);
    col += ringCol * (exp(-x * x) * seg * 4.0 * (0.0045 / (0.0045 + rough)) + exp(-abs(el - 0.36) * 30.0) * 0.12) * (1.0 + lift);
    // a dimmer warm ring low down lights the far water
    float segs2 = fract(az * 9.5493 + 0.5);
    float bar2 = mix(smoothstep(0.0, 0.1, segs2) * smoothstep(1.0, 0.75, segs2), 0.7, haze);
    float x2 = (el - 0.12) / (0.004 + rough * 0.8);
    col += lowCol * (exp(-x2 * x2) * bar2 * 2.4 * (0.004 / (0.004 + rough * 0.8)) + exp(-abs(el - 0.12) * 40.0) * 0.08)
         * (0.6 + 0.4 * sin(az * 5.0 + 1.0)) * (0.35 + 0.4 * lift);
    // a soft upper softbox fills the crests that face away from the ring
    col += ringCol * 0.08 * smoothstep(0.55, 0.95, el);
    return col;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float t = mod(u.time, 600.0);

    float kRing = mix(1.1, 2.8, u.param0);      // rings per world unit
    float drift = mix(0.25, 1.0, u.param1);
    float heat = mix(1.6, 3.4, u.param2);

    // camera: circles the pool on the speed profile, eased bank, slow bob
    vec2 fl = osFlight(u, 0.3, -0.12);
    float ang = fl.x * 0.045 + 0.6;
    float camH = 2.45 + 0.3 * sin(t * 0.043);
    vec3 ro = vec3(cos(ang) * 4.3, camH, sin(ang) * 4.3);
    vec3 ta = vec3(cos(ang + 1.7) * 0.5, 0.05, sin(ang + 1.7) * 0.5);
    float fov = 1.75;
    float roll = osBank(u, 0.03);
    vec3 rd = osCamera(ro, ta, roll, fov, p);
    vec3 cfw = normalize(ta - ro);
    vec3 crt = normalize(cross(cfw, vec3(sin(roll), cos(roll), 0.0)));
    vec3 ccu = cross(crt, cfw);
    // the ripples spread steadily and quicken on the speed profile, so the
    // pool carries the tempo without its bright crests racing across it
    float wph = (0.08 * t + osFlight(u, 0.1, -0.04).x) * 0.5;

    vec3 ringCol = mix(vec3(0.8, 0.88, 1.0), ifPalStill(0.78, u), 0.55);
    vec3 horCol = ifPalStill(0.86, u);
    vec3 lowCol = ifPalStill(0.3, u);
    float lift = 0.3 * saturate(u.level);

    // per-orb colour, energy and position
    vec3 tints[3];
    float en[3];
    vec3 orbs[3];
    // the bass, trace and treble roles' stops (common.glsl), read still
    tints[0] = mix(ifPalStill(0.15, u), ifPalStill(0.039, u), 0.62);
    tints[1] = ifPalStill(0.44, u);
    tints[2] = ifPalStill(0.8272, u);
    float swell = sin(3.14159265 * saturate(u.beatPhase));
    swell *= swell;
    // the bass orb swells smoothly through each beat (a kick-sharp jump lights
    // its whole pool at once)
    float lv = saturate(u.level);
    en[0] = 0.55 + 0.5 * lv + 0.08 * u.bass * swell;
    en[1] = 0.5 + 0.45 * lv + 0.25 * u.mid;
    en[2] = 0.5 + 0.45 * lv + 0.25 * u.treble;
    for (int i = 0; i < 3; i++) orbs[i] = ifOrb(float(i), drift, t);
    // the triangle of orbs turns slowly about the pool, counter to the camera
    mat2 spin = rot2(-fl.x * 0.012);
    for (int i = 0; i < 3; i++) orbs[i].xz = spin * orbs[i].xz;

    vec3 col;
    float tHit = rd.y < -1e-3 ? -ro.y / rd.y : 1e6;
    if (tHit < 60.0) {
        vec3 P = ro + rd * tHit;
        // pixel footprint on the liquid, to fade rings finer than a pixel
        float fp = tHit * 2.0 / (u.resolution.y * fov) / max(-rd.y, 0.04);
        int harm = osSteps(2.0, 3.0, detail);

        vec2 grad = vec2(0.0);
        float sum = 0.0;
        float crestAll = 0.0;
        vec3 emit = vec3(0.0);
        float swR = u.beatPhase * 3.0;
        float swAmp = swell * (0.06 + 0.06 * lv);
        float swKick = exp(-u.beatPhase * 2.6) * (0.12 + 0.05 * u.bassImpact);
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            vec2 dv = P.xz - orbs[i].xz;
            float r = length(dv) + 1e-4;
            float k = kRing * (1.0 + 0.18 * fi);
            float q = r * k - wph * (1.0 + 0.2 * fi) - fi * 0.7;
            float e = en[i];
            // the band's trace as a ring profile and its derivative in q
            float a1 = 0.55 + 0.85 * min(e, 1.8) * 0.5;
            float w1 = 6.2831853 * q;
            float s = sin(w1) * a1;
            float ds = cos(w1) * a1 * 6.2831853;
            float f1 = exp(-k * k * fp * fp * 6.0);
            float a2 = 0.28 * min(e, 1.8) * 0.5;
            float f2 = exp(-k * k * fp * fp * 24.0);
            s += sin(w1 * 2.0 + fi * 2.1) * a2;
            ds += cos(w1 * 2.0 + fi * 2.1) * a2 * 12.566371 * f2;
            if (harm > 2) {
                float f3 = exp(-k * k * fp * fp * 82.0);
                float w3 = w1 * 3.7 - wph * 0.7 + fi;
                s += sin(w3) * 0.12;
                ds += cos(w3) * 0.12 * 23.247786 * f3;
            }
            ds *= f1;
            float att = 1.0 / (1.0 + r * r * 0.35);
            float dAtt = -0.7 * r * att * att;
            float amp = 0.018 * (0.6 + 0.4 * e);
            float dh = amp * (dAtt * s * f1 + att * ds * k);
            // beat shockwave: a soft ring racing outward; the kick ripples the
            // surface, the glow swells and settles with the beat
            float x = (r - swR) / 0.22;
            float sw = exp(-x * x) * swAmp * att;
            dh += -2.0 * x / 0.22 * exp(-x * x) * swKick * att * 0.03 * f1;
            grad += dh * dv / r;

            // hot zones saturate with energy, so loud passages do not make
            // large moving crests brighter
            float sa = s * min(e, 1.2) * att;
            sum += sa;
            float crest = smoothstep(0.5, 1.0, s) * att * e * f1;
            crestAll += crest;
            emit += tints[i] * (crest * 0.07 + sw * 0.15 + exp(-r * 1.6) * 0.13 * e);
        }

        // wind capillaries: three small directional wave trains that break
        // the reflections into glitter; past the pixel footprint they fade
        // and turn into roughness that stretches the reflected lights
        float mfade = 0.0;
        for (int j = 0; j < 3; j++) {
            float fj = float(j);
            float a = fj * 2.2 + 0.4;
            vec2 dj = vec2(cos(a), sin(a));
            float fq = 9.0 + 7.0 * fj;
            float fd = exp(-fq * fq * fp * fp * 0.35);
            mfade += fd / 3.0;
            grad += dj * (0.008 * fq * 0.3) * cos(dot(P.xz, dj) * fq - t * (0.6 + 0.2 * fj) + fj * 1.7) * fd;
        }
        float rough = (1.0 - mfade) * 0.007;
        vec3 N = normalize(vec3(-grad.x, 1.0, -grad.y));
        vec3 V = -rd;
        float nv = saturate(dot(N, V));
        float F = 0.06 + 0.94 * pow(1.0 - nv, 5.0);
        vec3 R = reflect(rd, N);
        R.y = abs(R.y) + 1e-3;
        R = normalize(R);

        vec3 refl = ifSky(R, ringCol, horCol, lowCol, lift, rough, u);
        vec3 sheen = vec3(0.0);
        for (int i = 0; i < 3; i++) {
            vec3 L = orbs[i] - P;
            float d2 = dot(L, L);
            L *= inversesqrt(d2);
            refl += ifOrbLight(P, R, 30.0, orbs[i], tints[i], en[i]);
            float nh = saturate(dot(N, normalize(L + V)));
            sheen += tints[i] * en[i] * (pow(nh, 90.0) * 2.5 + pow(nh, 12.0) * 0.12) / (0.4 + d2);
        }
        col = vec3(0.002, 0.003, 0.006) + refl * F + sheen * (0.3 + 0.7 * F);

        // constructive interference: hot zones where the crests align
        float cons = max(sum, 0.0);
        float hot = pow(cons * 0.6, heat);
        float shim = 0.75 + 0.25 * sin(sum * 9.0 + wph * 3.0);
        vec3 zone = ifPalStill(fract(0.18 + cons * 0.22 + 0.1 * u.spectralCentroid), u);
        emit += zone * hot * shim * 0.3 * (0.8 + 0.3 * lv);
        col += emit;

        // distance haze toward the horizon
        float fog = 1.0 - exp(-tHit * 0.055);
        col = mix(col, ifSky(vec3(rd.x, -rd.y, rd.z), ringCol, horCol, lowCol, lift, 0.06, u) * 0.8, fog);
    } else {
        col = ifSky(rd, ringCol, horCol, lowCol, lift, 0.0, u);
    }

    // spray motes hanging over the liquid, lit by whichever orb is near:
    // shells along the ray, one jittered mote per cell, rising slowly
    int nm = osSteps(3.0, 8.0, detail);
    float rise = mod(t * 0.06 + fl.x * 0.01, 60.0);
    for (int j = 0; j < 8; j++) {
        if (j >= nm) break;
        float d = 1.6 + float(j) * 0.62;
        if (d > tHit) break;
        vec3 P = ro + rd * d;
        vec3 q = P - vec3(0.0, rise, 0.0);
        vec3 cell = floor(q / 0.55);
        float h1 = hash21(cell.xz + cell.y * vec2(17.31, 41.7));
        float h2 = hash21(cell.zx * 1.37 + cell.y * vec2(5.3, 11.9) + 3.1);
        float h3 = hash21(cell.xz * 0.71 + cell.y * vec2(29.1, 7.7) + 8.4);
        vec3 mp = (cell + 0.2 + 0.6 * vec3(h1, h2, h3)) * 0.55 + vec3(0.0, rise, 0.0);
        if (mp.y < 0.03 || mp.y > 1.5 || h1 > 0.55) continue;
        float tc = dot(mp - ro, rd);
        vec3 dv = ro + rd * tc - mp;
        float rr = 0.006 + 0.0025 * tc;
        float g = exp(-dot(dv, dv) / (rr * rr));
        vec3 lit = vec3(0.0);
        for (int i = 0; i < 3; i++) {
            vec3 L = orbs[i] - mp;
            lit += tints[i] * en[i] / (0.08 + dot(L, L) * 1.6);
        }
        float tw = 0.75 + 0.25 * sin(t * 0.9 + h2 * 40.0);
        col += lit * g * tw * 0.7 * (1.0 - smoothstep(4.0, 7.0, tc));
    }

    // the orbs themselves
    for (int i = 0; i < 3; i++) {
        col += ifOrbView(ro, rd, tHit, orbs[i], tints[i], en[i], crt, ccu, t, float(i));
    }
    // keep reds just off pure red: the bass pool's moving crests would
    // otherwise flicker in and out of saturated red
    col = max(col, vec3(0.0, 0.3, 0.15) * col.r);
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
