// SPDX-License-Identifier: AGPL-3.0-only
// Murmuration.
// Blue hour over a reed marsh: the sun is down, a band of afterglow burns on
// the horizon under a deep teal sky, a perspective cloud deck and high cirrus
// combed out and lit rose and gold. A vast flock of starlings spreads across
// the sky in several lobes that stretch, fold and merge. The flock is a thin
// sheet rippling in depth: where it turns edge-on the birds pack into narrow
// dark fold bands, where it tilts to the low sun they show pale undersides and
// a few glint. Thousands of V-winged birds are drawn from jittered cells on
// tilted grids at three depths plus a fine layer that fills the folds, so near
// and far birds drift at different rates; wings beat lazily. Calm under loud music: the flock
// moves at a slow, steady tempo so the dense birds never stream fast enough
// to flicker, and the camera never moves. Every four bars a faint banking
// wave, strength from the smoothed level, rolls slowly through the flock with a soft
// band of birds turning their pale undersides (glints stay put), their tone easing slowly
// between warm and cool silver; the smoothed level lights the glints and warms the afterglow.
// A still lagoon mirrors it all.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 = Flock Spread ; param1 = Wave Strength ; param2 = Wind

// The palette read: the visual's own palette with no beat or spectral nudge.
// The vivid tour swaps whole palettes of very different brightness every few
// seconds, which swells the light across the frame, so this visual keeps its
// own colours there (as the calm visuals do); a host's manifest palette still
// replaces them.
vec3 muPalSteady(float t, VisualUniforms u) { return osPalCalm(t, 11, u); }

const float MU_HY = -0.46;   // horizon height in centred screen units

// The palette, read once per pixel at fixed stops.
struct MuPal { vec3 dome; vec3 mid; vec3 glow; vec3 ember; vec3 sun; vec3 cloud; vec3 cirr;
               vec3 shA; vec3 shB; vec3 pale; vec3 gl1; vec3 land; vec3 water; vec3 glit; };

float muFbm(vec2 p, int oct) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 6; ++i) {
        if (i >= oct) break;
        v += a * vnoise(p);
        p = FBM_OCTAVE * p;
        a *= 0.5;
    }
    return v;
}

// Flock envelope at q (already warped): density, about 0..2.
float muFlock(vec2 q, float tau, float spread) {
    float f = 0.0;
    for (int k = 0; k < 5; ++k) {
        float fk = float(k);
        vec2 c = vec2(sin(tau * (0.048 + 0.012 * fk) + fk * 2.17) * (0.55 + 0.75 * spread),
                      MU_HY + 0.78 + 0.26 * sin(tau * (0.04 + 0.009 * fk) + fk * 1.71));
        float ang = 0.45 * sin(tau * 0.032 + fk * 1.3) + 0.25 * fk - 0.5;
        vec2 d = rot2(ang) * (q - c);
        float sz = 0.75 + 0.35 * sin(tau * 0.045 + fk * 2.9);
        d *= vec2(1.0 / (0.62 * sz * (0.7 + 0.6 * spread)), 1.0 / (0.17 * sz));
        f += exp(-dot(d, d));
    }
    return f;
}

// The flock is a thin sheet of birds rippling in depth. Returns the slope of
// the sheet's depth at q (xy) and how nearly edge-on it is seen (z): there its
// birds pile up in projection into narrow dark fold bands; where it tilts
// toward the sun the birds show their pale undersides. The beat pulse travels
// through it as a wave of banking birds.
vec3 muSheet(vec2 q, float tau, float wx, float wa) {
    // one rolling fold train, its crests bent into curves by a slower wave, so
    // the folds run as long curved bands rather than spots
    vec2 k1 = vec2(4.6, 2.0), k2 = vec2(-1.6, 3.4);
    float bend = dot(k2, q) + tau * 0.07;
    float ph = dot(k1, q) - tau * 0.22 + 1.4 * sin(bend);
    vec2 dph = k1 + 1.4 * cos(bend) * k2;
    float cp = cos(ph);
    vec2 g = 0.32 * cp * dph;
    float c2 = cp * cp;
    float band = c2 * c2 * c2 * c2 * c2;
    // the banking pulse: a raised ridge of the sheet running across the flock
    vec2 bd = vec2(0.92, 0.38);
    float x = dot(q, bd) - wx;
    float pr = x * exp(-x * x * 20.0);
    g += bd * wa * (-24.0 * pr);
    band += saturate(wa * 150.0 * pr * pr);
    return vec3(g, saturate(band));
}

