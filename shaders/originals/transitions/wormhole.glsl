// SPDX-License-Identifier: AGPL-3.0-only
// Wormhole: a lensing throat opens in the outgoing frame at a seeded point
// and the camera glides into it, drifting to centre it, without any turn.
// Around the throat the old frame is bent by its gravity: the scene behind
// it is wrapped into a bright Einstein ring, split slightly by colour, and
// the frame streams outwards past the camera. Through the throat the whole
// incoming frame is seen squeezed into the opening, compressed towards its
// rim like the sky of another universe; it opens out to fill the screen as
// the throat passes around the camera. A thin photon ring in the palette,
// with a complementary inner glow, outlines the throat and swells on the beat.
vec2 whMirror(vec2 x) { return 1.0 - abs(1.0 - abs(x)); }

// keeps a sample at distance rho from c along dir inside the frame: the
// distance is eased into the frame edge over a knee of width k (identity well
// inside, and exactly identity everywhere in the frame when k = 0), so no
// sample folds back at the edges
float whEdge(vec2 c, vec2 dir, float asp) {                 // distance from c to the frame edge along dir
    vec2 ad = max(abs(dir), vec2(1e-4));
    vec2 room = vec2(0.5 * asp, 0.5) - c * sign(dir);
    return max(min(room.x / ad.x, room.y / ad.y), 1e-3);
}

float whFit(vec2 c, vec2 dir, float rho, float k, float asp) {
    float E = whEdge(c, dir, asp);
    float x = rho / E, x0 = 1.0 - k;
    if (x > x0) x = x0 + k * (1.0 - exp(-(x - x0) / max(k, 1e-4)));
    return min(x, 1.0) * E;
}

