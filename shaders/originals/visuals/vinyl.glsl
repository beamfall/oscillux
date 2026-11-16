// SPDX-License-Identifier: AGPL-3.0-only
// Vinyl.
// A macro product shot of a spinning record. A low, tilted camera drifts over
// the grooves; two lights rake across them and the grooves throw long
// anisotropic sheen streaks that break into the spectrum along the radius
// (outer grooves low, inner high). A soft light sweep crosses the disc every
// eight beats, the label turns, the stylus sparks on the bass, and the studio
// behind melts into bokeh. The camera follows the shared 32-beat speed profile;
// audio drives light and colour, never the camera.
// param0 = Groove Count ; param1 = Spin ; param2 = Needle

const float VY_LABEL = 0.34;
const float VY_PLATTER = 1.035;
const float VY_PLINTH = -0.075;

// The palette read once at five fixed stops and blended locally: a palVisual
// call at a per-pixel position is expensive, and this one is shared by every
// surface below.
struct VyPal { vec3 a; vec3 b; vec3 c; vec3 d; vec3 e; };

vec3 vyPal(VyPal P, float t) {
    float x = clamp(t, 0.1, 0.9) * 5.0 - 0.5;
    vec3 c = mix(P.a, P.b, smoothstep(0.0, 1.0, x));
    c = mix(c, P.c, smoothstep(1.0, 2.0, x));
    c = mix(c, P.d, smoothstep(2.0, 3.0, x));
    return mix(c, P.e, smoothstep(3.0, 4.0, x));
}

// Closest approach of a ray to a segment: (distance, ray t).
vec2 vySegRay(vec3 ro, vec3 rd, vec3 a, vec3 b) {
    vec3 ba = b - a;
    vec3 w = ro - a;
    float bb = max(dot(ba, ba), 1e-6);
    float br = dot(ba, rd);
    float bo = dot(ba, w);
    float rw = dot(rd, w);
    float s = saturate((bo - rw * br) / max(bb - br * br, 1e-6));
    float t = max(s * br - rw, 0.0);
    return vec2(length(w + t * rd - s * ba), t);
}

// Per-channel complement: flips the hue, keeps lightness and saturation.
vec3 vyComp(vec3 c) {
    float hi = max(c.r, max(c.g, c.b)), lo = min(c.r, min(c.g, c.b));
    return vec3(hi + lo) - c;
}

float vyCapsule(vec3 ro, vec3 rd, vec3 pa, vec3 pb, float ra) {
    vec3 ba = pb - pa;
    vec3 oa = ro - pa;
    float baba = dot(ba, ba);
    float bard = dot(ba, rd);
    float baoa = dot(ba, oa);
    float rdoa = dot(rd, oa);
    float oaoa = dot(oa, oa);
    float a = max(baba - bard * bard, 1e-6);
    float b = baba * rdoa - baoa * bard;
    float c = baba * oaoa - baoa * baoa - ra * ra * baba;
    float h = b * b - a * c;
    if (h < 0.0) return -1.0;
    float t = (-b - sqrt(h)) / a;
    float y = baoa + t * bard;
    if (y > 0.0 && y < baba) return t;
    vec3 oc = y <= 0.0 ? oa : ro - pb;
    b = dot(rd, oc);
    c = dot(oc, oc) - ra * ra;
    h = b * b - c;
    return h > 0.0 ? -b - sqrt(h) : -1.0;
}

vec3 vyCapNormal(vec3 pos, vec3 a, vec3 b, float r) {
    vec3 ba = b - a;
    vec3 pa = pos - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return (pa - h * ba) / r;
}

