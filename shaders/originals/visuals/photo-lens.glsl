// SPDX-License-Identifier: AGPL-3.0-only
// Photo lens.
// A faceted crystal lens floats in front of the photo like a macro product
// shot. Through the glass the photo folds into mirrored kaleidoscope shards,
// each facet refracting its own piece with spectral dispersion at the seams
// and grading it through the palette, so the shards read as cut coloured
// crystal; behind it the same photo sits out of focus in a dark duotone, its
// highlights opening into bokeh discs and an anamorphic streak. A softbox
// reflection, Fresnel rim and facet glints light the glass, and the lens
// throws a caustic onto the backdrop. The shards drift slowly and steadily
// through the photo and fold in from the centre outward on a slow tide, a
// faint beam of light glides slowly round the lens, and the colour wheel
// eases round over two phrases; the smoothed level gently lifts the rim,
// caustic, glints and dispersion (no beat flashes or speed surges), and the
// deepest reds are kept just off pure saturated red.
// param0 = Segments ; param1 = Spin ; param2 = Glints

// mirrored repeat, so kaleidoscope samples never hit a hard image edge
// The palette read without the library's per-beat and spectral-centroid hue
// nudge, so large lit areas never shimmer with the music; under the host's
// palette tour the cross-fade between palettes is spread over the whole tour
// step, so the colours change slowly.
vec3 plPalStill(float t, VisualUniforms u) {
    if (u.palette.x >= 0.0) return palByIndex(t, int(floor(u.palette.x + 0.5)));
    int a = int(mod(floor(u.palette.z), OS_PAL_COUNT));
    int b = int(mod(float(a + 1), OS_PAL_COUNT));
    float blend = smoothstep(0.0, 1.0, fract(u.palette.z));
    return mix(palByIndex(t, a), palByIndex(t, b), blend);
}

vec2 plMirror(vec2 x) { return 1.0 - abs(1.0 - mod(x, 2.0)); }

vec3 plPhoto(vec2 s, VisualUniforms u) {
    return max(IMG(photoCover(clamp(s, 0.0, 1.0), u.resolution, IMGSIZE)).rgb, vec3(0.0));
}

// cyclic blend of four palette samples read once per pixel (each palette
// read is costly, so the visual reads four and interpolates)
vec3 plPal(float t, vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
    float x = fract(t) * 4.0;
    float i = floor(x);
    float f = smoothstep(0.3, 0.7, x - i);   // short blends: no grey midpoints
    vec3 a = i < 1.0 ? c0 : (i < 2.0 ? c1 : (i < 3.0 ? c2 : c3));
    vec3 b = i < 1.0 ? c1 : (i < 2.0 ? c2 : (i < 3.0 ? c3 : c0));
    vec3 m = mix(a, b, f);
    // lift the chroma that an RGB blend between distant hues loses
    return max(mix(vec3(luma(m)), m, 1.0 + 2.4 * f * (1.0 - f)), vec3(0.0));
}
#define PLPAL(t) plPal(t, pc0, pc1, pc2, pc3)

// Out-of-focus photo: a golden-angle disc gather, weighted toward highlights
// so bright points open into round bokeh discs.
vec3 plBokeh(vec2 s, float rad, float aspect, int n, VisualUniforms u) {
    vec3 acc = vec3(0.0);
    float ws = 0.0;
    float fn = float(max(n, 1));
    for (int i = 0; i < 40; i++) {
        if (i >= n) break;
        float fi = float(i) + 0.5;
        float a = fi * 2.39996;
        vec2 o = vec2(cos(a), sin(a)) * sqrt(fi / fn) * rad;
        vec3 c = plPhoto(s + vec2(o.x / aspect, o.y), u);
        float l = luma(c);
        float w = 1.0 + 14.0 * l * l * l * l;
        acc += c * w;
        ws += w;
    }
    return acc / max(ws, 1e-4);
}

// The photo's own key colour: nine fixed taps averaged. The taps do not
// depend on the pixel, so every pixel agrees and the cost is tiny.
vec3 plKey(VisualUniforms u) {
    vec3 s = vec3(0.0);
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        s += plPhoto(vec2(mod(fi, 3.0), floor(fi / 3.0)) * 0.3 + 0.2, u);
    }
    return s / 9.0;
}

