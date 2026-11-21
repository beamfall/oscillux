// SPDX-License-Identifier: AGPL-3.0-only
// Reactor.
// A slow orbit around a fusion core held in a gimbal of containment rings. The
// core is a white-hot sphere of boiling plasma with a bright limb and corona;
// its light fills the haze of the chamber, glints off the machined rings and
// the wet floor, and the air around it shimmers with heat. Spectrum arcs run
// round the inner face of every ring (lows on the inner ring, highs outside),
// a steady drift of sparks rises gently with the level; the field tags, guide
// ring and beam glow a little brighter with the smoothed level, never the core
// light. Every second beat the core sheds a faint eased shell of plasma
// (alternating colours of matched brightness) that washes over the rings and
// runs on across the floor; a cool bounce light from the chamber answers the
// warm core. The arcs and plasma texture flow continuously, the orbit is a
// slow steady drift with a fixed roll, and audio drives soft light only, never
// the camera or sudden flashes.
// param0 = Core (size and heat) ; param1 = Orbit Count (two to four rings) ;
// param2 = Sparks

const float RC_WALL = 15.0;    // chamber wall radius
const float RC_FLOOR = -3.6;   // floor height
const float RC_BOUND = 4.6;    // bounding sphere of the rings

float rcNoise3(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x);
    float b = mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x);
    float c = mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x);
    float d = mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

// ring k: radius, half thickness (radial, axial)
vec3 rcRingSize(int k) {
    float fk = float(k);
    return vec3(1.85 + 0.68 * fk, 0.11 + 0.015 * fk, 0.21 - 0.025 * fk);
}

// Ring frames are rotations about two axes, eased, slow.
mat3 rcRingFrame(int k, float ang) {
    float fk = float(k);
    float a = ang * (0.55 + 0.25 * fk) * (mod(fk, 2.0) < 0.5 ? 1.0 : -1.0) + fk * 1.3;
    float b = 0.35 + 0.42 * fk + 0.25 * sin(ang * 0.3 + fk);
    float ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b);
    mat3 ry = mat3(ca, 0.0, -sa, 0.0, 1.0, 0.0, sa, 0.0, ca);
    mat3 rx = mat3(1.0, 0.0, 0.0, 0.0, cb, sb, 0.0, -sb, cb);
    return rx * ry;
}

