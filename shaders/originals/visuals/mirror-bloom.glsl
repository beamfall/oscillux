// SPDX-License-Identifier: AGPL-3.0-only
// Mirror bloom.
// A kinetic mirror facade in a black studio: a wall of thousands of small
// hinged chrome sequins, packed in a honeycomb over black felt, that the
// music tilts like wind running through sequins. Each sequin is a real tilted,
// slightly domed metal disc: it is foreshortened as it tips, shows its bevelled
// edge, and mirrors a rig of hard-edged softboxes, point keys and a ring light
// round the lens, so a lit disc carries a crisp sliver of studio light and an
// unlit one goes black. The tilt field is a mirrored bloom: its lobes, rings
// and spirals are symmetric about the spine, so twin discs catch the same
// light and a Rorschach flower of glints opens across the wall. The spectrum
// barely swells the lobes by angle; every beat rolls a soft colour wave out
// from the heart of the bloom that faintly tints the discs it crosses in the beat's
// accent, gold and teal in turn, without brightening them; slow ripples and
// wind gusts drift glint bands across the wall, the bevelled rims catch the
// keys, a rare disc glints, and through every eight beats the next figure
// (petals, butterfly wings, a twin spiral, an iris) blooms out of the heart in
// a narrow re-forming ring. The lights hold steady through the
// beat, their colours drift slowly and never shimmer with the music, and their aim
// drifts slowly. The camera drifts slowly and steadily in
// front of the wall with shallow depth of field; audio moves the discs and
// their colour, never the camera or the overall brightness.
// param0 = Bloom Size ; param1 = Tilt ; param2 = Flutter


// The palette read without the library's per-beat and spectral-centroid hue
// nudge, so large lit areas never shimmer with the music; under the host's
// palette tour the cross-fade between palettes is spread over the whole tour
// step, so the colours change slowly.
vec3 mbPalStill(float t, VisualUniforms u) {
    if (u.palette.x >= 0.0) return palByIndex(t, int(floor(u.palette.x + 0.5)));
    int a = int(mod(floor(u.palette.z), 32.0));
    int b = int(mod(float(a + 1), 32.0));
    float blend = smoothstep(0.0, 1.0, fract(u.palette.z));
    return mix(palByIndex(t, a), palByIndex(t, b), blend);
}

// The palette read once at five fixed stops and blended locally.
struct MbPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

vec3 mbPal(MbPal P, float t) {
    t = fract(t) * 5.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    c = mix(c, P.c4, smoothstep(3.0, 4.0, t));
    return mix(c, P.c0, smoothstep(4.0, 5.0, t));
}

// Honeycomb cell: xy = offset from the cell centre, zw = centre (spacing 1).
vec4 mbHex(vec2 p) {
    const vec2 s = vec2(1.0, 1.7320508);
    vec4 hc = floor(vec4(p, p - vec2(0.5, 0.8660254)) / s.xyxy) + 0.5;
    vec4 h = vec4(p - hc.xy * s, p - (hc.zw + 0.5) * s);
    return dot(h.xy, h.xy) < dot(h.zw, h.zw) ? vec4(h.xy, hc.xy * s) : vec4(h.zw, (hc.zw + 0.5) * s);
}

// Figure parameters, blended between the four eight-beat figures.
struct MbFig { float lobes; float twist; float wings; float iris; float size; float spin; };

MbFig mbFigure(float k) {
    // k in [0, 4): 0 petals, 1 butterfly, 2 twin spiral, 3 iris
    MbFig f;
    f.lobes = k < 1.0 ? 3.0 : k < 2.0 ? 1.0 : k < 3.0 ? 2.0 : 6.0;
    f.twist = k < 2.0 ? 0.0 : k < 3.0 ? 1.6 : 0.0;
    f.wings = k < 1.0 ? 0.0 : k < 2.0 ? 1.0 : 0.0;
    f.iris = k < 3.0 ? 0.0 : 1.0;
    f.size = k < 1.0 ? 1.0 : k < 2.0 ? 1.1 : k < 3.0 ? 1.25 : 0.95;
    f.spin = 0.0;
    return f;
}

