// SPDX-License-Identifier: AGPL-3.0-only
// Vault.
// A projection-mapping show inside a cathedral at night. The camera walks a
// raymarched vaulted hall of pale stone whose ribs, webbing, walls and piers
// are the projection screen: graphic light is mapped onto the architecture in
// time with the music. Every eight beats a new pattern slowly fades in over the
// last: light pouring gently down the ribs from the crown, a
// tiled reveal across the webbing, a spectrum meter climbing each bay, a scan
// plane gliding down the nave, chevrons drifting over the vault. Every
// pattern paints in the projector's warm colour and its cool complement; a faint
// neon outline traces every edge of the hall, and the backlit stained glass
// glows steadily. The polished floor mirrors the show. The camera glides very
// slowly down the hall with a level horizon, and the stone right beside it
// stays dim, so no bright stripe streams past; the smoothed level gently lifts the
// projectors and the reds are kept just off saturated red, so the show never
// flashes or blacks out and audio never moves the camera.
// param0 = Grandeur ; param1 = Ornament ; param2 = Walk Speed

// The palette read without the library's per-beat and spectral-centroid hue
// nudge, so large lit areas never shimmer with the music; under the host's
// palette tour the cross-fade between palettes is spread over the whole tour
// step, so the colours change slowly.
vec3 vtPalStill(float t, VisualUniforms u) {
    if (u.palette.x >= 0.0) return palByIndex(t, int(floor(u.palette.x + 0.5)));
    int a = int(mod(floor(u.palette.z), 32.0));
    int b = int(mod(float(a + 1), 32.0));
    float blend = smoothstep(0.0, 1.0, fract(u.palette.z));
    return mix(palByIndex(t, a), palByIndex(t, b), blend);
}

const float VT_BAY = 3.0;      // rib and column spacing
const float VT_ROOM = 24.0;    // room length
const float VT_WRAP = 6144.0;  // 256 rooms; the hall repeats seamlessly

// room descriptor: x = half width, y = crown height, z = chorus, w = seed
vec4 vtRoom(float idx) {
    float i = mod(idx, 256.0);
    float s = hash11(i * 7.31 + 2.7);
    float chorus = step(2.0, mod(i, 4.0));
    float w = mix(1.5 + s * 0.4, 2.4 + s * 0.9, chorus);
    float h = mix(1.9 + s * 0.5, 3.3 + s * 1.2, chorus);
    return vec4(w, h, chorus, s);
}

// Room shape at depth z, blended through the doorways.
vec4 vtRoomAt(float z, float grand) {
    float ri = floor(z / VT_ROOM);
    float f = z - ri * VT_ROOM;
    vec4 r = mix(vtRoom(ri), vtRoom(ri + 1.0), smoothstep(VT_ROOM - 5.0, VT_ROOM, f));
    r.xy *= grand;
    return r;
}

float vtSpring(vec4 r) { return 0.1 + r.y * 0.4; }

// Hue-flipped partner of a palette colour (same lightness and saturation), so
// any palette gets a complementary accent: gold turns to cobalt, ember to azure.
vec3 vtComp(vec3 c) {
    return max(vec3(max(max(c.r, c.g), c.b) + min(min(c.r, c.g), c.b)) - c, 0.0);
}

// The glass colours: gold, cobalt (the palette complement) and crimson.
// gold and ember are the rib gilding and the torch light, read once per pixel.
struct VtGlassSet { vec3 warm; vec3 cool; vec3 red; vec3 gold; vec3 ember; };

