// SPDX-License-Identifier: AGPL-3.0-only
// Spectrum.
// A spectrum analyser built as an endless row of thick glass columns standing
// on a black mirror floor, one column per frequency bin, low to high and back.
// Each column glows from inside in segmented analyser rows, hottest at the
// top, with bright edges and a floating peak cap that swells up over each beat
// and settles. Column heights follow the overall level with a light touch of
// each bin's own band, so kicks never sweep whole column tops at once; a soft
// wave of light runs down the row on the beat. A light behind the row shines
// through the gaps between the columns into haze, so the spectrum casts shafts
// of light toward the camera. The camera drifts slowly along the row and
// slowly swings between a raking view down the row and a face-on one. Audio
// drives the columns and their light, never the camera. Heights and glow
// barely move with the level, the back glow does not pump with the bass, and
// the palette is read without its centroid nudge or beat swing and held at one
// mean luma, so the row recolours with the palette tour but never flashes.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 = Perspective ; param1 = Column Glass ; param2 = Reflection

// The palette read: the visual's own palette (23) with no beat or spectral
// nudge and no palette tour, so the host's vivid tour never swells the light;
// a host's manifest palette still replaces it. The fog tint is rebuilt on it.
vec3 spPalSteady(float t, VisualUniforms u) { return osPalCalm(t, 23, u); }
vec3 spPalSteadyFog(float t, VisualUniforms u) {
    vec3 c = spPalSteady(t, u);
    return mix(vec3(luma(c) * 0.62), c, 0.42);
}

const float SP_W = 0.30;     // column half-width along the row (cells are 1 apart)
const float SP_D = 0.30;     // column half-depth
const float SP_SEG = 0.16;   // analyser segment pitch
const float SP_CAP = 0.045;  // peak cap half-height

// Bin shown by the column in cell c: low to high then back down, so the row
// repeats every 128 cells without a seam.
float spBin(float c) {
    float m = mod(c, 128.0);
    return m < 64.0 ? m : 127.0 - m;
}

// The palette without its per-frame centroid nudge and beat swing: the raw
// centroid jumps from hop to hop and the beat swing turns every column's hue
// in step, and on these saturated bodies both flicker the whole row.
vec3 spPal(float t, VisualUniforms u) {
    return spPalSteady(t, u);
}

// Column height and its band level for cell c.
vec2 spColumn(VisualUniforms u, float c) {
    float bin = spBin(c);
    float b = saturate(mix(u.level * (1.0 - 0.25 * bin / 63.0), band(u, int(bin)), 0.05) * (1.0 + bin * 0.014));
    return vec2(1.24 + 0.12 * pow(b, 0.8), b);




}

// Ray against an axis-aligned box: (near, far), far < near on a miss.
vec2 spBox(vec3 ro, vec3 ird, vec3 bmin, vec3 bmax, out vec3 tmn) {
    vec3 t1 = (bmin - ro) * ird;
    vec3 t2 = (bmax - ro) * ird;
    tmn = min(t1, t2);
    vec3 tmx = max(t1, t2);
    return vec2(max(max(tmn.x, tmn.y), tmn.z), min(min(tmx.x, tmx.y), tmx.z));
}

// The light behind the row and the haze around it, seen along dir. The
// colours are read once per pixel: glow, hot core, horizon haze.
vec3 spSky(vec3 dir, vec3 Ldir, vec3 cGlow, vec3 cCore, vec3 cHaze) {
    float g = saturate(dot(dir, Ldir));
    float g2 = g * g;
    float g8 = g2 * g2 * g2 * g2;
    float g64 = g8 * g8 * g8 * g8 * g8 * g8 * g8 * g8;
    float g512 = g64 * g64 * g64 * g64 * g64 * g64 * g64 * g64;
    return vec3(0.0008) + cGlow * (g2 * 0.006 + g8 * 0.06 + g64 * 0.12) + cCore * g512 * 3.0
         + cHaze * exp(-abs(dir.y - 0.02) * 9.0) * 0.03;
}

