// SPDX-License-Identifier: AGPL-3.0-only
// Circuit Trace: the screen is a circuit board under the outgoing frame. From
// a seeded origin, pulses of energy race outwards along a branching tree of
// copper traces routed the way a board is: straight runs, 45-degree chamfered
// bends, vias where the bus branches or ends. Each pulse is a bright
// complementary head with a palette tail. Close behind the pulses, the new
// frame floods across the board along an organic, glowing front, with a brief
// prismatic offset where it has just arrived and the freshly powered traces
// still glowing through it on the beat. Ahead of the front the old frame dims
// and the etched circuit shows faintly, as if the board were warming up.
vec2 ctParent(vec2 c, vec2 o, float sd) {                    // the neighbour this cell is fed from
    vec2 d = o - c;
    float ax = abs(d.x), ay = abs(d.y);
    if (ax + ay < 0.5) return c;
    float h = hash21(c + vec2(sd * 61.0, sd * 13.0));
    bool stepX = ay < 0.5 || (ax > 0.5 && h < ax / (ax + ay));
    return stepX ? c + vec2(sign(d.x), 0.0) : c + vec2(0.0, sign(d.y));
}

float ctTime(vec2 c, vec2 o, float mm, float sd) {           // when the pulse reaches this cell's centre
    float m = abs(c.x - o.x) + abs(c.y - o.y);              // = depth in the tree, so times grow outwards
    return 0.02 + 0.66 * m / mm + 0.006 * hash21(c * 1.7 + vec2(sd * 29.0, 3.1));
}

