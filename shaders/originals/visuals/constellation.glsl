// SPDX-License-Identifier: AGPL-3.0-only
// Constellation.
// A slow drift through a deep star cluster drawn as a living star chart.
// Stars sit on stacked depth sheets that stream past with true parallax: far
// sheets glitter finely, near ones swim by large and soft as out-of-focus
// bokeh, and in a burst the stars stretch into short streaks. Star colours
// follow temperature: blue-white, white and a few gold giants, the gold being
// the palette's own complement. On every beat a new set of constellation
// lines draws itself between the bright stars: a gold-hot spark races ahead,
// the line cools behind it to the figure's colour, and each star it reaches
// lights up inside a fine chart ring, the lines stopping short of the rings.
// Every sixteen beats a star goes nova: a gold flash with diffraction spikes,
// a shock ring that sweeps out across the sky, re-lighting every line and
// star it passes, and a light echo in the dust. Behind it all a dust lane
// glows magenta and blue. The drift follows the shared 32-beat speed profile
// and the roll eases to a new side every eight beats. Audio drives light
// only: the spectrum lights the stars, the beat draws the lines, bass sends
// pulses along them and treble makes the brightest stars flare.
// param0 = Drift Speed ; param1 = Link Density ; param2 = Pulse

const float CN_FOCUS = 2.0;    // depth of the focal plane
const float CN_NEAR = 0.35;    // depth of the nearest sheet
const float CN_FAR = 8.0;      // depth of the farthest sheet
const float CN_GRID = 0.6;     // bright-star cells per world unit
const float CN_DUST = 3.0;     // dust-star cells per bright-star cell

// The hue opposite c at the same lightness: the palette's own complement.
vec3 cnComp(vec3 c) {
    return vec3(max(max(c.r, c.g), c.b) + min(min(c.r, c.g), c.b)) - c;
}

// Bright star of a sheet cell: jittered inside the cell and slowly orbiting,
// never closer than 0.08 to the cell edge.
vec2 cnStar(vec2 cell, float key, float t) {
    vec2 h = hash22(cell * vec2(0.731, 1.37) + key * 3.17);
    vec2 w = vec2(sin(t * (0.21 + 0.3 * h.x) + h.y * 6.2832),
                  cos(t * (0.17 + 0.25 * h.y) + h.x * 6.2832));
    return cell + 0.5 + (h - 0.5) * 0.64 + w * 0.1;
}

// One of four band levels, chosen by a hash in [0,1).
float cnPick(vec4 b, float h) {
    vec4 k = step(vec4(0.0, 0.25, 0.5, 0.75), vec4(h)) - step(vec4(0.25, 0.5, 0.75, 2.0), vec4(h));
    return dot(b, k);
}

// Fractal noise with a detail-scaled octave count.
float cnFbm(vec2 p, int oct) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        if (i >= oct) break;
        v += a * vnoise(p);
        p = FBM_OCTAVE * p;
        a *= 0.5;
    }
    return v;
}

// Constellation figures live in blocks of 3x3 bright-star cells. Every eight
// beats a block may form a figure, starting on its own beat of the bar.
// Returns (beats since the figure began, 1 if it forms this cycle, hue key).
vec3 cnFigure(vec2 blk, float key, float dens, VisualUniforms u) {
    float hb = hash21(blk * vec2(0.37, 0.53) + key * 0.91 + 0.3);
    float n = floor(u.beatCount) + floor(hb * 8.0);
    float cyc = floor(n / 8.0);
    float lt = n - cyc * 8.0 + saturate(u.beatPhase);
    float on = step(hash21(vec2(hb * 31.0 + 0.7, mod(cyc, 97.0))), dens);
    return vec3(lt, on, hb);
}

// When the drawing reaches the star in cell c of its block: the figure grows
// outward from the corner the block's hash picks, 0.3 beats per step.
vec2 cnLocal(vec2 c, vec2 blk, float hb) {
    vec2 l = c - blk * 3.0;
    vec2 fl = step(0.5, fract(vec2(hb * 7.0, hb * 11.0)));
    return mix(l, 2.0 - l, fl);
}

