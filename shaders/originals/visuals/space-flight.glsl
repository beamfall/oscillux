// SPDX-License-Identifier: AGPL-3.0-only
// Space flight.
// A flight through an asteroid field along a procession of giant worlds: a
// planet, some ringed, waits far ahead, swells as the route closes on it and
// sweeps past to one side, then the next one rises in the distance. Behind
// them a nebula of cool gas burns with warm emission cores and fine filaments
// under a band of stars, cut by black dust. A warm sun rims the tumbling rocks.
// The speed follows a 32-beat profile of cruise, build, burst, brake and
// drift; in a burst the star streaks lengthen into a blue-shifted tunnel. The
// roll eases to a new side every eight beats. Audio drives the light, never
// the camera: bass lights the glowing seams in the rocks and warms the gas,
// treble twinkles the stars and the rings glow band by band with the spectrum.
// Now and then, about once every minute or two of flight, a visitor crosses
// the route for a few seconds: an alien skiff that paces the camera, a
// tumbling derelict with a red beacon, a leviathan gliding across the gas, a
// wormhole that opens onto another sky, a comet, or a school of jellies. The
// order is fixed by route distance, so a replay shows the same visitors.
// param0 = Flight Speed ; param1 = Banking ; param2 = Nebula Density

// The palette is read once per pixel at its five stops and blended locally:
// each library palette read walks the whole stop table, and this visual needs
// dozens of colours per pixel. sfPal follows the library blend closely; the
// role helpers mirror the library roles (trace, peak, rim, fog, bass, treble).
struct SfPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

SfPal sfPalLoad(VisualUniforms u) {
    SfPal P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 sfPal(SfPal P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

vec3 sfPeak(SfPal P, float t, VisualUniforms u) {
    return peakWhite(sfPal(P, t + 0.08 * u.spectralCentroid), saturate(u.onset * 0.18 + u.bassImpact * 0.10));
}

vec3 sfRim(SfPal P, float t, VisualUniforms u) {
    return mix(sfPal(P, t), sfPeak(P, t + 0.18, u), 0.35 + 0.35 * u.flux);
}

vec3 sfFog(SfPal P, float t, VisualUniforms u) {
    vec3 c = sfPal(P, t + 0.04 * u.spectralCentroid);
    return mix(vec3(luma(c) * 0.62), c, 0.42);
}

vec3 sfBass(SfPal P, float t, VisualUniforms u) {
    return mix(sfPal(P, t + 0.10), sfPal(P, 0.03 + t * 0.18 + 0.04 * u.beatPhase), 0.62 + 0.25 * u.bassImpact);
}

vec3 sfTreble(SfPal P, float t, VisualUniforms u) {
    return peakWhite(sfPal(P, 0.62 + t * 0.28 + 0.10 * u.spectralCentroid), u.treble * u.onset * 0.14);
}

vec3 sfPath(float z) {
    return vec3(4.0 * sin(z * 0.017) + 2.0 * sin(z * 0.041), 2.5 * sin(z * 0.023 + 1.0), z);
}

float sfNoise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x),
                  mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x), f.y);
    float b = mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x),
                  mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x), f.y);
    return mix(a, b, f.z);
}

// 2D fbm with a detail-scaled octave count (the last octave fades in).
float sfFbm(vec2 p, float oct) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        float w = saturate(oct - float(i));
        if (w <= 0.0) break;
        v += a * w * vnoise(p);
        p = FBM_OCTAVE * p;
        a *= 0.5;
    }
    return v;
}

// The warm star that lights the scene; it does not take the palette, so the
// sunlit side of everything stays the complement of the cool gas.
const vec3 SF_SUN = vec3(1.0, 0.8, 0.58);

const float SF_CELL = 13.0;

// ---- Rare visitors --------------------------------------------------------
// About once a minute (one slot per 2000 units of route, a little over a
// minute at the mean flight speed) something unusual shares the flight: an
// alien skiff overtakes and pulls away ahead, a derelict hulk tumbles among
// the rocks, a vast creature drifts through the nebula, a wormhole opens on
// another sky, a comet crosses, or a tiny school of lantern jellies drifts by
// close to the lane. Slots are keyed by route distance, so world-anchored
// visitors stay put while the camera passes; each block of six slots plays
// all six in a hashed order, the first block in a fixed one. Only the
// current slot is evaluated, and a visitor costs work only inside its
// bounding sphere or screen rectangle.
const float SF_ESLOT = 2000.0;

struct SfEv {
    float type;   // 0 skiff, 1 derelict, 2 leviathan, 3 wormhole, 4 comet, 5 jellies
    float zs;     // route distance where it starts
    float len;    // route distance it lasts
    float e;      // progress, on in (0, 1)
    float fade;
    float side;
    float h;
    float h2;
    vec3 pos;     // world anchor (derelict, jellies); the skiff's lateral berth in xy
};

// Exact modulo for integer-valued floats on every target.
float sfModI(float x, float m) { return x - m * floor((x + 0.5) / m); }

SfEv sfEventAt(float z) {
    SfEv E;
    float k = floor(max(z, 0.0) / SF_ESLOT);
    float kk = sfModI(k, 360.0);
    float B = floor((kk + 0.5) / 6.0);
    float i = kk - 6.0 * B;
    float stp = hash21(vec2(B, 17.3)) < 0.5 ? 1.0 : 5.0;
    float off = floor(hash21(vec2(B, 29.1)) * 5.999);
    if (B < 0.5) { stp = 1.0; off = 0.0; }
    E.type = sfModI(off + i * stp, 6.0);
    E.h = hash21(vec2(kk, 41.7));
    E.h2 = hash21(vec2(kk, 61.3));
    E.side = hash21(vec2(kk, 53.9)) < 0.5 ? -1.0 : 1.0;
    E.len = E.type < 0.5 ? 260.0 : E.type < 1.5 ? 300.0 : E.type < 2.5 ? 300.0 : E.type < 3.5 ? 240.0 : E.type < 4.5 ? 260.0 : 280.0;
    E.zs = k < 0.5 ? 380.0 : (k + 0.12 + 0.6 * E.h) * SF_ESLOT;
    E.e = (z - E.zs) / E.len;
    E.fade = smoothstep(0.0, 0.12, E.e) * smoothstep(1.0, 0.88, E.e);
    float za = E.zs + (E.type < 1.5 ? 250.0 : 160.0);
    vec3 lane = sfPath(za);
    E.pos = E.type < 0.5 ? vec3(E.side * 4.5, 1.3, 0.0)
          : E.type < 1.5 ? vec3(lane.xy + vec2(E.side * 10.5, -1.5 + 3.0 * E.h2), za)
                         : vec3(E.side * 6.5, 0.8, za);
    return E;
}

// The rock in cell id, if any: xyz = centre, w = radius (0 when the cell is
// empty). Rocks that would reach into the flight lane are left out, so the
// lane never shows cut faces.
// The current slot's berth for rocks to keep clear of: a tube along the lane
// over z in (x, y), offset by zw from the lane centre, of radius w.
vec4 sfBerth(float z, out float rad) {
    SfEv E = sfEventAt(z);
    vec3 lane = sfPath(E.pos.z);
    rad = E.type < 0.5 ? 4.5 : E.type < 1.5 ? 12.0 : 3.6;
    return E.type < 0.5 ? vec4(E.zs - 30.0, E.zs + E.len + 90.0, E.pos.xy)
         : E.type < 1.5 ? vec4(E.pos.z - 12.0, E.pos.z + 12.0, E.pos.xy - lane.xy)
         : E.type > 4.5 ? vec4(E.pos.z - 15.0, E.pos.z + 75.0, E.pos.xy)
                        : vec4(1.0, 0.0, 0.0, 0.0);
}

vec4 sfRockAt(vec3 id, vec4 berth, float bRad) {
    if (hash31(id) < 0.76) return vec4(0.0);
    vec3 c = (id + 0.5) * SF_CELL + (vec3(hash31(id + 1.3), hash31(id + 2.7), hash31(id + 4.1)) - 0.5) * 2.4;
    float hr = hash31(id + 7.9);
    float r = 0.7 + 2.2 * hr + 1.6 * hr * hr * hr * hr;
    vec3 lane = sfPath(c.z);
    if (length(c.xy - lane.xy) < 3.5 + r) return vec4(0.0);
    // the current slot's visitor keeps a clear berth. It is fixed in the
    // world for the whole slot and lies beyond the traced range when a slot
    // begins or ends, so no rock ever pops.
    if (c.z > berth.x && c.z < berth.y && length(c.xy - lane.xy - berth.zw) < bRad + r) return vec4(0.0);
    return vec4(c, r);
}

