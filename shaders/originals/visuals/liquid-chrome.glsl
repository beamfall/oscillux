// SPDX-License-Identifier: AGPL-3.0-only
// Liquid Chrome.
// One nude woman dancing alone on a glossy club floor, turned to liquid chrome:
// nothing is drawn of her but her outline, rounded out into a mirror, so all
// you see inside it is the club bent round her curves. Rings of light strips
// circle the room and two light poles stand in it; the rings jump round on
// every beat, so their reflections slide over her in steps, and the bright
// horizon of the room runs along her contours. On each kick a ripple of bass
// runs out from her hips across the chrome, and the metal flows slowly over
// her all the time. Her reflection lies on the floor beneath her. She sways
// her hips over two beats and dips into each one; every eight beats she
// changes moves and may turn three-quarters, and the room takes a new hue.
// param0 = Glow ; param1 = Sway ; param2 = Liquid

const float LQ_SC = 0.82;              // her height on screen, in half-frame heights per unit
const vec2 LQ_FOOT = vec2(0.0, -0.7);
const vec3 LQ_EYE = vec3(0.0, -0.24, -0.97); // looking at her, a little down

// Tapered capsule from a (radius ra) to b (radius rb).
float lqCapsule(vec2 p, vec2 a, vec2 b, float ra, float rb) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * h) - mix(ra, rb, h);
}

float lqEllipse(vec2 p, vec2 c, vec2 r) {
    vec2 q = (p - c) / r;
    return (length(q) - 1.0) * min(r.x, r.y);
}