// Stained glass at a point on a clerestory opening (z along the wall, height).
// Two lancets per bay with round tops. Each holds a rose medallion of gold and
// crimson petals set in a diamond lattice of cobalt and azure quarries, all
// leaded. fine = 1 for the glass itself, lower for its blurred projection, 0 for
// the dusty air (colour only, no lead). Returns the transmitted colour.
vec3 vtGlass(float wz, float wy, float sy, float fine, VtGlassSet gs) {
    float gx = (fract(wz / VT_BAY) - 0.28) / 0.44;      // 0..1 across the opening
    float gy = (wy - (sy - 0.95)) / 0.93;               // 0..1 up the opening
    if (gx < 0.0 || gx > 1.0 || gy < 0.0 || gy > 1.0) return vec3(0.0);
    float lx = fract(gx * 2.0) * 2.0 - 1.0;             // -1..1 across one lancet
    float edge = mix(0.3, 0.025, fine);
    float top = 0.74 + 0.26 * sqrt(max(1.0 - lx * lx, 0.0));
    float m = smoothstep(0.0, edge, gy) * smoothstep(top, top - edge, gy)
            * smoothstep(0.0, edge * 2.5, 1.0 - abs(lx));
    // metres inside the lancet
    vec2 q = vec2(lx * 0.33, (gy - 0.58) * 0.93);
    float md = length(q);
    float med = smoothstep(0.23, 0.23 - edge * 0.8, md);
    vec3 azure = mix(gs.cool, vec3(0.45, 0.9, 1.0) * max(gs.cool.b, 0.35), 0.5);
    if (fine < 0.05) {
        // in the air the panes blur into a cobalt beam with a warm core
        return mix(mix(gs.cool, azure, 0.4) * 0.8, mix(gs.warm, gs.red, 0.45), med) * m;
    }
    // diamond quarries
    vec2 dq = vec2(q.x + q.y, q.x - q.y) * 9.0;
    vec2 cell = floor(dq);
    vec2 f = fract(dq) - 0.5;
    float bay = mod(floor(wz / VT_BAY), 256.0);
    float h = hash21(cell + vec2(bay * 6.1 + step(0.0, lx) * 17.0, bay * 0.37));
    vec3 bg = h < 0.45 ? gs.cool * 0.7 : h < 0.82 ? azure : h < 0.94 ? gs.red : gs.warm;
    // hand-made glass: each quarry its own thickness, and a fine mottling within
    float mott = hash21(floor(dq * 4.0) + cell * 3.7);
    bg *= (0.62 + 0.7 * fract(h * 7.31)) * mix(1.0, 0.85 + 0.3 * mott, fine);
    // deepen the pale panes toward their own hue
    bg = bg * bg / max(max(bg.r, max(bg.g, bg.b)), 0.05) * 1.15;
    float lead = smoothstep(0.5, 0.5 - 0.12 / max(fine, 0.2) * 0.4, max(abs(f.x), abs(f.y)) * 1.0);
    // rose: eight petals around a bright heart
    float a = atan(q.y, q.x + 1e-5);
    float pet = cos(a * 4.0);
    vec3 rose = mix(gs.red, gs.warm, step(0.0, pet));
    rose = mix(rose, gs.warm * 1.4 + 0.25, smoothstep(0.075, 0.06, md));
    float rl = smoothstep(0.0, 0.08 * fine, abs(pet) * md * 4.0)          // petal seams
             * smoothstep(0.0, 0.012 / fine, abs(md - 0.075))
             * smoothstep(0.0, 0.014 / fine, abs(md - 0.23));            // medallion ring
    lead = mix(lead, rl, med);
    vec3 c = mix(bg, rose, med);
    // the sun burns brightest through the middle of each lancet
    c *= 0.8 + 0.55 * exp(-dot(q, q) * 7.0);
    return c * m * mix(1.0, 0.1 + 0.9 * lead, fine);
}

// Distance to the hall surfaces. Floor at y = -1, springline of the vault at
// vtSpring, barrel vault above it.
float vtMap(vec3 p, vec4 r, float orn) {
    float sy = vtSpring(r);
    float rise = r.y - sy;
    vec2 q = vec2(p.x / r.x, max(p.y - sy, 0.0) / rise);
    float arch = (1.0 - length(q)) * min(r.x, rise);
    float dWall = r.x - abs(p.x);
    float dIn = min(dWall, arch);
    float bz = mod(p.z, VT_BAY) - 0.5 * VT_BAY;
    float rw = 0.07 + 0.04 * orn;
    float dRib = max(dIn - rw, abs(bz) - rw);
    float dCol = length(vec2(abs(p.x) - r.x, bz)) - (0.2 + 0.07 * orn);
    dCol = max(dCol, p.y - sy);
    return min(min(dIn, dRib), min(dCol, p.y + 1.0));
}


// Everything the projectors need that is the same for the whole frame.
struct VtShow {
    int pNew;      // pattern fading in
    int pOld;      // pattern fading out
    float wipe;    // crossfade, 0 old to 1 new
    float life;    // 0..1 through the pattern's two beats
    float bp;      // beat phase
    float zc;      // camera depth
    float proj;    // projector level: low in a breakdown
    float outline; // neon outline level: high in a burst
    float seed;    // per-pattern seed
    float seedOld;
    vec3 cA;       // this beat's projector colour
    vec3 cB;       // its partner
    vec3 cOA;      // the outgoing pattern's colours
    vec3 cOB;
};

