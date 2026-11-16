// SPDX-License-Identifier: AGPL-3.0-only
// Portal: a vortex forms at a seeded point. The outgoing frame twists and is
// dragged towards it with motion blur along the swirl, darkening into a
// lensing shadow, until an event horizon with an energy rim and spiral arms
// opens and widens past the corners. Through it the incoming frame is seen
// magnified and counter-rotated, settling into place as the rim passes.
vec2 poMirror(vec2 x) { return 1.0 - abs(1.0 - abs(x)); }

// Pacing: the switch progress p is remapped through a monotone piecewise-linear
// curve (TR_PACE at p = i/16, from 0 to 1) so the picture changes at an even
// rate, with no burst of change in a few frames (OSC-TRANSITIONS, criterion 4).
const float TR_PACE[17] = float[17](0.0000, 0.1110, 0.2211, 0.2942, 0.3484, 0.3940, 0.4354, 0.4748, 0.5128, 0.5496, 0.5869, 0.6268, 0.6711, 0.7203, 0.7805, 0.8800, 1.0000);
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
    float win = 4.0 * p * (1.0 - p);
    float e = p * p * (3.0 - 2.0 * p);
    float px = 1.0 / max(u.resolution.y, 1.0);
    vec2 sa = vec2(asp, 1.0);
    vec2 c = (vec2(hash11(sd * 41.3 + 0.3), hash11(sd * 67.1 + 1.7)) - 0.5) * vec2(asp * 0.35, 0.3);
    vec2 v = (uv - 0.5) * sa - c;
    float r = length(v);
    float Rmax = length(vec2(0.5 * asp + abs(c.x), 0.5 + abs(c.y))) + 0.06;
    float g = smoothstep(0.1, 0.92, p);
    float Rp = mix(-0.03, Rmax, g * (0.55 + 0.45 * g));
    float dirS = hash11(sd * 13.7 + 4.4) < 0.5 ? -1.0 : 1.0;
    float beat = 0.75 + 0.5 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    float uo = r - Rp;                          // signed distance to the horizon
    float cov = smoothstep(-1.5 * px, 1.5 * px, uo);
    bool lowQ = u.presentation1.y > 0.5;

    vec3 outC = vec3(0.0), inC = vec3(0.0);
    if (cov > 0.0) {
        // swirl and pull of the old frame, blurred along the swirl
        float infl = exp(-max(uo, 0.0) / 0.32);
        float tw = dirS * win * (0.3 + 1.7 * infl * infl);
        float rs = r + win * (0.05 + 0.45 * max(Rp, 0.0)) * infl;
        vec2 vn = v * (rs / max(r, 1e-4));
        float bl = dirS * win * 0.05 * (0.2 + infl);
        int n = lowQ ? 2 : 4;
        float stp = bl / float(n - 1);
        float a0 = tw - 0.5 * bl;
        vec2 cs = vec2(cos(a0), sin(a0));
        vec2 ds = vec2(cos(stp), sin(stp));
        for (int k = 0; k < 4; ++k) {
            if (k >= n) break;
            vec2 vr = vec2(cs.x * vn.x - cs.y * vn.y, cs.y * vn.x + cs.x * vn.y);
            outC += FROM(poMirror((c + vr) / sa + 0.5));
            cs = vec2(cs.x * ds.x - cs.y * ds.y, cs.y * ds.x + cs.x * ds.y);
        }
        outC /= float(n);
        float uop = max(uo, 0.0);
        outC *= 1.0 - 0.7 * exp(-uop / 0.07) * win;   // lensing shadow at the horizon
    }
    vec3 pc = suppressGreenCast(palVisual(0.2 + 0.6 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = vec3(mx + mn) - pc;
    if (cov < 1.0) {
        // the incoming frame seen through the horizon: magnified, lensed and
        // counter-rotated, settling as the portal widens
        float q = clamp(r / max(Rp, 1e-3), 0.0, 1.0);
        float s = (1.0 - 0.38 * (1.0 - e)) * (1.0 - 0.16 * win * (1.0 - q * q));
        float ang = -dirS * 0.6 * (1.0 - e) * (1.0 - e);
        vec2 rc = vec2(cos(ang), sin(ang));
        vec2 vr = vec2(rc.x * v.x - rc.y * v.y, rc.y * v.x + rc.x * v.y) * s;
        float rim = exp(min(uo, 0.0) / 0.07) * win;
        if (lowQ || rim < 0.02) {
            inC = TO(poMirror((c + vr) / sa + 0.5));
        } else {
            float k = 0.02 * rim;
            inC = vec3(TO(poMirror((c + vr * (1.0 + k)) / sa + 0.5)).r,
                       TO(poMirror((c + vr) / sa + 0.5)).g,
                       TO(poMirror((c + vr * (1.0 - k)) / sa + 0.5)).b);
        }
        inC *= 1.0 - 0.55 * rim;
        inC += comp * rim * rim * 0.18 * beat;
    }
    vec3 col = mix(inC, outC, cov);

    // energy rim and spiral arms
    float au = abs(uo);
    float ring = exp(-au / (0.0025 + 1.5 * px)) * win;
    float glow = exp(-au / 0.035) * win;
    float th = atan2_(v.y, v.x);
    float uop = max(uo, 0.0);
    float arm = 0.5 + 0.5 * cos(3.0 * th - dirS * (7.0 * log(uop + 0.06) + 9.0 * p));
    arm = arm * arm; arm *= arm;
    float arms = arm * exp(-uop / 0.13) * smoothstep(0.0, 0.03, uo) * win;
    float pulse = beat * (0.85 + 0.15 * cos(3.0 * th + dirS * 6.0 * p));
    col += pc * (ring * 1.4 + glow * 0.22) * pulse;
    col += mix(comp, pc, 0.35) * arms * 0.6 * beat;
    return col;
}
