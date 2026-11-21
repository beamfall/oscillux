// SPDX-License-Identifier: AGPL-3.0-only
// Circuit.
// A low fly-over of a circuit board seen as a night city. Chips, capacitor
// clusters and finned heat-sink towers stand in blocks between avenues of
// neon and bare-copper bus traces. Data packets stream along the traces, the
// chip tops twinkle like lit office windows, and uplink beams rise from the
// skyline. Every beat sends a faint copper or ice-blue diamond ripple across
// the board that warms the traces it passes. The glossy solder mask mirrors
// the towers. The camera glides at a slow steady pace with a gentle sway, and
// packets, windows and uplink bursts move unhurriedly, so no bright structure
// sweeps fast over the dark board. The light follows the music's smoothed
// level with only a small spectrum term and no beat flashes; reds are kept
// just off saturated red. Its colours come from its own palette, unnudged by
// beat or centroid, so the host's vivid palette tour never swells the light.
// param0 = Scale (board size under the camera) ; param1 = Pulse Speed ; param2 = Trace Brightness

const float CI_C = 4.0;    // block pitch
const float CI_TOP = 2.7;  // tallest component

// avenue (x) and street (z) centre-lines run along the block boundaries
float ciPath(float z) { return 2.0 * sin(z * 0.023) + 1.2 * sin(z * 0.051 + 0.7); }

// Distance to the component standing in a block. l is block-local, board at y = 0.
float ciComp(vec3 l, float h, float h2) {
    if (h < 0.40) {
        // flat chip package
        vec3 b = vec3(0.8 + 0.5 * h2, 0.09 + 0.12 * fract(h2 * 7.0), 0.8 + 0.5 * fract(h2 * 3.3));
        return osBox(l - vec3(0.0, b.y, 0.0), b - 0.02) - 0.02;
    }
    if (h < 0.60) {
        // capacitor cluster: four cylinders
        vec2 s = vec2(l.x < 0.0 ? -1.0 : 1.0, l.z < 0.0 ? -1.0 : 1.0);
        vec2 c = l.xz - s * 0.78;
        float ht = 0.6 + 1.3 * hash21(s + h2 * 11.0);
        float dr = length(c) - 0.58;
        float dy = abs(l.y - ht * 0.5) - ht * 0.5;
        float d = min(max(dr, dy), 0.0) + length(max(vec2(dr, dy), 0.0)) - 0.03;
        // the quadrant split bounds the step so a neighbour is never jumped
        return min(d, min(abs(l.x), abs(l.z)) + 0.2);
    }
    if (h < 0.80) {
        // finned heat-sink tower
        float ht = 1.1 + 1.5 * h2;
        float base = osBox(l - vec3(0.0, 0.12, 0.0), vec3(1.35, 0.12, 1.35));
        float fx = l.x - (floor(l.x / 0.27) + 0.5) * 0.27;
        float fins = max(osBox(l - vec3(0.0, ht * 0.5, 0.0), vec3(1.2, ht * 0.5, 1.2)), abs(fx) - 0.05);
        return min(base, fins);
    }
    // field of small surface-mount parts
    vec2 sc = floor(l.xz / 0.6);
    vec2 sq = l.xz - (sc + 0.5) * 0.6;
    float sh = hash21(sc + h * 17.0);
    if (max(abs(l.x), abs(l.z)) > 1.5 || sh < 0.3) return 0.3 - max(abs(sq.x), abs(sq.y)) + 0.12;
    vec3 b = sh > 0.65 ? vec3(0.18, 0.06, 0.09) : vec3(0.09, 0.05 + 0.08 * sh, 0.18);
    float d = osBox(vec3(sq.x, l.y - b.y, sq.y), b);
    return min(d, 0.3 - max(abs(sq.x), abs(sq.y)) + 0.12);
}

