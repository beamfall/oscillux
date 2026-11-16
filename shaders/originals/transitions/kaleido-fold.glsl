// SPDX-License-Identifier: AGPL-3.0-only
// Kaleido Fold: from a seeded centre, a slowly turning kaleidoscope of the
// outgoing frame blooms outwards behind a glassy polygonal rim that lenses the
// image as it passes and casts a soft shadow. Ring by ring its mirrored facets
// turn over like cards, key-lit as they turn, opening thin glowing gaps, and
// land showing the incoming frame's kaleidoscope, which a second rim then
// unfolds, from the centre out, into the plain incoming frame. Beat and bass
// pulse the creases and rims.
vec2 kfMirror(vec2 q) { return 1.0 - abs(1.0 - mod(q, 2.0)); }   // mirrored repeat: no clamped smears

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1423, 0.2177, 0.2835, 0.3408, 0.3881, 0.4292, 0.4670, 0.5047, 0.5436, 0.5852, 0.6276, 0.6695, 0.7148, 0.7672, 0.8364, 1.0000);
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
    float e = p * p * p * (p * (p * 6.0 - 15.0) + 10.0);
    float win = sin(3.14159265 * p);
    float N = 6.0 + 2.0 * floor(2.0 * fract(sd * 2.9));
    float A = 6.28318531 / N;
    float dirR = fract(sd * 7.7) > 0.5 ? 1.0 : -1.0;
    vec2 c = (vec2(fract(sd * 3.3), fract(sd * 5.9)) - 0.5) * vec2(0.24, 0.14);
    vec2 s = vec2((uv.x - 0.5) * asp, 0.5 - uv.y);
    vec2 d = s - c;
    float r = length(d);
    float rot = dirR * (0.25 + 0.5 * e) + 6.2831853 * sd;
    float th = atan(d.y, d.x + 1e-7) - rot;
    float fi = floor(th / A);
    float phi = th - (fi + 0.5) * A;                       // angle within the facet
    fi = fi - N * floor(fi / N);
    float rp = r * cos(phi);                               // distance in an N-gon with corners on the creases

    // two polygonal rims sweep out from the centre: the first folds the old frame
    // into its kaleidoscope, the second unfolds the new one
    float k1 = clamp(p / 0.46, 0.0, 1.0);       k1 = k1 * k1 * (3.0 - 2.0 * k1);
    float k3 = clamp((p - 0.5) / 0.47, 0.0, 1.0); k3 = k3 * k3 * (3.0 - 2.0 * k3);
    // the rims end past the farthest corner, so wide frames are covered too
    float Rend = max(1.3, length(vec2(0.5 * asp, 0.5) + abs(c)) + 0.05);
    float R1 = mix(-0.03, Rend, k1), R3 = mix(-0.03, Rend, k3);
    float dB1 = rp - R1, dB3 = rp - R3;
    float m1 = clamp(-dB1 / (1.2 * px) + 0.5, 0.0, 1.0);    // inside the first rim: folded
    float m3 = clamp(-dB3 / (1.2 * px) + 0.5, 0.0, 1.0);    // inside the second: unfolded

    // the facets turn over ring by ring, swept round the circle
    float RW = 0.17;
    float ri = floor(r / RW);
    float ord = 0.45 * fract(fi / N + 0.37 * sd) + 0.55 * min(ri / 4.0, 1.0);
    float qf = clamp((p - 0.2 - 0.32 * ord) / 0.26, 0.0, 1.0);
    float fa = 3.14159265 * qf * qf * qf * (qf * (qf * 6.0 - 15.0) + 10.0);
    float cf = cos(fa), sf = sin(fa);
    float acf = max(abs(cf), 1e-3);
    float phf = phi / acf;                                 // coordinate on the turned facet
    float ac = (fi + 0.5) * A + rot;                       // facet centre line angle
    bool front = cf > 0.0;
    float mk = front ? m1 : 1.0 - m3;                      // how much of the shown face is kaleidoscope

    float beat = 0.6 + 0.8 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    vec3 rimC = suppressGreenCast(palVisual(fract(0.2 * sd + fi / N * 0.5), u));
    float mx = max(rimC.r, max(rimC.g, rimC.b)), mn = min(rimC.r, min(rimC.g, rimC.b));
    vec3 compC = vec3(mx + mn) - rimC;

    // the rims are glass: they lens the image a little as they pass
    float lens = (exp(-dB1 * dB1 / 0.0012) + exp(-dB3 * dB3 / 0.0012)) * 0.07 * win;
    float rl = r * (1.0 - lens);
    // plain face: the facet's own point (on the turned card)
    float tf = ac + phf;
    vec2 sP = c + rl * vec2(cos(tf), sin(tf));
    vec2 fP = clamp(vec2(sP.x / asp + 0.5, 0.5 - sP.y), 0.0, 1.0);
    // kaleidoscope face: a mirrored wedge of the frame, slowly drifting and turning
    float srcA = 6.2831853 * fract(sd * 11.3) - dirR * 0.6 * e;
    vec2 cs = c + 0.09 * (e - 0.5) * vec2(cos(srcA + 0.7), sin(srcA + 0.7));
    float ka = srcA + abs(phf);
    vec2 sK = cs + rl * 0.78 * vec2(cos(ka), sin(ka));
    vec2 fK = kfMirror(vec2(sK.x / asp + 0.5, 0.5 - sK.y));
    vec3 col;
    if (front) {
        col = m1 < 1.0 ? FROM(fP) : vec3(0.0);
        if (m1 > 0.0) col = mix(col, FROM(fK), m1);
    } else {
        col = m3 > 0.0 ? TO(fP) : vec3(0.0);
        if (m3 < 1.0) col = mix(TO(fK), col, m3);
    }

    // lighting of the turning facet: its normal swings about the radial axis
    vec2 tg = vec2(-sin(ac), cos(ac));
    vec3 L = normalize(vec3(-0.5, 0.6, -0.62));
    vec3 n = vec3(tg * sf * (front ? 1.0 : -1.0), -abs(cf));
    float lam = (0.3 + 0.7 * max(dot(n, L), 0.0)) / (0.3 + 0.7 * 0.62);
    col *= mix(1.0, lam, sf);
    vec3 Hv = normalize(L + vec3(0.0, 0.0, -1.0));
    col += mix(rimC, compC, 0.35) * pow(max(dot(n, Hv), 0.0), 40.0) * 0.5 * sf * beat;
    // facets deepen towards their creases (mirror depth)
    float aph = min(abs(phf) / (0.5 * A), 1.0);
    col *= 1.0 - 0.22 * mk * aph * aph;
    // the raised kaleidoscope casts a soft shadow on the plain frame beside its rim
    float sh1 = smoothstep(0.08, 0.0, dB1) * smoothstep(-px, px, dB1);
    float sh3 = smoothstep(-0.08, 0.0, dB3) * smoothstep(px, -px, dB3);
    col *= 1.0 - 0.4 * (front ? sh1 : sh3) * win;

    // creases and turning-facet rims, anti-aliased in pixels
    float ep = (0.5 * A - abs(phf)) * acf * r / px;
    float crease = exp(-ep / 1.3) * 0.8 + exp(-ep / 7.0) * 0.25;
    float arc = (0.5 - abs(fract(r / RW) - 0.5)) * RW / px;
    float ring = (exp(-arc / 1.2) * 0.6 + exp(-arc / 6.0) * 0.18) * step(RW * 0.5, r);
    float rf = 0.45 + 0.55 * exp(-r * 1.8);
    float mw = mk * win;
    col += mix(rimC, compC, 0.25 + 0.5 * sf) * (crease * (0.6 * mw + 0.6 * sf) + ring * (0.25 * mw + 0.7 * sf)) * rf * beat;
    // the glass rims of the two sweeps
    float a1 = abs(dB1), a3 = abs(dB3);
    float rim = (exp(-a1 / (1.4 * px)) * 0.55 + exp(-a1 / 0.012) * 0.16) + (exp(-a3 / (1.4 * px)) * 0.55 + exp(-a3 / 0.012) * 0.16);
    col += mix(compC, rimC, 0.4) * rim * win * beat;
    // a soft jewel at the centre where the facets converge
    col += mix(rimC, compC, 0.5) * 0.3 * exp(-r * r / 0.0016) * mw * beat;

    float cov = clamp(ep + 0.5, 0.0, 1.0);
    cov = 1.0 - (1.0 - cov) * min(sf * 12.0, 1.0);        // flush when not turning
    if (cov < 1.0) {
        // the gaps opened by turning facets: the new frame deep below, with a glow from the centre
        vec3 back = FROM(uv) * 0.05 + TO(uv) * 0.34 + rimC * 0.12 * exp(-r * 4.0) * win * beat;
        col = mix(back, col, cov);
    }
    return col;
}
