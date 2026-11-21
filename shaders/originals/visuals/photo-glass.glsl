// SPDX-License-Identifier: AGPL-3.0-only
// Photo Glass.
// A field of solid glass towers stands on a black mirror floor in front of
// the photo, shown as a giant backlit screen. Every tower is a real lens: the
// photo seen through it is flipped, magnified and split into prismatic
// fringes, while studio softboxes streak bright highlights down the glass.
// The towers breathe slowly with the music's smoothed level and a trace of
// their own band, like a calm equalizer skyline, and their rims glow softly
// in the palette; there are no kick lifts or beat flashes, so the refracted
// photo never jumps inside the flash budget. The camera orbits very slowly and
// level, with no audio surge; audio only shades the towers' height and light.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 = Towers ; param1 = Height ; param2 = Reflection

// The palette read: the visual's own palette with no beat or spectral nudge.
// The vivid tour swaps whole palettes of very different brightness every few
// seconds, which swells the light across the frame, so this visual keeps its
// own colours there (as the calm visuals do); a host's manifest palette still
// replaces them. The fog and peak roles read the same steady palette.
vec3 pglPalSteady(float t, VisualUniforms u) { return osPalCalm(t, 31, u); }
vec3 pglPalSteadyFog(float t, VisualUniforms u) {
    vec3 c = pglPalSteady(t, u);
    return mix(vec3(luma(c) * 0.62), c, 0.42);
}

const float PG2_WALL = 3.8;    // the photo screen's depth
const float PG2_WH = 6.0;      // half height of the photo screen
const float PG2_Z0 = -2.0;     // tower field depth range
const float PG2_Z1 = 3.0;
const float PG2_IOR = 1.22;  // a gentle lens, so the photo stays readable through the glass

// The palette read once at five fixed stops and blended locally; the fixed
// fog reads and the photo's complementary accent ride along.
struct PglPal { vec3 a; vec3 b; vec3 c; vec3 d; vec3 e; vec3 fogTop; vec3 fogLow; vec3 accent; };

vec3 pglPal(PglPal P, float t) {
    float x = fract(t) * 5.0;
    vec3 c = mix(P.a, P.b, smoothstep(0.5, 1.5, x));
    c = mix(c, P.c, smoothstep(1.5, 2.5, x));
    c = mix(c, P.d, smoothstep(2.5, 3.5, x));
    c = mix(c, P.e, smoothstep(3.5, 4.5, x));
    return mix(c, P.a, smoothstep(4.5, 5.0, x));
}

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float PGL_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 pglFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * PGL_RUN[32] + PGL_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

// Tower in cell c: xz centre, radius, height (radius 0 = empty cell).
vec4 pglTower(vec2 c, VisualUniforms u, float density, float hAmt) {
    if (c.y < PG2_Z0 || c.y >= PG2_Z1 || abs(c.x + 0.5) > 6.5) return vec4(0.0);
    float h1 = hash21(c + 0.37);
    vec2 j = hash22(c * 1.7 + 4.1) - 0.5;
    // keep a clear aisle down the middle so the photo reads directly too
    float aisle = smoothstep(0.6, 1.6, abs(c.x + 0.5));
    if (h1 > mix(0.25, 0.9, density) * mix(0.35, 1.0, aisle)) return vec4(0.0);
    vec2 ctr = c + 0.5 + j * 0.18;
    float rad = 0.17 + 0.15 * hash21(c + 9.1);
    float b = bandAt(u, saturate((ctr.x + 6.0) / 12.0));
    float row = (c.y - PG2_Z0) / (PG2_Z1 - PG2_Z0);
    float h = (2.6 + 1.3 * h1 + 0.25 * u.level + 0.06 * b) * hAmt * (0.55 + 0.8 * row);
    return vec4(ctr, rad, max(h, 0.12));
}

