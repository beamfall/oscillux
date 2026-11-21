// SPDX-License-Identifier: AGPL-3.0-only
// Neon Kiss.
// Last call in a dark bar. On the brick wall behind it hangs an animated neon
// sign of a nude woman dancing, drawn in one pink tube round her outline with
// nothing inside it: like the real thing it flips from frame to frame, one
// frame a beat, the new pose striking on with a stutter (cleanly on the
// downbeat) while the last one fades in the glass, so she pops her hips
// right, centre, left, centre and changes moves every eight beats. Beside her
// a pair of neon lips purse through the end of each bar and blow a kiss on the
// downbeat, a neon heart floating up from them. Every tube lights the bricks
// around it, the lacquered bar top mirrors the sign, and out of focus in front
// of it all the bar's lights hang as bokeh that swells on the highs.
// param0 = Glow ; param1 = Sway ; param2 = Bokeh

const float NK_SC = 0.7;               // the sign dancer's height on screen, in half-frame heights per unit
const vec2 NK_FOOT = vec2(-0.42, -0.5);
const float NK_BAR = -0.62;            // the near edge of the bar top
const vec2 NK_LIPS = vec2(0.62, 0.32);
const float NK_LS = 0.3;               // the lips' half-width

// Tapered capsule from a (radius ra) to b (radius rb).
float nkCapsule(vec2 p, vec2 a, vec2 b, float ra, float rb) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * h) - mix(ra, rb, h);
}

float nkEllipse(vec2 p, vec2 c, vec2 r) {
    vec2 q = (p - c) / r;
    return (length(q) - 1.0) * min(r.x, r.y);
}

// The middle joint of a two-bone limb from a to c, bent toward side `bend`.
vec2 nkJoint(vec2 a, vec2 c, float l1, float l2, vec2 bend) {
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
const float NK_KY[6] = float[6](0.78, 0.92, 1.08, 1.24, 1.375, 1.5);

float nkOutline(float y, vec3 lo, vec3 hi) {
    float w = lo.x;
    w = mix(w, lo.y, smoothstep(NK_KY[0], NK_KY[1], y));
    w = mix(w, lo.z, smoothstep(NK_KY[1], NK_KY[2], y));
    w = mix(w, hi.x, smoothstep(NK_KY[2], NK_KY[3], y));
    w = mix(w, hi.y, smoothstep(NK_KY[3], NK_KY[4], y));
    // the shoulder rounds over and slopes into the neck instead of stepping in
    float x = saturate((y - NK_KY[4]) / (NK_KY[5] - NK_KY[4]));
    return mix(w, hi.z, 1.0 - (1.0 - x) * (1.0 - x));
}

// The dancer in the sign for this frame: joints and outline, solved for each pixel.
struct NkPose {
    vec2 hip; vec2 chest; vec2 head; float dy;
    vec3 rLo; vec3 rHi; vec3 lLo; vec3 lHi;   // outline half-widths, right and left
    vec2 hj0; vec2 knee0; vec2 ankle0; vec2 toe0;
    vec2 hj1; vec2 knee1; vec2 ankle1; vec2 toe1;
    vec2 sh0; vec2 el0; vec2 ha0; vec2 sh1; vec2 el1; vec2 ha1;
    float turn; float facing; float lag;
};

// Where a hand goes for move `pose` (side -1 left, +1 right; t in beats).
vec2 nkHand(int pose, float side, float t, vec2 hip, vec2 chest, vec2 head) {
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

NkPose nkPose(VisualUniforms u) {
    NkPose P;
    float t = u.beatCount + saturate(u.beatPhase);
    float amt = 0.6 + 0.9 * u.param1;

    // moves and turns change with each block of eight beats, eased in over its first beat
    float block = floor(t / 8.0);
    float w = smoothstep(0.0, 1.0, t - block * 8.0);
    P.turn = 0.75 * mix(step(0.55, hash11((block - 1.0) * 3.17 + 4.1)), step(0.55, hash11(block * 3.17 + 4.1)), w);
    P.facing = (mod(block, 2.0) < 1.0) ? -1.0 : 1.0;

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
        vec2 knee = mix(mix(hj, ankle, 0.51), nkJoint(hj, ankle, 0.4, 0.375, bend), mix(0.3, 1.0, P.turn));
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
        vec2 hand = mix(nkHand(poseB, s, t, P.hip, P.chest, P.head), nkHand(poseA, s, t, P.hip, P.chest, P.head), w);
        vec2 elbow = nkJoint(sh, hand, 0.28, 0.25, vec2(s, -0.35));
        vec2 dir = normalize(hand - elbow + vec2(0.0, 1e-4));
        if (k == 0) { P.sh0 = sh; P.el0 = elbow; P.ha0 = hand + dir * 0.085; }
        else { P.sh1 = sh; P.el1 = elbow; P.ha1 = hand + dir * 0.085; }
    }
    return P;
}

// A limb from a to b whose radius follows a muscle profile, one per side: x at a, y at b,
// plus a swell of z centred at w along it. `outer` points to the outer side.
float nkLimb(vec2 p, vec2 a, vec2 b, vec4 rOut, vec4 rIn, vec2 outer) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    vec2 q = pa - ba * h;
    vec2 n = vec2(-ba.y, ba.x);
    vec4 r = (dot(q, n) * dot(n, outer) >= 0.0) ? rOut : rIn;
    float g = saturate(1.0 - (h - r.w) * (h - r.w) * 8.0);
    return length(q) - (mix(r.x, r.y, h) + r.z * g * g);
}

