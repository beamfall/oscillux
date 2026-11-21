// SPDX-License-Identifier: AGPL-3.0-only
// Disco Floor.
// Saturday night under the mirror ball: a lit LED dance floor runs back to a
// crowd at the far wall, and eight dancers work it: six women, curvy in
// sequinned minis and catsuits, and two men, seen as dark silhouettes edged
// with a thin rim of the rig's two colours. Every dancer pops a hip out on
// each beat and dips into it, the knees giving and the shoulders answering
// the hips, and every eight beats each one changes moves (hands up, a hand
// through the hair or his point, arms low and loose, hands on the hips) and
// may turn to profile. Hair swings behind the sway and whips round on the bar. The floor changes
// its pattern every eight beats too (a checker that flips on the beat, a
// ripple from the middle, a scatter, a diagonal chase) and flashes on the
// kick; the ball throws its spots across the wall, the floor and the dancers,
// and four moving heads sweep coloured beams through the haze, changing
// colour on the bar. The camera holds still; only the room moves.
// param0 = Glow ; param1 = Sway ; param2 = Sparkle

const float DF_H = -0.12;      // horizon
const float DF_F = 1.85;       // focal length
const float DF_CAMH = 1.0;     // eye height above the floor
const vec2 DF_BALL = vec2(0.0, 0.80);
const float DF_BALL_R = 0.12;

// depth and screen x of the eight dancers, back to front
const float DF_Z[8] = float[8](9.5, 8.5, 7.5, 6.5, 5.5, 4.6, 3.8, 2.7);
// who dances where: mostly women, two men among them, a woman out front
const float DF_MALE[8] = float[8](0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0);
const float DF_X[8] = float[8](0.05, -0.95, 1.0, -0.38, 0.52, -1.22, 1.24, -0.12);

// Tapered capsule from a (radius ra) to b (radius rb).
float dfCapsule(vec2 p, vec2 a, vec2 b, float ra, float rb) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * h) - mix(ra, rb, h);
}

float dfEllipse(vec2 p, vec2 c, vec2 r) {
    vec2 q = (p - c) / r;
    return (length(q) - 1.0) * min(r.x, r.y);
}

