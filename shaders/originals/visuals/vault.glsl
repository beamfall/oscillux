// SPDX-License-Identifier: AGPL-3.0-only
// Vault.
// A projection-mapping show inside a cathedral at night. The camera walks a
// raymarched vaulted hall of pale stone whose ribs, webbing, walls and piers
// are the projection screen: graphic light is mapped onto the architecture in
// time with the music. Every two beats a new pattern wipes down the hall from
// the camera outward: light pouring down the ribs from the crown, a tiled
// reveal across the webbing, a spectrum meter climbing each bay, a scan plane
// racing down the nave, scrolling chevrons over the vault. Each beat swaps
// the projector's colour between warm and its cool complement; a burst draws
// every edge of the hall as a neon outline; a breakdown blacks the
// projectors out until only the backlit stained glass glows. The polished
// floor mirrors the show. The walk follows the shared 32-beat speed profile
// and the roll eases to a new side every eight beats; audio drives the light
// only, never the camera.
// param0 = Grandeur ; param1 = Ornament ; param2 = Walk Speed

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
    int pNew;      // pattern being wiped in
    int pOld;      // pattern being wiped out
    float wipe;    // depth of the wipe front
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
        float fr = fract(bp * 0.9 + bay * 0.11);
        float front = vc * (1.0 - fr);
        float d = vs - front;
        float head = exp(-d * d * 14.0);
        float tail = d > 0.0 ? exp(-d * 1.6) : 0.0;
        vec3 c = mix(cA, cB, step(0.0, side));
        return c * (rib * (head * 4.0 + tail * 1.2 + 0.15) + (1.0 - rib) * (head * 0.5 + tail * 0.12));
    }
    if (pid == 1) {
        // a tiled reveal: tiles switch on in a scattered order
        vec2 g = vec2(z, vs) / 0.62;
        vec2 cell = floor(g);
        vec2 f = abs(fract(g) - 0.5);
        float h = hash21(cell + vec2(seed * 13.7, seed * 3.1));
        float rev = smoothstep(h - 0.05, h + 0.05, life * 1.5);
        float tile = 1.0 - smoothstep(0.40 - fw * 1.6, 0.44 + fw * 1.6, max(f.x, f.y));
        float h2 = fract(h * 31.7);
        vec3 c = h2 < 0.65 ? cA : h2 < 0.92 ? cB : vec3(1.0);
        return c * tile * rev * (0.6 + 1.6 * fract(h * 7.3)) * (1.0 - rib * 0.6);
    }
    if (pid == 2) {
        // each bay a spectrum meter, segmented like LEDs, peaking white
        float lvl = saturate(eq * 1.1 + 0.05) * vc;
        float fill = 1.0 - smoothstep(lvl - fw, lvl + fw, vs);
        float seg = smoothstep(0.10, 0.16, fract(vs * 3.0)) * smoothstep(1.0, 0.94, fract(vs * 3.0));
        float cap = vtLine(vs - lvl - 0.08, 0.04, fw);
        // alternate bays take the two colours (mixing complements would grey them)
        vec3 c = mod(bay, 2.0) < 1.0 ? cA : cB;
        c = mix(c, vec3(1.0), 0.35 * smoothstep(0.75, 1.0, vs / vc));
        float top = smoothstep(lvl - 0.9, lvl, vs);
        return c * (fill * seg * (0.35 + 0.9 * top) + cap * 3.0) * (1.0 - rib * 0.7) + cB * rib * 0.2;
    }
    if (pid == 3) {
        // a scan plane races down the nave, leaving contour lines behind it
        float zf = zc + 2.0 + 34.0 * fract(bp);
        float d = z - zf;
        float slice = exp(-d * d * 40.0);
        float trail = d < 0.0 ? exp(d * 0.45) : 0.0;
        float cont = vtLine(fract(vs * 2.0 + 0.5) - 0.5, 0.05, fw * 2.0);
        return mix(cA, vec3(1.0), 0.4) * slice * 5.0 + cB * cont * trail * 1.4 + cA * trail * 0.08;
    }
    // chevrons scroll down the vault, pointing along the walk
    float w = z * 0.45 + vs * 0.55 - life * 2.0;
    float s = fract(w);
    float k = floor(w);
    float band = smoothstep(0.0, 0.04 + fw, s) * (1.0 - smoothstep(0.42 - fw, 0.46 + fw, s));
    vec3 c = mod(k, 2.0) < 1.0 ? cA : cB;
    return c * band * 1.4 * (1.0 - rib * 0.5) + c * rib * band * 1.6;
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

    // ---- the projection: the new pattern behind the wipe, the old beyond it ----
    float eq = bandAt(u, fract(bay * 0.0625 + 0.03));
    bool fresh = pos.z < S.wipe;
    vec3 L = fresh
        ? vtPattern(S.pNew, pos.z, vs, vc, side, bay, rib, fw, S.seed, S.life, S.bp, S.zc, eq, S.cA, S.cB)
        : vtPattern(S.pOld, pos.z, vs, vc, side, bay, rib, fw, S.seedOld, S.life + 1.0, S.bp, S.zc, eq, S.cOA, S.cOB);
    // the wipe front itself is a bright seam
    float wd = pos.z - S.wipe;
    L += mix(S.cA, vec3(1.0), 0.5) * exp(-wd * wd * 30.0) * 2.5 * step(S.wipe, S.zc + 45.0);
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

    // the stained glass, lit from outside, each pane breathing with its band
    float isWin = step(r.x - 0.02, pos.x) * step(0.5, -n.x);
    if (isWin > 0.5) {
        vec3 gl = vtGlass(pos.z, pos.y, sy, 1.0, gs);
        float pane = bandAt(u, fract(pos.y * 1.7 + pos.z * 0.31));
        col += gl * (0.9 + 1.4 * pane) * mix(2.2, 0.8, S.proj);
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

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float VT_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 vtFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * VT_RUN[32] + VT_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}