// Her signed distance at p (local units, feet at y = 0).
float nkBody(vec2 p, NkPose P) {
    // torso: the outline about a centre line that bends from the hips to the chest
    float xc = mix(P.hip.x, P.chest.x, smoothstep(0.9, 1.34, p.y + P.dy));
    float yy = p.y + P.dy;
    float dx = p.x - xc;
    float hw = (dx > 0.0) ? nkOutline(yy, P.rLo, P.rHi) : nkOutline(yy, P.lLo, P.lHi);
    float d = max(abs(dx) - hw, max(NK_KY[0] - yy, yy - NK_KY[5])) * 0.85;

    // neck and head, with a nose, lips and chin as she turns
    vec2 neckBase = vec2(P.chest.x, 1.43 - 0.85 * P.dy);
    d = osSmin(d, nkCapsule(p, neckBase, P.head - vec2(0.0, 0.06), 0.034, 0.028), 0.03);
    d = min(d, nkEllipse(p, P.head + vec2(0.006 * P.facing * P.turn, 0.0), vec2(0.068, 0.094)));
    vec2 f = vec2(P.facing, 1.0);
    float face = nkCapsule(p, P.head + f * vec2(0.055, 0.005), P.head + f * vec2(0.081, -0.024), 0.011, 0.007);
    face = min(face, nkEllipse(p, P.head + f * vec2(0.064, -0.05), vec2(0.013, 0.01)));
    face = min(face, nkEllipse(p, P.head + f * vec2(0.05, -0.076), vec2(0.018, 0.015)));
    d = osSmin(d, face + 0.03 * (1.0 - P.turn / 0.75), 0.008);

    // long hair: full at the crown, falling in waves past the shoulders and swinging late,
    // its edge broken into locks
    vec2 crown = P.head + vec2(-0.012 * P.facing * P.turn, 0.022);
    float hair = nkEllipse(p, crown, vec2(0.092, 0.112));
    vec2 sway = vec2(-1.3 * P.lag, 0.0);
    for (int k = 0; k < 2; k++) {
        float s = (k == 0) ? -1.0 : 1.0;
        vec2 a = P.head + vec2(s * 0.062, 0.0);
        vec2 b = P.head + vec2(s * (0.1 + 0.02 * P.lag * s), -0.36) + sway * (1.0 + 0.3 * s);
        float h = saturate(dot(p - a, b - a) / dot(b - a, b - a));
        float wave = 0.012 * sin(h * 14.0 + 2.0 * s + 4.0 * P.lag);
        hair = osSmin(hair, nkCapsule(p - vec2(wave, 0.0), a, b, 0.05, 0.03), 0.04);
    }
    vec2 tail = P.head + vec2(-P.lag * 1.2 - 0.07 * P.facing, -0.4);
    float backHair = nkLimb(p, P.head + vec2(-0.03 * P.facing, 0.03), tail, vec4(0.09, 0.035, 0.018, 0.45), vec4(0.085, 0.03, 0.01, 0.5), vec2(-P.facing, 0.0));
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
        float thigh = nkLimb(p, hj + vec2(0.0, 0.03), kn, vec4(0.098, 0.05, 0.014, 0.28), vec4(0.088, 0.045, 0.006, 0.2), out2);
        float calf = nkLimb(p, kn, an, vec4(0.047, 0.022, 0.017, 0.3), vec4(0.046, 0.022, 0.012, 0.26), out2);
        float leg = osSmin(thigh, calf, 0.03);
        float foot = nkLimb(p, an, to, vec4(0.024, 0.012, 0.004, 0.3), vec4(0.022, 0.011, 0.0, 0.3), vec2(0.0, 1.0));
        vec2 heel = vec2(-P.facing * 0.03, -0.1) * P.turn;
        foot = min(foot, nkCapsule(p, an, an + heel, 0.012, 0.005));
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
        float up = nkLimb(p, sh, el, vec4(0.05, 0.03, 0.01, 0.12), vec4(0.038, 0.03, 0.004, 0.4), out2);
        float fore = nkLimb(p, el, wr, vec4(0.031, 0.018, 0.007, 0.25), vec4(0.03, 0.018, 0.005, 0.3), out2);
        float hand = nkLimb(p, wr, ha, vec4(0.019, 0.008, 0.007, 0.35), vec4(0.019, 0.008, 0.005, 0.35), out2);
        arms = min(arms, osSmin(osSmin(up, fore, 0.02), hand, 0.01));
    }
    d = osSmin(d, arms, 0.035);

    return d;
}

