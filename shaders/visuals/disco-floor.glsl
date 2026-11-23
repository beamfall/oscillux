// SPDX-License-Identifier: AGPL-3.0-only
// Catalog copy of the Disco Floor original (shaders/originals/visuals/disco-floor.glsl), with
// the shaders/originals/common.glsl helpers it calls copied ahead of it, so it compiles on the
// catalog prelude alone. The release set and hosts draw the original, which overrides this
// entry; tools that load the catalog by itself draw this copy. test-wrap.mjs checks it.

// Detail the host can afford: 1, the default, down to 0. Hosts lower it with
// presentation1.y, a reduction in [0, 1], to hold their frame rate.
float osDetail(VisualUniforms u) { return 1.0 - saturate(u.presentation1.y); }

// Smooth union with blend radius k.
float osSmin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// ---- vivid palettes ----
// In the hosts' free palette mode (palette.x < 0) the originals read this set
// instead of the library's: sixteen loops of five saturated stops in linear
// light, each a few hue families with a contrasting accent. palette.z tours
// them, cross-fading from one to the next, and also walks t by a quarter loop
// per palette (four whole loops per tour, so the wrap is seamless), so a visual
// that reads only a narrow range of t still meets every stop. Manifest mode
// (palette.x >= 0) keeps the library palettes, so reference renders do not
// change.
const vec3 OS_PAL[80] = vec3[80](
    vec3(1.000, 0.033, 0.133), vec3(1.000, 0.262, 0.010), vec3(1.000, 0.807, 0.010), vec3(0.033, 1.000, 0.262), vec3(0.000, 0.578, 1.000), // 0 tropicPunch
    vec3(0.000, 0.784, 1.000), vec3(0.027, 0.105, 1.000), vec3(0.479, 0.022, 1.000), vec3(1.000, 0.027, 0.309), vec3(1.000, 0.323, 0.014), // 1 synthSunset
    vec3(0.000, 1.000, 0.578), vec3(0.000, 0.392, 1.000), vec3(1.000, 0.078, 0.366), vec3(1.000, 0.434, 0.000), vec3(1.000, 0.102, 0.037), // 2 lagoonPop
    vec3(0.565, 1.000, 0.000), vec3(1.000, 0.791, 0.000), vec3(1.000, 0.195, 0.000), vec3(1.000, 0.000, 0.100), vec3(0.000, 1.000, 0.195), // 3 acidCitrus
    vec3(0.000, 0.871, 1.000), vec3(0.000, 0.133, 1.000), vec3(1.000, 0.047, 0.000), vec3(1.000, 0.552, 0.000), vec3(1.000, 0.000, 0.156), // 4 iceFire
    vec3(0.000, 1.000, 0.332), vec3(0.000, 0.658, 1.000), vec3(0.047, 0.102, 0.991), vec3(1.000, 0.823, 0.000), vec3(0.328, 1.000, 0.000), // 5 electricMint
    vec3(1.000, 0.347, 0.000), vec3(1.000, 0.074, 0.000), vec3(0.791, 0.000, 0.195), vec3(0.144, 0.000, 0.905), vec3(0.000, 0.539, 1.000), // 6 mangoBerry
    vec3(1.000, 0.050, 0.371), vec3(1.000, 0.347, 0.050), vec3(1.000, 0.784, 0.050), vec3(0.050, 1.000, 0.434), vec3(0.050, 0.479, 1.000), // 7 candyShop
    vec3(0.000, 1.000, 0.235), vec3(0.000, 0.745, 0.565), vec3(0.000, 0.296, 1.000), vec3(0.254, 0.024, 1.000), vec3(1.000, 0.028, 0.631), // 8 aurora
    vec3(1.000, 0.014, 0.014), vec3(1.000, 0.144, 0.000), vec3(1.000, 0.479, 0.000), vec3(1.000, 0.791, 0.000), vec3(1.000, 0.000, 0.212), // 9 lavaLamp
    vec3(0.784, 1.000, 0.000), vec3(0.000, 1.000, 0.133), vec3(0.000, 0.694, 1.000), vec3(0.000, 0.080, 1.000), vec3(1.000, 0.434, 0.000), // 10 cyberLime
    vec3(1.000, 0.102, 0.114), vec3(1.000, 0.026, 0.301), vec3(0.397, 0.045, 1.000), vec3(0.026, 0.198, 1.000), vec3(0.000, 0.807, 0.565), // 11 coralReef
    vec3(1.000, 0.631, 0.000), vec3(1.000, 0.254, 0.000), vec3(1.000, 0.044, 0.044), vec3(1.000, 0.195, 0.000), vec3(1.000, 0.871, 0.074), // 12 goldRush
    vec3(0.000, 0.010, 1.000), vec3(0.000, 0.283, 1.000), vec3(0.000, 0.913, 0.658), vec3(0.328, 1.000, 0.000), vec3(1.000, 0.791, 0.000), // 13 deepNeon
    vec3(1.000, 0.195, 0.565), vec3(0.571, 0.205, 1.000), vec3(0.195, 0.392, 1.000), vec3(0.195, 1.000, 0.745), vec3(1.000, 0.871, 0.195), // 14 bubbleTea
    vec3(1.000, 0.000, 0.091), vec3(0.133, 0.000, 1.000), vec3(0.000, 0.451, 1.000), vec3(0.000, 1.000, 0.665), vec3(0.468, 1.000, 0.000) // 15 neonTokyo
);
const float OS_PAL_COUNT = 16.0;

