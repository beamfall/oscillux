// SPDX-License-Identifier: AGPL-3.0-only
// Blinds: the outgoing frame is printed on the fronts of a row of 3D slats
// and the incoming one on their backs. A wave runs along the stack (axis and
// direction seeded) and each slat turns half a turn about its own axis in
// perspective. Slats have thickness, so edge-on they show a lit edge; faces
// are key-lit by their normal, catch a travelling specular glint and a
// beat-pulsed palette edge light, and shade the next slat with their shadow.
// Through the gaps a dim, backlit view of the incoming frame shows. Each
// pixel inverts the projection of its own slat and its two neighbours, and
// composites them front to back.
const float BL_F = 1.35;

// each slat is a ribbon: its cross-sections start turning at different times
// along its length (tof), so the turn travels along it as a twist
float blTurn(float p, float k, float N, float dirW, float tof) {
    float ord = dirW > 0.0 ? (N - 1.0 - k) / max(N - 1.0, 1.0) : k / max(N - 1.0, 1.0);
    float q = clamp((p - 0.42 * ord - tof) / 0.42, 0.0, 1.0);
    return 3.14159265 * q * q * q * (q * (q * 6.0 - 15.0) + 10.0);
}

vec3 blBody(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    float win = sin(3.14159265 * p);
    bool vert = fract(sd * 3.7) > 0.62;
    float dirW = fract(sd * 11.3) > 0.5 ? 1.0 : -1.0;   // which end the wave starts at
    float sR = fract(sd * 5.9) > 0.5 ? 1.0 : -1.0;     // turning direction
    vec2 s = vec2((uv.x - 0.5) * asp, 0.5 - uv.y);
    // a: across the slats (stacking axis), b: along them
    float a = vert ? s.x : s.y, b = vert ? s.y : s.x;
    float A = vert ? 0.5 * asp : 0.5, B = vert ? 0.5 : 0.5 * asp;
    float N = floor(2.0 * A * (vert ? 7.0 : 9.0) + 0.5);
    float h = 2.0 * A / N;
    float tau = 0.16 * h;                              // slat thickness
    float k0 = clamp(floor((a + A) / h), 0.0, N - 1.0);
    float bn = b / B;
    float twA = 6.2831853 * sd + 0.9 * dirW;

    float beat = 0.6 + 0.8 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    vec3 rimC = suppressGreenCast(palRoleRim(0.2 + 0.4 * sd, u));
    float mx = max(rimC.r, max(rimC.g, rimC.b)), mn = min(rimC.r, min(rimC.g, rimC.b));
    vec3 compC = vec3(mx + mn) - rimC;
    vec3 L = normalize(vec3(-0.35, 0.75, -0.55));       // (b, a, z): light from the a+ side
    vec3 Hv = normalize(L + vec3(0.0, 0.0, -1.0));

    // backdrop through the gaps: the incoming frame, deeper and backlit
    vec2 ub = 0.5 + (uv - 0.5) * 0.95;
    float gy = fract((a + A) / h);
    vec3 back = (TO(ub) * 0.3 + rimC * 0.012 * win * beat) * (0.3 + 0.7 * smoothstep(1.0, 0.25, gy));

    vec3 cc[3];
    float cw[3], cz[3];
    for (int j = 0; j < 3; ++j) {
        cc[j] = vec3(0.0); cw[j] = 0.0; cz[j] = 1e5;
        float k = k0 + float(j - 1);
        if (k < 0.0 || k > N - 1.0) continue;
        float yk = -A + (k + 0.5) * h;
        float tof = 0.08 + 0.08 * sin(2.3 * bn + twA + 0.35 * k);
        float ph = blTurn(p, k, N, dirW, tof);
        float c = cos(ph), sn = sR * sin(ph);
        float tw = abs(sin(ph));
        float Fz = BL_F + 0.7 * h * tw;                 // a turning slat drops back a little
        float den = BL_F * c - a * sn;
        if (abs(den) < 1e-4) continue;
        float v = (a * Fz - BL_F * yk) / den;
        float Z = Fz - BL_F + v * sn;
        if (BL_F + Z < 0.2) continue;
        float X = b * (BL_F + Z) / BL_F;
        float sc = BL_F / (BL_F + Z);
        float rv = abs(BL_F * (Fz * c - sn * yk)) / ((BL_F + Z) * (BL_F + Z));
        float pv = (0.5 * h - abs(v)) * rv / px;        // pixels inside the face's long edge
        float pxx = (B - abs(X)) * sc / px;
        float eb = 0.5 * tau * abs(sn) * sc / px;       // edge band seen as the slat turns
        float cv = clamp(pv + eb + 0.5, 0.0, 1.0) * clamp(pxx + 0.5, 0.0, 1.0);
        if (cv <= 0.0) continue;
        // front faces the camera while (0, sn, -c) . (X, Y, f + Z) < 0
        float Y = yk + v * c;
        bool front = sn * Y - c * (BL_F + Z) < 0.0;
        float vc = clamp(v, -0.5 * h, 0.5 * h);
        float fa = front ? yk + vc : yk - vc;
        vec2 fs = vert ? vec2(fa, X) : vec2(X, fa);
        vec2 fu = vec2(fs.x / asp + 0.5, 0.5 - fs.y);
        vec3 base = front ? FROM(fu) : TO(fu);
        vec3 n = vec3(0.0, sn, -c) * (front ? 1.0 : -1.0);
        float lam = (0.32 + 0.68 * max(dot(n, L), 0.0)) / (0.32 + 0.68 * 0.55);
        vec3 f = base * mix(1.0, lam, tw);
        // shadow from the neighbour on the light side, falling across this slat
        float kn = k + 1.0;
        float tn = kn <= N - 1.0 ? abs(sin(blTurn(p, kn, N, dirW, 0.08 + 0.08 * sin(2.3 * bn + twA + 0.35 * kn)))) : 0.0;
        float vt = front ? v : -v;                       // + towards the lit edge
        float shw = smoothstep(0.5 * h - 0.9 * h * tn, 0.5 * h, vt) * tn;
        f *= 1.0 - 0.7 * shw;
        float spec = pow(max(dot(n, Hv), 0.0), 70.0) * tw;
        f += mix(rimC, compC, 0.3) * spec * 0.45 * beat;
        // the slat's edge: dark lacquer lit from the light side, with a bright lip
        float eN = v > 0.0 ? 1.0 : -1.0;
        vec3 en = vec3(0.0, c, sn) * eN;
        // a rounded, polished edge: dark body with a lit bevel across its thickness
        float bev = sin(3.14159265 * clamp(-pv / max(eb, 1.0), 0.0, 1.0));
        vec3 edgeC = mix(base * 0.18, mix(rimC, compC, 0.25 * bev) * beat,
                         bev * (0.25 + 0.6 * max(dot(en, L), 0.0)));
        float inEdge = clamp(0.5 - pv, 0.0, 1.0);
        f = mix(f, edgeC, inEdge * tw);
        float rim = exp(-abs(pv + 0.5 * eb) / 1.2) * tw * (0.35 + 0.65 * max(dot(en, L), 0.0));
        f += mix(rimC, compC, front ? 0.15 : 0.6) * rim * 0.6 * beat;
        cc[j] = f; cw[j] = cv; cz[j] = Z;
    }
    // front-to-back over the (at most three) candidates; adjacent slats share coverage
    vec3 col = vec3(0.0);
    float ca = 0.0;
    for (int i = 0; i < 3; ++i) {
        int m = 0;
        float zm = 1e6;
        for (int j = 0; j < 3; ++j) { if (cw[j] > 0.0 && cz[j] < zm) { zm = cz[j]; m = j; } }
        if (zm > 1e5) break;
        float wgt = min(cw[m], 1.0 - ca);
        col += cc[m] * wgt;
        ca += wgt;
        cw[m] = 0.0;
    }
    return col + back * (1.0 - ca);
}

// The ends hand over to the frames themselves over the first and last 4%, so
// p = 0 is exactly FROM and p = 1 exactly TO at any render size.
vec3 transition(vec2 uv, float p, VisualUniforms u) {
    vec3 col = mix(FROM(uv), blBody(uv, p, u), smoothstep(0.0, 0.04, p));
    return mix(col, TO(uv), smoothstep(0.96, 1.0, p));
}