// One constellation line from the star a in cell ca to its neighbour b in
// cell ca + dc, where dc is (1,0) or (0,1), so both cells agree on the link.
// Both cells lie in block blk, whose figure is fig. q is the pixel in sheet
// units, sc converts sheet units to screen units, gap is the chart-ring
// radius the line stops short of. Returns (line core, line glow, spark
// light, tip heat).
vec4 cnLink(vec2 q, vec2 a, vec2 b, vec2 ca, vec2 dc, vec2 blk, vec3 fig, float sc,
            float w, float gap, VisualUniforms u) {
    vec2 ba = b - a;
    float len2 = dot(ba, ba);
    float s = clamp(dot(q - a, ba) / max(len2, 1e-4), 0.0, 1.0);
    float d = length(q - a - ba * s) * sc;
    if (d > w * 6.0 + 0.006) return vec4(0.0);
    if (any(notEqual(floor((ca + dc) / 3.0), blk))) return vec4(0.0);
    // a figure is a tree: every star but the root joins the one parent its
    // hash picks, plus the odd extra link that closes a loop
    vec2 la = cnLocal(ca, blk, fig.z);
    vec2 lb = cnLocal(ca + dc, blk, fig.z);
    float dir = step(lb.x + lb.y, la.x + la.y);   // grow from the earlier end
    vec2 child = mix(ca + dc, ca, dir);
    vec2 lc = mix(lb, la, dir);
    float hc = hash21(child * vec2(0.613, 0.917) + fig.z * 9.0);
    float parentX = lc.y < 0.5 ? 1.0 : (lc.x < 0.5 ? 0.0 : step(0.5, hc));
    float keep = abs(dc.x - parentX) < 0.5 ? step(hc, 0.9) : step(fract(hc * 23.0), 0.12);
    if (keep <= 0.0) return vec4(0.0);
    float h = fract(hc * 7.0);
    float len = sqrt(len2);
    float lenFade = 1.0 - smoothstep(1.3, 1.75, len);
    float ta = (min(la.x + la.y, lb.x + lb.y)) * 0.3;
    float x = saturate((fig.x - ta) / 0.4);
    float grow = 1.0 - (1.0 - x) * (1.0 - x) * (1.0 - x);
    float fade = 1.0 - smoothstep(5.0, 8.0, fig.x);
    float sg = mix(s, 1.0 - s, dir);
    // the drawn part, its end antialiased over one line width
    float aw = w / max(len * sc, 1e-4);
    float drawn = 1.0 - smoothstep(grow - aw, grow + aw, sg);
    // a chart line stops short of the star rings at both ends
    float ends = min(s, 1.0 - s) * len * sc;
    float cut = smoothstep(gap, gap * 1.6, ends);

    float core = exp(-d * d / (w * w));
    float halo = exp(-d / (w * 2.5)) * 0.35;
    // bass pulse running along the held line
    float pp = fract(u.beatPhase + h * 0.3);
    float pulse = exp(-(sg - pp) * (sg - pp) * 60.0) * u.bassImpact;
    float line = drawn * fade * lenFade * cut * (0.6 + 2.4 * pulse);
    // the spark at the growing tip, fading as the line completes; the line is
    // hot just behind it and cools to the figure colour
    float ds = length(q - a - ba * mix(grow, 1.0 - grow, dir)) * sc;
    float sr = w * 1.6 + 0.002;
    float spark = exp(-ds * ds / (sr * sr)) * (1.0 - x) * step(0.001, x) * lenFade * 7.0;
    float heat = saturate(exp(-max(grow - sg, 0.0) * len * 3.0) * (1.0 - x * x) + pulse);
    return vec4(core * line, halo * line, spark, heat);
}

// A figure's colour: mostly blue, some magenta, the odd gold one.
vec3 cnFigCol(float h, vec3 b, vec3 m, vec3 g) {
    return h < 0.5 ? b : (h < 0.8 ? m : g);
}