vec3 whBody(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    bool lowQ = u.presentation1.y > 0.5;
    vec2 sa = vec2(asp, 1.0);
    float win = sin(3.14159265 * p);
    float e = p * p * (3.0 - 2.0 * p);

    // the throat starts off centre and the camera eases onto its axis
    vec2 c0 = (vec2(hash11(sd * 43.7 + 2.1), hash11(sd * 71.3 + 5.9)) - 0.5) * vec2(asp * 0.32, 0.26);
    vec2 cc = c0 * (1.0 - e);
    vec2 v = (uv - 0.5) * sa - cc;
    float r = length(v);
    vec2 dir = v / max(r, 1e-4);
    float Rc = length(vec2(0.5 * asp, 0.5)) + length(c0);

    // the throat's apparent radius grows like an approach: slow, then sweeping past
    float g = mix(p, e, 0.55);
    float R = (Rc + 0.35) * (exp(3.6 * g) - 1.0) / (exp(3.6) - 1.0);
    R = max(R, 1e-4);
    float beat = 0.7 + 0.6 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);

    vec3 pc = suppressGreenCast(palRoleRim(0.2 + 0.6 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = vec3(mx + mn) - pc;
    pc /= max(mx, 0.05);
    comp /= max(mx, 0.05);

    float aa = 1.2 * px;
    float inside = (1.0 - smoothstep(R - aa, R + aa, r)) * clamp(R / (2.0 * aa) - 0.05, 0.0, 1.0);
    vec3 col = vec3(0.0);

    float kn = 0.22 * sqrt(win);                             // fitting knee, gone at both ends
    // frame dragging: space near the throat is swept slowly around it
    float swd = sd < 0.5 ? 1.0 : -1.0;
    if (inside < 1.0) {
        // outside: gravitational lensing of the old frame, plus the approach
        float zoom = 1.0 + 0.55 * e * e;
        float ra0 = max(r, R);
        float sw = swd * 0.55 * win * (R / ra0) * (R / ra0) * smoothstep(0.0, 0.25, p);
        vec2 dro = mat2(cos(sw), sin(sw), -sin(sw), cos(sw)) * dir;
        vec3 f = vec3(0.0);
        float ra = max(r, R);
        // per-channel Einstein radius for a chromatic ring
        vec3 L = R * vec3(1.02, 1.0, 0.98);
        vec3 beta = vec3(ra) - L * L / ra;
        if (lowQ) {
            vec2 q = (cc + dro * whFit(cc, dro, beta.g / zoom, kn, asp)) / sa + 0.5;
            f = FROM(whMirror(q));
        } else {
            // the near field streams past: a short radial blur that grows with speed
            float bl = 0.035 * e * win;
            for (int i = 0; i < 3; ++i) {
                float k = 1.0 - bl * float(i);
                vec2 qr = (cc + dro * whFit(cc, dro, beta.r * k / zoom, kn, asp)) / sa + 0.5;
                vec2 qg = (cc + dro * whFit(cc, dro, beta.g * k / zoom, kn, asp)) / sa + 0.5;
                vec2 qb = (cc + dro * whFit(cc, dro, beta.b * k / zoom, kn, asp)) / sa + 0.5;
                f += vec3(FROM(whMirror(qr)).r, FROM(whMirror(qg)).g, FROM(whMirror(qb)).b);
            }
            f /= 3.0;
        }
        // the lensed ring is brighter (light is focused), the far field slightly dimmed
        float focus = exp(-(r - R) / max(0.25 * R, 1e-3));
        f *= 1.0 + 0.35 * focus * win;
        col = f;
    }
    if (inside > 0.0) {
        // inside: the other side, squeezed into the opening and compressed at its rim
        float q = min(r / R, 1.0);
        // the whole frame fits the opening (its edge on the rim), compressed towards
        // the rim, then relaxes to the plain frame as the throat passes the camera
        float sqz = 1.0 - smoothstep(0.3, 0.88, p);
        float Eo = whEdge(cc, dir, asp);
        float rim = q * q * q * q * q * q;
        float rho = mix(r * (1.0 + 0.4 * rim * win * (1.0 - smoothstep(0.55, 0.9, p))), Eo * q * (1.55 - 0.55 * q), sqz);
        float rhoF = whFit(cc, dir, rho, kn, asp);
        vec2 dt = dir / sa;
        vec2 ct = cc / sa + 0.5;
        vec3 t;
        if (lowQ) {
            t = TO(whMirror(ct + dt * rhoF));
        } else {
            float ch = 0.025 * rim * win * rhoF;
            t = vec3(TO(whMirror(ct + dt * whFit(cc, dir, rho + ch, kn, asp))).r, TO(whMirror(ct + dt * rhoF)).g,
                     TO(whMirror(ct + dt * whFit(cc, dir, rho - ch, kn, asp))).b);
        }
        // a shadowed gap just inside the rim gives the throat depth
        t *= 1.0 - 0.55 * smoothstep(0.82, 1.0, q) * win;
        col = mix(col, t, inside);
    }

    // photon ring and glows
    float d = r - R;
    float ring = exp(-abs(d) / (aa + 0.0025 + 0.006 * g));
    float halo = exp(-max(d, 0.0) / (0.03 + 0.06 * R)) * step(0.0, d);
    float inner = exp(-max(-d, 0.0) / (0.02 + 0.05 * R)) * step(d, 0.0);
    vec3 light = pc * (ring * 0.9 + halo * 0.12) + comp * inner * 0.14;
    float open = smoothstep(0.0, 0.08, p);
    col += light * win * open * beat;
    return col;
}

// The ends hand over to the frames themselves over the first and last 4%, so
// p = 0 is exactly FROM and p = 1 exactly TO at any render size.
// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.2363, 0.3300, 0.3919, 0.4418, 0.4852, 0.5245, 0.5613, 0.5963, 0.6308, 0.6652, 0.6999, 0.7352, 0.7712, 0.8090, 0.8562, 1.0000);
float trPace(float p) {
    if (!(p > 0.0)) return 0.0;
    if (p >= 1.0) return 1.0;
    float x = p * 16.0;
    int i = int(x);
    return mix(TR_PACE[i], TR_PACE[i + 1], x - float(i));
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    p = trPace(p);
    vec3 col = mix(FROM(uv), whBody(uv, p, u), smoothstep(0.0, 0.04, p));
    return mix(col, TO(uv), smoothstep(0.96, 1.0, p));
}
