// SPDX-License-Identifier: AGPL-3.0-only
// Crystal.
// A macro product shot: a large brilliant-cut gem floats over black lacquer
// in a dark studio. An overhead softbox, a ring light and two equaliser strip
// lights (the spectrum) surround it; the gem bends them through several
// internal bounces with dispersion at every exit, so its fire changes as it
// turns. Below, the light it focuses lands as spectral caustic streaks, and
// defocused studio lights hang in the dark behind. The camera circles the
// stone in a slow, steady orbit with a gentle dolly, and a laser's spectrum
// fan drifts round it about once a minute. Audio drives light only: the
// level, shaped by the spectrum, lights the strips and the fan rays; the
// level with only a faint swell on each beat lights the ring, the gem's heart
// and the caustics, and the level softly lifts the glints and inner fractures. The gem is
// an exact convex polytope (no marching), so facets stay crisp at every
// detail level.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 = Facet Count ; param1 = Dispersion ; param2 = Fracture

// The palette read: the visual's own palette (13) with no beat or spectral
// nudge and no palette tour, so the host's vivid tour never swells the light;
// a host's manifest palette still replaces it. The fog tint is rebuilt on it.
vec3 crPalSteady(float t, VisualUniforms u) { return osPalCalm(t, 13, u); }
vec3 crPalSteadyFog(float t, VisualUniforms u) {
    vec3 c = crPalSteady(t, u);
    return mix(vec3(luma(c) * 0.62), c, 0.42);
}

const float CR_FLOOR = -1.25;

// Ray against the convex gem: returns (tEnter, tExit), the entry normal and
// the exit normal. Rings of planes: table, crown mains, crown stars, girdle,
// pavilion mains and pavilion halves, each built by rotating its first normal
// around y.
vec2 crHit(vec3 ro, vec3 rd, int N, vec2 rot, vec2 half_, out vec3 nEnter, out vec3 nExit) {
    float tin = -1e4;
    float tout = 1e4;
    nEnter = vec3(0.0, 1.0, 0.0);
    nExit = vec3(0.0, 1.0, 0.0);
    for (int k = 0; k < 6; k++) {
        // ring: (sin tilt, cos tilt with sign, plane offset, half-step flag)
        vec4 rg = k == 0 ? vec4(0.0, 1.0, 0.36, 0.0)          // table
                : k == 1 ? vec4(0.566, 0.824, 0.607, 0.0)      // crown mains, 34.5 deg
                : k == 2 ? vec4(0.669, 0.743, 0.690, 1.0)      // crown stars, 42 deg
                : k == 3 ? vec4(1.0, 0.0, 0.985, 1.0)          // girdle
                : k == 4 ? vec4(0.653, -0.757, 0.676, 0.0)     // pavilion mains, 40.75 deg
                :          vec4(0.690, -0.724, 0.695, 1.0);    // pavilion halves
        vec2 az = rg.w > 0.5 ? half_ : vec2(1.0, 0.0);
        int cnt = k == 0 ? 1 : N;
        for (int i = 0; i < 12; i++) {
            if (i >= cnt) break;
            vec3 n = vec3(rg.x * az.x, rg.y, rg.x * az.y);
            float den = dot(rd, n);
            float num = rg.z - dot(ro, n);
            float t = num / (abs(den) < 1e-6 ? (den < 0.0 ? -1e-6 : 1e-6) : den);
            if (den < 0.0) { if (t > tin) { tin = t; nEnter = n; } }
            else { if (t < tout) { tout = t; nExit = n; } }
            az = vec2(az.x * rot.x - az.y * rot.y, az.x * rot.y + az.y * rot.x);
        }
    }
    return vec2(tin, tout);
}

// Cheap bounding-sphere test (radius 1.25 around the gem's centre), so only
// rays near the stone pay for the polytope.
bool crNear(vec3 ro, vec3 rd) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - 1.5625;
    return b < 0.0 && b * b - c > 0.0;
}