// Linear mix that keeps the endpoints' channel range, so a blend between two
// saturated colours stays saturated instead of passing through grey.
vec3 osVividMix(vec3 a, vec3 b, float w) {
    vec3 m = mix(a, b, w);
    float lo = min(m.r, min(m.g, m.b)), hi = max(m.r, max(m.g, m.b));
    float tlo = mix(min(a.r, min(a.g, a.b)), min(b.r, min(b.g, b.b)), w);
    float thi = mix(max(a.r, max(a.g, a.b)), max(b.r, max(b.g, b.b)), w);
    return tlo + (m - lo) * ((thi - tlo) / max(hi - lo, 1e-3));
}

vec3 osPalLoop(float t, int idx) {
    float f = fract(t) * 5.0;
    int i = int(floor(f));
    i = clamp(i, 0, 4);
    int j = i == 4 ? 0 : i + 1;
    return osVividMix(OS_PAL[idx * 5 + i], OS_PAL[idx * 5 + j], smoothstep(0.0, 1.0, f - float(i)));
}

vec3 osPalVisual(float t, VisualUniforms u) {
    if (u.palette.x >= 0.0) return palVisual(t, u);
    float phase = u.palette.z;
    int a = int(mod(floor(phase), OS_PAL_COUNT));
    int b = int(mod(float(a + 1), OS_PAL_COUNT));
    float blend = smoothstep(0.18, 0.82, fract(phase));
    float nudge = phase * 0.25 + u.beatPhase * 0.015 + u.spectralCentroid * 0.08;
    return osVividMix(osPalLoop(t + nudge, a), osPalLoop(t + nudge, b), blend);
}

// Every original finishes through osOffRed. The present pass grades with the vivid saturation
// and vibrance (palette.rs), which pushes a nearly pure red past the 0.8 red share at which the
// flash limiter counts saturated red and holds it. Where green plus blue is under 0.55 of red
// (linear light), both rise by half the difference, so the graded red presents under a 0.77
// share. Near black the present dither can still split a dim red into a saturated-red byte
// triple such as (1, 0, 0), so a dim colour becomes exactly grey and a dim red loses its excess
// over green and blue, which then ramps back in (limiter-red-expire-black, design.md section 3;
// tools/shader/test-originals-red.mjs). A quality measure: the frame limiter carries the safety
// claim. NaN becomes 0 by a boolean select, exact on targets honouring IEEE NaN.
const float OS_GREY_BELOW = 0.006;  // below it the colour becomes exactly grey
const float OS_RED_FROM = 0.012;    // below it red is at most the larger of green and blue
const float OS_RED_FULL = 0.05;     // red's excess is whole from here, and red returned as it stands
vec3 osOffRed(vec3 c) {
    c = mix(c, vec3(0.0), notEqual(c, c));      // NaN -> 0
    c = clamp(c, vec3(0.0), vec3(16.0));
    float s = c.g + c.b, t = 0.55 * c.r;        // gated on the rounded sum and product, so a
    if (s < t) c += vec3(0.0, 0.5 * (t - s), 0.5 * (t - s));  // colour that meets the share is kept
    float m = max(c.r, max(c.g, c.b));
    if (m < OS_GREY_BELOW) return vec3(luma(c));  // three identical channels
    float p = max(c.g, c.b);
    if (c.r > p && m < OS_RED_FULL) {           // no saturated red byte from the present dither
        float w = clamp((m - OS_RED_FROM) / (OS_RED_FULL - OS_RED_FROM), 0.0, 1.0);
        c.r = w <= 0.0 ? p : p + w * (c.r - p);  // red equal to a partner below OS_RED_FROM
    }
    return c;
}