float rcBox2(vec2 p, vec2 b) {
    vec2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// distance to ring k in its own frame q; magnet blocks on the outer ring
float rcRing(vec3 q, int k, int nRing) {
    vec3 s = rcRingSize(k);
    float rad = length(q.xz);
    float d = rcBox2(vec2(rad - s.x, q.y), s.yz) - 0.02;
    // a groove down the inner face carries the spectrum arc
    d = max(d, -rcBox2(vec2(rad - s.x + s.y, q.y), vec2(0.04, 0.045)));
    if (k == nRing - 1) {
        float a = atan2_(q.z, q.x);
        float sec = 6.2831853 / 16.0;
        float ai = (floor(a / sec) + 0.5) * sec;
        vec2 cs = vec2(cos(ai), sin(ai));
        vec3 lq = vec3(dot(q.xz, cs) - s.x - 0.05, q.y, dot(q.xz, vec2(-cs.y, cs.x)));
        d = min(d, osBox(lq, vec3(0.16, s.z + 0.08, 0.14)) - 0.02);
    }
    return d;
}

float rcMap(vec3 p, mat3 f0, mat3 f1, mat3 f2, mat3 f3, int nRing, out int id) {
    float d = rcRing(f0 * p, 0, nRing);
    id = 0;
    float e = rcRing(f1 * p, 1, nRing);
    if (e < d) { d = e; id = 1; }
    if (nRing > 2) {
        e = rcRing(f2 * p, 2, nRing);
        if (e < d) { d = e; id = 2; }
    }
    if (nRing > 3) {
        e = rcRing(f3 * p, 3, nRing);
        if (e < d) { d = e; id = 3; }
    }
    return d;
}

// How much core light reaches pos past the rings: light leaves the centre
// radially, so ring k blocks pos when pos lies beyond it and within the band's
// angular height in the ring's frame.
float rcRingVis(vec3 q, int k) {
    vec3 s = rcRingSize(k);
    float rxz = length(q.xz);
    float slope = abs(q.y) / max(rxz, 1e-3);
    float edge = (s.z + 0.02) / s.x;
    float beyond = smoothstep(s.x - s.y, s.x + s.y, length(q));
    return 1.0 - beyond * (1.0 - smoothstep(edge * 0.85, edge * 1.15, slope));
}

float rcVis(vec3 p, mat3 f0, mat3 f1, mat3 f2, mat3 f3, int nRing) {
    float v = rcRingVis(f0 * p, 0) * rcRingVis(f1 * p, 1);
    if (nRing > 2) v *= rcRingVis(f2 * p, 2);
    if (nRing > 3) v *= rcRingVis(f3 * p, 3);
    return v;
}

// in-scattered light of a point source at the origin along ro + rd*t, t in [0, tm]
float rcScatter(vec3 ro, vec3 rd, float tm, float soft) {
    float tc = -dot(ro, rd);
    float h2 = max(dot(ro, ro) - tc * tc, 0.0) + soft * soft;
    float h = sqrt(h2);
    return (atan((tm - tc) / h) - atan(-tc / h)) / h;
}

// Chamber wall at pos: dark ribbed panels lit by the core, and vertical light
// strips that rise with the spectrum.
vec3 rcWall(vec3 pos, vec3 coreLight, vec3 coolFill, float vis, VisualUniforms u) {
    float a = atan2_(pos.z, pos.x);
    float rib = abs(fract(a * 48.0 / 6.2831853) - 0.5);
    float ribs = smoothstep(0.30, 0.5, rib);
    float bands = smoothstep(0.46, 0.5, abs(fract(pos.y * 0.35) - 0.5));
    float lit = 1.0 / (1.0 + pos.y * pos.y * 0.06);
    vec3 col = coreLight * vec3(0.0026, 0.0029, 0.0034) * vis * lit * (0.35 + 0.65 * ribs) * (1.0 - 0.6 * bands);
    float sid = floor(a * 12.0 / 6.2831853);
    float sx = abs(fract(a * 12.0 / 6.2831853) - 0.5);
    float strip = (1.0 - smoothstep(0.004, 0.012, sx)) * smoothstep(RC_FLOOR, RC_FLOOR + 0.6, pos.y);
    float sl = bandAt(u, fract(sid / 12.0 + 0.03));
    float rise = smoothstep(sl * 10.0 + 0.6, sl * 10.0, pos.y - RC_FLOOR);
    col += palRoleTrace(0.55 + sid / 24.0, u) * strip * (0.06 + 2.2 * rise);
    // cool bounce light off the panels, against the warm key of the core
    col += coolFill * 0.014 * lit * (0.3 + 0.7 * ribs) * (1.0 - 0.6 * bands);
    return col;
}

// ray from ro along rd to the chamber wall (ro inside it)
float rcWallT(vec3 ro, vec3 rd) {
    float bw = dot(ro.xz, rd.xz);
    float aw = max(dot(rd.xz, rd.xz), 1e-4);
    float cw = dot(ro.xz, ro.xz) - RC_WALL * RC_WALL;
    return (-bw + sqrt(max(bw * bw - aw * cw, 0.0))) / aw;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float tm = mod(u.time, 600.0);

    // ---- camera: slow orbit on the speed profile, eased roll ----
    vec2 fl = osFlight(u, 0.06, 0.0);
    float orb = 0.06 * u.time + 0.1 * fl.x;
    float rush = saturate((fl.y - 1.0) / 3.5);
    float camR = 5.9 + 0.45 * sin(tm * 0.031);
    float elev = 0.13 + 0.10 * sin(tm * 0.047 + 1.0);
    vec3 ro = camR * vec3(cos(elev) * cos(orb), sin(elev), cos(elev) * sin(orb));
    vec2 ph = p;

    // ---- heat shimmer: the air near the core bends the view ----
    float coreR = mix(0.85, 1.3, u.param0) * (1.0 + 0.0 * u.bassImpact);
    float heatAmt = 0.006 + 0.002 * u.level;
    vec2 hw = vec2(vnoise(p * 9.0 + vec2(0.0, -tm * 0.9)), vnoise(p * 9.0 + vec2(5.2, -tm * 1.1))) - 0.5;
    float nearCore = exp(-dot(p, p) * 2.2);
    ph += hw * heatAmt * nearCore;
    float fov = 1.35 - 0.02 * rush;
    vec3 rd = osCamera(ro, vec3(0.0), 0.05, fov, ph);

    int nRing = int(mix(2.0, 4.99, saturate(u.param1)));
    mat3 f0 = rcRingFrame(0, orb * 0.9 + tm * 0.05);
    mat3 f1 = rcRingFrame(1, orb * 0.9 + tm * 0.05);
    mat3 f2 = rcRingFrame(2, orb * 0.9 + tm * 0.05);
    mat3 f3 = rcRingFrame(3, orb * 0.9 + tm * 0.05);

    float heat = (0.75 + 0.5 * u.param0) * (1.1 + 0.15 * u.level);
    // core colours: a saturated body and a hotter, paler crest
    vec3 cb0 = palRoleBass(0.15, u);
    // blackbody orange steered by the palette, so the core always reads as fire
    vec3 cb1 = max(mix(vec3(luma(cb0)), cb0, 1.5), vec3(0.0));
    vec3 coreTint = cb1 / max(max(cb1.r, max(cb1.g, cb1.b)), 0.05);
    vec3 coreBody = mix(vec3(1.0, 0.36, 0.07), vec3(1.0, 0.36, 0.07) * coreTint, 0.3);
    vec3 coreHot = peakWhite(palVisual(0.32 + 0.06 * u.spectralCentroid, u), 0.4);
    vec3 coreLight = mix(coreBody, coreHot, 0.35) * heat;
    // cool fill from the chamber, the complement of the core's fire
    vec3 coolFill = palVisual(0.88, u);

    // ---- beat shockwave: every beat the core throws off a shell of plasma
    // that sweeps out through the rings and across the floor; alternate beats
    // alternate its colour ----
    float bp = saturate(u.beatPhase);
    // a swell that rises and falls within the beat: zero on the kick
    float swell = sin(3.14159265 * bp);
    swell *= swell;
    float sp = saturate((mod(floor(u.beatCount), 2.0) + bp) * 0.5);
    float shR = coreR + sp * (3.4 + 0.6 * u.bass);
    float shW = 0.07 + 0.20 * sp;
    float shA = (0.2 + 0.1 * u.level) * pow(1.0 - sp, 1.3) * smoothstep(0.0, 0.25, sp);
    // where the shell lands on the floor it runs on as a ground wave
    float gwR = sp * (8.0 + 1.5 * u.bass);
    vec3 shA0 = palVisual(0.74, u), shB0 = palVisual(0.52, u);
    float shL = min(luma(shA0), luma(shB0));
    vec3 shCol = mix(shA0 * shL / max(luma(shA0), 1e-3), shB0 * shL / max(luma(shB0), 1e-3),
                     step(0.5, mod(floor(u.beatCount * 0.5), 2.0)));

    // ---- core sphere (analytic) ----
    float b = dot(ro, rd);
    float c = dot(ro, ro) - coreR * coreR;
    float disc = b * b - c;
    float tCore = disc > 0.0 ? -b - sqrt(disc) : 1e4;

    // ---- rings (bounded march) ----
    float tHit = 1e4;
    int hid = 0;
    float dMin = 1e3;
    int nid = 0;
    float cb = dot(ro, ro) - RC_BOUND * RC_BOUND;
    float db = b * b - cb;
    if (db > 0.0) {
        float t = max(-b - sqrt(db), 0.0);
        float tEnd = min(-b + sqrt(db), tCore);
        int n = osSteps(32.0, 64.0, detail);
        for (int i = 0; i < 64; i++) {
            if (i >= n || t > tEnd) break;
            int id;
            float d = rcMap(ro + rd * t, f0, f1, f2, f3, nRing, id);
            if (d < dMin) { dMin = d; nid = id; }
            if (d < 0.0015 * t) { tHit = t; hid = id; break; }
            t += d * 0.9;
        }
    }

    vec3 col = vec3(0.0);
    float tSurf;
    if (tHit < tCore && tHit < 1e3) {
        tSurf = tHit;
        vec3 pos = ro + rd * tHit;
        vec2 e = vec2(0.0015, 0.0);
        int dummy;
        vec3 n = normalize(vec3(
            rcMap(pos + e.xyy, f0, f1, f2, f3, nRing, dummy) - rcMap(pos - e.xyy, f0, f1, f2, f3, nRing, dummy),
            rcMap(pos + e.yxy, f0, f1, f2, f3, nRing, dummy) - rcMap(pos - e.yxy, f0, f1, f2, f3, nRing, dummy),
            rcMap(pos + e.yyx, f0, f1, f2, f3, nRing, dummy) - rcMap(pos - e.yyx, f0, f1, f2, f3, nRing, dummy)) + 1e-6);
        // light from the core
        float r = max(length(pos), 1e-3);
        vec3 l = -pos / r;
        float dif = saturate(dot(n, l));
        float fall = 1.0 / (0.35 + r * r * 0.22);
        vec3 refl = reflect(rd, n);
        // glossy reflection of the core sphere
        float rb = dot(pos, refl);
        float rc2 = dot(pos, pos) - rb * rb;
        float glint = rb < 0.0 ? exp(-max(rc2 - coreR * coreR, 0.0) * 1.3) : 0.0;
        float fres = 0.15 + 0.85 * pow(1.0 - saturate(-dot(rd, n)), 4.0);
        mat3 fr = hid == 0 ? f0 : hid == 1 ? f1 : hid == 2 ? f2 : f3;
        vec3 q = fr * pos;
        float ang = atan2_(q.z, q.x);
        float turn = ang / 6.2831853 + 0.5;
        // machined panels: fine radial grooves
        float groove = 0.7 + 0.3 * smoothstep(0.0, 0.25, abs(fract(turn * 64.0) - 0.5));
        vec3 metal = vec3(0.045, 0.047, 0.055) * groove;
        float rvis = rcVis(pos * 0.995, f0, f1, f2, f3, nRing);
        col = metal * coreLight * (0.25 + dif * 1.6 * rvis) * fall;
        col += coreLight * glint * (0.3 + 1.6 * fres) * 1.4;
        // broad brushed-metal lobe toward the core
        col += coreLight * pow(saturate(dot(refl, l)), 10.0) * 0.35 * rvis * fall * 4.0;
        col += palRoleFog(0.3, u) * 0.03 * fres * saturate(refl.y * 0.5 + 0.6);
        // the chamber strips slide across the polished metal
        vec3 rw = pos + refl * rcWallT(pos, refl);
        col += rcWall(rw, coreLight, coolFill, 1.0, u) * (0.25 + 0.75 * fres) * 0.8;
        // cool rim from the chamber
        col += palRoleRim(0.18, u) * pow(1.0 - saturate(-dot(rd, n)), 3.0) * 0.05;
        // spectrum arc in the groove on the inner face
        vec3 s = rcRingSize(hid);
        float rq = length(q.xz);
        float inGroove = (1.0 - smoothstep(0.035, 0.05, abs(q.y))) *
                         (1.0 - smoothstep(0.02, 0.06, rq - (s.x - s.y + 0.04)));
        float fb = (float(hid) + fract(turn * 2.0)) / 4.0;
        float lvl = bandAt(u, fb);
        float flow = 0.55 + 0.45 * sin(turn * 6.2831853 * 6.0 - tm * (0.6 + 0.2 * float(hid)));
        vec3 arcCol = palRoleTrace(0.12 + 0.18 * float(hid) + 0.25 * turn + 0.1 * u.spectralCentroid, u);
        col += arcCol * inGroove * (2.5 + 2.5 * lvl) * flow;
        // the shockwave washes over the metal as it passes
        col += shCol * shA * exp(-pow((r - shR) / (shW * 0.6), 2.0)) * (0.1 + 1.2 * fres) * 0.7;
        // light strips on the magnet blocks
        if (hid == nRing - 1) {
            float tag = (1.0 - smoothstep(0.02, 0.035, abs(q.y - s.z - 0.04))) * step(s.x + 0.1, rq);
            col += palRoleBass(0.3, u) * tag * (0.9 + 0.15 * u.level + 0.1 * swell * u.level);
        }
    } else if (tCore < 1e3) {
        tSurf = tCore;
        vec3 pos = ro + rd * tCore;
        vec3 n = pos / coreR;
        // plasma: field-line filaments wound round a tilted axis, warped by
        // slow 3D noise, over a white-hot centre and a saturated limb
        float sp = tm * 0.08;
        vec3 q = vec3(n.x * cos(sp) - n.z * sin(sp), n.y, n.x * sin(sp) + n.z * cos(sp));
        float w = rcNoise3(q * 2.2 + vec3(0.0, tm * 0.12, 0.0));
        float g = detail > 0.5 ? rcNoise3(q * 5.0 + w * 2.0 - vec3(tm * 0.14)) : 0.5;
        vec3 ax = normalize(vec3(0.35, 1.0, 0.2));
        float lat = dot(n, ax);
        vec3 tg = normalize(cross(ax, n) + 1e-4);
        float lon = atan2_(dot(tg, vec3(0.0, 0.0, 1.0)), dot(tg, vec3(1.0, 0.0, 0.0)));
        float wind = lat * 16.0 + lon * 1.0 + (w - 0.5) * 6.0 + (g - 0.5) * 4.0 - tm * 0.5;
        float fil = pow(0.5 + 0.5 * sin(wind), 7.0);
        float fil2 = pow(0.5 + 0.5 * sin(wind * 2.3 + 1.7 + tm * 0.25), 9.0);
        float mu = saturate(-dot(rd, n));
        float limb = pow(1.0 - mu, 2.5);
        // temperature: deep red body, orange-gold filaments, white-hot centre
        float temp = 0.2 * w * w + 0.5 * fil + 0.35 * fil2 + 0.75 * pow(mu, 6.0) * (0.6 + 0.8 * g) + 0.45 * limb;
        vec3 fire = mix(vec3(0.62, 0.2, 0.03), vec3(1.0, 0.38, 0.06), smoothstep(0.0, 0.45, temp));
        fire = mix(fire, vec3(1.0, 0.82, 0.55), smoothstep(0.5, 1.2, temp));
        fire = mix(fire, fire * coreTint, 0.3);
        col = fire * (0.25 + 2.6 * temp) * heat;
    } else {
        // ---- chamber: wet floor and ribbed wall ----
        float tf = rd.y < -1e-3 ? (RC_FLOOR - ro.y) / rd.y : 1e4;
        float tw = rcWallT(ro, rd);
        if (tf < tw) {
            tSurf = tf;
            vec3 pos = ro + rd * tf;
            float r = length(pos);
            // wet, slightly rippled black floor: mirror of the core and the wall strips
            vec2 rip = vec2(vnoise(pos.xz * 2.1 + vec2(0.0, tm * 0.2)), vnoise(pos.zx * 2.1)) - 0.5;
            vec3 rr = normalize(vec3(rd.x + rip.x * 0.03, -rd.y, rd.z + rip.y * 0.03));
            float rb = dot(pos, rr);
            float rc2 = max(dot(pos, pos) - rb * rb, 0.0);
            vec2 tile = abs(fract(pos.xz * 0.5) - 0.5);
            float seam = 1.0 - smoothstep(0.0, 0.02, min(tile.x, tile.y));
            float wet = smoothstep(0.25, 0.75, vnoise(pos.xz * 0.9 + 3.0));
            float fres = 0.2 + 0.8 * pow(1.0 - saturate(-rd.y), 5.0);
            float mirror = rb > 0.0 ? exp(-max(rc2 - coreR * coreR, 0.0) * (0.5 + 2.5 * (1.0 - wet))) : 0.0;
            float fvis = rcVis(pos, f0, f1, f2, f3, nRing);
            col = coreLight * 0.04 * fvis / (1.0 + r * r * 0.12) * (1.0 - 0.7 * seam);
            col += coreLight * mirror * (0.15 + 0.6 * wet) * (1.0 - 0.8 * seam);
            vec3 rw = pos + rr * rcWallT(pos, rr);
            col += rcWall(rw, coreLight, coolFill, 1.0, u) * fres * (0.3 + 0.7 * wet) * (1.0 - 0.8 * seam);
            // a glowing guide ring set in the floor under the core
            float fr = length(pos.xz);
            float guide = exp(-pow((fr - 5.2) * 10.0, 2.0)) + 0.5 * exp(-pow((fr - 6.0) * 16.0, 2.0));
            col += palRoleTrace(0.4 + 0.05 * sin(atan2_(pos.z, pos.x) * 3.0), u) * guide * (0.6 + 0.1 * u.level + 0.05 * swell);
            // the shockwave's footprint racing out over the wet floor, and its mirror
            float fq = length(pos.xz) - gwR;
            float shF = exp(-fq * fq * 18.0) + 0.18 * exp(-max(-fq, 0.0) * 1.2) * step(fq, 0.0);
            col += shCol * shA * shF * (0.25 + 0.9 * wet) * (1.0 - 0.6 * seam) * 0.5;
            col += coolFill * 0.010 * (0.4 + 0.6 * wet) * (1.0 - 0.7 * seam);
        } else {
            tSurf = tw;
            vec3 pw = ro + rd * tw;
            col = rcWall(pw, coreLight, coolFill, rcVis(pw, f0, f1, f2, f3, nRing), u);
        }
    }

    // ---- arcs bloom past the ring edges ----
    if (tHit > 1e3) {
        vec3 hc = palRoleTrace(0.12 + 0.18 * float(nid) + 0.1 * u.spectralCentroid, u);
        col += hc * exp(-dMin * 22.0) * (0.06 + 0.06 * bandAt(u, float(nid) / 4.0 + 0.1));
    }

    // ---- injector beam: a thin column of light feeding the core ----
    {
        vec2 rxz = rd.xz;
        float l2 = max(dot(rxz, rxz), 1e-5);
        float tb = -dot(ro.xz, rxz) / l2;
        float db = abs(ro.x * rxz.y - ro.z * rxz.x) / sqrt(l2);
        float yb = ro.y + rd.y * tb;
        if (tb > 0.0 && tb < tSurf && abs(yb) > coreR * 0.9) {
            float pulse = 0.55 + 0.45 * sin(abs(yb) * 3.0 + tm * 2.0);
            float beam = exp(-db * db * 900.0) * 1.6 + exp(-db * db * 40.0) * 0.12;
            col += palRoleTrace(0.62 + 0.1 * u.spectralCentroid, u) * beam * pulse * (1.0 + 0.15 * u.level + 0.05 * swell)
                   * smoothstep(9.0, 2.0, abs(yb));
        }
    }

    // ---- volumetric glow of the core in the chamber haze ----
    float tv = min(tSurf, 40.0);
    float scat = rcScatter(ro, rd, tv, coreR * 0.9);
    // light shafts: weight the rings' shadow along the ray by the light density
    {
        float tc0 = -b;
        float hd2 = max(dot(ro, ro) - tc0 * tc0, 0.0);
        int ns = osSteps(5.0, 14.0, detail);
        float span = 7.0;
        float t0 = max(tc0 - span, 0.0);
        float t1 = min(tc0 + span, tv);
        float dt = (t1 - t0) / float(ns);
        float jit = hash21(uv * u.resolution);
        float sw = 0.0, sv = 0.0;
        for (int i = 0; i < 14; i++) {
            if (i >= ns) break;
            float ts = t0 + (float(i) + jit) * dt;
            vec3 ps = ro + rd * ts;
            float w = 1.0 / (dot(ps, ps) + 0.6);
            sv += w * rcVis(ps, f0, f1, f2, f3, nRing);
            sw += w;
        }
        scat *= t1 > t0 ? mix(0.12, 1.0, sv / max(sw, 1e-5)) : 1.0;
    }
    vec3 hazeCol = mix(coolFill * 1.2, coreBody, 0.5);
    col += hazeCol * scat * 0.032 * heat * 1.05;
    // tight corona just outside the limb
    float tc = -b;
    float dperp = sqrt(max(dot(ro, ro) - tc * tc, 0.0));
    if (tSurf > tc) {
        float cor = exp(-max(dperp - coreR, 0.0) * 5.5) * step(coreR, dperp);
        float crn = rcNoise3(vec3(normalize(ro + rd * tc + 1e-4) * 3.0 + tm * 0.3));
        col += mix(coreBody, coreHot, 0.4) * cor * (0.4 + 0.9 * crn) * 0.9 * heat;
    }

    // ---- the shockwave shell in the haze: brightest where seen edge-on ----
    {
        float h = shR * shR - dperp * dperp;
        float cap = sqrt(2.0 * shR * shW);
        float sOut = sqrt(max(h, 0.0));
        float g = h > 0.0 ? min(shR * shW / max(sOut, 1e-3), cap) : cap * exp(-pow((dperp - shR) / shW, 2.0));
        float tn = tc - sOut, tf = tc + sOut;
        float vis = (tn > 0.0 && tn < tSurf ? 1.0 : 0.0) + (tf > 0.0 && tf < tSurf ? 0.7 : 0.0);
        vec3 dn = normalize(ro + rd * max(tn, 0.0) + 1e-4);
        float tex = 0.45 + 0.9 * rcNoise3(dn * 3.5 + vec3(tm * 0.2, tm * 0.15, 0.0));
        col += shCol * shA * g * vis * tex * 0.22;
    }

    // ---- sparks: streaks flung out of the core ----
    // The camera looks at the core, so sparks fly outward from the screen
    // centre. Each layer splits the circle into sectors holding one spark;
    // a pixel checks its own sector and the nearer neighbour.
    float sparkAmt = mix(0.3, 1.6, u.param2);
    float burst = 0.6 + 0.0 * u.onset + 0.0 * u.flux + 0.1 * u.level;
    float coreScr = coreR * fov / camR;
    float pr = length(p);
    float pa = atan2_(p.y, p.x) / 6.2831853 + 0.5;
    vec3 spkA = palRoleTreble(0.1 + 0.15 * u.spectralCentroid, u);
    vec3 spkB = peakWhite(palRolePeak(0.85, u), 0.4);
    vec3 spk = vec3(0.0);
    int nLayer = osSteps(1.0, 3.0, detail);
    for (int L = 0; L < 3; L++) {
        if (L >= nLayer) break;
        float fL = float(L);
        float ns = 28.0 + 12.0 * fL;
        float x = pa * ns + fL * 0.37;
        float k0 = floor(x);
        float k1 = k0 + (fract(x) < 0.5 ? -1.0 : 1.0);
        for (int j = 0; j < 2; j++) {
            float k = mod(j == 0 ? k0 : k1, ns);
            float h = hash21(vec2(k, fL * 17.0 + 3.0));
            float rate = 0.16 + 0.24 * h;
            float lt = tm * rate + hash21(vec2(k * 1.7, fL + 9.0));
            float life = fract(lt);
            float gen = mod(floor(lt), 97.0);
            float hg = hash21(vec2(k + gen * 3.1, fL * 5.0 + gen));
            // angle within the sector, with a slight magnetic swirl
            float ang = (k + 0.2 + 0.6 * hg - fL * 0.37 + 0.35 * life * (hg - 0.5)) / ns;
            ang = (ang - 0.5) * 6.2831853;
            vec2 dir = vec2(cos(ang), sin(ang));
            float reach = 0.35 + 1.3 * h * h;
            float rr = coreScr * (1.0 + 0.2 * hg) + life * reach;
            float len = (0.03 + 0.10 * h) * (1.0 - 0.5 * life) * (0.7 + 0.6 * burst) ;
            vec2 q = p - dir * rr;
            float al = dot(q, dir);
            float pe = dot(q, vec2(-dir.y, dir.x));
            float along = saturate(-al / max(len, 1e-3));
            float body = step(al, 0.004) * (1.0 - along);
            float w = 0.0016 + 0.0018 * (1.0 - life);
            float s1 = exp(-pe * pe / (w * w)) * body * body;
            float head = 1.2e-5 / (dot(q, q) + 1.2e-5);
            float fade = (1.0 - life) * smoothstep(0.0, 0.04, life) * step(hg, 0.2 + 0.4 * saturate(burst));
            spk += mix(spkA, spkB, hg) * (s1 * 1.4 + head) * fade;
        }
    }
    // sparks behind a ring in front of the core are hidden
    float occl = tHit < camR - 0.5 ? 0.25 : 1.0;
    col += spk * burst * sparkAmt * 1.6 * occl;

    col = accentize(col, u.accent, 0.10);
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
