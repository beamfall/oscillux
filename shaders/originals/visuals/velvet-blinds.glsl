// SPDX-License-Identifier: AGPL-3.0-only
// Velvet Blinds.
// Late night, one nude woman dancing alone in a room lit only through venetian
// blinds, seen as a silhouette: the light falls across her and the velvet
// curtain behind her in slanted bars that bend round her curves, a warm rim
// and a cool one trace her outline, and her shadow follows her across the
// folds. Nothing is drawn inside the outline but light and shade.
// She sways her hips slowly, side to side over two beats, dipping
// into every beat with the shoulders rolling after the hips; every eight beats
// she changes moves (both hands up through her hair, one hand in her hair and
// one on her hip, arms low and loose, wrists crossed overhead) and may
// turn three-quarters to the light. Her hair swings behind the sway and whips
// round on the bar. The slats tilt open and closed on the bar and flare open
// on the downbeat, the bars of light pump on the kick, and smoke drifts
// through the beams with dust glinting in them on the highs. Every eight beats
// the light changes hue along the palette and the slats change what they do:
// only tilt, alternate two hues, carry a bright band sweeping across and back,
// wash one hue down into the other, or scroll as the blinds rise or drop.
// param0 = Glow ; param1 = Sway ; param2 = Smoke

const float VB_SC = 0.98;              // her height on screen, in half-frame heights per unit
const vec2 VB_FOOT = vec2(0.18, -0.93);
const float VB_WALL = -0.72;           // where the curtain meets the floor
const vec2 VB_BEAM = vec2(0.34, 0.94); // across the bars of light
const vec3 VB_L = vec3(-0.8, 0.45, 0.45);

// Tapered capsule from a (radius ra) to b (radius rb).
float vbCapsule(vec2 p, vec2 a, vec2 b, float ra, float rb) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * h) - mix(ra, rb, h);
}

float vbEllipse(vec2 p, vec2 c, vec2 r) {
    vec2 q = (p - c) / r;
    return (length(q) - 1.0) * min(r.x, r.y);
}

// The middle joint of a two-bone limb from a to c, bent toward side `bend`.
vec2 vbJoint(vec2 a, vec2 c, float l1, float l2, vec2 bend) {
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
const float VB_KY[6] = float[6](0.78, 0.92, 1.08, 1.24, 1.375, 1.5);

float vbOutline(float y, vec3 lo, vec3 hi) {
    float w = lo.x;
    w = mix(w, lo.y, smoothstep(VB_KY[0], VB_KY[1], y));
    w = mix(w, lo.z, smoothstep(VB_KY[1], VB_KY[2], y));
    w = mix(w, hi.x, smoothstep(VB_KY[2], VB_KY[3], y));
    w = mix(w, hi.y, smoothstep(VB_KY[3], VB_KY[4], y));
    // the shoulder rounds over and slopes into the neck instead of stepping in
    float x = saturate((y - VB_KY[4]) / (VB_KY[5] - VB_KY[4]));
    return mix(w, hi.z, 1.0 - (1.0 - x) * (1.0 - x));
}

// Her figure for this frame: joints and outline, solved for each pixel.
struct VbPose {
    vec2 hip; vec2 chest; vec2 head; float dy;
    vec3 rLo; vec3 rHi; vec3 lLo; vec3 lHi;   // outline half-widths, right and left
    vec2 hj0; vec2 knee0; vec2 ankle0; vec2 toe0;
    vec2 hj1; vec2 knee1; vec2 ankle1; vec2 toe1;
    vec2 sh0; vec2 el0; vec2 ha0; vec2 sh1; vec2 el1; vec2 ha1;
    float turn; float facing; float lag;
};

// Where a hand goes for move `pose` (side -1 left, +1 right; t in beats).
vec2 vbHand(int pose, float side, float t, vec2 hip, vec2 chest, vec2 head) {
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

VbPose vbPose(VisualUniforms u) {
    VbPose P;
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
        vec2 knee = mix(mix(hj, ankle, 0.51), vbJoint(hj, ankle, 0.4, 0.375, bend), mix(0.3, 1.0, P.turn));
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
        vec2 hand = mix(vbHand(poseB, s, t, P.hip, P.chest, P.head), vbHand(poseA, s, t, P.hip, P.chest, P.head), w);
        vec2 elbow = vbJoint(sh, hand, 0.28, 0.25, vec2(s, -0.35));
        vec2 dir = normalize(hand - elbow + vec2(0.0, 1e-4));
        if (k == 0) { P.sh0 = sh; P.el0 = elbow; P.ha0 = hand + dir * 0.085; }
        else { P.sh1 = sh; P.el1 = elbow; P.ha1 = hand + dir * 0.085; }
    }
    return P;
}

// A limb from a to b whose radius follows a muscle profile, one per side: x at a, y at b,
// plus a swell of z centred at w along it. `outer` points to the outer side.
float vbLimb(vec2 p, vec2 a, vec2 b, vec4 rOut, vec4 rIn, vec2 outer) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    vec2 q = pa - ba * h;
    vec2 n = vec2(-ba.y, ba.x);
    vec4 r = (dot(q, n) * dot(n, outer) >= 0.0) ? rOut : rIn;
    float g = saturate(1.0 - (h - r.w) * (h - r.w) * 8.0);
    return length(q) - (mix(r.x, r.y, h) + r.z * g * g);
}