// The middle joint of a two-bone limb from a to c, bent toward side `bend`.
vec2 dfJoint(vec2 a, vec2 c, float l1, float l2, vec2 bend) {
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
// waist, bust, shoulder, neck), each eased in with zero slope so the curve stays smooth.
const float DF_KY[6] = float[6](0.78, 0.92, 1.08, 1.24, 1.38, 1.47);

float dfOutline(float y, vec3 lo, vec3 hi) {
    float w = lo.x;
    w = mix(w, lo.y, smoothstep(DF_KY[0], DF_KY[1], y));
    w = mix(w, lo.z, smoothstep(DF_KY[1], DF_KY[2], y));
    w = mix(w, hi.x, smoothstep(DF_KY[2], DF_KY[3], y));
    w = mix(w, hi.y, smoothstep(DF_KY[3], DF_KY[4], y));
    return mix(w, hi.z, smoothstep(DF_KY[4], DF_KY[5], y));
}

// One dancer's figure for this frame: joints and outline, solved for each pixel near it.
struct DfPose {
    vec2 hip; vec2 chest; vec2 head; vec2 headR; float dy;
    vec3 rLo; vec3 rHi; vec3 lLo; vec3 lHi;   // outline half-widths, right and left
    vec2 hj0; vec2 knee0; vec2 ankle0; vec2 toe0;
    vec2 hj1; vec2 knee1; vec2 ankle1; vec2 toe1;
    vec2 sh0; vec2 el0; vec2 ha0; vec2 sh1; vec2 el1; vec2 ha1;
    vec2 hairA; vec2 hairB; float hairR; float style;
    float male; float dress; float turn; float facing; float lag; float sway;
};

// Where a hand goes for move `pose` (side -1 left, +1 right; t in beats).
vec2 dfHand(int pose, float side, float t, float male, vec2 sh, vec2 hip, vec2 head) {
    if (pose == 0) {
        // arms up, wrists crossing and parting over the head
        float w = sin(3.14159265 * t + side * 0.7);
        return head + vec2(side * 0.05 + 0.09 * w, 0.31 - 0.03 * abs(w));
    }
    if (pose == 1) {
        if (male > 0.5) {
            // the point: up and out, then down and across, every two beats
            if (side > 0.0) {
                float up = smoothstep(0.0, 0.35, fract(t * 0.5)) * (1.0 - smoothstep(0.5, 0.85, fract(t * 0.5)));
                return sh + mix(vec2(-0.2, -0.42), vec2(0.34, 0.42), up);
            }
            return hip + vec2(-0.19, 0.03);
        }
        // one hand drawn up through the hair, the other resting on the hip
        if (side > 0.0) return head + vec2(0.07, 0.07 + 0.04 * sin(3.14159265 * t));
        return hip + vec2(-0.2, 0.05);
    }
    if (pose == 2) {
        // arms low and loose, swaying out from the hips
        float w = sin(3.14159265 * t + side);
        return hip + vec2(side * (0.33 + 0.05 * w), -0.04 + 0.07 * w);
    }
    // hands on the hips
    return hip + vec2(side * 0.205, 0.05);
}

DfPose dfPose(float seed, VisualUniforms u) {
    DfPose P;
    float t = u.beatCount + saturate(u.beatPhase);
    P.male = DF_MALE[int(seed) - 1];
    P.dress = (P.male < 0.5 && hash11(seed * 2.9) < 0.6) ? 1.0 : 0.0;
    P.facing = (hash11(seed * 6.7) < 0.5) ? -1.0 : 1.0;
    float amt = (0.55 + 0.9 * u.param1) * (0.8 + 0.4 * hash11(seed * 3.7)) * (1.0 - 0.1 * P.male);
    float mirror = (hash11(seed * 5.1) < 0.5) ? 0.0 : 1.0;

    // moves and turns change with each block of eight beats, eased in over its first beat
    float block = floor(t / 8.0);
    float w = smoothstep(0.0, 1.0, t - block * 8.0);
    P.turn = mix(step(0.62, hash11((block - 1.0) * 3.17 + seed * 7.9)), step(0.62, hash11(block * 3.17 + seed * 7.9)), w);

    // the hip pops to a side on every beat and the knees dip into it; the chest answers late
    float c = cos(3.14159265 * (t + mirror));
    P.sway = sign(c) * pow(abs(c), 0.6);
    float cl = cos(3.14159265 * (t + mirror - 0.18));
    float hx = 0.07 * amt * P.sway * (1.0 - 0.5 * P.turn);
    P.dy = 0.035 * amt * (0.5 + 0.5 * cos(6.2831853 * t)) + 0.015 * u.beat * amt;
    P.hip = vec2(hx, 0.93 - P.dy);
    P.chest = vec2(-0.4 * 0.07 * amt * sign(cl) * pow(abs(cl), 0.6) * (1.0 - 0.5 * P.turn), 1.30 - 0.85 * P.dy);
    P.head = P.chest + vec2(-0.25 * hx + 0.02 * P.facing * P.turn, 0.29 + 0.02 * P.male);
    P.headR = mix(vec2(0.07, 0.097), vec2(0.082, 0.103), P.male);
    P.lag = 0.09 * amt * cos(3.14159265 * (t + mirror - 0.35)) + 0.04 * u.downbeat * (mirror * 2.0 - 1.0);

    // the outline: an hourglass from the front, bust and seat in profile; his is a V
    vec3 fLo = mix(vec3(0.165, 0.19, 0.122), vec3(0.15, 0.155, 0.145), P.male);
    vec3 fHi = mix(vec3(0.155, 0.178, 0.045), vec3(0.19, 0.225, 0.058), P.male);
    vec3 frontLo = mix(vec3(0.085, 0.085, 0.072), vec3(0.09, 0.09, 0.1), P.male);
    vec3 frontHi = mix(vec3(0.15, 0.085, 0.04), vec3(0.13, 0.1, 0.05), P.male);
    vec3 backLo = mix(vec3(0.095, 0.155, 0.072), vec3(0.09, 0.11, 0.08), P.male);
    vec3 backHi = mix(vec3(0.1, 0.09, 0.04), vec3(0.11, 0.1, 0.05), P.male);
    // the popped hip pushes out and the other side straightens
    vec3 pop = vec3(0.012, 0.03, 0.0) * P.sway * (1.0 - P.turn);
    bool right = P.facing > 0.0;
    P.rLo = mix(fLo, right ? frontLo : backLo, P.turn) + pop;
    P.rHi = mix(fHi, right ? frontHi : backHi, P.turn);
    P.lLo = mix(fLo, right ? backLo : frontLo, P.turn) - pop;
    P.lHi = mix(fHi, right ? backHi : frontHi, P.turn);

    // legs: the one under the popped hip straight, the other bent in and up on its toes
    for (int k = 0; k < 2; k++) {
        float s = (k == 0) ? -1.0 : 1.0;
        vec2 hj = P.hip + vec2(s * 0.085 * (1.0 - 0.75 * P.turn), -0.07);
        float lift = saturate(-s * P.sway) * (1.0 - 0.5 * P.male);
        vec2 front = vec2(s * mix(0.08 - 0.035 * lift, 0.0, P.turn) + P.facing * P.turn * s * 0.07 + 0.3 * P.hip.x, 0.0);
        vec2 ankle = vec2(front.x, mix(0.1, 0.035, P.male) + 0.06 * lift);
        vec2 bend = mix(vec2(-s, 0.0), vec2(P.facing, 0.0), P.turn);
        // from the front a bent knee comes toward us, so only part of its bend shows across
        vec2 knee = mix(mix(hj, ankle, 0.51), dfJoint(hj, ankle, mix(0.4, 0.43, P.male), mix(0.375, 0.41, P.male), bend), mix(0.3, 1.0, P.turn));
        // the foot: a pointed heel from the front, the instep and toe in profile
        vec2 toe = ankle + mix(vec2(0.0, -0.085), vec2(P.facing * 0.11, -0.095), P.turn);
        toe = mix(toe, ankle + mix(vec2(0.0, -0.03), vec2(P.facing * 0.12, -0.03), P.turn), P.male);
        if (k == 0) { P.hj0 = hj; P.knee0 = knee; P.ankle0 = ankle; P.toe0 = toe; }
        else { P.hj1 = hj; P.knee1 = knee; P.ankle1 = ankle; P.toe1 = toe; }
    }

    // arms
    int poseA = int(floor(hash11(block * 7.31 + seed * 13.7) * 4.0));
    int poseB = int(floor(hash11((block - 1.0) * 7.31 + seed * 13.7) * 4.0));
    float lu = mix(0.28, 0.31, P.male), ll = mix(0.25, 0.27, P.male);
    for (int k = 0; k < 2; k++) {
        float s = (k == 0) ? -1.0 : 1.0;
        float sw = (s > 0.0) ? P.rHi.y : P.lHi.y;
        vec2 sh = vec2(P.chest.x + s * (sw - 0.035), 1.375 - 0.85 * P.dy);
        vec2 hand = mix(dfHand(poseB, s, t, P.male, sh, P.hip, P.head), dfHand(poseA, s, t, P.male, sh, P.hip, P.head), w);
        vec2 elbow = dfJoint(sh, hand, lu, ll, vec2(s, -0.35));
        vec2 dir = normalize(hand - elbow + vec2(0.0, 1e-4));
        if (k == 0) { P.sh0 = sh; P.el0 = elbow; P.ha0 = hand + dir * 0.085; }
        else { P.sh1 = sh; P.el1 = elbow; P.ha1 = hand + dir * 0.085; }
    }

    // hair: long and loose, big curls, a high ponytail; his is short
    P.style = (P.male > 0.5) ? 3.0 : floor(hash11(seed * 9.3) * 3.0);
    P.hairA = P.head + vec2(0.0, 0.03);
    P.hairB = P.head + vec2(-P.lag - 0.05 * P.facing * P.turn, -0.30);
    P.hairR = 0.085;
    if (P.style > 1.5 && P.style < 2.5) {
        P.hairA = P.head + vec2(-0.02 * P.facing * P.turn, 0.1);
        P.hairB = P.hairA + vec2(-1.5 * P.lag - 0.1 * P.facing * P.turn, -0.24);
        P.hairR = 0.035;
    }
    return P;
}

// A limb from a to b whose radius follows a muscle profile, one per side: x at a, y at b,
// plus a swell of z centred at w along it. `outer` points to the outer side.
float dfLimb(vec2 p, vec2 a, vec2 b, vec4 rOut, vec4 rIn, vec2 outer) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    vec2 q = pa - ba * h;
    vec2 n = vec2(-ba.y, ba.x);
    vec4 r = (dot(q, n) * dot(n, outer) >= 0.0) ? rOut : rIn;
    float g = saturate(1.0 - (h - r.w) * (h - r.w) * 8.0);
    return length(q) - (mix(r.x, r.y, h) + r.z * g * g);
}

