// SPDX-License-Identifier: AGPL-3.0-only
// Shoji Shadows.
// A nude couple dance behind a paper shoji screen, seen only as their shadows on
// the paper. A lantern behind them throws one shadow and a second, cooler light
// off to the left throws a fainter one, so where one light is blocked and the
// other is not their outlines carry a fringe of colour. The lantern flares on
// the kick, swelling the shadows and hardening their edges, and its
// flame flickers on the mids. Through each bar the two drift together, leaning
// in and reaching for each other (her arms round his neck, his hands at her
// waist), until their shadows run into one on the downbeat, eclipsing the
// lantern, and then part again. Every eight beats the light takes a new hue and
// their moves and turns change. The lattice of the screen stands dark in front of
// the glowing paper, its edges catching the glow, and the paper's fibres show
// most where the light is strongest. Nothing is drawn but the shadows.
// param0 = Glow ; param1 = Sway ; param2 = Paper

const float SJ_SC = 0.78;    // her height on screen, in half-frame heights per unit
const float SJ_HIM = 1.09;   // how much taller he is
const float SJ_FLOOR = -0.8; // where their feet stand on the paper
const float SJ_RAIL = -0.84; // the top of the wooden rail along the bottom

// Tapered capsule from a (radius ra) to b (radius rb).
float sjCapsule(vec2 p, vec2 a, vec2 b, float ra, float rb) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * h) - mix(ra, rb, h);
}

float sjEllipse(vec2 p, vec2 c, vec2 r) {
    vec2 q = (p - c) / r;
    return (length(q) - 1.0) * min(r.x, r.y);
}

// The middle joint of a two-bone limb from a to c, bent toward side `bend`.
vec2 sjJoint(vec2 a, vec2 c, float l1, float l2, vec2 bend) {
    vec2 d = c - a;
    // never nearer than the bones can fold, or the joint flies off along the line
    float len = clamp(length(d), abs(l1 - l2) + 1e-4, l1 + l2 - 1e-4);
    vec2 dir = d / max(length(d), 1e-4);
    float x = (len * len + l1 * l1 - l2 * l2) / (2.0 * len);
    float h = sqrt(max(l1 * l1 - x * x, 0.0));
    vec2 n = vec2(-dir.y, dir.x);
    n *= sign(dot(n, bend) + 1e-4);
    return a + dir * x + n * h;
}

// The torso's outline is a half-width per side read through six heights (upper thigh, hip,
// waist, chest, shoulder, neck), each eased in with zero slope.
const float SJ_KY[6] = float[6](0.78, 0.92, 1.08, 1.24, 1.375, 1.5);

float sjOutline(float y, vec3 lo, vec3 hi) {
    float w = lo.x;
    w = mix(w, lo.y, smoothstep(SJ_KY[0], SJ_KY[1], y));
    w = mix(w, lo.z, smoothstep(SJ_KY[1], SJ_KY[2], y));
    w = mix(w, hi.x, smoothstep(SJ_KY[2], SJ_KY[3], y));
    w = mix(w, hi.y, smoothstep(SJ_KY[3], SJ_KY[4], y));
    float x = saturate((y - SJ_KY[4]) / (SJ_KY[5] - SJ_KY[4]));
    return mix(w, hi.z, 1.0 - (1.0 - x) * (1.0 - x));
}

// One dancer's figure for this frame. Each is solved in a frame of their own, facing +x
// toward the other.
struct SjPose {
    vec2 hip; vec2 chest; vec2 head; float dy;
    vec3 rLo; vec3 rHi; vec3 lLo; vec3 lHi;   // outline half-widths, front and back
    vec2 hj0; vec2 knee0; vec2 ankle0; vec2 toe0;
    vec2 hj1; vec2 knee1; vec2 ankle1; vec2 toe1;
    vec2 sh0; vec2 el0; vec2 ha0; vec2 sh1; vec2 el1; vec2 ha1;
    float turn; float lag;
};

