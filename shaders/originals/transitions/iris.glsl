// SPDX-License-Identifier: AGPL-3.0-only
// Iris: a seven-blade camera aperture with curved blades closes on the outgoing
// frame and opens on the incoming one. The blades are dark brushed metal with a
// soft reflection of the scene and spiral seams; their edges catch a chromatic,
// beat-pulsed rim light and cast a soft shadow into the aperture. Near closure
// the image defocuses into luminance-weighted heptagonal bokeh.
const int IR_BLADES = 7;

float irAperture(vec2 a, float R, float rotA) {
    float Rb = 3.0 * R + 0.35;
    float c = cos(rotA), s = sin(rotA);
    vec2 dir = vec2(c, s);
    const float st = 6.2831853 / 7.0;
    mat2 step7 = mat2(cos(st), sin(st), -sin(st), cos(st));
    float d = 1e5;
    for (int i = 0; i < IR_BLADES; ++i) {
        d = min(d, Rb - length(a + (Rb - R) * dir));
        dir = step7 * dir;
    }
    return d;
}

vec3 irBokeh(vec2 uv, float rad, float asp, bool from, float q) {
    if (rad < 1e-4) return from ? FROM(uv) : TO(uv);
    int n = q > 0.5 ? 8 : 16;
    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    // golden-angle spiral, rotated incrementally (no trig per tap)
    const mat2 GA = mat2(-0.7373688, 0.6754903, -0.6754903, -0.7373688);
    vec2 dir = vec2(1.0, 0.0);
    for (int k = 0; k < 16; ++k) {
        if (k >= n) break;
        float fk = (float(k) + 0.5) / float(n);
        vec2 o = dir * sqrt(fk) * rad;
        dir = GA * dir;
        o.x /= asp;
        vec3 c = from ? FROM(uv + o) : TO(uv + o);
        float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
        float w = 1.0 + 3.0 * l * l;
        acc += c * w;
        wsum += w;
    }
    return acc / wsum;
}

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1508, 0.1981, 0.2399, 0.2783, 0.3156, 0.3558, 0.4089, 0.5566, 0.6170, 0.6585, 0.6956, 0.7325, 0.7716, 0.8134, 0.8638, 1.0000);
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
    float win = 4.0 * p * (1.0 - p);
    bool first = p < 0.5;
    float h = first ? p * 2.0 : p * 2.0 - 1.0;
    float eh = h * h * (3.0 - 2.0 * h);
    vec2 c = (vec2(fract(sd * 3.71), fract(sd * 5.13)) - 0.5) * vec2(0.18, 0.12);
    vec2 a = (uv - 0.5) * vec2(asp, 1.0) - c;
    float Rmax = 0.5 * length(vec2(asp, 1.0)) + length(c) + 0.14;
    float R = Rmax * (first ? 1.0 - eh : eh);
    float rotA = 6.2831853 * sd + 0.55 * p * (2.0 - p);
    float sdf = irAperture(a, R, rotA);

    // the frame seen through the aperture: defocus peaks near closure
    float blur = 0.026 * win * win;
    vec2 cu = c / vec2(asp, 1.0) + 0.5;
    float z = first ? 1.0 + 0.07 * eh : 1.0 + 0.09 * (1.0 - eh);
    vec2 suv = cu + (uv - cu) / z;
    vec2 rdir = a * inversesqrt(max(dot(a, a), 1e-6));
    float edgeBand = exp(-max(sdf, 0.0) / 0.05) * win;
    vec2 ca = rdir * 0.012 * edgeBand / vec2(asp, 1.0);
    vec3 img = vec3(0.0);
    if (sdf > -2.0 * px) img = irBokeh(suv, blur, asp, first, u.presentation1.y);
    if (edgeBand > 0.01 && sdf > -2.0 * px) {
        vec3 cR = first ? FROM(suv - ca) : TO(suv - ca);
        vec3 cB = first ? FROM(suv + ca) : TO(suv + ca);
        img = mix(img, vec3(cR.r, img.g, cB.b), min(edgeBand * 1.5, 1.0));
    }
    // blade shadow inside the aperture
    img *= 1.0 - 0.55 * exp(-max(sdf, 0.0) / 0.06) * win;

    // blades: brushed dark metal, spiral seams, scene reflection
    float r = length(a);
    float phi = atan2_(a.y, a.x);
    float sp = (phi - rotA - 2.2 * (r - R)) * (7.0 / 6.2831853) + 0.5;
    float sf = fract(sp);
    float seamD = min(sf, 1.0 - sf) * 6.2831853 * max(r, 0.02) / 7.0;
    float seam = 1.0 - smoothstep(0.0, 2.2 * px, seamD);
    float overlap = smoothstep(0.0, 0.35, sf);
    vec3 pc1 = suppressGreenCast(palVisual(0.22 + 0.2 * sd, u));
    vec3 pc2 = suppressGreenCast(palVisual(0.72 + 0.2 * sd, u));
    vec3 bladeBase = vec3(0.0055, 0.006, 0.0068) + 0.004 * pc2;
    vec2 refl = vec2(1.0) - uv;
    vec3 scene = first ? FROM(refl) : TO(refl);
    float sheenA = 0.5 + 0.5 * cos(2.0 * (phi - rotA * 0.3) - 1.2 + 3.0 * r);
    float sl = dot(scene, vec3(0.333));
    vec3 sheenC = mix(vec3(0.5), scene / max(sl, 0.02) * 0.5, 0.6) * (0.5 + 0.5 * min(sl * 4.0, 1.0));
    vec3 blade = bladeBase + scene * 0.05 * (0.6 + 0.4 * overlap)
               + sheenC * (pow(sheenA, 12.0) * 0.05 + pow(sheenA, 80.0) * 0.09) * (0.3 + 0.7 * overlap);
    blade *= 0.45 + 0.55 * overlap;
    blade *= 1.0 - 0.8 * seam;

    // rim light on the blade edges, beat pulsed, complementary inner fringe
    float beat = 0.75 + 0.5 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    vec3 rimC = mix(pc1, pc2, 0.5 + 0.5 * sin(phi + rotA)) * 1.2;
    vec3 rimC2 = pc2;
    float rimO = exp(-abs(sdf + 1.5 * px) / (2.0 * px));
    float rimG = exp(-max(-sdf, 0.0) / 0.018) * (1.0 - smoothstep(0.0, 4.0 * px, sdf));
    float cov = clamp(0.5 + sdf / px, 0.0, 1.0);
    vec3 col = mix(blade, img, cov);
    col += (rimC * (rimO * 0.9 + rimG * 0.35) + rimC2 * exp(-abs(sdf - 3.0 * px) / (2.5 * px)) * 0.35) * beat * win;
    return col;
}