// Rectangle mask in a light's projected plane, edge softness s.
float crRect(vec2 q, vec2 b, float s) {
    vec2 e = abs(q) - b;
    return 1.0 - smoothstep(-0.006 - s, 0.006 + s, max(e.x, e.y));
}

// The palette colour's complement at the same lightness: a warm accent for a
// cool palette (and the reverse), so the studio never sits in one hue.
vec3 crCompl(vec3 c) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    return vec3(mx + mn) - c;
}

// The palette read once per pixel at fixed stops: the gem samples the studio
// up to eight times per pixel, and each palette read at a call site costs.
struct CrPal { vec3 ring; vec3 spot; vec3 key; vec3 cool; vec3 heart; vec3 warm; vec3 w05; vec3 s0; vec3 s1; vec3 b0; vec3 b1; vec3 sweep; float beam; };

// The light pulse: the level, with a beat that swells in and out within the
// beat (zero at both ends), so the studio breathes with the music instead of
// jumping on each kick.
float crPulse(VisualUniforms u) {
    float b = sin(3.14159265 * saturate(u.beatPhase));
    return saturate(u.level) * (0.25 + 0.03 * b * b);
}

// A band of the spectrum, mostly the steady level: the spectrum still shapes
// the strips, streaks and rays, but a kick only nudges them.
float crBand(VisualUniforms u, float x) {
    return mix(saturate(u.level), bandAt(u, x), 0.15);
}

// The laser that feeds the stone, from high on one side of the studio.
const vec3 CR_BEAM_FROM = vec3(-0.7365, 0.6088, 0.2946);

// Studio lights shared by every view: the key softbox, hard spots that become
// the fire, and the ring light. soft widens the edges (defocus, gloss).
vec3 crLights(vec3 d, VisualUniforms u, float soft, vec3 ringL, CrPal P, float spots, vec3 sweepL) {
    vec3 col = vec3(0.0);
    vec3 warm = P.warm;
    // overhead key softbox, with a darker cross bar like a real light box
    {
        vec3 L = vec3(0.234, 0.936, -0.262);
        float dl = dot(d, L);
        if (dl > 0.2) {
            vec2 q = vec2(dot(d, vec3(0.97, -0.243, 0.0)), dot(d, vec3(0.063, 0.254, 0.965))) / dl;
            float m = crRect(q, vec2(0.5, 0.11), soft);
            m *= 1.0 - 0.7 * (1.0 - smoothstep(0.0, 0.015 + soft, abs(q.x)));
            col += vec3(2.4, 2.35, 2.3) * m;
        }
    }
    // small hard spots, white and warm/cool: these become the fire
    for (int k = 0; k < 6; k++) {
        if (spots < 0.5) break;
        float fk = float(k);
        float az = fk * 1.047 + 0.4;
        float el = 0.15 + 0.5 * fract(fk * 0.618);
        vec3 L = vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
        float x = max(1.0 - dot(d, L), 0.0);
        vec3 sc = k == 1 || k == 4 ? warm * 1.4 : k == 2 ? P.spot : vec3(1.0);
        col += sc * exp(-x * (900.0 - 700.0 * saturate(soft * 4.0))) * 4.0;
    }
    // the ring light: a crisp, hot tube with a tight halo that swells with the beat
    {
        float dl = dot(d, ringL);
        vec3 rc = P.ring;
        float pump = 0.8 + 0.9 * crPulse(u);
        if (dl > 0.3) {
            vec3 ax = normalize(vec3(ringL.z, 0.0, -ringL.x));
            vec2 q = vec2(dot(d, ax), dot(d, cross(ringL, ax))) / dl;
            float e = abs(length(q) - 0.42);
            float tube = 1.0 - smoothstep(0.004, 0.009 + soft * 0.4, e);
            col += rc * tube * 4.0 * pump;
            col += rc * (exp(-e * 40.0) * 0.25 + exp(-e * 8.0) * 0.05) * pump;
        }
    }
    // the sweep light: a tall strip that laps the stone slowly and steadily,
    // alternating warm and cool, so the fire rolls through the facets;
    // and the laser's source, a hard white point. The stone alone sees both.
    if (spots > 0.5) {
        float xb = max(1.0 - dot(d, CR_BEAM_FROM), 0.0);
        col += vec3(1.0, 0.97, 0.94) * exp(-xb * 1400.0) * 9.0 * P.beam;
        float dl = dot(d, sweepL);
        if (dl > 0.5) {
            vec3 ax = normalize(vec3(sweepL.z, 0.0, -sweepL.x));
            vec2 q = vec2(dot(d, ax), d.y) / dl;
            float m = crRect(q - vec2(0.0, 0.25), vec2(0.035, 0.7), soft);
            col += P.sweep * m * 3.2;
        }
    }
    return col;
}