// An accent complementary to the photo: the palette stop whose hue sits
// furthest from the photo's key, pushed toward the key's true complement
// (the more colourful the photo, the harder the push).
vec3 plAccent(vec3 key, vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
    vec3 kc = key - vec3(luma(key));
    float ks = length(kc);
    vec3 kn = kc / max(ks, 1e-4);
    vec3 best = c0;
    float bd = dot(c0 - vec3(luma(c0)), kn) / max(length(c0 - vec3(luma(c0))), 1e-4);
    float d1 = dot(c1 - vec3(luma(c1)), kn) / max(length(c1 - vec3(luma(c1))), 1e-4);
    float d2 = dot(c2 - vec3(luma(c2)), kn) / max(length(c2 - vec3(luma(c2))), 1e-4);
    float d3 = dot(c3 - vec3(luma(c3)), kn) / max(length(c3 - vec3(luma(c3))), 1e-4);
    if (d1 < bd) { best = c1; bd = d1; }
    if (d2 < bd) { best = c2; bd = d2; }
    if (d3 < bd) { best = c3; bd = d3; }
    vec3 comp = max(vec3(0.33) - kn * 0.75, vec3(0.0));
    vec3 a = mix(best, comp * 1.6, saturate(ks * 6.0) * 0.6);
    return a / max(max(a.r, max(a.g, a.b)), 0.05);
}

// the host's filmic tonemap curve and its inverse (for the red guard below)
vec3 plFilmic(vec3 x) { return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14); }
float plFilmicInv(float t) {
    t = min(t, 0.99);
    float a = 2.51 - 2.43 * t, b = 0.03 - 0.59 * t, c = -0.14 * t;
    return (-b + sqrt(max(b * b - 4.0 * a * c, 0.0))) / (2.0 * a);
}

