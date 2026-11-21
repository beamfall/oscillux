// SPDX-License-Identifier: AGPL-3.0-only
// Wave tunnel.
// A flight through open space along a winding corridor of light, where every
// ring of the corridor is a slice of the waveform history: the ring's radius
// wiggles with the trace, so the tunnel is the sound extruded in depth. No
// walls: the rings float in a violet and blue nebula cut by dark dust lanes,
// each ring shifts hue around its circumference, an echo trace in a contrasting
// hue rides just inside it with a faint lit ribbon between the two, beads of
// light ride the trace peaks and line up into streams, and sparse stars streak
// gently past. The camera
// glides slowly along the shared 32-beat speed profile (cruise, build, burst,
// brake, drift) and rolls gently into the bends, slow enough that the bright
// rings never sweep a large area within the flash budget. Audio drives only
// shape and steady light, always smoothed: the level with only a trace of
// the spectrum shapes the rings and lifts the beads, so no ring twitches, the overall level breathes
// the ring glow gently, the beat sends a faint wave down the ribbons, the
// ribbon shimmer drifts slowly, and the level barely warms the core glow; nothing
// flashes on the beat and the hue barely follows the spectral centroid.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 = Velocity ; param1 = Ring Density ; param2 = Wall Turbulence

// The palette read: the visual's own palette with no beat or spectral nudge.
// The vivid tour swaps whole palettes of very different brightness every few
// seconds, which swells the light across the frame, so this visual keeps its
// own colours there (as the calm visuals do); a host's manifest palette still
// replaces them.
vec3 wtPalSteady(float t, VisualUniforms u) { return osPalCalm(t, 23, u); }

const float WT_R = 1.7;   // base ring radius

// The palette is read once per pixel at its five stops and blended locally;
// each library read walks the whole stop table, and every ring needs several.
struct WtPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

WtPal wtPalLoad(VisualUniforms u) {
    WtPal P;
    P.c0 = wtPalSteady(0.0, u);
    P.c1 = wtPalSteady(0.26, u);
    P.c2 = wtPalSteady(0.52, u);
    P.c3 = wtPalSteady(0.78, u);
    P.c4 = wtPalSteady(0.999, u);
    return P;
}