// The rock's own tumbling frame.
vec3 sfSpin(vec3 q, vec3 id, float time) {
    float spin = time * (0.2 + 0.5 * hash31(id + 3.3));
    q.xy = rot2(spin) * q.xy;
    q.yz = rot2(spin * 0.7) * q.yz;
    return q;
}

// Undo sfSpin: back from the rock frame to the world.
vec3 sfUnspin(vec3 q, vec3 id, float time) {
    float spin = time * (0.2 + 0.5 * hash31(id + 3.3));
    q.yz = rot2(-spin * 0.7) * q.yz;
    q.xy = rot2(-spin) * q.xy;
    return q;
}

// Three cleavage planes per rock (columns of F, offsets o): the chips that
// split it off its parent body, so silhouettes are angular, not potatoes.
mat3 sfFacets(vec3 id, float r, out vec3 o) {
    vec3 a = vec3(hash31(id + 21.1), hash31(id + 22.3), hash31(id + 23.7)) - 0.5;
    vec3 b = vec3(hash31(id + 24.9), hash31(id + 25.1), hash31(id + 26.3)) - 0.5;
    vec3 n0 = normalize(a + vec3(0.0, 0.0, 0.3));
    vec3 n1 = normalize(cross(n0, b + vec3(0.3, 0.0, 0.0)) + 0.4 * n0 + 1e-4);
    vec3 n2 = normalize(-n0 - 0.6 * n1 + 0.5 * (b - a) + 1e-4);
    o = r * (0.5 + 0.22 * vec3(hash31(id + 27.7), hash31(id + 28.1), hash31(id + 29.9)));
    return mat3(n0, n1, n2);
}

// Lumpy, chipped rock around its own centre, in its tumbling frame. The lumps
// and the facets only cut inward, so the bounding sphere of radius r holds it.
float sfRock(vec3 q, vec3 id, float r, mat3 F, vec3 o) {
    float d = length(q) - r + r * (0.35 * sfNoise(q * 1.3 / r + id) + 0.12 * sfNoise(q * 3.7 / r));
    vec3 pl = q * F - o;
    return max(d, max(pl.x, max(pl.y, pl.z)) + 0.04 * r * sfNoise(q * 5.0 / r + 3.0));
}

vec3 sfRockNormal(vec3 q, vec3 id, float r, mat3 F, vec3 o) {
    vec2 k = vec2(1.0, -1.0);
    float e = 0.01;
    return normalize(k.xyy * sfRock(q + k.xyy * e, id, r, F, o) + k.yyx * sfRock(q + k.yyx * e, id, r, F, o) +
                     k.yxy * sfRock(q + k.yxy * e, id, r, F, o) + k.xxx * sfRock(q + k.xxx * e, id, r, F, o) + 1e-6);
}

// Walk the rock grid cell by cell along the ray (no wasted steps in empty
// space); only a cell whose bounding sphere the ray meets is sphere-marched.
// Returns t (or -1) and writes the hit normal and the rock's local frame.
float sfField(vec3 ro, vec3 rd, float tmax, float time, float detail, out vec3 nrm, out vec4 hitRock, out vec3 hitQ) {
    nrm = vec3(0.0, 0.0, -1.0);
    hitRock = vec4(0.0);
    hitQ = vec3(0.0);
    vec3 id = floor(ro / SF_CELL);
    vec3 sg = vec3(rd.x >= 0.0 ? 1.0 : -1.0, rd.y >= 0.0 ? 1.0 : -1.0, rd.z >= 0.0 ? 1.0 : -1.0);
    vec3 inv = 1.0 / max(abs(rd), vec3(1e-5));
    vec3 tDelta = SF_CELL * inv;
    vec3 tNext = ((id + max(sg, 0.0)) * SF_CELL - ro) * sg * inv;
    int nCells = osSteps(12.0, 22.0, detail);
    float bRad;
    vec4 berth = sfBerth(ro.z, bRad);
    for (int i = 0; i < 22; i++) {
        if (i >= nCells) break;
        vec4 rk = sfRockAt(id, berth, bRad);
        if (rk.w > 0.0) {
            vec3 oc = ro - rk.xyz;
            float b = dot(oc, rd);
            float h = b * b - dot(oc, oc) + rk.w * rk.w;
            if (h > 0.0) {
                float sh = sqrt(h);
                float t = max(-b - sh, 0.0);
                float t1 = -b + sh;
                // march in the rock's own frame: the tumble is one rotation per rock
                vec3 lo = sfSpin(oc, id, time);
                vec3 ld = sfSpin(rd, id, time);
                vec3 fo;
                mat3 F = sfFacets(id, rk.w, fo);
                // a ray that runs out of steps while grazing a face still
                // counts as a hit, so flat faces never show see-through holes
                for (int j = 0; j < 20; j++) {
                    if (t > t1 || t > tmax) break;
                    vec3 q = lo + ld * t;
                    float d = sfRock(q, id, rk.w, F, fo);
                    if (d < 0.002 * t || (j == 19 && d < 0.04 * rk.w)) {
                        nrm = sfUnspin(sfRockNormal(q, id, rk.w, F, fo), id, time);
                        hitRock = vec4(id, rk.w);
                        hitQ = q;
                        return t;
                    }
                    t += max(d * 0.75, 0.01);
                }
            }
        }
        vec3 m = step(tNext, tNext.yzx) * step(tNext, tNext.zxy);
        if (dot(m, tNext) > tmax) break;
        id += m * sg;
        tNext += m * tDelta;
    }
    return -1.0;
}

// Star streaks: in each angular sector around the vanishing point a star
// rushes toward the camera; its streak runs from where it is now back to where
// it was a moment ago, so streaks lengthen with speed and shrink to points in
// a brake. Each streak tapers from a bright head to a blue-shifted tail, and a
// burst turns the field into a coloured tunnel. The angle is taken in world
// roll, so the field banks with the view.
vec3 sfWarp(vec2 p, vec2 sunS, float roll, float z, float v, float fov, float tHit, SfPal P, VisualUniforms u, float detail) {
    float r = length(p);
    float a = atan2_(p.y, p.x) + roll;
    float px = 2.0 / max(u.resolution.y, 1.0);
    float rush = saturate((v - 1.0) / 3.0);
    float len = 0.08 + 0.55 * v * v;          // world distance the streak spans
    vec3 col = vec3(0.0);
    vec3 spark = sfTreble(P, 0.3, u);
    vec3 shift = mix(vec3(0.35, 0.6, 1.6), sfRim(P, 0.7, u), 0.35);
    // the streaks are sunlit dust: warm gold on the sun's side of the view,
    // palette-cool away from it; a few ice grains flare in the beat accent
    vec2 dir = p / max(r, 1e-4);
    float sunSide = saturate(dot(dir, sunS) * 0.65 + 0.35);
    sunSide *= sunSide;
    vec3 accent = sfPeak(P, 0.12, u);
    int nl = osSteps(2.0, 4.0, detail);
    for (int l = 0; l < 4; l++) {
        if (l >= nl) break;
        float fl = float(l);
        float n = 110.0 + 47.0 * fl;
        float ca = a * (n / 6.2831853) + fl * 0.37;
        float cell = mod(floor(ca), n);
        float f = fract(ca);
        float h1 = hash21(vec2(cell, fl * 7.1 + 1.0));
        float h2 = hash21(vec2(cell, fl * 7.1 + 2.0));
        float h3 = hash21(vec2(cell, fl * 7.1 + 3.0));
        float span = 70.0;
        float d = span * fract(h2 - z / span) + 0.5;
        float rr = 2.2 + 6.0 * h3;               // distance from the flight axis
        float rs = rr * fov / d;
        float rt = rr * fov / (d + len);
        float along = saturate((r - rt) / max(rs - rt, 1e-4));   // 0 tail .. 1 head
        float arc = (f - 0.2 - 0.6 * h1) * (6.2831853 / n) * r;
        float dr = max(max(rt - r, r - rs), 0.0);
        float wid = px * (0.55 + 0.9 * saturate(4.0 / d)) * (0.55 + 0.65 * along);
        float g = wid * wid / (dr * dr + arc * arc + wid * wid);
        float fade = smoothstep(span, span * 0.5, d) * step(d, tHit) * step(0.45, h2);
        fade *= (0.25 + 0.75 * saturate(8.0 / d)) * smoothstep(0.08, 0.5, r);
        fade *= mix(1.0, 0.12 + 0.88 * along * along, saturate(v - 0.6));
        // colour temperature varies; tails blue-shift in a burst
        vec3 coolT = sfPal(P, 0.5 + 0.3 * h1);
        coolT = mix(coolT * coolT * 2.2, vec3(0.45, 0.65, 1.4), 0.35);
        vec3 tint = mix(coolT, vec3(1.5, 0.78, 0.36), sunSide * (0.6 + 0.4 * h1));
        tint = mix(tint, spark, 0.25 * h3);
        float ice = step(0.86, h3);
        tint = mix(tint, accent * (1.2 + 2.0 * u.bassImpact), ice * along);
        tint = mix(tint, shift, rush * (1.0 - along));
        tint = mix(tint, vec3(1.1, 1.05, 1.0), 0.6 * pow(along, 12.0));
        col += tint * g * g * fade * (0.8 + 0.5 * u.treble) * (1.0 + 0.5 * rush);
    }
    // the tunnel: soft coloured flecks streaming outward round the rim of the
    // view in a burst, kept to the edges so the centre never washes out
    float fleck = sfNoise(vec3(dir * 30.0, 4.0 / max(r, 0.05) - z * 0.08));
    float tun = smoothstep(0.35, 1.1, r) * smoothstep(0.55, 0.85, fleck) * rush * rush;
    col += mix(shift, sfPal(P, 0.6 + 0.2 * fleck + 0.03 * u.beatPhase), 0.5) * tun * 0.07;
    return col * 1.4;
}

