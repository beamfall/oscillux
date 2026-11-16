// SPDX-License-Identifier: AGPL-3.0-only
// Cymatics/Prism.
// A Chladni plate under a prism, shot like a physics-lab still. Fine quartz
// sand lies on a square black plate driven from its centre bolt; the plate
// rings in a standing mode and the sand crawls off the vibrating antinodes
// and settles on the still nodal lines. Every eight beats the plate is driven
// at a new mode and the figure dissolves and regathers, and the camera finds
// a new angle. A low raking beam split by a prism fans a spectrum across the
// plate, so every ridge of sand burns a different hue and casts a long lee
// shadow, and the shaft of split light hangs in the haze. Grains left on the
// antinodes hop to the spectrum, the bass shivers the plate's reflection and
// the beats alternate a warm and a cool edge light.
// param0 = Mode Order ; param1 = Sand ; param2 = Prism

const float CY_PI = 3.14159265;
const float CY_CELL = 0.0105; // grain lattice pitch on the plate
const float CY_THK = 0.03;    // plate thickness

struct CyPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

// The prism's fan, red .. violet, from the five fixed stops.
vec3 cySpec(CyPal P, float x) {
    x = clamp(x, 0.0, 0.999) * 4.0;
    float f = smoothstep(0.0, 1.0, fract(x));
    vec3 a = x < 1.0 ? P.c0 : x < 2.0 ? P.c1 : x < 3.0 ? P.c2 : P.c3;
    vec3 b = x < 1.0 ? P.c1 : x < 2.0 ? P.c2 : x < 3.0 ? P.c3 : P.c4;
    return mix(a, b, f);
}

struct CyM { vec2 nm; float sg; };

CyM cyMode(float s, float ord, float t) {
    float k = mod(s, 8.0);
    vec2 m = k < 0.5 ? vec2(1.0, 4.0) : k < 1.5 ? vec2(3.0, 5.0)
           : k < 2.5 ? vec2(2.0, 7.0) : k < 3.5 ? vec2(1.0, 6.0)
           : k < 4.5 ? vec2(4.0, 7.0) : k < 5.5 ? vec2(3.0, 8.0)
           : k < 6.5 ? vec2(2.0, 5.0) :            vec2(5.0, 8.0);
    m += floor(ord * 2.0 + 0.5);
    // a slight detune breathes the figure while the mode holds
    m += vec2(0.24, -0.18) * sin(0.47 * t + s * 1.7);
    return CyM(m, mod(s, 3.0) < 1.0 ? -1.0 : 1.0);
}

// Chladni field f and its gradient over the plate q in [-1, 1].
vec3 cyField(vec2 q, CyM M) {
    vec2 w = (q + 1.0) * 0.5;
    float A = M.nm.x * CY_PI, B = M.nm.y * CY_PI;
    float cax = cos(A * w.x), sax = sin(A * w.x), cbx = cos(B * w.x), sbx = sin(B * w.x);
    float caz = cos(A * w.y), saz = sin(A * w.y), cbz = cos(B * w.y), sbz = sin(B * w.y);
    float f = cax * cbz - M.sg * cbx * caz;
    float fx = -A * sax * cbz + M.sg * B * sbx * caz;
    float fz = -B * cax * sbz + M.sg * A * cbx * saz;
    return vec3(f, 0.5 * fx, 0.5 * fz);
}

// Sand density near the nodal lines, with its gradient; w is the line width.
vec3 cySand(vec2 q, CyM M, float w) {
    vec3 F = cyField(q, M);
    float g2 = dot(F.yz, F.yz) + 0.4;
    float d = F.x / sqrt(g2);
    float rho = exp(-d * d / (w * w));
    vec2 gr = -2.0 * rho * d / (w * w) * F.yz / sqrt(g2);
    return vec3(rho, gr);
}

struct CyS {
    CyM mA; CyM mB; float e; float wA; float wB; float amt; float haze;
};

vec3 cyRho(vec2 q, CyS S) {
    vec3 r = cySand(q, S.mB, S.wB);
    if (S.e < 0.999) r = mix(cySand(q, S.mA, S.wA), r, S.e);
    // a thin scatter of grains everywhere, densest while the figure re-forms
    r.x = r.x * S.amt + S.haze;
    r.yz *= S.amt;
    return r;
}