// The full studio, for the background and the lacquer's reflection: a dark
// cyclorama split warm and cool, the ring light's wash, two equaliser strips
// (the spectrum) and the lights above.
vec3 crEnv(vec3 d, VisualUniforms u, float soft, vec4 lvA, vec4 lvB, vec3 ringL, CrPal P, vec3 sweepL) {
    vec3 cool = P.cool;
    vec3 warm = P.warm;
    float sideW = dot(d.xz, vec2(ringL.z, -ringL.x));          // left/right of the ring
    vec3 wall = mix(cool * 0.012, warm * 0.016, smoothstep(-0.6, 0.6, sideW));
    vec3 col = wall * smoothstep(-0.2, 0.5, d.y) + vec3(0.0008, 0.0008, 0.0012);
    // the ring's backdrop wash and the horizon sweep of the cyclorama
    float dl = dot(d, ringL);
    col += mix(P.ring, vec3(0.6), 0.2) * 0.05 * exp(-max(1.0 - dl, 0.0) * 5.0) * (0.8 + 0.6 * crPulse(u));
    col += mix(cool, warm, smoothstep(-0.5, 0.5, sideW)) * 0.025 * exp(-abs(d.y - 0.02) * 9.0);
    col += crLights(d, u, soft, ringL, P, 0.0, sweepL);
    // two vertical equaliser strips in 16 segments: warm on the left, cool on the right
    for (int s = 0; s < 2; s++) {
        float az = s == 0 ? 1.75 : -2.25;
        vec3 L = vec3(sin(az), 0.0, cos(az));
        float sl = dot(d, L);
        if (sl > 0.2) {
            vec2 q = vec2(dot(d, vec3(L.z, 0.0, -L.x)), d.y) / sl;
            float m = crRect(q - vec2(0.0, 0.05), vec2(0.022, 0.95), soft);
            if (m > 0.0) {
                float hgt = saturate(q.y * 0.5 + 0.475) * 16.0;
                float gap = mix(smoothstep(0.06, 0.16, abs(fract(hgt) - 0.5)), 1.0, saturate(soft * 6.0));
                vec4 lv = s == 0 ? lvA : lvB;
                float f = hgt / 4.0;
                float lvl = f < 1.0 ? lv.x : f < 2.0 ? lv.y : f < 3.0 ? lv.z : lv.w;
                float lit = smoothstep(0.0, 0.08, lvl * 1.3 - fract(f));
                vec3 sc = s == 0 ? mix(warm, P.w05 * 0.6 + warm * 0.6, fract(hgt / 16.0))
                                 : mix(P.s0, P.s1, floor(hgt) / 15.0);
                col += sc * m * gap * (0.08 + 2.2 * lit * lvl + 0.3 * lvl);
            }
        }
    }
    // the floor seen from inside the gem: dark with a coloured bounce
    col = d.y < -0.05 ? mix(col, cool * 0.04 * (0.5 + crPulse(u)), smoothstep(-0.05, -0.4, d.y)) : col;
    return col;
}