// Everything joined after this file reads the vivid set through the usual names.
#define palVisual osPalVisual

// Disco Floor.
// Saturday night under the mirror ball: a lit LED dance floor runs back to a
// crowd at the far wall, and eight dancers work it: six women, curvy in
// sequinned minis and catsuits, and two men, each a solid figure in the
// complement of the floor's colours, edged in neon. Every dancer sways a hip
// out on each beat and dips into it, the knees giving and the shoulders
// answering the hips, and every eight beats each one changes moves (hands up,
// a hand through the hair or his point, arms low and loose, hands on the hips)
// and may turn to profile. Hair swings behind the sway. The floor changes its
// pattern every eight beats too (a checker that flips on the beat, a ripple
// from the middle, a scatter, a diagonal chase). The ball throws its spots
// across the wall, the floor and the dancers, and four moving heads sweep
// coloured beams through the haze. The camera holds still; only the room moves.
//
// The kick moves colour, never light. A lit area that pumps on the beat, or an
// edge that snaps across the dark wall, is a large-area flash the limiter has
// to hold (ADR-0232), and a held frame shows as ghosts. So the tiles swap
// colour at nearly one luminance, crossfading over most of the beat, stepping
// their palette on the beat and fading from one pattern to the next; the kick tints the floor, beams,
// haze and crowd toward the rig's hot colour at a fixed luminance; the beams
// and halos shine steadily; the spots and sequins are coloured and add less
// than a flash step to whatever they cross; strong reds ease toward grey so the
// palette tour never spends the limiter's red budget; and the dancers move at a
// bounded speed, with no snap through the middle of a sway.
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

    // the hip sways to a side on every beat as a plain sine, and the knees dip over the first
    // part of each beat and rest; the chest answers late. Nothing snaps: a fast edge would jerk
    // the figure and sweep it across the dark wall in a frame, which the limiter must hold
    P.sway = cos(3.14159265 * (t + mirror));
    float cl = cos(3.14159265 * (t + mirror - 0.18));
    float hx = 0.07 * amt * P.sway * (1.0 - 0.5 * P.turn);
    float dip = sin(3.14159265 * min(fract(t) / 0.4, 1.0));
    P.dy = 0.04 * amt * dip * dip;
    P.hip = vec2(hx, 0.93 - P.dy);
    P.chest = vec2(-0.4 * 0.07 * amt * cl * (1.0 - 0.5 * P.turn), 1.30 - 0.85 * P.dy);
    P.head = P.chest + vec2(-0.25 * hx + 0.02 * P.facing * P.turn, 0.29 + 0.02 * P.male);
    P.headR = mix(vec2(0.07, 0.097), vec2(0.082, 0.103), P.male);
    P.lag = 0.1 * amt * cos(3.14159265 * (t + mirror - 0.35));

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