// Her signed distance at p (local units, feet at y = 0).
float vbBody(vec2 p, VbPose P) {
    // torso: the outline about a centre line that bends from the hips to the chest
    float xc = mix(P.hip.x, P.chest.x, smoothstep(0.9, 1.34, p.y + P.dy));
    float yy = p.y + P.dy;
    float dx = p.x - xc;
    float hw = (dx > 0.0) ? vbOutline(yy, P.rLo, P.rHi) : vbOutline(yy, P.lLo, P.lHi);
    float d = max(abs(dx) - hw, max(VB_KY[0] - yy, yy - VB_KY[5])) * 0.85;

    // neck and head, with a nose, lips and chin as she turns
    vec2 neckBase = vec2(P.chest.x, 1.43 - 0.85 * P.dy);
    d = osSmin(d, vbCapsule(p, neckBase, P.head - vec2(0.0, 0.06), 0.034, 0.028), 0.03);
    d = min(d, vbEllipse(p, P.head + vec2(0.006 * P.facing * P.turn, 0.0), vec2(0.068, 0.094)));
    vec2 f = vec2(P.facing, 1.0);
    float face = vbCapsule(p, P.head + f * vec2(0.055, 0.005), P.head + f * vec2(0.081, -0.024), 0.011, 0.007);
    face = min(face, vbEllipse(p, P.head + f * vec2(0.064, -0.05), vec2(0.013, 0.01)));
    face = min(face, vbEllipse(p, P.head + f * vec2(0.05, -0.076), vec2(0.018, 0.015)));
    d = osSmin(d, face + 0.03 * (1.0 - P.turn / 0.75), 0.008);

    // long hair: full at the crown, falling in waves past the shoulders and swinging late,
    // its edge broken into locks
    vec2 crown = P.head + vec2(-0.012 * P.facing * P.turn, 0.022);
    float hair = vbEllipse(p, crown, vec2(0.092, 0.112));
    vec2 sway = vec2(-1.3 * P.lag, 0.0);
    for (int k = 0; k < 2; k++) {
        float s = (k == 0) ? -1.0 : 1.0;
        vec2 a = P.head + vec2(s * 0.062, 0.0);
        vec2 b = P.head + vec2(s * (0.1 + 0.02 * P.lag * s), -0.36) + sway * (1.0 + 0.3 * s);
        float h = saturate(dot(p - a, b - a) / dot(b - a, b - a));
        float wave = 0.012 * sin(h * 14.0 + 2.0 * s + 4.0 * P.lag);
        hair = osSmin(hair, vbCapsule(p - vec2(wave, 0.0), a, b, 0.05, 0.03), 0.04);
    }
    vec2 tail = P.head + vec2(-P.lag * 1.2 - 0.07 * P.facing, -0.4);
    float backHair = vbLimb(p, P.head + vec2(-0.03 * P.facing, 0.03), tail, vec4(0.09, 0.035, 0.018, 0.45), vec4(0.085, 0.03, 0.01, 0.5), vec2(-P.facing, 0.0));
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
        float thigh = vbLimb(p, hj + vec2(0.0, 0.03), kn, vec4(0.098, 0.05, 0.014, 0.28), vec4(0.088, 0.045, 0.006, 0.2), out2);
        float calf = vbLimb(p, kn, an, vec4(0.047, 0.022, 0.017, 0.3), vec4(0.046, 0.022, 0.012, 0.26), out2);
        float leg = osSmin(thigh, calf, 0.03);
        float foot = vbLimb(p, an, to, vec4(0.024, 0.012, 0.004, 0.3), vec4(0.022, 0.011, 0.0, 0.3), vec2(0.0, 1.0));
        vec2 heel = vec2(-P.facing * 0.03, -0.1) * P.turn;
        foot = min(foot, vbCapsule(p, an, an + heel, 0.012, 0.005));
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
        float up = vbLimb(p, sh, el, vec4(0.05, 0.03, 0.01, 0.12), vec4(0.038, 0.03, 0.004, 0.4), out2);
        float fore = vbLimb(p, el, wr, vec4(0.031, 0.018, 0.007, 0.25), vec4(0.03, 0.018, 0.005, 0.3), out2);
        float hand = vbLimb(p, wr, ha, vec4(0.019, 0.008, 0.007, 0.35), vec4(0.019, 0.008, 0.005, 0.35), out2);
        arms = min(arms, osSmin(osSmin(up, fore, 0.02), hand, 0.01));
    }
    d = osSmin(d, arms, 0.035);

    return d;
}