// What the stone sees: the studio's lights and the light tent around it,
// near-white louvred panels with black gaps, which gives the facets their
// black-and-white brilliance; dispersion turns every edge into fire. It skips
// the strips' segments and the wall detail, which the facets would scramble.
vec3 crGemEnv(vec3 d, VisualUniforms u, vec3 ringL, CrPal P, vec4 lvA, vec3 sweepL) {
    vec3 warm = P.warm;
    vec3 col = vec3(0.001) + crLights(d, u, 0.0, ringL, P, 1.0, sweepL);
    float az = atan2_(d.z, d.x) * 1.9098593;               // 12 panels around
    float fa = fract(az);
    float pan = smoothstep(0.30, 0.24, abs(fa - 0.5));
    float band = smoothstep(0.12, 0.2, d.y) * (1.0 - smoothstep(0.75, 0.8, d.y));
    float hi = smoothstep(0.92, 0.95, d.y);                 // the open top
    float pk = floor(az);
    // one panel in six carries the cool key colour; the rest are clean white
    vec3 pc = mod(pk, 6.0) < 0.5 ? P.key : vec3(1.0);
    col += pc * (pan * band * 1.5 + hi * 1.1) * (0.7 + 0.5 * u.level);
    // the warm strip low around the stone
    col += warm * smoothstep(0.08, 0.02, abs(d.y + 0.02)) * (0.05 + 2.5 * lvA.x * lvA.x);
    return col;
}

// Fractures: three flat sheets inside the stone, each a straight-edged shard
// (a triangle in its plane). The ray meets each sheet analytically, so edges
// stay crisp: an iridescent thin-film sheen across the sheet and a hot line
// along its edge that flares on onsets.
vec3 crCracks(vec3 pos, vec3 dir, float seg, VisualUniforms u, float fracture) {
    vec3 col = vec3(0.0);
    for (int k = 0; k < 3; k++) {
        vec3 n = k == 0 ? vec3(0.6, 0.48, -0.64) : k == 1 ? vec3(-0.3, 0.906, 0.3) : vec3(0.813, -0.2, 0.547);
        vec3 c = k == 0 ? vec3(0.12, 0.05, -0.1) : k == 1 ? vec3(-0.15, -0.05, 0.12) : vec3(0.18, -0.15, 0.2);
        float dn = dot(dir, n);
        if (abs(dn) < 0.02) continue;
        float t = dot(c - pos, n) / dn;
        if (t <= 0.0 || t >= seg) continue;
        vec3 q = pos + dir * t - c;
        vec3 e1 = normalize(cross(n, vec3(0.0, 0.0, 1.0) + 0.3 * float(k)));
        vec3 e2 = cross(n, e1);
        vec2 w = vec2(dot(q, e1), dot(q, e2));
        // triangle distance: max of three edge half-planes
        float R = (0.22 + 0.2 * fracture) * (1.0 + 0.3 * float(k));
        float tri = max(max(dot(w, vec2(0.0, 1.0)), dot(w, vec2(0.866, -0.5))), dot(w, vec2(-0.866, -0.5))) - R * 0.5;
        if (tri > 0.03) continue;
        float inside = 1.0 - smoothstep(-0.004, 0.0, tri);
        float edge = exp(-abs(tri) * 260.0);
        // a straight inner hairline from the shard's centre
        float hair = exp(-abs(dot(w, vec2(0.6, 0.8))) * 400.0) * inside * smoothstep(0.0, -0.08, tri);
        vec3 film = hsv2rgb(vec3(fract(length(w) * 2.5 + float(k) * 0.3 + 0.1 * u.spectralCentroid), 0.7, 1.0));
        float view = 1.0 / (0.3 + abs(dn));
        col += film * inside * 0.05 * view + peakWhite(film, 0.5) * (edge + hair) * (0.08 + 0.1 * saturate(u.level));
    }
    return col * fracture;
}

