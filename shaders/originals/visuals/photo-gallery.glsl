// SPDX-License-Identifier: AGPL-3.0-only
// Photo gallery.
// A slow tracking shot along a dark hall of floating holographic photo cards.
// Every card is a glass print of the photo with a diffraction foil that
// throws a rainbow sheen as it turns; spotlights pour shafts of light through
// the haze onto each card, and the black mirror floor doubles the whole hall.
// Cards hang in rows at four depths, so they slide past in parallax. The
// glide is slow and steady, easing only a little faster on the shared 32-beat
// speed profile's builds and bursts, with an eased bank. Audio drives the
// light gently: each card's foil and rim follow the level and a little of a
// spectrum band, the beat's card glows a touch brighter, and a soft pulse
// runs down the floor strips; nothing large brightens on the beat.
// param0 = Cards ; param1 = Drift ; param2 = Edges

const float PG_FLOOR = -1.35;

float pgSq(float x) { return x * x; }

// The palette read once at five fixed stops and blended locally.
struct PgPal { vec3 a; vec3 b; vec3 c; vec3 d; vec3 e; vec3 accent; vec3 keyLight; };

vec3 pgPal(PgPal P, float t) {
    float x = fract(t) * 5.0;
    vec3 c = mix(P.a, P.b, smoothstep(0.5, 1.5, x));
    c = mix(c, P.c, smoothstep(1.5, 2.5, x));
    c = mix(c, P.d, smoothstep(2.5, 3.5, x));
    c = mix(c, P.e, smoothstep(3.5, 4.5, x));
    return mix(c, P.a, smoothstep(4.5, 5.0, x));
}

// Row r: depth, spacing along the hall, sideways offset.
vec3 pgRow(float r, float density) {
    float z = 2.6 + r * 2.6 + r * r * 0.45;
    float per = (2.9 + r * 0.5) * mix(1.35, 0.85, density);
    return vec3(z, per, r * 0.37 * per);
}

// Card c of a row on tier 0 (low) or 1 (high, set between): centre, yaw.
vec4 pgCard(float r, float c, float tier, vec3 row, float t, float drift) {
    float h = hash21(vec2(c * 1.37 + 3.1 + tier * 17.0, r * 7.7 + 1.9));
    float h2 = hash21(vec2(c * 2.11 + 9.4, r * 3.3 + 5.2 + tier * 11.0));
    float x = row.z + (c + 0.5 * tier) * row.y + (h - 0.5) * row.y * 0.3;
    float y = (h2 - 0.5) * (0.8 + 0.3 * r) - 0.2 + tier * (1.55 + 0.35 * r)
            + 0.12 * drift * sin(t * 0.23 + h * 6.28);
    float z = row.x + (h2 - 0.5) * 0.8 + tier * 0.6;
    float yaw = (h - 0.5) * 0.7 + 0.22 * drift * sin(t * 0.17 + h2 * 6.28);
    return vec4(x, y, z, yaw);
}

// Nearest card along the ray. Returns t (or -1) and fills the card's local
// coordinates (cl: -1..1 across, -1..1 up), its normal and identity.
float pgTrace(vec3 ro, vec3 rd, float t0, float t1, vec2 half_, float density, float drift,
              int rows, out vec2 cl, out vec3 nrm, out vec3 id) {
    cl = vec2(0.0); nrm = vec3(0.0, 0.0, -1.0); id = vec3(-1.0);
    for (int r = 0; r < 4; r++) {
        if (r >= rows) break;
        float fr = float(r);
        vec3 row = pgRow(fr, density);
        float tz = (row.x - ro.z) / max(rd.z, 1e-3);
        if (tz < 0.0) continue;
        float c0 = floor((ro.x + rd.x * tz - row.z) / row.y + 0.5);
        float best = 1e4;
        for (int k = 0; k < 6; k++) {
            float tier = k < 3 ? 0.0 : 1.0;
            float c = c0 + float(k) - 1.0 - 3.0 * tier - 0.5 * tier;
            c = floor(c + 0.5);
            vec4 cd = pgCard(fr, c, tier, row, t0, drift);
            vec3 n = vec3(sin(cd.w), 0.0, -cos(cd.w));
            vec3 tg = vec3(cos(cd.w), 0.0, sin(cd.w));
            float dn = dot(rd, n);
            if (abs(dn) < 1e-4) continue;
            float th = dot(cd.xyz - ro, n) / dn;
            if (th <= 0.0 || th >= best || th > t1) continue;
            vec3 hp = ro + rd * th - cd.xyz;
            vec2 q = vec2(dot(hp, tg), hp.y) / half_;
            if (abs(q.x) > 1.0 || abs(q.y) > 1.0) continue;
            best = th; cl = q; nrm = dn < 0.0 ? n : -n; id = vec3(fr, c + 101.0 * tier, dn < 0.0 ? 1.0 : 0.0);
        }
        if (best < 1e3) return best;
    }
    return -1.0;
}