// Ray against a vertical cylinder from outside: t and the outward normal.
float pglCylIn(vec3 o, vec3 d, vec4 tw, out vec3 n) {
    n = vec3(0.0, 1.0, 0.0);
    vec2 oc = o.xz - tw.xy;
    float a = max(dot(d.xz, d.xz), 1e-6);
    float b = dot(oc, d.xz);
    float c = dot(oc, oc) - tw.z * tw.z;
    float disc = b * b - a * c;
    float best = -1.0;
    if (disc > 0.0) {
        float t = (-b - sqrt(disc)) / a;
        float y = o.y + d.y * t;
        if (t > 1e-3 && y > 0.0 && y < tw.w) {
            best = t;
            n = vec3((oc + d.xz * t) / tw.z, 0.0).xzy;
        }
    }
    if (d.y < -1e-4) {
        float t = (tw.w - o.y) / d.y;
        vec2 q = oc + d.xz * t;
        if (t > 1e-3 && dot(q, q) < tw.z * tw.z && (best < 0.0 || t < best)) {
            best = t; n = vec3(0.0, 1.0, 0.0);
        }
    }
    return best;
}

// Exit from inside the same cylinder: t and the outward normal there.
float pglCylOut(vec3 o, vec3 d, vec4 tw, out vec3 n) {
    vec2 oc = o.xz - tw.xy;
    float a = max(dot(d.xz, d.xz), 1e-6);
    float b = dot(oc, d.xz);
    float c = dot(oc, oc) - tw.z * tw.z;
    float t = (-b + sqrt(max(b * b - a * c, 0.0))) / a;
    n = vec3((oc + d.xz * t) / tw.z, 0.0).xzy;
    if (d.y > 1e-4) {
        float tc = (tw.w - o.y) / d.y;
        if (tc < t) { t = tc; n = vec3(0.0, 1.0, 0.0); }
    }
    if (d.y < -1e-4) {
        float tb = -o.y / d.y;
        if (tb < t) { t = tb; n = vec3(0.0, -1.0, 0.0); }
    }
    return max(t, 0.0);
}

// Studio surround seen in reflections: two tall softboxes, a top panel.
vec3 pglEnv(vec3 d, PglPal P) {
    float az = atan2_(d.x, -d.z);
    float strip = exp(-pow((az - 0.95) * 7.0, 2.0)) + 0.7 * exp(-pow((az + 1.25) * 6.0, 2.0));
    strip *= smoothstep(-0.15, 0.1, d.y) * smoothstep(0.9, 0.4, d.y);
    float top = smoothstep(0.75, 0.95, d.y);
    vec3 col = vec3(1.0, 0.97, 0.92) * strip * 2.6 + P.fogTop * top * 0.7;
    return col + P.d * 0.012;
}

vec3 pglScreen(vec2 q, vec2 disp, VisualUniforms u, float ia, int taps) {
    // q: screen position in units of its half height, x across, y up from the floor
    // the screen is at least 3:2; a narrower photo is cover-cropped to fill it
    float sa = max(ia, 1.5);
    vec2 iuv = vec2(0.5 + 0.5 * q.x / sa, 1.0 - 0.5 * q.y);
    // past its edges the picture carries on mirrored and falls away into the
    // dark, so a wide orbit never finds a hard border
    vec2 e = abs(iuv - 0.5) * 2.0;
    iuv = 1.0 - abs(mod(iuv, 2.0) - 1.0);
    iuv.y = 0.5 + (iuv.y - 0.5) * (ia / sa);
    vec3 c;
    if (taps > 1) {
        c.r = IMG(clamp(iuv + disp, vec2(0.001), vec2(0.999))).r;
        c.g = IMG(clamp(iuv, vec2(0.001), vec2(0.999))).g;
        c.b = IMG(clamp(iuv - disp, vec2(0.001), vec2(0.999))).b;
    } else {
        c = IMG(clamp(iuv, vec2(0.001), vec2(0.999))).rgb;
    }
    c = max(c, vec3(0.0));
    c = c * c * (0.7 + 0.6 * c);   // stored values to linear light, with a touch more contrast
    // a soft shoulder keeps a bright sky from flattening into white glare
    c = c / (1.0 + 0.35 * c);
    float out_ = max(max(e.x, e.y) - 1.0, 0.0);
    float fall = 1.0 - smoothstep(0.0, 0.45, out_);
    // the screen dims toward its foot so the glass stands against deep shadow
    float foot = 0.45 + 0.55 * smoothstep(0.85, 1.45, q.y);
    return c * 1.1 * fall * fall * foot;
}