// spectral weight of a sample at wavelength position w (0 red .. 1 violet)
vec3 plSpectrum(float w) {
    return max(vec3(1.0 - abs(w - 0.12) * 2.6, 1.0 - abs(w - 0.5) * 2.6, 1.0 - abs(w - 0.88) * 2.6), vec3(0.0));
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    float detail = osDetail(u);
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    vec2 p = centered(uv, u.resolution);          // y grows downward
    float t = mod(u.time, 600.0);

    float segs = 6.0 + floor(u.param0 * 6.0 + 0.5);
    float glints = mix(0.4, 1.7, u.param2);
    // shard drift and facet turn glide at a steady pace (no beat surges);
    // wrapped so every frequency below completes whole cycles across the wrap
    float d = mod(mix(0.06, 0.14, u.param1) * u.time, 62.831853);
    float turn = d * 0.1;
    // how far the glass folds the photo into kaleidoscope shards: a slow
    // 48-second tide, so each shard eases between clear and folded over seconds
    float bc = u.beatCount + saturate(u.beatPhase);
    float fold = 0.45 + 0.55 * (0.5 - 0.5 * cos(t * 0.1308997));

    // the colour wheel turns steadily, one palette stop per 32 beats,
    // so the roles of the colours trade places without a sudden recolour
    float hueOff = mod(bc, 128.0) / 128.0;
    // a swell that rises and falls within the beat: zero on the kick, so
    // nothing large jumps on the downbeat
    float kick = sin(3.14159265 * saturate(u.beatPhase));
    kick *= kick;
    vec3 pc0 = plPalStill(0.04, u);
    vec3 pc1 = plPalStill(0.26, u);
    vec3 pc2 = plPalStill(0.80, u);
    vec3 pc3 = plPalStill(0.99, u);
    vec3 accent = plAccent(plKey(u), pc0, pc1, pc2, pc3);

    // ---- backdrop: the photo out of focus behind the glass, in a dark duotone ----
    vec2 par = vec2(0.012 * sin(t * 0.07), 0.008 * sin(t * 0.05 + 1.0));
    vec2 bs = (uv - 0.5) * 0.9 + 0.5 + par;
    int nb = osSteps(10.0, 32.0, detail);
    vec3 bg = plBokeh(bs, 0.030, aspect, nb, u);
    float bl = luma(bg);
    // cool shadows and mids, only the brightest bokeh turn warm
    float bt = smoothstep(0.2, 0.7, bl);
    vec3 bduo = bl * bl * PLPAL(hueOff + 0.02 + 0.24 * bt) * (1.3 + 0.3 * bt)
              + PLPAL(hueOff + 0.80) * 2.2 * bl * smoothstep(0.82, 1.0, bl) * (0.85 + 0.12 * u.level);
    // the photo keeps its own colours behind the duotone, so it stays legible
    vec3 col = mix(bg * bg * 0.8, bduo, 0.70) * 0.68;
    col = max(mix(vec3(luma(col)), col, 1.55), vec3(0.0)) * smoothstep(0.02, 0.2, bl);

    // lens placement: large, slow drift, gentle breathing with the level
    vec2 lc = vec2(0.10 * sin(t * 0.09), 0.05 * sin(t * 0.13 + 1.3));
    float R = 0.88 + 0.015 * sin(t * 0.21) + 0.004 * u.level;
    vec2 q = (p - lc) / R;
    float r = length(q);

    // contact shadow and caustic the lens throws onto the backdrop
    vec2 qs = q - vec2(0.06, 0.10);
    float rs = length(qs);
    col *= 1.0 - 0.65 * smoothstep(1.45, 0.95, rs);
    // the caustic: a thin dispersed crescent focused just outside the shadow
    vec2 qc = q - vec2(0.10, 0.16);
    float cr = length(qc) - 1.04;
    float cmask = exp(-dot(qc / max(length(qc), 1e-4) - vec2(0.32, 0.95), qc / max(length(qc), 1e-4) - vec2(0.32, 0.95)) * 3.0);
    vec3 caus = vec3(1.0, 0.25, 0.08) * exp(-pow((cr - 0.035) * 38.0, 2.0))
              + accent * 1.3 * exp(-pow(cr * 38.0, 2.0))
              + vec3(0.35, 0.15, 1.0) * exp(-pow((cr + 0.035) * 38.0, 2.0));
    col += caus * cmask * (0.42 + 0.06 * u.level + 0.02 * u.level * kick);

    float inside = aaFill(r - 1.0);
    if (inside > 0.0) {
        float rc = min(r, 0.9995);
        float nzS = sqrt(1.0 - rc * rc);
        vec3 nS = vec3(q, nzS);   // smooth dome normal (|q| = r)
        float rimB = smoothstep(0.80, 1.0, r);

        // kaleidoscope fold: segs mirrored sectors turning slowly
        float sector = 6.2831853 / segs;
        float a = atan2_(q.y, q.x) + turn;
        float sidx = floor(a / sector + 0.5);
        float la = a - sidx * sector;
        float ma = abs(la);
        vec2 kq = vec2(cos(ma), sin(ma)) * r;
        // a soft beam of light that glides slowly round the lens
        float dc = mod(a / sector - 0.2 * t, segs);
        dc = min(dc, segs - dc);
        float chase = exp(-dc * dc * 1.1);

        // glass shards: Voronoi cells in the folded space, so every shard is
        // mirrored across the sector seams like a real kaleidoscope
        vec2 sp = kq * 3.2 + vec2(0.0, 0.35 * sin(d * 0.1));
        vec2 ci = floor(sp);
        vec2 cf = sp - ci;
        float d1 = 8.0;
        float d2 = 8.0;
        vec2 best = vec2(0.0);
        vec2 bestO = vec2(0.0);
        for (int j = 0; j < 9; j++) {
            vec2 o = vec2(float(j % 3) - 1.0, float(j / 3) - 1.0);
            vec2 h = hash22(ci + o);
            vec2 pt = o + 0.5 + 0.38 * sin(6.2831853 * h + d * 0.2);
            vec2 dv = pt - cf;
            float dd = dot(dv, dv);
            if (dd < d1) { d2 = d1; d1 = dd; best = ci + o; bestO = dv; }
            else if (dd < d2) { d2 = dd; }
        }
        float edge = (sqrt(d2) - sqrt(d1)) / 3.2;    // shard border distance
        float sector2 = min(ma, sector * 0.5 - ma) * r; // mirror seam distance
        float h1 = hash21(best + 1.7);
        float h2 = hash21(best + 5.3);
        // each shard is a flat facet tilted its own way
        vec2 tiltV = (vec2(h1, h2) - 0.5) * 0.9;
        vec3 nF = normalize(vec3(q * 0.75 + tiltV, 1.0));
        vec3 n = normalize(mix(nS, nF, 0.75));

        // refracted, dispersed kaleidoscope sample
        vec2 origin = vec2(0.5) + vec2(0.20 * sin(d * 0.3), 0.18 * sin(d * 0.5 + 1.0));
        float zoomK = 0.52 + 0.08 * sin(d * 0.2);
        float near = exp(-edge * 70.0);
        float disp = (0.004 + 0.03 * near) * (1.0 + 0.1 * u.level);
        int ns = osSteps(3.0, 7.0, detail);
        vec3 acc = vec3(0.0);
        vec3 wsum = vec3(0.0);
        for (int j = 0; j < 7; j++) {
            if (j >= ns) break;
            float w = (float(j) + 0.5) / float(ns);
            vec2 off = tiltV * (0.12 + disp * (w - 0.5) * 4.0) + kq * disp * (w - 0.5);
            vec2 s = plMirror(origin + kq * zoomK + off);
            vec3 sw = plSpectrum(w);
            acc += plPhoto(s, u) * sw;
            wsum += sw;
        }
        vec3 glass = acc / max(wsum, vec3(1e-3));

        // the clear view: the photo behind, magnified and split by the shards
        vec2 pc = lc + (p - lc) * 0.70 + tiltV * 0.05;
        vec2 cs = ((pc / vec2(aspect, 1.0)) * 0.5 + 0.5 - 0.5) * 0.9 + 0.5 + par;
        vec3 clear = vec3(plPhoto(cs + tiltV * 0.004, u).r, plPhoto(cs, u).g, plPhoto(cs - tiltV * 0.004, u).b);
        // each shard folds in from the centre outward, so the change sweeps
        // across the glass instead of whole mirrored shard sets switching at once
        float fth = 0.75 * saturate(0.35 * h1 + 0.75 * r);
        float fs = smoothstep(fth, fth + 0.2, fold);
        glass = mix(clear, glass, fs);
        // cut-crystal colour: each shard grades its piece of the photo through
        // its own stretch of the palette wheel, dark mids into saturated lights
        float L = luma(glass);
        // the chased sector swings to the opposite side of the wheel
        float hk = 0.45 * h1 + 0.30 * r + hueOff + 0.05 * smoothstep(0.3, 1.0, chase);
        float lt = smoothstep(0.03, 0.45, L);
        L = L / (1.0 + 0.5 * L);     // roll off the photo's blown sky
        vec3 duo = L * (0.25 + 1.2 * L) * PLPAL(hk + 0.22 * lt) * (1.0 + 0.6 * lt);
        glass = mix(glass * glass, duo, 0.82);
        glass = max(mix(vec3(luma(glass)), glass, 1.35), vec3(0.0));
        // facets turned from the key light fall dark, like cut crystal
        float lam = saturate(dot(nF, normalize(vec3(-0.35, -0.45, 0.82))));
        float shade = 0.12 + 1.05 * lam * lam * lam;
        glass *= shade * (0.88 + 0.35 * h1 + 0.07 * u.level);
        glass *= 0.92 + chase * (0.08 + 0.02 * kick * u.level);

        // thick edge: the glass bends the backdrop inward and darkens
        vec3 edgeView = plPhoto(clamp(uv - q * 0.18 * rimB, 0.0, 1.0), u);
        vec3 lensCol = mix(glass, luma(edgeView * edgeView) * PLPAL(hueOff + 0.02) * 0.5, rimB * rimB);
        lensCol += mix(PLPAL(hueOff + 0.26 + 0.12 * sin(a * 0.5)), accent, 0.85) * pow(rimB, 8.0) * (1.0 + 0.1 * kick * u.level);

        // softbox reflection on the dome, up and to the left
        vec3 rv = reflect(vec3(0.0, 0.0, -1.0), nS);
        vec2 sb = (rv.xy - vec2(-0.45, -0.50)) * vec2(1.0, 1.7);
        float box = smoothstep(0.26, 0.16, max(abs(sb.x), abs(sb.y)));
        lensCol += mix(vec3(1.0), accent, 0.5) * box * 0.14;

        // shard glints flare as the facets turn through the key lights
        vec3 hv = normalize(vec3(-0.45, -0.55, 0.70) + vec3(0.0, 0.0, 1.0));
        vec3 hv2 = normalize(vec3(0.6, 0.45, 0.66) + vec3(0.0, 0.0, 1.0));
        float g = pow(saturate(dot(n, hv)), 180.0);
        float g2 = pow(saturate(dot(n, hv2)), 120.0);
        lensCol += peakWhite(PLPAL(hk + 0.1), 0.6) * 1.6 * g * glints * (0.5 + 0.08 * u.level);
        lensCol += PLPAL(hueOff + 0.85) * 1.6 * g2 * glints * (0.45 + 0.08 * u.level);

        // borders: spectral seams, brighter as each beat's ring passes; the
        // dispersed violet and blue are the accent against the palette pair
        float ringR = saturate(u.beatPhase) * 1.2;
        float ring = exp(-pow((r - ringR) / 0.10, 2.0)) * (1.0 - saturate(u.beatPhase));
        float seamL = exp(-edge * 260.0) + 0.45 * fold * exp(-sector2 * 480.0);
        vec3 seamC = mix(PLPAL((h1 < 0.5 ? 0.26 : 0.80) + 0.1 * h2 + hueOff),
                         plSpectrum(fract(0.55 + 0.4 * h2 + 2.0 * hueOff)) * 1.2, 0.5) * 1.5;
        lensCol += seamC * seamL * glints * (0.38 + 0.06 * u.level + 0.05 * ring + 0.1 * chase) * (1.0 - rimB);
        lensCol += vec3(1.5) * seamL * (g + g2) * glints;

        // twinkling star sparkles on a few shards, brighter with the treble
        float tw = hash21(best + 9.1);
        if (tw > 0.80) {
            vec2 so = -bestO;
            float sl = length(so);
            float ph = sin(6.2831853 * (tw * 7.0 + t * (0.25 + 0.3 * tw)));
            float spark = (exp(-sl * 40.0) + exp(-abs(so.x) * 90.0 - abs(so.y) * 9.0)
                         + exp(-abs(so.y) * 90.0 - abs(so.x) * 9.0)) * smoothstep(0.35, 0.1, sl);
            lensCol += peakWhite(PLPAL(hk + 0.5), 0.5) * 2.0 * spark * glints * saturate(ph) * (0.45 + 0.08 * u.level);
        }

        // a hairline of light where the glass meets the air
        lensCol += mix(vec3(1.7), accent * 2.0, 0.6) * exp(-(1.0 - r) * 220.0) * 0.45;

        // coloured gels: cool from the upper left, warm from the lower right
        vec3 gel = mix(PLPAL(hueOff + 0.26), PLPAL(hueOff + 0.80), smoothstep(-0.9, 0.9, q.x + 0.6 * q.y));
        lensCol *= mix(vec3(1.0), gel * 1.5, 0.22);
        col = mix(col, lensCol, inside);
    }

    // anamorphic streak through the brightest parts of the photo
    int nh = osSteps(4.0, 12.0, detail);
    float streak = 0.0;
    for (int i = 0; i < 12; i++) {
        if (i >= nh) break;
        float fi = (float(i) + 0.5) / float(nh);
        float ox = (fi * 2.0 - 1.0) * 0.32;
        float l = luma(plPhoto(vec2(uv.x + ox, uv.y), u));
        streak += smoothstep(0.75, 1.0, l) * (1.0 - abs(fi * 2.0 - 1.0));
    }
    streak /= float(nh);
    col += mix(PLPAL(hueOff + 0.26), vec3(1.0), 0.25) * streak * (0.8 + 0.08 * u.level);

    // out-of-focus motes drifting up in front of everything, lit by the spectrum
    float dm = mod(0.03 * u.time, 100.0);
    int nl = detail > 0.5 ? 2 : 1;
    for (int L = 0; L < 2; L++) {
        if (L >= nl) break;
        float fL = float(L);
        float sc = 3.0 + 2.5 * fL;
        vec2 mp = p * sc + vec2(0.3 * sin(t * 0.05 + fL), dm * 0.3 * (1.0 + fL));
        vec2 mc = floor(mp);
        vec2 mf = mp - mc;
        vec2 mid = vec2(mc.x, mod(mc.y, 30.0)) + fL * 17.0;
        float mh = hash21(mid);
        if (mh > 0.70) {
            vec2 mo = hash22(mid + 2.0);
            float mr = 0.08 + 0.26 * mo.x * mo.x;
            float md = length(mf - 0.5 - (mo - 0.5) * 0.5) / mr;
            float disc = smoothstep(1.0, 0.85, md) * (0.6 + 0.4 * smoothstep(0.5, 0.95, md));
            vec3 mcol = PLPAL(hueOff + (mo.y < 0.5 ? 0.26 : 0.80));
            col += mcol * disc * (0.15 + 0.03 * u.level + 0.03 * bandAt(u, 0.3 + 0.7 * mh)) * (0.6 - 0.25 * fL);
        }
    }

    // vignette keeps the corners deep
    col *= 1.0 - 0.60 * smoothstep(0.8, 2.0, length(p));
    // keep the deepest reds just off pure saturated red, so the crimson shards
    // can change without a red flash: after the filmic tonemap green plus blue
    // stay at least 0.28 of red (the toe crushes them, so lift them through it)
    vec3 tmc = plFilmic(col);
    float lift = max(0.28 * tmc.r - tmc.g - tmc.b, 0.0) * 0.5;
    if (lift > 0.0) {
        col.g = plFilmicInv(tmc.g + lift);
        col.b = plFilmicInv(tmc.b + lift);
    }
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