// The figure's signed distance at p (local units, feet at y = 0); dressMask is 1 inside the dress.
float dfBody(vec2 p, DfPose P, out float dressMask) {
    // torso: the outline about a centre line that bends from the hips to the chest
    float xc = mix(P.hip.x, P.chest.x, smoothstep(0.9, 1.34, p.y + P.dy));
    float yy = p.y + P.dy;
    float dx = p.x - xc;
    float hw = (dx > 0.0) ? dfOutline(yy, P.rLo, P.rHi) : dfOutline(yy, P.lLo, P.lHi);
    float d = max(abs(dx) - hw, max(DF_KY[0] - yy, yy - DF_KY[5])) * 0.85;

    // neck and head
    vec2 neckBase = vec2(P.chest.x, 1.44 - 0.85 * P.dy);
    d = osSmin(d, dfCapsule(p, neckBase, P.head - vec2(0.0, 0.05), mix(0.036, 0.05, P.male), mix(0.032, 0.045, P.male)), 0.025);
    d = min(d, dfEllipse(p, P.head, P.headR));

    if (P.style < 0.5) {
        // long and loose: full at the crown, falling past the shoulders either side and swinging late
        d = osSmin(d, dfEllipse(p, P.head + vec2(0.0, 0.018), P.headR + vec2(0.028, 0.02)), 0.02);
        vec2 sway = vec2(-1.3 * P.lag, 0.0);
        float strands = min(dfCapsule(p, P.head + vec2(-0.07, -0.01), P.head + vec2(-0.105, -0.26) + sway, 0.05, 0.028),
                            dfCapsule(p, P.head + vec2(0.07, -0.01), P.head + vec2(0.105, -0.26) + sway, 0.05, 0.028));
        d = osSmin(d, mix(strands, dfCapsule(p, P.hairA, P.hairB, P.hairR, 0.06), P.turn), 0.04);
    } else if (P.style < 1.5) {
        vec2 q = p - P.head - vec2(-0.3 * P.lag, 0.025);
        float a = atan2_(q.y, q.x);
        d = min(d, length(q / vec2(1.0, 0.9)) - 0.15 - 0.012 * sin(a * 13.0));
    } else if (P.style < 2.5) {
        d = osSmin(d, dfEllipse(p, P.head + vec2(0.0, 0.01), P.headR + vec2(0.008, 0.01)), 0.02);
        d = osSmin(d, dfCapsule(p, P.hairA, P.hairB, P.hairR, 0.018), 0.02);
    } else {
        d = min(d, dfEllipse(p, P.head + vec2(0.0, 0.015), P.headR + vec2(0.006, 0.0)));
    }

    // legs: a full thigh into a soft knee, a calf that swells high and tapers to the ankle,
    // and a heeled shoe; his trousers run straight and flare below the knee
    float legs = 1.0;
    for (int k = 0; k < 2; k++) {
        vec2 hj = (k == 0) ? P.hj0 : P.hj1;
        vec2 kn = (k == 0) ? P.knee0 : P.knee1;
        vec2 an = (k == 0) ? P.ankle0 : P.ankle1;
        vec2 to = (k == 0) ? P.toe0 : P.toe1;
        vec2 out2 = vec2((k == 0) ? -1.0 : 1.0, 0.0);
        float thigh = dfLimb(p, hj + vec2(0.0, 0.03), kn,
            mix(vec4(0.098, 0.05, 0.014, 0.28), vec4(0.092, 0.06, 0.004, 0.3), P.male),
            mix(vec4(0.088, 0.045, 0.006, 0.2), vec4(0.085, 0.058, 0.0, 0.3), P.male), out2);
        float calf = dfLimb(p, kn, an,
            mix(vec4(0.047, 0.022, 0.017, 0.3), vec4(0.058, 0.07, 0.0, 0.5), P.male),
            mix(vec4(0.046, 0.022, 0.012, 0.26), vec4(0.056, 0.068, 0.0, 0.5), P.male), out2);
        float foot = dfCapsule(p, an, to, mix(0.022, 0.04, P.male), mix(0.01, 0.012, P.male));
        vec2 heel = vec2(-P.facing * 0.03, -0.1) * P.turn * (1.0 - P.male);
        foot = min(foot, dfCapsule(p, an, an + heel, 0.012, 0.005));
        legs = min(legs, osSmin(osSmin(thigh, calf, 0.03), foot, 0.012));
    }
    d = osSmin(d, legs, 0.035);

    // arms: a rounded shoulder into the upper arm, a forearm tapering to the wrist, and a
    // hand with the fingers together; his heavier through the shoulder
    float arms = 1.0;
    for (int k = 0; k < 2; k++) {
        vec2 sh = (k == 0) ? P.sh0 : P.sh1;
        vec2 el = (k == 0) ? P.el0 : P.el1;
        vec2 ha = (k == 0) ? P.ha0 : P.ha1;
        vec2 out2 = vec2((k == 0) ? -1.0 : 1.0, 0.4);
        vec2 dir = normalize(ha - el + vec2(0.0, 1e-4));
        vec2 wr = ha - dir * 0.085;
        float up = dfLimb(p, sh, el, mix(vec4(0.05, 0.03, 0.01, 0.12), vec4(0.06, 0.04, 0.014, 0.18), P.male),
            mix(vec4(0.038, 0.03, 0.004, 0.4), vec4(0.046, 0.038, 0.008, 0.4), P.male), out2);
        float fore = dfLimb(p, el, wr, mix(vec4(0.031, 0.018, 0.007, 0.25), vec4(0.04, 0.024, 0.009, 0.25), P.male),
            mix(vec4(0.03, 0.018, 0.005, 0.3), vec4(0.038, 0.024, 0.006, 0.3), P.male), out2);
        float hand = dfLimb(p, wr, ha, vec4(0.019, 0.008, 0.007, 0.35), vec4(0.019, 0.008, 0.005, 0.35), out2);
        arms = min(arms, osSmin(osSmin(up, fore, 0.02), hand, 0.01));
    }
    d = osSmin(d, arms, 0.035);

    // a short fitted dress: the hip line carried down to mid-thigh, its hem swinging after the hips
    dressMask = 0.0;
    if (P.dress > 0.5) {
        float hem = 0.66 - 0.5 * P.dy;
        float k = saturate((P.hip.y - yy) / (P.hip.y - hem));
        // the hem follows the thighs toward the knees
        vec2 km = 0.5 * (P.knee0 + P.knee1);
        float cx = mix(P.hip.x, km.x, k * (P.hip.y - hem) / max(P.hip.y - km.y, 0.1));
        float dxd = p.x - cx + 0.12 * P.lag * k;
        float hwd = ((dxd > 0.0) ? P.rLo.y : P.lLo.y) * (1.0 - 0.1 * k) + 0.008;
        float ds = max(abs(dxd) - hwd, max(hem - yy, yy - P.hip.y)) * 0.85;
        dressMask = saturate(-min(ds, max(abs(dx) - hw, max(DF_KY[0] - yy, yy - 1.28)) * 0.85) * 40.0);
        d = osSmin(d, ds, 0.015);
    }
    return d;
}