float ciMap(vec3 p) {
    vec2 cell = floor(p.xz / CI_C);
    vec2 l2 = p.xz - (cell + 0.5) * CI_C;
    float h = hash21(cell + 0.37);
    float h2 = hash21(cell * 1.7 + 5.1);
    float d = ciComp(vec3(l2.x, p.y, l2.y), h, h2);
    // components keep 0.5 from the block edge, so the edge bounds the step
    vec2 e = 0.5 * CI_C - abs(l2);
    return min(d, min(e.x, e.y) + 0.5);
}

vec3 ciNormal(vec3 p) {
    vec2 e = vec2(0.002, 0.0);
    return normalize(vec3(ciMap(p + e.xyy) - ciMap(p - e.xyy),
                          ciMap(p + e.yxy) - ciMap(p - e.yxy),
                          ciMap(p + e.yyx) - ciMap(p - e.yyx)) + 1e-6);
}

// March the components inside their slab; -1 means the ray left the slab or
// reached tmax (the board plane) first.
float ciMarch(vec3 ro, vec3 rd, float tmax, int n) {
    float t = 0.0;
    if (ro.y > CI_TOP) {
        if (rd.y > -1e-3) return -1.0;
        t = (ro.y - CI_TOP) / -rd.y;
    }
    for (int i = 0; i < 140; i++) {
        if (i >= n) break;
        vec3 p = ro + rd * t;
        float d = ciMap(p);
        if (d < 0.0015 * (1.0 + t)) return t;
        t += d * 0.9;
        if (t > tmax || p.y < 0.0 || (p.y > CI_TOP + 0.01 && rd.y > 0.0)) break;
    }
    return -1.0;
}

// The palette read: the visual's own palette with no beat or spectral nudge.
vec3 ciPal(float t, VisualUniforms u) { return osPalCalm(t, 23, u); }

// Keeps every red just off saturated red once tonemapped.
float ciTone(float x) { return x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14); }
float ciToneInv(float y) {
    y = clamp(y, 0.0, 0.999);
    float a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y;
    return (-b + sqrt(b * b + 0.56 * a * y)) / (2.0 * a);
}
vec3 ciOffRed(vec3 c) {
    float r = ciTone(c.r), g = ciTone(c.g), b = ciTone(c.b);
    float need = 0.3 * r - g - b;
    if (need <= 0.0) return c;
    if (c.g > c.b) c.g = max(c.g, ciToneInv(g + need));
    else c.b = max(c.b, ciToneInv(b + need));
    return c;
}

// Palette colours, band levels and beat terms, computed once per pixel.
struct CiK {
    vec3 tA, tB, tre, pA, pB, key, glow, bass, mask, albA, albB, top, hot, cool;
    vec4 bA, bB;
    float wPh, wAmp, pulse, tm, bassE, beat, par;
};

CiK ciKMake(VisualUniforms u) {
    CiK k;
    k.tA = ciPal(0.55, u);
    k.tB = ciPal(0.95, u);
    k.tre = ciPal(0.3, u);
    k.pA = ciPal(0.6, u);
    k.pB = ciPal(0.95, u);
    k.glow = ciPal(0.35, u);
    // warm key from the right, cool palette rim from the left
    k.key = mix(vec3(1.0, 0.72, 0.48), ciPal(0.75, u), 0.3) * 0.1;
    k.bass = ciPal(0.4, u);
    k.mask = ciPal(0.2, u) * 0.006;
    k.albA = ciPal(0.5, u);
    k.albB = ciPal(0.9, u);
    k.top = ciPal(0.02, u);
    // bare copper: the board's own material, the warm counterpart to the neon
    k.hot = vec3(1.0, 0.45, 0.13);
    // its complement: an ice-blue charge tinted by the palette; beat waves
    // alternate between the two
    k.cool = mix(vec3(0.16, 0.55, 1.0), k.pB, 0.3);
    k.par = mod(floor(u.beatCount), 2.0);
    // band levels ride on the smoothed level; the spectrum only tints them
    float lv = 0.22 * saturate(u.level);
    k.bA = lv + 0.05 * vec4(band(u, 2), band(u, 6), band(u, 10), band(u, 16));
    k.bB = lv + 0.05 * vec4(band(u, 24), band(u, 32), band(u, 42), band(u, 54));
    k.wPh = saturate(u.beatPhase);
    k.wAmp = 0.005;
    k.pulse = mix(0.4, 1.2, u.param1);
    k.tm = mod(u.time, 600.0);
    k.bassE = 0.0;
    k.beat = 0.0;
    return k;
}