// The palette read once per pixel at its five stops and blended locally.
struct VtPalette { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

VtPalette vtPalLoad(VisualUniforms u) {
    VtPalette P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
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

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 sp = centered(uv, u.resolution);
    sp.y = -sp.y;
    float detail = osDetail(u);
    float grand = mix(0.85, 1.45, u.param0);
    float orn = mix(0.4, 1.4, u.param1);

    float cruise = mix(1.2, 4.0, u.param2);
    vec2 fl = vtFlight(u, cruise, 0.55 * mix(0.6, 1.4, u.param2));
    float zc = mod(fl.x, VT_WRAP);
    float rush = saturate((fl.y - 1.0) / 3.5);
    float lull = saturate(1.0 - fl.y);

    VtPalette P = vtPalLoad(u);
    float sec = u.beatCount / 16.0;
    float chorus = step(2.0, mod(floor(sec), 4.0));
    VtGlassSet gs;
    gs.warm = vtPal(P, 0.72);
    gs.cool = vtComp(vtPal(P, mix(0.7, 0.45, chorus)));
    gs.red = vtPal(P, 0.3);
    gs.gold = vtPal(P, 0.6);
    gs.ember = vtPal(P, 0.42);

    // ---- the show: a new pattern every two beats, a colour swap every beat ----
    float n = floor(u.beatCount);
    float bp = saturate(u.beatPhase);
    float k2 = floor(n / 2.0);
    VtShow S;
    S.pNew = vtPick(k2);
    S.pOld = vtPick(k2 - 1.0);
    S.life = (n - 2.0 * k2 + bp) * 0.5;
    float wf = smoothstep(0.0, 0.3, S.life);
    S.wipe = zc + 0.3 + 52.0 * wf * wf;
    S.bp = bp;
    S.zc = zc;
    S.seed = mod(k2, 97.0);
    S.seedOld = mod(k2 - 1.0, 97.0);
    vec3 warm = vtVivid(vtPal(P, mix(0.62, 0.8, chorus)));
    vec3 cool = vtVivid(vtComp(warm) + 0.02);
    float odd = mod(n, 2.0);
    // the swap eases in quickly so complements never meet as grey
    float sw = smoothstep(0.0, 0.06, bp);
    vec3 cNow = odd > 0.5 ? warm : cool;
    vec3 cPrev = odd > 0.5 ? cool : warm;
    S.cA = mix(cPrev, cNow, sw);
    S.cB = mix(cNow, cPrev, sw);
    S.cOA = mix(cNow, cPrev, sw);
    S.cOB = mix(cPrev, cNow, sw);
    // breakdown: the projectors black out; burst: the outline blazes
    S.proj = (0.08 + 0.92 * smoothstep(0.55, 1.15, fl.y)) * (0.8 + 0.45 * u.beat) * (0.8 + 0.4 * u.amplitude);
    S.outline = 0.12 + 0.9 * smoothstep(1.6, 3.5, fl.y) + 0.25 * u.bassImpact;

    // camera: slow sway, eased roll; audio never moves it
    float tw = mod(u.time, 600.0);
    vec4 rc = vtRoomAt(zc, grand);
    vec3 ro = vec3(0.3 * sin(tw * 0.17) * rc.x * 0.4, -0.15 + 0.06 * sin(tw * 0.13), zc);
    vec3 ta = vec3(0.35 * sin(tw * 0.17 + 0.8), 0.15 + 0.2 * sin(tw * 0.071), zc + 6.0);
    float fov = 1.2 - 0.25 * rush + 0.1 * lull;
    vec3 rd = osCamera(ro, ta, osBank(u, 0.12), fov, sp);
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

    // the projectors' light hangs faintly in the air of the nave
    float haze = 1.0 - exp(-min(tt, 40.0) * 0.04);
    col += (S.cA + S.cB) * haze * 0.006 * S.proj;
    // haze to cool black: the far hall vanishes into the dark
    float fog = 1.0 - exp(-tt * 0.06);
    col = mix(col, gs.cool * 0.006 + vec3(0.002), fog);

    col *= 1.0 - 0.3 * smoothstep(0.8, 1.9, length(sp));
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0015;
    return max(col, 0.0); // LINEAR HDR — post chain tonemaps
}