// The lips at q (half-width 1): their outline's signed distance, and in `mouth` the
// distance to the line between them. pk purses them, narrower and fuller.
float nkLips(vec2 q, float pk, out float mouth) {
    vec2 s = vec2(1.0 - 0.4 * pk, 1.0 + 0.3 * pk);
    q /= s;
    float m = -0.03 + 0.1 * q.x * q.x - 0.035 * exp(-q.x * q.x * 30.0) - 0.03 * pk;
    // the upper lip in two lobes that meet in a cupid's bow, the lower in one
    float up = min(nkEllipse(q, vec2(-0.3, 0.02), vec2(0.52, 0.27)), nkEllipse(q, vec2(0.3, 0.02), vec2(0.52, 0.27)));
    up = max(up, m - q.y);
    float lo = max(nkEllipse(q, vec2(0.0, -0.04), vec2(0.8, 0.36 + 0.05 * pk)), q.y - m);
    float k = min(s.x, s.y);
    mouth = max(abs(q.y - m) / sqrt(1.0 + 0.0256 * q.x * q.x), abs(q.x) - 0.7 + 0.25 * pk) * k;
    return min(up, lo) * k;
}

// A heart with its tip at the origin and its top near y = 1.
float nkHeart(vec2 p) {
    p.x = abs(p.x);
    if (p.y + p.x > 1.0) return length(p - vec2(0.25, 0.75)) - 0.35355339;
    vec2 a = p - vec2(0.0, 1.0), b = p - 0.5 * max(p.x + p.y, 0.0);
    return sqrt(min(dot(a, a), dot(b, b))) * sign(p.x - p.y);
}

