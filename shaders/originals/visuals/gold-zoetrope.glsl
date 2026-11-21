// SPDX-License-Identifier: AGPL-3.0-only
// Gold Zoetrope.
// A black lacquer zoetrope drum turning slowly under a warm light, seen from a
// little above. Round the inside of the far wall stand gold art-deco reliefs
// of a nude woman, one in each panel in front of a gold sunburst; nothing is
// drawn of her but her raised outline, rounded and polished, with a line
// engraved just inside it. Each relief steps on to its next frame every half
// beat, as the eye sees a zoetrope through its slits: she sways her hips over
// two beats, dips into each one and every eight beats changes moves and may
// turn. In alternate blocks of eight beats the dancers move in unison or in
// canon, each half a beat behind the one before. Her legs show through the
// slits in the near wall, the light flickers softly with each frame like a
// shutter, the gold flares on the kick, and the panels change hue every
// eight beats.
// param0 = Glow ; param1 = Sway ; param2 = Deco

const float ZT_R = 1.3;      // the drum's radius, across the screen
const float ZT_K = 0.3;      // how far its circle is squashed seen from above
const float ZT_H = 0.85;     // the wall's height
const float ZT_Y0 = -0.42;   // the centre of the drum's base
const float ZT_N = 12.0;     // panels and slits round the drum
const float ZT_FIG = 0.38;   // a relief's height on the wall, per unit of her

// Tapered capsule from a (radius ra) to b (radius rb).
float ztCapsule(vec2 p, vec2 a, vec2 b, float ra, float rb) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * h) - mix(ra, rb, h);
}

float ztEllipse(vec2 p, vec2 c, vec2 r) {
    vec2 q = (p - c) / r;
    return (length(q) - 1.0) * min(r.x, r.y);
}

// The middle joint of a two-bone limb from a to c, bent toward side `bend`.
vec2 ztJoint(vec2 a, vec2 c, float l1, float l2, vec2 bend) {
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
const float ZT_KY[6] = float[6](0.78, 0.92, 1.08, 1.24, 1.375, 1.5);

float ztOutline(float y, vec3 lo, vec3 hi) {
    float w = lo.x;
    w = mix(w, lo.y, smoothstep(ZT_KY[0], ZT_KY[1], y));
    w = mix(w, lo.z, smoothstep(ZT_KY[1], ZT_KY[2], y));
    w = mix(w, hi.x, smoothstep(ZT_KY[2], ZT_KY[3], y));
    w = mix(w, hi.y, smoothstep(ZT_KY[3], ZT_KY[4], y));
    // the shoulder rounds over and slopes into the neck instead of stepping in
    float x = saturate((y - ZT_KY[4]) / (ZT_KY[5] - ZT_KY[4]));
    return mix(w, hi.z, 1.0 - (1.0 - x) * (1.0 - x));
}

// Her figure for this frame: joints and outline, solved for each pixel.
struct ZtPose {
    vec2 hip; vec2 chest; vec2 head; float dy;
    vec3 rLo; vec3 rHi; vec3 lLo; vec3 lHi;   // outline half-widths, right and left
    vec2 hj0; vec2 knee0; vec2 ankle0; vec2 toe0;
    vec2 hj1; vec2 knee1; vec2 ankle1; vec2 toe1;
    vec2 sh0; vec2 el0; vec2 ha0; vec2 sh1; vec2 el1; vec2 ha1;
    float turn; float facing; float lag;
};

// Where a hand goes for move `pose` (side -1 left, +1 right; t in beats).
vec2 ztHand(int pose, float side, float t, vec2 hip, vec2 chest, vec2 head) {
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

// Her figure at time t in beats, with sway amount amt and the beat and downbeat pulses.
ZtPose ztPose(float t, float amt, float beat, float downbeat) {
    ZtPose P;

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
    P.dy = 0.03 * amt * (0.5 + 0.5 * cos(6.2831853 * t)) + 0.03 * beat * amt;
    P.hip = vec2(hx, 0.93 - P.dy);
    P.chest = vec2(-0.45 * 0.08 * amt * sign(cl) * pow(abs(cl), 0.7) * (1.0 - 0.4 * P.turn), 1.30 - 0.85 * P.dy);
    P.head = P.chest + vec2(-0.3 * hx + 0.02 * P.facing * P.turn, 0.29);
    P.lag = 0.08 * amt * sin(1.5707963 * (t - 0.6)) + 0.05 * downbeat * P.facing;

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
        vec2 knee = mix(mix(hj, ankle, 0.51), ztJoint(hj, ankle, 0.4, 0.375, bend), mix(0.3, 1.0, P.turn));
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
        vec2 hand = mix(ztHand(poseB, s, t, P.hip, P.chest, P.head), ztHand(poseA, s, t, P.hip, P.chest, P.head), w);
        vec2 elbow = ztJoint(sh, hand, 0.28, 0.25, vec2(s, -0.35));
        vec2 dir = normalize(hand - elbow + vec2(0.0, 1e-4));
        if (k == 0) { P.sh0 = sh; P.el0 = elbow; P.ha0 = hand + dir * 0.085; }
        else { P.sh1 = sh; P.el1 = elbow; P.ha1 = hand + dir * 0.085; }
    }
    return P;
}

// A limb from a to b whose radius follows a muscle profile, one per side: x at a, y at b,
// plus a swell of z centred at w along it. `outer` points to the outer side.
float ztLimb(vec2 p, vec2 a, vec2 b, vec4 rOut, vec4 rIn, vec2 outer) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    vec2 q = pa - ba * h;
    vec2 n = vec2(-ba.y, ba.x);
    vec4 r = (dot(q, n) * dot(n, outer) >= 0.0) ? rOut : rIn;
    float g = saturate(1.0 - (h - r.w) * (h - r.w) * 8.0);
    return length(q) - (mix(r.x, r.y, h) + r.z * g * g);
}