// Studio behind the record: a dark room melted into bokeh, plus the softbox.
vec3 vyStudio(vec3 rd, VisualUniforms u, float sweep, vec3 teal, VyPal P, vec3 fog, bool soft) {
    vec3 col = fog * 0.012 * (1.0 - abs(rd.y));
    // a warm back glow low behind the record, breathing with the mids
    col += vyPal(P, 0.35) * exp(-abs(rd.y - 0.1) * 5.0) * (0.012 + 0.02 * u.mid);
    // softbox overhead: a large soft rectangle the record mirrors
    if (rd.y > 0.05) {
        vec2 q = rd.xz / rd.y;
        vec2 b = abs(q - vec2(-0.6, 0.9)) - vec2(0.7, 0.18);
        float box = 1.0 - smoothstep(-0.05, 0.12, max(b.x, b.y));
        col += vec3(1.0, 0.92, 0.85) * box * (0.25 + 0.5 * sweep);
    }
    float az = atan2_(rd.x, rd.z) / 6.2831853 + 0.5;
    float el = rd.y;
    float band0 = smoothstep(-0.25, 0.05, el) * (1.0 - smoothstep(0.4, 0.7, el));
    if (soft) {
        // curved chrome would alias the discs: reflect their blurred average
        float w = 0.5 + 0.5 * sin(az * 37.699112);
        return col + mix(vyPal(P, 0.3), teal * 0.6, w) * band0 * (0.04 + 0.1 * u.mid);
    }
    // bokeh: hashed discs on a direction grid, each lit by one band
    vec2 g = vec2(az * 30.0, el * 9.5);
    vec2 cell = floor(g);
    vec2 f = fract(g);
    for (int j = 0; j < 4; j++) {
        vec2 o = vec2(float(j - (j / 2) * 2), float(j / 2));
        vec2 id = cell + step(0.5, f) - 1.0 + o;
        vec2 cid = vec2(mod(id.x, 30.0), id.y);
        vec2 hh = hash22(cid + 17.0);
        vec2 centre = id + vec2(0.25, 0.3) + vec2(0.5, 0.4) * hh;
        vec2 d = (g - centre) * vec2(1.0, 0.5);
        float rad = 0.1 + 0.1 * hash21(cid + 3.0);
        float dd = length(d);
        float disc = 1.0 - smoothstep(rad - 0.025, rad, dd);
        float ring = exp(-(dd - rad + 0.015) * (dd - rad + 0.015) * 3000.0);
        float lvl = bandAt(u, hash21(cid + 9.0));
        float on = step(0.25, hash21(cid + 5.0)) * band0;
        vec3 c = hh.y > 0.62 ? teal : vyPal(P, 0.2 + 0.7 * hh.x);
        // a lens-like disc: brighter rim, a faint cool fringe outside it
        float fringe = exp(-(dd - rad - 0.01) * (dd - rad - 0.01) * 2500.0);
        col += (c * (disc * 0.22 + ring * 0.4) + teal * fringe * 0.08) * on * (0.25 + 1.6 * lvl);
    }
    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);

    float grooves = mix(80.0, 220.0, u.param0);   // visible groove rings per unit radius
    float spinRate = mix(0.25, 1.1, u.param1);    // radians per second
    float needle = mix(0.3, 1.4, u.param2);
    float tm = mod(u.time, 600.0);
    float spin = mod(u.time * spinRate, 6.2831853);

    VyPal P = VyPal(palVisual(0.1, u), palVisual(0.3, u), palVisual(0.5, u), palVisual(0.7, u), palVisual(0.9, u));
    vec3 fog = palRoleFog(0.15, u);
    vec3 peak = palRolePeak(0.2, u);
    vec3 trace = palRoleTrace(0.25, u);
    float bassI = saturate(u.bassImpact);

    // ---- camera: a low macro drift on the shared speed profile ----
    vec2 fl = osFlight(u, 1.0, 0.2);
    // bursts of the speed profile open the light up; brakes let it settle
    float burst = smoothstep(1.6, 4.0, fl.y);
    float s1 = sin(fl.x * 0.021);
    float s2 = sin(fl.x * 0.013 + 1.3);
    float phi = -2.35 + 0.3 * s1;
    float dist = 1.08 + 0.14 * s2;
    float camH = 0.2 + 0.05 * sin(u.time * 0.053);
    vec3 ro = vec3(sin(phi) * dist, camH, cos(phi) * dist);
    vec3 ta = vec3(sin(phi) * 0.22, -0.02, cos(phi) * 0.22) + vec3(0.08 * s2, 0.0, 0.06 * s1);
    float roll = 0.14 + osBank(u, 0.05);
    vec3 rd = osCamera(ro, ta, roll, 2.3, p);
    float focus = length(ta - ro);
    float pixA = 2.0 / (max(u.resolution.y, 1.0) * 2.3);   // radians per pixel

    // ---- lights: a key that drifts, a coloured rim, the orbiting spot and a front fill ----
    float ka = 0.4 + 0.9 * sin(tm * 0.11);
    vec3 teal = vyComp(P.b) * 1.5;
    // a teal spot orbits the deck so its streak sweeps round the disc
    float oa = mod(tm * 0.35, 6.2831853);
    vec3 Lo = normalize(vec3(cos(oa), 0.4, sin(oa)));
    vec3 Lk = normalize(vec3(cos(ka), 0.55, sin(ka)));
    vec3 Lr = normalize(vec3(-sin(phi) * 0.9 + 0.3, 0.22, -cos(phi) * 0.9));
    // a fill from behind the camera's left shoulder lays a streak over the near grooves
    vec3 fw = normalize(vec3(ta.x - ro.x, 0.0, ta.z - ro.z));
    vec3 lf = vec3(fw.z, 0.0, -fw.x);
    float fa = 0.35 * sin(tm * 0.07 + 1.0);
    vec3 Lf = normalize(-fw * 0.55 + lf * (0.9 + fa) + vec3(0.0, 0.5, 0.0));
    vec3 fillC = mix(P.c, P.e, 0.5 + 0.5 * sin(tm * 0.05)) * 1.1;
    float sb = (u.beatCount + saturate(u.beatPhase)) / 8.0;
    float sweepT = fract(sb);
    float sweepOn = smoothstep(0.0, 0.15, sweepT) * (1.0 - smoothstep(0.75, 1.0, sweepT));
    float level = 0.6 + 0.6 * u.level;

    // ---- tonearm geometry ----
    vec3 sty = vec3(0.5805, 0.012, 0.2176);
    vec3 piv = vec3(0.6505, 0.13, 1.0748);
    vec3 postA = vec3(piv.x, VY_PLINTH, piv.z);
    vec3 armDir = normalize(piv - sty);
    vec3 headA = sty + vec3(0.0, 0.025, 0.0);
    vec3 headB = headA + armDir * 0.16 + vec3(0.0, 0.012, 0.0);
    vec3 cwA = piv + armDir * 0.08;
    vec3 cwB = piv + armDir * 0.26;

    // exact hits for shading, closest approach for an antialiased silhouette
    float tArm = 1e3;
    vec3 armN = vec3(0.0, 1.0, 0.0);
    float armA = 0.0;
    {
        vec2 c1 = vySegRay(ro, rd, headB, piv);
        vec2 c2 = vySegRay(ro, rd, headA, headB);
        vec2 c3 = vySegRay(ro, rd, cwA, cwB);
        vec2 c4 = vySegRay(ro, rd, postA, piv);
        float e1 = (c1.x - 0.021) / max(c1.y * pixA, 1e-5);
        float e2 = (c2.x - 0.03) / max(c2.y * pixA, 1e-5);
        float e3 = (c3.x - 0.075) / max(c3.y * pixA, 1e-5);
        float e4 = (c4.x - 0.045) / max(c4.y * pixA, 1e-5);
        float em = min(min(e1, e2), min(e3, e4));
        armA = saturate(0.5 - em);
        if (armA > 0.0) {
            float t1 = vyCapsule(ro, rd, headB, piv, 0.021);
            if (t1 > 0.0) { tArm = t1; armN = vyCapNormal(ro + rd * t1, headB, piv, 0.021); }
            float t2 = vyCapsule(ro, rd, headA, headB, 0.03);
            if (t2 > 0.0 && t2 < tArm) { tArm = t2; armN = vyCapNormal(ro + rd * t2, headA, headB, 0.03); }
            float t3 = vyCapsule(ro, rd, cwA, cwB, 0.075);
            if (t3 > 0.0 && t3 < tArm) { tArm = t3; armN = vyCapNormal(ro + rd * t3, cwA, cwB, 0.075); }
            float t4 = vyCapsule(ro, rd, postA, piv, 0.045);
            if (t4 > 0.0 && t4 < tArm) { tArm = t4; armN = vyCapNormal(ro + rd * t4, postA, piv, 0.045); }
            if (tArm > 1e2) {
                // a silhouette pixel the ray just misses: shade it with the nearest rim normal
                vec2 cb = em == e1 ? c1 : em == e2 ? c2 : em == e3 ? c3 : c4;
                vec3 sa = em == e1 ? headB : em == e2 ? headA : em == e3 ? cwA : postA;
                vec3 sbb = em == e1 ? piv : em == e2 ? headB : em == e3 ? cwB : piv;
                vec3 rp = ro + rd * cb.y;
                vec3 ba = sbb - sa;
                float hh = saturate(dot(rp - sa, ba) / max(dot(ba, ba), 1e-6));
                vec3 nn = rp - (sa + ba * hh);
                armN = dot(nn, nn) > 1e-10 ? nn : -rd;
                tArm = cb.y;
            }
        }
    }

    vec3 col;
    float tRec = rd.y < -1e-4 ? -ro.y / rd.y : -1.0;
    vec3 hp = ro + rd * max(tRec, 0.0);
    float rr = length(hp.xz);
    bool onRecord = tRec > 0.0 && rr < 1.0;
    float tHit = 1e3;

    if (onRecord) {
        tHit = tRec;
        vec2 q = hp.xz;
        float r = max(rr, 1e-3);
        vec3 radial = vec3(q.x, 0.0, q.y) / r;
        vec3 T = vec3(-radial.z, 0.0, radial.x);
        vec3 V = -rd;
        float ang = atan2_(q.y, q.x) - spin;
        vec2 cs = vec2(cos(ang), sin(ang));
        // defocus away from the focal plane softens the groove detail
        float blur = saturate(abs(tRec - focus) * 1.2);
        float pix = tRec * 2.5 / max(u.resolution.y, 1.0) / max(-rd.y, 0.08);

        if (r < VY_LABEL) {
            // ---- label: matte printed paper, turning ----
            vec3 lc = mix(P.a, P.b, 0.1 + 0.25 * sin(tm * 0.11));
            float printRing = smoothstep(0.004 + pix, 0.0, abs(r - 0.29)) + smoothstep(0.003 + pix, 0.0, abs(r - 0.2));
            float arcs = step(0.5, fract(ang * 1.2732395)) * smoothstep(0.004, 0.0, abs(r - 0.245) - 0.018);
            float blocks = step(0.62, vnoise(vec2(cs.x * 9.0 + cs.y * 3.0, r * 60.0)))
                         * smoothstep(0.004, 0.0, abs(r - 0.12) - 0.035);
            float diff = 0.25 + 0.75 * saturate(dot(Lk, vec3(0.0, 1.0, 0.0)));
            col = lc * diff * 0.35 * level;
            col += peakWhite(lc, 0.5) * (printRing + arcs * 0.6 + blocks * 0.5) * 0.25 * level;
            // the printed ring lights up with the bass, a teal accent on the label
            col += teal * smoothstep(0.004 + pix, 0.0, abs(r - 0.29)) * (0.1 + 0.9 * bassI) * 0.5;
            float sheenL = pow(saturate(dot(reflect(-Lk, vec3(0.0, 1.0, 0.0)), V)), 12.0);
            col += vec3(0.9, 0.85, 0.8) * sheenL * 0.15;
            // spindle
            float sp = smoothstep(0.03 + pix, 0.022, r);
            col = mix(col, vec3(0.05) + vec3(1.6, 1.5, 1.4) * pow(saturate(1.0 - r / 0.03), 3.0) * (0.4 + 1.0 * u.beat), sp);
        } else {
            // ---- grooved vinyl ----
            float fBin = saturate((1.0 - r) / (1.0 - VY_LABEL));     // outer = low
            float lvl = bandAt(u, fBin * 0.9);
            // tracks separated by polish gaps; loudness bands give each track its sheen
            float tr = (r - VY_LABEL) / (0.985 - VY_LABEL) * 6.0;
            float gapD = abs(fract(tr) - 0.5) * 2.0;
            float gap = smoothstep(0.985, 0.995, gapD) * step(r, 0.985);
            float leadIn = smoothstep(0.985, 0.99, r);
            float polish = max(gap, leadIn);
            float loud = 0.4 + 0.6 * vnoise(vec2(r * 120.0 + cs.x * 4.0, cs.y * 4.0 + 3.0));
            // groove rings, filtered so they fade before aliasing
            float gp = r * grooves;
            float gw = grooves * pix;
            float gl = 0.5 + 0.5 * cos(gp * 6.2831853);
            float ringC = (1.0 - saturate(gw * 1.5)) * (1.0 - 0.7 * blur);
            float micro = mix(0.5, gl, ringC);

            // anisotropic sheen along the groove tangent
            float expo = mix(900.0, 260.0, blur);
            float warp = 0.035 * cs.y + 0.015 * (cs.x * cs.x - cs.y * cs.y);
            T = normalize(T + vec3(0.0, warp, 0.0));
            vec3 Hk = normalize(Lk + V);
            vec3 Ho = normalize(Lo + V);
            vec3 Hf = normalize(Lf + V);
            // Divide by the half vector's horizontal length: when a light sits straight
            // behind the record its streak would otherwise widen over the whole disc.
            float to = dot(T, Ho) * 0.7 / max(length(Ho.xz), 0.4);
            float ao = exp(-to * to * expo * 0.4);
            vec3 Hr = normalize(Lr + V);
            float tk = dot(T, Hk) * 0.7 / max(length(Hk.xz), 0.4);
            float trr = dot(T, Hr) * 0.7 / max(length(Hr.xz), 0.4);
            float tf = dot(T, Hf) * 0.7 / max(length(Hf.xz), 0.4);
            float ak = exp(-tk * tk * expo * 0.5);
            float ar = exp(-trr * trr * expo * 0.3);
            float af = exp(-tf * tf * expo * 0.8);
            float akw = exp(-tk * tk * 40.0);   // wide faint halo around the key streak
            float specMul = (1.0 - polish) * loud * (0.55 + 0.45 * micro);
            // grating colour: hue walks with the offset from the streak's core
            vec3 kc = vyPal(P, 0.62 + 0.3 * clamp(tk * 8.0, -1.0, 1.0));
            kc = mix(kc, vec3(1.0, 0.94, 0.88), ak * ak * 0.6);
            vec3 rc = vyPal(P, 0.2 + 0.12 * fBin);
            // the key light swells on each beat as well
            float kick = 1.0 + 0.6 * burst + 0.5 * u.beat;
            col = kc * (ak * 1.6 + akw * 0.06) * specMul * (0.8 + 2.4 * lvl) * level * kick;
            col += rc * ar * specMul * (0.5 + 2.0 * lvl) * level;
            col += teal * ao * specMul * (0.5 + 1.8 * u.mid + 1.2 * lvl) * level;
            // the fill streak, with first-order diffraction fringes either side of it
            col += fillC * af * specMul * (0.15 + 1.1 * lvl + 0.5 * bassI) * level;
            float d1 = abs(tf) - 0.075;
            float lobe = exp(-d1 * d1 * mix(5200.0, 1400.0, blur));
            vec3 fringe = vyPal(P, 0.5 + 0.4 * clamp(tf * 9.0, -1.0, 1.0) + 0.15 * fBin);
            col += fringe * lobe * specMul * (0.15 + 0.9 * lvl) * level * kick;

            // mirror reflection of the studio: crisp in the gaps, smeared on the grooves
            vec3 nr = normalize(vec3(0.0, 1.0, 0.0) + radial * (micro - 0.5) * 0.06 * (1.0 - polish)
                              - radial * warp * 0.5);
            vec3 refl = vyStudio(reflect(rd, nr), u, sweepOn, teal, P, fog, detail < 0.5);
            float fres = 0.045 + 0.955 * pow(1.0 - saturate(-rd.y), 5.0);
            col += refl * fres * mix(0.12, 0.6, polish);
            col += vec3(0.0025, 0.002, 0.0025);

            // luminous grooves: the spectrum glows in the dark between streaks, more on a burst
            float glowRing = pow(gl, 8.0) * ringC + 0.08;
            col += vyPal(P, 0.08 + 0.3 * fBin + 0.1 * u.spectralCentroid)
                 * glowRing * lvl * lvl * (0.25 + 0.6 * burst) * (1.0 - polish);

            // each beat a teal wave runs out through the grooves from the label,
            // brightest as it leaves
            float bp = saturate(u.beatPhase);
            float wr = VY_LABEL + (1.0 - VY_LABEL) * (1.0 - (1.0 - bp) * (1.0 - bp));
            float wv = exp(-(r - wr) * (r - wr) * 900.0) * (1.0 - bp) * (0.2 + 1.8 * u.beat);
            col += teal * wv * (0.35 + 0.65 * micro) * (0.15 + 0.95 * bassI) * (1.0 - polish);

            // a light bar crossing the disc every eight beats, a teal edge trailing it
            float sx = mix(-1.4, 1.4, sweepT);
            vec2 sdir = vec2(cos(-phi + 0.6), sin(-phi + 0.6));
            float sd = dot(q, sdir) - sx;
            float sweep = exp(-sd * sd * 220.0) * sweepOn;
            float sweepE = exp(-(sd + 0.1) * (sd + 0.1) * 420.0) * sweepOn;
            col += (P.d * vec3(1.1, 1.0, 0.95) * sweep * 1.2 + teal * sweepE * 0.45) * (0.2 + 0.8 * specMul);

            // playing groove: the stylus line glows on the beat
            float playR = length(sty.xz);
            float hot = exp(-abs(r - playR) * 400.0);
            // brightest just behind the stylus, fading round the turn
            float behind = fract((atan2_(q.y, q.x) - atan2_(sty.z, sty.x)) / 6.2831853 + 1.0);
            hot *= 0.15 + 0.85 * exp(-behind * 5.0);
            col += peak * hot * (0.1 + 1.6 * bassI) * needle;
        }
    } else {
        // ---- platter lip, strobe dots, plinth and the studio ----
        vec3 bg = vyStudio(rd, u, sweepOn, teal, P, fog, false);
        col = bg;
        float tP = rd.y < -1e-4 ? (VY_PLINTH - ro.y) / rd.y : -1.0;
        // platter side: a cylinder of strobe dots under the record
        float a2 = max(dot(rd.xz, rd.xz), 1e-6);
        float b2 = dot(ro.xz, rd.xz);
        float c2 = dot(ro.xz, ro.xz) - VY_PLATTER * VY_PLATTER;
        float h2 = b2 * b2 - a2 * c2;
        bool side = false;
        if (h2 > 0.0) {
            float tc = (-b2 - sqrt(h2)) / a2;
            vec3 cp = ro + rd * tc;
            if (tc > 0.0 && cp.y < 0.0 && cp.y > VY_PLINTH + 0.01) {
                side = true;
                tHit = tc;
                float ca = atan2_(cp.z, cp.x) - spin;
                float dotsA = fract(ca / 6.2831853 * 90.0) - 0.5;
                float row = abs(cp.y + 0.03) - 0.008;
                float dots = smoothstep(0.25, 0.1, abs(dotsA)) * smoothstep(0.004, 0.0, row);
                vec3 cn = vec3(cp.x, 0.0, cp.z) / VY_PLATTER;
                float lit = 0.1 + 0.9 * saturate(dot(cn, Lk));
                col = vec3(0.03, 0.03, 0.035) * lit + trace * dots * (1.0 + 2.5 * bassI);
                col += vyStudio(reflect(rd, cn), u, sweepOn, teal, P, fog, true) * 0.3;
            }
        }
        if (!side && tRec > 0.0 && rr < VY_PLATTER) {
            // platter lip around the record edge
            tHit = tRec;
            col = vec3(0.04) + vec3(0.9, 0.85, 0.8) * pow(saturate(dot(reflect(-Lk, vec3(0.0, 1.0, 0.0)), -rd)), 8.0) * 0.3;
        } else if (!side && tP > 0.0) {
            // glossy black plinth
            tHit = tP;
            vec3 pp = ro + rd * tP;
            vec3 pr = reflect(rd, vec3(0.0, 1.0, 0.0));
            float fres = 0.04 + 0.96 * pow(1.0 - saturate(-rd.y), 5.0);
            float pd = length(pp.xz);
            col = vyStudio(pr, u, sweepOn, teal, P, fog, detail < 0.5) * fres * 0.35 * exp(-pd * 0.6) + vec3(0.003);
            col = mix(col, bg, smoothstep(1.5, 5.0, pd));
            // the platter's glow spills onto the plinth
            float pl = length(pp.xz) - VY_PLATTER;
            col += trace * exp(-max(pl, 0.0) * 12.0) * 0.05 * (1.0 + 2.0 * bassI);
        }
    }

    // ---- chrome tonearm, composited over with its antialiased coverage ----
    if (armA > 0.0) {
        vec3 n = normalize(armN);
        vec3 refl = vyStudio(reflect(rd, n), u, sweepOn, teal, P, fog, true);
        float fres = 0.5 + 0.5 * pow(1.0 - saturate(-dot(rd, n)), 3.0);
        float spk = pow(saturate(dot(reflect(-Lk, n), -rd)), 60.0);
        float spr = pow(saturate(dot(reflect(-Lr, n), -rd)), 30.0);
        float spf = pow(saturate(dot(reflect(-Lf, n), -rd)), 40.0);
        vec3 ac = refl * fres * 0.9 + vec3(1.4, 1.35, 1.3) * spk * 2.0 + P.b * spr * 1.5 + fillC * spf * 1.2;
        ac += vec3(0.01);
        col = mix(col, ac, armA);
        tHit = min(tHit, tArm);
    }

    // a soft shaft of the softbox's light through the haze, dust lit inside it
    vec2 sh = vySegRay(ro, rd, vec3(-0.9, 1.7, 1.25), vec3(0.15, 0.0, 0.1));
    float shW = 0.16 + 0.1 * (1.0 - saturate(sh.y));
    float shaft = exp(-sh.x * sh.x / (shW * shW)) * smoothstep(0.0, 0.3, tHit - sh.y + 0.3);
    col += mix(vec3(1.0, 0.9, 0.8), P.c, 0.35) * shaft * (0.025 + 0.04 * u.mid + 0.05 * sweepOn);

    // stylus spark on the bass, a small hot glint at the contact point
    vec3 so = sty - ro;
    float sa = dot(so, rd);
    if (sa > 0.0) {
        float sd2 = max(dot(so, so) - sa * sa, 0.0) / (sa * sa);
        float spark = 3e-6 / (sd2 + 3e-6) + 0.02 * exp(-sd2 * 4000.0);
        col += palRoleBass(0.1, u) * spark * needle * (0.3 + 1.5 * bassI + 0.8 * u.flux);
    }

    // dust motes drifting through the key light
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        vec2 h = hash22(vec2(fi, 2.7));
        vec3 mp = vec3((h.x - 0.5) * 1.6, 0.05 + 0.35 * fract(h.y + tm * 0.01 * (1.0 + h.x)), (h.y - 0.5) * 1.6);
        mp.xz += 0.05 * vec2(sin(tm * 0.3 + fi), cos(tm * 0.23 + fi * 1.7));
        vec3 mo = mp - ro;
        float ma = dot(mo, rd);
        if (ma <= 0.0 || ma > tHit) continue;
        float md2 = max(dot(mo, mo) - ma * ma, 0.0) / (ma * ma);
        float m = 1.5e-6 / (md2 + 1.5e-6);
        col += vec3(1.0, 0.9, 0.8) * m * (0.15 + 0.8 * u.treble);
    }

    return col; // LINEAR HDR — post chain tonemaps
}