// Full gem shading for a ray in gem space that hits at t with normal n.
vec3 crShadeGem(vec3 ro, vec3 rd, float t, vec3 n, mat3 toWorld, VisualUniforms u,
                int N, vec2 rot, vec2 half_, int bounces, float disp, vec3 tint,
                float fracture, vec3 ringL, CrPal P, vec4 lvA, vec3 sweepL) {
    vec3 pos = ro + rd * t;
    float c = saturate(-dot(rd, n));
    float F = 0.17 + 0.83 * pow(1.0 - c, 5.0);
    vec3 col = crGemEnv(toWorld * reflect(rd, n), u, ringL, P, lvA, sweepL) * F;
    vec3 dir = refract(rd, n, 1.0 / 2.42);
    vec3 thr = vec3(1.0 - F);
    for (int b = 0; b < 4; b++) {
        if (b >= bounces) break;
        vec3 nE, nX;
        vec2 h = crHit(pos, dir, N, rot, half_, nE, nX);
        float seg = clamp(h.y, 1e-3, 3.0);
        // inner glow: the level, swelling on the beat, lights the heart
        vec3 mid = pos + dir * (0.5 * seg);
        vec3 em = P.heart * exp(-dot(mid, mid) * 9.0) * (0.004 + 0.16 * crPulse(u)) * seg;
        if (b == 0 && fracture > 0.001) em += crCracks(pos, dir, seg, u, fracture);
        col += thr * em;
        pos += dir * seg;
        thr *= exp(-seg * (vec3(1.0) - tint) * 0.8);
        // leave through the face, split into wavelengths: red, green and blue
        // for the first exit, the two ends for the second, one ray after
        vec3 r0 = refract(dir, -nX, 2.42 - disp);
        if (dot(r0, r0) > 0.5) {
            float fr = 0.17 + 0.83 * pow(1.0 - saturate(dot(dir, nX)), 5.0);
            vec3 outc;
            if (b < 2) {
                vec3 r2 = refract(dir, -nX, 2.42 + disp);
                r2 = dot(r2, r2) < 0.5 ? r0 : r2;
                vec3 e0 = crGemEnv(toWorld * r0, u, ringL, P, lvA, sweepL);
                vec3 e2 = crGemEnv(toWorld * r2, u, ringL, P, lvA, sweepL);
                float g = 0.5 * (e0.g + e2.g);
                if (b == 0) {
                    vec3 r1 = refract(dir, -nX, 2.42);
                    r1 = dot(r1, r1) < 0.5 ? r0 : r1;
                    g = crGemEnv(toWorld * r1, u, ringL, P, lvA, sweepL).g;
                }
                outc = vec3(e0.r, g, e2.b);
            } else {
                outc = crGemEnv(toWorld * r0, u, ringL, P, lvA, sweepL);
            }
            col += thr * (1.0 - fr) * outc;
            thr *= fr;
        }
        dir = reflect(dir, nX);
        pos += dir * 1e-3;
    }
    // what is left after the last bounce leaves as a soft tinted glow
    col += thr * tint * crGemEnv(toWorld * dir, u, ringL, P, lvA, sweepL) * 0.6;
    return col;
}

// Spectral caustic streaks the gem throws on the floor: each facet throws a
// dashed streak whose width fans out into a rainbow with distance, as
// dispersed light does; under the stone, a focused star of light.
vec3 crCaustic(vec2 q, float yaw, float N, float disp, vec3 tint, float T, VisualUniforms u) {
    float r = length(q);
    float a = atan2_(q.y, q.x) + yaw;
    vec3 c = vec3(0.0);
    for (int l = 0; l < 2; l++) {
        float fl = float(l);
        float N2 = N * (2.0 + fl);
        float A = a * N2 / 6.2831853 + fl * 0.37;
        float id = floor(A);
        float hs = hash11(mod(id, N2) * 3.7 + 1.0 + fl * 9.0);
        float x = fract(A) - 0.5 + 0.2 * (hs - 0.5);
        float wdt = (0.025 + 0.45 * disp * r) * (0.6 + 0.6 * hs);
        float prof = exp(-x * x / (wdt * wdt));
        vec3 spec = hsv2rgb(vec3(fract(0.62 + 0.45 * x / max(wdt, 1e-3)), 0.9, 1.0));
        float dash = smoothstep(0.35, 0.75, vnoise(vec2(id * 7.3 + fl * 31.0, r * 2.4 - T * 0.12)));
        // each streak is one band of an equaliser fanning out from the stone
        float lv = crBand(u, fract(id / N2 + fl * 0.5));
        float reach = smoothstep(0.25, 0.55, r) * exp(-r * (0.45 + 0.7 * hs)) * smoothstep(0.0, 0.4, 1.3 + 4.5 * lv - r);
        c += spec * prof * dash * reach * (0.5 + 1.1 * hs + 1.2 * lv) / (1.0 + fl);
    }
    // the focused star right under the stone: N sharp spikes and a hot ring
    float spike = pow(abs(cos(a * N * 0.5)), 24.0) * exp(-r * 4.0) * smoothstep(0.02, 0.15, r);
    float e = (r - 0.42) / 0.025;
    vec3 ringC = hsv2rgb(vec3(fract(0.55 + (r - 0.42) * 3.0), 0.6, 1.0));
    c += tint * spike * 0.8 + ringC * exp(-e * e) * 0.35 + tint * exp(-r * r * 30.0) * 0.4;
    return c * mix(vec3(1.0), tint, 0.3) * (0.6 + 1.6 * crPulse(u));
}