vec2 ctSeg(vec2 l, vec2 a, vec2 b) {                         // (distance, 0..1 along) to segment ab
    vec2 ab = b - a;
    float h = clamp(dot(l - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return vec2(length(l - a - ab * h), h);
}

// light of one trace piece at distance dist whose pulse passes at time ta
vec3 ctLit(float dist, float ta, float p, float aa, float beat) {
    const float TW = 0.03;                                    // trace half width, in cells
    float dt = p - ta;
    float line = 1.0 - smoothstep(TW - aa, TW + aa, dist);
    float halo = exp(-dist / 0.07);
    float on = step(0.0, dt);
    float tail = on * exp(-dt / 0.05);
    float after = on * 0.36 * exp(-dt / 0.13) * beat;
    return vec3((line * 0.9 + halo * 0.3) * (after + 0.9 * tail),
                exp(-abs(dt) / 0.008) * (line + halo * 0.8),
                line * smoothstep(-0.15, 0.0, dt) * (1.0 - on));
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    bool lowQ = u.presentation1.y > 0.5;
    vec2 sa = vec2(asp, 1.0);
    float win = sin(3.14159265 * p);
    float beat = 0.7 + 0.6 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    // the board: square cells, the origin cell seeded
    const float G = 1.0 / 13.0;
    vec2 s = uv * sa;                                         // y down, from the top-left
    vec2 sc = s / G;
    vec2 cid = floor(sc);
    vec2 l = sc - cid - 0.5;                                  // -0.5..0.5 inside the cell
    vec2 cmax = floor(sa / G);
    vec2 o = floor(vec2(hash11(sd * 37.9 + 1.2), hash11(sd * 53.1 + 4.4)) * (cmax + 1.0));
    float mm = max(max(o.x, cmax.x - o.x) + max(o.y, cmax.y - o.y), 1.0);
    float Tc = ctTime(cid, o, mm, sd);
    vec2 pa = ctParent(cid, o, sd);
    float aa = px / G;                                        // one pixel in cell units

    vec3 pc = suppressGreenCast(palRoleRim(0.2 + 0.6 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = (vec3(mx + mn) - pc) / max(mx, 0.05);
    pc /= max(mx, 0.05);

    // the flood front: a blend of the routing distance and the straight one,
    // broken up by noise, a little behind the pulses
    vec2 oc = o + 0.5;
    vec2 dd = abs(sc - oc);
    float emax = length(max(oc, cmax + 1.0 - oc));
    float dist = mix(length(sc - oc) / max(emax, 1.0), (dd.x + dd.y) / mm, 0.5);
    float nz = vnoise(sc * 0.3 + vec2(sd * 17.0, 3.0)) + 0.5 * vnoise(sc * 0.8 + vec2(5.0, sd * 23.0));
    float Tr = 0.07 + 0.74 * dist + 0.07 * (nz - 0.75);
    float wa = 2.0 * 0.8 / (mm * G * max(u.resolution.y, 1.0)) + 1e-4;
    float dr = p - Tr;
    float rev = smoothstep(-wa, wa, dr);
    rev = max(rev, smoothstep(0.93, 1.0, p));                 // (a guarantee for the last moment)

    vec3 col = vec3(0.0);
    if (rev < 1.0) {
        vec3 f = FROM(uv);
        f *= 1.0 - 0.3 * smoothstep(-0.12, 0.0, dr) * win;    // the board warms up ahead of the front
        col = f;
    }
    float ch = exp(-max(dr, 0.0) / 0.035) * rev * win;
    if (rev > 0.0) {
        vec2 rd = sc - oc;
        rd = rd / max(length(rd), 1e-3);
        vec2 ca = rd * 0.007 * ch / sa;
        vec3 t;
        if (lowQ || ch < 0.02) t = TO(uv);
        else t = vec3(TO(clamp(uv + ca, 0.0, 1.0)).r, TO(uv).g, TO(clamp(uv - ca, 0.0, 1.0)).b);
        col = mix(col, t, rev);
    }
    // the front's rim
    float rw = smoothstep(0.0, 0.05, p) * (1.0 - smoothstep(0.85, 0.97, p));
    float rcore = exp(-abs(dr) / 0.0035), rhalo = exp(-abs(dr) / 0.014);
    vec3 light = (mix(comp, pc, 0.4) * rcore * 0.32 + pc * rhalo * 0.07) * rw * (0.75 + 0.35 * beat);

    // traces: collect this cell's visible links (to its parent and its children)
    vec2 dirs[4];
    float tE[4];
    int nl = 0;
    for (int k = 0; k < 4; ++k) {
        vec2 dn = k == 0 ? vec2(1.0, 0.0) : (k == 1 ? vec2(-1.0, 0.0) : (k == 2 ? vec2(0.0, 1.0) : vec2(0.0, -1.0)));
        vec2 nb = cid + dn;
        bool toParent = all(equal(pa, nb));
        bool toChild = all(equal(ctParent(nb, o, sd), cid));
        if (!toParent && !toChild) continue;
        // some links run beneath the board: the pulse still passes, unseen
        vec2 child = toChild ? nb : cid;
        if (hash21(child * 2.3 + vec2(sd * 17.0, 7.7)) < 0.35) continue;
        dirs[nl] = dn;
        tE[nl] = 0.5 * (Tc + ctTime(nb, o, mm, sd));          // the time at the shared cell edge
        nl++;
    }
    vec3 acc = vec3(0.0);
    bool pad = nl != 2;
    if (nl == 2 && abs(dot(dirs[0], dirs[1])) < 0.5) {
        // a bend: route it with a 45-degree chamfer instead of a square corner
        const float C = 0.26;
        vec2 P0 = dirs[0] * 0.5, P1 = dirs[0] * C, P2 = dirs[1] * C, P3 = dirs[1] * 0.5;
        float L1 = 0.5 - C, L2 = C * 1.41421356, Lt = 2.0 * L1 + L2;
        vec2 a0 = ctSeg(l, P0, P1), a1 = ctSeg(l, P1, P2), a2 = ctSeg(l, P2, P3);
        acc = max(acc, ctLit(a0.x, mix(tE[0], tE[1], a0.y * L1 / Lt), p, aa, beat));
        acc = max(acc, ctLit(a1.x, mix(tE[0], tE[1], (L1 + a1.y * L2) / Lt), p, aa, beat));
        acc = max(acc, ctLit(a2.x, mix(tE[0], tE[1], (L1 + L2 + a2.y * L1) / Lt), p, aa, beat));
    } else {
        for (int k = 0; k < 4; ++k) {
            if (k >= nl) break;
            vec2 a0 = ctSeg(l, vec2(0.0), dirs[k] * 0.5);
            acc = max(acc, ctLit(a0.x, mix(Tc, tE[k], a0.y), p, aa, beat));
        }
    }
    if (pad && nl > 0) {
        // a via where the bus branches or ends, lit when the pulse arrives
        float pr = length(l);
        float ring = 1.0 - smoothstep(0.03 - aa, 0.03 + aa, abs(pr - 0.08));
        float pon = step(Tc, p);
        acc.x = max(acc.x, ring * pon * (0.1 + 1.0 * exp(-(p - Tc) / 0.04)));
        acc.z = max(acc.z, ring * smoothstep(-0.15, 0.0, p - Tc) * (1.0 - pon));
    }
    float fade = 1.0 - smoothstep(0.7, 1.0, p);
    light += pc * acc.x * 0.5 + mix(comp, pc, 0.25) * acc.y * 0.9;
    light += pc * acc.z * 0.08;                               // the circuit shows faintly just ahead
    col += light * fade * smoothstep(0.0, 0.04, p);
    return col;
}