// The bars of light thrown through the slats: 1 in a bar, 0 between, softer far from the window.
float vbBars(float s, float open, float soft) {
    return smoothstep(-soft, soft, 0.5 * open - abs(fract(s) - 0.5));
}

// A palette colour brought to one brightness, so the room is as bright in blue as in gold.
vec3 vbEven(vec3 c) {
    return c * clamp(0.3 / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-3), 0.5, 2.5);
}

// A look: the hues the light takes and what the slats do, held for eight beats. Every
// look has a new hue; in turn the slats only tilt, alternate two hues, carry a bright
// band sweeping across them, wash one hue down into the other, or scroll as the blinds
// rise or drop.
struct VbLook {
    vec3 hot, hot2, warm, cool;
    float sweep, scroll, two, wash;
};

VbLook vbLook(float k, VisualUniforms u) {
    VbLook L;
    float h = fract(0.3 + 0.382 * k);
    L.hot = vbEven(palVisual(h, u));
    L.hot2 = vbEven(palVisual(fract(h + 0.4), u));
    L.warm = palVisual(fract(h + 0.2), u);
    L.cool = palVisual(fract(h + 0.58), u);
    float m = mod(k * 3.0, 5.0);
    L.sweep = step(abs(m - 1.0), 0.5);
    L.scroll = step(abs(m - 2.0), 0.5) * (hash11(k * 4.1 + 0.6) < 0.5 ? -1.0 : 1.0);
    L.two = step(abs(m - 3.0), 0.5);
    L.wash = step(abs(m - 4.0), 0.5);
    return L;
}

