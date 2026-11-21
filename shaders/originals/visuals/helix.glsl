// SPDX-License-Identifier: AGPL-3.0-only
// Helix.
// A flight down an avenue of double helices drawn entirely in light. A helix
// winds past on each side of the camera and recedes to the vanishing point,
// strung with glowing beads; between the backbones the base-pair rungs are
// lines of light particles, each rung tuned to a band of the spectrum so the
// molecules play like a running equaliser. Pulses of light stream along the
// backbones, two more helices stand in the dark, thin streaks of light fly
// out of the vanishing point, and everything near or far is thrown softly out
// of focus. Backbones are cyan and magenta over black, the warm accent is
// orange. Calm under loud music: the rungs and beads brighten with the
// smoothed level plus a modest band term, each beat sends only a faint warm
// wave down the helices and warms a few scattered rungs, and the camera
// glides at a slow steady pace with a gentle bank and no beat surges. Audio
// drives the light, never the camera.
// param0 = Twist ; param1 = Depth ; param2 = Sparkle

const float HX_TAU = 6.2831853;
const float HX_SP = 1.25;      // rung spacing
const float HX_GROOVE = 2.35;   // angle from one backbone to the other (major / minor groove)

// The palette is read once per pixel at its five stops and blended locally:
// each library palette read walks the whole stop table, and this visual needs
// many colours per pixel. hxPal follows the library blend closely.
struct HxPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

