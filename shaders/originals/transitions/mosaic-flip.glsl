// SPDX-License-Identifier: AGPL-3.0-only
// Mosaic Flip: the outgoing frame breaks into a mosaic of square tiles in
// three sizes (a seeded quadtree). A wave from a seeded point reaches each
// tile in turn: the tile sinks back, flips half a turn about its own row or
// column axis and settles flush again with the incoming frame on its back.
// Tiles are key-lit by their normal, catch a specular glint and a beat-pulsed
// palette bevel, and throw a soft shadow onto the dark backplate between
// them. Each tile is seen through its own axis, so it only shrinks within
// its cell and every pixel inverts exactly one tile's projection.
const float MF_F = 2.2;

vec3 mfBody(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float px = 1.0 / max(u.resolution.y, 1.0);
    float win = sin(3.14159265 * p);
    vec2 s = vec2((uv.x - 0.5) * asp, 0.5 - uv.y);
    vec2 go = vec2(fract(sd * 13.7), fract(sd * 7.1)) * 0.3;

    // quadtree tile that owns this pixel
    float C = 0.34;
    vec2 g = floor((s + go) / C);
    float hs = hash21(g + vec2(sd * 17.0, 3.0));
    if (hs < 0.6) {
        C *= 0.5;
        g = floor((s + go) / C);
        if (hash21(g + vec2(5.0, sd * 23.0)) < 0.3) { C *= 0.5; g = floor((s + go) / C); }
    }
    vec2 c = (g + 0.5) * C - go;
    float a = 0.5 * C;
    vec2 th = hash22(g * 1.37 + vec2(C * 41.0, sd * 9.0));

    // wave from a seeded origin
    vec2 o = (vec2(hash11(sd * 51.3 + 0.7), hash11(sd * 29.9 + 1.9)) - 0.5) * vec2(asp, 1.0) * 0.8;
    float md = length(vec2(0.5 * asp, 0.5)) + length(o);
    float dl = 0.44 * length(c - o) / md + 0.08 * th.x;
    float q = clamp((p - dl) / 0.46, 0.0, 1.0);
    float ge = q * q * (3.0 - 2.0 * q);
    float ph = 3.14159265 * ge;
    float tw = sin(3.14159265 * q);
    // like a stadium card stunt, every tile tips away from the wave's origin:
    // its trailing edge lifts, its leading edge drops back
    vec2 dv = c - o;
    bool axY = abs(dv.x) > abs(dv.y) + (th.y - 0.5) * 0.5 * length(dv);   // flip about the vertical axis
    float sg = (axY ? dv.x : dv.y) >= 0.0 ? 1.0 : -1.0;
    float cs = cos(ph), sn = sin(ph) * sg;
    vec2 ql = s - c;
    if (!axY) ql = ql.yx;
    float F = MF_F + a * abs(sn) * 1.05 + 0.3 * a * tw;

    float beat = 0.6 + 0.8 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    vec3 rimC = suppressGreenCast(palRoleRim(0.15 + 0.5 * th.x, u));
    float mx = max(rimC.r, max(rimC.g, rimC.b)), mn = min(rimC.r, min(rimC.g, rimC.b));
    vec3 compC = vec3(mx + mn) - rimC;

    // backplate: the incoming frame deep and dim, shadowed by the tile
    vec3 back = TO(0.5 + (uv - 0.5) * 0.97) * 0.12 + rimC * 0.025 * win;
    float sc0 = MF_F / F;
    vec2 sh = abs(ql - vec2(0.12, -0.15) * a * tw) - vec2(a * abs(cs), a) * sc0;
    float sdf = length(max(sh, 0.0)) + min(max(sh.x, sh.y), 0.0);
    back *= 1.0 - 0.7 * tw * (1.0 - smoothstep(-0.2 * a, 0.35 * a, sdf));
    // light wells up from the cavity under a lifting tile and hugs its outline
    vec3 cavC = mix(rimC, compC, 0.3 + 0.4 * th.x);
    cavC = max(cavC - 0.65 * min(cavC.r, min(cavC.g, cavC.b)), 0.0);        // richer, never grey
    cavC /= max(max(cavC.r, max(cavC.g, cavC.b)), 0.05);
    float halo = exp(-max(sdf, 0.0) / (0.1 * a)) * 0.07 + exp(-max(sdf, 0.0) / (0.02 * a)) * 0.2;
    back += cavC * halo * tw * tw * beat;

    float den = cs * MF_F - ql.x * sn;
    if (abs(den) < 1e-4) return back;
    float x = ql.x * F / den;
    float zz = F + x * sn;
    if (zz < 0.2) return back;
    float y = ql.y * zz / MF_F;
    float dx = (a - abs(x)) * abs(cs) * MF_F * F / (zz * zz) / px;
    float dy = (a - abs(y)) * MF_F / zz / px;
    // at rest a tile is flush with its neighbours: no edge to anti-alias
    float cov = 1.0 - (1.0 - clamp(dx + 0.5, 0.0, 1.0) * clamp(dy + 0.5, 0.0, 1.0)) * min(tw * 12.0, 1.0);
    if (cov <= 0.0) return back;

    bool front = cs > 0.0;
    vec2 fl = vec2(front ? x : -x, y);
    vec2 xs = c + (axY ? fl : fl.yx);
    vec2 fu = vec2(xs.x / asp + 0.5, 0.5 - xs.y);
    vec3 col = front ? FROM(fu) : TO(fu);

    // normal in screen axes (x right, y up, z away)
    vec3 n = vec3(sn, 0.0, -cs) * (front ? 1.0 : -1.0);
    if (!axY) n = n.yxz;
    vec3 L = normalize(vec3(-0.45, 0.65, -0.6));
    float lam = (0.3 + 0.7 * max(dot(n, L), 0.0)) / (0.3 + 0.7 * 0.6);
    col *= mix(1.0, lam, tw);
    vec3 Hv = normalize(L + vec3(0.0, 0.0, -1.0));
    // a glossy reflection band slides across the face as it turns, not a flat wash
    float gb = (fl.x + 0.6 * fl.y) / a - (2.0 * ge - 1.0) * 1.6;
    float gloss = exp(-gb * gb * 6.0) * (0.25 + 0.75 * pow(max(dot(n, Hv), 0.0), 8.0));
    col += mix(rimC, compC, 0.35) * gloss * 0.3 * tw * beat;
    float ed = min(dx, dy);
    float bev = exp(-ed / 1.3) + 0.2 * exp(-ed / 6.0);
    col += mix(rimC, compC, front ? 0.2 : 0.65) * bev * 0.55 * tw * beat;
    return mix(back, col, cov);
}

// The ends hand over to the frames themselves over the first and last 4%, so
// p = 0 is exactly FROM and p = 1 exactly TO at any render size.
// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1840, 0.2490, 0.2974, 0.3402, 0.3801, 0.4181, 0.4557, 0.4933, 0.5315, 0.5706, 0.6117, 0.6569, 0.7091, 0.7744, 0.8674, 1.0000);
float trPace(float p) {
    if (!(p > 0.0)) return 0.0;
    if (p >= 1.0) return 1.0;
    float x = p * 16.0;
    int i = int(x);
    return mix(TR_PACE[i], TR_PACE[i + 1], x - float(i));
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    p = trPace(p);
    vec3 col = mix(FROM(uv), mfBody(uv, p, u), smoothstep(0.0, 0.04, p));
    return mix(col, TO(uv), smoothstep(0.96, 1.0, p));
}