MbFig mbMix(MbFig a, MbFig b, float w) {
    MbFig f;
    f.lobes = mix(a.lobes, b.lobes, w);
    f.twist = mix(a.twist, b.twist, w);
    f.wings = mix(a.wings, b.wings, w);
    f.iris = mix(a.iris, b.iris, w);
    f.size = mix(a.size, b.size, w);
    f.spin = 0.0;
    return f;
}

// Height of the tilt field at q (bloom-centred, mirrored about x = 0). The
// discs tilt along its gradient. sb holds eight cached spectrum bands.
float mbHeight(vec2 q, MbFig f, float sb[8], float t, float bloomR, float flutter) {
    q.x = abs(q.x);
    float r = length(q);
    float a = atan2_(q.x, q.y + 1e-5);               // 0 at the top, pi at the bottom
    float aw = a + f.twist * r + f.spin;
    // the spectrum swells each lobe by angle
    float sx = clamp(a / 3.14159 * 7.0, 0.0, 6.999);
    int si = int(sx);
    float sp = mix(sb[si], sb[si + 1], sx - float(si));
    float R = bloomR * f.size * (0.96 + 0.02 * sp);
    float lobe = 0.5 + 0.5 * cos(f.lobes * 2.0 * aw);
    float petal = exp(-r * r / (R * R) * (1.4 - 0.9 * lobe));
    float h = 0.9 * petal * (0.55 + 0.45 * lobe);
    // butterfly: two great mirrored wings with eye spots
    // (an upper and a lower wing per side, a plateau with steep edges so the
    // outline catches the light, and an eye spot in each upper wing)
    float up = exp(-pow((a - 1.05) / 0.55, 2.0));
    float lo = exp(-pow((a - 2.25) / 0.42, 2.0));
    float Rw = R * (0.25 + 1.35 * up + 0.85 * lo);
    float rw = r / max(Rw, 1e-3);
    float wing = 1.0 / (1.0 + rw * rw * rw * rw * rw * rw);
    vec2 eq = q - vec2(0.62, 0.42) * R;
    wing -= 0.45 * exp(-dot(eq, eq) * 22.0 / (R * R));
    h += f.wings * (0.95 * wing - 0.85 * petal * (0.55 + 0.45 * lobe));
    // iris: fine radial spokes round a pupil
    h += f.iris * 0.12 * cos(a * 18.0 + r * 1.5) * smoothstep(0.25, 0.6, r) * petal;
    // spectrum ripples running out of the heart
    h += 0.05 * sin(r * 7.0 - t * 0.3) * (0.34 + 0.02 * sb[1]) * exp(-0.35 * r);
    h += 0.035 * sin(r * 13.0 - t * 0.45) * (0.24 + 0.02 * sb[5]) * exp(-0.45 * r);
    // wind gusts roll slow glint bands across the outer wall, so the whole
    // facade shimmers, not just the bloom
    float gust = sin(r * 2.3 - t * 0.2 + 0.8 * sin(a * 2.0 + t * 0.05)) + 0.6 * sin(q.y * 3.1 + t * 0.13);
    h += 0.08 * gust * smoothstep(0.7, 1.6, r / max(bloomR, 0.5)) * (0.78 + 0.02 * sb[0] + 0.02 * sb[3]);
    // wind flutter, mirrored too
    h += flutter * 0.18 * (vnoise(q * 1.3 + vec2(0.0, t * 0.06)) - 0.5);
    return h;
}


// The studio as a mirror sees it. r is the reflected ray, v the direction back
// to the eye, k the point-key sharpness and edge the softbox edge width (both
// widen with the pixel footprint and the defocus, so the glints never alias).
struct MbRig {
    vec3 dA; vec3 dA2; vec3 dB; vec3 dB2; vec3 dC;
    vec3 cWarm; vec3 cWarm2; vec3 cCool; vec3 cKey; vec3 cRing;
    vec2 box; float bar; float ringRho; float ringA;
};

// The point keys alone, as lobes of sharpness k.
vec3 mbKeys(vec3 r, MbRig L, float k) {
    vec3 c = L.cWarm * (exp(k * (dot(r, L.dA) - 1.0)) + exp(k * (dot(r, L.dA2) - 1.0)));
    c += L.cCool * (exp(k * (dot(r, L.dB) - 1.0)) + exp(k * (dot(r, L.dB2) - 1.0)));
    return c + L.cKey * 0.8 * exp(k * 0.5 * (dot(r, L.dC) - 1.0));
}