// Trace the row of columns along one ray, up to tmax. Returns the light
// gathered; T is the transmittance left over and tFirst the first hit.
vec3 spTrace(vec3 ro, vec3 rd, float tmax, int ncell, bool full, bool caps, float glass, float capLift,
             float pix, vec3 Ldir, vec3 Lk, vec3 cGlow, vec3 cCore, vec3 cHaze,
             vec2 wave, VisualUniforms u, inout float T, out float tFirst) {
    vec3 col = vec3(0.0);
    tFirst = 1e5;
    vec3 ird = 1.0 / vec3(abs(rd.x) > 1e-5 ? rd.x : 1e-5, abs(rd.y) > 1e-5 ? rd.y : 1e-5,
                          abs(rd.z) > 1e-5 ? rd.z : 1e-5);
    // the span of the ray inside the row's slab |z| < SP_D
    float tz0 = (-SP_D - ro.z) * ird.z;
    float tz1 = (SP_D - ro.z) * ird.z;
    float ta = max(min(tz0, tz1), 0.0);
    float tb = min(max(tz0, tz1), tmax);
    if (tb <= ta) return col;
    float xa = ro.x + rd.x * ta;
    float xb = ro.x + rd.x * tb;
    float s = rd.x >= 0.0 ? 1.0 : -1.0;
    float c0 = floor(xa + 0.5);
    float cEnd = floor(xb + 0.5);
    for (int i = 0; i < 18; i++) {
        if (i >= ncell) break;
        float c = c0 + s * float(i);
        if ((c - cEnd) * s > 0.5) break;
        vec2 hb = spColumn(u, c);
        float H = hb.x;
        float b = hb.y;
        float bin = spBin(c);
        float hue = bin / 63.0 * 1.9;
        vec3 cBody = accentize(spPal(hue, u), u.accent, 0.08);
        cBody = max(mix(vec3(luma(cBody)), cBody, 1.35), 0.0);
        // the hot rows at the top of a loud column turn to the complementary
        // hue, warm over cool, like the red zone of an analyser
        vec3 cHot = (vec3(max(cBody.r, max(cBody.g, cBody.b)) + min(cBody.r, min(cBody.g, cBody.b))) - cBody)
                  * vec3(1.0, 0.85, 0.7) * 1.3;
        // the beat runs down the row as a wave of light
        float wv = wave.y * exp(-abs(c - wave.x) * 0.9);

        // the floating peak cap
        float capY = H + 0.40 + capLift * (0.25 + 0.9 * b);
        vec3 tmnC;
        vec2 tc = spBox(ro, ird, vec3(c - SP_W, capY - SP_CAP, -SP_D), vec3(c + SP_W, capY + SP_CAP, SP_D), tmnC);
        // the column
        vec3 tmn;
        vec2 tt = spBox(ro, ird, vec3(c - SP_W, 0.0, -SP_D), vec3(c + SP_W, H, SP_D), tmn);
        bool hitCap = caps && tc.x < tc.y && tc.y > 0.0 && tc.x < tmax;
        bool hitCol = tt.x < tt.y && tt.y > 0.0 && tt.x < tmax;

        if (hitCap && (!hitCol || tc.x < tt.x)) {
            float tn = max(tc.x, 0.0);
            tFirst = min(tFirst, tn);
            vec3 p0 = ro + rd * tn;
            float fog = exp(-tn * 0.035);
            float capRim = exp(-max(min(SP_W - abs(p0.x - c), SP_D - abs(p0.z)), 0.0) / (0.012 + pix * tn));
            vec3 cc = mix(cHot, vec3(1.0), 0.08 + 0.08 * wv + 0.4 * capRim);
            col += T * cc * (2.1 + 0.1 * b + 0.2 * wv + 1.5 * capRim)
 * fog;
            T *= 0.15;
        }
        if (hitCol) {
            float tn = max(tt.x, 0.0);
            tFirst = min(tFirst, tn);
            vec3 p = ro + rd * tn;
            vec3 m = step(tmn.yzx, tmn) * step(tmn.zxy, tmn);
            vec3 n = -m * sign(rd);
            float hy = saturate(p.y / H);
            // distance to the nearest edge of the face that was hit
            vec3 d3 = vec3(SP_W - abs(p.x - c), min(p.y, H - p.y), SP_D - abs(p.z)) + m * 1e3;
            float ed = max(min(d3.x, min(d3.y, d3.z)), 0.0);
            float fw = pix * tn;
            float edge = exp(-ed / (0.010 + fw));
            // segmented analyser rows, fading out once they are under a pixel
            float sp = p.y / SP_SEG;
            float sf = abs(fract(sp) - 0.5);
            float lineAA = saturate(fw / SP_SEG * 3.0);
            float seg = mix(smoothstep(0.38, 0.46, sf) * (1.0 - m.y), 0.0, lineAA);
            // light inside the glass grows with the path through it
            float path = min(max(tt.y - tn, 0.0), 1.6);
            // the red zone: rows above 1.5 units glow in the hot colour
            float zone = smoothstep(1.25, 1.75, p.y);
            vec3 cRow = mix(cBody, cHot, zone);
            // the glow inside rises with height in the world, not along the
            // column, so a column that grows does not brighten all the way down
            vec3 inner = cRow * mix(0.12, 1.0, smoothstep(0.0, 1.1, p.y))

                       + mix(cRow, vec3(1.0), 0.2) * smoothstep(0.72, 1.0, hy) * 0.9;
            vec3 emis = inner * (0.15 + glass * 0.9 * path) * (1.3 + 0.08 * b + 0.1 * wv) * (1.0 - 0.75 * seg);
            float ndv = saturate(dot(n, -rd));
            float F = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
            vec3 env = full ? spSky(reflect(rd, n), Ldir, cGlow, cCore, cHaze) : vec3(0.0);
            float spec = pow(saturate(dot(reflect(rd, n), Lk)), 60.0);
            vec3 surf = emis * (1.0 - F) + F * env * 0.8 + vec3(spec * 1.2)
                      + mix(cRow, vec3(1.0), 0.35) * edge * (1.75 + 0.08 * b + 0.15 * wv);
            float fog = exp(-tn * 0.035);
            col += T * surf * fog;
            T *= mix(0.22, 0.55, glass);
            if (T < 0.03) break;
        }
    }
    return col;
}