// A band level picked by a hash: linear blend across eight anchor bands.
float ciLv(CiK k, float h) {
    float x = h * 7.0;
    return dot(max(1.0 - abs(x - vec4(0.0, 1.0, 2.0, 3.0)), 0.0), k.bA)
         + dot(max(1.0 - abs(x - vec4(4.0, 5.0, 6.0, 7.0)), 0.0), k.bB);
}

// Two diamond waves per beat, the current and the fading previous one, so
// nothing pops when the beat rolls over. x = molten front, y = neon wake.
// Even beats send molten copper, odd beats an ice-blue charge: z is the
// copper share of the front, so ciWaveCol never pops at the rollover.
vec3 ciWave(vec2 xz, vec2 src, CiK k) {
    float m = abs(xz.x - src.x) + abs(xz.y - src.y);
    vec3 w = vec3(0.0);
    for (int i = 0; i < 2; i++) {
        float age = k.wPh + float(i);
        float x = m - (1.5 + 18.0 * age);
        // white-hot as it leaves the source, then a steady glow; a function of
        // age alone, so the rollover stays seamless
        float fade = exp(-age * 1.25) * (0.45 + 0.25 * exp(-age * 3.0));
        float f = (x < 0.0 ? exp(x * 1.8) : exp(-x * x * 1.6)) * fade;
        w.x += f;
        w.y += (x < 0.0 ? exp(x * 0.22) * 0.55 : 0.0) * fade;
        w.z += (f + 1e-4) * (i == 0 ? 1.0 - k.par : k.par);
    }
    return vec3(w.xy * k.wAmp, w.z / (w.x + 2e-4));
}

vec3 ciWaveCol(vec3 w, CiK k) { return mix(k.cool * 1.3, k.hot, w.z); }

// Anti-aliased line with an analytic footprint fp in the units of d, so no
// derivatives are taken inside branches.
float ciLine(float d, float hw, float fp) {
    return 1.0 - smoothstep(hw - fp, hw + fp, abs(d));
}

// Repeating line of period 1 centred at phase 0.5; it fades to its mean
// coverage as the period shrinks toward a pixel, so distant buses never shimmer.
float ciLines(float ph, float hw, float fp) {
    float l = ciLine(fract(ph) - 0.5, hw, fp);
    return mix(l, 2.0 * hw, smoothstep(0.2, 0.55, fp));
}