// The middle joint of a two-bone limb from a to c, bent toward side `bend`.
vec2 lqJoint(vec2 a, vec2 c, float l1, float l2, vec2 bend) {
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
// waist, bust, shoulder, neck), each eased in with zero slope so the curve stays smooth
// up to the shoulder.
const float LQ_KY[6] = float[6](0.78, 0.92, 1.08, 1.24, 1.375, 1.5);

float lqOutline(float y, vec3 lo, vec3 hi) {
    float w = lo.x;
    w = mix(w, lo.y, smoothstep(LQ_KY[0], LQ_KY[1], y));
    w = mix(w, lo.z, smoothstep(LQ_KY[1], LQ_KY[2], y));
    w = mix(w, hi.x, smoothstep(LQ_KY[2], LQ_KY[3], y));
    w = mix(w, hi.y, smoothstep(LQ_KY[3], LQ_KY[4], y));
    // the shoulder rounds over and slopes into the neck instead of stepping in
    float x = saturate((y - LQ_KY[4]) / (LQ_KY[5] - LQ_KY[4]));
    return mix(w, hi.z, 1.0 - (1.0 - x) * (1.0 - x));
}

// Her figure for this frame: joints and outline, solved for each pixel.
struct LqPose {
    vec2 hip; vec2 chest; vec2 head; float dy;
    vec3 rLo; vec3 rHi; vec3 lLo; vec3 lHi;   // outline half-widths, right and left
    vec2 hj0; vec2 knee0; vec2 ankle0; vec2 toe0;
    vec2 hj1; vec2 knee1; vec2 ankle1; vec2 toe1;
    vec2 sh0; vec2 el0; vec2 ha0; vec2 sh1; vec2 el1; vec2 ha1;
    float turn; float facing; float lag;
};

// Where a hand goes for move `pose` (side -1 left, +1 right; t in beats).
vec2 lqHand(int pose, float side, float t, vec2 hip, vec2 chest, vec2 head) {
    float slow = sin(1.5707963 * t + side);
    if (pose == 0) {
        // both hands up through the hair, elbows out
        return head + vec2(side * (0.1 + 0.02 * slow), 0.09 + 0.05 * slow);
    }
    if (pose == 1) {
        // one hand in her hair, the other on her hip
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

LqPose lqPose(VisualUniforms u) {
    LqPose P;
    float t = u.beatCount + saturate(u.beatPhase);
    float amt = 0.6 + 0.9 * u.param1;

    // moves and turns change with each block of eight beats, eased in over its first beat
    float block = floor(t / 8.0);
    float w = smoothstep(0.0, 1.0, t - block * 8.0);
    // she faces the other way each block, turning back through the front halfway
    // through that beat: the last block's turn unwinds and the new one winds in
    P.facing = ((mod(block, 2.0) < 1.0) ? -1.0 : 1.0) * (2.0 * w - 1.0);
    float turnA = step(0.55, hash11((block - 1.0) * 3.17 + 4.1)), turnB = step(0.55, hash11(block * 3.17 + 4.1));
    P.turn = 0.75 * mix(turnA, turnB, step(0.5, w)) * abs(P.facing);

    // the hips sway over two beats and dip into each one; the shoulders roll after them
    float c = sin(1.5707963 * t);
    float sway = sign(c) * pow(abs(c), 0.7);
    float cl = sin(1.5707963 * (t - 0.45));
    float hx = 0.08 * amt * sway * (1.0 - 0.4 * P.turn);
    P.dy = 0.03 * amt * (0.5 + 0.5 * cos(6.2831853 * t)) + 0.03 * u.beat * amt;
    P.hip = vec2(hx, 0.93 - P.dy);
    P.chest = vec2(-0.45 * 0.08 * amt * sign(cl) * pow(abs(cl), 0.7) * (1.0 - 0.4 * P.turn), 1.30 - 0.85 * P.dy);
    P.head = P.chest + vec2(-0.3 * hx + 0.02 * P.facing * P.turn, 0.29);
    P.lag = 0.08 * amt * sin(1.5707963 * (t - 0.6)) + 0.05 * u.downbeat * P.facing;

    // the outline: an hourglass from the front, bust and seat as she turns
    vec3 fLo = vec3(0.165, 0.192, 0.12);
    vec3 fHi = vec3(0.155, 0.16, 0.04);
    vec3 frontLo = vec3(0.085, 0.085, 0.072);
    vec3 frontHi = vec3(0.15, 0.08, 0.035);
    vec3 backLo = vec3(0.095, 0.16, 0.072);
    vec3 backHi = vec3(0.1, 0.085, 0.035);
    vec3 pop = vec3(0.012, 0.03, 0.0) * sway * (1.0 - P.turn);
    bool right = P.facing > 0.0;
    P.rLo = mix(fLo, right ? frontLo : backLo, P.turn) + pop;
    P.rHi = mix(fHi, right ? frontHi : backHi, P.turn);
    P.lLo = mix(fLo, right ? backLo : frontLo, P.turn) - pop;
    P.lHi = mix(fHi, right ? backHi : frontHi, P.turn);

    // legs: the one under the hip straight, the other bent in and up on its toes
    for (int k = 0; k < 2; k++) {
        float s = (k == 0) ? -1.0 : 1.0;
        vec2 hj = P.hip + vec2(s * 0.085 * (1.0 - 0.6 * P.turn), -0.07);
        float lift = saturate(-s * sway);
        vec2 front = vec2(s * mix(0.075 - 0.04 * lift, 0.01, P.turn) + P.facing * P.turn * s * 0.06 + 0.3 * P.hip.x, 0.0);
        vec2 ankle = vec2(front.x, 0.1 + 0.05 * lift);
        vec2 bend = mix(vec2(-s, 0.0), vec2(P.facing, 0.0), P.turn);
        // from the front a bent knee comes toward us, so only part of its bend shows across
        vec2 knee = mix(mix(hj, ankle, 0.51), lqJoint(hj, ankle, 0.4, 0.375, bend), mix(0.3, 1.0, P.turn));
        // the foot: a pointed heel from the front, the instep and toe as she turns
        vec2 toe = ankle + mix(vec2(0.0, -0.085), vec2(P.facing * 0.11, -0.095), P.turn);
        if (k == 0) { P.hj0 = hj; P.knee0 = knee; P.ankle0 = ankle; P.toe0 = toe; }
        else { P.hj1 = hj; P.knee1 = knee; P.ankle1 = ankle; P.toe1 = toe; }
    }

    // arms
    int poseA = int(floor(hash11(block * 7.31 + 2.3) * 4.0));
    int poseB = int(floor(hash11((block - 1.0) * 7.31 + 2.3) * 4.0));
    for (int k = 0; k < 2; k++) {
        float s = (k == 0) ? -1.0 : 1.0;
        float sw = (s > 0.0) ? P.rHi.y : P.lHi.y;
        vec2 sh = vec2(P.chest.x + s * (sw - 0.035), 1.375 - 0.85 * P.dy);
        vec2 hand = mix(lqHand(poseB, s, t, P.hip, P.chest, P.head), lqHand(poseA, s, t, P.hip, P.chest, P.head), w);
        vec2 elbow = lqJoint(sh, hand, 0.28, 0.25, vec2(s, -0.35));
        vec2 dir = normalize(hand - elbow + vec2(0.0, 1e-4));
        if (k == 0) { P.sh0 = sh; P.el0 = elbow; P.ha0 = hand + dir * 0.085; }
        else { P.sh1 = sh; P.el1 = elbow; P.ha1 = hand + dir * 0.085; }
    }
    return P;
}

// A limb from a to b whose radius follows a muscle profile, one per side: x at a, y at b,
// plus a swell of z centred at w along it. `outer` points to the outer side.
float lqLimb(vec2 p, vec2 a, vec2 b, vec4 rOut, vec4 rIn, vec2 outer) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    vec2 q = pa - ba * h;
    vec2 n = vec2(-ba.y, ba.x);
    vec4 r = (dot(q, n) * dot(n, outer) >= 0.0) ? rOut : rIn;
    float g = saturate(1.0 - (h - r.w) * (h - r.w) * 8.0);
    return length(q) - (mix(r.x, r.y, h) + r.z * g * g);
}

// Her signed distance at p (local units, feet at y = 0).
float lqBody(vec2 p, LqPose P) {
    // torso: the outline about a centre line that bends from the hips to the chest
    float xc = mix(P.hip.x, P.chest.x, smoothstep(0.9, 1.34, p.y + P.dy));
    float yy = p.y + P.dy;
    float dx = p.x - xc;
    float hw = (dx > 0.0) ? lqOutline(yy, P.rLo, P.rHi) : lqOutline(yy, P.lLo, P.lHi);
    float d = max(abs(dx) - hw, max(LQ_KY[0] - yy, yy - LQ_KY[5])) * 0.85;

    // neck and head, with a nose, lips and chin as she turns
    vec2 neckBase = vec2(P.chest.x, 1.43 - 0.85 * P.dy);
    d = osSmin(d, lqCapsule(p, neckBase, P.head - vec2(0.0, 0.06), 0.034, 0.028), 0.03);
    d = min(d, lqEllipse(p, P.head + vec2(0.006 * P.facing * P.turn, 0.0), vec2(0.068, 0.094)));
    vec2 f = vec2(P.facing, 1.0);
    float face = lqCapsule(p, P.head + f * vec2(0.055, 0.005), P.head + f * vec2(0.081, -0.024), 0.011, 0.007);
    face = min(face, lqEllipse(p, P.head + f * vec2(0.064, -0.05), vec2(0.013, 0.01)));
    face = min(face, lqEllipse(p, P.head + f * vec2(0.05, -0.076), vec2(0.018, 0.015)));
    d = osSmin(d, face + 0.03 * (1.0 - P.turn / 0.75), 0.008);

    // long hair: full at the crown, falling in waves past the shoulders and swinging late,
    // its edge broken into locks
    vec2 crown = P.head + vec2(-0.012 * P.facing * P.turn, 0.022);
    float hair = lqEllipse(p, crown, vec2(0.092, 0.112));
    vec2 sway = vec2(-1.3 * P.lag, 0.0);
    for (int k = 0; k < 2; k++) {
        float s = (k == 0) ? -1.0 : 1.0;
        vec2 a = P.head + vec2(s * 0.062, 0.0);
        vec2 b = P.head + vec2(s * (0.1 + 0.02 * P.lag * s), -0.36) + sway * (1.0 + 0.3 * s);
        float h = saturate(dot(p - a, b - a) / dot(b - a, b - a));
        float wave = 0.012 * sin(h * 14.0 + 2.0 * s + 4.0 * P.lag);
        hair = osSmin(hair, lqCapsule(p - vec2(wave, 0.0), a, b, 0.05, 0.03), 0.04);
    }
    vec2 tail = P.head + vec2(-P.lag * 1.2 - 0.07 * P.facing, -0.4);
    float backHair = lqLimb(p, P.head + vec2(-0.03 * P.facing, 0.03), tail, vec4(0.09, 0.035, 0.018, 0.45), vec4(0.085, 0.03, 0.01, 0.5), vec2(-P.facing, 0.0));
    hair = mix(hair, osSmin(hair, backHair, 0.05), P.turn / 0.75);
    hair += 0.008 * (vnoise(vec2(p.x * 60.0, p.y * 14.0)) - 0.5) * saturate((P.head.y - p.y) * 6.0);
    d = osSmin(d, hair, 0.02);

    // legs: a full thigh into a soft knee, a calf that swells high and tapers to a fine
    // ankle, and a heeled shoe
    float legs = 1.0;
    for (int k = 0; k < 2; k++) {
        vec2 hj = (k == 0) ? P.hj0 : P.hj1;
        vec2 kn = (k == 0) ? P.knee0 : P.knee1;
        vec2 an = (k == 0) ? P.ankle0 : P.ankle1;
        vec2 to = (k == 0) ? P.toe0 : P.toe1;
        vec2 out2 = vec2((k == 0) ? -1.0 : 1.0, 0.0);
        float thigh = lqLimb(p, hj + vec2(0.0, 0.03), kn, vec4(0.098, 0.05, 0.014, 0.28), vec4(0.088, 0.045, 0.006, 0.2), out2);
        float calf = lqLimb(p, kn, an, vec4(0.047, 0.022, 0.017, 0.3), vec4(0.046, 0.022, 0.012, 0.26), out2);
        float leg = osSmin(thigh, calf, 0.03);
        float foot = lqLimb(p, an, to, vec4(0.024, 0.012, 0.004, 0.3), vec4(0.022, 0.011, 0.0, 0.3), vec2(0.0, 1.0));
        vec2 heel = vec2(-P.facing * 0.03, -0.1) * P.turn;
        foot = min(foot, lqCapsule(p, an, an + heel, 0.012, 0.005));
        legs = min(legs, osSmin(leg, foot, 0.012));
    }
    d = osSmin(d, legs, 0.035);

    // arms: a rounded shoulder into a slim upper arm, a forearm tapering to the wrist,
    // and a hand with the fingers together
    float arms = 1.0;
    for (int k = 0; k < 2; k++) {
        vec2 sh = (k == 0) ? P.sh0 : P.sh1;
        vec2 el = (k == 0) ? P.el0 : P.el1;
        vec2 ha = (k == 0) ? P.ha0 : P.ha1;
        vec2 out2 = vec2((k == 0) ? -1.0 : 1.0, 0.4);
        vec2 dir = normalize(ha - el + vec2(0.0, 1e-4));
        vec2 wr = ha - dir * 0.085;
        float up = lqLimb(p, sh, el, vec4(0.05, 0.03, 0.01, 0.12), vec4(0.038, 0.03, 0.004, 0.4), out2);
        float fore = lqLimb(p, el, wr, vec4(0.031, 0.018, 0.007, 0.25), vec4(0.03, 0.018, 0.005, 0.3), out2);
        float hand = lqLimb(p, wr, ha, vec4(0.019, 0.008, 0.007, 0.35), vec4(0.019, 0.008, 0.005, 0.35), out2);
        arms = min(arms, osSmin(osSmin(up, fore, 0.02), hand, 0.01));
    }
    d = osSmin(d, arms, 0.035);

    return d;
}

// A palette colour brought to one brightness, so the room is as bright in blue as in lime.
vec3 lqEven(vec3 c) {
    return c * clamp(0.3 / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-3), 0.5, 2.5);
}

// The room's lights seen at elevation el (sine) and azimuth az: the horizon, three
// rings of segmented strips turning in alternate directions, and two light poles.
// `blur` softens all of them, for the room seen out of focus and on the floor.
vec3 lqLights(float el, float az, float spin, vec3 c0, vec3 c1, vec3 c2, float blur) {
    vec3 col = mix(c0, vec3(1.0), 0.35) * exp(-el * el / (0.0006 + 0.02 * blur)) * 0.55;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float e = 0.35 + 0.23 * fi;
        float band = exp(-(el - e) * (el - e) / (0.0012 + 0.02 * blur));
        float n = 10.0 + 6.0 * fi;
        float dir = (i == 1) ? -1.0 : 1.0;
        float x = (az + dir * spin * (1.0 + 0.3 * fi)) * n / 6.2831853;
        float soft = 0.04 + 0.25 * blur;
        float seg = smoothstep(0.28 + soft, 0.28 - soft, abs(fract(x) - 0.5));
        vec3 c = (i == 0) ? c1 : ((i == 1) ? c2 : c0);
        col += c * band * seg * 0.8;
    }
    for (int k = 0; k < 2; k++) {
        float a0 = 1.1 + 0.25 * spin + 3.14159265 * float(k);
        float d = mod(az - a0 + 3.14159265, 6.2831853) - 3.14159265;
        float pole = exp(-d * d / (0.0025 + 0.03 * blur)) * smoothstep(-0.1, 0.3, el) * (1.0 - smoothstep(0.75, 0.95, el));
        col += ((k == 0) ? c2 : c1) * pole * 0.5;
    }
    return col;
}