// One gain for the whole palette that holds its mean luma fixed, so the
// palette tour's crossfades change the colours but never brighten or darken
// the whole frame.
float spGain(VisualUniforms u) {
    float l = 0.25 * (luma(spPalSteady(0.125, u)) + luma(spPalSteady(0.375, u))
                    + luma(spPalSteady(0.625, u)) + luma(spPalSteady(0.875, u)));
    return clamp(0.22 / max(l, 1e-3), 0.4, 1.5);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float t = mod(u.time, 1200.0) * 0.5;

    float persp = u.param0;
    float glass = mix(0.35, 1.0, u.param1);
    float reflK = mix(0.35, 1.0, u.param2);

    // ---- camera: trucks along the row, swinging slowly between views ----
    vec2 fl = vec2(u.time * 0.015, 1.0);
    float cx = mod(fl.x, 128.0);   // the row repeats every 128 cells
    float camDist = mix(5.0, 3.0, persp) + 0.6 * sin(t * 0.031 + 0.5);
    float lead = 1.2 + 4.2 * sin(t * 0.019 + 0.7);
    vec3 ro = vec3(cx, 0.75 + 0.45 * sin(t * 0.037 + 1.0), -camDist);
    vec3 ta = vec3(cx + lead, 1.15 + 0.35 * sin(t * 0.029 + 2.0), 0.0);
    float fov = mix(1.75, 1.25, persp);
    vec3 rd = osCamera(ro, ta, osBank(u, 0.02), fov, p);
    float pix = 2.0 / (u.resolution.y * fov);

    // the back light sits low behind the row, a little inside the camera's
    // heading, so it is mostly hidden behind the columns and shines between them
    vec3 Ldir = normalize(vec3(0.7 * lead / camDist + 0.12 * sin(t * 0.013), 0.06, 1.0));
    vec3 Lk = normalize(vec3(-0.5, 0.8, -0.4));
    float bp = saturate(u.beatPhase);
    // a smooth swell over the beat: rises over its first third, settles by its end
    float bSw = smoothstep(0.0, 0.3, bp) * (1.0 - bp) * (1.0 - bp) * 1.0;
    float capLift = bSw * 0.02;

    // the beat wave starts at the camera and runs ahead along the row
    vec2 wave = vec2(cx + 0.5 + 16.0 * bp, bSw * 0.03);

    int ncell = osSteps(6.0, 18.0, detail);
    int ncellM = osSteps(3.0, 9.0, detail);
    // the back glow keeps the bass role's warm mix but not its kick swing:
    // it lights the whole sky, so it must not pump with the bass
    vec3 cGlow = mix(spPal(0.40, u), spPal(0.084, u), 0.62);
    vec3 cCore = spPal(0.80, u);
    vec3 cHaze = spPal(0.55, u);

    float tF = rd.y < -1e-4 ? -ro.y / rd.y : 1e5;
    float T = 1.0;
    float tFirst;
    vec3 col = spTrace(ro, rd, tF, ncell, true, true, glass, capLift, pix, Ldir, Lk, cGlow, cCore, cHaze, wave, u, T, tFirst);

    // ---- shafts: the back light through the gaps, scattered by haze ----
    int ns = osSteps(4.0, 16.0, detail);
    float tEnd = min(min(tFirst, tF), 16.0);
    float dt = tEnd / float(ns);
    float jit = fract(52.9829189 * fract(dot(floor(uv * u.resolution), vec2(0.06711056, 0.00583715))));
    float phaseF = 0.025 + 2.2 * pow(saturate(dot(rd, Ldir)), 10.0);
    vec3 shaftCol = cGlow * (0.9 + 0.1 * bSw);
    float shaft = 0.0;
    for (int i = 0; i < 16; i++) {
        if (i >= ns) break;
        float ts = (float(i) + jit) * dt;
        vec3 q = ro + rd * ts;
        float vis = 1.0;
        if (q.z < -SP_D) {
            // follow the light back to the row's mid-plane: blocked by a column?
            vec3 w = q + Ldir * (-q.z / Ldir.z);
            float c = floor(w.x + 0.5);
            float H = spColumn(u, c).x;
            float inX = 1.0 - smoothstep(SP_W - 0.03, SP_W + 0.03, abs(w.x - c));
            float inY = 1.0 - smoothstep(H - 0.04, H + 0.04, w.y);
            vis = 1.0 - inX * inY;
        }
        // ground haze: thick low down, thin above the columns
        shaft += vis * exp(-ts * 0.06 - max(q.y, 0.0) * 1.1);
    }
    col += shaftCol * shaft * dt * phaseF * 0.16;

    // ---- a second row, three times the size, far behind: depth and skyline ----
    if (T > 0.03) {
        vec3 roB = (ro - vec3(0.0, 0.0, 26.0)) / 6.0 + vec3(41.0, 0.0, 0.0);
        float TB = 1.0;
        float tB;
        vec3 cb = spTrace(roB, rd, tF / 6.0, osSteps(3.0, 7.0, detail), false, false, glass, capLift, pix,
                          Ldir, Lk, cGlow, cCore, cHaze, vec2(0.0), u, TB, tB);
        // seen through the haze: dim, and veiled in the back light
        col += T * (cb * 0.16 + (1.0 - TB) * cGlow * 0.004) * exp(-tB * 0.12);
        T *= TB;
    }

    // ---- floor: black glass mirroring the row, pooled with column light ----
    if (tF < 1e4 && T > 0.03) {
        vec3 pf = ro + rd * tF;
        float fres = (0.06 + 0.94 * pow(1.0 - saturate(-rd.y), 5.0)) * reflK;
        vec3 fcol = vec3(0.002);
        float cf = floor(pf.x + 0.5);
        int np = detail > 0.5 ? 3 : 1;
        for (int i = 0; i < 3; i++) {
            if (i >= np) break;
            float c = cf + float(i - np / 2);
            vec2 hb = spColumn(u, c);
            vec2 dq = max(abs(vec2(pf.x - c, pf.z)) - vec2(SP_W, SP_D), 0.0);
            float dd = length(dq);
            vec3 cc = spPal(spBin(c) / 63.0 * 1.9, u);
            fcol += cc * exp(-dd * 3.0) * (0.08 + 0.12 * hb.y) * (0.4 + 0.25 * hb.x);

        }
        // faint seams in the floor plates
        float seam = max(aaLineCyclic(pf.x, 0.01), aaLineCyclic(pf.z * 0.5, 0.01)) * exp(-tF * 0.08);
        fcol += spPalSteadyFog(0.5, u) * seam * 0.03;
        float fogF = exp(-tF * 0.035);
        col += T * fcol * fogF;
        // the mirror, a little rough: dimmer the further it travels
        vec3 roM = vec3(pf.x, 1e-3, pf.z);
        vec3 rdM = vec3(rd.x, -rd.y, rd.z);
        float TM = 1.0;
        float tFM;
        vec3 refl = spTrace(roM, rdM, 1e5, ncellM, false, true, glass, capLift, pix, Ldir, Lk, cGlow, cCore, cHaze, wave, u, TM, tFM);
        refl += TM * spSky(rdM, Ldir, cGlow, cCore, cHaze);
        col += T * fres * refl * fogF * mix(1.0, 0.6, saturate(tFM * 0.2));
        col += T * (1.0 - fogF) * spSky(rd, Ldir, cGlow, cCore, cHaze);
    } else {
        col += T * spSky(rd, Ldir, cGlow, cCore, cHaze);
    }
    col *= spGain(u);
    return col; // linear HDR; the host tone-maps
}