// Defocused studio lights hanging in the dark behind the gem: lens bokeh
// with a bright rim and a soft core, alternating warm and cool.
vec3 crBokeh(vec2 p, float orbit, VisualUniforms u, CrPal P) {
    vec3 warm = P.warm;
    vec3 col = vec3(0.0);
    for (int l = 0; l < 2; l++) {
        float fl = float(l);
        float sc = 2.0 + 1.8 * fl;
        vec2 q = p * sc + vec2(orbit * (3.0 + 2.0 * fl), 0.3 * fl);
        vec2 g = floor(q);
        vec2 f = fract(q) - 0.5;
        vec2 h = hash22(g + fl * 17.0);
        float on = step(0.5, hash21(g * 1.7 + fl * 3.0));
        float rad = 0.12 + 0.18 * h.x;
        float d = length(f - (h - 0.5) * 0.35) - rad;
        float disc = 1.0 - smoothstep(-0.012, 0.012, d);
        float rim = exp(-abs(d + 0.012) * 60.0) * disc;
        float lvl = crBand(u, h.y);
        vec3 bc = h.y < 0.5 ? warm : mix(P.b0, P.b1, h.x);
        col += bc * (disc * 0.5 + rim * 0.8) * on * (0.05 + 0.3 * lvl) / (1.0 + 1.5 * fl);
    }
    return col;
}