// Soft-edged line of half width w at distance d, widened by the pixel size.
float vtLine(float d, float w, float fw) {
    return (1.0 - smoothstep(w - fw, w + fw, abs(d))) * (w / (w + fw));
}

// The projected light at a surface point, for one pattern. z runs down the
// hall, vs is the distance up the cross-section from the floor (crown at vc),
// side is the wall, bay the bay index, rib 1 on a rib.
vec3 vtPattern(int pid, float z, float vs, float vc, float side, float bay, float rib,
               float fw, float seed, float life, float bp, float zc, float eq, vec3 cA, vec3 cB) {
    if (pid == 0) {
        // light pours down the ribs from the crown, bay after bay
        float fr = fract(life + bay * 0.11);
        float front = vc * (1.0 - fr);
        float d = vs - front;
        float head = exp(-d * d * 3.0);
        float tail = d > 0.0 ? exp(-d * 0.8) : 0.0;
        vec3 c = mix(cA, cB, step(0.0, side));
        return c * (rib * (head * 0.6 + tail * 0.35 + 0.4) + (1.0 - rib) * (head * 0.08 + tail * 0.04 + 0.06));
    }
    if (pid == 1) {
        // a tiled reveal: tiles switch on in a scattered order
        vec2 g = vec2(z, vs) / 0.62;
        vec2 cell = floor(g);
        vec2 f = abs(fract(g) - 0.5);
        float h = hash21(cell + vec2(seed * 13.7, seed * 3.1));
        float rev = smoothstep(h - 0.3, h + 0.3, life * 1.4);
        float tile = 1.0 - smoothstep(0.40 - fw * 1.6, 0.44 + fw * 1.6, max(f.x, f.y));
        float h2 = fract(h * 31.7);
        vec3 c = h2 < 0.65 ? cA : h2 < 0.92 ? cB : vec3(1.0);
        return c * tile * (0.15 + 0.5 * rev) * (0.7 + 0.3 * fract(h * 7.3)) * (1.0 - rib * 0.6);
    }
    if (pid == 2) {
        // each bay a spectrum meter, segmented like LEDs, peaking white
        float lvl = saturate(0.42 + 0.03 * eq) * vc;
        float fill = 1.0 - smoothstep(lvl - fw, lvl + fw, vs);
        float seg = smoothstep(0.10, 0.16, fract(vs * 3.0)) * smoothstep(1.0, 0.94, fract(vs * 3.0));
        float cap = vtLine(vs - lvl - 0.08, 0.04, fw);
        // alternate bays take the two colours (mixing complements would grey them)
        vec3 c = mod(bay, 2.0) < 1.0 ? cA : cB;
        c = mix(c, vec3(1.0), 0.35 * smoothstep(0.75, 1.0, vs / vc));
        float top = smoothstep(lvl - 0.9, lvl, vs);
        return c * (fill * seg * (0.35 + 0.6 * top) + cap * 1.2) * (1.0 - rib * 0.7) + cB * rib * 0.2;
    }
    if (pid == 3) {
        // a scan plane glides down the nave, leaving contour lines behind it
        float zf = zc + 3.0 + 10.0 * life;
        float d = z - zf;
        float slice = exp(-d * d * 4.0);
        float trail = d < 0.0 ? exp(d * 0.25) : 0.0;
        float cont = vtLine(fract(vs * 2.0 + 0.5) - 0.5, 0.05, fw * 2.0);
        return mix(cA, vec3(1.0), 0.3) * slice * 0.5 + cB * cont * (0.3 + 0.5 * trail) + cA * (0.05 + 0.05 * trail);
    }
    // chevrons drift down the vault, pointing along the walk
    float w = z * 0.45 + vs * 0.55 - life * 0.5;
    float s = fract(w);
    float k = floor(w);
    float band = smoothstep(0.0, 0.04 + fw, s) * (1.0 - smoothstep(0.42 - fw, 0.46 + fw, s));
    vec3 c = mod(k, 2.0) < 1.0 ? cA : cB;
    return c * (0.1 + 0.7 * band) * (1.0 - rib * 0.5) + c * rib * band * 0.8;
}