vec3 pgPhoto(vec2 q, float flip) {
    vec2 iuv = vec2(0.5 + 0.5 * q.x * flip, 0.5 - 0.5 * q.y);
    vec3 ph = max(IMG(clamp(iuv, vec2(0.002), vec2(0.998))).rgb, vec3(0.0));
    return ph * ph * (0.7 + 0.6 * ph);   // stored values to linear light, a touch more contrast
}

// Shade a card hit: glass print, holographic foil, edge light, spotlight.
vec3 pgShade(vec3 rd, vec2 q, vec3 n, vec3 id, VisualUniforms u, float edgeAmt, PgPal P, vec3 fogC) {
    float key = hash21(id.xy + 0.7);
    float b = bandAt(u, fract(key * 3.7 + id.y * 0.13));
    float pick = step(abs(mod(u.beatCount, 7.0) - mod(id.y + id.x * 3.0, 7.0)), 0.5);
    float lift = pick * 0.3;
    vec3 v = -rd;
    float ndv = saturate(dot(n, v));
    vec3 photo = pgPhoto(q, id.z > 0.5 ? 1.0 : -1.0);
    // spotlight from above: brighter at the top of the card
    float spot = 0.75 + 0.35 * q.y;
    vec3 col = photo * spot * (1.0 + 0.08 * lift + 0.05 * u.level);
    // holographic foil: a narrow rainbow band sweeps over the print as the card
    // turns against the camera; the hue runs through the full spectrum across it
    float g = dot(q, vec2(0.8, 0.6)) * 1.3 + (1.0 - ndv) * 3.0 + dot(v.xy, vec2(2.0, -1.4));
    float sp = fract(g * 0.4) - 0.5;
    float sheen = exp(-sp * sp * 150.0);
    vec3 foil = hsv2rgb(vec3(fract(sp * 2.2 + key + 0.1 * u.spectralCentroid), 0.95, 1.0));
    foil = mix(foil, pgPal(P, g * 0.5 + key), 0.25);
    float lum = luma(photo);
    float onPrint = 0.3 + 0.7 * smoothstep(0.02, 0.4, lum);
    // Highlights are tinted through the film instead of washed over: the
    // additive sheen fades out on bright print, a multiplicative tint takes over.
    float hiL = smoothstep(0.2, 0.75, lum);
    col *= mix(vec3(1.0), 0.45 + 0.85 * foil, sheen * hiL * 0.55);
    col += foil * onPrint * (1.0 - 0.8 * hiL) * (0.012 + sheen * (0.35 + 0.2 * b + 0.15 * lift));
    // the foil darkens the print a little either side of the band, so it reads as a film
    col *= 1.0 - 0.12 * exp(-sp * sp * 14.0) * (1.0 - sheen);
    // glass: fresnel reflection of the dark hall and a hard spot glint
    float fres = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
    col = mix(col, fogC * 0.25, fres * 0.25);
    vec3 hv = normalize(normalize(vec3(0.25, 1.0, -0.35)) + v);
    col += vec3(1.0, 0.95, 0.9) * pow(saturate(dot(n, hv)), 400.0) * 1.6;
    // lit glass edge
    vec2 e = 1.0 - abs(q);
    float edge = 1.0 - smoothstep(0.0, 0.025, min(e.x * 1.0, e.y * 1.6));
    // lit glass edge: the photo's complementary accent on the beat's card, palette elsewhere
    vec3 rim = mix(pgPal(P, key), P.accent, 0.35 + 0.65 * lift);
    col += rim * edge * edgeAmt * (0.75 + 0.3 * b + 0.4 * lift);
    return col;
}

// Spotlight shafts: cones from the ceiling onto each card of a row, seen
// where the ray crosses that row's plane in front of the hit.
float pgShafts(vec3 ro, vec3 rd, float tHit, float density, float drift, float t, int rows) {
    float s = 0.0;
    for (int r = 0; r < 4; r++) {
        if (r >= rows) break;
        float fr = float(r);
        vec3 row = pgRow(fr, density);
        float tz = (row.x - ro.z) / max(rd.z, 1e-3);
        if (tz < 0.0 || tz > tHit) continue;
        vec3 p = ro + rd * tz;
        float c0 = floor((p.x - row.z) / row.y + 0.5);
        for (int k = -1; k <= 1; k++) {
            vec4 cd = pgCard(fr, c0 + float(k), 0.0, row, t, drift);
            float above = p.y - cd.y;
            float wdt = 0.35 + 0.22 * max(3.0 - above, 0.0);
            float cone = exp(-pgSq((p.x - cd.x) / wdt) * 2.0);
            s += cone * smoothstep(-0.6, 0.5, above) * smoothstep(4.0, 0.5, above) * (0.6 + 0.4 / (1.0 + fr));
        }
    }
    return s;
}