// The colour of the bar at slat coordinate s: alternate slats take the second hue, or
// the second hue rolls down the slats a quarter turn a beat.
vec3 vbTint(float s, float t, vec3 hot, vec3 hot2, float two, float wash) {
    float n = floor(s);
    float k = two * mod(n, 2.0) + wash * (0.5 + 0.5 * sin(n * 0.8 - t * 1.5708));
    return mix(hot, hot2, saturate(k));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 sp = centered(uv, u.resolution);
    sp.y = -sp.y;
    float t = u.beatCount + saturate(u.beatPhase);
    float ph = saturate(u.beatPhase);
    float kick = exp(-ph * 3.0) * (0.45 + 0.55 * saturate(u.bassImpact + u.bass * 0.5));
    float glow = 0.5 + u.param0;
    float smoke = 0.3 + 1.2 * u.param2;
    float detail = osDetail(u);

    // the look changes every eight beats, easing in over the first beat and a half
    float bar = floor(u.beatCount / 4.0);
    VbLook LA = vbLook(floor(t / 8.0) - 1.0, u), LB = vbLook(floor(t / 8.0), u);
    float lf = smoothstep(0.0, 1.5, mod(t, 8.0));
    vec3 hot = mix(LA.hot, LB.hot, lf);
    vec3 hot2 = mix(LA.hot2, LB.hot2, lf);
    vec3 warm = mix(LA.warm, LB.warm, lf);
    vec3 cool = mix(LA.cool, LB.cool, lf);
    vec3 deep = palVisual(0.1, u);
    float two = mix(LA.two, LB.two, lf), wash = mix(LA.wash, LB.wash, lf);
    // the scroll covers two whole slats a look, so it is back in step when the look ends
    float roll = mix(LA.scroll, LB.scroll, lf) * 0.25 * mod(t, 8.0);

    // the slats tilt to a new angle on each bar and flare open on the downbeat
    float tiltA = hash11(bar * 1.93 + 0.4), tiltB = hash11((bar - 1.0) * 1.93 + 0.4);
    float tilt = mix(tiltB, tiltA, smoothstep(0.0, 1.0, mod(t, 4.0)));
    float open = mix(0.2, 0.45, tilt) + 0.07 * kick + 0.12 * u.downbeat * exp(-ph * 2.0);
    float pump = (0.35 + 1.7 * kick) * glow;

    // where the window's light lands: a slanted frame with a mullion down it
    float a = sp.x - 0.35 * sp.y;
    float window = smoothstep(-1.35, -1.1, a) * (1.0 - smoothstep(0.55, 0.85, a))
        * (1.0 - 0.9 * exp(-(a + 0.32) * (a + 0.32) / 0.001225));
    // the sweep: a bright band across the window and back, once each way in four beats
    float sx = a + 0.25 - 1.15 * cos(t * 0.7853982);
    window *= 1.0 + mix(LA.sweep, LB.sweep, lf) * (2.4 * exp(-sx * sx / 0.03) - 0.45);
    float freq = 4.2 * (1.0 - 0.08 * sp.x);
    float soft = 0.03 + 0.07 * saturate(sp.x + 0.6);

    // her shadow on the curtain, thrown down and to the right
    VbPose P = vbPose(u);
    vec2 ps = (sp - VB_FOOT - vec2(0.3, 0.02)) / (VB_SC * 1.06);
    ps.x -= 0.18 * ps.y;
    float shadow = 0.0;
    if (ps.y > -0.1 && ps.y < 2.0 && abs(ps.x) < 0.75) shadow = 1.0 - smoothstep(-0.03, 0.05, vbBody(ps, P));

    vec3 col;
    if (sp.y > VB_WALL) {
        // the velvet curtain: deep folds, a sheen at their edges, the bars bending over them
        float fold = sin(sp.x * 9.0 + 1.3 * sin(sp.x * 2.3 + sp.y * 0.7));
        float shade = 0.55 + 0.45 * fold;
        float sheen = pow(1.0 - abs(fold), 3.0);
        float s = dot(sp, VB_BEAM) * freq + 0.03 * fold + roll;
        float light = vbBars(s, open, soft) * window * (1.0 - 0.85 * shadow);
        col = deep * (0.03 + 0.03 * sheen) * shade;
        col += vbTint(s, t, hot, hot2, two, wash) * light * (0.1 + 0.16 * shade + 0.14 * sheen) * pump;
        // the backlight behind her, low on the curtain
        col += warm * 0.06 * exp(-length((sp - vec2(VB_FOOT.x, -0.3)) * vec2(0.8, 1.6))) * glow * (0.6 + kick);
    } else {
        // the floor: dark lacquer, the bars stretched across it toward us
        float z = 1.0 / max(VB_WALL - sp.y + 0.12, 1e-3);
        float s = (sp.x * 0.4 + z * 0.35) * 1.4 + roll;
        float light = vbBars(s, open, soft * 1.5) * window * (1.0 - 0.85 * shadow) * saturate((sp.x + 1.6) * 0.6);
        col = deep * 0.015 + vbTint(s, t, hot, hot2, two, wash) * light * 0.14 * pump * exp(-(VB_WALL - sp.y) * 1.2);
        col = mix(col, deep * 0.05, exp(-(VB_WALL - sp.y) * 7.0));
    }

    // her
    vec2 p = (sp - VB_FOOT) / VB_SC;
    if (p.y > -0.1 && p.y < 2.15 && abs(p.x) < 0.7) {
        float d = vbBody(p, P);
        // one pixel in her units; edges are filled from it, not from fwidth, which the
        // branches above leave undefined
        float px = 2.0 / (u.resolution.y * VB_SC);
        col += warm * exp(-max(d, 0.0) * 30.0) * 0.03 * glow * (0.5 + kick);
        float fill = saturate(0.5 - d / px);
        if (fill > 0.0) {
            float e = 0.006;
            vec2 n2 = normalize(vec2(vbBody(p + vec2(e, 0.0), P) - d, vbBody(p + vec2(0.0, e), P) - d) + vec2(0.0, 1e-5));
            // round her out: the normal turns toward us away from the outline
            float lat = saturate(1.0 + d / 0.12);
            vec3 n = vec3(n2 * lat, sqrt(max(1.0 - lat * lat, 0.0)));
            vec3 L = normalize(VB_L);
            float diff = saturate(dot(n, L));
            // the bars land on her nearer the window and curve round her
            float s = dot(sp, VB_BEAM) * freq + 0.3 + 0.15 * n.z + roll;
            float light = vbBars(s, open, 0.09) * window;
            float spec = saturate(dot(reflect(-L, n), vec3(0.0, 0.0, 1.0)));
            spec *= spec; spec *= spec; spec *= spec;
            // the sheen stays on her curves near the outline; the middle of her is left dark
            spec *= saturate(1.0 + d / 0.05);
            // her skin: a little bounce off the curtain keeps her shape between the bars,
            // which soften as they wrap round her, with a sheen where they cross her curves
            vec3 body = deep * 0.012 + hot * diff * 0.03 * pump
                + vbTint(s, t, hot, hot2, two, wash) * light * (0.08 + 0.92 * diff) * 0.24 * pump
                + warm * light * spec * 0.3 * pump;
            // the rims, a few pixels wide: warm from the backlight on the window side and
            // cool from the room on the other
            float rim = pow(saturate(1.0 + d / (2.5 * px)), 2.0);
            float side = n2.x * -P.facing;
            body += warm * rim * (0.35 + 0.8 * kick) * glow * saturate(0.4 + 0.6 * side + 0.4 * n2.y);
            body += cool * rim * 0.22 * glow * saturate(-side) * (0.6 + 0.4 * u.mid);
            col = mix(col, body, fill);
        }
    }

    // smoke drifting through the beams, dust glinting in them on the highs
    float haze = fbm(sp * 1.8 + vec2(u.time * 0.06, u.time * 0.025)) * smoke;
    float bs = dot(sp, VB_BEAM) * freq + 0.15 + roll;
    float beams = vbBars(bs, open, 0.08) * window;
    col += vbTint(bs, t, hot, hot2, two, wash) * beams * haze * 0.09 * pump * (0.5 + 0.5 * saturate(0.6 - sp.x * 0.3));
    if (detail > 0.25) {
        vec2 g = sp * 55.0 + vec2(u.time * 0.4, -u.time * 0.7);
        vec2 cell = floor(g);
        float mote = exp(-dot(fract(g) - 0.5, fract(g) - 0.5) * 60.0) * step(0.93, hash21(cell));
        float tw = 0.5 + 0.5 * sin(u.time * 7.0 + hash21(cell + 3.1) * 40.0);
        col += mix(warm, vec3(1.0), 0.5) * mote * tw * beams * (0.2 + 1.2 * u.treble) * smoke;
    }

    col *= 1.0 - 0.45 * smoothstep(0.8, 1.9, length(sp * vec2(0.85, 1.0)));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    return max(col, 0.0); // LINEAR HDR — post chain tonemaps
}