// Where a hand goes for move `pose` (side -1 back, +1 front; t in beats).
vec2 sjHand(int pose, float side, float t, vec2 hip, vec2 chest, vec2 head) {
    float slow = sin(1.5707963 * t + side);
    if (pose == 0) {
        // both hands up through the hair
        return head + vec2(side * (0.1 + 0.02 * slow), 0.09 + 0.05 * slow);
    }
    if (pose == 1) {
        // one hand up behind the head, the other on the hip
        if (side > 0.0) return head + vec2(0.08, 0.08 + 0.04 * slow);
        return hip + vec2(-0.2, 0.05);
    }
    if (pose == 2) {
        // arms low and loose, swaying out from the hips
        float k = sin(3.14159265 * t + side);
        return hip + vec2(side * (0.33 + 0.05 * k), -0.04 + 0.07 * k);
    }
    // wrists crossed overhead, swaying
    return head + vec2(side * 0.025 + 0.06 * sin(1.5707963 * t), 0.3);
}

// male is 0 for her and 1 for him; mirror is -1 when their frame is flipped on screen,
// so the two sway the same way. As they come together (c) both hands go to `reach`.
SjPose sjPose(float t, float amt, float beat, float male, float mirror, vec2 reach, float c) {
    SjPose P;
    amt *= 1.0 - 0.4 * male;
    float block = floor(t / 8.0);
    float w = smoothstep(0.0, 1.0, t - block * 8.0);
    // in profile to each other, or now and then turned a little more toward us
    float seed = 4.1 + 11.0 * male;
    float more = mix(0.3, 0.4, male);
    P.turn = mix(0.75 - more * step(0.6, hash11((block - 1.0) * 3.17 + seed)), 0.75 - more * step(0.6, hash11(block * 3.17 + seed)), w);

    // the hips sway over two beats and dip into each one; the shoulders roll after them
    float cs = sin(1.5707963 * t);
    float sway = mirror * sign(cs) * pow(abs(cs), 0.7);
    float cl = sin(1.5707963 * (t - 0.45));
    float hx = 0.08 * amt * sway * (1.0 - 0.4 * P.turn);
    P.dy = 0.03 * amt * (0.5 + 0.5 * cos(6.2831853 * t)) + 0.03 * beat * amt;
    P.hip = vec2(hx + 0.02 * c, 0.93 - P.dy);
    P.chest = vec2(-0.45 * 0.08 * amt * mirror * sign(cl) * pow(abs(cl), 0.7) * (1.0 - 0.4 * P.turn) + 0.05 * c, 1.30 - 0.85 * P.dy);
    // leaning in, the head comes forward and tips toward the other's
    P.head = P.chest + vec2(-0.3 * hx + 0.02 * P.turn + 0.03 * c, 0.29 - 0.02 * c);
    P.lag = 0.08 * amt * mirror * sin(1.5707963 * (t - 0.6));

    // the outline: an hourglass for her and a wedge for him from the front, chest and
    // seat in profile
    vec3 fLo = mix(vec3(0.165, 0.192, 0.12), vec3(0.15, 0.15, 0.135), male);
    vec3 fHi = mix(vec3(0.155, 0.16, 0.04), vec3(0.17, 0.205, 0.05), male);
    vec3 frontLo = mix(vec3(0.085, 0.085, 0.072), vec3(0.08, 0.075, 0.08), male);
    vec3 frontHi = mix(vec3(0.15, 0.08, 0.035), vec3(0.105, 0.1, 0.045), male);
    vec3 backLo = mix(vec3(0.095, 0.16, 0.072), vec3(0.09, 0.09, 0.075), male);
    vec3 backHi = mix(vec3(0.1, 0.085, 0.035), vec3(0.1, 0.1, 0.045), male);
    vec3 pop = vec3(0.012, 0.03, 0.0) * sway * (1.0 - P.turn) * (1.0 - male);
    P.rLo = mix(fLo, frontLo, P.turn) + pop;
    P.rHi = mix(fHi, frontHi, P.turn);
    P.lLo = mix(fLo, backLo, P.turn) - pop;
    P.lHi = mix(fHi, backHi, P.turn);

    // legs: the one under the hip straight, the other bent in and up on its toes
    for (int k = 0; k < 2; k++) {
        float s = (k == 0) ? -1.0 : 1.0;
        vec2 hj = P.hip + vec2(s * 0.085 * (1.0 - 0.6 * P.turn), -0.07);
        float lift = saturate(-s * sway) * (1.0 - 0.5 * male);
        vec2 front = vec2(s * mix(0.075 - 0.04 * lift, 0.01, P.turn) + P.turn * s * 0.06 + 0.3 * P.hip.x, 0.0);
        vec2 ankle = vec2(front.x, 0.1 + 0.05 * lift);
        vec2 bend = mix(vec2(-s, 0.0), vec2(1.0, 0.0), P.turn);
        vec2 knee = mix(mix(hj, ankle, 0.51), sjJoint(hj, ankle, 0.4, 0.375, bend), mix(0.3, 1.0, P.turn));
        vec2 toe = ankle + mix(vec2(0.0, -0.085), vec2(0.11 + 0.02 * male, -0.095), P.turn);
        if (k == 0) { P.hj0 = hj; P.knee0 = knee; P.ankle0 = ankle; P.toe0 = toe; }
        else { P.hj1 = hj; P.knee1 = knee; P.ankle1 = ankle; P.toe1 = toe; }
    }

    // arms: this block's move, given up for the other as they come together
    int poseA = int(floor(hash11(block * 7.31 + 2.3 + 5.0 * male) * 4.0));
    int poseB = int(floor(hash11((block - 1.0) * 7.31 + 2.3 + 5.0 * male) * 4.0));
    float hold = smoothstep(0.0, 1.0, c);
    for (int k = 0; k < 2; k++) {
        float s = (k == 0) ? -1.0 : 1.0;
        float sw = (s > 0.0) ? P.rHi.y : P.lHi.y;
        vec2 sh = vec2(P.chest.x + s * (sw - 0.035), 1.375 - 0.85 * P.dy);
        vec2 dance = mix(sjHand(poseB, s, t, P.hip, P.chest, P.head), sjHand(poseA, s, t, P.hip, P.chest, P.head), w);
        vec2 hand = mix(dance, reach + vec2(0.04 * s, 0.04 * s), hold);
        vec2 elbow = sjJoint(sh, hand, 0.28, 0.25, mix(vec2(s, -0.35), vec2(0.0, -1.0), hold));
        vec2 dir = normalize(hand - elbow + vec2(0.0, 1e-4));
        if (k == 0) { P.sh0 = sh; P.el0 = elbow; P.ha0 = hand + dir * 0.085; }
        else { P.sh1 = sh; P.el1 = elbow; P.ha1 = hand + dir * 0.085; }
    }
    return P;
}