// Stars on the sky sheet: a few bright ones with diffraction spikes and a
// fainter field that crowds into a galactic band.
vec3 sfStars(vec2 s, float band, VisualUniforms u) {
    vec3 col = vec3(0.0);
    float px = 0.7 / max(u.resolution.y, 1.0);   // a pixel on the sky sheet
    float tm = mod(u.time, 600.0);
    for (int l = 0; l < 2; l++) {
        float sc = l == 0 ? 34.0 : 120.0;
        vec2 g = s * sc;
        vec2 id = floor(g);
        vec2 h = hash22(id + float(l) * 31.7);
        vec2 dlt = (fract(g) - 0.2 - 0.6 * h) / sc;
        float rs = saturate(u.resolution.y / 1000.0);
        float on = l == 0 ? step(0.8, h.y) : step(0.985 - 0.42 * band * (0.45 + 0.55 * rs), h.y);
        float sz = px * (l == 0 ? 1.2 : 0.75);
        float tw = 0.75 + 0.25 * sin(tm * (1.5 + 3.0 * h.x) + h.y * 40.0);
        float b = exp(-dot(dlt, dlt) / (sz * sz));
        vec3 tint = mix(vec3(0.75, 0.88, 1.3), vec3(1.3, 0.95, 0.7), h.x);
        // the faint field dims at low render scales, where each star covers more
        // of the frame, so level 0 is not a snowstorm
        float mag = l == 0 ? 0.6 + 3.0 * pow(fract(h.x * 7.31), 3.0) : (0.35 + 0.4 * h.x) * (0.5 + 0.5 * rs);
        vec3 sc0 = tint * b * mag;
        if (l == 0) {
            // spikes on the brightest
            vec2 ad = abs(dlt) / px;
            float spk = exp(-ad.x * 0.9) * exp(-ad.y * 0.05) + exp(-ad.y * 0.9) * exp(-ad.x * 0.05);
            sc0 += tint * spk * 0.025 * mag * mag * step(0.88, fract(h.x * 7.31));
        }
        col += sc0 * on * tw * (1.0 + 0.6 * u.treble);
    }
    return col;
}

// Nebula: domain-warped 2D sheets on the sky. Cool palette gas, warm emission
// cores where a second field runs hot, teal fringes, bright filaments along
// the ridges of the warped noise, and dark dust lanes on a nearer sheet.
vec3 sfNebula(vec2 s, vec3 ro, float rush, SfPal P, VisualUniforms u, float detail, out float dust) {
    float dens = mix(0.45, 1.5, u.param2);
    float oct = mix(2.6, 4.4, detail);
    float tm = mod(u.time, 600.0);
    vec2 q = s * 1.6 + vec2(3.1, 7.7) + ro.xy * 0.004;
    vec2 wq = vec2(sfFbm(q + vec2(0.0, tm * 0.006), oct - 2.0), sfFbm(q + vec2(5.2, 1.3), oct - 2.0));
    float gas = sfFbm(q + 1.8 * wq, oct);
    float big = smoothstep(0.38, 0.8, vnoise(s * 0.55 + 4.0));
    float g = pow(saturate((gas - 0.4) * 2.6), 2.2) * (0.03 + 0.97 * big) * dens;
    // filaments: thin bright ridges of a finer warped field
    float fil = sfFbm(q * 2.2 + 2.6 * wq + 11.0, oct - 1.0);
    float ridge = pow(saturate(1.0 - abs(2.0 * fil - 1.0) * 1.6), 6.0) * smoothstep(0.25, 0.6, gas) * big * dens;
    // a nearer, finer dust sheet drifts faster: parallax against the gas
    vec2 q2 = s * 3.2 + vec2(9.0, 2.0) + ro.xy * 0.012 + vec2(0.0, mod(ro.z * 0.0008, 100.0));
    float lane = sfFbm(q2 + wq, oct - 2.0);
    dust = smoothstep(0.42, 0.66, lane) * (0.4 + 0.6 * big) * saturate(dens);
    vec3 cool = sfPal(P, 0.6 + 0.3 * wq.x - 0.12 * rush);
    cool = cool * cool;
    vec3 warm = mix(vec3(1.0, 0.34, 0.14), sfPeak(P, 0.25, u), 0.25);
    vec3 teal = vec3(0.2, 0.75, 0.85);
    // builds and bursts let the warm emission spread through the gas
    float hot = smoothstep(0.45, 0.68, wq.y + 0.25 * gas + 0.14 * rush + 0.06 * u.bassImpact);
    vec3 c = mix(cool, warm * warm * 0.9, hot);
    c += teal * 0.25 * smoothstep(0.5, 0.0, abs(hot - 0.5) * 2.0) * (1.0 - hot);
    // hot cores where the gas is densest
    float core = pow(saturate((gas - 0.55) * 3.0), 3.0);
    c += mix(vec3(1.2, 0.85, 0.6), sfPeak(P, 0.4 + wq.x * 0.2, u), 0.4) * core * 0.6;
    vec3 neb = c * g + mix(cool * 1.4, warm, hot) * ridge * 0.35;
    return 0.2 * neb * (1.0 - 0.85 * dust) * (0.85 + 0.25 * u.bassImpact + 0.2 * u.mid + 0.15 * hot * u.bass);
}

// Planet k of the procession along the route: xyz = centre, w = radius. Each
// sits far enough off the route that its rings never cross the lane.
const float SF_PSPACE = 1800.0;
vec4 sfPlanetAt(float k, out vec4 look) {
    float kk = mod(k, 97.0);
    float h1 = hash21(vec2(kk, 3.1));
    float h2 = hash21(vec2(kk, 5.7));
    float h3 = hash21(vec2(kk, 8.3));
    float h4 = hash21(vec2(kk, 9.9));
    float ringed = step(0.35, h3);
    float ang = (h2 < 0.5 ? 3.1415927 : 0.0) + (fract(h2 * 2.0) - 0.5) * 1.3;
    if (kk < 0.5) {            // the first world: ringed, warm, low on the left
        h1 = 0.55; ringed = 1.0; ang = 3.55; h4 = 0.8;
    }
    float pr = 140.0 + 120.0 * h1;
    float off = pr * (ringed > 0.5 ? 2.7 : 1.5) + 60.0;
    look = vec4(ringed, h4, fract(h1 * 5.3 + h2), h3);
    return vec4(off * cos(ang), off * sin(ang), k * SF_PSPACE + 700.0, pr);
}