// The area lights: softboxes, a strip bar and the ring light, over a faint studio gradient so an unlit disc still reads as metal.
vec3 mbEnv(vec3 r, vec3 v, MbRig L, float edge) {
    vec3 c = mix(L.cWarm2 * 0.006, L.cCool * 0.014, smoothstep(-0.5, 0.6, r.y));
    vec2 s = r.xy / max(-r.z, 0.2);
    float sx = abs(s.x);
    // tall softboxes left and right, mirrored, hot along their centre line
    float dx = abs(sx - L.box.x);
    float bx = smoothstep(L.box.y + edge, L.box.y - edge, dx) * smoothstep(0.45 + edge, 0.45 - edge, abs(s.y + 0.05));
    c += L.cWarm2 * bx * (0.7 + 1.3 * exp(-dx * dx / (0.09 * L.box.y * L.box.y)));
    // an overhead strip bar
    float hy = abs(s.y - L.bar);
    c += L.cCool * 1.3 * smoothstep(0.022 + edge, 0.022 - edge, hy) * smoothstep(0.7 + edge, 0.7 - edge, sx);
    // the ring light round the lens
    float cr = sqrt(max(2.0 * (1.0 - dot(r, v)), 0.0));
    float rw = 0.014 + edge;
    float rg = (cr - L.ringRho) / rw;
    c += L.cRing * L.ringA * exp(-rg * rg);
    return c;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float t = mod(u.time, 600.0);
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));

    MbPal P = MbPal(mbPalStill(0.0, u), mbPalStill(0.2, u), mbPalStill(0.4, u), mbPalStill(0.6, u), mbPalStill(0.8, u));

    float sb[8];
    for (int i = 0; i < 8; i++) sb[i] = bandAt(u, (float(i) + 0.5) / 8.0);

    // ---- camera: a slow, steady drift in front of the wall ----
    float s = t * 0.1;
    float yaw = 0.20 * sin(s * 0.19) + 0.07 * sin(s * 0.071 + 1.3);
    float pitch = 0.10 * sin(s * 0.13 + 0.4);
    float dist = 3.7 + 0.5 * sin(s * 0.087 + 2.0);
    vec3 ta = vec3(0.35 * sin(s * 0.053), 0.15 + 0.15 * sin(s * 0.061), 0.0);
    vec3 ro = ta + dist * vec3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch));
    float fov = 1.55;
    vec3 rd = osCamera(ro, ta, 0.0, fov, p);
    float pix = 2.0 / (u.resolution.y * fov);

    // ---- beat clock, figures and accents ----
    float bc = u.beatCount + saturate(u.beatPhase);
    float sect = floor(bc / 8.0);
    float kCur = mod(sect, 4.0);
    float kNext = mod(sect + 1.0, 4.0);
    // the next figure blooms out of the heart across the section, so only a
    // narrow ring of discs is re-forming at any moment
    float morph = (bc - sect * 8.0) / 8.0;
    float front = -0.12 + morph * 4.4;
    MbFig figA = mbFigure(kCur);
    MbFig figB = mbFigure(kNext);
    float bph = saturate(u.beatPhase);
    float warmBeat = mod(floor(u.beatCount), 2.0) < 0.5 ? 1.0 : 0.0;
    float bloomR = mix(1.3, 2.0, u.param0) * (0.99 + 0.01 * u.level);
    float tiltGain = mix(0.25, 0.6, u.param1);
    float flutter = mix(0.3, 1.6, u.param2) * (0.8 + 0.03 * u.level);
    // the beat's colour wave: a ring rolling out of the heart that recolours
    // the discs it crosses in the beat's accent without brightening them
    float ringR = 0.2 + bph * 3.6;
    float ringA = (1.0 - bph) * smoothstep(0.0, 0.08, bph);
    // the lobes open and close round the spine, mirrored, on a slow swing
    float spin = 0.25 * sin(t * 0.06);

    // stage lights behind the camera in mirrored pairs; their aim drifts
    // slowly and the rig eases to a new aim as each figure blooms
    float rig = hash11(sect * 3.17 + 1.0);
    float rigN = hash11((sect + 1.0) * 3.17 + 1.0);
    float rg = mix(rig, rigN, smoothstep(0.0, 1.0, morph));
    vec4 aim = 0.5 + 0.5 * sin(t * vec4(0.031, 0.023, 0.027, 0.019) + vec4(0.4, 2.1, 4.0, 5.3));
    float sw = t * 0.12;
    vec2 la = vec2(0.2 + 0.55 * aim.x + 0.06 * rg, -0.05 + 0.3 * aim.y);
    vec2 lb = vec2(0.05 + 0.6 * aim.z + 0.04 * cos(sw * 1.1), -0.3 + 0.24 * aim.w);
    vec2 lc = vec2(0.0, 0.30 + 0.08 * sin(sw * 0.6));
    // the warm pair walks red to gold and the cool pair teal to blue as the
    // mix brightens; the key is the palette's last stop
    float hueW = saturate(0.45 + 0.25 * sin(t * 0.05));
    vec3 cWarm = mix(P.c0, P.c1, hueW) * 1.35;
    vec3 cWarm2 = mix(P.c0, P.c1, 1.0 - hueW);
    vec3 cCool = mix(P.c2, P.c3, saturate(0.5 + 0.4 * cos(t * 0.09))) * 1.35;
    vec3 cKey = P.c4 * (0.95 + 0.1 * u.level);


    MbRig L;
    L.dA = normalize(vec3(la.x, la.y, -1.0));
    L.dA2 = normalize(vec3(-la.x, la.y, -1.0));
    L.dB = normalize(vec3(lb.x, lb.y, -1.0));
    L.dB2 = normalize(vec3(-lb.x, lb.y, -1.0));
    L.dC = normalize(vec3(lc.x, lc.y, -1.0));
    L.cWarm = cWarm;
    L.cWarm2 = cWarm2 * (0.95 + 0.1 * u.level);
    L.cCool = cCool;
    L.cKey = cKey;
    L.cRing = mix(P.c2, P.c1, 0.5);
    L.box = vec2(0.5 + 0.4 * aim.y + 0.05 * sin(sw * 0.7), 0.065);
    L.bar = 0.42 + 0.18 * aim.x;
    L.ringRho = 0.16 + 0.12 * u.param1 + 0.05 * sin(t * 0.31);
    L.ringA = 1.0;

    // ---- the facade: discs stand a little in front of the black felt ----
    const float SP = 0.1;                                // disc pitch
    const float ZD = -0.3 * SP;                            // disc hinge plane
    float rz = max(rd.z, 0.05);
    float th = (ZD - ro.z) / rz;
    vec3 w3 = ro + rd * th;
    vec2 w = w3.xy;
    float foot = th * pix / max(rz, 0.25);                // pixel footprint on the wall
    float focus = length(ta - ro);
    float coc = abs(th - focus) * 0.009;                   // defocus blur on the wall
    float blur = max(foot, coc);

    vec4 hx = mbHex(w / SP);
    vec2 cell = hx.zw * SP;
    float hid = hash21(hx.zw + 17.0);
    float hid2 = hash21(hx.zw + 41.3);

    vec2 bc0 = vec2(0.0, 0.2);
    vec2 q = cell - bc0;
    float e = 0.5 * SP;
    MbFig fig = mbMix(figA, figB, smoothstep(0.0, 0.12, front - length(q)));
    fig.spin = spin;
    float h0 = mbHeight(q, fig, sb, t, bloomR, flutter);
    float hX = mbHeight(q + vec2(e, 0.0), fig, sb, t, bloomR, flutter);
    float hY = mbHeight(q + vec2(0.0, e), fig, sb, t, bloomR, flutter);
    vec2 g = vec2(hX - h0, hY - h0) / e;
    // each disc also twinkles on its hinge
    // each disc hangs a little askew and flutters on its hinge, so
    // neighbours sparkle apart instead of reading as a halftone screen
    vec2 jit = 0.04 * vec2(sin(t * (0.12 + 0.12 * hid) + hid2 * 6.28), cos(t * (0.1 + 0.12 * hid2) + hid * 6.28));
    vec2 skew = 0.05 * (vec2(hid, hid2) - 0.5);
    vec2 tilt = g * tiltGain + skew + jit * 0.7;
    tilt *= 0.6 / max(0.6, length(tilt));
    vec3 n = normalize(vec3(tilt, -1.0));

    // the eye ray against the tilted disc's own plane: the disc foreshortens
    // to an ellipse as it tips and opens a black gap to the felt behind it
    vec3 c3 = vec3(cell, ZD);
    float den = min(dot(rd, n), -0.05);
    vec3 pd = ro + rd * (dot(c3 - ro, n) / den);
    vec3 lp = pd - c3;
    float dd = length(lp);
    float rr = 0.45 * SP;
    float aw = max(blur * 1.2, 0.6 * foot);
    float disc = smoothstep(rr + aw, rr - aw, dd);

    // the face is a flat mirror with a slightly pillowed centre: the area
    // lights fill a whole disc as it tips into them, and the point keys sit
    // on it as a sharp hot glint whose place slides with the tilt. Both
    // flatten where the disc is too small or blurred to resolve.
    float res = saturate(1.6 - blur / SP * 2.5);
    vec3 v = -rd;
    vec3 nf = normalize(n - lp / rr * (0.02 * res));
    vec3 ng = normalize(n - lp / rr * (0.12 * res));
    float soft = 1.0 / (1.0 + 60.0 * blur * blur / (SP * SP));
    float edge = 0.008 + 0.05 * aw / rr + 0.04 * (1.0 - soft);
    vec3 env = mbEnv(reflect(rd, nf), v, L, edge);
    vec3 rgl = reflect(rd, ng);
    env += mbKeys(rgl, L, 1500.0 * soft + 120.0) * (9.0 * soft + 0.4);
    env += mbKeys(reflect(rd, nf), L, 220.0) * 0.5;
    // chrome with a few anodised discs, gold and violet; Fresnel to white
    vec3 f0 = vec3(0.9);
    f0 = mix(f0, P.c1 * 0.95 + 0.05, 0.45 * step(0.86, hid));
    f0 = mix(f0, P.c4 * 0.9 + 0.1, 0.4 * step(hid, 0.12));
    float fr = pow(1.0 - saturate(dot(nf, v)), 5.0);
    vec3 face = env * (f0 + (1.0 - f0) * fr);

    // the bevelled edge catches the keys from another angle
    float rimW = 0.025 * SP + aw;
    float rim = exp(-pow((dd - rr + 0.03 * SP) / rimW, 2.0)) * disc * res;
    vec3 ldir = lp / max(dd, 1e-4);
    vec3 nr = normalize(n + ldir * 0.9);
    vec3 rimC = mbKeys(reflect(rd, nr), L, 160.0) * 2.0;

    // glitter: on the treble a few discs flick into the key and flash
    float gk = floor(t * 2.0);
    float gp = fract(t * 2.0);
    float gh = hash21(hx.zw * 1.31 + vec2(mod(gk, 97.0) * 7.13, mod(gk, 89.0) * 3.7));
    float glit = step(1.0 - 0.0008 * (0.6 + 0.4 * u.level), gh) * sin(gp * 3.14159);
    vec3 hot = lp - n * dot(lp, n);
    float hs = 0.22 * rr + aw;
    face += mix(cKey, vec3(1.0), 0.5) * 0.7 * glit * exp(-dot(hot, hot) / (hs * hs)) * res;

    // black felt between the discs, with the disc's shadow darkening it further
    vec3 backing = vec3(0.0012) + (cWarm + cCool) * 0.0015 * smoothstep(rr * 0.9, rr * 1.15, length(w - cell));
    vec3 col = mix(backing, face + rimC * rim, disc);
    // defocused discs: blend toward their mean so far discs never shimmer
    float avg = saturate(blur / SP * 1.4 - 0.25);
    col = mix(col, env * f0 * 0.72 + backing * 0.28, avg);

    // the beat's colour wave: discs on the ring take the accent, gold and
    // teal in turn, at their own luminance
    float rq = (length(q) - ringR) * 5.0;
    vec3 acc = mix(P.c2, P.c1, warmBeat);
    vec3 tint = acc * (dot(col, vec3(0.2126, 0.7152, 0.0722)) / max(dot(acc, vec3(0.2126, 0.7152, 0.0722)), 1e-3));
    col = mix(col, tint, 0.15 * ringA * exp(-rq * rq));

    // mild vignette, IGN dither against banding
    col *= 1.0 - 0.28 * dot(p * 0.55, p * 0.55);
    col += (ign - 0.5) * 0.003;
    return max(col, vec3(0.0));
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