// A beam through the studio haze: the view ray's closest approach to the beam
// c + s b (s in [s0, L], b unit), seen only in front of tMax. A hot core and a
// wide scattering halo, fading along the beam.
vec3 crBeam(vec3 ro, vec3 rd, vec3 c, vec3 b, float s0, float L, float tMax, vec3 colr) {
    vec3 w0 = ro - c;
    float bb = dot(rd, b);
    float dd = dot(rd, w0), e = dot(b, w0);
    float den = max(1.0 - bb * bb, 1e-4);
    float s = clamp((e - bb * dd) / den, s0, L);
    vec3 cp = c + b * s;
    float t = max(dot(cp - ro, rd), 0.0);
    if (t > tMax) return vec3(0.0);
    vec3 dv = ro + rd * t - cp;
    float d2 = dot(dv, dv);
    float fade = exp(-(s - s0) * 0.16) * smoothstep(s0, s0 + 0.15, s);
    return colr * fade * (exp(-d2 * 9000.0) * 1.6 + exp(-d2 * 300.0) * 0.18 + exp(-d2 * 14.0) * 0.02);
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float T = mod(u.time, 600.0);
    int N = int(floor(mix(6.0, 12.0, u.param0) + 0.5));
    float fN = float(N);
    vec2 rot = vec2(cos(6.2831853 / fN), sin(6.2831853 / fN));
    vec2 half_ = vec2(cos(3.14159265 / fN), sin(3.14159265 / fN));
    float disp = mix(0.03, 0.22, u.param1);
    float fracture = u.param2;

    // the strip lights' bands: left strip low end, right strip high end
    vec4 lvA = vec4(crBand(u, 0.03), crBand(u, 0.10), crBand(u, 0.18), crBand(u, 0.28));
    vec4 lvB = vec4(crBand(u, 0.40), crBand(u, 0.55), crBand(u, 0.70), crBand(u, 0.85));
    // the warm accent: the complement of the palette's key colour
    vec3 warm = crCompl(crPalSteady(0.42, u));
    warm = warm / max(max(warm.r, max(warm.g, warm.b)), 0.05);
    CrPal P;
    P.warm = warm;
    P.ring = mix(crPalSteady(0.4, u), vec3(1.0), 0.35);
    P.spot = crPalSteady(0.6, u);
    P.key = crPalSteady(0.55, u);
    P.cool = crPalSteady(0.45, u);
    P.heart = crPalSteady(0.48, u);
    P.w05 = crPalSteady(0.05, u);
    P.s0 = crPalSteady(0.36, u); P.s1 = crPalSteady(0.54, u);
    P.b0 = crPalSteady(0.35, u); P.b1 = crPalSteady(0.85, u);
    // the sweep light: a slow, steady lap of about 30 s (the facets multiply
    // its motion, so a faster lap would strobe the stone)
    float sweepA = u.time * 0.21;
    // warm and cool alternate lap by lap, crossfading while the strip is behind the stone
    float coolMix = 0.5 - 0.5 * cos(0.5 * sweepA);
    P.sweep = mix(warm, P.key * 1.3, coolMix) * (0.6 + 1.4 * crPulse(u));
    P.beam = 0.45 + 0.8 * crPulse(u);

    // camera: a slow, steady orbit and dolly, level (a roll would sweep the
    // fan's long rays across the frame)
    float orbit = u.time * 0.045;
    float elev = 0.17 + 0.06 * sin(T * 0.071);
    float dist = 2.35 + 0.2 * sin(T * 0.053);
    vec3 ro = dist * vec3(sin(orbit) * cos(elev), sin(elev), -cos(orbit) * cos(elev));
    vec3 ta = vec3(0.0, -0.12, 0.0);
    // the ring light hangs behind the stone wherever the camera is
    vec3 ringL = vec3(-sin(orbit) * 0.987, 0.16, cos(orbit) * 0.987);
    vec3 sweepL = vec3(sin(sweepA) * 0.94, 0.34, cos(sweepA) * 0.94);
    vec3 rd = osCamera(ro, ta, 0.0, 1.45, p);

    // gem pose: slow spin and a gentle eased tilt toward the camera
    float yaw = 0.06 * T;
    float tilt = 0.28 + 0.1 * sin(T * 0.09);
    float cy = cos(yaw), sy = sin(yaw), ct = cos(tilt), st = sin(tilt);
    mat3 ry = mat3(cy, 0.0, sy, 0.0, 1.0, 0.0, -sy, 0.0, cy);
    mat3 rx = mat3(1.0, 0.0, 0.0, 0.0, ct, st, 0.0, -st, ct);
    mat3 toWorld = ry * rx;
    mat3 toGem = transpose(toWorld);
    vec3 gc = vec3(0.0, 0.05 * sin(T * 0.4), 0.0);

    vec3 tint = mix(vec3(1.0), crPalSteady(0.3, u), 0.25);
    int bounces = osSteps(2.0, 3.0, detail);

    vec3 lo = toGem * (ro - gc);
    vec3 ld = toGem * rd;
    vec3 nE = vec3(0.0, 1.0, 0.0), nX = nE;
    vec2 h = vec2(1.0, -1.0);
    if (crNear(lo, ld)) h = crHit(lo, ld, N, rot, half_, nE, nX);
    vec3 col;
    if (h.x < h.y && h.x > 0.0) {
        col = crShadeGem(lo, ld, h.x, nE, toWorld, u, N, rot, half_, bounces, disp, tint, fracture, ringL, P, lvA, sweepL);
        // facet glints toward the key light, sparked by treble
        float g = pow(saturate(dot(reflect(ld, nE), toGem * vec3(0.234, 0.936, -0.262))), 160.0);
        col += peakWhite(tint, 0.8) * g * (1.0 + 0.4 * saturate(u.level));
    } else if (rd.y < 0.0) {
        // black lacquer floor: glossy reflections, caustics
        float tf = (CR_FLOOR - ro.y) / rd.y;
        vec3 fp = ro + rd * tf;
        vec3 rr = vec3(rd.x, -rd.y, rd.z);
        float fres = 0.05 + 0.6 * pow(1.0 - saturate(-rd.y), 5.0);
        vec3 refl = crEnv(rr, u, 0.06, lvA, lvB, ringL, P, sweepL);
        vec3 nE2 = vec3(0.0, 1.0, 0.0), nX2 = nE2;
        vec3 flo = toGem * (fp - gc);
        vec3 fld = toGem * rr;
        vec2 h2 = vec2(1.0, -1.0);
        if (crNear(flo, fld)) h2 = crHit(flo, fld, N, rot, half_, nE2, nX2);
        if (h2.x < h2.y && h2.x > 0.0) {
            refl = crShadeGem(flo, fld, h2.x, nE2, toWorld, u, N, rot, half_, 1, disp, tint, 0.0, ringL, P, lvA, sweepL) * 2.0;
        }
        float fade = exp(-length(fp.xz) * 0.15);
        col = refl * fres * fade;
        vec2 kq = (fp.xz - vec2(-0.3, 0.35)) * 0.8;
        col += crCaustic(kq, yaw, fN, disp, tint, T, u) * 0.45;
        float far = smoothstep(4.0, 10.0, length(fp.xz));
        col = mix(col, refl * 0.5, far);
        // the floor curves up into the cyclorama: no hard horizon
        if (rd.y > -0.1) {
            vec3 sky = crEnv(rd, u, 0.0, lvA, lvB, ringL, P, sweepL) * 0.5 + crBokeh(p, orbit, u, P);
            col = mix(sky, col, smoothstep(0.0, -0.1, rd.y));
        }
    } else {
        col = crEnv(rd, u, 0.0, lvA, lvB, ringL, P, sweepL) * 0.5 + crBokeh(p, orbit, u, P);
    }
    // the laser into the stone and the spectrum fan it throws out: the rays
    // spread in a vertical fan, red on top, that drifts slowly round the studio,
    // and each ray rides a band of the spectrum
    float tMax = h.x < h.y && h.x > 0.0 ? h.x : rd.y < 0.0 ? (CR_FLOOR - ro.y) / rd.y : 1e4;
    col += crBeam(ro, rd, gc, CR_BEAM_FROM, 0.55, 12.0, tMax, vec3(1.0, 0.96, 0.92) * P.beam);
    int rays = osSteps(3.0, 6.0, detail);
    // a slow drift of about a minute: out to one side, behind, out to the other
    float sw = sin(u.time * 0.1 + 1.2);
    float fanAz = orbit + 3.1415927 + 1.9 * sw;
    vec2 fanH = vec2(sin(fanAz), -cos(fanAz));
    vec3 fanC = gc + vec3(0.0, -0.2, 0.0) + vec3(fanH.x, 0.0, fanH.y) * 0.2;
    for (int i = 0; i < 6; i++) {
        if (i >= rays) break;
        float fi = (float(i) + 0.5) / float(rays);
        float el = 0.14 - 0.5 * fi;
        vec3 bd = vec3(fanH.x * cos(el), sin(el), fanH.y * cos(el));
        vec3 rc = hsv2rgb(vec3(fi * 0.78, 0.92, 1.0));
        col += crBeam(ro, rd, fanC, bd, 0.75, 12.0, tMax, rc * P.beam * (0.25 + 1.6 * crBand(u, fi)) * 0.8);
    }
    col *= 1.0 - 0.3 * smoothstep(0.8, 1.9, length(p));
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