// Shade planet k over col (sky behind it). Returns the planet hit distance.
float sfPlanet(float k, vec3 ro, vec3 rd, vec3 sunDir, SfPal P, VisualUniforms u, inout vec3 col) {
    vec4 look;
    vec4 pl = sfPlanetAt(k, look);
    vec3 pc = vec3(pl.xy, pl.z);
    float pr = pl.w;
    vec3 oc = ro - pc;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - pr * pr;
    float h = b * b - c;
    float tPlanet = 1e9;
    float warmth = look.y;
    vec3 atm = mix(mix(sfRim(P, 0.55, u), vec3(0.45, 0.75, 1.4), 0.4), vec3(1.0, 0.7, 0.5), 0.3 * warmth);
    if (h > 0.0 && b < 0.0) {
        tPlanet = -b - sqrt(h);
        vec3 pos = ro + rd * tPlanet;
        vec3 n = (pos - pc) / pr;
        vec3 rn = normalize(vec3(0.3 + 0.4 * (look.w - 0.5), 1.0, -0.5 + 0.6 * (look.z - 0.5)));
        float lat = dot(n, rn);
        float lon = dot(n, normalize(cross(rn, vec3(0.0, 0.0, 1.0))));
        float turb = sfFbm(vec2(lat * 9.0 + look.z * 7.0, lon * 2.5 + mod(u.time, 600.0) * 0.01), 3.0);
        float bands = sin(lat * (16.0 + 14.0 * look.z) + 6.0 * turb + 2.0 * sin(lat * 7.0)) * 0.5 + 0.5;
        vec3 c1 = sfPal(P, look.z + 0.1 * turb);
        vec3 c2 = sfPal(P, look.z + 0.3 + 0.1 * bands);
        vec3 w1 = vec3(0.95, 0.6, 0.32);
        vec3 w2 = vec3(0.55, 0.26, 0.14);
        vec3 surf = mix(mix(c1, w1, warmth), mix(c2, w2, warmth), bands) * 0.85;
        // a storm eye on some worlds
        vec2 se = vec2(lat - 0.25, lon - 0.3);
        surf = mix(surf, w1 * 1.1, smoothstep(0.08, 0.0, length(se * vec2(2.0, 1.0))) * step(0.5, look.w));
        float ndl = dot(n, sunDir);
        float dif = saturate(ndl);
        float wrapL = saturate(ndl * 0.5 + 0.5);
        float rsh = 1.0;
        if (look.x > 0.5) {
            float ts = -dot(pos - pc, rn) / dot(sunDir, rn);
            float rr = length(pos + sunDir * ts - pc) / pr;
            rsh = ts > 0.0 ? 1.0 - 0.75 * smoothstep(1.3, 1.4, rr) * (1.0 - smoothstep(2.2, 2.3, rr)) : 1.0;
        }
        col = surf * SF_SUN * (1.6 * dif * rsh) + sfFog(P, 0.6, u) * 0.01;
        col += surf * sfPal(P, 0.6) * 0.02 * (1.0 - dif) * look.x;
        // atmosphere: a scattering rim that wraps onto the lit side
        float fr = pow(1.0 - saturate(dot(n, -rd)), 2.0);
        col += atm * fr * (0.06 + 2.6 * wrapL * wrapL * wrapL);
        col += SF_SUN * pow(saturate(dot(reflect(rd, n), sunDir)), 40.0) * 0.2 * rsh;
        // terminator glow
        col += vec3(1.0, 0.45, 0.25) * exp(-abs(ndl) * 14.0) * 0.1;
    } else if (b < 0.0) {
        // atmosphere halo just outside the limb, brightest on the lit side
        float miss = sqrt(max(-h, 0.0)) / pr;
        vec3 lp = normalize(oc + rd * max(-b, 0.0) + 1e-4);
        float lit = saturate(dot(lp, sunDir) * 0.6 + 0.4);
        col += atm * exp(-miss * 6.0) * 1.3 * lit * lit;
    }
    if (look.x > 0.5) {
        vec3 rn = normalize(vec3(0.3 + 0.4 * (look.w - 0.5), 1.0, -0.5 + 0.6 * (look.z - 0.5)));
        float dn = dot(rd, rn);
        float tr = abs(dn) > 1e-5 ? -dot(oc, rn) / dn : -1.0;
        if (tr > 0.0 && tr < tPlanet) {
            vec3 rp = ro + rd * tr;
            float rr = length(rp - pc) / pr;
            float ring = smoothstep(1.3, 1.36, rr) * (1.0 - smoothstep(2.2, 2.3, rr));
            // fine ringlets, a dark division and a bright inner band; the
            // ringlets fade out with distance so they never alias
            float aa = saturate(tr * 0.0006);
            float grooves = mix(vnoise(vec2(rr * 70.0, 0.5)) * 0.6 + vnoise(vec2(rr * 210.0, 3.5)) * 0.4, 0.5, aa);
            ring *= smoothstep(0.15, 0.75, grooves) * (1.0 - 0.9 * smoothstep(1.72, 1.735, rr) * (1.0 - smoothstep(1.79, 1.805, rr)));
            ring *= 1.0 + 0.8 * smoothstep(1.45, 1.55, rr) * (1.0 - smoothstep(1.65, 1.72, rr));
            vec3 rel = rp - pc;
            float sb = dot(rel, sunDir);
            float shadow = sb < 0.0 ? smoothstep(pr * 0.95, pr * 1.05, length(rel - sunDir * sb)) : 1.0;
            float lit = 0.2 + 1.1 * shadow * (0.5 + 0.5 * abs(dot(sunDir, rn)));
            // spectrum: each band lights its own ring lane, accents only
            float eq = bandAt(u, saturate((rr - 1.3) / 1.0));
            vec3 rc = mix(sfPal(P, look.z + 0.5 + 0.25 * (rr - 1.3) + 0.1 * grooves), vec3(0.8, 0.7, 0.6), 0.45) * SF_SUN * lit * 0.85;
            rc += sfPal(P, 0.75 + rr * 0.2 + 0.03 * u.beatPhase) * eq * eq * 1.6 * grooves;
            float fwd = 1.0 - abs(dn);
            col = mix(col, rc, saturate(ring) * (0.6 + 0.3 * fwd));
        }
    }
    return tPlanet;
}

// The alien skiff: a dark lens-shaped pod with twin forward prongs, its aft
// wrapped in a spinning ring-wing held on four diagonal struts.
float sfSkiff(vec3 q, float spin) {
    vec3 hr = vec3(1.25, 0.62, 3.3);
    float k0 = length(q / hr);
    float k1 = length(q / (hr * hr));
    float hull = k0 * (k0 - 1.0) / max(k1, 1e-4);
    vec3 pq = vec3(abs(q.x), q.y, q.z);
    vec3 pa = pq - vec3(0.72, -0.08, 1.2);
    vec3 ba = vec3(-0.34, -0.06, 3.9);
    float hh = saturate(dot(pa, ba) / dot(ba, ba));
    float d = osSmin(hull, length(pa - ba * hh) - mix(0.26, 0.06, hh), 0.35);
    vec2 w = abs(vec2(length(q.xy) - 2.35, q.z + 1.2)) - vec2(0.03, 0.5);
    float ring = length(max(w, 0.0)) + min(max(w.x, w.y), 0.0) - 0.08;
    vec2 dq = abs(rot2(spin) * q.xy);
    float strut = osBox(vec3((dq.x + dq.y) * 0.70710678 - 1.7, (dq.x - dq.y) * 0.70710678, q.z + 1.2), vec3(0.62, 0.05, 0.28));
    return min(d, min(ring, strut));
}

// The derelict: the stern half of a freighter, broken off raggedly, bare ribs
// where the plating is gone, a keel and a spine beam running on, a habitat
// ring with a bite torn out of it and two engine bells.
float sfWreck(vec3 q) {
    float hull = osBox(q - vec3(0.0, 0.0, -1.6), vec3(1.15, 0.9, 3.6));
    hull = max(hull, q.z - 1.6 - 0.45 * sin(q.x * 3.7 + 1.0) * sin(q.y * 4.3 + 2.0));
    float rz = q.z - 0.7 * floor(q.z / 0.7) - 0.35;
    float rib = max(osBox(vec3(q.xy, rz), vec3(1.15, 0.9, 0.05)), -osBox(vec3(q.xy, 0.0), vec3(1.0, 0.76, 1.0)));
    rib = max(rib, abs(q.z - 3.3) - 1.7);
    float keel = osBox(q - vec3(0.0, -0.8, 0.4), vec3(0.16, 0.12, 5.4));
    float spine = osBox(q - vec3(0.6, 0.84, 1.2), vec3(0.08, 0.08, 4.4));
    float ring = length(vec2(length(q.xy) - 2.4, q.z + 0.9)) - 0.26;
    ring = max(ring, -osBox(q - vec3(1.9, 1.9, -0.9), vec3(1.1, 1.0, 1.0)));
    vec2 aq = abs(q.xy);
    float spoke = min(osBox(vec3(aq.x - 1.75, q.y, q.z + 0.9), vec3(0.6, 0.07, 0.07)),
                      osBox(vec3(q.x, aq.y - 1.6, q.z + 0.9), vec3(0.07, 0.72, 0.07)));
    vec3 eq = vec3(abs(q.x) - 0.55, q.y, q.z + 5.7);
    float bell = max(length(eq.xy) - 0.3 - 0.22 * saturate(0.5 - eq.z), abs(eq.z) - 0.55);
    return min(min(min(hull, rib), min(keel, spine)), min(min(ring, spoke), bell));
}