float muSeg(vec2 p, vec2 b) {
    float h = saturate(dot(p, b) / max(dot(b, b), 1e-6));
    return length(p - b * h);
}

// Sky above the horizon for centred position p: afterglow, teal dome, clouds.
vec3 muSky(vec2 p, float t, int oct, MuPal P, VisualUniforms u) {
    float h = max(p.y - MU_HY, 0.0);
    vec3 dome = P.dome * 0.035;
    vec3 mid = P.mid * 0.22;
    vec3 glow = P.glow;
    vec3 ember = P.ember;
    // afterglow: brightest low and toward the set sun on the right
    float sunX = 0.55;
    float side = exp(-abs(p.x - sunX) * 0.9);
    float warmth = 1.0 + 0.03 * saturate(u.level);
    vec3 col = mix(mid, dome, smoothstep(0.15, 1.3, h));
    col = mix(col, ember * (0.35 + 0.5 * side) * warmth, exp(-h * 5.0) * 0.85);
    col += glow * exp(-h * 16.0) * (0.6 + 1.9 * side) * warmth;
    col += P.sun * exp(-length(vec2((p.x - sunX) * 0.45, h)) * 11.0) * 1.6 * warmth;

    // crepuscular rays fanning up from the set sun
    vec2 sd = p - vec2(sunX, MU_HY - 0.12);
    vec2 dn = sd / max(length(sd), 1e-3);
    float ray = smoothstep(0.35, 0.9, vnoise(dn * 5.5 + vec2(t * 0.012, 0.0)) * 0.8 + 0.2 * vnoise(dn * 13.0 - vec2(t * 0.02, 0.0)));
    col += glow * ray * exp(-h * 2.0) * (0.06 + 0.22 * side) * (0.96 + 0.04 * saturate(u.level));

    // cloud deck in perspective, lit from below by the afterglow
    float dz = 0.32 / (h + 0.035);
    vec2 cc = vec2(p.x * dz * 0.9 + t * 0.012, dz * 1.6 + t * 0.02);
    float n = muFbm(cc * vec2(0.9, 1.7), oct);
    float dens = smoothstep(0.48, 0.78, n) * smoothstep(0.02, 0.10, h) * (1.0 - smoothstep(0.55, 1.2, h));
    float lit = exp(-h * 2.2) * (0.35 + 1.4 * side);
    float thin = 1.0 - smoothstep(0.5, 0.95, n);
    vec3 cloudCol = P.cloud * 0.02 + mix(ember, glow, thin * side * 0.7) * lit * (0.5 + 2.6 * thin);
    col = mix(col, cloudCol, dens * 0.9);
    // high cirrus combed out by the upper wind, lit rose and gold from below
    vec2 cq = rot2(-0.16) * p;
    float comb = cq.y * 9.0 + 1.6 * vnoise(vec2(cq.x * 1.3, cq.y * 2.0) + 7.0);
    float cx = cq.x + t * 0.006;
    float ci = 0.62 * vnoise(vec2(cx * 1.4, comb)) + 0.38 * vnoise(vec2(cx * 3.1 + 2.0, comb * 2.3));
    float wisp = smoothstep(0.5, 0.8, ci) * smoothstep(0.3, 0.65, h) * (1.0 - smoothstep(0.95, 1.45, h));
    col += mix(P.cirr, glow, side * 0.8) * wisp * (0.03 + 0.08 * side) * warmth * (1.0 - dens);
    // first stars high in the dome
    vec2 sp = p * 70.0;
    vec2 si = floor(sp);
    float sr = hash21(si + 3.1);
    float star = step(0.965, sr) * (1.0 - smoothstep(0.0, 0.12, length(fract(sp) - 0.5)));
    col += vec3(0.8, 0.9, 1.0) * star * smoothstep(0.5, 1.2, h) * (1.0 - dens) *
           (0.5 + 0.2 * sin(t * 0.8 + sr * 60.0));
    return col;
}

