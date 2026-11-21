// SPDX-License-Identifier: AGPL-3.0-only
// Starfield.
// A jump through hyperspace. Stars sit at random depths around the flight
// axis in several shells and are drawn as motion-blurred streaks whose length
// is a fixed stretch of depth, so near stars draw long warp lines and far
// ones short dashes; the speed changes how fast they rush past, not how long
// they are, so the lit area stays steady. Heads fade in over a few frames of
// flight and the cores are thin, so racing stars never flash. Behind them a
// tunnel of ionised gas streams past, lit from a bright exit point ahead. The
// speed follows the shared 32-beat profile at a calm cruise with no surge, and
// the roll eases to a new side every eight beats. Audio drives the light
// only: the spectrum sets each star's brightness by angle, the beat sends a
// light wave out along the tunnel, bass warms the gas and treble makes the
// star heads sparkle. The palette is held at one mean luma, so the palette
// tour recolours the tunnel without pumping its brightness.
// param0 = Warp Speed ; param1 = Density ; param2 = Streak Length

const float ST_TAU = 6.28318530718;
const float ST_DEPTH = 30.0;   // depth period of the star shells
const float ST_WRAP = 600.0;   // travel wraps here; every period divides it

// Value noise periodic in x with period px and in y with period py.
float stNoise(vec2 p, float px, float py) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 w = f * f * (3.0 - 2.0 * f);
    vec2 i0 = vec2(mod(i.x, px), mod(i.y, py));
    vec2 i1 = vec2(mod(i.x + 1.0, px), mod(i.y + 1.0, py));
    float a = hash21(i0);
    float b = hash21(vec2(i1.x, i0.y));
    float c = hash21(vec2(i0.x, i1.y));
    float d = hash21(i1);
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// One star of shell `layer` in angular cell `cell` (of n). Returns the light
// it adds at the screen point q.
vec3 stStar(vec2 q, float cell, float n, float layer, float travel, float len,
            float density, float px, float lvl, float shut, vec3 gold, VisualUniforms u) {
    float c = mod(cell, n);
    vec2 sd = vec2(c, layer * 17.0 + 3.0);
    float present = step(hash21(sd + 0.37), density);
    float ang = (c + 0.15 + 0.7 * hash21(sd + 1.7)) / n * ST_TAU + layer * 0.61;
    float R = mix(0.35, 3.2, hash21(sd + 5.3));
    // depth wraps three units behind the camera: a star that passes us keeps
    // its trail, which slides off the screen and fades instead of vanishing
    float zr = ST_DEPTH * fract(hash21(sd + 9.1) - travel / ST_DEPTH) - 3.0;
    float z = max(zr, 0.02);
    vec2 dir = vec2(cos(ang), sin(ang));
    // head at the star's depth, tail where it was a shutter's flight ago
    float rh = R / z;
    float lenE = max(len, shut);
    float rt = R / max(zr + lenE, 0.02);
    // where the head was a shutter ago: the last frames' flight is a box
    // shutter, so the head end of the streak ramps out across it instead of
    // ending in a dot that leaps between frames when a near star races by
    float rb = R / max(zr + shut, 0.02);
    float s = dot(q, dir);
    float sc = clamp(s, rt, rh);
    float d = length(q - dir * sc);
    // brightness follows depth along the trail: 1 at the head, 0 at the tail
    float zq = R / max(sc, 1e-4);
    float al = saturate((zr + lenE - zq) / lenE);
    float w = clamp(0.006 / z, px * 0.8, 0.008);
    float blur = rh - rb;
    // box shutter: the head end ramps over the last frames' flight
    float tip = saturate((zq - zr) / max(shut, 1e-3));
    // a dot smeared over a long blur spreads its light thinner
    float spread = w * 8.0 / (w * 8.0 + blur);
    // thin hot core plus a soft halo, both fading toward the tail; the core
    // falls off steeply so a fast star lights a thin line, not a wide band
    float core = w * w / (d * d + w * w);
    core *= core;
    float halo = exp(-d * 40.0);
    float fadeIn = smoothstep(ST_DEPTH - 3.0, ST_DEPTH * 0.5, z) * smoothstep(-3.0, 0.0, zr);
    // only this cell and its nearer neighbour are drawn, so the glow must end
    // within about half a cell of the star
    float reach = 0.6 * ST_TAU / n * sc;
    fadeIn *= 1.0 - smoothstep(0.35 * reach, reach, d);
    float tw = 1.0 + 0.05 * u.level * step
(0.8, hash21(sd + 2.9));
    float e = present * fadeIn * lvl * (al * al) * mix(1.0, tip, 0.85) * (core * 1.1 * tw + halo * 0.05)
            * min(1.0 + 0.8 / z, 1.8) * mix(0.55, 1.0, spread);

    // the head runs white-hot; the tail shifts down the palette like dispersion
    float hue = hash21(sd + 4.4);
    vec3 head = palVisual(hue < 0.6 ? 0.8 + 0.06 * hue : 0.52 + 0.1 * hue, u);
    vec3 tail = palVisual(hue < 0.6 ? 0.42 + 0.1 * hue : 0.7, u);
    // one star in seven burns gold: the warm complement of the cold field
    float warm = step(0.86, hash21(sd + 6.6));
    vec3 amber = gold * vec3(1.0, 0.72, 0.5);
    head = mix(head, amber * 1.7, warm);
    tail = mix(tail, amber * 0.75, warm);
    vec3 c3 = mix(tail, head, smoothstep(0.0, 0.8, al));
    return peakWhite(c3, (0.6 - 0.25 * warm) * smoothstep(0.85, 1.0, al) * spread) * e;
}