// Her signed distance at p (local units, feet at y = 0).
float ztBody(vec2 p, ZtPose P) {
    // torso: the outline about a centre line that bends from the hips to the chest
    float xc = mix(P.hip.x, P.chest.x, smoothstep(0.9, 1.34, p.y + P.dy));
    float yy = p.y + P.dy;
    float dx = p.x - xc;
    float hw = (dx > 0.0) ? ztOutline(yy, P.rLo, P.rHi) : ztOutline(yy, P.lLo, P.lHi);
    float d = max(abs(dx) - hw, max(ZT_KY[0] - yy, yy - ZT_KY[5])) * 0.85;

    // neck and head, with a nose, lips and chin as she turns
    vec2 neckBase = vec2(P.chest.x, 1.43 - 0.85 * P.dy);
    d = osSmin(d, ztCapsule(p, neckBase, P.head - vec2(0.0, 0.06), 0.034, 0.028), 0.03);
    d = min(d, ztEllipse(p, P.head + vec2(0.006 * P.facing * P.turn, 0.0), vec2(0.068, 0.094)));
    vec2 f = vec2(P.facing, 1.0);
    float face = ztCapsule(p, P.head + f * vec2(0.055, 0.005), P.head + f * vec2(0.081, -0.024), 0.011, 0.007);
    face = min(face, ztEllipse(p, P.head + f * vec2(0.064, -0.05), vec2(0.013, 0.01)));
    face = min(face, ztEllipse(p, P.head + f * vec2(0.05, -0.076), vec2(0.018, 0.015)));
    d = osSmin(d, face + 0.03 * (1.0 - P.turn / 0.75), 0.008);

    // long hair: full at the crown, falling in waves past the shoulders and swinging late,
    // its edge broken into locks
    vec2 crown = P.head + vec2(-0.012 * P.facing * P.turn, 0.022);
    float hair = ztEllipse(p, crown, vec2(0.092, 0.112));
    vec2 sway = vec2(-1.3 * P.lag, 0.0);
    for (int k = 0; k < 2; k++) {
        float s = (k == 0) ? -1.0 : 1.0;
        vec2 a = P.head + vec2(s * 0.062, 0.0);
        vec2 b = P.head + vec2(s * (0.1 + 0.02 * P.lag * s), -0.36) + sway * (1.0 + 0.3 * s);
        float h = saturate(dot(p - a, b - a) / dot(b - a, b - a));
        float wave = 0.012 * sin(h * 14.0 + 2.0 * s + 4.0 * P.lag);
        hair = osSmin(hair, ztCapsule(p - vec2(wave, 0.0), a, b, 0.05, 0.03), 0.04);
    }
    vec2 tail = P.head + vec2(-P.lag * 1.2 - 0.07 * P.facing, -0.4);
    float backHair = ztLimb(p, P.head + vec2(-0.03 * P.facing, 0.03), tail, vec4(0.09, 0.035, 0.018, 0.45), vec4(0.085, 0.03, 0.01, 0.5), vec2(-P.facing, 0.0));
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
        float thigh = ztLimb(p, hj + vec2(0.0, 0.03), kn, vec4(0.098, 0.05, 0.014, 0.28), vec4(0.088, 0.045, 0.006, 0.2), out2);
        float calf = ztLimb(p, kn, an, vec4(0.047, 0.022, 0.017, 0.3), vec4(0.046, 0.022, 0.012, 0.26), out2);
        float leg = osSmin(thigh, calf, 0.03);
        float foot = ztLimb(p, an, to, vec4(0.024, 0.012, 0.004, 0.3), vec4(0.022, 0.011, 0.0, 0.3), vec2(0.0, 1.0));
        vec2 heel = vec2(-P.facing * 0.03, -0.1) * P.turn;
        foot = min(foot, ztCapsule(p, an, an + heel, 0.012, 0.005));
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
        float up = ztLimb(p, sh, el, vec4(0.05, 0.03, 0.01, 0.12), vec4(0.038, 0.03, 0.004, 0.4), out2);
        float fore = ztLimb(p, el, wr, vec4(0.031, 0.018, 0.007, 0.25), vec4(0.03, 0.018, 0.005, 0.3), out2);
        float hand = ztLimb(p, wr, ha, vec4(0.019, 0.008, 0.007, 0.35), vec4(0.019, 0.008, 0.005, 0.35), out2);
        arms = min(arms, osSmin(osSmin(up, fore, 0.02), hand, 0.01));
    }
    d = osSmin(d, arms, 0.035);

    return d;
}