// Emission of the board: bus traces, fan-outs, vias, pads, silkscreen.
// fp is the pixel footprint (x across, y along the view). copper receives
// the copper coverage for the gloss.
vec3 ciBoard(vec2 xz, vec2 src, vec2 fp, CiK k, float detail, out float copper) {
    vec2 cell = floor(xz / CI_C);
    vec2 l = xz - (cell + 0.5) * CI_C;
    float h = hash21(cell + 0.37);
    float h2 = hash21(cell * 1.7 + 5.1);
    vec3 wv = ciWave(xz, src, k);
    vec3 wcl = ciWaveCol(wv, k);
    float tm = k.tm;

    vec3 col = vec3(0.0);
    copper = 0.0;

    // avenue bus: ten traces along z on each block boundary
    float s = xz.x - floor(xz.x / CI_C + 0.5) * CI_C;
    if (abs(s) < 0.55) {
        float li = floor(s / 0.1);
        float lid = li + 40.0 * floor(xz.x / CI_C + 0.5);
        float on = step(0.18, hash11(lid * 1.37 + 3.0));
        float seg = step(0.12, hash21(vec2(lid, floor(xz.y / 9.0 + hash11(lid)))));
        float dir = hash11(lid * 3.1) < 0.5 ? -1.0 : 1.0;
        float spd = k.pulse * (0.6 + 0.8 * hash11(lid * 5.7));
        float ph = fract((xz.y * dir - tm * spd) / 11.0 + hash11(lid * 9.3));
        float head = exp(-ph * 8.0) * 0.7 + exp(-ph * 3.0) * 0.3 + exp(-(1.0 - ph) * 30.0) * 0.3;
        // a packet swells its trace, so it reads at a distance
        float line = ciLines(s / 0.1, 0.17 + 0.12 * saturate(head * 0.3), fp.x / 0.1) * on * seg * step(abs(s), 0.5);
        float hc = hash11(lid * 2.3);
        float bi = ciLv(k, hash11(lid * 7.9));
        // one trace in four is bare copper, the rest carry the palette's neon
        vec3 tc = hc < 0.25 ? k.hot * 0.8 : mix(k.tA, k.tB, (hc - 0.25) * 1.33);
        col += line * (tc * (0.12 + 0.6 * bi + head * (0.4 + bi) + 3.0 * wv.y) + wcl * wv.x * 7.0);
        // soft halo the lit bus throws on the solder mask
        float halo = exp(-abs(s) * 4.0);
        col += halo * (tc * (0.04 + 0.2 * head * on * seg + 0.3 * wv.y) + wcl * wv.x * 0.5);
        copper += line;
    }
    // street bus: six traces along x
    float sz = xz.y - floor(xz.y / CI_C + 0.5) * CI_C;
    if (abs(sz) < 0.32 && abs(s) > 0.6) {
        float li = floor(sz / 0.1);
        float lid = li + 23.0 * floor(xz.y / CI_C + 0.5) + 7.0 * cell.x;
        float line = ciLines(sz / 0.1, 0.15, fp.y / 0.1) * step(0.25, hash11(lid * 1.9 + 1.0));
        float ph = fract((xz.x - tm * k.pulse * 0.7) / 6.0 + hash11(lid * 4.1));
        float head = exp(-ph * 8.0) * 0.5;
        col += line * (k.tre * (0.08 + head * 0.6 + 4.0 * wv.y) + wcl * wv.x * 6.0);
        copper += line;
    }
    // block interior: pads, fan-out traces, vias and silkscreen
    float inner = 0.5 * CI_C - 0.6;
    if (max(abs(l.x), abs(l.y)) < inner) {
        vec3 accent = mix(k.pA, k.pB, h);
        float wsum = wv.x * 2.0 + wv.y;
        if (h < 0.40) {
            vec2 b = vec2(0.8 + 0.5 * h2, 0.8 + 0.5 * fract(h2 * 3.3));
            // fan-out along x from the chip's x-facing pins to the avenue bus
            float ex = abs(l.x) - b.x;
            if (ex > 0.0) {
                float t = saturate(ex / (inner - b.x));
                float squeeze = mix(1.0, 0.45, smoothstep(0.15, 0.7, t));
                float zz = l.y / squeeze;
                float fz = fp.y / (0.14 * squeeze);
                float inside = step(abs(zz), b.y - 0.08);
                float line = ciLines(zz / 0.14 + 0.5, 0.16, fz) * inside;
                float pad = step(ex, 0.18) * ciLines(zz / 0.14 + 0.5, 0.3, fz) * inside;
                float lane = floor(zz / 0.14);
                float flow = exp(-fract(t * 1.5 - tm * k.pulse * 0.1 + hash21(vec2(lane, cell.x + cell.y * 7.0))) * 7.0);
                col += accent * (line * (0.08 + 1.4 * wsum + 0.9 * flow * (0.3 + ciLv(k, fract(lane * 0.37 + 0.5)))) + pad * 0.15);
                col += wcl * pad * wv.x * 2.0;
                copper += max(line, pad);
            }
            float ez = abs(l.y) - b.y;
            if (ez > 0.0 && ez < 0.18) {
                float pad = ciLines(l.x / 0.14 + 0.5, 0.3, fp.x / 0.14) * step(abs(l.x), b.x - 0.08);
                col += (accent * 0.12 + wcl * wv.x * 2.0) * pad;
                copper += pad;
            }
            // silkscreen outline
            vec2 o = abs(l) - b - 0.32;
            col += vec3(0.06) * ciLine(max(o.x, o.y), 0.012, fp.y);
        } else {
            // via field
            vec2 vc = floor(l / 0.25);
            vec2 vq = l - (vc + 0.5) * 0.25;
            float vh = hash21(vc + cell * 3.3);
            float ring = ciLine(length(vq) - 0.055, 0.018, fp.y) * step(0.82, vh) * (1.0 - smoothstep(0.03, 0.08, fp.y));
            col += ring * (accent * (0.2 + wsum * 1.8 + 0.8 * ciLv(k, vh)) + wcl * wv.x * 2.0);
            copper += ring;
        }
    }
    // the molten front itself sweeps across the solder mask
    col += wcl * wv.x * 0.22;
    // faint copper-pour hatch fills the gaps
    float hatch = ciLines((xz.x + xz.y) / 0.18, 0.08, (fp.x + fp.y) / 0.18);
    col += k.glow * hatch * 0.01 * detail;
    return col;
}