// The club seen along direction r: haze glowing up from the horizon into a dark dome with
// the rings in it, and a dark floor that mirrors the lights.
vec3 lqEnv(vec3 r, float spin, vec3 c0, vec3 c1, vec3 c2, vec3 deep, float pump, float blur) {
    float el = clamp(r.y, -1.0, 1.0);
    float az = atan2_(r.x, r.z);
    vec3 col = deep * 0.03 + vec3(0.004);
    if (el >= 0.0) {
        col += mix(c0, vec3(1.0), 0.25) * 0.22 * exp(-el * 5.0) * pump;
        col += lqLights(el, az, spin, c0, c1, c2, blur) * pump;
        // a soft white light overhead, for the highlights along her shoulders and arms
        col += vec3(0.5) * smoothstep(0.72, 0.92, el) * (1.0 - saturate(blur * 4.0));
    } else {
        // the floor: the lights again, streaked and dimmer, fading toward our feet
        col += mix(c1, vec3(1.0), 0.2) * 0.14 * exp(el * 4.0) * pump;
        col += lqLights(-el, az, spin, c0, c1, c2, blur + 0.08) * pump * 0.3 * exp(el * 2.5);
    }
    return col;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 sp = centered(uv, u.resolution);
    sp.y = -sp.y;
    float t = u.beatCount + saturate(u.beatPhase);
    float ph = saturate(u.beatPhase);
    float kick = exp(-ph * 3.0) * (0.45 + 0.55 * saturate(u.bassImpact + u.bass * 0.5));
    float glow = 0.5 + u.param0;
    float liquid = 0.3 + 1.2 * u.param2;
    float detail = osDetail(u);

    // the room takes a new hue every eight beats, easing in over the first beat and a half
    float block = floor(t / 8.0);
    float lf = smoothstep(0.0, 1.5, mod(t, 8.0));
    float hA = fract(0.3 + 0.382 * (block - 1.0)), hB = fract(0.3 + 0.382 * block);
    vec3 c0 = mix(lqEven(palVisual(hA, u)), lqEven(palVisual(hB, u)), lf);
    vec3 c1 = mix(lqEven(palVisual(fract(hA + 0.33), u)), lqEven(palVisual(fract(hB + 0.33), u)), lf);
    vec3 c2 = mix(lqEven(palVisual(fract(hA + 0.66), u)), lqEven(palVisual(fract(hB + 0.66), u)), lf);
    vec3 deep = palVisual(0.1, u);
    // the rings jump round early in every beat and hold, a further step on the downbeat
    float jump = smoothstep(0.0, 0.35, ph);
    float bar = floor(t / 4.0) - 1.0 + ((mod(floor(t), 4.0) < 0.5) ? jump : 1.0);
    float spin = (floor(t) + jump) * 0.6 + 0.4 * bar;
    float pump = (0.6 + 0.55 * kick) * glow;

    // the room behind her, out of focus and dim
    vec3 view = normalize(vec3(sp.x * 0.9, 0.7 * (sp.y + 0.6), -1.0));
    vec3 col = lqEnv(view, spin, c0, c1, c2, deep, pump, 0.2) * 0.22;

    LqPose P = lqPose(u);
    float px = 2.0 / (u.resolution.y * LQ_SC);

    // her reflection on the floor, fading away from her feet
    if (sp.y < LQ_FOOT.y) {
        vec2 pm = vec2(sp.x - LQ_FOOT.x, LQ_FOOT.y - sp.y) / LQ_SC;
        if (pm.y < 0.8 && abs(pm.x) < 0.7) {
            float dm = lqBody(pm, P);
            float fm = saturate(0.5 - dm / (3.0 * px));
            vec3 rc = lqEnv(normalize(vec3(pm.x * 1.6, 0.3 - pm.y * 0.3, 0.9)), spin, c0, c1, c2, deep, pump, 0.3);
            col = mix(col, rc * 0.35, fm * exp(-pm.y * 3.0));
        }
    }

    // her
    vec2 p = (sp - LQ_FOOT) / LQ_SC;
    if (p.y > -0.1 && p.y < 2.15 && abs(p.x) < 0.7) {
        float d = lqBody(p, P);
        // a faint glow of the room round her
        col += c0 * exp(-max(d, 0.0) * 35.0) * 0.025 * glow * (0.5 + kick);
        float fill = saturate(0.5 - d / px);
        if (fill > 0.0) {
            float e = 0.006;
            vec2 n2 = normalize(vec2(lqBody(p + vec2(e, 0.0), P) - d, lqBody(p + vec2(0.0, e), P) - d) + vec2(0.0, 1e-5));
            // round her out: the normal turns toward us away from the outline
            float lat = saturate(1.0 + d / 0.17);
            vec3 n = vec3(n2 * lat, sqrt(max(1.0 - lat * lat, 0.0)));
            // the bass ripple running out from her hips, and the slow flow of the metal
            vec2 fromHip = (p - P.hip) * vec2(1.0, 0.8);
            float rr = length(fromHip);
            float w = rr - ph * 1.4;
            float rip = kick * 0.6 * sin(w * 55.0) * exp(-w * w * 60.0);
            n.xy += fromHip / max(rr, 1e-3) * rip * 0.35;
            if (detail > 0.3) {
                vec2 fp = p * 5.0 + vec2(0.0, -0.4 * t);
                n.xy += (vec2(vnoise(fp), vnoise(fp + vec2(7.3, 3.1))) - 0.5) * 0.3 * liquid;
            }
            n = normalize(vec3(n.xy, max(n.z, 0.15)));
            vec3 r = reflect(normalize(LQ_EYE), n);
            vec3 body = lqEnv(r, spin, c0, c1, c2, deep, pump, 0.0) * vec3(1.4, 1.45, 1.5);
            // chrome brightens a little toward grazing angles
            float g = 1.0 - n.z;
            body *= 1.0 + 0.8 * g * g * g;
            // a hairline of light round her outline keeps her apart from the room
            float rim = saturate(1.0 + d / (2.0 * px));
            body += mix(c0, vec3(1.0), 0.4) * rim * rim * 0.12 * glow * (0.6 + 0.6 * kick);
            col = mix(col, body, fill);
        }
    }

    col *= 1.0 - 0.45 * smoothstep(0.8, 1.9, length(sp * vec2(0.85, 1.0)));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    return max(col, 0.0); // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