vec3 wtPal(WtPal P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// Push a colour away from its own grey so the tonemap keeps it saturated.
vec3 wtSat(vec3 c, float k) {
    return max(mix(vec3(dot(c, vec3(0.2126, 0.7152, 0.0722))), c, k), vec3(0.0));
}

vec2 wtPath(float z) {
    return vec2(3.4 * sin(z * 0.085) + 1.0 * sin(z * 0.15 + 2.0),
                2.0 * sin(z * 0.066 + 0.9) + 0.6 * sin(z * 0.17));
}

// Waveform slice for ring id around angle t01 (periodic in t01, no seam).
// lvl is the spectrum read at this angle; one read per ring keeps it cheap.
float wtSlice(float t01, float id, float lvl, VisualUniforms u) {
    float seed = hash11(id * 3.71);
    float w = (lvl - 0.45) * 0.03;
    w += sin(t01 * 6.2831853 * 3.0 + id * 1.7) * 0.17;
    w += sin(t01 * 6.2831853 * 7.0 - id * 2.3 + seed * 6.0) * 0.14;
    w += sin(t01 * 6.2831853 * 13.0 + id * 5.1) * 0.006 * saturate(u.level);
    return w;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float tt = mod(u.time, 600.0);
    WtPal P = wtPalLoad(u);

    float cruise = mix(0.6, 2.2, u.param0);
    vec2 fl = osFlight(u, 0.1 * cruise, -0.04 * cruise);
    float speed = fl.y;
    float rush = saturate((speed - 1.0) / 3.0);
    float lull = saturate(1.0 - speed);
    float sp = mix(1.6, 0.7, u.param1);          // ring spacing
    float turb = mix(0.10, 0.42, u.param2);
    // wrap the distance on a whole number of rings
    float wrap = sp * 1000.0;
    float z = mod(fl.x, wrap);

    vec3 ro = vec3(wtPath(z), z);
    vec3 ta = vec3(wtPath(z + 7.0), z + 7.0);
    vec2 bend = wtPath(z + 12.0) - 2.0 * wtPath(z + 6.0) + wtPath(z);
    float roll = -0.35 * bend.x;
    float fov = 1.25;
    vec3 rd = osCamera(ro, ta, roll, fov, p);
    float px = 2.0 / (u.resolution.y * fov);   // ray spread per pixel

    // ---- nebula backdrop: faint, coloured, so space is never flat black ----
    vec2 sky = rd.xy / max(rd.z, 0.2) * 0.6 + wtPath(z * 0.5) * 0.05;
    float neb = fbm(sky + vec2(0.0, tt * 0.01));
    float neb2 = vnoise(sky * 1.7 - vec2(tt * 0.013, 0.0) + 7.0);
    float lane = smoothstep(0.35, 0.75, vnoise(sky * 3.1 + vec2(tt * 0.007, 4.0)));
    // builds walk the hue of the whole corridor; drops settle it back
    float hueShift = 0.008 * saturate(u.spectralCentroid);
    vec3 nebCol = mix(wtPal(P, 0.97 + hueShift), wtPal(P, 0.2 + hueShift), smoothstep(0.25, 0.75, neb2));
    nebCol = mix(nebCol, wtPal(P, 0.5 + hueShift), smoothstep(0.7, 0.95, neb) * 0.6);
    nebCol = wtSat(nebCol, 1.6);
    // deep black space with brighter gas filaments, not an even haze
    float gas = smoothstep(0.42, 0.9, neb);
    vec3 col = nebCol * (gas * gas * 0.16 + 0.03 * smoothstep(0.6, 0.9, neb2) * gas) * (1.0 - 0.9 * lane);
    // the beat sends a wave of light down the corridor, away from the camera
    float wave = 2.0 + 30.0 * saturate(u.beatPhase);
    float waveAmp = smoothstep(0.0, 0.2, saturate(u.beatPhase)) * pow(1.0 - saturate(u.beatPhase), 1.5) * (0.2 + 0.1 * saturate(u.level));

    // ---- the rings, front to back ----
    int nR = osSteps(10.0, 30.0, detail);
    float k0 = floor(z / sp) + 1.0;
    float rdz = max(rd.z, 0.05);
    float coreW = 0.022;
    for (int k = 0; k < 30; k++) {
        if (k >= nR) break;
        float id = k0 + float(k);
        float zk = id * sp;
        float tk = (zk - z) / rdz;
        vec2 q = ro.xy + rd.xy * tk - wtPath(zk);
        float rq = length(q);
        float fp = tk * px / max(rd.z, 0.3);    // pixel footprint in the ring plane
        float fog = exp(-tk * 0.07);
        float nearFade = smoothstep(0.0, 1.2, tk);   // planes fade in as they leave the lens

        // star dust outside the corridor, on the same planes: it streams
        // outward in short, steady streaks
        if (k < 14 && rq > WT_R * (1.0 + turb) + 0.4) {
            vec2 g = q * 1.4;
            vec2 c = floor(g);
            vec2 h = hash22(c + vec2(mod(id, 512.0) * 7.31, 3.0));
            vec2 dv = (g - c - 0.2 - 0.6 * h) / 1.4;
            vec2 rad = q / max(rq, 1e-3);
            float stretch = 1.0 + 0.2 * rq / (tk + 0.6);
            vec2 dl = vec2(dot(dv, rad) / stretch, dot(dv, vec2(-rad.y, rad.x)));
            float sw = max(0.009, fp);
            float tw = 0.9 + 0.1 * sin(tt * (0.5 + 0.7 * h.y) + h.x * 40.0);
            float star = exp(-dot(dl, dl) / (sw * sw)) * (0.009 / sw) * step(0.94, h.x) / sqrt(stretch);
            col += mix(vec3(1.0), wtPal(P, h.y), 0.65) * star * 3.2 * tw * fog * nearFade;
        }

        // most rings are far from this pixel: skip them cheaply
        if (abs(rq - WT_R) > WT_R * turb * 1.3 + 0.5 + 3.0 * fp) continue;

        float t01 = atan2_(q.y, q.x) / 6.2831853 + 0.5;
        float rid = mod(id, 1000.0);
        float age = fract(rid * 0.618);
        float lvl = 0.5 * saturate(u.level) + 0.06 * bandAtWrapped(u, t01 + age);
        float d = rq - WT_R * (1.0 + wtSlice(t01, rid, lvl, u) * turb);

        // wide footprints spread the energy instead of aliasing
        // and the rings closest to the lens fall out of focus
        float coc = 0.05 * saturate(3.0 - tk);
        float w = max(coreW + coc, fp);
        float core = exp(-d * d / (w * w)) * coreW / w;
        float halo = exp(-abs(d) * 9.0) * 0.24;

        // hue walks along the corridor and drifts in time: a gradient in depth
        float hue = fract(id * 0.045 + 0.12 * age + tt * 0.01
                          + 0.16 * sin(t01 * 6.2831853 + rid * 0.9));
        hue += hueShift;
        vec3 rc = accentize(wtPal(P, hue), u.accent, 0.07);
        // keep the rings saturated: push away from their own grey
        rc = wtSat(rc, 1.8);
        float pw = exp(-(tk - wave) * (tk - wave) * 0.12) * waveAmp;
        float e = (1.24 + 0.02 * saturate(u.level)) * fog * nearFade;
        // a white-hot filament inside a saturated glow, split slightly by
        // dispersion toward the edge of the view
        float ca = 0.008 * rq;
        float cR = exp(-(d + ca) * (d + ca) / (w * w)) * coreW / w;
        float cB = exp(-(d - ca) * (d - ca) / (w * w)) * coreW / w;
        vec3 hotCore = vec3(cR, core, cB) * core * 0.4;
        float glow = exp(-abs(d) * 1.6) * 0.025;
        col += (rc * (core * 0.9 + halo + glow) + hotCore) * e;

        // an echo trace rides just inside each ring, a beat behind, in a
        // contrasting hue; the gap between the two reads as a lit ribbon
        float d2 = rq - WT_R * (0.93 + wtSlice(t01 + 0.07, rid + 0.5, lvl, u) * turb * 0.8);
        float w2 = max(0.016, fp);
        float core2 = exp(-d2 * d2 / (w2 * w2)) * 0.016 / w2;
        vec3 rc2 = wtSat(wtPal(P, hue + 0.42), 1.8);
        float lo = min(d, d2), hi = max(d, d2);
        float rib = smoothstep(-fp - 0.01, fp + 0.01, -lo) * smoothstep(-fp - 0.01, fp + 0.01, hi);
        float ribF = rib * (0.2 + 0.04 * pw) * (0.94 + 0.06 * sin(t01 * 6.2831853 * 24.0 + rid * 3.0 - tt * 0.4) * (1.0 - saturate(fp * 30.0)));
        col += (rc2 * (core2 * 1.5 + exp(-abs(d2) * 7.0) * 0.06) + mix(rc, rc2, 0.5) * ribF) * e;

        // beads on the trace peaks: they line up across rings into streams
        float bc = fract(t01 * 12.0) - 0.5;
        vec2 bd = vec2(bc * 6.2831853 / 12.0 * rq, d);
        float bw = max(0.05, fp);
        float bead = exp(-dot(bd, bd) / (bw * bw)) * (0.05 / bw);
        col += peakWhite(rc, 0.35) * bead * (0.8 + 0.08 * lvl) * fog * nearFade;

            }

    // ---- a distant coal where the corridor leads, a touch brighter when loud ----
    vec3 farDir = normalize(vec3(wtPath(z + 40.0), z + 40.0) - ro);
    float fd = max(1.0 - dot(rd, farDir), 0.0);
    vec3 coal = mix(wtPal(P, 0.16 + hueShift), wtPal(P, 0.03 + 0.18 * 0.06), 0.65);
    col += coal * (exp(-fd * 300.0) * 0.8 + exp(-fd * 30.0) * 0.12) * (0.95 + 0.05 * saturate(u.level));
    // shafts of contrasting light fan out of the coal down the corridor
    vec3 fx = normalize(cross(farDir, vec3(0.0, 1.0, 0.0)));
    vec3 fy = cross(fx, farDir);
    vec2 fa = vec2(dot(rd, fx), dot(rd, fy));
    vec2 fdir = fa / max(length(fa), 1e-4);
    float shafts = vnoise(fdir * 5.0 + vec2(tt * 0.11, -tt * 0.07));
    shafts = shafts * shafts * shafts * (0.6 + 0.4 * vnoise(fdir * 13.0 - tt * 0.05));
    vec3 shaftC = wtSat(wtPal(P, 0.7 + hueShift), 1.4);
    col += shaftC * shafts * exp(-fd * 7.0) * 0.3 * (1.0 - exp(-fd * 400.0));

    return col; // LINEAR HDR
}