// Where p sits on the dress: across from the line the dress hangs on (the torso's centre above
// the hips, the hem's swinging centre below) and up from the feet, both moving with the pose, so
// the sequins ride on the fabric instead of sliding under it as she sways and dips.
vec2 dfDressFrame(vec2 p, DfPose P) {
    float yy = p.y + P.dy;
    float xc = mix(P.hip.x, P.chest.x, smoothstep(0.9, 1.34, yy));
    float hem = 0.66 - 0.5 * P.dy;
    float k = saturate((P.hip.y - yy) / (P.hip.y - hem));
    vec2 km = 0.5 * (P.knee0 + P.knee1);
    float cx = mix(P.hip.x, km.x, k * (P.hip.y - hem) / max(P.hip.y - km.y, 0.1)) - 0.12 * P.lag * k;
    return vec2(p.x - mix(xc, cx, step(yy, P.hip.y)), yy);
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

// The colour c at relative luminance y: its hue kept, scaled to y, or at full
// strength with white mixed in where full strength is darker than y. A layer
// that covers much of the frame moves its colour at a fixed luminance, so it
// stays vivid without flashing.
vec3 dfAtLuma(vec3 c, float y) {
    // a palette can swing a channel below zero; the display would clip it and brighten the colour
    c = max(c, vec3(0.0));
    vec3 c1 = c / max(max(c.r, c.g), max(c.b, 1e-4));
    float l1 = luma(c1);
    if (l1 >= y) return c1 * (y / max(l1, 1e-4));
    return mix(c1, vec3(1.0), (y - l1) / (1.0 - l1));
}

// Lit and unlit tiles differ in colour only: a beat that changed the floor's luminance changed
// most of the screen at once, which the flash limiter has to hold (the ghosting)
const float DF_LED_ON = 0.13;   // a lit tile's luminance
const float DF_LED_OFF = 0.13;  // an unlit tile's: another colour, as bright
const float DF_BODY_L = 0.1;  // a dancer's figure, between the floor and the wall
// what a spot or a sequin adds: under the 0.1 luminance step that makes a flash, so the spots
// sweeping the room and the sequins riding the dresses never count as one
// before the present pass's grade and tone map, which lift a glint on the floor ~1.65 times
const float DF_GLINT_L = 0.045;

// How lit a tile is in one of the floor's four patterns.
float dfPattern(vec2 tile, float pattern, float t) {
    // a pattern that steps on the beat crossfades over most of the beat
    float on;
    float xf = smoothstep(0.0, 0.7, fract(t));
    if (pattern < 1.0) {
        on = mix(mod(tile.x + tile.y + floor(t) + 1.0, 2.0), mod(tile.x + tile.y + floor(t), 2.0), xf);
    } else if (pattern < 2.0) {
        float r = length(tile - vec2(0.0, 6.0));
        float e0 = r - fract(t) * 6.0, e1 = e0 - 3.0;
        on = exp(-e0 * e0 * 0.8) + 0.25 * exp(-e1 * e1 * 0.8);
    } else if (pattern < 3.0) {
        on = mix(step(0.62, hash21(tile + (floor(t) - 1.0) * 1.7)), step(0.62, hash21(tile + floor(t) * 1.7)), xf);
    } else {
        float ch = fract((tile.x - tile.y) * 0.125 - t * 0.25);
        on = smoothstep(0.0, 0.06, ch) * (1.0 - smoothstep(0.3, 0.36, ch));
    }
    return saturate(on);
}

// A tile's colour. Every eight beats the floor moves to its next pattern, fading the outgoing
// one out over the first beat of the incoming one rather than cutting between them.
vec3 dfLed(vec2 tile, float t, float kick, DfPalette P) {
    float block = floor(t / 8.0);
    float pattern = mod(block, 4.0);
    float on = dfPattern(tile, pattern, t);
    float fade = smoothstep(0.0, 1.0, t - block * 8.0);
    if (fade < 1.0) on = mix(dfPattern(tile, mod(block + 3.0, 4.0), t), on, fade);
    float h = hash21(tile * 1.31 + 7.0);
    vec3 c = (h < 0.4) ? P.hot : ((h < 0.75) ? P.warm : P.cool);
    vec3 c2 = (h < 0.4) ? P.cool : ((h < 0.75) ? P.hot : P.warm);
    // lit and unlit differ in colour; the kick blushes every tile toward the rig's hot colour
    vec3 hue = mix(c2, c, on);
    hue = mix(hue, P.hot, 0.55 * kick);
    return dfAtLuma(hue, mix(DF_LED_OFF, DF_LED_ON, on));
}

// Spots thrown by the mirror ball: cells in angle and log distance around it, turning as it does.
float dfSpots(vec2 sp, VisualUniforms u) {
    vec2 q = sp - DF_BALL;
    float r = length(q);
    float a = atan2_(q.y, q.x) / 6.2831853 * 48.0 + u.time * 0.35;
    float lr = log(max(r, 1e-3)) * 7.0;
    vec2 cell = floor(vec2(a, lr));
    vec2 f = fract(vec2(a, lr)) - 0.5;
    vec2 o = (hash22(cell) - 0.5) * 0.6;
    float on = step(0.6, hash21(cell + 19.0));
    float s = exp(-dot(f - o, f - o) * 60.0) * on;
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

    // the colours move on a step every beat, an even quarter of their bar's move each time: the
    // floor's answer to the beat, at a fixed luminance, so it is a change of colour, not a flash
    float bar = u.beatCount / 4.0;
    DfPalette Pal;
    Pal.warm = palVisual(fract(0.12 + bar * 0.17), u);
    Pal.hot = palVisual(fract(0.45 + bar * 0.17), u);
    Pal.cool = palVisual(fract(0.80 + bar * 0.17), u);

    vec3 col;

    // the floor's tile coordinates and their pixel footprint, taken here while every pixel
    // runs together: fwidth is undefined inside the branch below
    float floorZ = DF_CAMH * DF_F / max(DF_H - sp.y, 1e-4);
    vec2 floorP = vec2(sp.x * floorZ / DF_F, floorZ);
    vec2 floorW = fwidth(floorP);
    if (sp.y > DF_H) {
        // the far wall: dark, with coloured haze rising off the floor
        float hgt = sp.y - DF_H;
        col = mix(Pal.hot * 0.05, Pal.cool * 0.015, saturate(hgt * 0.9));
        col += dfAtLuma(mix(Pal.warm, Pal.hot, kick), 0.03) * exp(-hgt * 6.0);
    } else {
        // the LED floor in perspective
        float z = floorZ;
        vec2 fp = floorP;
        vec2 tile = floor(fp);
        vec2 f = fract(fp) - 0.5;
        vec3 led = dfLed(tile, t, kick, Pal);
        vec2 fw = floorW;
        float seamW = max(fw.x, fw.y);
        float edge = max(abs(f.x), abs(f.y));
        float glass = 1.0 - smoothstep(0.44 - seamW, 0.46 + seamW, edge);
        float centre = 1.0 - 0.45 * smoothstep(0.0, 0.5, edge);
        // far tiles fall below a pixel: show their mean instead of aliasing
        float farMix = saturate(seamW * 2.0 - 0.3);
        vec3 mean = dfAtLuma(Pal.hot * 0.4 + Pal.warm * 0.35 + Pal.cool * 0.25, 0.07);
        vec3 floorCol = mix(led * glass * centre, mean, farMix);
        // Glow lifts the floor only a little: its light stays near the dancers'
        col = floorCol * (0.85 + 0.3 * u.param0);
        // a mist where the floor meets the wall
        col = mix(col, Pal.warm * 0.08, exp(-(DF_H - sp.y) * 14.0) * 0.8);
        // the ball, mirrored in the glass
        vec2 mb = vec2(sp.x, 2.0 * DF_H - sp.y) - DF_BALL;
        col += Pal.cool * 0.05 * exp(-length(mb) * 5.0);
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
        bc = dfAtLuma(mix(bc, Pal.hot, 0.65 * kick), 0.3);
        col += bc * beam * haze * 0.42 * glow;
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
        // some hands are up
        if (hash11(cell * 3.7) < 0.3) {
            float hx0 = (cell + 0.5) / 15.0;
            float reach = 0.055 + 0.02 * hh;
            dc = min(dc, dfCapsule(sp, vec2(hx0 - 0.02, top - 0.012), vec2(hx0 - 0.034, top + reach), 0.0045, 0.0035));
            dc = min(dc, dfCapsule(sp, vec2(hx0 + 0.02, top - 0.012), vec2(hx0 + 0.034, top + reach), 0.0045, 0.0035));
        }
        float a = aaFill(dc) * step(DF_H - 0.02, sp.y);
        col = mix(col, Pal.hot * 0.01, a);
        col += dfAtLuma(mix(Pal.warm, Pal.hot, kick), 0.12) * aaLine(dc, 0.0015) * step(DF_H, sp.y);
    }

    // the ball's spots on the wall and the floor: coloured, and less than a flash brighter than
    // what they cross, since a spot sweeping a pixel lights and darkens it in under a second
    col += dfAtLuma(mix(vec3(1.0), Pal.cool, 0.5), DF_GLINT_L) * dfSpots(sp, u) * min(sparkle, 1.0);

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
            col *= 1.0 - 0.3 * saturate(0.5 - dr / px) * exp(p.y * 1.5);
        }
        if (!inFig) continue;
        float d = dfBody(p, P, dressMask);
        // a soft halo of the lights behind them
        col += mix(Pal.warm, Pal.hot, saturate(p.y * 0.5)) * exp(-max(d, 0.0) * 40.0) * 0.07 * glow * 0.8;
        float fill = saturate(0.5 - d / px);
        if (fill <= 0.0) continue;
        // rim light from the outline's normal: the rig's two colours from either side above,
        // the floor's from below
        float e = 0.006, dm;
        vec2 n = normalize(vec2(dfBody(p + vec2(e, 0.0), P, dm) - d, dfBody(p + vec2(0.0, e), P, dm) - d) + vec2(0.0, 1e-5));
        // a thin band, a few pixels wide however far away the dancer is
        float rim = pow(saturate(1.0 + d / (2.5 * px)), 2.0);
        float lightL = pow(saturate(dot(n, vec2(-0.85, 0.53))), 1.5);
        float lightR = pow(saturate(dot(n, vec2(0.85, 0.53))), 1.5);
        float bounce = saturate(-n.y);
        // the figure is a solid colour of its own, lit by the rig from either side, at a
        // luminance near the floor's: dark on the bright floor, its every move would step the
        // light over the area it sweeps, a large-area flash
        // its hue is the complement of the floor's, so it stands apart by colour, not light
        vec3 fm = Pal.hot * 0.4 + Pal.warm * 0.35 + Pal.cool * 0.25;
        vec3 comp = max(vec3(max(max(fm.r, fm.g), fm.b)) - fm, vec3(0.02));
        vec3 skin = dfAtLuma(comp, DF_BODY_L * (1.0 + 0.4 * (lightL + lightR - 0.5)));
        // the rim is a neon edge in the rig's colours at about the figure's luminance: a bright
        // edge sweeping with the dance would flash over all the area it crosses
        float rimA = rim * saturate((lightL + lightR + 0.35 * bounce) * 1.6) * (0.6 + 0.4 * glow);
        vec3 rimHue = mix(Pal.hot * lightL + Pal.cool * lightR + Pal.warm * bounce * 0.35, Pal.hot, 0.6 * kick);
        vec3 body = mix(skin, dfAtLuma(rimHue, 0.14), rimA);
        // sequins on the dresses catch the light
        if (dressMask > 0.0) {
            vec2 dp = dfDressFrame(p, P) * 140.0;
            vec2 sq = floor(dp);
            float dot_ = 1.0 - smoothstep(0.25, 0.45, length(fract(dp) - 0.5));
            float tw = pow(0.5 + 0.5 * sin(u.time * (1.5 + 2.0 * hash21(sq + 5.0)) + 6.2831853 * hash21(sq)), 6.0) * dot_;
            body += dfAtLuma(mix(vec3(1.0), Pal.warm, 0.5), DF_GLINT_L) * tw * dressMask * min(sparkle, 1.0);
            body += Pal.hot * 0.03 * dressMask;
        }
        // the spots fade out over the dress, so a spot and a sequin together stay within one glint
        body += dfAtLuma(mix(vec3(1.0), Pal.cool, 0.5), 0.7 * DF_GLINT_L) * dfSpots(sp, u) * min(sparkle, 1.0) * (1.0 - dressMask);
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
            float lon = atan2_(n.x, n.z) + u.time * 0.3;
            float lat = asin(clamp(n.y, -1.0, 1.0));
            vec2 fc = vec2(lon, lat) * (14.0 / 3.14159265);
            vec2 cell = floor(fc);
            vec2 ff = fract(fc) - 0.5;
            float seam = smoothstep(0.3, 0.5, max(abs(ff.x), abs(ff.y)));
            float glint = pow(0.5 + 0.5 * sin(u.time * (1.0 + 1.0 * hash21(cell + 3.0)) + 6.2831853 * hash21(cell)), 4.0);
            vec3 silver = vec3(0.10, 0.10, 0.12) * (0.4 + 0.6 * n.z) + Pal.cool * 0.05;
            vec3 ball = silver * (1.0 - 0.8 * seam) + mix(vec3(1.0), mix(Pal.warm, Pal.hot, kick), 0.35) * glint * (1.0 - seam) * 1.4 * sparkle;
            col = mix(col, ball, disc);
        }
        col += mix(vec3(1.0), Pal.cool, 0.4) * exp(-r * 9.0) * 0.25 * glow;
    }

    col *= 1.0 - 0.35 * smoothstep(0.9, 2.0, length(sp));
    // Strong reds ease toward grey at their own luminance. As the palette tours through red the
    // floor, beams and figures turn a red the vivid present grades into saturated red, and the
    // limiter's slower red budget then held whole windows of the room (the ghosting).
    float redShare = col.r / (col.r + col.g + col.b + 1e-4);
    col = mix(col, vec3(luma(col)), saturate((redShare - 0.7) * 5.0) * 0.5);
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    return max(col, 0.0); // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