// Light leaving a surface point.
vec3 vtShade(vec3 pos, vec3 n, vec4 r, float orn, vec3 rd, float fw,
             VtGlassSet gs, VtShow S, VisualUniforms u) {
    // fw is the pixel's size on the surface, foreshortened by the view angle
    fw /= max(abs(dot(rd, n)), 0.15);
    float sy = vtSpring(r);
    float rise = r.y - sy;
    float bz = mod(pos.z, VT_BAY) - 0.5 * VT_BAY;
    float bay = mod(floor(pos.z / VT_BAY + 0.5), 256.0);
    float rw = 0.07 + 0.04 * orn;
    float onFloor = step(pos.y, -0.995);
    float side = pos.x > 0.0 ? 1.0 : -1.0;
    vec2 aq = vec2(abs(pos.x) / r.x, max(pos.y - sy, 0.0) / rise);
    float nearWall = min(r.x - abs(pos.x), (1.0 - length(aq)) * min(r.x, rise));

    // the cross-section unrolled: up the wall, then over the vault to the crown
    float arcR = 0.5 * (r.x + rise);
    float vs = pos.y < sy ? pos.y + 1.0 : sy + 1.0 + atan(aq.y, max(aq.x, 1e-3)) * arcR;
    float vc = sy + 1.0 + 1.5707963 * arcR;
    if (onFloor > 0.5) vs = -(r.x - abs(pos.x));

    // pale limestone, faintly veined: a good projection screen
    float vein = vnoise(vec2(pos.z * 1.3 + pos.y * 0.7, pos.x * 1.9 + pos.y * 1.1));
    vec3 stone = mix(vec3(0.20, 0.185, 0.17), vec3(0.30, 0.28, 0.25), vein);
    if (onFloor > 0.5) {
        // polished black marble with fine joints
        vec2 tile = abs(fract(vec2(pos.x, pos.z) / 1.5) - 0.5);
        stone = vec3(0.012, 0.011, 0.012) * (0.8 + 0.4 * vein);
        stone *= 0.6 + 0.4 * smoothstep(0.47, 0.49, 0.97 - max(tile.x, tile.y));
    }
    // fluted piers
    float cdist = length(vec2(abs(pos.x) - r.x, bz));
    float onCol = onFloor < 0.5 && pos.y < sy && cdist < 0.21 + 0.07 * orn ? 1.0 : 0.0;
    float flute = 1.0;
    if (onCol > 0.5) {
        float ang = atan(bz, r.x - abs(pos.x) + 1e-4);
        flute = abs(cos(ang * 9.0));
        stone *= 0.55 + 0.6 * flute;
    }

    float ew = 0.5 * fw + 0.004;
    float onRib = (1.0 - smoothstep(rw + 0.01 - ew, rw + 0.01 + ew, abs(bz)))
                * (1.0 - smoothstep(rw * 2.5 + 0.05 - ew, rw * 2.5 + 0.05 + ew, nearWall)) * (1.0 - onFloor);
    float rib = max(onRib, onCol);

    // ---- the projection: the new pattern slowly fading in over the old ----
    float eq = bandAt(u, fract(bay * 0.0625 + 0.03));
    vec3 L = vtPattern(S.pNew, pos.z, vs, vc, side, bay, rib, fw, S.seed, S.life, S.bp, S.zc, eq, S.cA, S.cB);
    if (S.wipe < 1.0) {
        vec3 Lo = vtPattern(S.pOld, pos.z, vs, vc, side, bay, rib, fw, S.seedOld, S.life + 1.0, S.bp, S.zc, eq, S.cOA, S.cOB);
        L = mix(Lo, L, S.wipe);
    }
    L *= S.proj * (onFloor > 0.5 ? 0.25 : 1.0);

    // ---- neon outline: every edge of the hall ----
    float edge = vtLine(abs(bz) - rw - 0.012, 0.010, fw) * (1.0 - onFloor)
               * (1.0 - smoothstep(rw * 2.5 + 0.05, rw * 2.5 + 0.09, nearWall));
    edge = max(edge, vtLine(pos.y - sy, 0.012, fw) * step(r.x - 0.05, abs(pos.x)));
    edge = max(edge, vtLine(pos.y + 0.55, 0.010, fw) * step(r.x - 0.05, abs(pos.x)));
    edge = max(edge, onCol * smoothstep(0.95, 0.995, flute) * 0.25);
    float crownL = vtLine(pos.x, 0.015, fw) * step(r.y - 0.2, pos.y);
    edge = max(edge, crownL);
    vec3 outl = mix(S.cB, vec3(1.0), 0.35) * edge * S.outline * 3.0;

    vec3 col = stone * L * 2.2 + outl;

    // the stained glass, lit from outside, each pane breathing a little with its band
    float isWin = step(r.x - 0.02, pos.x) * step(0.5, -n.x);
    if (isWin > 0.5) {
        vec3 gl = vtGlass(pos.z, pos.y, sy, 1.0, gs);
        float pane = bandAt(u, fract(pos.y * 1.7 + pos.z * 0.31));
        col += gl * (1.15 + 0.04 * pane) * mix(2.2, 0.8, S.proj);
    }
    // the glass spills a faint glow on the stone; the show bounces off the floor
    col += stone * gs.cool * 0.012 * (1.0 + 2.0 * (1.0 - S.proj)) * smoothstep(-1.0, sy, pos.y);
    col += stone * (S.cA + S.cB) * 0.010 * S.proj * saturate(-n.y + 0.3);
    return col;
}

