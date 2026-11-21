// SPDX-License-Identifier: AGPL-3.0-only
// Pulse.
// A kinetic light installation in a black gallery: a long field of glowing
// glass orbs, eighteen wide, hangs from the ceiling on fine wires, a winch on
// every wire so the whole field moves as one sculpture. Every eight beats it
// slowly morphs into a new choreography (a rolling swell, a ripple tank, two
// interfering sources, a slow spiral), and every beat a soft pulse rings out
// from a point ahead, nudging the orbs it passes and tinting them warm and
// cool in turn. The orbs glow with the smoothed level and a little of the
// spectrum, and pool light on the polished floor, which mirrors the field.
// The camera glides slowly and steadily along under one edge of the sculpture
// with no bank or speed surges; audio drives soft orb light only, never the
// camera or sudden flashes.
// param0 = Glow ; param1 = Impact ; param2 = Wave Count

const float PU_R = 0.15;      // orb radius (grid spacing is 1)
const float PU_CEIL = 6.2;    // ceiling height
const float PU_BASE = 3.1;    // resting orb height
const float PU_HALF = 9.0;    // the installation is eighteen orbs wide

// The palette read once per pixel at five stops and blended locally.
struct PuPalette { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

PuPalette puPalLoad(VisualUniforms u) {
    PuPalette P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 puPal(PuPalette P, float t) {
    t = saturate(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// A light's colour: peak-normalised, a little more saturated.
vec3 puVivid(vec3 c) {
    c = c / max(max(c.r, max(c.g, c.b)), 0.05);
    return max(mix(vec3(luma(c)), c, 1.25), 0.0);
}

// The complementary hue at the same range.
vec3 puComp(vec3 c) {
    float hi = max(c.r, max(c.g, c.b));
    float lo = min(c.r, min(c.g, c.b));
    return vec3(hi + lo) - c;
}

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float PU_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);

// Beats' worth of travel at the start of beat m.
float puBeatRun(float m) {
    return floor(m / 32.0) * PU_RUN[32] + PU_RUN[int(mod(m, 32.0))];
}

// x: distance walked, y: current speed.
vec2 puFlight(VisualUniforms u, float tw, float cruise, float surge) {
    float n = floor(u.beatCount);
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = puBeatRun(n) + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(tw * cruise * 0.2 + beats * (cruise * 0.07 + surge), mix(v0, v1, ph));
}

// Everything the orbs need that is the same for the whole frame.
struct PuField {
    vec2 src0; vec2 src1; vec2 src2;   // where the last three pulses rang out
    float age0; float age1; float age2; // their ages in beats
    vec3 acc0; vec3 acc1; vec3 acc2;    // their colours, warm and cool in turn
    vec2 anchorA; vec2 anchorB;         // this and the last choreography's centre
    int formA; int formB;
    float morph;                        // 0 = last choreography, 1 = this one
    float k;                            // wave number
    float ph;                           // wave phase
    float amp;                          // choreography amplitude
    float lift;                         // pulse lift
    float ringV;                        // ring speed, cells per beat
    float energy;                       // overall orb level
    float b0; float b1; float b2; float b3; float b4; float b5;
    vec3 baseLo; vec3 baseHi;
};

// One choreography's height at offset q from its centre, in -1..1.
float puForm(int f, vec2 q, float k, float ph) {
    float d = length(q);
    if (f == 0) return sin(dot(q, vec2(0.6, 0.8)) * k - ph);
    if (f == 1) return sin(d * k - ph) * (0.35 + 0.65 * exp(-d * 0.05));
    if (f == 2) {
        vec2 o = vec2(5.0, 0.0);
        return 0.5 * (sin(length(q - o) * k - ph) + sin(length(q + o) * k - ph));
    }
    return sin(d * k * 0.7 + 3.0 * atan2_(q.y, q.x) - ph);
}

// A pulse ring's strength at distance d from its source, age a beats.
float puRing(float d, float a, float v) {
    float x = d - a * v;
    return exp(-x * x * 0.9) * exp(-a * 0.9) * step(0.0, a);
}

// The orb in cell c: its height and its light.
void puOrb(vec2 c, PuField F, out float h, out vec3 e) {
    float s = mix(puForm(F.formB, c - F.anchorB, F.k, F.ph), puForm(F.formA, c - F.anchorA, F.k, F.ph), F.morph);
    float d0 = length(c - F.src0);
    float r0 = puRing(d0, F.age0, F.ringV);
    float r1 = puRing(length(c - F.src1), F.age1, F.ringV);
    float r2 = puRing(length(c - F.src2), F.age2, F.ringV);
    // the spectrum spreads outward from the newest pulse, bass at the centre
    float bi = d0 * 0.22;
    float bnd = mix(F.b0, F.b1, saturate(bi));
    bnd = mix(bnd, F.b2, saturate(bi - 1.0));
    bnd = mix(bnd, F.b3, saturate(bi - 2.0));
    bnd = mix(bnd, F.b4, saturate(bi - 3.0));
    bnd = mix(bnd, F.b5, saturate(bi - 4.0));
    float ring = r0 + r1 + r2;
    h = clamp(PU_BASE + F.amp * s + F.lift * ring + 0.03 * bnd, 1.55, PU_CEIL - 0.6);
    float jit = hash21(mod(c, 251.0));
    vec3 base = mix(F.baseLo, F.baseHi, smoothstep(-0.6, 0.8, s));
    float s01 = saturate(0.5 + 0.5 * s);
    // the pulse recolours the orbs it passes rather than just brightening them
    e = base * F.energy * (0.12 + 0.45 * s01 * s01 + 0.08 * bnd) * (0.8 + 0.4 * jit) * (1.0 - 0.3 * saturate(ring))
      + (F.acc0 * r0 * 0.15 + F.acc1 * r1 * 0.12 + F.acc2 * r2 * 0.1) * (0.6 + 0.4 * F.energy);
}

// March the grid cell by cell. Returns the light gathered along the ray (orb
// halos, lit wires); fills in the first orb hit, if any.
vec3 puTrace(vec3 ro, vec3 rd, PuField F, int cells, float tMax, float pixA, float glow,
             out float tHit, out vec3 hitCol) {
    vec3 acc = vec3(0.0);
    tHit = -1.0;
    hitCol = vec3(0.0);
    vec2 o = ro.xz;
    vec2 d = rd.xz;
    d = vec2(abs(d.x) < 1e-5 ? (d.x < 0.0 ? -1e-5 : 1e-5) : d.x, abs(d.y) < 1e-5 ? (d.y < 0.0 ? -1e-5 : 1e-5) : d.y);
    vec2 cell = floor(o);
    vec2 st = sign(d);
    vec2 tDel = abs(1.0 / d);
    vec2 tNext = (cell + max(st, 0.0) - o) / d;
    float sg2 = (0.045 + 0.05 * glow);
    float fadeEnd = float(cells) * 0.72;
    float t = 0.0;
    for (int i = 0; i < 48; i++) {
        if (i >= cells) break;
        vec2 cc = cell + 0.5;
        // beyond the installation's edge and heading away: nothing more to see
        if (abs(cc.x) > PU_HALF && cc.x * st.x > 0.0) break;
        if (abs(cc.x) < PU_HALF) {
        float h;
        vec3 e;
        puOrb(cc, F, h, e);
        vec3 pc = vec3(cc.x, h, cc.y);
        vec3 oc = ro - pc;
        float b = dot(oc, rd);
        float c2 = dot(oc, oc);
        float far = 1.0 - smoothstep(fadeEnd * 0.55, fadeEnd, -b);
        // halo round the orb
        float m2 = max(c2 - b * b, 0.0);
        if (b < 0.0) acc += e * far * exp(-m2 / (sg2 * sg2)) * 0.35 * glow;
        // the wire above it: a hairline lit from below by its orb
        float tw = dot(cc - o, d) / dot(d, d);
        float wy = ro.y + rd.y * tw;
        if (tw > 0.0 && wy > h + PU_R && wy < PU_CEIL) {
            float dx = length(o + d * tw - cc);
            float pw = max(pixA * tw, 0.004);
            float cov = exp(-dx * dx / (pw * pw)) * (0.004 / pw);
            acc += (e * exp(-(wy - h) * 0.9) * 0.9 + vec3(0.012)) * cov * far;
        }
        // the orb itself: frosted glass with a hot core
        float disc = b * b - (c2 - PU_R * PU_R);
        if (disc > 0.0) {
            float th = -b - sqrt(disc);
            if (th > 0.0) {
                vec3 n = normalize(oc + rd * th);
                float ndv = saturate(-dot(n, rd));
                hitCol = e * far * (0.5 + 0.9 * pow(ndv, 2.0)) + e * e * far * 0.06 * pow(ndv, 6.0)
                       + vec3(0.03) * pow(1.0 - ndv, 3.0) * far;
                tHit = th;
                break;
            }
        }
        }
        float tn = min(tNext.x, tNext.y);
        if (tn > tMax) break;
        t = tn;
        if (tNext.x < tNext.y) { tNext.x += tDel.x; cell.x += st.x; }
        else { tNext.y += tDel.y; cell.y += st.y; }
    }
    return acc;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 sp = centered(uv, u.resolution);
    sp.y = -sp.y;
    float detail = osDetail(u);
    float glow = mix(0.5, 1.6, u.param0);
    float impact = mix(0.4, 1.6, u.param1);
    float waves = mix(0.5, 1.6, u.param2);
    float tw = mod(u.time, 600.0);

    // ---- camera: a slow glide under the field ----
    float cruise = 0.45;
    float surge = 0.0;
    vec2 fl = puFlight(u, tw, cruise, surge);
    float runK = cruise * 0.07 + surge;
    float tTerm = tw * cruise * 0.2;
    float lull = saturate(1.0 - fl.y);
    float rush = saturate((fl.y - 1.0) / 3.5);
    vec3 ro = vec3(-PU_HALF + 1.2 + 1.0 * sin(tw * 0.043), 1.45 + 0.2 * sin(tw * 0.11), fl.x);
    float yaw = 0.24 + 0.1 * sin(tw * 0.027 + 1.0);
    vec3 fwd = vec3(sin(yaw), 0.0, cos(yaw));
    vec3 ta = ro + fwd * 6.0 + vec3(0.0, 1.0 + 0.3 * sin(tw * 0.06), 0.0);
    float fov = 1.6 - 0.03 * rush + 0.02 * lull;
    vec3 rd = osCamera(ro, ta, 0.0, fov, sp);
    float pixA = 2.0 / (u.resolution.y * fov);

    // ---- the show ----
    PuPalette P = puPalLoad(u);
    float n = floor(u.beatCount);
    float bp = saturate(u.beatPhase);
    float sec = u.beatCount / 16.0;
    float cyc = mod(sec, 4.0);
    float chorus = smoothstep(1.75, 2.0, cyc) * (1.0 - smoothstep(3.75, 4.0, cyc));
    vec3 warm = puVivid(puPal(P, mix(0.5, 0.62, chorus)));
    vec3 cool = puVivid(mix(puComp(warm), vec3(0.05, 0.35, 1.0), 0.35));

    PuField F;
    // each pulse rings out from a point ahead of where the camera was on its beat
    F.src0 = vec2(-2.0 + 5.0 * (hash11(n * 0.71) - 0.5), puBeatRun(n) * runK + tTerm + 13.0);
    F.src1 = vec2(-2.0 + 5.0 * (hash11((n - 1.0) * 0.71) - 0.5), puBeatRun(n - 1.0) * runK + tTerm + 13.0);
    F.src2 = vec2(-2.0 + 5.0 * (hash11((n - 2.0) * 0.71) - 0.5), puBeatRun(n - 2.0) * runK + tTerm + 13.0);
    F.age0 = bp;
    F.age1 = bp + 1.0;
    F.age2 = bp + 2.0;
    bool odd = mod(n, 2.0) > 0.5;
    F.acc0 = odd ? cool : warm;
    F.acc1 = odd ? warm : cool;
    F.acc2 = odd ? cool : warm;
    // a new choreography every eight beats, morphing in steadily across all
    // eight so the whole field never lurches at once
    float blk = floor(n / 8.0);
    F.formA = int(mod(blk, 4.0));
    F.formB = int(mod(blk - 1.0, 4.0));
    F.morph = (n - blk * 8.0 + bp) / 8.0;
    F.anchorA = vec2(0.0, puBeatRun(blk * 8.0) * runK + 16.0);
    F.anchorB = vec2(0.0, puBeatRun(blk * 8.0 - 8.0) * runK + 16.0);
    F.k = 0.55 * waves;
    F.ph = tw * 0.25;
    F.amp = (0.8 + 0.1 * u.level) * (1.0 - 0.1 * lull);
    F.lift = impact * 0.08;
    F.ringV = 3.0;
    // breakdown: the field dims to a glimmer; burst: it blazes
    F.energy = (0.75 + 0.15 * u.level + 0.1 * smoothstep(0.5, 1.1, fl.y)) * glow;
    F.b0 = bandAt(u, 0.03);
    F.b1 = bandAt(u, 0.10);
    F.b2 = bandAt(u, 0.20);
    F.b3 = bandAt(u, 0.34);
    F.b4 = bandAt(u, 0.52);
    F.b5 = bandAt(u, 0.75);
    F.baseLo = puVivid(puPal(P, 0.22)) * 0.5;
    F.baseHi = puVivid(puPal(P, mix(0.42, 0.5, chorus)));

    // ---- trace ----
    int cells = osSteps(26.0, 48.0, detail);
    float tCeil = rd.y > 0.0 ? (PU_CEIL - ro.y) / rd.y : 1e4;
    float tFloor = rd.y < 0.0 ? -ro.y / rd.y : 1e4;
    float tMax = min(min(tCeil, tFloor), 60.0);
    float tHit;
    vec3 hitCol;
    vec3 col = puTrace(ro, rd, F, cells, tMax, pixA, glow, tHit, hitCol);
    if (tHit > 0.0) {
        col += hitCol;
    } else if (tFloor < tCeil) {
        // polished black floor: a mirror of the field, pooled with orb light
        vec3 fp = ro + rd * tFloor;
        float fres = 0.45 + 0.5 * pow(1.0 - saturate(-rd.y), 5.0);
        vec3 rr = vec3(rd.x, -rd.y, rd.z);
        int rc = osSteps(0.0, 24.0, detail);
        if (rc > 0) {
            float tH2;
            vec3 hc2;
            vec3 rg = puTrace(fp, rr, F, rc, (PU_CEIL - fp.y) / max(rr.y, 0.02), pixA, glow, tH2, hc2);
            col += (rg + hc2) * fres * exp(-tFloor * 0.04);
        }
        // the pool under the nearest orbs
        vec2 c0 = floor(fp.xz - 0.5) + 0.5;
        vec3 pool = vec3(0.0);
        for (int j = 0; j < 4; j++) {
            vec2 cc = c0 + vec2(float(j - (j / 2) * 2), float(j / 2));
            float h;
            vec3 e;
            puOrb(cc, F, h, e);
            vec2 dq = fp.xz - cc;
            pool += e * h / pow(dot(dq, dq) + h * h, 1.5) * step(abs(cc.x), PU_HALF);
        }
        float fade = 1.0 - smoothstep(float(cells) * 0.3, float(cells) * 0.7, tFloor);
        col += pool * 0.05 * fade;
    } else {
        // the ceiling: dark plaster with a socket for every wire
        vec3 cp = ro + rd * tCeil;
        vec2 cc = floor(cp.xz) + 0.5;
        float h;
        vec3 e;
        puOrb(cc, F, h, e);
        vec2 dq = cp.xz - cc;
        float fade = 1.0 - smoothstep(float(cells) * 0.25, float(cells) * 0.6, tCeil);
        float sock = exp(-dot(dq, dq) * 900.0) * step(abs(cc.x), PU_HALF);
        float over = step(abs(cc.x), PU_HALF);
        col += (e * over * 0.03 / (1.0 + (PU_CEIL - h)) + vec3(0.003)) * fade + e * sock * 0.15 * fade;
    }

    col *= 1.0 - 0.3 * smoothstep(0.8, 1.9, length(sp));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    col = max(col, 0.0);
    // a trace of green and blue under faint warm light, so near-black pixels
    // never read as saturated red
    col.gb += min(col.r, 0.002);
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