HxPal hxPalLoad(VisualUniforms u) {
    HxPal P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 hxPal(HxPal P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// Distance from p to segment ab, and where along it (0..1).
vec2 hxSeg(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return vec2(length(pa - ba * h), h);
}

// Soft glow of a line or dot of half-width w at screen distance d: a bright
// core with a long, quickly fading halo that ends at x = sqrt(1 / fl - 1).
float hxGlow(float d, float w, float fl) {
    float x = d / w;
    return max(1.0 / (1.0 + x * x) - fl, 0.0) * 1.05 + exp(-x * x * 2.0) * 1.5;
}

// The spectrum read once per pixel at eight points, and read back with linear
// weights: a library band read per rung selects through the whole uniform array.
struct HxBands { vec4 lo; vec4 hi; };

HxBands hxBandsLoad(VisualUniforms u) {
    HxBands b;
    b.lo = vec4(bandAt(u, 0.0), bandAt(u, 1.0 / 7.0), bandAt(u, 2.0 / 7.0), bandAt(u, 3.0 / 7.0));
    b.hi = vec4(bandAt(u, 4.0 / 7.0), bandAt(u, 5.0 / 7.0), bandAt(u, 6.0 / 7.0), bandAt(u, 1.0));
    return b;
}

float hxBand(HxBands b, float f) {
    float x = saturate(f) * 7.0;
    return dot(b.lo, max(1.0 - abs(x - vec4(0.0, 1.0, 2.0, 3.0)), 0.0))
         + dot(b.hi, max(1.0 - abs(x - vec4(4.0, 5.0, 6.0, 7.0)), 0.0));
}

// Rung index -> the band it plays: walks up and back down the spectrum.
float hxRungF(float c) {
    float f = fract(mod(c, 4096.0) / 28.0);
    return 1.0 - abs(2.0 * f - 1.0);
}

// World point -> (screen x, screen y, depth) for the camera at ro with
// basis rt, cu, fw and focal length fov.
vec3 hxProject(vec3 X, vec3 ro, vec3 rt, vec3 cu, vec3 fw, float fov) {
    vec3 d = X - ro;
    float zs = dot(d, fw);
    return vec3(fov * vec2(dot(d, rt), dot(d, cu)) / max(zs, 0.05), zs);
}

// Three rotated octaves of value noise for the gas: soft enough not to need five.
float hxGas(vec2 q) {
    float v = vnoise(q) * 0.55;
    q = FBM_OCTAVE * q + 1.7;
    v += vnoise(q) * 0.3;
    q = FBM_OCTAVE * q + 3.1;
    return v + vnoise(q) * 0.15;
}

// The flight path: the helices follow it, so far turns bend away out of view.
vec2 hxPath(float z) {
    return vec2(2.4 * sin(z * 0.041) + 1.1 * sin(z * 0.023 + 1.3), 1.4 * sin(z * 0.031 + 2.0));
}

// Unit vector at angle a, and rotation of a unit vector by one.
vec2 hxCs(float a) {
    return vec2(cos(a), sin(a));
}

vec2 hxRot(vec2 v, vec2 r) {
    return vec2(v.x * r.x - v.y * r.y, v.x * r.y + v.y * r.x);
}

// One helix, drawn additively: n rungs from zFrom, sp apart, then its
// backbones alone in coarser steps out to the vanishing point.
// look = (fov, line width, haze fade, seed).
vec3 hxDraw(vec2 p, vec3 ro, vec3 rt, vec3 cu, vec3 fw, vec4 look, vec2 o, float R, float L, float ph,
            vec2 sp, float zFrom, int n, int nC, vec3 cs[5], HxBands bands, VisualUniforms u, float sparkle, float beatKey, float flare) {
    float fov = look.x;
    float seed = look.w;
    vec3 col = vec3(0.0);
    vec3 cA = cs[0], cB = cs[1], c0 = cs[2], c1 = cs[3], c2 = cs[4];
    // each beat a wave of warm light runs down the helices, away from the camera
    // it swells and fades within the beat, so no light jumps on the kick
    float bp = saturate(u.beatPhase);
    float front = 1.0 + 26.0 * bp;
    float wAmp = smoothstep(0.0, 0.35, bp) * (1.0 - bp) * (0.1 + 0.06 * saturate(u.level));
    float lev = saturate(u.level);
    // The path's three sine terms and the strand angle are stepped by
    // rotation, so the loop needs no trigonometry. Each backbone segment bends
    // through the arc's midpoint, so the strands curve instead of kinking: the
    // midpoint is the chord's centre pushed out to the radius, since the path
    // itself barely turns within one step.
    float lw = L * sp.x;
    float cm = sp.y;
    vec2 h = hxCs(HX_TAU * mod(zFrom, lw) / lw + ph);
    vec2 p1 = hxCs(mod(zFrom * 0.041, HX_TAU));
    vec2 p2 = hxCs(mod(zFrom * 0.023, HX_TAU) + 1.3);
    vec2 p3 = hxCs(mod(zFrom * 0.031, HX_TAU) + 2.0);
    vec2 groove = hxCs(HX_GROOVE);
    vec2 rhF = hxCs(HX_TAU * sp.x / lw), rhC = hxCs(cm * HX_TAU * sp.x / lw);
    vec2 r1F = hxCs(0.041 * sp.x), r1C = hxCs(0.041 * cm * sp.x);
    vec2 r2F = hxCs(0.023 * sp.x), r2C = hxCs(0.023 * cm * sp.x);
    vec2 r3F = hxCs(0.031 * sp.x), r3C = hxCs(0.031 * cm * sp.x);
    // chord-to-arc: the half-angle secant, and how far the arc bulges past the chord
    float cF = sqrt(max(0.5 + 0.5 * rhF.x, 1e-3)), cC = sqrt(max(0.5 + 0.5 * rhC.x, 1e-3));
    float kF = 0.5 / cF, kC = 0.5 / cC;
    float bF = R * (1.0 - cF) * fov, bC = R * (1.0 - cC) * fov;
    // camera space: world x, y and z map onto these camera-space vectors, and
    // the two strand offsets (h and h turned by the groove) onto ga and gb
    vec3 ex = vec3(rt.x, cu.x, fw.x), ey = vec3(rt.y, cu.y, fw.y), ez = vec3(rt.z, cu.z, fw.z);
    vec3 roC = vec3(dot(ro, rt), dot(ro, cu), dot(ro, fw));
    vec3 gbx = R * (ex * groove.x + ey * groove.y), gby = R * (ey * groove.x - ex * groove.y);
    vec3 exR = R * ex, eyR = R * ey;
    vec2 cen = o + vec2(2.4 * p1.y + 1.1 * p2.y, 1.4 * p3.y);
    vec3 cc = ex * cen.x + ey * cen.y + ez * zFrom - roC;
    vec3 A = cc + exR * h.x + eyR * h.y;
    vec3 B = cc + gbx * h.x + gby * h.y;
    vec3 a0 = vec3(A.xy * (fov / max(A.z, 0.05)), A.z);
    vec3 b0 = vec3(B.xy * (fov / max(B.z, 0.05)), B.z);
    // end the fine steps on the coarse grid, so the coarse tail's corners stay put in z
    int nA = n + int(mod(-(floor(zFrom / sp.x + 0.5) + float(n)), cm) + 0.5);
    int total = nA + nC;
    float invTotal = 1.0 / float(max(total, 1));
    float zc = zFrom;
    for (int j = 0; j < 72; j++) {
        if (j >= total) break;
        bool fine = j < nA;
        zc += fine ? sp.x : cm * sp.x;
        h = hxRot(h, fine ? rhF : rhC);
        p1 = hxRot(p1, fine ? r1F : r1C);
        p2 = hxRot(p2, fine ? r2F : r2C);
        p3 = hxRot(p3, fine ? r3F : r3C);
        vec3 cp = cc, ap = A, bpv = B;
        cen = o + vec2(2.4 * p1.y + 1.1 * p2.y, 1.4 * p3.y);
        cc = ex * cen.x + ey * cen.y + ez * zc - roC;
        A = cc + exR * h.x + eyR * h.y;
        B = cc + gbx * h.x + gby * h.y;
        vec3 am = vec3(A.xy * (fov / max(A.z, 0.05)), A.z);
        vec3 bm = vec3(B.xy * (fov / max(B.z, 0.05)), B.z);
        float zs = 0.5 * (am.z + bm.z);
        float izs = 1.0 / max(zs, 0.5);
        // skip segments whose glow cannot reach this pixel (margin covers the widest blur)
        float mg = min(look.y * 44.0 * izs, 0.2) + (fine ? bF : bC) * izs;
        vec2 lo = min(min(a0.xy, am.xy), min(b0.xy, bm.xy)) - mg;
        vec2 hi = max(max(a0.xy, am.xy), max(b0.xy, bm.xy)) + mg;
        bool near = all(greaterThan(p, lo)) && all(lessThan(p, hi)) && zs > 0.6;
        if (near) {
        float ri = floor(zc / sp.x + 0.5);
        // fade in from beside the camera, out into the haze
        float vis = smoothstep(1.0, 3.5, min(min(am.z, bm.z), min(a0.z, b0.z))) * exp(-zs * look.z);
        vis *= 1.0 - smoothstep(0.55, 1.0, float(j) * invTotal);
        // depth of field: lines grow and dim away from the focus distance
        float coc = min(zs < 7.0 ? (7.0 - zs) * izs : (zs - 7.0) / 7.0, 2.5);
        float w = look.y * (1.0 + 2.5 * coc) * izs;
        // the box is loose for slanted segments: test the chords (the arcs lie
        // within the bulge of them) against the glow's reach before shading
        vec2 sR = hxSeg(p, am.xy, bm.xy);
        // out-of-focus lines are dim, so their halo is cut shorter
        float fl = 0.05 + 0.13 * saturate(coc * 0.5);
        float reach = sqrt(1.0 / fl - 1.0);
        bool rungNear = fine && zs < 26.0 && zs > 1.8 && sR.x < w * 1.7 * reach;
        float dC = min(hxSeg(p, a0.xy, am.xy).x, hxSeg(p, b0.xy, bm.xy).x) - (fine ? bF : bC) * izs;
        if (vis > 0.002 && (dC < w * 1.4 * reach || rungNear)) {
            float dimW = vis / (1.0 + 2.2 * coc);

            vec3 cm2 = 0.5 * (cp + cc);
            float k = fine ? kF : kC;
            vec3 Am = cm2 + k * (ap + A - cp - cc);
            vec3 Bm = cm2 + k * (bpv + B - cp - cc);
            vec2 ah = Am.xy * (fov / max(Am.z, 0.05));
            vec2 bh = Bm.xy * (fov / max(Bm.z, 0.05));
            float sA = min(hxSeg(p, a0.xy, ah).x, hxSeg(p, ah, am.xy).x);
            float sB = min(hxSeg(p, b0.xy, bh).x, hxSeg(p, bh, bm.xy).x);
            // pulses streaming along the backbones, away from the camera
            float flowA = exp(-fract(ri * 0.11 - u.time * 0.3 + seed) * 6.0);
            float flowB = exp(-fract(ri * 0.11 - u.time * 0.3 + seed + 0.5) * 6.0);
            float dz = zs - front;
            float wave = wAmp * (exp(-dz * dz * 0.35) + 0.35 * exp(-max(-dz, 0.0) * 0.4) * step(dz, 0.0));
            float gA = hxGlow(sA, w * 1.4, fl), gB = hxGlow(sB, w * 1.4, fl);
            float keep = 1.0 - 0.25 * saturate(wave);
            col += cA * gA * (0.5 + 0.6 * flowA * (0.7 + 0.3 * lev)) * dimW * keep;
            col += cB * gB * (0.5 + 0.6 * flowB * (0.7 + 0.3 * lev)) * dimW * keep;
            col += c2 * (gA + gB) * wave * 0.6 * dimW;

            if (rungNear) {
            // the base-pair rung: a dotted line of light, two-tone, tuned to its band
            float idx = mod(ri + floor(37.0 * seed), 4096.0);
            float f = hxRungF(idx);
            float lv = hxBand(bands, f);
            float ig = step(0.86, hash21(vec2(idx, beatKey))) * flare;
            float dots = 0.35 + 0.65 * pow(0.5 + 0.5 * cos(sR.y * HX_TAU * 7.0), 3.0);
            float gap = smoothstep(0.015, 0.05, abs(sR.y - 0.5));
            float ft = saturate(f + (sR.y > 0.5 ? 0.12 : -0.06));
            vec3 rc = ft < 0.5 ? mix(c0, c1, ft * 2.0) : mix(c1, c2, ft * 2.0 - 1.0);
            float e = (0.35 + 0.5 * lev + 0.6 * lv * lv + 1.5 * ig + 1.0 * wave) * dots * gap;
            // far turns keep only their backbones; rungs beside the camera fade out
            float detailFade = smoothstep(26.0, 9.0, zs) * smoothstep(1.8, 4.0, zs);
            col += rc * hxGlow(sR.x, w, fl) * e * dimW * detailFade;

            // glowing beads where rungs meet the backbones
            float wb = w * 1.7;
            float bead = hxGlow(length(p - am.xy), wb, fl) + hxGlow(length(p - bm.xy), wb, fl);
            float glint = 0.05 * u.onset * sparkle * step(0.7, hash21(vec2(idx, beatKey + 9.0)));
            col += mix(mix(rc, c2, saturate(wave)), vec3(1.0), 0.25) * bead * (0.18 + 0.2 * lev + 0.15 * lv + 0.6 * ig + 0.6 * glint + 0.6 * wave) * dimW * detailFade;
            }
        }
        }
        a0 = am;
        b0 = bm;
    }
    return col;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    HxPal P = hxPalLoad(u);
    HxBands bands = hxBandsLoad(u);

    float L = mix(13.0, 7.0, u.param0);              // rungs per turn
    float depth = mix(0.6, 1.6, u.param1);
    float sparkle = mix(0.3, 1.6, u.param2);

    // a slow, steady glide with no beat surges
    float z = 8.0 + 0.45 * u.time;
    float spin = mod(u.time * 0.05 + z * 0.03, HX_TAU);
    float cyc = fract((mod(u.beatCount, 256.0) + saturate(u.beatPhase)) / 32.0);
    float hs = 0.035 * sin(cyc * HX_TAU);

    vec3 ro = vec3(hxPath(z) + vec2(0.3 * sin(z * 0.019), 0.2 * sin(z * 0.027 + 1.0)), z);
    vec3 ta = vec3(hxPath(z + 7.0) + vec2(0.15 * sin(z * 0.017), 0.1), z + 7.0);
    float curve = hxPath(z + 9.0).x - 2.0 * hxPath(z + 4.5).x + hxPath(z).x;
    float roll = -0.3 * curve + osBank(u, 0.02);
    float fov = 1.05;
    vec3 fw = normalize(ta - ro);
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(fw, up));
    vec3 cu = cross(rt, fw);
    vec3 rd = normalize(p.x * rt + p.y * cu + fov * fw);

    float bp = saturate(u.beatPhase);
    float we = sin(3.14159265 * bp);
    float flare = we * we * (0.08 + 0.06 * saturate(u.level));
    float beatKey = mod(floor(u.beatCount), 64.0);

    // background: deep haze, gas walls along the avenue and the light at the
    // vanishing point
    float vp = saturate(rd.z);
    vec2 sq = rd.xy / max(rd.z, 0.2);
    float ang = atan2_(sq.y, sq.x) / HX_TAU + 0.5;
    float rr = length(sq);
    // the gas streams outward past the camera with the flight: two zoom
    // layers an octave apart cross-fade as the distance flown wraps
    float zt = fract(z * 0.035);
    vec2 gq = sq * 1.5 + vec2(mod(u.time * 0.008, 50.0), 0.0);
    float neb = mix(hxGas(gq * exp2(-zt) + 3.7), hxGas(gq * exp2(1.0 - zt) + 3.7), zt);
    float wall = smoothstep(0.15, 1.1, rr);
    float gasLit = smoothstep(0.4, 0.78, neb) * wall * (1.0 + 0.1 * saturate(u.level));
    float gh = 0.5 + 0.5 * sin(HX_TAU * ang + 5.0 * neb + 0.4 * z * 0.035);
    vec3 gas = mix(hxPal(P, 0.24 + hs), hxPal(P, 0.52 + hs), gh);
    vec3 col = hxPal(P, 0.05) * 0.0015 + gas * gasLit * gasLit * 0.07;
    col += hxPal(P, 0.99) * (0.006 * pow(vp, 8.0) + 0.05 * pow(vp, 90.0));
    // light streaming down the avenue: thin streaks fly out of the vanishing
    // point at a steady length
    {
        float lanes = 90.0;
        float ln = floor(ang * lanes);
        float lh = hash11(ln * 1.37 + 3.1);
        float lx = abs(fract(ang * lanes) - 0.5);
        float ph = fract(-0.35 / max(rr, 0.05) + z * 0.035 * (0.7 + 0.6 * lh) + lh * 7.0);
        float len = 0.04;
        float tail = 1.0 - saturate(ph / len);
        float sk = tail * tail * step(0.55, lh);
        // a constant thin width on screen, whatever the radius
        float wx = lx * HX_TAU * rr / lanes;
        float sw = 0.0016 + 0.0015 * rr;
        sk *= exp(-wx * wx / (sw * sw)) * smoothstep(0.08, 0.5, rr);
        vec3 skc = hxPal(P, lh < 0.75 ? 0.985 : 0.24 + hs);
        col += skc * sk * (0.06 + 0.04 * saturate(u.level));
    }

    float zFrom = (floor(z / HX_SP) - 1.0) * HX_SP;
    int nHero = osSteps(9.0, 17.0, detail);
    int cHero = osSteps(6.0, 10.0, detail);
    int nFar = osSteps(5.0, 9.0, detail);
    int cFar = osSteps(4.0, 7.0, detail);
    float fade = mix(0.05, 0.028, saturate(depth - 0.6));
    vec3 cs[5] = vec3[5](hxPal(P, 0.24 + hs), hxPal(P, 0.52 + hs), hxPal(P, 0.04), hxPal(P, 0.62 + hs), hxPal(P, 0.985));
    // helices in the haze, then the hero beside the camera
    col += hxDraw(p, ro, rt, cu, fw, vec4(fov, 0.05, fade * 1.2, 0.37), vec2(-7.5, -4.6), 1.9, L * 1.3,
                  2.1 - spin, vec2(HX_SP, 2.0), zFrom + 3.0 * HX_SP, nFar, cFar, cs, bands, u, sparkle, beatKey, flare) * 0.5;
    col += hxDraw(p, ro, rt, cu, fw, vec4(fov, 0.05, fade * 1.2, 0.71), vec2(7.5, 4.8), 1.9, L * 1.3,
                  4.0 + spin, vec2(HX_SP, 2.0), zFrom + 3.0 * HX_SP, nFar, cFar, cs, bands, u, sparkle, beatKey, flare) * 0.45;
    // the avenue: a helix on each side of the flight path
    col += hxDraw(p, ro, rt, cu, fw, vec4(fov, 0.035, fade, 0.53), vec2(-3.9, 1.3), 1.15, L * 1.1,
                  3.3 - spin, vec2(HX_SP, 3.0), zFrom + HX_SP, nHero, cHero, cs, bands, u, sparkle, beatKey, flare) * depth * 0.8;
    col += hxDraw(p, ro, rt, cu, fw, vec4(fov, 0.035, fade, 0.0), vec2(4.0, -0.8), 1.3, L,
                  spin, vec2(HX_SP, 3.0), zFrom, nHero, cHero, cs, bands, u, sparkle, beatKey, flare) * depth;

    // out-of-focus motes on planes ahead
    int motes = osSteps(3.0, 7.0, detail);
    float zsp = 3.0;
    float z0 = ceil(z / zsp) * zsp;
    for (int i = 0; i < 7; i++) {
        if (i >= motes) break;
        float zp = z0 + zsp * float(i);
        float tp = (zp - ro.z) / max(rd.z, 1e-3);
        if (tp <= 0.0) continue;
        vec2 xy = ro.xy + rd.xy * tp;
        vec2 g = xy * 0.8;
        vec2 gi = floor(g);
        vec2 key = gi + vec2(mod(zp, 512.0) * 7.0, 0.0);
        if (hash21(key) > 0.2) continue;
        vec2 c = gi + 0.2 + 0.6 * hash22(key + 1.7);
        float dd = length(g - c);
        float rad = 0.03 + 0.13 * saturate(1.0 - tp / 20.0);
        float disk = 1.0 - smoothstep(rad * 0.55, rad, dd);
        float ringE = smoothstep(rad * 0.6, rad * 0.95, dd) * disk;
        float mh = hash21(key + 4.0);
        vec3 mc = hxPal(P, mh < 0.3 ? 0.985 : 0.2 + 0.4 * mh);
        float fadeM = smoothstep(0.0, 2.0, tp) * exp(-tp * 0.06);
        col += mc * (disk * 0.6 + ringE * 0.6) * fadeM * (0.08 + 0.05 * saturate(u.level)) / (1.0 + 5.0 * rad);
    }
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