float sfEvSdf(vec3 q, float kind, float spin) { return kind < 0.5 ? sfSkiff(q * 0.7692, spin) * 1.3 : sfWreck(q * 0.6667) * 1.5; }

vec3 sfEvNormal(vec3 q, float kind, float spin, float e) {
    vec2 k = vec2(1.0, -1.0);
    return normalize(k.xyy * sfEvSdf(q + k.xyy * e, kind, spin) + k.yyx * sfEvSdf(q + k.yyx * e, kind, spin) +
                     k.yxy * sfEvSdf(q + k.yxy * e, kind, spin) + k.xxx * sfEvSdf(q + k.xxx * e, kind, spin) + 1e-6);
}

// March a visitor in its own frame between the bounding-sphere hits t0..t1.
float sfEvMarch(vec3 lo, vec3 ld, float t0, float t1, int n, float kind, float spin) {
    float t = t0;
    for (int j = 0; j < 64; j++) {
        if (j >= n || t > t1) break;
        float d = sfEvSdf(lo + ld * t, kind, spin);
        if (d < 0.0012 * t + 0.002) return t;
        t += d * 0.85;
    }
    return -1.0;
}

// A soft glow round a world point, at least a couple of pixels wide.
float sfGlowPt(vec3 ro, vec3 rd, vec3 pnt, float sig, float pxw, out float tp) {
    vec3 v = pnt - ro;
    tp = dot(v, rd);
    vec3 perp = v - rd * max(tp, 0.0);
    float sg = max(sig, max(tp, 0.0) * pxw);
    return tp > 0.0 ? exp(-dot(perp, perp) / (sg * sg)) * sig * sig / (sg * sg) : 0.0;
}

// The leviathan: a vast manta-like silhouette drifting through the gas on the
// sky sheet. It swallows the light behind it; the sun rims its lit edge and
// rows of photophores pulse along its flanks with the bass.
void sfLeviathan(vec2 s, SfEv E, vec2 sunSky, float px, SfPal P, VisualUniforms u, inout vec3 col) {
    vec2 hd = normalize(vec2(-E.side, 0.25 * (E.h2 - 0.5)));
    vec2 c = vec2(E.side * (0.21 - 0.36 * E.e), 0.05 + 0.1 * (E.h2 - 0.5));
    const float L = 0.15;
    vec2 d = s - c;
    if (dot(d, d) > L * L * 5.0) return;
    vec2 sd = vec2(-hd.y, hd.x);
    vec2 q = vec2(dot(d, hd), dot(d, sd)) / L;
    float tm = mod(u.time, 600.0);
    float sw = tm * 1.1;
    float y = q.y - 0.07 * sin(q.x * 2.6 + sw) * saturate(0.9 - q.x);
    float ay = abs(y);
    float xs = q.x + 0.45 * ay;
    float body = 0.12 * sqrt(saturate(1.0 - (q.x - 0.3) * (q.x - 0.3) / 0.72));
    float tail = 0.05 * saturate((q.x + 1.9) / 1.4) * step(q.x, -0.3);
    float fin = 0.62 * (0.8 + 0.2 * sin(sw * 0.55)) * exp(-(xs - 0.12) * (xs - 0.12) / 0.07);
    float W = max(body, max(tail, fin));
    float dd = ay - W;
    float aa = 0.012 + px / L;
    float a = smoothstep(aa, -aa, dd) * E.fade;
    col *= 1.0 - 0.9 * a;
    vec2 nrm = (y >= 0.0 ? 1.0 : -1.0) * sd;
    vec2 ts = sunSky - c;
    float sunSide = saturate(dot(nrm, ts / max(length(ts), 1e-4)) * 0.7 + 0.3);
    vec3 bio = mix(vec3(0.2, 0.95, 1.1), sfPeak(P, 0.2, u), 0.3);
    float rim = exp(-abs(dd) * 40.0) * E.fade;
    col += (SF_SUN * (0.012 + 0.09 * sunSide * sunSide) + bio * 0.02) * rim;
    float cx = fract(q.x * 9.0) - 0.5;
    float ry = (ay - 0.55 * W) * 9.0;
    float wave = pow(0.5 + 0.5 * sin(q.x * 5.0 + tm * 2.6), 4.0) * (0.35 + 1.3 * u.bass);
    float spot = exp(-(cx * cx + ry * ry) * 14.0) * step(-1.6, q.x) * step(0.04, W);
    vec2 eyeQ = vec2(q.x - 0.98, ay - 0.06);
    col += bio * (spot * wave * 0.7 + exp(-dot(eyeQ, eyeQ) * 2500.0) * 1.6) * a;
}

// A comet crossing far off: a bright nucleus in a soft coma, a straight blue
// ion tail and a curved warm dust tail, both blown straight away from the sun.
void sfComet(vec2 s, SfEv E, vec2 sunSky, float px, SfPal P, VisualUniforms u, inout vec3 col) {
    vec2 hc = vec2(E.side * (0.36 - 0.6 * E.e), -0.03 + 0.16 * (E.h2 - 0.5) + 0.05 * E.e);
    vec2 td = hc - sunSky;
    td /= max(length(td), 1e-4);
    vec2 tn = vec2(-td.y, td.x);
    vec2 d = s - hc;
    float x = dot(d, td);
    float y = dot(d, tn);
    if (x < -0.05 || x > 0.5 || abs(y) > 0.2) return;
    float lag = dot(vec2(-E.side, 0.08), tn) >= 0.0 ? -1.0 : 1.0;
    float tm = mod(u.time, 600.0);
    float r2 = dot(d, d);
    vec3 c = vec3(2.2, 2.3, 2.4) * exp(-r2 / (6e-6 + px * px)) * 1.2;
    c += mix(vec3(0.6, 0.9, 1.2), SF_SUN, 0.4) * exp(-sqrt(r2) / 0.018) * 0.6;
    float xp = max(x, 0.0);
    float wi = 0.003 + 0.022 * xp + px;
    float str = 0.6 + 0.4 * vnoise(vec2(y / wi * 1.5, xp * 25.0 - tm * 2.5));
    c += mix(vec3(0.35, 0.65, 1.5), sfPal(P, 0.55), 0.3) * exp(-y * y / (wi * wi)) * exp(-xp / 0.26) *
         smoothstep(-0.005, 0.01, x) * str * 0.8;
    float yd = y - lag * 1.1 * xp * xp;
    float wd = 0.006 + 0.08 * xp;
    c += SF_SUN * vec3(1.1, 0.95, 0.8) * exp(-yd * yd / (wd * wd)) * exp(-xp / 0.15) * smoothstep(-0.01, 0.02, x) * 0.45;
    col += c * E.fade;
}