struct DfPalette { vec3 warm; vec3 hot; vec3 cool; };

vec3 dfLed(vec2 tile, float pattern, float t, VisualUniforms u, DfPalette P) {
    float on;
    if (pattern < 1.0) {
        on = mod(tile.x + tile.y + floor(t), 2.0);
    } else if (pattern < 2.0) {
        float r = length(tile - vec2(0.0, 6.0));
        float e0 = r - fract(t) * 6.0, e1 = e0 - 3.0;
        on = exp(-e0 * e0 * 0.8) + 0.25 * exp(-e1 * e1 * 0.8);
    } else if (pattern < 3.0) {
        on = step(0.62, hash21(tile + floor(t) * 1.7));
    } else {
        on = step(fract((tile.x - tile.y) * 0.125 - t * 0.25), 0.3);
    }
    float h = hash21(tile * 1.31 + 7.0);
    vec3 c = (h < 0.4) ? P.hot : ((h < 0.75) ? P.warm : P.cool);
    return c * mix(0.03, 1.0, on);
}

// Spots thrown by the mirror ball: cells in angle and log distance around it, turning as it does.
float dfSpots(vec2 sp, VisualUniforms u) {
    vec2 q = sp - DF_BALL;
    float r = length(q);
    float a = atan2_(q.y, q.x) / 6.2831853 * 48.0 + u.time * 1.1;
    float lr = log(max(r, 1e-3)) * 7.0;
    vec2 cell = floor(vec2(a, lr));
    vec2 f = fract(vec2(a, lr)) - 0.5;
    vec2 o = (hash22(cell) - 0.5) * 0.6;
    float on = step(0.6, hash21(cell + 19.0));
    float s = exp(-dot(f - o, f - o) * 140.0) * on;
    return s * smoothstep(DF_BALL_R * 1.4, DF_BALL_R * 3.0, r);
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 sp = centered(uv, u.resolution);
    sp.y = -sp.y;
    float t = u.beatCount + saturate(u.beatPhase);
    float ph = saturate(u.beatPhase);
    float kick = exp(-ph * 3.0) * (0.45 + 0.55 * saturate(u.bassImpact + u.bass * 0.5));
    float glow = 0.5 + u.param0;
    float sparkle = 0.4 + 1.2 * u.param2;
    float detail = osDetail(u);

    // colours change on the bar
    float bar = floor(u.beatCount / 4.0);
    DfPalette Pal;
    Pal.warm = palVisual(fract(0.12 + bar * 0.17), u);
    Pal.hot = palVisual(fract(0.45 + bar * 0.17), u);
    Pal.cool = palVisual(fract(0.80 + bar * 0.17), u);

    vec3 col;
    float spotGain;

    // the floor's tile coordinates and their pixel footprint, taken here while every pixel
    // runs together: fwidth is undefined inside the branch below
    float floorZ = DF_CAMH * DF_F / max(DF_H - sp.y, 1e-4);
    vec2 floorP = vec2(sp.x * floorZ / DF_F, floorZ);
    vec2 floorW = fwidth(floorP);
    if (sp.y > DF_H) {
        // the far wall: dark, with coloured haze rising off the floor
        float hgt = sp.y - DF_H;
        col = mix(Pal.hot * 0.05, Pal.cool * 0.015, saturate(hgt * 0.9)) * (0.8 + 0.4 * u.level);
        col += Pal.warm * 0.08 * exp(-hgt * 6.0) * (0.6 + kick);
        spotGain = 0.7;
    } else {
        // the LED floor in perspective
        float z = floorZ;
        vec2 fp = floorP;
        vec2 tile = floor(fp);
        vec2 f = fract(fp) - 0.5;
        float pattern = mod(floor(u.beatCount / 8.0), 4.0);
        vec3 led = dfLed(tile, pattern, t, u, Pal);
        vec2 fw = floorW;
        float seamW = max(fw.x, fw.y);
        float edge = max(abs(f.x), abs(f.y));
        float glass = 1.0 - smoothstep(0.44 - seamW, 0.46 + seamW, edge);
        float centre = 1.0 - 0.45 * smoothstep(0.0, 0.5, edge);
        // far tiles fall below a pixel: show their mean instead of aliasing
        float farMix = saturate(seamW * 2.0 - 0.3);
        vec3 mean = (Pal.hot * 0.4 + Pal.warm * 0.35 + Pal.cool * 0.25) * 0.45;
        vec3 floorCol = mix(led * glass * centre, mean, farMix);
        col = floorCol * (0.35 + 1.6 * kick) * glow;
        // a mist where the floor meets the wall
        col = mix(col, Pal.warm * 0.08, exp(-(DF_H - sp.y) * 14.0) * 0.8);
        // the ball, mirrored in the glass
        vec2 mb = vec2(sp.x, 2.0 * DF_H - sp.y) - DF_BALL;
        col += Pal.cool * 0.05 * exp(-length(mb) * 5.0);
        spotGain = 0.35;
    }

    // the moving heads: four beams from the rig, sweeping through the haze
    float haze = 0.55 + 0.45 * fbm(sp * 2.2 + vec2(u.time * 0.05, -u.time * 0.03));
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        vec2 src = vec2(-1.35 + fi * 0.9, 1.08);
        float ang = -1.5708 + (fi - 1.5) * 0.22 + 0.42 * sin(t * 0.39 + fi * 1.7) * (1.0 - 2.0 * mod(fi, 2.0));
        vec2 dir = vec2(cos(ang), sin(ang));
        vec2 q = sp - src;
        float along = dot(q, dir);
        float across = abs(dot(q, vec2(-dir.y, dir.x)));
        float width = 0.012 + max(along, 0.0) * 0.075;
        float aw = across / width;
        float beam = exp(-aw * aw) * step(0.0, along) * exp(-along * 0.55);
        vec3 bc = (mod(fi + bar, 3.0) < 1.0) ? Pal.cool : ((mod(fi + bar, 3.0) < 2.0) ? Pal.hot : Pal.warm);
        col += bc * beam * haze * (0.18 + 0.35 * u.mid + 0.4 * kick) * glow;
    }

    // the crowd along the far wall: heads and shoulders, bouncing on the beat
    {
        float cx = sp.x * 15.0;
        float cell = floor(cx);
        float fx = fract(cx) - 0.5;
        float hh = hash11(cell * 1.13);
        float bob = 0.012 * (0.5 + 0.5 * cos(6.2831853 * (t + hh * 0.3)));
        float top = DF_H + 0.035 + hh * 0.02 - bob;
        vec2 hq = vec2(fx / 15.0, sp.y - top);
        float dh = length(hq) - 0.022;
        float shoulders = sp.y - (DF_H + 0.012 + 0.012 * (1.0 - fx * fx * 4.0) - bob);
        float dc = min(dh, shoulders);
        // some hands go up when the music lifts
        if (hash11(cell * 3.7) < 0.25 + 0.5 * u.level) {
            float hx0 = (cell + 0.5) / 15.0;
            float reach = 0.055 + 0.02 * hh;
            dc = min(dc, dfCapsule(sp, vec2(hx0 - 0.02, top - 0.012), vec2(hx0 - 0.034, top + reach), 0.0045, 0.0035));
            dc = min(dc, dfCapsule(sp, vec2(hx0 + 0.02, top - 0.012), vec2(hx0 + 0.034, top + reach), 0.0045, 0.0035));
        }
        float a = aaFill(dc) * step(DF_H - 0.02, sp.y);
        col = mix(col, Pal.hot * 0.01, a);
        col += Pal.warm * 0.4 * aaLine(dc, 0.0015) * step(DF_H, sp.y) * (0.5 + kick);
    }

    // the ball's spots on the wall and the floor
    float spots = dfSpots(sp, u) * sparkle * (0.5 + 0.8 * u.treble + 0.5 * u.onset);
    col += mix(vec3(1.0), Pal.cool, 0.3) * spots * spotGain;

    // the dancers, back to front, each with its reflection in the floor
    for (int i = 0; i < 8; i++) {
        float z = DF_Z[i];
        float seed = float(i) + 1.0;
        float sc = DF_F / z * (0.95 + 0.1 * hash11(seed * 8.1));
        vec2 foot = vec2(DF_X[i], DF_H - DF_CAMH * DF_F / z);
        vec2 p = (sp - foot) / sc;
        bool inFig = p.y > -0.1 && p.y < 2.2 && abs(p.x) < 0.75;
        bool inRefl = p.y < 0.0 && p.y > -2.2 && abs(p.x) < 0.75 && detail > 0.25;
        if (!inFig && !inRefl) continue;
        DfPose P = dfPose(seed, u);
        float dressMask;
        // one pixel in the figure's units; edges are filled from it, not from fwidth, which
        // this loop's branches leave undefined
        float px = 2.0 / (u.resolution.y * sc);
        // the reflection: the dancer mirrored about the feet, faint in the glass
        if (inRefl) {
            float dr = dfBody(vec2(p.x, -p.y), P, dressMask);
            col *= 1.0 - 0.55 * saturate(0.5 - dr / px) * exp(p.y * 1.5);
        }
        if (!inFig) continue;
        float d = dfBody(p, P, dressMask);
        // a soft halo of the lights behind them
        col += mix(Pal.warm, Pal.hot, saturate(p.y * 0.5)) * exp(-max(d, 0.0) * 40.0) * 0.07 * glow * (0.5 + kick);
        float fill = saturate(0.5 - d / px);
        if (fill <= 0.0) continue;
        // rim light from the outline's normal: the rig's two colours from either side above,
        // the floor's from below
        float e = 0.006, dm;
        vec2 n = normalize(vec2(dfBody(p + vec2(e, 0.0), P, dm) - d, dfBody(p + vec2(0.0, e), P, dm) - d) + vec2(0.0, 1e-5));
        // a thin band, a few pixels wide however far away the dancer is; inside, near black
        float rim = pow(saturate(1.0 + d / (2.5 * px)), 2.0);
        float lightL = pow(saturate(dot(n, vec2(-0.85, 0.53))), 1.5);
        float lightR = pow(saturate(dot(n, vec2(0.85, 0.53))), 1.5);
        float bounce = saturate(-n.y);
        vec3 body = Pal.hot * 0.01
            + (Pal.hot * lightL + Pal.cool * lightR) * rim * (0.8 + 1.4 * kick) * glow
            + Pal.warm * bounce * rim * 0.35 * (0.5 + kick);
        // sequins on the dresses catch the light
        if (dressMask > 0.0) {
            vec2 sq = floor(p * 140.0);
            float dot_ = 1.0 - smoothstep(0.25, 0.45, length(fract(p * 140.0) - 0.5));
            float tw = step(0.9 - 0.06 * u.treble, hash21(sq + floor(u.time * 12.0))) * dot_;
            body += mix(vec3(1.0), Pal.warm, 0.4) * tw * dressMask * sparkle * 0.9;
            body += Pal.hot * 0.03 * dressMask;
        }
        body += mix(vec3(1.0), Pal.cool, 0.3) * dfSpots(sp, u) * sparkle * 0.25;
        col = mix(col, body, fill);
    }
    // the mirror ball, hanging from the rig
    {
        vec2 q = sp - DF_BALL;
        float wire = aaLine(q.x, 0.0015) * step(DF_BALL_R, q.y);
        col = mix(col, vec3(0.05), wire * 0.8);
        float r = length(q);
        float disc = aaFill(r - DF_BALL_R);
        if (disc > 0.0) {
            vec2 nq = q / DF_BALL_R;
            vec3 n = vec3(nq, sqrt(max(1.0 - dot(nq, nq), 0.0)));
            float lon = atan2_(n.x, n.z) + u.time * 0.6;
            float lat = asin(clamp(n.y, -1.0, 1.0));
            vec2 fc = vec2(lon, lat) * (14.0 / 3.14159265);
            vec2 cell = floor(fc);
            vec2 ff = fract(fc) - 0.5;
            float seam = smoothstep(0.38, 0.5, max(abs(ff.x), abs(ff.y)));
            float glint = step(0.88 - 0.1 * u.onset, hash21(cell + floor(u.time * 6.0)));
            vec3 silver = vec3(0.10, 0.10, 0.12) * (0.4 + 0.6 * n.z) + Pal.cool * 0.05;
            vec3 ball = silver * (1.0 - 0.8 * seam) + mix(vec3(1.0), Pal.warm, 0.25) * glint * (1.0 - seam) * (1.2 + 2.0 * kick) * sparkle;
            col = mix(col, ball, disc);
        }
        col += mix(vec3(1.0), Pal.cool, 0.4) * exp(-r * 9.0) * (0.12 + 0.25 * u.treble + 0.3 * kick) * glow;
    }

    col *= 1.0 - 0.35 * smoothstep(0.9, 2.0, length(sp));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    return max(col, 0.0); // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
