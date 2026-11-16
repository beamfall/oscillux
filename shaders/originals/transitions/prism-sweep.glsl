// SPDX-License-Identifier: AGPL-3.0-only
// Prism Sweep: the screen is a row of triangular glass prisms, like a
// rotating billboard. The outgoing frame is printed in strips on one face of
// each prism and the incoming frame on the next; a sweep (axis, side and
// turning sense seeded) turns each prism a third of a turn in sequence. The
// turning faces are key-lit, a softbox glint runs along the row as each face
// passes the light, the ridge nearest the camera flares in a dispersed
// palette spectrum pulsed by the beat, and the prisms' ends recede in
// perspective against a dark, backlit gap.
const float PS_F = 1.6;

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.2531, 0.3067, 0.3471, 0.3824, 0.4161, 0.4474, 0.4759, 0.5019, 0.5268, 0.5516, 0.5773, 0.6054, 0.6379, 0.6740, 0.7382, 1.0000);
float trPace(float p) {
    if (!(p > 0.0)) return 0.0;
    if (p >= 1.0) return 1.0;
    float x = p * 16.0;
    int i = int(x);
    return mix(TR_PACE[i], TR_PACE[i + 1], x - float(i));
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    p = trPace(p);
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    float win = sin(3.14159265 * p);
    bool horiz = fract(sd * 4.3) > 0.7;
    float dirW = fract(sd * 9.7) > 0.5 ? 1.0 : -1.0;
    float dR = fract(sd * 6.1) > 0.5 ? 1.0 : -1.0;
    vec2 s = vec2((uv.x - 0.5) * asp, 0.5 - uv.y);
    float a = horiz ? s.y : s.x, b = horiz ? s.x : s.y;
    float A = horiz ? 0.5 : 0.5 * asp, B = horiz ? 0.5 * asp : 0.5;
    float N = floor(2.0 * A * (horiz ? 4.0 : 4.5) + 0.5);
    float W = 2.0 * A / N;
    float k = clamp(floor((a + A) / W), 0.0, N - 1.0);
    float ac = -A + (k + 0.5) * W;
    float x = a - ac;

    float ord = dirW > 0.0 ? k / max(N - 1.0, 1.0) : (N - 1.0 - k) / max(N - 1.0, 1.0);
    // uneven, lively cascade: each prism has its own delay and pace, overshoots
    // a touch and settles; the bass leans into the turn
    float hk = hash11(k * 7.31 + sd * 31.7), hk2 = hash11(k * 3.17 + sd * 11.3 + 4.0);
    float dly = 0.52 * (0.72 * ord + 0.28 * hk);
    float dur = 0.43 + 0.08 * (hk2 - 0.5);
    // the cascade surges and eases rather than marching at one pace
    float pp = p + 0.035 * sin(12.566371 * p + 6.2831853 * sd) * win;
    float q = clamp((pp - dly) / dur, 0.0, 1.0);
    float sq2 = sin(3.14159265 * q);
    float e = q * q * q * (q * (q * 6.0 - 15.0) + 10.0) + 0.1 * sq2 * sq2 * smoothstep(0.45, 1.0, q);
    float bassP = clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    // the whole row ripples gently the whole switch, swelling on the bass
    float wob = 0.13 * win * win * (0.45 + 0.55 * bassP) * sin(6.2831853 * (1.2 * p - 0.7 * ord + hk));
    float tw = max(sq2, min(abs(wob) * 5.0, 1.0));
    float th = -dR * (2.0943951 * e + 0.1 * bassP * sq2 * sq2) + wob;
    float c = cos(th), sn = sin(th);
    float r = W * 0.28867513;                         // inradius; the front face sits at z = 0
    vec2 C = vec2(0.0, r);
    vec2 V0 = vec2(-0.5 * W, -r), V1 = vec2(0.5 * W, -r), V2 = vec2(0.0, 2.0 * r);
    V0 = C + vec2(V0.x * c - V0.y * sn, V0.x * sn + V0.y * c);
    V1 = C + vec2(V1.x * c - V1.y * sn, V1.x * sn + V1.y * c);
    V2 = C + vec2(V2.x * c - V2.y * sn, V2.x * sn + V2.y * c);

    float beat = 0.6 + 0.8 * bassP;
    vec3 rimC = suppressGreenCast(palRoleRim(0.25 + 0.4 * sd, u));
    float mx = max(rimC.r, max(rimC.g, rimC.b)), mn = min(rimC.r, min(rimC.g, rimC.b));
    vec3 compC = vec3(mx + mn) - rimC;

    // backdrop between and behind the prisms
    vec3 back = TO(0.5 + (uv - 0.5) * 0.96) * 0.1 + rimC * 0.05 * win * beat;

    // the front-facing face that the (orthographic) ray at x meets
    float zh = 1e5, tf = 0.0;
    int fi = -1;
    vec2 nf = vec2(0.0, -1.0);
    for (int i = 0; i < 3; ++i) {
        vec2 P0 = i == 0 ? V0 : (i == 1 ? V1 : V2);
        vec2 P1 = i == 0 ? V1 : (i == 1 ? V2 : V0);
        vec2 dv = P1 - P0;
        vec2 n = vec2(dv.y, -dv.x) / W;               // outward normal (counter-clockwise order)
        if (n.y >= 0.0 || abs(dv.x) < 1e-6) continue;
        float t = (x - P0.x) / dv.x;
        if (t < 0.0 || t > 1.0) continue;
        float z = P0.y + t * dv.y;
        if (z < zh) { zh = z; tf = t; fi = i; nf = n; }
    }
    float xmn = min(V0.x, min(V1.x, V2.x)), xmx = max(V0.x, max(V1.x, V2.x));
    float dxs = min(x - xmn, xmx - x) / px;
    if (fi < 0) return back;
    float ys = b * (PS_F + zh) / PS_F;                // the prism's ends recede in perspective
    float dys = (B - abs(ys)) * PS_F / (PS_F + zh) / px;
    float cov = clamp(dxs + 0.5, 0.0, 1.0) * clamp(dys + 0.5, 0.0, 1.0);
    // at rest the prisms are flush: no silhouette to fade
    cov = 1.0 - (1.0 - cov) * min(tw * 12.0, 1.0);

    float fa = ac + (tf - 0.5) * W;
    vec2 fs = horiz ? vec2(ys, fa) : vec2(fa, ys);
    vec2 fu = vec2(fs.x / asp + 0.5, 0.5 - fs.y);
    int toFace = dR > 0.0 ? 1 : 2;
    vec3 col;
    if (fi == 0) col = FROM(fu);
    else if (fi == toFace) col = TO(fu);
    else col = rimC * 0.04;

    // lighting in (across, z) with the light from the sweep's leading side
    vec3 n3 = vec3(nf.x, 0.0, nf.y);
    vec3 L = normalize(vec3(-0.5 * dirW, 0.45, -0.75));
    float lam = (0.15 + 0.85 * max(dot(n3, L), 0.0)) / (0.15 + 0.85 * 0.75);
    col *= mix(1.0, lam, tw);
    vec3 Hv = normalize(L + vec3(0.0, 0.0, -1.0));
    float spec = pow(max(dot(n3, Hv), 0.0), 50.0);
    col += mix(rimC, compC, 0.3) * spec * 0.6 * tw * beat;
    // a softbox bar travels along the row the whole switch, catching tilted faces
    float bar = (a * dirW + A) / (2.0 * A) - mix(-0.2, 1.2, p);
    float tilt = 1.0 - abs(nf.y);
    col += mix(rimC, compC, 0.4) * exp(-bar * bar / 0.012) * tilt * 0.3 * win * beat;
    // the ridge nearest the camera flares with a dispersed spectrum
    vec2 Vn = V0.y < V1.y ? (V0.y < V2.y ? V0 : V2) : (V1.y < V2.y ? V1 : V2);
    float dr = abs(x - Vn.x) / px;
    float hue = fract(0.15 * k + 0.3 * sd) + 0.25 * (x - Vn.x) / W;
    vec3 spc = suppressGreenCast(palVisual(hue, u));
    col += mix(spc, compC, 0.25) * (exp(-dr / 1.4) * 0.8 + exp(-dr / 8.0) * 0.25) * tw * tw * beat;
    // and the silhouette edges get a thin lit lip
    col += rimC * exp(-min(dxs, dys) / 1.2) * 0.4 * tw * beat;
    return mix(back, col, cov);
}