// What the reliefs need from the frame, worked out once.
struct ZtScene {
    float rot;      // the drum's turn, in panels
    float frame;    // the beat the reliefs are on, stepping each half beat
    float canon;    // 0 in unison, 1 in canon
    float amt;
    vec3 gold; vec3 tint; vec3 deep;
    float pump; float deco; float res;
};

// The far wall's inside at drum angle th and height v (0 at its foot, 1 at its rim):
// a gold relief of her in each panel, before a sunburst on black lacquer.
vec3 ztWall(float th, float v, ZtScene Z) {
    float a = th * ZT_N / 6.2831853 + Z.rot;
    float slot = floor(a);
    float fa = fract(a) - 0.5;
    float pw = 6.2831853 * ZT_R / ZT_N;
    vec2 p = vec2(fa * pw, v * ZT_H - 0.04) / ZT_FIG;

    // the panel: lacquer, a sunburst behind her, gold borders and bands
    vec2 q = p - vec2(0.0, 1.15);
    float rays = smoothstep(0.18, 0.28, abs(fract(atan2_(q.x, q.y + 1e-6) * 2.5464791) - 0.5));
    float sun = rays * (1.0 - smoothstep(0.2, 1.25, length(q))) * Z.deco;
    vec3 col = Z.deep * 0.012 + Z.tint * sun * 0.05 * Z.pump;
    float edge = 1.0 - smoothstep(0.008, 0.016, 0.5 - abs(fa));
    float zig = abs(fract(a * 4.0) - 0.5);
    float band = 1.0 - smoothstep(0.0, 0.006, abs(v - 0.935 + 0.03 * zig));
    band = max(band, step(0.975, v) + step(v, 0.02));
    col += Z.gold * max(edge, band) * 0.12 * Z.pump;

    if (p.y > -0.1 && p.y < 2.15 && abs(p.x) < 0.7) {
        // her frame: in canon each panel is half a beat behind the one before
        float tf = Z.frame - Z.canon * mod(slot, ZT_N) * 0.5;
        // the beat and downbeat pulses held at her frame, so a relief only moves as it steps
        float bp = exp(-fract(tf) * 4.0);
        ZtPose P = ztPose(tf, Z.amt, bp, bp * step(mod(floor(tf), 4.0), 0.5));
        float d = ztBody(p, P);
        // one pixel in her units, wider toward the drum's sides where the wall turns away
        float px = 2.0 / (Z.res * ZT_FIG * max(sin(th), 0.25));
        // the lacquer darkens in the hollow round the relief
        col *= 1.0 - 0.6 * exp(-max(d, 0.0) / 0.03);
        float fill = saturate(0.5 - d / px);
        if (fill > 0.0) {
            float e = 0.006;
            vec2 n2 = normalize(vec2(ztBody(p + vec2(e, 0.0), P) - d, ztBody(p + vec2(0.0, e), P) - d) + vec2(0.0, 1e-5));
            // a low relief: the gold rounds over at her outline and is flatter inside it
            float lat = saturate(1.0 + d / 0.09) * 0.85;
            vec3 n = vec3(n2 * lat, sqrt(max(1.0 - lat * lat, 0.0)));
            vec3 L = normalize(vec3(-0.45, 0.65, 0.6));
            float diff = saturate(dot(n, L));
            float spec = saturate(dot(reflect(-L, n), vec3(0.0, 0.0, 1.0)));
            spec *= spec; spec *= spec; spec *= spec;
            vec3 body = Z.gold * (0.05 + 0.45 * diff) * Z.pump + mix(Z.gold, vec3(1.0), 0.45) * spec * 0.7 * Z.pump;
            // the line engraved just inside her outline
            float cut = 1.0 - smoothstep(0.5 * px, 1.5 * px, abs(d + 0.022));
            body *= 1.0 - 0.75 * cut;
            col = mix(col, body, fill);
        }
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
    float detail = osDetail(u);

    ZtScene Z;
    Z.rot = t / 8.0;
    Z.frame = floor(t * 2.0) * 0.5;
    float block = floor(t / 8.0);
    float ease = smoothstep(0.0, 1.0, t - block * 8.0);
    // unison or canon switches with the block, so every relief stays on a half-beat frame
    Z.canon = mod(block, 2.0);
    Z.amt = 0.6 + 0.9 * u.param1;
    Z.gold = palVisual(0.78, u);
    Z.tint = mix(palVisual(fract(0.3 + 0.382 * (block - 1.0)), u), palVisual(fract(0.3 + 0.382 * block), u), ease);
    Z.deep = palVisual(0.1, u);
    // the light dips softly as each frame steps on, like a shutter, and flares on the kick
    float flick = 1.0 - 0.15 * exp(-fract(t * 2.0) * 8.0);
    Z.pump = (0.55 + 0.6 * kick) * glow * flick;
    Z.deco = 0.4 + 1.2 * u.param2;
    Z.res = u.resolution.y;
    float kR = ZT_K * ZT_R;

    // the room: dark, warm behind the drum, a pool of light on the table beneath it
    vec3 col = Z.deep * 0.01 + Z.gold * 0.05 * glow * exp(-length((sp - vec2(0.0, 0.1)) * vec2(0.6, 1.0)) * 2.0);
    float table = ZT_Y0 - kR - 0.2;
    if (sp.y < table) {
        col = Z.deep * 0.008 + Z.gold * 0.06 * glow * exp(-length((sp - vec2(0.0, table - 0.15)) * vec2(0.7, 3.0)) * 2.0);
    }
    // the spindle the drum turns on
    float post = 1.0 - smoothstep(0.035, 0.045, abs(sp.x));
    if (sp.y < ZT_Y0 - kR && sp.y > table - 0.2) {
        col = mix(col, Z.gold * (0.12 + 0.25 * saturate(1.0 - sp.x / 0.04)) * Z.pump, post);
    }

    float x = sp.x / ZT_R;
    if (abs(x) < 1.0) {
        float thF = acos(x);
        float s = sin(thF);
        // the far wall, seen over the near wall's rim and through its slits
        float vF = (sp.y - (ZT_Y0 + kR * s)) / ZT_H;
        // the near wall in front, worked out first so the far wall is skipped where it hides it
        float vN = (sp.y - (ZT_Y0 - kR * s)) / ZT_H;
        float a = -thF * ZT_N / 6.2831853 + Z.rot + 0.5;
        float fa = fract(a) - 0.5;
        float slit = (1.0 - smoothstep(0.075, 0.085, abs(fa))) * step(0.45, vN) * step(vN, 0.93);
        bool nearWall = vN >= 0.0 && vN <= 1.0;
        vec3 inside = Z.deep * 0.01;
        if (vF >= 0.0 && vF <= 1.0) {
            if (!nearWall || slit > 0.0) inside = ztWall(thF, vF, Z);
        } else if (vF < 0.0) {
            // the drum's floor, catching a little light
            inside = Z.gold * 0.025 * glow * (0.6 + 0.4 * saturate(1.0 + vF * 3.0));
        }
        if (vF <= 1.0 && sp.y > ZT_Y0 - kR * s) col = inside;
        // the far rim catching the light
        col += Z.gold * 0.3 * Z.pump * exp(-abs(vF - 1.0) * ZT_H * u.resolution.y * 0.35) * s;

        // the near wall: black lacquer, gold at its rims and in a zigzag band, slits up high
        if (nearWall) {
            // the lacquer: a broad highlight where the curve faces the light
            float sheen = exp(-(x + 0.35) * (x + 0.35) * 16.0);
            vec3 wall = Z.deep * 0.008 + mix(Z.gold, vec3(1.0), 0.6) * sheen * 0.035 * glow * s;
            float zig = abs(fract(a * 4.0) - 0.5);
            float band = 1.0 - smoothstep(0.004, 0.009, abs(vN - 0.22 + 0.1 * zig));
            band = max(band, step(0.965, vN) + step(vN, 0.03));
            band = max(band, (1.0 - smoothstep(0.004, 0.009, abs(abs(fa) - 0.1))) * step(0.43, vN) * step(vN, 0.95));
            wall += Z.gold * band * (0.15 + 0.25 * sheen) * Z.pump * mix(0.6, 1.0, saturate(Z.deco)) * (0.4 + 0.6 * s);
            col = mix(wall, col, slit);
            if (detail > 0.3) col *= 1.0 - 0.3 * slit * (1.0 - s);
        }
    }

    col *= 1.0 - 0.5 * smoothstep(0.9, 1.9, length(sp * vec2(0.8, 1.0)));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    return max(col, 0.0); // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