// Lantern jellies: a tiny school drifting by just off the lane, translucent
// bells that contract on the beat, trailing slow tendrils. Billboards at
// world points, hidden behind nearer rocks and fogged with depth.
void sfJellies(vec2 p, vec3 ro, vec3 rt, vec3 cu, vec3 fw, float fov, SfEv E, vec2 sunS, float zHit,
               SfPal P, VisualUniforms u, inout vec3 col) {
    float tm = mod(u.time, 600.0);
    float px = 2.0 / max(u.resolution.y, 1.0);
    vec3 glowC = mix(vec3(0.3, 1.0, 1.25), sfPeak(P, 0.1, u), 0.3);
    vec3 tipC = mix(sfPal(P, 0.85), vec3(1.0, 0.5, 0.8), 0.4);
    float pulse = u.bassImpact;
    for (int i = 0; i < 7; i++) {
        float fi = float(i);
        vec3 hj = vec3(hash31(vec3(fi, E.h, 3.0)), hash31(vec3(fi, E.h, 7.0)), hash31(vec3(fi, E.h, 9.0))) - 0.5;
        float zj = E.pos.z + 9.0 * fi + 4.0 * hj.z;
        vec3 c = vec3(sfPath(zj).xy + E.pos.xy + vec2(E.side * 2.4 * hj.x, 2.0 * hj.y + 0.3 * sin(tm * 0.7 + fi * 2.0)), zj);
        float sz = 0.6 + 0.5 * fract(hj.x * 7.0 + hj.y * 3.0);
        vec3 v = c - ro;
        float dz = dot(v, fw);
        if (dz < 0.8 || dz > zHit) continue;
        float sc = sz * fov / dz;
        vec2 q = (p - vec2(dot(v, rt), dot(v, cu)) * fov / dz) / sc;
        if (abs(q.x) > 2.2 || q.y > 1.3 || q.y < -4.8) continue;
        float aa = max(px / sc, 0.03);
        float pl = pulse * (1.0 - 0.3 * fi);
        vec2 bq = q / vec2(1.0 - 0.14 * pl, 0.85 + 0.12 * pl);
        float bd = length(bq) - 1.0;
        float margin = q.y + 0.12 - 0.07 * cos(q.x * 14.0);
        float bell = smoothstep(aa, -aa, bd) * smoothstep(-aa, aa, margin);
        float rim = bell * (0.2 + 0.8 * smoothstep(-0.5, 0.0, bd));
        float canal = pow(0.5 + 0.5 * cos(atan2_(q.x, q.y + 0.35) * 8.0), 6.0) * bell * 0.4;
        float tnd = 0.0;
        float yy = -q.y;
        for (int j = 0; j < 5; j++) {
            float fj = float(j) - 2.0;
            float x = fj * 0.27 * (1.0 - 0.15 * pl) * (1.0 + 0.2 * yy) + 0.2 * sin(yy * 2.2 - tm * 1.8 + fj * 1.3 + fi) * saturate(yy * 0.6);
            float w = aa + 0.045;
            tnd += exp(-(q.x - x) * (q.x - x) / (w * w)) * smoothstep(-0.05, 0.3, yy) * (1.0 - smoothstep(2.0, 4.3 + 0.3 * fj, yy));
        }
        vec2 qn = q + vec2(0.0, 0.3);
        float lit = saturate(dot(qn / max(length(qn), 1e-4), sunS) * 0.5 + 0.5);
        float fog = (1.0 - smoothstep(50.0, 120.0, dz)) * E.fade;
        vec3 jc = glowC * (rim * 0.8 + canal) * (0.6 + 0.8 * u.bass) + SF_SUN * bell * lit * lit * 0.3 + tipC * tnd * 0.3;
        col = col * (1.0 - 0.35 * saturate(bell + 0.4 * tnd) * fog) + jc * fog;
    }
}

// Skiff surfaces: a near-black pod with a palette sheen, bioluminescent veins,
// a glowing seam and eye; a pale gold ring-wing whose inner face carries a
// chase of running lights.
vec3 sfShadeSkiff(vec3 q, vec3 nq, vec3 n, vec3 rd, vec3 sunDir, float spin, float bassL, vec3 glow, SfPal P, VisualUniforms u) {
    float ndl = dot(n, sunDir);
    float dif = saturate(ndl);
    float ndv = saturate(-dot(n, rd));
    float fre = pow(1.0 - ndv, 3.0);
    float sp = saturate(dot(reflect(rd, n), sunDir));
    vec3 fill = sfPal(P, 0.65);
    vec2 w = abs(vec2(length(q.xy) - 2.35, q.z + 1.2)) - vec2(0.03, 0.5);
    float ringD = length(max(w, 0.0)) + min(max(w.x, w.y), 0.0) - 0.08;
    vec2 sq = rot2(spin) * q.xy;
    vec2 dq = abs(sq);
    float strutD = osBox(vec3((dq.x + dq.y) * 0.70710678 - 1.7, (dq.x - dq.y) * 0.70710678, q.z + 1.2), vec3(0.62, 0.05, 0.28));
    vec3 c;
    if (min(ringD, strutD) < 0.02) {
        vec3 alb = vec3(0.5, 0.42, 0.3);
        c = alb * SF_SUN * (1.8 * dif) + alb * fill * 0.3 + SF_SUN * pow(sp, 30.0) * 0.9 + fill * fre * 0.15;
        float inner = step(dot(nq.xy, q.xy), 0.0) * step(ringD, 0.02);
        float lights = pow(0.5 + 0.5 * cos(atan2_(sq.y, sq.x) * 12.0), 24.0);
        c += glow * (0.12 * inner + lights * (0.5 + inner) * (1.0 + 2.0 * u.bassImpact));
    } else {
        vec3 alb = mix(vec3(0.025, 0.028, 0.035), sfPal(P, 0.5 + 0.4 * fre + 0.05 * q.z), 0.12);
        c = alb * SF_SUN * (2.2 * dif) + alb * fill * 0.45 + SF_SUN * (pow(sp, 70.0) * 1.4 + pow(sp, 12.0) * 0.08);
        c += sfPal(P, 0.55 + 0.35 * fre) * fre * 0.18;
        float vein = pow(saturate(1.0 - abs(sin(q.z * 3.2 + 1.6 * sin(q.x * 2.4)))), 18.0) * smoothstep(0.0, 0.25, q.y);
        float seam = smoothstep(0.05, 0.0, abs(q.y + 0.02 * q.z)) * step(abs(q.x), 1.3);
        float eye = smoothstep(2.4, 3.1, q.z) * smoothstep(0.22, 0.0, abs(q.y + 0.12)) * smoothstep(0.5, 0.2, abs(q.x));
        c += glow * (vein * 0.25 * (0.5 + bassL) + seam * 0.9 + eye * 2.2);
    }
    return c;
}