// A limb from a to b whose radius follows a muscle profile, one per side: x at a, y at b,
// plus a swell of z centred at w along it. `outer` points to the outer side.
float sjLimb(vec2 p, vec2 a, vec2 b, vec4 rOut, vec4 rIn, vec2 outer) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    vec2 q = pa - ba * h;
    vec2 n = vec2(-ba.y, ba.x);
    vec4 r = (dot(q, n) * dot(n, outer) >= 0.0) ? rOut : rIn;
    float g = saturate(1.0 - (h - r.w) * (h - r.w) * 8.0);
    return length(q) - (mix(r.x, r.y, h) + r.z * g * g);
}

// One dancer's signed distance at p (their own units, feet at y = 0).
float sjBody(vec2 p, SjPose P, float male) {
    // torso: the outline about a centre line that bends from the hips to the chest
    float xc = mix(P.hip.x, P.chest.x, smoothstep(0.9, 1.34, p.y + P.dy));
    float yy = p.y + P.dy;
    float dx = p.x - xc;
    float hw = (dx > 0.0) ? sjOutline(yy, P.rLo, P.rHi) : sjOutline(yy, P.lLo, P.lHi);
    float d = max(abs(dx) - hw, max(SJ_KY[0] - yy, yy - SJ_KY[5])) * 0.85;

    // neck and head, with a nose, lips and chin in profile
    vec2 neckBase = vec2(P.chest.x, 1.43 - 0.85 * P.dy);
    d = osSmin(d, sjCapsule(p, neckBase, P.head - vec2(0.0, 0.06), 0.034 + 0.01 * male, 0.028 + 0.01 * male), 0.03);
    d = min(d, sjEllipse(p, P.head + vec2(0.006 * P.turn, 0.0), vec2(0.068, 0.094) * (1.0 + 0.05 * male)));
    float face = sjCapsule(p, P.head + vec2(0.055, 0.005), P.head + vec2(0.081, -0.024), 0.011, 0.007);
    face = min(face, sjEllipse(p, P.head + vec2(0.064, -0.05), vec2(0.013, 0.01)));
    face = min(face, sjEllipse(p, P.head + vec2(0.05 + 0.01 * male, -0.076 - 0.006 * male), vec2(0.018, 0.015 + 0.004 * male)));
    d = osSmin(d, face + 0.03 * (1.0 - P.turn / 0.75), 0.008);

    // hair: hers long, falling in waves past the shoulders and swinging late; his short
    vec2 crown = P.head + vec2(-0.012 * P.turn, 0.022);
    float hair;
    if (male > 0.5) {
        hair = sjEllipse(p, P.head + vec2(-0.01, 0.014), vec2(0.078, 0.096));
    } else {
        hair = sjEllipse(p, crown, vec2(0.092, 0.112));
        vec2 sway = vec2(-1.3 * P.lag, 0.0);
        for (int k = 0; k < 2; k++) {
            float s = (k == 0) ? -1.0 : 1.0;
            vec2 a = P.head + vec2(s * 0.062, 0.0);
            vec2 b = P.head + vec2(s * (0.1 + 0.02 * P.lag * s), -0.36) + sway * (1.0 + 0.3 * s);
            float h = saturate(dot(p - a, b - a) / dot(b - a, b - a));
            float wave = 0.012 * sin(h * 14.0 + 2.0 * s + 4.0 * P.lag);
            hair = osSmin(hair, sjCapsule(p - vec2(wave, 0.0), a, b, 0.05, 0.03), 0.04);
        }
        vec2 tail = P.head + vec2(-P.lag * 1.2 - 0.07, -0.4);
        float backHair = sjLimb(p, P.head + vec2(-0.03, 0.03), tail, vec4(0.09, 0.035, 0.018, 0.45), vec4(0.085, 0.03, 0.01, 0.5), vec2(-1.0, 0.0));
        hair = mix(hair, osSmin(hair, backHair, 0.05), P.turn / 0.75);
        hair += 0.008 * (vnoise(vec2(p.x * 60.0, p.y * 14.0)) - 0.5) * saturate((P.head.y - p.y) * 6.0);
    }
    d = osSmin(d, hair, 0.02);

    // legs: a full thigh into a soft knee, a calf that swells high and tapers to the ankle;
    // his are heavier
    float ls = 1.0 + 0.18 * male;
    float legs = 1.0;
    for (int k = 0; k < 2; k++) {
        vec2 hj = (k == 0) ? P.hj0 : P.hj1;
        vec2 kn = (k == 0) ? P.knee0 : P.knee1;
        vec2 an = (k == 0) ? P.ankle0 : P.ankle1;
        vec2 to = (k == 0) ? P.toe0 : P.toe1;
        vec2 out2 = vec2((k == 0) ? -1.0 : 1.0, 0.0);
        float thigh = sjLimb(p, hj + vec2(0.0, 0.03), kn, vec4(0.098, 0.05, 0.014, 0.28) * ls, vec4(0.088, 0.045, 0.006, 0.2) * ls, out2);
        float calf = sjLimb(p, kn, an, vec4(0.047, 0.022, 0.017, 0.3) * ls, vec4(0.046, 0.022, 0.012, 0.26) * ls, out2);
        float leg = osSmin(thigh, calf, 0.03);
        float foot = sjLimb(p, an, to, vec4(0.024, 0.012, 0.004, 0.3) * ls, vec4(0.022, 0.011, 0.0, 0.3) * ls, vec2(0.0, 1.0));
        foot = min(foot, sjCapsule(p, an, an + vec2(-0.03, -0.1) * P.turn, 0.012, 0.005));
        legs = min(legs, osSmin(leg, foot, 0.012));
    }
    d = osSmin(d, legs, 0.035);

    // arms: a rounded shoulder into the upper arm, a forearm tapering to the wrist, and a
    // hand with the fingers together; his are heavier
    float as = 1.0 + 0.25 * male;
    float arms = 1.0;
    for (int k = 0; k < 2; k++) {
        vec2 sh = (k == 0) ? P.sh0 : P.sh1;
        vec2 el = (k == 0) ? P.el0 : P.el1;
        vec2 ha = (k == 0) ? P.ha0 : P.ha1;
        vec2 out2 = vec2((k == 0) ? -1.0 : 1.0, 0.4);
        vec2 dir = normalize(ha - el + vec2(0.0, 1e-4));
        vec2 wr = ha - dir * 0.085;
        float up = sjLimb(p, sh, el, vec4(0.05, 0.03, 0.01, 0.12) * as, vec4(0.038, 0.03, 0.004, 0.4) * as, out2);
        float fore = sjLimb(p, el, wr, vec4(0.031, 0.018, 0.007, 0.25) * as, vec4(0.03, 0.018, 0.005, 0.3) * as, out2);
        float hand = sjLimb(p, wr, ha, vec4(0.019, 0.008, 0.007, 0.35), vec4(0.019, 0.008, 0.005, 0.35), out2);
        arms = min(arms, osSmin(osSmin(up, fore, 0.02), hand, 0.01));
    }
    d = osSmin(d, arms, 0.035);

    return d;
}