vec3 vtNormal(vec3 p, vec4 r, float orn) {
    vec2 k = vec2(1.0, -1.0) * 0.003;
    return normalize(k.xyy * vtMap(p + k.xyy, r, orn) + k.yyx * vtMap(p + k.yyx, r, orn)
                   + k.yxy * vtMap(p + k.yxy, r, orn) + k.xxx * vtMap(p + k.xxx, r, orn) + 1e-6);
}

// The palette read once per pixel at its five stops and blended locally.
struct VtPalette { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

VtPalette vtPalLoad(VisualUniforms u) {
    VtPalette P;
    P.c0 = vtPalStill(0.0, u);
    P.c1 = vtPalStill(0.26, u);
    P.c2 = vtPalStill(0.52, u);
    P.c3 = vtPalStill(0.78, u);
    P.c4 = vtPalStill(0.999, u);
    return P;
}

vec3 vtPal(VtPalette P, float t) {
    t = saturate(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// A projector colour: peak-normalised and pushed a little more saturated.
vec3 vtVivid(vec3 c) {
    c = c / max(max(c.r, max(c.g, c.b)), 0.05);
    return max(mix(vec3(luma(c)), c, 1.3), 0.0);
}

// The pattern shown in two-beat slot k, never the same twice running.
int vtPick(float k) {
    int a = int(floor(hash11(k * 1.37 + 0.5) * 4.999));
    int b = int(floor(hash11((k - 1.0) * 1.37 + 0.5) * 4.999));
    return a == b ? int(mod(float(a) + 1.0, 5.0)) : a;
}

// Keep reds just off saturated red: lift the weaker of green and blue until,
// after the tone curve, they carry at least 0.3 of the red.
float vtTone(float x) { return x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14); }
float vtToneInv(float y) {
    y = clamp(y, 0.0, 0.999);
    float a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y;
    return (-b + sqrt(b * b + 0.56 * a * y)) / (2.0 * a);
}
vec3 vtOffRed(vec3 c) {
    float r = vtTone(c.r), g = vtTone(c.g), b = vtTone(c.b);
    float need = 0.3 * r - g - b;
    if (need <= 0.0) return c;
    if (c.g > c.b) c.g = max(c.g, vtToneInv(g + need));
    else c.b = max(c.b, vtToneInv(b + need));
    return c;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 sp = centered(uv, u.resolution);
    sp.y = -sp.y;
    float detail = osDetail(u);
    float grand = mix(0.85, 1.45, u.param0);
    float orn = mix(0.4, 1.4, u.param1);

    // a very slow, steady glide down the hall: no speed surges, and slow
    // enough that the bright stripes on the near walls never stream past
    float zc = mod(5.0 + mix(0.005, 0.02, u.param2) * u.time, VT_WRAP);

    VtPalette P = vtPalLoad(u);
    float sec = u.beatCount / 16.0;
    float cyc = mod(sec, 4.0);
    float chorus = smoothstep(1.5, 2.0, cyc) * (1.0 - smoothstep(3.5, 4.0, cyc));
    VtGlassSet gs;
    gs.warm = vtPal(P, 0.72);
    gs.cool = vtComp(vtPal(P, mix(0.7, 0.62, chorus)));
    gs.red = vtPal(P, 0.3);
    gs.gold = vtPal(P, 0.6);
    gs.ember = vtPal(P, 0.42);

    // ---- the show: a new pattern every eight beats, its colours traded ----
    float n = floor(u.beatCount);
    float bp = saturate(u.beatPhase);
    float k2 = floor(n / 8.0);
    VtShow S;
    S.pNew = vtPick(k2);
    S.pOld = vtPick(k2 - 1.0);
    S.life = (n - 8.0 * k2 + bp) / 8.0;
    S.wipe = smoothstep(0.0, 0.9, S.life);
    S.bp = bp;
    S.zc = zc;
    S.seed = mod(k2, 97.0);
    S.seedOld = mod(k2 - 1.0, 97.0);
    vec3 warm = vtVivid(vtPal(P, mix(0.62, 0.68, chorus)));
    vec3 cool = vtVivid(vtComp(warm) + 0.02);
    // every pattern keeps the same two colours, so a new pattern changes the
    // shapes of the light, never the colour of whole walls at once
    S.cA = warm;
    S.cB = cool;
    S.cOA = warm;
    S.cOB = cool;
    // steady projectors and a faint outline, lifted a little by the level
    S.proj = 0.85 + 0.03 * u.level;
    S.outline = 0.2 + 0.03 * u.level;

    // camera: slow sway, level horizon; audio never moves it
    float tw = mod(u.time, 600.0);
    vec4 rc = vtRoomAt(zc, grand);
    vec3 ro = vec3(0.3 * sin(tw * 0.17) * rc.x * 0.4, -0.15 + 0.06 * sin(tw * 0.13), zc);
    vec3 ta = vec3(0.35 * sin(tw * 0.17 + 0.8), 0.15 + 0.2 * sin(tw * 0.071), zc + 6.0);
    float fov = 1.2;
    vec3 rd = osCamera(ro, ta, 0.0, fov, sp);
    float pixA = 2.0 / (u.resolution.y * fov);

    // ---- primary march ----
    int steps = osSteps(36.0, 72.0, detail);
    float tt = 0.0;
    vec4 r = rc;
    bool hit = false;
    for (int i = 0; i < 72; i++) {
        if (i >= steps) break;
        vec3 pos = ro + rd * tt;
        r = vtRoomAt(pos.z, grand);
        float d = vtMap(pos, r, orn);
        if (d < 0.0015 * tt + 0.0005) { hit = true; break; }
        tt += d * 0.92;
        if (tt > 52.0) break;
    }

    vec3 col = vec3(0.0);
    vec3 pos = ro + rd * tt;
    if (hit) {
        vec3 nrm = vtNormal(pos, r, orn);
        col = vtShade(pos, nrm, r, orn, rd, tt * pixA, gs, S, u);
        // polished floor mirrors the show
        if (pos.y < -0.99 && detail > 0.0) {
            vec3 rr = reflect(rd, nrm);
            int rsteps = osSteps(0.0, 24.0, detail);
            float t2 = 0.02;
            bool hit2 = false;
            float dLast = 1.0;
            vec4 r2 = r;
            for (int i = 0; i < 24; i++) {
                if (i >= rsteps) break;
                vec3 p2 = pos + rr * t2;
                r2 = vtRoomAt(p2.z, grand);
                float d = vtMap(p2, r2, orn);
                dLast = d;
                if (d < 0.003 * t2 + 0.001) { hit2 = true; break; }
                t2 += d * 0.95;
                if (t2 > 24.0) break;
            }
            float fres = 0.30 + 0.62 * pow(1.0 - saturate(-rd.y), 5.0);
            // a march that ran out of steps close to a surface still shades it
            float near2 = hit2 ? 1.0 : 1.0 - smoothstep(0.02, 0.12, dLast);
            if (near2 > 0.0) {
                vec3 p2 = pos + rr * t2;
                vec3 n2 = vtNormal(p2, r2, orn);
                vec3 rc2 = vtShade(p2, n2, r2, orn, rr, (tt + t2) * pixA, gs, S, u);
                col += rc2 * fres * exp(-t2 * 0.07) * near2;
            }
        }
    }

    // the projectors are aimed down the hall: the stone right beside the
    // walker stays dim, so nothing bright drifts past the edges of the view
    col *= mix(0.3, 1.0, smoothstep(0.6, 3.2, tt));

    // the projectors' light hangs faintly in the air of the nave
    float haze = 1.0 - exp(-min(tt, 40.0) * 0.04);
    col += (S.cA + S.cB) * haze * 0.006 * S.proj;
    // haze to cool black: the far hall vanishes into the dark
    float fog = 1.0 - exp(-tt * 0.06);
    col = mix(col, gs.cool * 0.006 + vec3(0.002), fog);

    col *= 1.0 - 0.3 * smoothstep(0.8, 1.9, length(sp));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    return vtOffRed(max(col, 0.0)); // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