// Caustics on the floor: each tower focuses the screen light into a bright
// line that pinches at its focal distance in front of it (toward -z).
vec3 pglCaustic(vec2 fp, VisualUniforms u, float density, float hAmt, int nx, vec3 light) {
    vec3 acc = vec3(0.0);
    vec2 c0 = floor(fp);
    float side = fract(fp.x) < 0.5 ? -1.0 : 1.0;
    float f = PG2_IOR / (2.0 * (PG2_IOR - 1.0));   // focal distance in radii
    for (int i = 0; i < 2; i++) {
        if (i >= nx) break;
        for (int k = 0; k < 3; k++) {
            vec2 cell = c0 + vec2(float(i) * side, float(k));
            vec4 tw = pglTower(cell, u, density, hAmt);
            if (tw.z <= 0.0) continue;
            float along = tw.y - fp.y;
            float across = fp.x - tw.x;
            if (along < tw.z) continue;
            float wdt = tw.z * abs(1.0 - along / (f * tw.z)) + 0.015;
            float fade = smoothstep(tw.z, tw.z * 1.6, along) * smoothstep(2.4, 0.9, along)
                       * smoothstep(0.45, 0.2, wdt) * min(tw.w, 2.0);
            float gain = min(tw.z / wdt, 5.0) * fade;
            // the glass splits the line into a fringe of colour at its edges
            vec3 line = vec3(exp(-pow((across - 0.25 * wdt) / wdt, 2.0)),
                             exp(-pow(across / wdt, 2.0)),
                             exp(-pow((across + 0.25 * wdt) / wdt, 2.0)));
            acc += line * gain;
        }
    }
    return acc * light;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    p.y = -p.y;
    float detail = osDetail(u);
    float t = mod(u.time, 600.0);
    float density = u.param0;
    float hAmt = mix(0.45, 1.15, u.param1);
    float reflAmt = mix(0.25, 1.0, u.param2);
    vec2 isz = max(IMGSIZE, vec2(1.0));
    float ia = clamp(isz.x / isz.y, 0.5, 2.4);

    // camera: a slow orbit across the field on the shared speed profile
    vec2 fl = pglFlight(u, 0.3, -0.1);
    float burst = smoothstep(1.6, 4.0, fl.y);
    float ang = 0.27 * sin(fl.x * 0.03) + 0.05 * sin(t * 0.05);
    vec3 ctr = vec3(0.0, 0.55, 1.0);
    float rad = 5.5 + 0.8 * sin(fl.x * 0.017 + 1.0);
    vec3 ro = ctr + vec3(sin(ang) * rad, 0.15 + 0.2 * sin(fl.x * 0.021 + 0.5), -cos(ang) * rad);
    vec3 ta = vec3(0.2 * sin(ang), 1.75, 1.6);
    vec3 rd = osCamera(ro, ta, 0.0, 1.75, p);
    vec3 rd0 = rd;

    int segs = detail > 0.5 ? 4 : 3;
    int steps = osSteps(12.0, 18.0, detail);
    int taps = detail > 0.25 ? 3 : 1;
    vec3 col = vec3(0.0);
    vec3 thr = vec3(1.0);
    vec3 o = ro;
    vec3 d = rd;
    vec2 bend = vec2(0.0);
    float glassPath = 0.0;
    bool live = true;
    // the photo's key colour from nine fixed taps, weighted toward saturated
    // pixels; the accent is its complement, kept saturated
    vec3 kAcc = vec3(0.0);
    float kW = 0.0;
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        vec2 tuv = vec2(0.18 + 0.32 * mod(fi, 3.0), 0.18 + 0.32 * floor(fi / 3.0));
        vec3 c = max(IMG(tuv).rgb, vec3(0.0));
        float w = 0.04 + max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
        kAcc += c * w;
        kW += w;
    }
    vec3 keyC = kAcc / max(kW, 1e-4);
    float kHi = max(keyC.r, max(keyC.g, keyC.b));
    float kLo = min(keyC.r, min(keyC.g, keyC.b));
    float kSat = (kHi - kLo) / max(kHi, 1e-3);
    vec3 keyHue = (keyC - kLo) / max(kHi - kLo, 1e-3);
    PglPal P = PglPal(pglPalSteady(0.1, u), pglPalSteady(0.3, u), pglPalSteady(0.5, u), pglPalSteady(0.7, u), pglPalSteady(0.9, u),
                      pglPalSteadyFog(0.5, u), pglPalSteadyFog(0.62, u), vec3(0.0));
    P.accent = mix(P.c, (vec3(1.0) - keyHue) * 1.3, smoothstep(0.08, 0.3, kSat));
    vec3 cl0 = max(IMG(vec2(0.5, 0.45)).rgb, vec3(0.0));
    vec3 causticLight = cl0 * cl0 + P.accent * 0.18;
    for (int sgi = 0; sgi < 4; sgi++) {
        if (sgi >= segs) break;
        // distance to the floor and the screen
        float tF = d.y < -1e-4 ? -o.y / d.y : 1e4;
        float tW = d.z > 1e-4 ? (PG2_WALL - o.z) / d.z : 1e4;
        float tEnd = min(tF, tW);
        // walk the tower grid cell by cell (DDA in xz)
        float tStart = 0.0;
        if (o.z < PG2_Z0 && d.z > 1e-4) tStart = (PG2_Z0 - o.z) / d.z;
        vec3 os = o + d * tStart;
        vec2 dz = vec2(abs(d.x) < 1e-4 ? 1e-4 : d.x, abs(d.z) < 1e-4 ? 1e-4 : d.z);
        vec2 cell = floor(os.xz);
        vec2 st = sign(dz);
        vec2 tDel = abs(1.0 / dz);
        vec2 tMax = (cell + max(st, 0.0) - os.xz) / dz + tStart;
        float tHit = -1.0;
        vec3 nHit = vec3(0.0);
        vec4 twHit = vec4(0.0);
        for (int k = 0; k < 22; k++) {
            if (k >= steps) break;
            float tc = tStart;
            if (tc > tEnd) break;
            vec4 tw = pglTower(cell, u, density, hAmt);
            if (tw.z > 0.0) {
                vec3 n;
                float th = pglCylIn(o, d, tw, n);
                if (th > 0.0 && th < tEnd) { tHit = th; nHit = n; twHit = tw; break; }
            }
            if (tMax.x < tMax.y) { tStart = tMax.x; tMax.x += tDel.x; cell.x += st.x; }
            else { tStart = tMax.y; tMax.y += tDel.y; cell.y += st.y; }
        }

        if (tHit > 0.0) {
            vec3 hp = o + d * tHit;
            float ndv = saturate(-dot(d, nHit));
            float fres = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
            col += thr * fres * pglEnv(reflect(d, nHit), P);
            // rim light on the tower's top edge, one spectrum band each
            float b = bandAt(u, saturate((twHit.x + 6.0) / 12.0));
            float rim = nHit.y > 0.5
                ? smoothstep(0.80, 0.97, length(hp.xz - twHit.xy) / twHit.z)
                : smoothstep(twHit.w - 0.06, twHit.w, hp.y);
            float hk = hash21(twHit.xy + 3.3);
            vec3 hue = pglPal(P, 0.45 + 0.5 * fract((twHit.x + 6.0) / 12.0 + 0.37 * hk));
            // rims alternate between the palette and the photo's complementary accent
            vec3 rimC = hk > 0.6 ? P.accent : peakWhite(hue, 0.15);
            col += thr * rimC * rim * (1.5 + 0.25 * u.level + 0.08 * b);
            if (nHit.y < 0.5) {
                // etched rings up the glass, antialiased to the pixel footprint:
                // they glow toward the top with the band, and a lit ring climbs
                // each tower through the beat
                float px = tHit * 2.4 / (max(u.resolution.y, 1.0) * 1.75);
                float gy = hp.y / 0.2;
                float gd = abs(fract(gy) - 0.5) * 0.2;
                float ring = (1.0 - smoothstep(0.0, 0.006 + px, gd)) * step(0.1, hp.y) * step(hp.y, twHit.w - 0.08);
                float nearTop = exp(-(twHit.w - hp.y) * 2.8);
                float cph = fract(u.beatPhase + hk);
                float climb = cph * twHit.w;
                // it fades in at the foot and out at the top, so the wrap never pops
                float pulse = exp(-pow((hp.y - climb) * 5.0, 2.0)) * sin(3.14159 * cph) * 0.05;
                // rings fade out before they crowd below a few pixels apart
                ring *= 1.0 - smoothstep(0.02, 0.045, px);
                vec3 ringC = mix(hue, rimC, 0.25) * 1.2;
                col += thr * ringC * ring * (0.015 + (0.6 + 0.2 * u.level) * nearTop + pulse) * (0.4 + 0.6 * ndv);
            }
            // into the glass and out the far side
            vec3 d1 = refract(d, nHit, 1.0 / PG2_IOR);
            if (dot(d1, d1) < 0.5) d1 = reflect(d, nHit);
            vec3 nOut;
            float tx = pglCylOut(hp, d1, twHit, nOut);
            vec3 xp = hp + d1 * tx;
            if (nOut.y < -0.5) {
                // the base is a lit mirror: bounce once and pick up its glow
                col += thr * (1.0 - fres) * pglPal(P, twHit.x * 0.07 + 0.3)
                     * (1.0 + 0.1 * u.level);
                d1.y = -d1.y;
                float tx2 = pglCylOut(xp + d1 * 1e-3, d1, twHit, nOut);
                if (nOut.y < -0.5) nOut = vec3(0.0, 1.0, 0.0);
                tx += tx2;
                xp = xp + d1 * tx2;
            }
            vec3 d2 = refract(d1, -nOut, PG2_IOR);
            if (dot(d2, d2) < 0.5) d2 = reflect(d1, -nOut);
            glassPath += tx;
            // light trapped in the glass: each tower glows in its own hue with its band
            float lowGlow = 1.0 - 0.6 * saturate(0.5 * (hp.y + xp.y) / twHit.w);
            col += thr * (1.0 - fres) * hue * tx * lowGlow * (0.75 + 0.1 * u.level);
            // dense glass: it absorbs toward its own colour, so thick towers read deep and jewel-like
            vec3 tint = mix(vec3(1.0), hue, 0.1 + 0.14 * hk);
            thr *= (1.0 - fres) * tint * exp(-tx * 0.12);
            bend += d2.xy - d.xy;
            o = xp + d2 * 1e-3;
            d = d2;
        } else if (tF < tW) {
            // black mirror floor
            vec3 fp = o + d * tF;
            vec2 rip = vec2(vnoise(fp.xz * 3.0 + vec2(t * 0.15, 0.0)), vnoise(fp.zx * 3.0 - vec2(0.0, t * 0.12))) - 0.5;
            float fres = 0.05 + 0.95 * pow(1.0 - saturate(-d.y), 5.0);
            col += thr * P.fogLow * 0.006;
            if (abs(fp.x) < 7.5 && fp.z > PG2_Z0 - 3.0 && fp.z < PG2_Z1) {
                col += thr * pglCaustic(fp.xz, u, density, hAmt, detail > 0.5 ? 2 : 1, causticLight) * 0.35;
            }
            thr *= reflAmt * (0.1 + 0.7 * fres);
            d = normalize(reflect(d, vec3(0.0, 1.0, 0.0)) + vec3(rip.x, 0.0, rip.y) * 0.008);
            o = fp + d * 1e-3;
        } else {
            if (tW < 1e3) {
                vec3 wp = o + d * tW;
                vec2 q = vec2(wp.x / PG2_WH, (wp.y + 1.2) / PG2_WH);
                vec2 disp = bend * 0.2 + bend * glassPath * 0.015;
                vec3 scr = pglScreen(q, disp, u, ia, taps);
                col += thr * scr * (0.95 + 0.05 * u.level);
            } else {
                col += thr * pglEnv(d, P) * 0.15;
            }
            live = false;
            break;
        }
    }

    if (live && d.z > 1e-3) {
        // out of bounces: finish the path on the screen, ignoring what is left in the way
        vec3 wp = o + d * ((PG2_WALL - o.z) / d.z);
        col += thr * pglScreen(vec2(wp.x / PG2_WH, (wp.y + 1.2) / PG2_WH), bend * 0.12, u, ia, 1);
    }

    // haze in front of the screen and a glow at its foot
    col += P.fogLow * 0.03 * exp(-abs(p.y + 0.35) * 3.0);
    col *= 0.45 + 0.55 * smoothstep(1.95, 0.55, length(p * vec2(0.8, 1.0)));
    return col;   // linear HDR; the host tonemaps
}