// Night sky over the board: a near-black zenith, a palette haze on the
// horizon over a thin seam of the current wave colour.
vec3 ciSky(vec3 rd, CiK k) {
    float h = rd.y;
    float ah = abs(h);
    vec3 col = vec3(0.0006, 0.0008, 0.002) + k.glow * 0.03 * exp(-ah * 6.0);
    col += k.top * 0.025 * smoothstep(0.0, 0.5, h) * exp(-h * 2.0);
    col += k.bass * exp(-ah * 26.0) * (0.22 + 0.25 * k.bassE);
    col += mix(k.cool, k.hot, 0.5) * exp(-ah * 110.0) * (0.08 + 0.25 * k.bassE);
    return col;
}

// Uplink pillars: in some 4x4 super-blocks one block sends a column of light
// straight up. Each pillar sits on a block centre clear of the flight line.
const float CI_P = 16.0;
vec4 ciPil(vec2 c) {
    float hp = hash21(c * 0.71 + 2.3);
    vec2 bi = floor(vec2(hash21(c + 9.1), hash21(c + 4.7)) * 3.999);
    vec2 pp = c * CI_P + (bi + 0.5) * CI_C;
    float on = step(hp, 0.55) * step(3.0, abs(pp.x - ciPath(pp.y)));
    return vec4(pp, on, hp);
}

// Colour and strength of a pillar: copper or ice by its hash, metered by a
// band, with the beat's accent colour on top.
vec4 ciPilLight(float hp, CiK k) {
    float lv = ciLv(k, fract(hp * 5.3));
    vec3 c = fract(hp * 7.7) < 0.4 ? k.hot : mix(k.tA, k.cool, fract(hp * 3.1));
    vec3 acc = mix(k.hot, k.cool, k.par);
    return vec4(c * (0.35 + 1.2 * lv) + acc * k.beat * 0.0, lv);
}