vec4 cyPose(float s) {
    float k = mod(s, 4.0);
    float h = hash11(s * 1.37 + 0.2);
    vec4 v = k < 0.5 ? vec4(0.58, 2.05, 0.0, 0.0)
           : k < 1.5 ? vec4(1.05, 2.20, 0.0, 0.05)
           : k < 2.5 ? vec4(0.30, 1.70, 0.0, 0.30)
           :           vec4(0.72, 1.45, 0.0, -0.38);
    v.x += 0.08 * (h - 0.5);
    v.z = 0.9 * s + 0.7 * h;
    return v;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float t = mod(u.time, 600.0);
    float detail = osDetail(u);
    CyPal C = CyPal(palVisual(0.0, u), palVisual(0.25, u), palVisual(0.5, u),
                    palVisual(0.75, u), palVisual(0.98, u));
    float bp = saturate(u.beatPhase);
    float kick = (1.0 - bp) * (1.0 - bp);
    bool even = mod(floor(u.beatCount), 2.0) < 0.5;
    float bass = saturate(u.bassImpact);
    float bc = u.beatCount + bp;
    float sec = floor(bc / 8.0);
    float ph8 = fract(bc / 8.0);
    vec4 sbA = vec4(bandAt(u, 0.05), bandAt(u, 0.18), bandAt(u, 0.32), bandAt(u, 0.46));
    vec4 sbB = vec4(bandAt(u, 0.58), bandAt(u, 0.70), bandAt(u, 0.82), bandAt(u, 0.94));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));

    // the sand: the old figure blurs out as the new one gathers and sharpens
    CyS S;
    S.mA = cyMode(sec - 1.0, u.param0, t);
    S.mB = cyMode(sec, u.param0, t);
    S.e = smoothstep(0.04, 0.45, ph8);
    S.wA = mix(0.022, 0.16, smoothstep(0.0, 0.3, ph8));
    S.wB = mix(0.16, 0.024, smoothstep(0.06, 0.5, ph8));
    S.amt = mix(0.55, 1.35, u.param1);
    S.haze = (0.025 + 0.22 * (1.0 - smoothstep(0.0, 0.6, ph8))) * mix(0.6, 1.3, u.param1);

    // camera: a slow arc through each section, re-framed every eight beats
    vec2 flc = osFlight(u, 0.35, 0.15);
    float ease = smoothstep(0.0, 0.45, ph8);
    ease = ease * ease * (3.0 - 2.0 * ease);
    vec4 pose = mix(cyPose(sec - 1.0), cyPose(sec), ease);
    float az = pose.z + 0.4 * (1.0 - ease) + 0.4 * ph8 + 0.04 * flc.x;
    vec3 ta = vec3(pose.w, -0.05, 0.6 * pose.w);
    vec3 ro = ta + pose.y * vec3(cos(pose.x) * sin(az), sin(pose.x), cos(pose.x) * cos(az));
    const float FOV = 1.75;
    vec3 rd = osCamera(ro, ta, 0.0, FOV, p);

    // the prism beam: low and raking, from off one side of the camera
    float la = az + 1.75 + 0.45 * sin(0.13 * t);
    float le = 0.24 + 0.05 * sin(0.17 * t + 1.0);
    vec3 Ld = vec3(sin(la) * cos(le), sin(le), cos(la) * cos(le));
    vec2 Lperp = normalize(vec2(-Ld.z, Ld.x));
    float fan = mix(0.6, 1.25, u.param2);
    float disp = 0.16 * sin(0.21 * t);
    vec3 accent = even ? mix(C.c1, C.c0, 0.25) : mix(C.c3, C.c2, 0.3);
    float accK = 0.6 + 1.6 * kick;
    vec3 Ra = normalize(vec3(-Ld.x, 0.55, -Ld.z));

    // studio: near black, a violet cast low and the split shaft in the haze
    vec3 col = mix(C.c4 * 0.012, vec3(0.002), smoothstep(-0.4, 0.5, rd.y));
    vec3 Lp = Ld * 3.4;
    {
        vec3 ax = -Ld;
        vec3 w0 = ro - Lp;
        float b = dot(rd, ax);
        float dd = dot(rd, w0), ee = dot(ax, w0);
        float den = max(1.0 - b * b, 1e-4);
        float s1 = (ee - b * dd) / den;      // along the beam from the prism
        float s0 = (dd - b * ee) / den;      // along the view ray (negated)
        vec3 cpB = Lp + ax * s1;
        vec3 cpR = ro - rd * s0;
        float sn = clamp(s1 / 3.4, 0.0, 1.3);
        float bw = mix(0.04, 1.05, sn);
        vec3 off = cpR - cpB;
        float lat = dot(off.xz, Lperp) / bw;
        float rad = length(off) / bw;
        float on = step(0.0, -s0) * smoothstep(0.0, 0.05, sn) * (1.0 - smoothstep(1.0, 1.3, sn));
        col += cySpec(C, 0.5 + 0.5 * lat * fan + disp) * exp(-rad * rad * 1.6) * on
             * (0.22 / (0.3 + sn)) * mix(0.3, 1.2, u.param2);
        // the prism's own glint where the beam is split
        float pg = max(dot(rd, normalize(Lp - ro)), 0.0);
        col += mix(vec3(1.0), C.c1, 0.4) * pow(pg, 40000.0) * 6.0 * mix(0.4, 1.0, u.param2);
    }

    // plate: a box [-1,1] x [-THK,0] x [-1,1]
    vec3 bmin = vec3(-1.0, -CY_THK, -1.0), bmax = vec3(1.0, 0.0, 1.0);
    vec3 inv = 1.0 / (rd + vec3(1e-7));
    vec3 t0 = (bmin - ro) * inv, t1 = (bmax - ro) * inv;
    vec3 tn = min(t0, t1), tf = max(t0, t1);
    float tN = max(max(tn.x, tn.y), tn.z), tF = min(min(tf.x, tf.y), tf.z);
    bool plate = tF > max(tN, 0.0);
    if (plate) {
        vec3 hp = ro + rd * tN;
        bool top = tn.y >= max(tn.x, tn.z) - 1e-6;
        if (top) {
            vec2 q = hp.xz;
            float fp = tN * 2.0 / (u.resolution.y * FOV) / max(-rd.y, 0.18);
            float edge = max(abs(q.x), abs(q.y));
            // the beam's colour and strength over the plate
            float lat = dot(q, Lperp);
            vec3 Lc = cySpec(C, 0.5 + 0.42 * lat * fan + disp) * 2.6;
            Lc *= 0.55 + 0.45 * smoothstep(1.6, 0.4, abs(lat));
            float r = length(q);

            // the plate itself: black anodised, brushed, shivering with the bass
            vec3 F = cyField(q, S.mB);
            float shv = 0.004 * bass * sin(t * 9.0);
            vec3 Np = normalize(vec3(-F.y * shv, 1.0, -F.z * shv));
            vec3 R = reflect(rd, Np);
            float spec = pow(max(dot(R, Ld), 0.0), 60.0);
            float brushed = pow(max(dot(normalize(vec3(R.x, R.y * 0.25, R.z)), normalize(vec3(Ld.x, Ld.y * 0.25, Ld.z))), 0.0), 400.0);
            vec3 pc = vec3(0.006, 0.006, 0.008) + C.c4 * 0.004;
            pc += Lc * (spec * 0.5 + brushed * 0.25 + 0.035 * Ld.y);
            pc += accent * accK * 0.05 * pow(max(dot(R, Ra), 0.0), 20.0);
            pc += mix(C.c3, C.c4, 0.5) * 0.01 * smoothstep(-0.1, 0.6, R.y);

            // centre bolt
            float bolt = 1.0 - smoothstep(0.034, 0.034 + fp * 1.5, r);
            vec3 bc3 = (vec3(0.03) + Lc * 0.25 * smoothstep(0.02, 0.033, r)) * mix(vec3(1.0), C.c1, 0.2);
            pc = mix(pc, bc3, bolt);

            // sand bed: dense ridges as packed sand lit by the raking beam
            vec3 Rh = cyRho(q, S);
            float H = 0.022;
            vec3 Ns = normalize(vec3(-H * Rh.y, 1.0, -H * Rh.z));
            float lee = 1.0;
            if (detail > 0.25) {
                // lee shadow: sand piled toward the light shades the plate
                float r2 = cyRho(q + Ld.xz / Ld.y * 0.012, S).x;
                lee = 1.0 - 0.75 * smoothstep(0.15, 0.7, r2 - Rh.x * 0.8);
            }
            vec3 alb = vec3(0.62, 0.52, 0.38);
            float dif = max(dot(Ns, Ld), 0.0);
            float bed = smoothstep(0.55, 1.05, Rh.x) * (1.0 - bolt);
            // packed sand is granular: a per-grain tone and a sparse sparkle
            vec2 gc0 = floor(q / (CY_CELL * 0.55));
            float gt = hash21(gc0 + 3.7);
            alb *= 1.0 + (gt - 0.5) * 0.7 * (1.0 - smoothstep(0.3, 1.0, fp / (CY_CELL * 0.55)));
            dif *= 0.6 + 0.4 * smoothstep(0.0, 0.7, dif);
            vec3 sc = alb * (Lc * dif * lee + accent * accK * 0.08 * max(dot(Ns, Ra), 0.0) + C.c4 * 0.01);
            vec3 c = mix(pc * lee, sc, bed);

            // individual grains: a 3x3 search of the grain lattice
            vec2 g = q / CY_CELL;
            vec2 ci = floor(g);
            float rg = CY_CELL * 0.34;
            float hopK = 4.0 * bp * (1.0 - bp);
            vec3 hv = normalize(Ld - rd);
            // low detail keeps only the home cell
            int gr = detail > 0.5 ? 1 : 0;
            for (int j = -1; j <= 1; j++) {
                if (j < -gr || j > gr) continue;
                for (int i = -1; i <= 1; i++) {
                    if (i < -gr || i > gr) continue;
                    vec2 cc = ci + vec2(float(i), float(j));
                    vec2 h2 = hash22(cc);
                    float h3 = hash21(cc + 17.31);
                    float pres = smoothstep(h3, h3 + 0.12, Rh.x);
                    if (pres <= 0.0) continue;
                    vec2 gp = (cc + 0.18 + 0.64 * h2) * CY_CELL;
                    // grains off the lines hop; the spectrum sets how high by radius
                    float fb = clamp(length(gp) * 4.9, 0.0, 6.999);
                    int bi = int(fb);
                    float bv = bi < 4 ? sbA[bi] : sbB[bi - 4];
                    float loose = 1.0 - smoothstep(0.25, 0.8, Rh.x);
                    float hop = CY_CELL * 0.75 * loose * (0.25 + bv) * hopK;
                    vec2 app = gp - rd.xz * (hop / rd.y);
                    vec2 dv = q - app;
                    float rr = rg * (0.6 + 0.4 * pres) * (0.75 + 0.5 * h2.x);
                    float dl = length(dv);
                    float cov = (1.0 - smoothstep(rr - fp, rr + fp, dl)) * (1.0 - bolt);
                    if (cov <= 0.0) continue;
                    vec2 o = dv / rr;
                    vec3 n = normalize(vec3(o.x, sqrt(max(1.0 - dot(o, o), 0.05)), o.y));
                    float gd = max(dot(n, Ld), 0.0);
                    float gl = h3 < 0.16 ? pow(max(dot(n, hv), 0.0), 70.0) * 2.2 : 0.0;
                    vec3 gc = alb * (0.75 + 0.5 * h2.y) * (Lc * (0.04 + gd) + accent * accK * 0.1 * max(dot(n, Ra), 0.0))
                            + Lc * gl;
                    c = mix(c, gc, cov);
                }
            }
            // the beam fades off the plate's edge
            c *= 1.0 - 0.4 * smoothstep(0.9, 1.0, edge);
            // a bright chamfer at the plate's rim
            float ch = smoothstep(1.0 - 3.0 * fp, 1.0, edge);
            c += (Lc * 0.3 * max(dot(R, Ld), 0.0) + accent * accK * 0.12) * ch;
            col = c;
        } else {
            // plate edge: dark anodised with a hot line along the top chamfer
            float y = hp.y / CY_THK;
            vec3 nE = tn.x > tn.z ? vec3(-sign(rd.x), 0.0, 0.0) : vec3(0.0, 0.0, -sign(rd.z));
            vec3 R = reflect(rd, nE);
            float lat = dot(hp.xz, Lperp);
            vec3 Lc = cySpec(C, 0.5 + 0.42 * lat * fan + disp) * 2.6;
            col = vec3(0.004) + Lc * 0.25 * pow(max(dot(R, Ld), 0.0), 8.0);
            col += (Lc * 0.4 + accent * accK * 0.15) * smoothstep(-0.25, 0.0, y);
        }
    } else {
        // the stand below the plate's centre
        float a = dot(rd.xz, rd.xz), b = dot(ro.xz, rd.xz), cc = dot(ro.xz, ro.xz) - 0.045 * 0.045;
        float D = b * b - a * cc;
        if (D > 0.0 && a > 1e-6) {
            float ts = (-b - sqrt(D)) / a;
            vec3 sp = ro + rd * ts;
            if (ts > 0.0 && sp.y < -CY_THK && sp.y > -2.0) {
                vec3 n = normalize(vec3(sp.x, 0.0, sp.z));
                float dl = max(dot(n, Ld), 0.0);
                vec3 Lc = cySpec(C, 0.5 + disp) * 0.5;
                col = vec3(0.004) + Lc * dl * 0.25 * exp(sp.y * 1.4) + accent * accK * 0.03 * max(dot(n, Ra), 0.0);
            }
        }
    }

    col *= 1.0 - 0.35 * smoothstep(0.75, 1.9, length(p * vec2(0.75, 1.0)));
    col += (ign - 0.5) / 255.0;
    return max(col, vec3(0.0));
}