// Star light at offset dq (screen units), radius r. Out of focus (blur > 0)
// the star opens into a flat bokeh disc with a bright rim.
float cnGlow(vec2 dq, float r, float blur) {
    float d = length(dq);
    float star = exp(-d * d / (r * r)) + exp(-d / (r * 3.0)) * 0.2;
    float br = r + blur;
    float disc = (1.0 - smoothstep(br * 0.86, br, d)) * (0.55 + 0.45 * smoothstep(br * 0.5, br * 0.95, d));
    float k = saturate(blur / (r * 2.0 + 1e-4) - 0.3);
    return mix(star, disc * r * r / (br * br) * 2.2, k);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float t = mod(u.time, 600.0);
    float px = 2.0 / max(u.resolution.y, 1.0);   // one pixel in screen units

    // the drift: the shared beat speed profile, an eased bank, a slow turn
    vec2 fl = osFlight(u, mix(0.5, 1.6, u.param0), 0.4 * mix(0.5, 1.5, u.param0));
    float travel = fl.x * 0.03;
    float rush = saturate((fl.y - 1.0) / 3.5);
    float roll = osBank(u, 0.22) + t * 0.01;
    p = rot2(roll) * p;
    p *= 1.0 + 0.10 * rush;   // a touch wider in a burst
    vec2 cam = vec2(sin(t * 0.061) * 1.6 + sin(t * 0.023) * 0.9,
                    cos(t * 0.047) * 1.1);

    float dens = mix(0.12, 0.6, u.param1);
    float pulseAmt = mix(0.4, 1.6, u.param2);

    // three hue families: the palette's blue and magenta, and the gold that
    // is the blue's complement
    vec3 cBlue = palVisual(0.80 + 0.05 * u.spectralCentroid, u);
    vec3 cPink = palVisual(0.60, u);
    vec3 cGold = cnComp(palVisual(0.80, u));
    vec3 white = vec3(1.0, 0.97, 0.94);

    // the nova: every sixteen beats a star flares at a fresh spot; its shock
    // ring sweeps out over the whole sky
    float hn = floor(u.beatCount / 16.0);
    float ha = mod(floor(u.beatCount), 16.0) + saturate(u.beatPhase);
    vec2 hp = (hash22(vec2(mod(hn, 251.0), 3.7)) - 0.5) * vec2(1.5, 0.9);
    vec2 dh = p - hp;
    float rh = length(dh);
    float hEnv = smoothstep(0.0, 0.06, ha) * exp(-ha * 0.42) * (0.75 + 0.5 * saturate(u.level + u.bassImpact));
    float hR = 0.03 + 1.6 * (1.0 - exp(-ha * 0.32));
    float hW = 0.007 + 0.006 * ha;
    float hx = (rh - hR) / hW;
    float hRing = exp(-hx * hx) * smoothstep(0.0, 0.1, ha) * exp(-ha * 0.55) * (0.007 / hW + 0.4);
    // the sweep re-lights what the ring passes, trailing a little behind it
    float hx2 = (rh - hR + hW * 1.5) / (hW * 3.0);
    float sweep = exp(-hx2 * hx2) * smoothstep(0.0, 0.1, ha) * exp(-ha * 0.2);

    // deep background: blue-black space and a two-tone dust lane
    vec2 bp = p * (1.0 + 0.12 * sin(t * 0.021)) + cam * 0.1 + vec2(t * 0.008, 0.0);
    vec2 lane = rot2(0.5) * bp;
    int oct = osSteps(2.0, 4.0, detail);
    vec2 warp = vec2(cnFbm(bp * 0.9 + 3.1, 2), cnFbm(bp * 0.9 + 7.7, 2));
    float dust = cnFbm(bp * 1.6 + warp * 1.4, oct);
    // ridged filaments along the warped flow, dark dust lanes across it
    float fil = 1.0 - abs(2.0 * dust - 1.0);
    fil = fil * fil * fil * fil;
    float lw = exp(-lane.y * lane.y * 1.1);
    float neb = lw * (0.12 * smoothstep(0.45, 0.85, dust) + 1.2 * fil * smoothstep(0.35, 0.65, warp.x));
    // dark absorbing lanes cut across both colours
    float lanes = 1.0 - 0.85 * smoothstep(0.52, 0.72, vnoise(bp * 2.3 + warp * 2.6)) * lw;
    vec3 col = vec3(0.0015, 0.0012, 0.006) + palVisual(0.2, u) * 0.025 * lw;
    // the dust is magenta on one side of the flow, blue on the other, and
    // warms toward magenta as a burst builds
    vec3 nebCol = mix(cPink, cBlue, smoothstep(0.38, 0.60, warp.y) * (1.0 - 0.5 * rush));
    col += nebCol * neb * 0.5 * (0.8 + 0.4 * u.level);
    // hot emission knots where the filaments bunch up
    col += mix(nebCol, white, 0.3) * neb * neb * neb * 1.4 * (0.7 + 0.5 * u.mid);
    // light echo: the nova lights the dust around it
    col += cGold * (neb + 0.03) * hEnv * (exp(-rh * 2.5) * 1.2 + sweep * 0.8);
    col *= lanes;

    float lineGain = (0.8 + 1.2 * u.level) * (0.7 + 0.3 * pulseAmt) * (1.0 + 2.5 * sweep);
    // four spectrum bands read once; stars pick one by hash
    vec4 bq = vec4(band(u, 1), band(u, 5), band(u, 9), band(u, 13));
    float rp = length(p);
    vec2 rdir = p / max(rp, 1e-3);

    int layers = osSteps(3.0, 5.0, detail);
    float nl = float(layers);
    for (int i = 0; i < 5; i++) {
        if (i >= layers) break;
        float fi = float(i);
        float lp = fi / nl - travel;
        float fr = fract(lp);
        float key = mod(floor(lp) * 13.0 + fi, 997.0);
        float z = mix(CN_NEAR, CN_FAR, fr);
        float vis = smoothstep(0.0, 0.12, fr) * (1.0 - smoothstep(0.65, 1.0, fr));
        if (vis <= 0.0) continue;
        float fog = exp(-z * 0.12) * vis;
        float blur = 0.012 * max(CN_FOCUS - z, 0.0) / z;

        // sheet coordinates: world = screen * depth + camera
        mat2 rk = rot2(key * 2.39996);
        vec2 q = rk * (p * z + cam) * CN_GRID + hash22(vec2(key, 5.1)) * 40.0;
        float sc = 1.0 / (z * CN_GRID);
        vec2 id = floor(q);
        vec2 blk = floor(id / 3.0);
        vec3 fig = cnFigure(blk, key, dens, u);
        float r = 0.0026 / z + 0.0012;
        // line width never under a pixel; wider lines carry the same light
        float wS = 0.0009 + 0.0014 / z;
        float w = max(wS + blur * 0.3, px * 0.75);
        // a defocused line spreads its light: dimmer and flatter, and the nova
        // sweep lifts mostly the sharp ones
        float fk = min(wS, 0.004) / w;
        float lineE = fk * fk * (1.0 + 2.5 * sweep * fk) / (1.0 + 2.5 * sweep);
        float ringR = r * 4.0 + 2.0 * px;
        float nearK = 1.0 / (1.0 + blur * 40.0);   // soft near lines stay quiet
        vec3 light = vec3(0.0);
        vec2 s0 = cnStar(id, key, t);
        if (fig.y > 0.0) {
            vec2 sx = cnStar(id + vec2(1.0, 0.0), key, t);
            vec2 sy = cnStar(id + vec2(0.0, 1.0), key, t);
            vec2 sxm = cnStar(id - vec2(1.0, 0.0), key, t);
            vec2 sym = cnStar(id - vec2(0.0, 1.0), key, t);
            vec4 l0 = cnLink(q, s0, sx, id, vec2(1.0, 0.0), blk, fig, sc, w, ringR, u);
            vec4 l1 = cnLink(q, s0, sy, id, vec2(0.0, 1.0), blk, fig, sc, w, ringR, u);
            vec4 l2 = cnLink(q, sxm, s0, id - vec2(1.0, 0.0), vec2(1.0, 0.0), blk, fig, sc, w, ringR, u);
            vec4 l3 = cnLink(q, sym, s0, id - vec2(0.0, 1.0), vec2(0.0, 1.0), blk, fig, sc, w, ringR, u);
            // the figure's own colour, gold where the nova sweep passes
            vec3 fc = mix(cnFigCol(fig.z, cBlue, cPink, cGold), cGold, saturate(sweep * 1.5));
            vec3 hot = mix(cGold, white, 0.35);
            vec4 core = vec4(l0.x, l1.x, l2.x, l3.x);
            vec4 heat = vec4(l0.w, l1.w, l2.w, l3.w);
            float cs = dot(core, vec4(1.0));
            float ch = dot(core, heat);
            float hs = dot(vec4(l0.y, l1.y, l2.y, l3.y), vec4(1.0));
            float hh = dot(vec4(l0.y, l1.y, l2.y, l3.y), heat);
            // white-hot core, saturated glow, both warming at the tip
            light = ((fc * 0.35 + 0.65) * (cs - ch) + (hot * 0.6 + 0.5) * ch
                     + (fc * (hs - hh) + cGold * hh) * 1.4)
                    * lineGain * lineE;
            light += (mix(cGold, white, 0.5) * 1.2) * (l0.z + l1.z + l2.z + l3.z) * nearK * nearK;
        }

        // the bright star of this cell: temperature-coloured, with a treble
        // flare on the biggest
        float hs = hash21(id * vec2(1.93, 0.71) + key * 2.3);
        float ht = fract(hs * 7.3);
        vec3 tint = ht < 0.55 ? mix(cBlue, white, 0.45) : (ht < 0.84 ? white * 0.9 : mix(cGold, white, 0.1));
        float lvl = 0.4 + 2.2 * cnPick(bq, hs);
        // stars of a forming figure light up as the line reaches them
        float lit = fig.y * smoothstep(0.0, 0.25, fig.x - (dot(cnLocal(id, blk, fig.z), vec2(1.0)) * 0.3)) *
                    (1.0 - smoothstep(5.0, 8.0, fig.x)) * (1.0 + 1.2 * u.bassImpact);
        lvl = (lvl + 1.6 * lit) * (1.0 + 2.0 * sweep);
        vec2 dq = (q - s0) * sc;
        // burst streaks: stretched along the screen-radial flow, which grows
        // with distance from the centre and nearness
        vec2 rq = rk * rdir;
        float str = 1.0 + rush * min(rp * 2.2 / z, 5.0);
        vec2 dqs = dq - rq * dot(dq, rq) * (1.0 - 1.0 / str);
        float sE = inversesqrt(str);
        float big = step(0.7, hs) * (1.0 + 2.0 * u.treble) * saturate(1.0 - blur * 80.0);
        float rf = max(r, px * 0.6);
        float flare = big * (exp(-abs(dq.x) / (r * 12.0) - abs(dq.y) / (rf * 0.4)) +
                             exp(-abs(dq.y) / (r * 12.0) - abs(dq.x) / (rf * 0.4))) * (r / rf);
        light += ((tint * 0.75 + 0.35) * cnGlow(dqs, r * 1.2, blur) * sE * (1.6 + 1.2 * step(0.7, hs))
                 + mix(tint, cBlue, 0.4) * flare * 0.8) * lvl;
        // a lit star sits in a fine chart ring of the figure's colour
        float dl = length(dq);
        float rw = max(px * 0.8, blur * 0.6);
        float rx = (dl - ringR) / rw;
        vec3 rc = mix(cnFigCol(fig.z, cBlue, cPink, cGold), white, 0.35);
        light += rc * (exp(-rx * rx) * (px * 0.8 / rw) * 0.9 + exp(-dl / (r * 6.0)) * 0.5) * lit
               // anamorphic streak across the lit stars
               + cPink * exp(-abs(dq.y) / max(r * 0.35, px * 0.5) - abs(dq.x) / (r * 45.0)) * lit * 0.6;

        // dust stars: a finer grid, most faint, a few bright
        vec2 qd = q * CN_DUST;
        vec2 dd = floor(qd);
        vec3 hd = vec3(hash22(dd + key * 0.37), hash21(dd * 1.37 + key));
        vec2 sd = dd + 0.25 + 0.5 * hd.xy;
        float rd = max(0.0016 / z + 0.0009, px * 0.55);
        float bd = hd.z * hd.z * hd.z * (0.6 + 1.6 * cnPick(bq, hd.x)) * (1.0 + 1.5 * sweep);
        vec2 dqd = (qd - sd) * sc / CN_DUST;
        dqd -= rq * dot(dqd, rq) * (1.0 - 1.0 / str);
        vec3 dTint = fract(hd.x * 13.0) < 0.18 ? mix(cGold, white, 0.4) : mix(white, cBlue, 0.35);
        light += dTint * cnGlow(dqd, rd, blur * 0.8) * bd * sE * 2.2;

        col += light * fog;
    }

    // the nova itself: a gold-white core, four diffraction spikes and the
    // shock ring, warming to magenta as it spreads
    vec2 da = rot2(0.35 + hn * 0.9) * dh;
    vec2 aa = abs(da);
    float spikes = exp(-aa.y / (0.0016 + 0.012 * aa.x) - aa.x * 3.0) + exp(-aa.x / (0.0016 + 0.012 * aa.y) - aa.y * 3.0);
    float nCore = exp(-rh * rh / 0.00025) * 4.0 + exp(-rh / 0.03) * 0.6;
    col += (mix(cGold, white, 0.55) * nCore + mix(cGold, cBlue, 0.25) * spikes * 0.9) * hEnv * (1.0 + 0.5 * u.treble);
    col += mix(mix(cGold, white, 0.3), cPink, saturate(ha / 6.0)) * hRing * 0.5;

    // the beat lifts the dust lane a little, never the frame
    col += palRolePeak(0.6, u) * neb * 0.06 * u.bassImpact * pulseAmt;
    return col; // LINEAR HDR — post chain tonemaps
}