// The couple's shadow at paper point q, in her units: her frame from herO, his mirrored
// from hisO. Close together the two run into one.
float sjCouple(vec2 q, SjPose W, SjPose M, vec2 herO, vec2 hisO, float c) {
    vec2 p = (q - herO) / SJ_SC;
    vec2 pm = vec2(hisO.x - q.x, q.y - hisO.y) / (SJ_SC * SJ_HIM);
    float dw = 1.0, dm = 1.0;
    if (p.y > -0.15 && p.y < 2.2 && p.x > -0.7 && p.x < 0.95) dw = sjBody(p, W, 0.0);
    if (pm.y > -0.15 && pm.y < 2.2 && pm.x > -0.7 && pm.x < 0.95) dm = sjBody(pm, M, 1.0) * SJ_HIM;
    return osSmin(dw, dm, 0.01 + 0.08 * c * c);
}

// A palette colour brought to one brightness, so the paper is as bright in teal as in amber.
vec3 sjEven(vec3 c) {
    return c * clamp(0.3 / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-3), 0.5, 2.5);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 sp = centered(uv, u.resolution);
    sp.y = -sp.y;
    float t = u.beatCount + saturate(u.beatPhase);
    float ph = saturate(u.beatPhase);
    float kick = exp(-ph * 3.0) * (0.45 + 0.55 * saturate(u.bassImpact + u.bass * 0.5));
    float glow = 0.5 + u.param0;
    float grain = 0.3 + 1.4 * u.param2;
    float amt = 0.6 + 0.9 * u.param1;
    float detail = osDetail(u);

    // through each bar they drift together, closest on the downbeat, and part again
    float a = mod(t, 4.0);
    float c = max(smoothstep(1.8, 4.0, a), 1.0 - smoothstep(0.0, 1.4, a));
    c = saturate(c + 0.15 * u.downbeat * exp(-ph * 3.0));
    float sep = mix(0.95, 0.31, c);
    float hs = SJ_SC * SJ_HIM;
    vec2 herO = vec2(-0.5 * sep, SJ_FLOOR), hisO = vec2(0.5 * sep, SJ_FLOOR);
    // her hands go round his neck, his to her waist
    SjPose W = sjPose(t, amt, u.beat, 0.0, 1.0, vec2(sep / SJ_SC - 0.06, 1.5), c);
    SjPose M = sjPose(t, amt, u.beat, 1.0, -1.0, vec2(sep / hs - 0.1, 0.99), c);

    // the light takes a new hue every eight beats, easing in over a beat and a half
    float block = floor(t / 8.0);
    float lf = smoothstep(0.0, 1.5, mod(t, 8.0));
    float hA = fract(0.08 + 0.382 * (block - 1.0)), hB = fract(0.08 + 0.382 * block);
    vec3 warm = mix(sjEven(palVisual(hA, u)), sjEven(palVisual(hB, u)), lf);
    vec3 cool = mix(sjEven(palVisual(fract(hA + 0.5), u)), sjEven(palVisual(fract(hB + 0.5), u)), lf);
    vec3 deep = palVisual(0.1, u);
    float flame = 1.0 + 0.07 * sin(u.time * 23.0 + 3.0 * sin(u.time * 7.0)) * (0.4 + u.mid);
    float pump = (0.5 + 0.8 * kick) * glow * flame;

    // the lantern swells on the kick: the shadows swell from it and their edges harden
    vec2 lc = vec2(0.04 * sin(t * 0.7853982), 0.12);
    float grow = 1.0 + 0.07 * kick;
    float pen = mix(0.045, 0.015, saturate(kick * 1.2));
    float sh1 = 1.0 - smoothstep(-pen, pen, sjCouple(lc + (sp - lc) / grow, W, M, herO, hisO, c));
    // the second light, off to the left, throws a softer shadow a little to the right
    vec2 l2 = vec2(-1.1, 0.4);
    float sh2 = 0.0;
    if (detail > 0.3) sh2 = 1.0 - smoothstep(-0.09, 0.09, sjCouple(l2 + (sp - vec2(0.14, -0.01) - l2) / 1.03, W, M, herO, hisO, c));

    // the paper: fibres and pulp that show most where the light comes through
    float fib = fbm(sp * vec2(2.5, 14.0) + 3.7) - 0.5;
    float pulp = vnoise(sp * vec2(70.0, 9.0)) - 0.5;
    float tex = 1.0 + (0.28 * fib + 0.18 * pulp) * grain;
    float r2 = dot(sp - lc, sp - lc);
    float i1 = (0.25 + 0.9 * exp(-r2 * 0.7)) * pump;
    float i2 = (0.3 + 0.2 * exp(-dot(sp - l2, sp - l2) * 0.4)) * glow;
    vec3 col = (warm * i1 * (1.0 - 0.93 * sh1) + cool * i2 * (1.0 - 0.9 * sh2)) * 0.32 * tex;
    // the lantern itself, a soft bright patch through the paper that they eclipse
    col += warm * exp(-r2 * 9.0) * 0.12 * pump * (1.0 - 0.75 * sh1);
    col += deep * 0.01;

    // the lattice: dark wood in front of the paper, wider stiles where the panels meet, the
    // edges catching the glow; and the solid rail along the bottom
    float px = 2.0 / u.resolution.y;
    float gx = abs(fract((sp.x - 0.235) / 0.47 + 0.5) - 0.5) * 0.47;
    float gy = abs(fract((sp.y - SJ_RAIL) / 0.335 + 0.5) - 0.5) * 0.335;
    float bar = min(gx - ((abs(abs(sp.x) - 1.175) < 0.2) ? 0.026 : 0.012), gy - 0.012);
    if (sp.y < SJ_RAIL) bar = min(bar, sp.y - SJ_RAIL);
    float wood = saturate(0.5 - bar / px);
    float grainW = 0.8 + 0.4 * vnoise(sp * vec2(3.0, 70.0));
    vec3 woodC = deep * 0.02 * grainW + col * (0.05 + 0.3 * exp(min(bar, 0.0) / (1.5 * px)));
    col = mix(col, woodC, wood);

    col *= 1.0 - 0.45 * smoothstep(0.9, 2.0, length(sp * vec2(0.8, 1.0)));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    return max(col, 0.0); // LINEAR HDR — post chain tonemaps
}