// Derelict surfaces: scorched grey plating in panels, a faded paint band, the
// sun's rim on its edges and a few windows still burning dimly.
vec3 sfShadeWreck(vec3 q, vec3 nq, vec3 n, vec3 rd, vec3 sunDir, SfPal P, VisualUniforms u) {
    float ndl = dot(n, sunDir);
    float dif = saturate(ndl);
    float ndv = saturate(-dot(n, rd));
    float sp = saturate(dot(reflect(rd, n), sunDir));
    vec3 g = q * vec3(1.7, 1.7, 0.9);
    vec3 m = 0.5 - abs(fract(g) - 0.5) + step(0.7, abs(nq));
    float line = smoothstep(0.0, 0.05, min(m.x, min(m.y, m.z)));
    float tone = 0.7 + 0.3 * hash31(floor(g));
    float scorch = smoothstep(0.35, 0.75, sfNoise(q * 0.8 + 3.0));
    vec3 alb = vec3(0.3, 0.29, 0.27) * tone * (0.4 + 0.6 * line);
    float side = step(0.7, abs(nq.x));
    alb = mix(alb, vec3(0.34, 0.1, 0.05), 0.85 * side * step(abs(q.z + 3.2), 0.6));
    alb *= 1.0 - 0.75 * scorch;
    vec3 fill = sfPal(P, 0.65);
    vec3 c = alb * SF_SUN * (2.4 * dif) + alb * fill * (0.3 + 0.15 * saturate(-n.z));
    c += SF_SUN * pow(sp, 18.0) * 0.25 * line * (1.0 - scorch);
    float edge = pow(1.0 - ndv, 4.0);
    c += SF_SUN * edge * saturate(ndl + 0.3) * 0.6 + sfRim(P, 0.7, u) * edge * saturate(-ndl) * 0.2;
    float wz = q.z * 1.5;
    float win = side * smoothstep(0.09, 0.05, abs(q.y - 0.3)) * smoothstep(0.35, 0.3, abs(fract(wz) - 0.5)) *
                step(0.55, hash31(vec3(floor(wz), sign(q.x), 5.0))) * step(q.z, 1.2);
    c += vec3(1.0, 0.62, 0.3) * win * 1.4 * (0.8 + 0.2 * sin(mod(u.time, 600.0) * 7.0 + floor(wz)));
    return c;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    SfPal P = sfPalLoad(u);

    float speed = mix(4.0, 16.0, u.param0);
    float surge = 2.5 * mix(0.5, 1.5, u.param0);
    vec2 fl = osFlight(u, speed, surge);
    float z = fl.x;
    float rush = saturate((fl.y - 1.0) / 3.5);
    float lull = saturate(1.0 - fl.y);
    vec3 ro = sfPath(z);
    vec3 ta = sfPath(z + 6.0);

    vec3 fw = normalize(ta - ro);
    float roll = osBank(u, mix(0.0, 0.45, u.param1)) + 0.25 * sin(mod(u.time, 600.0) * 0.11);
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(fw, up));
    vec3 cu = cross(rt, fw);
    float fov = 1.2 - 0.18 * rush + 0.08 * lull;
    vec3 rd = normalize(p.x * rt + p.y * cu + fov * fw);

    vec3 sunDir = normalize(vec3(0.62, 0.36, 0.5));
    vec2 sunS = vec2(dot(sunDir, rt), dot(sunDir, cu));
    sunS /= max(length(sunS), 1e-4);
    float bassL = 0.5 * u.bass + 0.5 * u.bassImpact;
    float tm = mod(u.time, 600.0);

    // asteroid field first: it hides the sky behind its near rocks
    vec3 n;
    vec4 rk;
    vec3 lq;
    float t = sfField(ro, rd, 90.0, u.time, detail, n, rk, lq);
    // this slot's visitor; -1 when none is on
    SfEv E = sfEventAt(z);
    float evType = E.e > 0.0 && E.e < 1.0 ? E.type : -1.0;
    vec3 evGlow = mix(vec3(0.25, 1.25, 0.95), sfPeak(P, 0.15, u), 0.3);
    float hit = t > 0.0 ? 1.0 : 0.0;
    // the sky and the worlds behind a near, unfogged rock are never seen
    vec3 col = vec3(0.0);
    if (hit < 0.5 || t > 50.0) {
        // sky sheet coordinates: smooth over the forward hemisphere
        vec2 s = rd.xy / (rd.z + 1.35);
        float pxS = 0.8 / max(u.resolution.y, 1.0);
        vec2 sunSky = sunDir.xy / (sunDir.z + 1.35);
        // the wormhole bends the sky sheet itself: outside its throat the sky
        // is lensed (stars smear into arcs), inside lies another, swirling sky
        float whR = 0.0;
        float whr = 1.0;
        float whA = 0.0;
        if (evType > 2.5 && evType < 3.5) {
            float open = smoothstep(0.0, 0.3, E.e) * smoothstep(1.0, 0.7, E.e);
            vec2 whC = vec2(E.side * (0.07 + 0.1 * E.h2), -0.06 + 0.12 * fract(E.h2 * 7.3));
            whR = 0.055 * open;
            vec2 wd = s - whC;
            whr = length(wd);
            if (whR > 1e-4 && whr < 5.0 * whR) {
                vec2 dir = wd / max(whr, 1e-5);
                whA = atan2_(dir.y, dir.x);
                if (whr > whR) {
                    s = whC + dir * (whr - whR * whR / whr * smoothstep(5.0 * whR, 2.5 * whR, whr));
                } else {
                    float sw = 2.2 * (1.0 - whr / whR) + tm * 0.3;
                    s = whC + vec2(4.1, -2.7) + (rot2(sw) * dir) * whR * whR / max(whr, 0.35 * whR);
                }
            }
        }
        float dust;
        col = sfNebula(s, ro, rush, P, u, detail, dust);
        // the galactic band: unresolved starlight, mottled, behind the dust
        float bd = dot(rd, normalize(vec3(0.35, 1.0, -0.3)));
        float band = exp(-bd * bd * 14.0);
        float mott = vnoise(s * 9.0 + 2.0) * 0.6 + vnoise(s * 23.0) * 0.4;
        col += mix(vec3(0.55, 0.6, 0.8), vec3(0.9, 0.75, 0.6), mott) * band * mott * 0.01 * (1.0 - 0.9 * dust);
        col += sfStars(s, band, u) * (1.0 - 0.9 * dust);
        if (whR > 1e-4 && whr < 5.0 * whR) {
            // the far side in a shifted hue family, spiral arms streaming into
            // a soft throat light, the photon ring and a faint outer halo
            vec3 ringC = mix(vec3(1.3, 1.15, 1.0), sfPeak(P, 0.15, u), 0.45);
            if (whr < whR) {
                float arms = pow(0.5 + 0.5 * sin(whA * 3.0 + log(max(whr / whR, 0.02)) * 6.0 - tm * 1.6), 4.0);
                col = col.zxy * 1.5 + luma(col) * sfPeak(P, 0.05, u) * 0.6;
                col += mix(ringC, evGlow, 0.5) * (arms * 0.12 * smoothstep(whR, 0.3 * whR, whr) + 0.5 * exp(-whr / (0.22 * whR)));
            }
            // a sharp photon ring, a fainter coloured echo outside it, a soft halo
            float dr = (whr - whR) / (0.03 * whR + pxS);
            float dr2 = (whr - 1.22 * whR) / (0.05 * whR + pxS);
            float spark = 0.75 + 0.25 * sin(whA * 5.0 + tm * 0.9) * sin(whA * 3.0 - tm * 0.6);
            col += ringC * exp(-dr * dr) * (1.1 + 0.4 * u.bassImpact) * spark;
            col += mix(sfPeak(P, 0.45, u), evGlow, 0.3) * (exp(-dr2 * dr2) * 0.3 + 0.05 * exp(-abs(whr - whR) / (0.6 * whR)));
        }
        if (evType > 3.5 && evType < 4.5) sfComet(s, E, sunSky, pxS, P, u, col);

        // the star: a hot core, a warm halo and an anamorphic streak
        float sd = saturate(dot(rd, sunDir));
        col += vec3(3.0, 2.6, 2.2) * pow(sd, 1400.0) * 3.0;
        col += SF_SUN * pow(sd, 60.0) * 0.45 * (1.0 - 0.6 * dust);
        col += SF_SUN * pow(sd, 8.0) * 0.04;
        float sz = dot(sunDir, fw);
        if (sz > 0.05) {
            vec2 sp = vec2(dot(sunDir, rt), dot(sunDir, cu)) * fov / sz;
            vec2 o = p - sp;
            col += mix(vec3(0.5, 0.7, 1.4), sfRim(P, 0.6, u), 0.4) *
                   exp(-abs(o.y) * 140.0) * exp(-abs(o.x) * 1.6) * 0.4 * smoothstep(0.05, 0.4, sz);
        }

        if (evType > 1.5 && evType < 2.5) sfLeviathan(s, E, sunSky, pxS, P, u, col);

        // the procession of worlds: the next one ahead, then the one after it
        float k0 = floor((z - 1600.0) / SF_PSPACE) + 1.0;
        sfPlanet(k0 + 1.0, ro, rd, sunDir, P, u, col);
        sfPlanet(k0, ro, rd, sunDir, P, u, col);
    }
    if (hit > 0.5) {
        vec3 pos = ro + rd * t;
        // fine pitted relief in the shading normal, strongest up close
        vec3 bq = lq * 7.0 / rk.w + rk.xyz;
        float near = saturate(1.5 - t * 0.04);
        vec3 b1 = vec3(sfNoise(bq), sfNoise(bq + 17.1), sfNoise(bq + 31.7)) - 0.5;
        vec3 bq2 = bq * 3.7 + 9.3;
        vec3 b2 = vec3(sfNoise(bq2), sfNoise(bq2 + 17.1), sfNoise(bq2 + 31.7)) - 0.5;
        vec3 bump = 0.5 * b1 + 0.45 * b2 * near;
        n = normalize(n + bump * 1.1 * near + 1e-5);
        float ndl = dot(n, sunDir);
        float dif = saturate(ndl);
        float ndv = saturate(-dot(n, rd));
        float grain = sfNoise(lq * 3.0 / rk.w + rk.xyz);
        float patchy = smoothstep(0.35, 0.65, sfNoise(bq * 0.7 + 5.0));
        // dark basalt with paler regolith on the crests; pits deep inside the
        // bounding sphere are occluded
        vec3 rock = mix(vec3(0.055, 0.05, 0.047), vec3(0.15, 0.12, 0.095), 0.3 + 0.35 * grain + 0.2 * patchy);
        // fine speckle and a network of dark fracture lines up close
        float crack = pow(saturate(1.0 - abs(b2.y) * 8.0), 3.0) * smoothstep(-0.05, 0.15, b1.z) * near;
        rock *= (0.9 + 0.3 * b2.x * near) * (1.0 - 0.75 * crack);
        float cav = smoothstep(0.35, 0.8, length(lq) / rk.w);
        rock *= 0.6 + 0.4 * cav;
        // warm key from the sun, cool fill from the nebula
        vec3 rc = rock * SF_SUN * (2.8 * dif);
        vec3 fill = sfPal(P, 0.65);
        rc += rock * fill * fill * (0.12 + 0.1 * saturate(-n.y)) + sfFog(P, 0.5, u) * 0.006;
        // the sun's rim: edges turned toward it catch a bright warm line
        float edge = pow(1.0 - ndv, 4.0);
        rc += SF_SUN * edge * saturate(ndl + 0.3) * (0.18 + 1.2 * pow(saturate(dot(rd, sunDir)), 3.0));
        rc += sfRim(P, 0.7, u) * edge * saturate(-ndl) * (0.08 + 0.4 * u.treble);
        float sp = saturate(dot(reflect(rd, n), sunDir));
        rc += SF_SUN * pow(sp, 10.0) * 0.12 * (0.3 + grain) * cav;
        // frost in the cracks catches the sun as tiny glints up close
        float frost = smoothstep(0.7, 0.8, sfNoise(bq * 2.1 + 41.0)) * near * near;
        rc += mix(vec3(1.2, 1.1, 1.0), sfPal(P, 0.6), 0.3) * frost * pow(sp, 24.0) * 3.0;
        // glowing seams in some rocks, lit by the bass
        float seam = 1.0 - abs(2.0 * sfNoise(lq * 1.7 / rk.w + rk.zxy * 1.3) - 1.0);
        float glowRock = step(0.72, hash31(rk.xyz + 11.0));
        vec3 seamC = mix(vec3(1.0, 0.35, 0.12), sfBass(P, 0.3, u), 0.4);
        rc += seamC * pow(seam, 16.0) * glowRock * (0.15 + 1.8 * bassL) * (1.0 - 0.6 * dif) * (1.0 - smoothstep(30.0, 60.0, t));
        float fog = smoothstep(50.0, 90.0, t);
        col = mix(rc, col, fog);
    }

    // the skiff and the derelict: marched only inside their bounding sphere and
    // only in front of the nearest rock
    float zHit = hit > 0.5 ? t * dot(rd, fw) : 1e9;
    if (evType > -0.5 && evType < 1.5) {
        float kind = evType;
        vec3 C;
        mat3 Bm;
        float br;
        float spin = tm * 0.8;
        if (kind < 0.5) {
            // it overtakes from behind on one side, banks in and pulls away
            // ahead along the route; its speed is tied to ours
            float rel = -16.0 + 60.0 * E.e;
            float zc = z + rel;
            float lat = 6.0 - 3.5 * smoothstep(0.2, 1.0, E.e);
            C = sfPath(zc) + vec3(E.side * lat, 1.8 - 0.8 * E.e + 0.4 * sin(E.e * 6.0), 0.0);
            vec3 f = normalize(sfPath(zc + 5.0) - sfPath(zc));
            vec3 X = normalize(cross(vec3(0.0, 1.0, 0.0), f));
            // it yaws in toward the lane as it comes alongside, showing its flank
            float yw = -E.side * 0.5 * smoothstep(0.15, 0.5, E.e) * (1.0 - 0.6 * smoothstep(0.6, 1.0, E.e));
            vec3 f2 = cos(yw) * f + sin(yw) * X;
            X = cos(yw) * X - sin(yw) * f;
            f = f2;
            vec3 Y = cross(f, X);
            float bank = E.side * 0.5 * smoothstep(0.2, 0.5, E.e) * smoothstep(0.95, 0.6, E.e);
            float cb = cos(bank);
            float sb = sin(bank);
            Bm = mat3(cb * X + sb * Y, cb * Y - sb * X, f);
            br = 6.8;
        } else {
            // the hulk tumbles slowly about all three axes
            C = E.pos;
            float a1 = 6.2832 * E.h + tm * 0.05;
            float a2 = 3.0 * E.h2 + tm * 0.035;
            float a3 = 1.7 * E.h + tm * 0.02;
            vec3 Z = vec3(sin(a1) * cos(a2), sin(a2), cos(a1) * cos(a2));
            vec3 X = vec3(cos(a1), 0.0, -sin(a1));
            vec3 Y = cross(Z, X);
            Bm = mat3(cos(a3) * X + sin(a3) * Y, cos(a3) * Y - sin(a3) * X, Z);
            br = 10.0;
        }
        vec3 oc = ro - C;
        float b = dot(oc, rd);
        float h = b * b - dot(oc, oc) + br * br;
        float tLim = hit > 0.5 ? t : 1e9;
        float tE = -1.0;
        if (h > 0.0) {
            float sh = sqrt(h);
            float t0 = max(-b - sh, 0.0);
            float t1 = min(-b + sh, tLim);
            if (t1 > t0) {
                vec3 lo = oc * Bm;
                vec3 ld = rd * Bm;
                tE = sfEvMarch(lo, ld, t0, t1, osSteps(36.0, 64.0, detail), kind, spin);
                if (tE > 0.0) {
                    vec3 q = lo + ld * tE;
                    vec3 nq = sfEvNormal(q, kind, spin, 0.002 + 0.0008 * tE);
                    vec3 nW = Bm * nq;
                    vec3 ec = kind < 0.5 ? sfShadeSkiff(q * 0.7692, nq, nW, rd, sunDir, spin, bassL, evGlow, P, u)
                                         : sfShadeWreck(q * 0.6667, nq, nW, rd, sunDir, P, u);
                    col = mix(col, ec, (1.0 - smoothstep(60.0, 150.0, tE)) * E.fade);
                    zHit = min(zHit, tE * dot(rd, fw));
                }
            }
        }
        float pxw = 2.0 / (max(u.resolution.y, 1.0) * fov);
        float tOcc = tE > 0.0 ? tE : tLim;
        float tp;
        if (kind < 0.5) {
            // the drive: a hot core inside the ring-wing and a fading plume
            vec3 f = Bm[2];
            vec3 A = C - f * 2.5;
            float core = sfGlowPt(ro, rd, A, 0.35, pxw, tp) * (tp < tOcc + 0.5 ? 1.0 : 0.15);
            vec3 w0 = ro - A;
            float bb = -dot(rd, f);
            float dd = dot(rd, w0);
            float tc = clamp((-dot(f, w0) - bb * dd) / max(1.0 - bb * bb, 1e-4), 0.0, 16.0);
            vec3 Q = A - f * tc;
            float sq = max(dot(Q - ro, rd), 0.0);
            vec3 dv = ro + rd * sq - Q;
            float sg = 0.3 + 0.07 * tc + sq * pxw;
            float plume = exp(-dot(dv, dv) / (sg * sg)) * exp(-tc / 5.0) * (sq < tOcc ? 1.0 : 0.0) * 0.3 / (sg / 0.3);
            col += evGlow * (core * (1.4 + 0.8 * u.bassImpact) + plume) * E.fade * (1.0 - smoothstep(90.0, 300.0, tp));
        } else {
            // a beacon still blinking slowly on the spine
            float bl = sfGlowPt(ro, rd, C + Bm * vec3(0.9, 1.47, 8.25), 0.14, pxw, tp);
            float pulse = pow(0.5 + 0.5 * sin(tm * 2.3), 10.0);
            col += vec3(1.6, 0.12, 0.06) * bl * pulse * 1.5 * (tp < tOcc + 0.2 ? 1.0 : 0.0) * E.fade * (1.0 - smoothstep(60.0, 150.0, tp));
        }
    }
    if (evType > 4.5) sfJellies(p, ro, rt, cu, fw, fov, E, sunS, zHit, P, u, col);

    col += sfWarp(p, sunS, roll, z, fl.y, fov, zHit, P, u, detail);
    // break 8-bit banding in the soft halos with a tiny relative noise
    float gn = hash21(floor(uv * u.resolution) + vec2(0.11, 0.53)) - 0.5;
    col = max(col * (1.0 + 0.03 * gn) + vec3(0.0005 * gn), vec3(0.0));
    return col; // LINEAR HDR — post chain tonemaps
}
