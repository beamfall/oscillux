// SPDX-License-Identifier: AGPL-3.0-only
// Glyph.
// A monumental spectral sigil, machined from dark lathe-turned metal and
// extruded in depth: broken concentric rings whose segments push forward like a
// 3D equalizer, a notched outer crown and a blazing core lens. The core sits
// just behind the plane, so its warm light pours out through every gap in the
// rings as volumetric shafts and pools on a brushed back plate, silhouetting
// the sigil; the segments' inlays answer in a cool complementary glow. The
// camera orbits slowly on the shared speed profile, so the turn cruises,
// builds, surges and brakes; audio drives the light and the segment depth,
// never the camera.
// param0 = Rings ; param1 = Rotation ; param2 = Glyph Density

const float GY_R0 = 0.52;    // first ring radius
const float GY_SP = 0.165;   // ring spacing
const float GY_TH = 0.052;   // ring half-thickness, radial
const float GY_BACK = 0.07;  // how far every segment reaches behind the plane
const float GY_ROUT = 1.78;  // crown radius
const float GY_PLATE = -1.15; // back plate depth
const vec3 GY_LIGHT = vec3(0.0, 0.0, -0.55);

// The palette read once at five stops, blended locally.
struct GyPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

GyPal gyPalLoad(VisualUniforms u) {
    GyPal P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 gyPal(GyPal P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

vec3 gySat(vec3 c, float k) {
    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return max(mix(vec3(l), c, k), 0.0);
}

// Dash count of ring k.
float gyDashes(float k, float density) { return density + 4.0 * k; }

// Ring k's rotation: alternate directions, slower outward.
float gyRingRot(float k, float spin) {
    float dir = mod(k, 2.0) < 0.5 ? 1.0 : -1.0;
    return dir * spin * (1.0 - 0.07 * k) + k * 0.71;
}

// Depth of dash j of ring k from the spectrum: the ring spans the spectrum
// mirrored left/right, inner rings lean on the bass.
float gyDepth(float k, float j, float n, VisualUniforms u) {
    float f = abs(fract((j + 0.5) / n) * 2.0 - 1.0);
    int bi = int(clamp(f * 34.0 + k * 4.0, 0.0, 63.0));
    float b = band(u, bi);
    return 0.03 + 0.75 * b * (0.6 + 0.4 * b);
}

// One dash: ring k, cell j (any integer, wrapped).
float gyDash(vec2 q, float z, float k, float j, float n, float rot, VisualUniforms u) {
    float jw = mod(j, n);
    float ac = (jw + 0.5) * 6.2831853 / n + rot;
    vec2 l = rot2(ac) * q;   // l.x radial, l.y tangential
    float rk = GY_R0 + k * GY_SP;
    float h = gyDepth(k, jw, n, u);
    float halfArc = rk * 3.14159265 / n * 0.74;
    vec3 c = vec3(l.x - rk, l.y, z - 0.5 * (h - GY_BACK));
    return osBox(c, vec3(GY_TH, halfArc, 0.5 * (h + GY_BACK))) - 0.006;
}

// Nearest ring and its neighbour, each with its nearest dash and neighbour.
// r and a are the point's polar coordinates in the sigil plane.
float gyRings(vec3 p, float r, float a, vec4 sp, VisualUniforms u) {
    float x = (r - GY_R0) / GY_SP;
    float k0 = clamp(floor(x + 0.5), 0.0, sp.x - 1.0);
    float k1 = clamp(k0 + (x > k0 ? 1.0 : -1.0), 0.0, sp.x - 1.0);
    float d = 1e3;
    for (int i = 0; i < 2; i++) {
        float k = i == 0 ? k0 : k1;
        // the neighbour ring cannot be nearer than its radial gap
        if (i == 1 && (k1 == k0 || d < abs(r - GY_R0 - k * GY_SP) - GY_TH - 0.006)) break;
        float n = gyDashes(k, sp.z);
        float rot = gyRingRot(k, sp.y);
        float ca = (a - rot) * n / 6.2831853 - 0.5;
        float j0 = floor(ca + 0.5);
        float j1 = j0 + (ca > j0 ? 1.0 : -1.0);
        d = min(d, gyDash(p.xy, p.z, k, j0, n, rot, u));
        // the neighbour dash lies beyond this cell's edge
        float edge = r * sin(min((0.5 - abs(ca - j0)) * 6.2831853 / n, 1.5));
        if (d > edge * 0.9) d = min(d, gyDash(p.xy, p.z, k, j1, n, rot, u));
    }
    return d;
}

// Notched crown, a thin outer halo ring and the core lens.
float gyCrown(vec3 p, float r, float a0, float spin, out float m) {
    vec2 w = vec2(abs(r - GY_ROUT) - 0.12, abs(p.z) - 0.16);
    float crown = min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - 0.01;
    // 48 notches cut into the front face; a cut only makes the crown farther,
    // so away from it the plain ring is a safe bound
    if (crown < 0.05) {
        float a = a0 - spin * 0.25;
        float cell = 6.2831853 / 48.0;
        float an = (fract(a / cell) - 0.5) * cell;
        vec3 nq = vec3(r * sin(an), r - GY_ROUT - 0.11, p.z - 0.16);
        crown = max(crown, -osBox(nq, vec3(0.028, 0.07, 0.06)));
    }
    // inner bevel step
    vec2 w2 = vec2(abs(r - GY_ROUT + 0.17) - 0.035, abs(p.z + 0.02) - 0.1);
    crown = min(crown, min(max(w2.x, w2.y), 0.0) + length(max(w2, 0.0)) - 0.006);
    // halo ring well outside
    vec2 w3 = vec2(abs(r - 2.45) - 0.025, abs(p.z + 0.25) - 0.03);
    float halo = min(max(w3.x, w3.y), 0.0) + length(max(w3, 0.0));
    float core = length(p - vec3(0.0, 0.0, -0.05)) - 0.26;
    m = crown < halo ? 1.0 : 2.0;
    float d = min(crown, halo);
    if (core < d) { m = 3.0; d = core; }
    return d;
}

// Open (> 0) or solid (< 0) at a point q of the sigil's plane: what the core
// light sees. Everything outside the crown's inner edge counts as solid.
float gyGap(vec2 q, vec4 sp) {
    float r = length(q);
    float x = (r - GY_R0) / GY_SP;
    float k = floor(x + 0.5);
    float open = min(GY_ROUT - 0.2 - r, r - GY_R0 + GY_TH + 0.01);
    if (open < 0.0) return open;
    if (k < 0.0 || k > sp.x - 1.0) return open;
    float a = atan2_(q.y, q.x);
    float rk = GY_R0 + k * GY_SP;
    float n = gyDashes(k, sp.z);
    float da = abs(fract((a - gyRingRot(k, sp.y)) * n / 6.2831853) - 0.5);
    float tang = (da - 0.37) * 6.2831853 * rk / n;
    return min(open, max(abs(r - rk) - GY_TH, tang));
}

float gyMap(vec3 p, vec4 sp, VisualUniforms u, out float m) {
    float r = length(p.xy);
    float a = atan2_(p.y, p.x);
    float d = gyCrown(p, r, a, sp.y, m);
    // the rings only exist in a slab around the plane
    float slab = max(abs(p.z - 0.36) - 0.44, abs(r - 1.0) - 0.62);
    if (slab < d) {
        float dr = max(slab, gyRings(p, r, a, sp, u));
        if (dr < d) { m = 0.0; d = dr; }
    }
    return d;
}

vec3 gyNormal(vec3 p, vec4 sp, VisualUniforms u) {
    float m;
    vec2 e = vec2(0.0015, -0.0015);
    vec3 n = e.xyy * gyMap(p + e.xyy, sp, u, m) + e.yyx * gyMap(p + e.yyx, sp, u, m) +
             e.yxy * gyMap(p + e.yxy, sp, u, m) + e.xxx * gyMap(p + e.xxx, sp, u, m);
    float l = length(n);
    return l > 1e-6 ? n / l : vec3(0.0, 0.0, 1.0);
}

// Ray / sphere at the origin: entry and exit distances, entry clamped to 0;
// (1, 0) on a miss so every loop over the span is empty.
vec2 gySphere(vec3 ro, vec3 rd, float r) {
    float b = dot(ro, rd);
    float h = b * b - dot(ro, ro) + r * r;
    if (h < 0.0) return vec2(1.0, 0.0);
    h = sqrt(h);
    return vec2(max(-b - h, 0.0), -b + h);
}

// Where the core's light through point s crosses the sigil plane (s in front).
vec2 gyProject(vec3 s) { return s.xy * (-GY_LIGHT.z / max(s.z - GY_LIGHT.z, 1e-3)); }

// Local frame of the nearest dash: radial and tangential offsets, its half
// arc and its ring index.
vec4 gyDashLocal(vec2 q, vec4 sp) {
    float r = length(q);
    float k = clamp(floor((r - GY_R0) / GY_SP + 0.5), 0.0, sp.x - 1.0);
    float n = gyDashes(k, sp.z);
    float rot = gyRingRot(k, sp.y);
    float j = floor((atan2_(q.y, q.x) - rot) * n / 6.2831853);
    float ac = (j + 0.5) * 6.2831853 / n + rot;
    vec2 l = rot2(ac) * q;
    float rk = GY_R0 + k * GY_SP;
    return vec4(l.x - rk, l.y, rk * 3.14159265 / n * 0.74, k);
}

// Studio reflection for the metal: a cool softbox overhead, a warm bounce
// from the core's side and near black elsewhere.
vec3 gyEnv(vec3 rf, vec3 warm, vec3 cool) {
    float box = smoothstep(0.35, 0.75, rf.y) * smoothstep(0.95, 0.3, abs(rf.x));
    float strip = smoothstep(0.86, 0.98, rf.x) * 0.6;
    return cool * (box * 0.55 + strip) + warm * 0.25 * smoothstep(0.2, -0.8, rf.z);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);

    float rings = floor(mix(4.0, 7.0, u.param0) + 0.5);
    float density = floor(mix(10.0, 26.0, u.param2) + 0.5);
    vec2 fl = osFlight(u, 1.0, 0.5);
    float ph = mod(fl.x, 2400.0);
    float spin = ph * mix(0.006, 0.05, u.param1);
    vec4 sp = vec4(rings, spin, density, 0.0);

    // slow orbit; the speed profile sets how fast it turns
    float orb = ph * 0.045;
    float yaw = 0.62 * sin(orb) + 0.18 * sin(orb * 0.43 + 1.0);
    float pitch = 0.22 * sin(orb * 0.71 + 0.6);
    float dist = 3.5 - 0.4 * sin(orb * 0.37 + 2.0);
    vec3 ro = dist * vec3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch));
    float roll = osBank(u, 0.08);
    vec3 rd = osCamera(ro, vec3(0.0, 0.0, 0.0), roll, 1.55, p);

    // light colours: a warm core against cool inlays and rims
    // the song's build pushes every hue a little further round the palette;
    // every eight beats the inlays ease to a new place in it
    GyPal P = gyPalLoad(u);
    float build = saturate((fl.y - 1.0) / 3.0);
    float b8 = (u.beatCount + saturate(u.beatPhase)) / 8.0;
    float k8 = floor(b8);
    float inHue = 0.14 * mix(sin(k8 * 2.39996), sin((k8 + 1.0) * 2.39996), smoothstep(0.0, 1.0, b8 - k8));
    vec3 warm = gyPal(P, 0.13 + 0.05 * u.spectralCentroid + 0.06 * build);
    vec3 ember = gyPal(P, 0.04);
    vec3 cool = gyPal(P, 0.76 + 0.04 * u.spectralCentroid);
    vec3 deep = gyPal(P, 0.97);
    // the beat ring: a front that runs out through the rings on every beat
    float bw = saturate(u.beatPhase) * (rings + 1.5) - 0.5;
    float bwAmp = (0.35 + 0.65 * u.bassImpact) * (1.0 - smoothstep(0.6, 1.0, saturate(u.beatPhase)));
    vec3 coreCol = peakWhite(warm, 0.35 + 0.3 * u.onset);
    float corePow = 0.8 + 1.4 * u.bassImpact + 0.5 * u.level;
    // the light that fills the frame answers the kick more gently than the
    // core itself, so a kick never jumps the whole frame's brightness
    float fillPow = 1.0 + 0.45 * u.bassImpact + 0.5 * u.level;

    // march only the slab that holds geometry, clipped by the bounding sphere
    vec2 bs = gySphere(ro, rd, 2.52);
    float pxa = 2.0 / (max(u.resolution.y, 1.0) * 1.55);   // pixel footprint per unit distance
    float zA = (0.82 - ro.z) / (abs(rd.z) > 1e-4 ? rd.z : -1e-4);
    float zB = (-0.32 - ro.z) / (abs(rd.z) > 1e-4 ? rd.z : -1e-4);
    float t = max(bs.x, min(zA, zB));
    float tEnd = min(bs.y, max(zA, zB));
    int n = osSteps(13.0, 52.0, detail);
    float m = -1.0;
    bool hit = false;
    for (int i = 0; i < 52; i++) {
        if (i >= n || t > tEnd) break;
        float mm;
        float d = gyMap(ro + rd * t, sp, u, mm);
        if (d < 0.0015 * t) { hit = true; m = mm; break; }
        t += d * 0.92;
    }

    vec3 col;
    float tHit = 1e3;
    if (!hit) {
        // brushed back plate, lit by the core in a warm pool
        float tp = rd.z < -1e-4 ? (GY_PLATE - ro.z) / rd.z : 1e3;
        col = deep * 0.002;
        if (tp < 60.0) {
            vec3 pp = ro + rd * tp;
            vec3 toL = GY_LIGHT - pp;
            float l2 = max(dot(toL, toL), 1e-3);
            float pr = length(pp.xy);
            float irr = toL.z / (l2 * sqrt(l2));
            // concentric machining and engraved ticks catch the light
            // fade the grooves out before they get finer than a pixel
            float fp = tp * pxa / max(-rd.z, 0.15);
            float lathe = 1.0 + 0.3 * sin(pr * 140.0) * saturate(1.5 - fp * 60.0);
            float pa = atan2_(pp.y, pp.x) / 6.2831853 + 0.5;
            float tick = aaLineCyclic(pa * 96.0, 0.06) * aaLine(pr - 2.9, 0.08);
            float ring = aaLine(pr - 3.25, 0.006) + aaLine(pr - 2.75, 0.004);
            vec3 pool = warm * exp(-pr * 1.2) + deep * 0.25;
            col += pool * fillPow * irr * 0.3 * lathe;
            // glossy streak: the core's reflection smeared along the grooves
            vec3 rf = reflect(rd, vec3(0.0, 0.0, 1.0));
            float g = saturate(dot(rf, normalize(toL)));
            col += warm * fillPow * pow(g, 18.0) * 0.5 * lathe;
            col += cool * (tick + ring) * irr * 1.4 * (0.6 + 0.8 * u.level);
            col *= exp(-0.02 * tp);
        }
    } else {
        tHit = t;
        vec3 pos = ro + rd * t;
        vec3 nor = gyNormal(pos, sp, u);
        vec3 v = -rd;
        vec3 toL = GY_LIGHT - pos;
        float ll = max(length(toL), 1e-3);
        vec3 ldir = toL / ll;
        // core light: soft falloff, no shadow (it hides behind the plane)
        float dif = saturate(dot(nor, ldir));
        vec3 lcore = warm * corePow * dif * 0.9 / (0.3 + ll * ll * ll * 6.0);
        vec3 kdir = normalize(vec3(-0.6, 0.7, 0.8));
        vec3 rf = reflect(-v, nor);
        float fres = pow(1.0 - saturate(dot(nor, v)), 4.0);
        float spec = pow(saturate(dot(rf, kdir)), 70.0);
        float pr = length(pos.xy);
        // lathe finish: concentric grooves break up the reflections
        float lathe = 1.0 - 0.3 * sin(pr * 260.0) * saturate(1.5 - t * pxa * 120.0);
        vec3 metal = vec3(0.010, 0.011, 0.014);
        col = metal * (0.3 + saturate(dot(nor, kdir)));
        if (m > 0.5) {
            col += (gyEnv(rf, warm, vec3(0.75, 0.82, 1.0)) * 0.22 + vec3(0.9, 0.93, 1.0) * spec * 0.7) * lathe;
            col += cool * fres * 0.3;
            col += lcore;
        }
        if (m < 0.5) {
            // segment: dark anodised metal with an emissive inlay that glows
            // with its depth. Each ring sits at its own place on the palette's
            // cool side and the dashes scatter a little round it.
            vec4 l = gyDashLocal(pos.xy, sp);
            float depth = saturate((pos.z - 0.02) / 0.6);
            float face = smoothstep(0.7, 0.95, nor.z);
            float ins = smoothstep(0.012, 0.0, max(abs(l.x) - GY_TH * 0.45, abs(l.y) - l.z * 0.72));
            float nd = gyDashes(l.w, sp.z);
            float jd = mod(floor((atan2_(pos.y, pos.x) - gyRingRot(l.w, sp.y)) * nd / 6.2831853), nd);
            float jh = hash21(vec2(jd, l.w));
            float eh = 0.46 + 0.36 * l.w / max(sp.x - 1.0, 1.0) + 0.06 * jh + 0.6 * inHue + 0.04 * build;
            vec3 ec = gySat(gyPal(P, clamp(eh, 0.4, 0.86)), 1.3);
            // the beat front lights each ring as it passes and warms it to gold
            float wv = bwAmp * exp(-2.5 * (l.w - bw) * (l.w - bw));
            ec = mix(ec, gySat(gyPal(P, 0.22 + 0.03 * l.w), 1.5), 0.85 * wv);
            // the tallest segments run white hot
            vec3 eh2 = peakWhite(ec, smoothstep(0.7, 1.0, depth) * 0.45);
            col += eh2 * face * ins * (0.1 + 3.0 * depth + 0.8 * u.onset * depth + 0.9 * wv);
            // the sides: dark coloured film, the inlay's light spilling down
            // from the face and the core's warm light on the inner walls
            float side = 1.0 - face;
            vec3 film = mix(deep * 0.5, ec, 0.3 + 0.5 * fres) * mix(0.2, 0.6, face);
            float grz = saturate(1.0 - t * pxa * 160.0);
            col += (gyEnv(rf, warm, film) * (0.22 + 0.25 * face) + ec * spec * 0.5) * mix(1.0, lathe, grz * face);
            col += vec3(0.9, 0.93, 1.0) * spec * 0.35 * face * lathe;
            float lz = max(gyDepth(l.w, jd, nd, u) - pos.z, 0.0);   // below the dash top
            float lip = side * smoothstep(0.035, 0.0, lz);
            col += ec * lip * (0.08 + 0.7 * depth + 0.6 * wv);
            col += ec * side * smoothstep(0.3, 0.0, lz) * (0.015 + 0.05 * depth);
            col += lcore * mix(0.55, 1.0, side);
            col += warm * face * (1.0 - ins) * u.treble * u.onset * 0.25;
            // contact shadow at the base
            col *= mix(0.3, 1.0, saturate((pos.z + 0.07) / 0.25));
        } else if (m < 1.5) {
            // crown: engraved glowing channel along its face
            float groove = aaLine(pr - GY_ROUT + 0.02, 0.01) * step(0.15, pos.z);
            col += gySat(gyPal(P, 0.72 + inHue * 0.5), 1.2) * groove * (1.0 + 4.0 * u.bassImpact);
        } else if (m < 2.5) {
            // halo: a dark band with a thin emissive line that runs round it
            float a01 = atan2_(pos.y, pos.x) / 6.2831853 + 0.5;
            float run = 0.5 + 0.5 * sin(a01 * 37.699112 - u.time * 0.8);
            col *= 0.4;
            col += mix(cool, warm, run) * smoothstep(0.85, 1.0, nor.z)
                 * (0.12 + (0.5 + 1.6 * u.level) * run * run);
        } else {
            // core lens: hot centre, coloured iris rings
            float c = saturate(dot(nor, v));
            float iris = 0.5 + 0.5 * sin(c * 26.0 - u.time * 1.5);
            col = coreCol * corePow * (0.25 + 2.2 * pow(c, 8.0)) * (0.55 + 0.45 * iris)
                + ember * (0.3 + 1.2 * fres) * (1.0 - pow(c, 8.0));
        }
    }

    // volumetric shafts: light from the core escapes through the gaps; a point
    // in front of the plane is lit when its line back to the core crosses the
    // plane in a gap. Samples are equi-angular about the core, so they bunch
    // where the light is strong and the estimate stays smooth.
    vec2 vb = gySphere(ro, rd, 3.2);
    float ta = vb.x;
    float tb = min(min(tHit, vb.y), rd.z < -1e-3 ? ro.z / -rd.z : 1e3);
    if (tb > ta) {
        float del = dot(GY_LIGHT - ro, rd);
        float dd = max(length(ro + rd * del - GY_LIGHT), 0.03);
        float tha = atan((ta - del) / dd);
        float thb = atan((tb - del) / dd);
        int vs = osSteps(3.0, 9.0, detail);
        float jit = 0.5;
        float hstep = 0.5 * (thb - tha) / float(vs);
        vec3 acc = vec3(0.0);
        for (int i = 0; i < 9; i++) {
            if (i >= vs) break;
            float th = mix(tha, thb, (float(i) + jit) / float(vs));
            vec3 s = ro + rd * (del + dd * tan(th));
            vec2 q = gyProject(s);
            // filter the gap mask over this sample's footprint on the plane,
            // so sparse samples blend instead of dithering
            vec2 qa = gyProject(ro + rd * (del + dd * tan(max(th - hstep, -1.55))));
            vec2 qb = gyProject(ro + rd * (del + dd * tan(min(th + hstep, 1.55))));
            float w = clamp(0.6 * length(qb - qa), 0.012, 0.4);
            float vis = smoothstep(-w, w, gyGap(q, sp));
            float kq = saturate((length(q) - GY_R0) / (GY_SP * 6.0));
            acc += mix(warm, ember, kq) * vis;
        }
        // dusty beams: streaks radiating from the core on screen, drifting
        // outward, looked up once per ray so they stay smooth
        vec3 fw = normalize(-ro);
        vec3 rt = normalize(cross(fw, vec3(sin(roll), cos(roll), 0.0)));
        vec3 off = ro + rd * del - GY_LIGHT;
        vec2 so = vec2(dot(off, rt), dot(off, cross(rt, fw)));
        float r0 = length(so);
        vec2 dir = so / max(r0, 1e-4);
        float drift = r0 * 0.5 - ph * 0.03;
        float n1 = vnoise(dir * 11.0 + vec2(drift, 3.1));
        float n2 = vnoise(dir * 27.0 + vec2(5.7, drift * 1.4));
        float sm = smoothstep(0.42, 1.0, n1 * 0.65 + n2 * 0.45);
        float smoke = 0.05 + 3.4 * sm;
        // each beam takes its own hue between the palette's warm stops, and
        // the hue drifts round with the build
        float bh = 0.03 + 0.42 * smoothstep(0.25, 0.8, vnoise(dir * 4.0 + vec2(1.3, ph * 0.004))) + 0.06 * build;
        vec3 bt = gySat(gyPal(P, bh), 1.35);
        float al = dot(acc, vec3(0.2126, 0.7152, 0.0722));
        acc = mix(acc, al * bt * 1.6, 0.7);
        // each kick sends a bright front out along the beams
        smoke *= 1.0 + 1.1 * u.bassImpact * exp(-3.0 * abs(r0 - 0.4 - 2.5 * saturate(u.beatPhase)));
        // thinner in front of the sigil, so its face stays crisp
        col += fillPow * smoke * acc * (thb - tha) / (dd * float(vs)) * (hit ? 0.07 : 0.13);
    }
    // bloom around the core where the view passes close to it
    float tc = max(dot(GY_LIGHT * 0.1 - ro, rd), 0.0);
    float dc = length(ro + rd * tc - GY_LIGHT * 0.1);
    col += coreCol * corePow * 0.004 / (0.01 + dc * dc);

    return col; // LINEAR HDR — post chain tonemaps
}