// Far shoreline and reed-bed silhouette height above the horizon at x.
float muShore(float x) {
    float trees = vnoise(vec2(x * 7.0, 1.3)) * 0.035 + vnoise(vec2(x * 23.0, 4.1)) * 0.012;
    return MU_HY + 0.006 + trees * smoothstep(-1.9, -0.4, x) * (1.0 - smoothstep(0.2, 1.3, x)) + 0.004 * vnoise(vec2(x * 60.0, 0.0));
}

// The sky with its flock, at p above the horizon. lay = bird layers to draw.
vec3 muScene(vec2 p, float t, float tau, int lay, int oct, float px, MuPal P, VisualUniforms u) {
    vec3 col = muSky(p, t, oct, P, u);

    float spread = u.param0;
    // organic folds: the envelope is read through a slowly moving warp
    vec2 w = vec2(vnoise(p * 1.4 + vec2(tau * 0.06, 0.0)),
                  vnoise(p * 1.4 + vec2(5.2, -tau * 0.052))) - 0.5;
    vec2 q = p + w * 0.42;
    float fl = muFlock(q, tau, spread);
    float edge = vnoise(q * 6.0 + vec2(0.0, tau * 0.05)) - 0.5;
    float dens = smoothstep(0.22, 0.85, fl + 0.32 * edge);
    if (dens <= 0.0) return col;                 // open sky: no flock here
    float core = smoothstep(0.8, 1.8, fl);
    // internal filaments: birds bunch into streams and thin into veils
    float inner = 0.45 + 0.75 * vnoise(q * vec2(4.5, 7.0) + w * 3.0 + vec2(tau * 0.04, 0.0));

    // the banking pulse sweeps the flock every sixteen beats, strength from the level
    float b4 = (mod(u.beatCount, 16.0) + saturate(u.beatPhase)) * 0.0625;
    float wavePos = -2.0 + 4.0 * b4;
    float waveAmp = (0.012 + 0.012 * saturate(u.level)) * mix(0.3, 1.2, u.param1);
    vec3 sh3 = muSheet(q, tau, wavePos, waveAmp);
    vec2 sg = sh3.xy;
    float fold = sh3.z;                          // the narrow bands where the sheet turns edge-on
    float edgeOn = fold;
    float proj = 1.0 + 1.6 * fold;               // birds per area in projection
    // pale undersides where the sheet tilts toward the low sun
    float under = smoothstep(0.6, 1.6, dot(sg, vec2(0.85, -0.5))) * (1.0 - 0.5 * edgeOn);
    // the turn: just behind the ridge the birds roll over and flash their pale
    // undersides, a faint light band sweeping the flock; the pale tone eases
    // between warm and cool silver over sixteen beats
    float wx = dot(q, vec2(0.92, 0.38)) - wavePos + 0.12;
    float turn = exp(-wx * wx * 9.0) * (0.07 + 0.03 * saturate(u.level)) * mix(0.4, 1.2, u.param1)
               * smoothstep(0.0, 0.08, b4) * (1.0 - smoothstep(0.82, 0.98, b4));
    float under0 = under;
    under = max(under, turn);
    float coolMix = 0.5 - 0.5 * cos(3.14159265 * (mod(u.beatCount, 16.0) + saturate(u.beatPhase)) / 8.0);
    vec3 paleC = mix(P.pale, mix(P.mid * 2.2, vec3(0.75, 0.85, 1.0), 0.55), coolMix);

    // the mass: sub-pixel birds as a translucent dark body, densest in folds
    float lowLight = exp(-max(p.y - MU_HY, 0.0) * 2.5);
    vec3 shade = mix(P.shA * 0.012, P.shB * 0.03, lowLight);
    vec3 pale = paleC * (0.05 + 0.12 * lowLight) * (0.95 + 0.1 * saturate(u.level)) * (1.0 + 0.4 * turn);
    float body = min(dens * inner * (0.2 + 0.6 * fold) + core * 0.06, 0.78) * (lay == 1 ? 1.25 : 1.0);
    col = mix(col, mix(shade, pale, under * 0.6), saturate(body));

    // individual birds on three depth layers: near birds large and sparse with
    // flapping wings, far ones fine; each layer on its own tilted grid. A
    // fourth, finest layer fills the folds, where the edge-on sheet packs the
    // birds tight in projection.
    float glintBoost = 0.85 + 0.15 * saturate(u.level);
    for (int k = 0; k < 4; ++k) {
        if (k >= lay) break;
        int L = lay == 1 ? 1 : k;   // a single layer draws the full mid-depth flock
        float fL = float(L);
        float cellPx = 8.0 - 3.0 * fL + 0.4 * fL * fL;    // 8, 5.4, 3.6, 2.6 px
        float sc = 1.0 / (cellPx * px);
        float drift = tau * (0.020 - 0.005 * fL);         // near birds drift faster
        vec2 g = rot2(0.5 + 1.3 * fL) * ((q + vec2(drift, 0.0)) * sc) + w * (6.0 + 3.0 * fL);
        vec2 id = floor(g);
        vec2 f = g - id;
        vec2 h = hash22(id + fL * 37.0);
        float want = L == 3 ? dens * fold * 1.6
                            : sqrt(dens) * proj * (0.55 + 0.25 * fL) * (L == 0 ? 0.45 : 1.0);
        float present = saturate((want - h.x) * 5.0);
        if (present <= 0.0) continue;
        vec2 j = 0.2 + 0.6 * hash22(id + 19.1 + fL) +
                 0.08 * vec2(sin(tau * 0.9 + h.y * 6.28), cos(tau * 1.1 + h.x * 6.28));
        float flap = sin(t * (2.0 + 0.8 * h.y) + h.y * 40.0);
        vec2 d = (f - j) * cellPx;                        // in pixels
        float span = 1.5 - 0.3 * fL;
        // a V of two wings; edge-on birds shrink to a dash
        vec2 tip = vec2(span * (1.0 - 0.5 * edgeOn), span * 0.55 * flap);
        float dist = min(muSeg(d, tip), muSeg(d, vec2(-tip.x, tip.y)));
        float a = (1.0 - smoothstep(0.3, 1.05 - 0.15 * fL, dist)) * present;
        // birds showing their undersides to the low sun catch its light
        float gth = 1.0 - (0.008 + 0.06 * under0) * 0.85;
        float glint = smoothstep(gth - 0.02, gth + 0.02, hash21(id + fL * 3.0));
        vec3 bird = mix(shade, pale * 1.6, under * 0.5);
        bird = mix(bird, mix(paleC, P.gl1, h.y) * (0.2 + 0.6 * lowLight) * glintBoost,
                   glint * under);
        col = mix(col, bird, a);
    }
    return col;
}