// Glow of the pillars along the ray up to tEnd, walking the super-block grid.
// The ray-to-column distance is horizontal, and the core widens to the
// pixel footprint so far pillars stay thin without shimmering.
vec3 ciPillars(vec3 ro, vec3 rd, float tEnd, CiK k, float pixk, int n) {
    vec2 d = rd.xz;
    float a = dot(d, d);
    if (a < 1e-6) return vec3(0.0);
    vec2 s = vec2(d.x >= 0.0 ? 1.0 : -1.0, d.y >= 0.0 ? 1.0 : -1.0);
    vec2 c = floor(ro.xz / CI_P);
    vec2 ad = max(abs(d), vec2(1e-4));
    vec2 tN = ((c + max(s, 0.0)) * CI_P - ro.xz) * s / ad;
    vec2 tD = CI_P / ad;
    vec3 col = vec3(0.0);
    for (int i = 0; i < 12; i++) {
        if (i >= n) break;
        vec4 pl = ciPil(c);
        if (pl.z > 0.5) {
            vec2 q = ro.xz - pl.xy;
            float tc = clamp(-dot(q, d) / a, 0.0, tEnd);
            vec2 w = q + d * tc;
            float r2 = dot(w, w);
            float y = ro.y + rd.y * tc;
            float fw = 0.012 + (tc * pixk) * (tc * pixk);
            float core = 0.012 / (r2 + fw) + 0.25 * exp(-r2 * 1.2);
            // data bursts climb the column
            float ph = fract(y * 0.05 - k.tm * (0.08 + 0.06 * pl.w) + pl.w * 7.0);
            float pk = exp(-ph * 4.0) * 0.4;
            float hf = exp(-max(y - 0.3, 0.0) * 0.1) * smoothstep(0.1, 0.5, y) * smoothstep(2.0, 1.2, sqrt(r2));
            vec4 lt = ciPilLight(pl.w, k);
            col += lt.rgb * core * hf * (1.0 + pk * (0.4 + lt.w)) * exp(-tc * 0.014) * smoothstep(2.0, 8.0, tc);
        }
        float tn = min(tN.x, tN.y);
        if (tn > tEnd) break;
        if (tN.x < tN.y) { tN.x += tD.x; c.x += s.x; } else { tN.y += tD.y; c.y += s.y; }
    }
    return col;
}

// Light the nearest pillar throws on the board and the parts around it.
vec3 ciPool(vec3 pos, CiK k) {
    vec4 pl = ciPil(floor(pos.xz / CI_P));
    vec2 q = pos.xz - pl.xy;
    return ciPilLight(pl.w, k).rgb * pl.z * exp(-dot(q, q) * 0.3) * 0.5 * exp(-max(pos.y, 0.0) * 0.4);
}