// A lit neon tube at distance d (tube half-width w, one pixel px): a near-white core
// in a coloured glow. `on` is how lit it is.
vec3 nkTube(float d, float w, float px, vec3 c, float on) {
    float ad = abs(d);
    float core = saturate((w - ad) / px + 0.5);
    float halo = exp(-ad / (2.2 * w)) * 0.6 + exp(-ad / (9.0 * w)) * 0.12;
    return (c * (1.6 * core + halo) + vec3(0.9) * core * core) * on;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 sp = centered(uv, u.resolution);
    sp.y = -sp.y;
    float t = u.beatCount + saturate(u.beatPhase);
    float ph = saturate(u.beatPhase);
    float kick = exp(-ph * 3.0) * (0.45 + 0.55 * saturate(u.bassImpact + u.bass * 0.5));
    float glow = 0.5 + u.param0;
    float bokehAmt = 0.3 + 1.2 * u.param2;
    float detail = osDetail(u);

    vec3 pink = palVisual(0.42, u);
    vec3 red = palVisual(0.3, u);
    vec3 cool = palVisual(0.88, u);
    vec3 gold = palVisual(0.7, u);

    // the sign flips one frame a beat: the new pose strikes on with a stutter while the
    // last one fades in the glass, which still shows faintly when unlit
    VisualUniforms v = u;
    v.beatCount = floor(t) + 1.0;
    v.beatPhase = 0.0;
    NkPose P = nkPose(v);
    v.beatCount = floor(t);
    NkPose Q = nkPose(v);
    float stutter = (ph < 0.05 ? 0.6 + 0.4 * step(0.5, fract(ph * 60.0)) : 1.0) * smoothstep(0.0, 0.015, ph);
    float strike = mod(floor(t), 4.0) < 0.5 ? 1.0 : stutter;
    float fade = exp(-ph * 45.0);
    float buzz = 1.0 - 0.25 * step(0.86, hash11(floor(t) * 5.3 + 1.7)) * step(0.5, fract(t * 13.0)) * step(ph, 0.4);
    float litGain = (0.45 + 1.0 * kick) * glow;

    // the lips purse through the end of each bar and blow the kiss on the downbeat
    float a = mod(t, 4.0);
    float pk = max(smoothstep(3.3, 3.85, a), 1.0 - smoothstep(0.0, 0.35, a));
    pk = saturate(pk + 0.3 * u.downbeat * exp(-ph * 4.0));
    float mouth;
    float lipsD = nkLips((sp - NK_LIPS) / NK_LS, pk, mouth) * NK_LS;
    mouth *= NK_LS;
    // the heart leaves the lips with the kiss and floats up, fading
    float hAge = a;
    vec2 hp = NK_LIPS + vec2(0.1 + 0.12 * hAge + 0.03 * sin(hAge * 3.0), 0.05 + 0.16 * hAge);
    float hs = 0.07 + 0.03 * smoothstep(0.0, 0.5, hAge);
    float heartD = nkHeart((sp - hp) / hs + vec2(0.0, 0.5)) * hs;
    float heartOn = smoothstep(0.0, 0.08, hAge) * (1.0 - smoothstep(2.0, 3.2, hAge));

    // the dancer: her litGain frame and the fading one, read only near her
    vec2 p = (sp - NK_FOOT) / NK_SC;
    float px = 2.0 / (u.resolution.y * NK_SC);
    float bodyD = 1.0, ghostD = 1.0;
    // her light on the bricks fades out before the edge of the box she is read in
    float near = smoothstep(1.0, 0.75, abs(p.x)) * smoothstep(-0.4, -0.25, p.y) * smoothstep(2.3, 2.1, p.y);
    if (p.y > -0.4 && p.y < 2.3 && abs(p.x) < 1.0) {
        bodyD = nkBody(p, P);
        ghostD = nkBody(p, Q);
    }
    float lipsOn = buzz * litGain;

    vec3 col;
    if (sp.y > NK_BAR) {
        // the brick wall, litGain by every tube near it
        vec2 g = sp * vec2(4.2, 9.0);
        float row = floor(g.y);
        g.x += 0.5 * mod(row, 2.0);
        vec2 f = fract(g);
        vec2 cell = floor(g);
        float mortar = smoothstep(0.0, 0.07, f.x) * smoothstep(1.0, 0.93, f.x) * smoothstep(0.0, 0.12, f.y) * smoothstep(1.0, 0.88, f.y);
        float tone = 0.6 + 0.4 * hash21(cell) + 0.15 * (vnoise(sp * 40.0) - 0.5);
        float wall = mix(0.25, tone, mortar);
        vec3 spill = pink * exp(-max(bodyD, 0.0) * NK_SC * 5.0) * 0.5 * strike * litGain * near
            + red * exp(-max(lipsD, 0.0) * 5.0) * 0.35 * lipsOn
            + gold * exp(-max(heartD, 0.0) * 6.0) * 0.2 * heartOn * litGain;
        col = (vec3(0.012, 0.008, 0.01) + spill * 0.22) * wall;

        // the tubes, unlit glass first
        col += pink * exp(-abs(ghostD) / 0.006) * 0.025 + pink * exp(-abs(bodyD) / 0.006) * 0.02;
        col += nkTube(ghostD, 0.011, px, pink, fade * 0.3 * litGain);
        col += nkTube(bodyD, 0.011, px, pink, strike * litGain);
        float lpx = 2.0 / u.resolution.y;
        col += nkTube(lipsD, 0.008, lpx, red, lipsOn);
        col += nkTube(mouth, 0.007, lpx, red, lipsOn);
        col += nkTube(heartD, 0.007, lpx, gold, heartOn * litGain);
    } else {
        // the bar top: black lacquer that mirrors the sign, softer the nearer it comes
        float depth = NK_BAR - sp.y;
        vec2 r = vec2(sp.x + 0.004 * sin(sp.y * 90.0 + u.time), 2.0 * NK_BAR - sp.y);
        vec2 rp = (r - NK_FOOT) / NK_SC;
        float rb = 1.0;
        float rnear = smoothstep(1.0, 0.75, abs(rp.x)) * smoothstep(-0.4, -0.25, rp.y) * smoothstep(2.3, 2.1, rp.y);
        if (rp.y > -0.4 && rp.y < 2.3 && abs(rp.x) < 1.0) rb = nkBody(rp, P);
        float rm;
        float rl = nkLips((r - NK_LIPS) / NK_LS, pk, rm) * NK_LS;
        float blur = 1.0 + depth * 4.0;
        float fres = 0.18 + 0.5 * exp(-depth * 5.0);
        vec3 refl = nkTube(rb, 0.011 * blur, px * blur, pink, strike * litGain * rnear)
            + nkTube(rl, 0.008 * blur, 2.0 * blur / u.resolution.y, red, lipsOn);
        col = vec3(0.006, 0.004, 0.006) + refl * fres / blur;
        // the bar's rounded near edge catches the light
        col += mix(pink, red, 0.5) * exp(-depth * 140.0) * 0.12 * litGain;
    }

    // the bar's lights out of focus in front of it all, swelling on the highs
    if (detail > 0.2) {
        float swell = 0.6 + 0.8 * saturate(u.treble * 1.5 + u.mid * 0.5);
        for (int i = 0; i < 9; i++) {
            float fi = float(i);
            vec2 c = vec2(hash11(fi * 3.7 + 0.2) * 3.6 - 1.8, hash11(fi * 5.1 + 0.9) * 1.6 - 0.95);
            c += 0.04 * vec2(sin(u.time * 0.21 + fi), cos(u.time * 0.17 + fi * 1.3));
            float rad = 0.08 + 0.12 * hash11(fi * 7.9 + 0.4);
            float dd = length(sp - c) / rad;
            float disc = saturate((1.0 - dd) * rad * u.resolution.y * 0.25);
            float edge = 0.7 + 0.3 * smoothstep(0.6, 1.0, dd);
            vec3 bc = palVisual(hash11(fi * 2.3 + 0.7), u);
            col += bc * disc * edge * 0.035 * swell * bokehAmt;
        }
    }

    col *= 1.0 - 0.5 * smoothstep(0.7, 1.9, length(sp * vec2(0.85, 1.0)));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    return max(col, 0.0); // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