// Foreground reed silhouettes: two layers of curved, tapering stems with
// plume heads, densest in the corners. Returns coverage 0..1.
float muReeds(vec2 p, float t, float px, float windAmt) {
    float cover = 0.0;
    float corner = smoothstep(0.35, 1.5, abs(p.x));
    for (int L = 0; L < 2; ++L) {
        float fL = float(L);
        float w = 0.045 - 0.017 * fL;              // stem spacing
        float cx = floor(p.x / w);
        float h = hash21(vec2(cx, 7.0 + fL * 11.0));
        float h2 = hash21(vec2(cx, 3.0 + fL * 5.0));
        float ccorner = smoothstep(0.35, 1.5, abs((cx + 0.5) * w));
        float top = -1.0 + (0.08 + 0.5 * h * h * ccorner) * (1.0 - 0.45 * fL);
        float y = (p.y + 1.0) / max(top + 1.0, 1e-3);   // 0 at the frame bottom, 1 at the tip
        float sway = (0.6 + 0.8 * windAmt) * (0.012 + 0.01 * h2) *
                     sin(t * (0.55 + 0.3 * h2) + cx * 0.7 + fL);
        float lean = (h2 - 0.5) * 0.05 + sway;
        float sx = (cx + 0.25 + 0.5 * h2) * w + lean * y * y;
        float th = mix(0.0055, 0.0012, saturate(y)) * (1.0 - 0.3 * fL);
        float stem = (1.0 - smoothstep(th, th + px, abs(p.x - sx))) * step(y, 1.0);
        // plume head on the taller stems
        vec2 pd = vec2(p.x - sx - lean * 0.15, p.y - top - 0.03);
        pd = rot2(-lean * 4.0) * pd;
        float plume = (1.0 - smoothstep(1.0, 1.0 + px * 60.0, length(pd * vec2(1.0 / 0.009, 1.0 / 0.04)))) *
                      step(0.45, h) * ccorner;
        cover = max(cover, max(stem, plume));
    }
    // low grass bank along the bottom edge
    float bank = -1.0 + 0.03 + 0.06 * corner + 0.025 * vnoise(vec2(p.x * 40.0, 0.0)) * (0.3 + corner);
    cover = max(cover, 1.0 - smoothstep(bank - px, bank + px, p.y));
    return cover;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float px = 2.0 / max(u.resolution.y, 1.0);
    float detail = osDetail(u);
    int lay = osSteps(1.0, 4.0, detail);
    int oct = osSteps(3.0, 5.0, detail);

    float t = mod(u.time, 600.0);
    float wind = mix(0.5, 1.6, u.param2);
    float tau = mod(mod(u.time, 36000.0) * 0.45 * wind, 4000.0);

    MuPal P;
    P.dome = muPalSteady(0.0, u);
    P.mid = muPalSteady(0.16, u);
    P.glow = muPalSteady(0.80, u);
    P.ember = muPalSteady(0.96, u);
    P.sun = muPalSteady(0.72, u);
    P.cloud = muPalSteady(0.04, u);
    P.cirr = muPalSteady(0.88, u);
    P.shA = muPalSteady(0.03, u);
    P.shB = muPalSteady(0.92, u);
    P.pale = muPalSteady(0.62, u);
    P.gl1 = muPalSteady(0.87, u);
    P.land = muPalSteady(0.9, u);
    P.water = muPalSteady(0.05, u);
    P.glit = muPalSteady(0.7, u);

    vec3 col;
    if (p.y >= MU_HY) {
        col = muScene(p, t, tau, lay, oct, px, P, u);
        // far shore and reed beds in silhouette, hazed by the afterglow
        float sh = muShore(p.x);
        float land = 1.0 - smoothstep(sh - px, sh + px, p.y);
        col = mix(col, P.land * 0.025, land);
    } else {
        // lagoon: a rippled mirror, darker toward the viewer
        float below = MU_HY - p.y;
        float dz = 1.0 / (below + 0.02);
        vec2 rip = vec2(vnoise(vec2(p.x * dz * 2.0, dz * 6.0 - t * 0.3)),
                        vnoise(vec2(p.x * dz * 3.1 + 4.0, dz * 9.0 + t * 0.2))) - 0.5;
        vec2 m = vec2(p.x + rip.x * 0.03 * below, MU_HY + below + rip.y * 0.05 * below);
        float sh = muShore(m.x);
        vec3 refl = m.y < sh ? P.land * 0.02 : muScene(m, t, tau, lay > 1 ? 1 : 0, oct - 1, px, P, u);
        float fres = mix(0.75, 0.25, saturate(below * 2.2));
        col = refl * fres + P.water * 0.004;
        // glitter along the afterglow's path, lit by the treble
        vec2 gc = vec2(p.x * dz * 9.0, dz * 3.0 - t * 0.15);
        float gl = step(0.93, hash21(floor(gc))) * (1.0 - smoothstep(0.0, 0.35, length(fract(gc) - 0.5)));
        col += P.glit * gl * exp(-abs(p.x - 0.55) * 2.5) * exp(-below * 6.0) *
               (0.7 + 0.3 * saturate(u.level));
    }

    // reed beds in the foreground corners, black against the water
    col = mix(col, vec3(0.002, 0.003, 0.004), muReeds(p, t, px, u.param2));

    return col; // LINEAR HDR — post chain tonemaps
}