// Out-of-focus motes drifting in the haze: soft discs with a brighter rim,
// three layers sliding past at their own parallax.
vec3 pgBokeh(vec2 p, float camX, VisualUniforms u, int layers, PgPal P) {
    vec3 acc = vec3(0.0);
    for (int l = 0; l < 3; l++) {
        if (l >= layers) break;
        float fl = float(l);
        float sc = 2.2 + fl * 1.6;
        vec2 q = p * sc + vec2(camX * (0.9 - 0.25 * fl) * sc * 0.35, 0.04 * u.time * (1.0 + fl));
        vec2 cell = floor(q);
        vec2 h = hash22(cell + fl * 19.0);
        if (h.x > 0.16 + 0.06 * fl) continue;
        vec2 f = q - cell - 0.5 - (h - 0.5) * 0.4;
        float rad = 0.22 + 0.16 * h.y;
        float d = length(f) / rad;
        float disc = smoothstep(1.0, 0.8, d) * (0.45 + 0.55 * smoothstep(0.5, 0.95, d));
        float b = bandAt(u, fract(h.y * 5.3));
        vec3 bc = h.y > 0.55 ? P.accent : pgPal(P, h.x * 7.1 + 0.3);
        acc += bc * disc * (0.03 + 0.02 * b) / (1.0 + fl * 0.6);
    }
    return acc;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    p.y = -p.y;
    float detail = osDetail(u);
    float t = mod(u.time, 600.0);
    float density = u.param0;
    float drift = mix(0.4, 1.5, u.param1);
    float edgeAmt = mix(0.4, 1.6, u.param2);
    vec2 isz = max(IMGSIZE, vec2(1.0));
    float ia = clamp(isz.x / isz.y, 0.5, 2.4);
    vec2 half_ = vec2(1.0, 1.0 / ia);
    int rows = detail > 0.5 ? 4 : 3;

    // camera: a tracking glide along the hall on the shared speed profile
    vec2 fl = osFlight(u, 0.0, 0.006);
    fl.x += 0.09 * u.time;

    float rush = saturate((fl.y - 1.0) / 3.5);
    vec3 ro = vec3(fl.x, -0.25 + 0.12 * sin(t * 0.07), 0.0);
    vec3 ta = ro + vec3(1.1 + 0.12 * rush, 0.25 + 0.05 * sin(t * 0.05), 6.0);
    vec3 rd = osCamera(ro, ta, osBank(u, 0.04), 1.55 - 0.03 * rush, p);


    // the photo's key colour from nine fixed taps, weighted toward saturated
    // pixels; the accent is its complement, kept saturated and bright
    vec3 kAcc = vec3(0.0);
    float kW = 0.0;
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        vec2 tuv = vec2(0.18 + 0.32 * mod(fi, 3.0), 0.18 + 0.32 * floor(fi / 3.0));
        vec3 c = max(IMG(tuv).rgb, vec3(0.0));
        float w = 0.04 + max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
        kAcc += c * w;
        kW += w;
    }
    vec3 keyC = kAcc / max(kW, 1e-4);
    float kHi = max(keyC.r, max(keyC.g, keyC.b));
    float kLo = min(keyC.r, min(keyC.g, keyC.b));
    float kSat = (kHi - kLo) / max(kHi, 1e-3);
    vec3 keyHue = (keyC - kLo) / max(kHi - kLo, 1e-3);
    vec3 P0 = palVisual(0.1, u);
    vec3 P1 = palVisual(0.3, u);
    vec3 P2 = palVisual(0.5, u);
    vec3 P3 = palVisual(0.7, u);
    vec3 P4 = palVisual(0.9, u);
    vec3 accent = mix(P2, (vec3(1.0) - keyHue) * 1.4, smoothstep(0.08, 0.3, kSat));
    vec3 keyLight = mix(vec3(1.0, 0.95, 0.9), keyHue, 0.45 * smoothstep(0.08, 0.3, kSat));
    PgPal P = PgPal(P0, P1, P2, P3, P4, accent, keyLight);
    vec3 fogC = palRoleFog(0.3, u);
    vec3 col = vec3(0.0);
    vec2 cl; vec3 n; vec3 id;
    float th = pgTrace(ro, rd, t, 60.0, half_, density, drift, rows, cl, n, id);
    float tFloor = rd.y < -1e-3 ? (PG_FLOOR - ro.y) / rd.y : 1e4;
    float tEnd;
    if (th > 0.0 && th < tFloor) {
        col = pgShade(rd, cl, n, id, u, edgeAmt, P, fogC);
        tEnd = th;
    } else if (tFloor < 60.0) {
        // black mirror floor: reflect the hall, rippled, with spot pools
        vec3 fp = ro + rd * tFloor;
        vec2 rip = vec2(vnoise(fp.xz * 2.5 + vec2(t * 0.2, 0.0)), vnoise(fp.zx * 2.5 - vec2(0.0, t * 0.15))) - 0.5;
        vec3 rr = reflect(rd, vec3(0.0, 1.0, 0.0));
        rr = normalize(rr + vec3(rip.x, 0.0, rip.y) * 0.012);
        float fres = 0.08 + 0.92 * pow(1.0 - saturate(-rd.y), 5.0);
        vec3 rc = fogC * 0.02;
        // the lowest detail keeps the mirror, with only the two nearest rows in it
        vec2 cl2; vec3 n2; vec3 id2;
        float t2 = pgTrace(fp, rr, t, 40.0, half_, density, drift, detail > 0.25 ? rows : 2, cl2, n2, id2);
        if (t2 > 0.0) rc = mix(pgShade(rr, cl2, n2, id2, u, edgeAmt, P, fogC) * exp(-t2 * 0.35), fogC * 0.04, saturate(t2 / 20.0));
        if (detail > 0.25) rc += fogC * 0.05 * pgShafts(fp, rr, t2 > 0.0 ? t2 : 40.0, density, drift, t, rows);
        col = rc * (0.22 + 0.6 * fres);
        // spot pools on the floor under the near rows
        float pool = 0.0;
        for (int r = 0; r < 3; r++) {
            vec3 row = pgRow(float(r), density);
            float c0 = floor((fp.x - row.z) / row.y + 0.5);
            vec4 cd = pgCard(float(r), c0, 0.0, row, t, drift);
            pool += exp(-(pgSq(fp.x - cd.x) * 1.4 + pgSq(fp.z - cd.z) * 2.5));
        }
        col += keyLight * P.d * pool * (0.07 + 0.01 * u.level);
        // accent light strips set in the floor between the rows: fixed dashes
        // that stream past with the glide, and a pulse shot down them on each beat
        float pxA = tFloor * 2.0 / (max(u.resolution.y, 1.0) * 1.5) / max(-rd.y, 0.04);
        float bp = saturate(u.beatPhase);
        for (int s = 0; s < 3; s++) {
            float zl = s == 0 ? 1.35 : s == 1 ? 4.1 : 7.6;
            float w = 0.025 + pxA;
            float line = exp(-pgSq((fp.z - zl) / w)) * (0.025 / w);
            float dash = 0.35 + 0.65 * smoothstep(0.2, 0.0, abs(fract(fp.x * 0.25 + float(s) * 0.33) - 0.5) - 0.3);
            float pulse = exp(-pgSq(fp.x - ro.x - 1.5 - 16.0 * bp) * 0.6) * (1.0 - bp) * 0.4;
            float lit = dash * (0.3 + 0.1 * u.level + 0.12 * bandAt(u, 0.1 + 0.3 * float(s))) + 0.5 * pulse;
            col += accent * line * lit * exp(-tFloor * 0.04) * 2.2;
            // and their glow on the wet floor around them
            col += accent * exp(-abs(fp.z - zl) * 5.0) * lit * 0.08 * exp(-tFloor * 0.04);
        }
        tEnd = tFloor;
    } else {
        col = fogC * 0.03 * (1.0 + rd.y);
        tEnd = 60.0;
    }

    // depth haze and the spotlight shafts in it
    float fogAmt = 1.0 - exp(-tEnd * 0.06);
    col = mix(col, fogC * 0.03, fogAmt);
    float sh = pgShafts(ro, rd, tEnd, density, drift, t, rows);
    col += mix(P3, keyLight, 0.6) * sh * (0.08 + 0.02 * u.level);
    col += pgBokeh(p, ro.x, u, detail > 0.5 ? 3 : 1, P);
    // a faint glow high in the hall
    col += fogC * 0.025 * smoothstep(0.0, 0.6, p.y + 0.2);
    col *= 0.45 + 0.55 * smoothstep(1.9, 0.5, length(p * vec2(0.8, 1.0)));
    return col;   // linear HDR; the host tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