// One gain for the whole palette that holds its mean luma fixed, so the
// palette tour's crossfades change the colours but never brighten or darken
// the whole frame.
float sfGain(VisualUniforms u) {
    float l = 0.25 * (luma(palVisual(0.125, u)) + luma(palVisual(0.375, u))
                    + luma(palVisual(0.625, u)) + luma(palVisual(0.875, u)));
    return clamp(0.32 / max(l, 1e-3), 0.4, 3.0);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float px = 2.0 / max(u.resolution.y, 1.0);

    // a steady cruise with no surge: fast bright streaks sweeping the frame
    // in a burst would flash large areas
    float cruise = mix(1.2, 4.4, u.param0);
    float travel = mod(mod(u.time, 6000.0) * cruise * 0.32, ST_WRAP);
    float rush = 0.0;
    float lull = 0.0;

    // the exit point drifts slowly, as if the ship were steering
    vec2 vp = vec2(0.16 * sin(u.time * 0.11), 0.09 * sin(u.time * 0.083 + 1.3));
    vec2 q = rot2(osBank(u, 0.3)) * (p - vp);
    // wider lens in a burst, a touch narrower when drifting
    q *= 1.0 + 0.35 * rush - 0.08 * lull;
    float r = max(length(q), 1e-4);
    float a = atan2_(q.y, q.x);

    // ---- gas tunnel: a cylinder of streaming filaments ----
    float zg = 1.0 / r;                       // depth on a unit cylinder
    float gx = (a / ST_TAU + 0.5) * 72.0;     // 72 cells round, periodic
    float stretch = 1.0 + 1.2 * rush;          // filaments lengthen with speed
    float gy = zg * 1.6 / stretch + travel * 0.05; // period 30 in gy = 600 in travel
    float g = stNoise(vec2(gx, gy), 72.0, 30.0);
    g = g * 0.65 + 0.35 * stNoise(vec2(gx * 2.0 + 7.0, gy * 2.0), 144.0, 60.0) * detail
          + 0.35 * 0.5 * (1.0 - detail);
    float strand = stNoise(vec2(gx * 0.25, gy * 0.5 + 3.0), 18.0, 15.0);
    g = smoothstep(0.42, 1.0, g) * (0.3 + 1.2 * strand * strand);
    float gasFog = exp(-zg * 0.3);             // far gas fades into the glow
    float near = smoothstep(0.0, 0.5, zg);      // and very near gas thins out
    float lvlA = bandAtWrapped(u, a / ST_TAU + 0.5);
    // beat light wave: a bright band racing out from the exit toward us
    float waveZ = mix(18.0, 0.6, sqrt(saturate(u.beatPhase)));
    float wave = exp(-abs(zg - waveZ) * 1.2) * (1.0 - saturate(u.beatPhase)) * 0.1;
    vec3 gasA = palVisual(0.2 + 0.1 * g, u);
    // the gas runs blue in a drift and heats toward magenta in a burst
    vec3 gasB = palVisual(0.74 + 0.06 * lvlA - 0.2 * smoothstep(0.2, 0.9, rush), u);
    vec3 gas = mix(gasA, gasB, smoothstep(0.3, 0.9, strand));
    float lvlS = mix(saturate(u.level), lvlA, 0.25);
    vec3 col = 0.45 * gas * g * gasFog * near * (0.7 + 0.15 * u.level + 0.1 * lvlS + 0.4 * wave);
    // deep-space floor so the frame never goes flat black
    col += palVisual(0.12, u) * 0.03 * (0.5 + 0.5 * smoothstep(0.2, 1.4, r));

    // ---- star shells ----
    float density = mix(0.35, 0.9, u.param1);
    float len = mix(0.46, 1.61, u.param2);
    float lvl = 0.75 + 0.3 * lvlS;
    // distance flown in four frames, for the shutter (about two beats a
    // second): the head fades in over it, so a racing star never pops
    float perSec = 4.0 * cruise * 0.32;

    float shut = min(perSec * clamp(u.dt, 0.0, 1.0 / 30.0), 1.5);
    // warm complement of the field's blue: hue turned half way round
    vec3 bl = palVisual(0.8, u);
    vec3 gold = vec3(max(bl.r, max(bl.g, bl.b)) + min(bl.r, min(bl.g, bl.b))) - bl;
    int shells = osSteps(3.0, 7.0, detail);
    for (int l = 0; l < 7; l++) {
        if (l >= shells) break;
        float fl0 = float(l);
        float n = 36.0 + 11.0 * fl0;
        float x = (a - fl0 * 0.61) / ST_TAU * n;
        x = x - n * floor(x / n);              // wrap into [0, n)
        float cell = floor(x);
        float side = fract(x) < 0.5 ? -1.0 : 1.0;
        col += stStar(q, cell, n, fl0, travel, len, density, px, lvl, shut, gold, u);
        col += stStar(q, cell + side, n, fl0, travel, len, density, px, lvl, shut, gold, u);
    }

    // ---- exit light: hot core, wide bloom and an anamorphic flare ----
    vec3 core = peakWhite(palVisual(0.78, u), 0.6);
    float glow = exp(-r * 12.0) * 1.2 + exp(-r * 3.5) * 0.12;
    vec2 fq = p - vp;
    float flare = exp(-abs(fq.y) * 90.0) * exp(-abs(fq.x) * 1.6) * 0.6;
    float boost = 0.8 + 0.1 * u.level;

    col += (core * glow + palVisual(0.8, u) * flare) * boost;

    // gentle vignette keeps the eye on the exit
    col *= 1.0 - 0.35 * smoothstep(0.8, 2.0, length(p));
    col *= sfGain(u);
    return col; // LINEAR HDR — post chain tonemaps
}