// Light a component surface: key light, underglow from the traces, emissive
// crowns and windows. fpw is the pixel footprint in world units.
vec3 ciShade(vec3 pos, vec3 n, vec3 rd, vec2 src, CiK k, float bright, float fpw) {
    vec2 cell = floor(pos.xz / CI_C);
    vec2 l = pos.xz - (cell + 0.5) * CI_C;
    float h = hash21(cell + 0.37);
    float h2 = hash21(cell * 1.7 + 5.1);
    vec3 L = vec3(-0.44667, 0.49629, 0.74444);
    float dif = saturate(dot(n, L));
    vec3 R = reflect(rd, n);
    float spec = pow(saturate(dot(R, L)), 48.0);
    float fres = 0.04 + 0.96 * pow(1.0 - saturate(dot(n, -rd)), 5.0);
    float top = step(0.5, n.y);

    // black epoxy by default; metal tints its highlights
    vec3 alb = vec3(0.008);
    vec3 tint = vec3(1.0);
    float gloss = 0.9;
    vec3 em = vec3(0.0);
    vec3 accent = mix(k.pA, k.pB, h);
    float lvl = ciLv(k, fract(h * 3.7 + h2));
    if (h < 0.40) {
        // chip top: glowing inset groove, a status light, a grid of lit windows
        vec2 b = vec2(0.8 + 0.5 * h2, 0.8 + 0.5 * fract(h2 * 3.3));
        vec2 o = abs(l) - b + 0.16;
        float groove = ciLine(max(o.x, o.y), 0.025, max(0.01, fpw)) * top;
        em += accent * groove * (0.8 + 4.0 * lvl) * bright;
        float dot0 = length(l - (b - 0.3) * vec2(-1.0, 1.0));
        em += k.tre * top * exp(-dot0 * dot0 * 600.0) * (2.0 + 6.0 * k.beat);
        if (top > 0.5 && max(o.x, o.y) < -0.12) {
            vec2 g = l / 0.13;
            vec2 wc = floor(g);
            vec2 wq = g - wc - 0.5;
            float wh = hash21(wc + cell * 7.3);
            // each window cross-fades to a new state, so none of them pops
            float st = k.tm * (0.05 + 0.08 * wh) + wh * 9.0;
            float a0 = hash21(wc + floor(st) * 1.31 + cell);
            float a1 = hash21(wc + (floor(st) + 1.0) * 1.31 + cell);
            float on = smoothstep(0.5, 0.8, mix(a0, a1, smoothstep(0.0, 1.0, fract(st))));
            float fq = fpw / 0.13;
            float cov = 1.0 - smoothstep(0.3 - fq, 0.3 + fq, max(abs(wq.x), abs(wq.y)));
            cov = mix(cov, 0.36, smoothstep(0.25, 0.6, fq));
            vec3 wcol = fract(wh * 11.0) < 0.3 ? k.hot : mix(k.tre, accent, fract(wh * 5.0));
            em += wcol * on * cov * (0.2 + 1.8 * ciLv(k, fract(wh * 3.3))) * bright;
        }
        // pin row on the sides
        float pins = (1.0 - top) * step(pos.y, 0.07) * ciLines((abs(n.x) > 0.5 ? l.y : l.x) / 0.14 + 0.5, 0.2, max(0.05, fpw / 0.14));
        alb = mix(alb, vec3(0.6), pins);
    } else if (h < 0.60) {
        // capacitor: tinted sleeve, metal top with a lit rim that meters its band
        vec2 s = vec2(l.x < 0.0 ? -1.0 : 1.0, l.y < 0.0 ? -1.0 : 1.0);
        float ht = 0.6 + 1.3 * hash21(s + h2 * 11.0);
        float q = hash21(s + cell);
        // deep lacquered sleeve in the palette, brushed aluminium top
        alb = mix(k.albA, k.albB, q) * 0.11;
        float r = length(l - s * 0.78);
        // the top's pressure-vent cross is scored into the aluminium
        vec2 cq = abs(l - s * 0.78);
        float score = ciLine(min(cq.x, cq.y), 0.014, max(0.01, fpw)) * step(r, 0.4);
        alb = mix(alb, vec3(0.07, 0.075, 0.085) * (1.0 - 0.8 * score), top);
        tint = mix(vec3(1.0), vec3(0.8, 0.88, 1.0), top);
        float lv = ciLv(k, q);
        em += accent * top * ciLine(r - 0.47, 0.035, max(0.01, fpw)) * (1.0 + 5.0 * lv) * bright;
        em += accent * (1.0 - top) * exp(-abs(pos.y - ht + 0.1) * 40.0) * (0.3 + 2.5 * lv) * bright;
        gloss = 1.0;
    } else if (h < 0.80) {
        // heat sink: bare-copper or gunmetal fins with a lit crown that
        // brightens on the beat
        float ht = 1.1 + 1.5 * h2;
        bool cu = fract(h2 * 5.3) < 0.5;
        alb = cu ? k.hot * vec3(0.05, 0.035, 0.03) : vec3(0.012, 0.013, 0.016);
        tint = cu ? vec3(1.0, 0.55, 0.3) : vec3(0.75, 0.8, 1.0);
        // distant fins fold into one face, so their facets do not shimmer
        float far = saturate(fpw * 12.0);
        gloss = 0.8 * (1.0 - 0.6 * far);
        float crown = exp(-max(ht - pos.y, 0.0) * 28.0) * step(0.3, pos.y) * (1.0 - top * 0.93);
        em += (cu ? k.hot : accent) * crown * (0.4 + 1.2 * k.bassE + 2.0 * lvl) * bright;
    } else {
        alb = vec3(0.03);
    }
    // the beat wave flares a block's lights as it passes
    vec3 wc = ciWave((cell + 0.5) * CI_C, src, k);
    em *= 1.0 + 1.2 * wc.x + 1.5 * wc.y;
    // and the wave front rakes the towers' flanks from below
    vec3 wp = ciWave(pos.xz, src, k);
    vec3 wcol = ciWaveCol(wp, k);
    float side = 1.0 - abs(n.y);
    em += wcol * wp.x * side * exp(-pos.y * 1.2) * 0.9 * bright;
    // glossy reflection: the horizon haze above, the lit board below
    vec3 env = R.y > 0.0 ? k.glow * 0.22 * exp(-R.y * 5.0) + k.bass * 0.3 * exp(-R.y * 22.0)
                         : (k.tA * (0.05 + 0.12 * k.bA.y) + wcol * wp.x * 0.5) * exp(R.y * 2.0);
    vec3 under = mix(k.tA, k.hot, 0.35) * exp(-pos.y * 3.0) * side * 0.06 * bright;
    vec3 pool = ciPool(pos, k) * (0.4 + side);
    vec3 col = alb * (k.key * dif * 4.0 + 0.02) + k.key * tint * spec * gloss * 2.5
             + env * tint * fres * gloss + under + pool * (alb * 20.0 + 0.1) + em;
    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float bright = mix(0.5, 1.7, u.param2);
    CiK k = ciKMake(u);

    float speed = mix(3.5, 9.5, u.param1);
    // a slow steady glide: no beat-timed surge or brake
    float z = u.time * speed * 0.05;
    float rush = 0.0;
    float lull = 0.0;
    float alt = mix(3.4, 6.0, u.param0) + 0.4 * sin(u.time * 0.21);
    vec3 ro = vec3(ciPath(z), alt, z);
    vec3 ta = vec3(ciPath(z + 8.0), -1.4, z + 8.0 + alt * 0.6);
    float curve = ciPath(z + 12.0) - 2.0 * ciPath(z + 6.0) + ciPath(z);
    float roll = -0.06 * curve + 0.05 * sin(u.time * 0.05);
    float fov = 1.3 - 0.16 * rush + 0.08 * lull;
    vec3 rd = osCamera(ro, ta, roll, fov, p);

    vec2 src = vec2(ciPath(z + 6.0), z + 6.0);
    vec3 fogCol = k.glow * 0.025;
    vec3 sky = ciSky(rd, k);
    float tmax = 110.0;
    float pixk = 2.0 / (max(u.resolution.y, 1.0) * fov);
    vec3 col;
    float t;
    // the board plane is the floor: march the component slab, else hit y = 0
    float tb = rd.y < -1e-3 ? ro.y / -rd.y : 1e4;
    float tc = ciMarch(ro, rd, min(tb, tmax), osSteps(32.0, 90.0, detail));
    t = tc > 0.0 ? tc : tb;
    if (t > tmax) {
        col = sky;
        t = tmax;
    } else {
        vec3 pos = ro + rd * t;
        if (tc < 0.0) {
            float copper;
            float pix = t * pixk;
            vec2 fp = vec2(pix, pix / max(-rd.y, 0.05));
            vec3 em = ciBoard(pos.xz, src, fp, k, detail, copper) * bright;
            // glossy solder mask: mirror the towers and the sky
            vec3 rr = vec3(rd.x, -rd.y, rd.z);
            float fres = 0.06 + 0.94 * pow(1.0 - saturate(-rd.y), 5.0);
            float t2 = ciMarch(pos + vec3(0.0, 0.003, 0.0), rr, 14.0, osSteps(8.0, 28.0, detail));
            vec3 refl;
            if (t2 < 0.0) refl = ciSky(rr, k);
            else {
                vec3 p2 = pos + rr * t2;
                refl = ciShade(p2, ciNormal(p2), rr, src, k, bright, (t + t2) * pixk);
            }
            col = k.mask + em + refl * mix(0.08 + fres * 0.6, 0.4 + 0.5 * fres, saturate(copper))
                + ciPool(pos, k) * (0.25 + 1.5 * saturate(copper));
        } else {
            col = ciShade(pos, ciNormal(pos), rd, src, k, bright, t * pixk);
        }
    }
    float fog = 1.0 - exp(-t * 0.016);
    col = mix(col, fogCol + sky, fog);
    col += k.bass * fogCol * 2.0 * k.bassE * fog;
    col += ciPillars(ro, rd, t, k, pixk, osSteps(5.0, 12.0, detail)) * bright;
    return ciOffRed(max(col, vec3(0.0))); // LINEAR HDR — post chain tonemaps
}
