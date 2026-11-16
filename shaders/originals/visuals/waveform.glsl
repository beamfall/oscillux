// SPDX-License-Identifier: AGPL-3.0-only
// Waveform.
// A night drone light show over a city lake. About a thousand drones hang in
// the sky in rows, and every row is the live waveform drawn in LEDs: band
// energies build its partials and each beat throws a kick that runs out along
// the rows. Every eight beats the swarm re-forms, flying row by row from a
// receding sheet of traces, to a tube whose silhouette is the waveform, to a
// wall of spectrum bars, and back. A colour sweep rings out from the centre
// of the formation on each beat, alternating warm and cool; onsets strobe
// single drones; a breakdown dims the swarm to a sparse constellation and a
// burst lights all of it. Below, a rippled lake mirrors the swarm as long
// streaks and a low skyline glows sodium amber on the far shore. The camera
// sweeps an arc along the shore on the shared cruise/build/burst/brake
// profile; audio drives the drones, their light and colour, never the camera.
// param0 = Thickness (LED size) ; param1 = Trail Length (how far the sheet
// reaches back) ; param2 = Trace Stack (how many rows fly)

const float WV_HC = 12.0;     // height of the formation's centre
const float WV_SX = 0.5;      // drone spacing along a row
const int WV_NC = 44;         // half the drones in a row
const int WV_NR = 14;         // rows at full detail
const float WV_SHORE = 170.0; // distance to the far shore

// Band energies at eight points across the spectrum, read with constant
// indices, and interpolated across the rows.
void wvBands(VisualUniforms u, out vec4 w0, out vec4 w1) {
    w0 = vec4(u.spectrum[0].x, u.spectrum[2].y, u.spectrum[4].z, u.spectrum[6].w);
    w1 = vec4(u.spectrum[9].x, u.spectrum[11].y, u.spectrum[13].z, u.spectrum[15].w);
}

float wvBand8(float s, vec4 w0, vec4 w1) {
    float x = saturate(s) * 7.0;
    vec4 h0 = max(1.0 - abs(x - vec4(0.0, 1.0, 2.0, 3.0)), 0.0);
    vec4 h1 = max(1.0 - abs(x - vec4(4.0, 5.0, 6.0, 7.0)), 0.0);
    return dot(w0, h0) + dot(w1, h1);
}

// The palette read once per pixel at its five stops and blended locally.
struct WvPalette { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

WvPalette wvPalLoad(VisualUniforms u) {
    WvPalette P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 wvPal(WvPalette P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float WV_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 wvFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * WV_RUN[32] + WV_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

// Everything a drone needs that is the same for the whole frame.
struct WvShow {
    vec4 amp;     // partial amplitudes
    vec4 kx;      // partial wavenumbers
    vec4 ph;      // partial phases at this instant
    float kick;   // the beat's travelling kick: front position
    float kickA;  // and its strength
    vec4 b0;      // band energies
    vec4 b1;
    int fA;       // formation flown from
    int fB;       // formation flown to
    float morph;  // segment time in beats, for the row-by-row morph
    float depth;  // how far the sheet reaches back
    float roll;   // the tube's slow roll
};

// The live waveform at x, delayed by d (in radians of the slowest partial).
float wvWave(WvShow S, float x, float d) {
    vec4 a = S.kx * x + S.ph - d * vec4(1.0, 1.7, 2.6, 3.9);
    float y = dot(S.amp, sin(a));
    float q = (abs(x) - S.kick) * 0.45;
    return y + S.kickA * exp(-q * q);
}

// The row's plane (z) in formation f; r is the row's place in [0, 1].
float wvRowZ(WvShow S, int f, float r) {
    if (f == 0) return (r - 0.5) * S.depth;
    if (f == 1) return 4.2 * sin(r * 6.2831853 + S.roll);
    return 0.0;
}

// A drone's height, depth offset from its row plane and LED level.
vec3 wvForm(WvShow S, int f, float x, float r) {
    if (f == 0) {
        // a sheet of traces receding row by row, each a little later in time
        return vec3(WV_HC - 3.6 + r * 8.0 + 1.5 * wvWave(S, x, r * 2.4), 0.0, 1.0);
    }
    if (f == 1) {
        // a tube along the rows: the waveform is its silhouette
        float th = r * 6.2831853 + S.roll;
        float R = max(4.2 + 1.2 * wvWave(S, x, 0.0), 0.6);
        return vec3(WV_HC + R * cos(th), (R - 4.2) * sin(th), 1.0);
    }
    // a wall of spectrum bars: drones above the bar's height go dark
    float b = saturate(wvBand8(abs(x) / (float(WV_NC) * WV_SX), S.b0, S.b1) * 1.15 + 0.08);
    return vec3(WV_HC - 5.5 + r * 11.0, 0.0, smoothstep(b + 0.04, b - 0.04, r) * 0.95 + 0.05);
}

// The light of every drone near the ray: per row, the ray meets the row's
// plane, and the three nearest drones of that row are lit. squash < 1 draws
// the glow out along world y, for the reflection on rippled water.
vec3 wvDrones(WvShow S, WvPalette P, VisualUniforms u, vec3 ro, vec3 rd, float pix,
              float size, int nr, float squash, vec4 look, vec3 cAcc, float sweepA) {
    vec3 acc = vec3(0.0);
    float rows = float(nr - 1);
    float rdz = rd.z > 1e-3 ? rd.z : 1e-3;
    float strobeK = floor(u.beatCount * 2.0) * 0.618;
    float strobeA = u.onset * u.treble;
    for (int j = 0; j < WV_NR; j++) {
        if (j >= nr) break;
        float r = float(j) / rows;
        // the morph runs row by row through beats 5.5 to 7.9 of the segment
        float m = smoothstep(5.5 + r * 0.9, 7.0 + r * 0.9, S.morph);
        float z = wvRowZ(S, S.fA, r);
        if (m > 0.0) z = mix(z, wvRowZ(S, S.fB, r), m);
        float tz = (z - ro.z) / rdz;
        if (tz <= 0.0) continue;
        float i0 = floor((ro.x + rd.x * tz) / WV_SX);
        for (int k = -1; k <= 1; k++) {
            float ic = i0 + float(k);
            if (abs(ic + 0.5) > float(WV_NC)) continue;
            float x = (ic + 0.5) * WV_SX;
            vec3 f = wvForm(S, S.fA, x, r);
            if (m > 0.0) f = mix(f, wvForm(S, S.fB, x, r), m);
            vec3 v = vec3(x, f.x, z + f.y) - ro;
            float tp = dot(v, rd);
            if (tp <= 0.0) continue;
            vec3 pr = v - rd * tp;
            pr.y *= squash;
            float a2 = dot(pr, pr) / (tp * tp * pix * pix);
            float sg = max(1.1, size / (tp * pix));
            float h = hash21(vec2(ic, float(j) * 7.13 + 3.0));
            // sparse in a breakdown, every drone in a burst
            float lit = f.z * smoothstep(h - 0.08, h + 0.08, look.x);
            // onsets strobe single drones white
            float strobe = step(0.93, fract(h * 17.3 + strobeK)) * strobeA;
            float hue = look.y + 0.22 * r + 0.10 * x / (float(WV_NC) * WV_SX) + 0.06 * h;
            vec3 c = wvPal(P, hue);
            c = c / max(max(c.r, max(c.g, c.b)), 0.05);
            // the beat's colour sweep rings out from the formation's centre
            float rho = length(vec2(x * 0.55, f.x - WV_HC));
            float sd = (rho - look.z) * 0.6;
            float sw = saturate(exp(-sd * sd) * sweepA);
            c = mix(mix(c, cAcc, sw), vec3(1.0), saturate(strobe));
            float I = lit * look.w * (1.0 + 2.2 * sw) + strobe * 3.0;
            acc += c * I * (exp(-a2 / (sg * sg)) * 1.6 + exp(-a2 * 0.03) * 0.07);
        }
    }
    return acc;
}

// The far shore: a low skyline in sodium light under its own glow, seen from
// height oy. Returns colour and whether a building was hit.
vec4 wvSkyline(vec3 rd, float oy, float t, vec3 cWarm) {
    float e = rd.y / max(length(rd.xz), 1e-3);
    float az = atan2_(rd.x, rd.z);
    float e0 = -oy / WV_SHORE;
    float city = smoothstep(1.25, 0.7, abs(az + 0.1));
    float bx = az * 48.0;
    float bi = floor(bx);
    float hb = hash11(bi * 1.37 + 4.0);
    float top = e0 + (0.008 + 0.045 * hb * hb + 0.05 * step(0.92, hb)) * city;
    vec3 col = vec3(0.0);
    float hit = 0.0;
    if (e < top && e > e0 - 0.004) {
        hit = 1.0;
        col = vec3(0.0016, 0.0014, 0.0022);
        // lit windows on a fine grid
        vec2 wg = vec2(bx * 5.0, (e - e0) * 300.0);
        vec2 wi = floor(wg);
        vec2 wf = fract(wg);
        float on = step(0.72, hash21(wi + bi * 3.1));
        float win = on * step(0.25, wf.x) * step(wf.x, 0.75) * step(0.3, wf.y) * step(wf.y, 0.7);
        float flick = 0.75 + 0.25 * sin(t * 0.7 + hash21(wi) * 40.0);
        col += mix(cWarm, vec3(1.0, 0.9, 0.75), step(0.8, hash21(wi + 9.0))) * win * 0.22 * flick;
        // red beacons on the tallest towers
        float bq = (fract(bx) - 0.5) * 9.0;
        float bz = (e - top + 0.002) * 1600.0;
        float bk = step(0.92, hb) * exp(-bq * bq - bz * bz);
        col += vec3(1.0, 0.05, 0.02) * bk * 3.0 * step(0.5, fract(t * 0.6 + hb * 3.0));
    }
    // light pollution over the city
    float above = max(e - e0, 0.0);
    col += cWarm * city * (exp(-above * 30.0) * 0.050 + exp(-above * 6.0) * 0.012) * (1.0 - hit);
    return vec4(col, hit);
}

vec3 wvSky(vec3 rd, vec3 ro, vec3 C, vec3 airCol, float air) {
    float e = rd.y / max(length(rd.xz), 1e-3);
    vec3 sky = mix(vec3(0.010, 0.006, 0.022), vec3(0.0012, 0.0016, 0.0045), smoothstep(0.0, 0.5, e));
    // the swarm lights the air around it
    vec3 oc = C - ro;
    vec3 dv = oc - rd * dot(oc, rd);
    return sky + airCol * exp(-dot(dv, dv) * 0.006) * air;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float t = mod(u.time, 600.0);

    // ---- the camera: an arc along the shore at the flight profile's pace ----
    vec2 fl = wvFlight(u, 0.55, 0.35);
    float surge = smoothstep(1.0, 4.0, fl.y);
    float ph = fl.x * 0.11;
    float azc = 0.55 * sin(ph * 0.35) + 0.12 * sin(ph * 0.83 + 1.0);
    float rad = 21.0 + 3.5 * sin(ph * 0.29 + 0.5);
    float hgt = 2.2 + 1.6 * (0.5 + 0.5 * sin(ph * 0.47 + 2.0));
    vec3 ro = vec3(rad * sin(azc), hgt, -rad * cos(azc));
    vec3 ta = vec3(2.5 * sin(ph * 0.51 + 0.3), WV_HC * 0.55 + 1.2 * sin(ph * 0.37), 0.0);
    float fov = 1.25;
    vec3 rd = osCamera(ro, ta, osBank(u, 0.05), fov, p);
    float pix = 2.0 / (u.resolution.y * fov);

    // ---- the show for this frame ----
    WvPalette P = wvPalLoad(u);
    WvShow S;
    wvBands(u, S.b0, S.b1);
    float bass = (S.b0.x + S.b0.y) * 0.5;
    float lowm = (S.b0.z + S.b0.w) * 0.5;
    float midb = (S.b1.x + S.b1.y) * 0.5;
    float treb = (S.b1.z + S.b1.w) * 0.5;
    float lift = 0.45 + 0.75 * saturate(u.amplitude * 1.3);
    S.amp = vec4(0.25 + 0.75 * bass, 0.12 + 0.55 * lowm, 0.05 + 0.40 * midb, 0.02 + 0.30 * treb) * lift;
    S.kx = vec4(0.17, 0.39, 0.83, 1.71);
    S.ph = vec4(0.9, 1.6, 2.5, 3.7) * t + vec4(0.0, 1.3, 2.9, 4.4);
    float bp = fract(u.beatPhase);
    S.kick = bp * 22.0;
    S.kickA = 1.3 * exp(-2.2 * bp) * (0.4 + 0.8 * u.bassImpact);
    float seg = floor(u.beatCount / 8.0);
    S.fA = int(mod(seg, 3.0));
    S.fB = int(mod(seg + 1.0, 3.0));
    S.morph = mod(u.beatCount, 8.0) + saturate(u.beatPhase);
    S.depth = mix(6.0, 18.0, u.param1);
    S.roll = 0.6 + t * 0.22;
    int nr = int(mix(8.0, float(WV_NR), u.param2) * mix(0.6, 1.0, detail) + 0.5);

    // breakdown: a sparse constellation; burst: every drone, brighter
    float energy = saturate(0.35 + 0.45 * surge + 0.35 * u.amplitude + 0.2 * u.bassImpact);
    float odd = mod(floor(u.beatCount), 2.0);
    vec3 cWarm = vec3(1.0, 0.42, 0.10);
    vec3 cCool = wvPal(P, 0.55);
    cCool = cCool / max(max(cCool.r, max(cCool.g, cCool.b)), 0.05);
    vec3 cAcc = odd > 0.5 ? vec3(1.0, 0.62, 0.25) : mix(cCool, vec3(0.3, 0.8, 1.0), 0.5);
    float hue0 = fract(0.008 * t + 0.12 * u.spectralCentroid + 0.15 * seg);
    vec4 look = vec4(mix(0.25, 1.08, energy), hue0, bp * 26.0,
                     (0.9 + 1.3 * surge + 0.6 * u.amplitude) * mix(0.9, 1.2, u.param0));
    float sweepA = exp(-1.6 * bp) * (0.6 + 0.6 * u.beat);
    float size = 0.07 * mix(0.6, 1.7, u.param0);
    vec3 C = vec3(0.0, WV_HC, 0.0);
    vec3 airCol = wvPal(P, hue0 + 0.2);
    airCol = max(mix(vec3(luma(airCol)), airCol, 1.5), 0.0) / max(max(airCol.r, max(airCol.g, airCol.b)), 0.05);
    airCol = mix(airCol, cAcc, 0.3 * sweepA);
    float air = 0.022 * min(look.w * look.x, 1.8);

    // ---- sky, stars and the far shore ----
    vec3 col = wvSky(rd, ro, C, airCol, air);
    {
        float e = rd.y / max(length(rd.xz), 1e-3);
        vec2 sc = vec2(atan2_(rd.x, rd.z) * 160.0, e * 160.0);
        vec2 si = floor(sc);
        float sh = hash21(si);
        vec2 sf = fract(sc) - 0.5 - (hash22(si) - 0.5) * 0.6;
        float star = step(0.985, sh) * exp(-dot(sf, sf) * 40.0) * smoothstep(0.02, 0.15, e);
        col += vec3(0.8, 0.85, 1.0) * star * (0.10 + 0.08 * sin(t * 2.0 + sh * 60.0));
    }
    if (rd.y > 0.02) {
        // a thin cloud deck high above, lit from below by the swarm and the city
        float tcl = (46.0 - ro.y) / rd.y;
        vec2 cq = (ro.xz + rd.xz * tcl) * 0.018 + vec2(t * 0.004, 0.0);
        float cd = vnoise(cq) * 0.65 + vnoise(cq * 2.7 + 3.1) * 0.35;
        cd = smoothstep(0.42, 0.85, cd) * exp(-tcl * 0.006);
        vec2 cl = (ro.xz + rd.xz * tcl) - vec2(0.0, 10.0);
        float lit = exp(-dot(cl, cl) * 0.0012);
        col += cd * (airCol * lit * min(air, 0.06) * 2.2 + cWarm * 0.008 * exp(-rd.y * 3.0));
    }
    vec4 shore = wvSkyline(rd, ro.y, t, cWarm);
    col = col * (1.0 - shore.w) + shore.rgb;

    // ---- the lake ----
    float tw = rd.y < -1e-4 ? -ro.y / rd.y : 1e9;
    if (tw < WV_SHORE && shore.w < 0.5) {
        vec3 pw = ro + rd * tw;
        // wind ripples, stirred by the bass
        float rip = 0.010 + 0.012 * u.bass;
        vec2 q = pw.xz;
        vec2 g = vec2(cos(q.x * 2.1 + q.y * 0.7 + t * 1.9), cos(q.y * 6.3 - q.x * 0.5 + t * 2.3))
               + vec2(cos(q.x * 5.3 - q.y * 2.1 - t * 3.1), cos(q.y * 13.1 + q.x * 0.9 + t * 3.7)) * 0.5;
        float fade = exp(-tw * 0.012);
        vec3 n = normalize(vec3(g.x * rip * 0.35, 1.0, g.y * rip * 3.0));
        vec3 rr = reflect(rd, n);
        rr.y = max(rr.y, 0.002);
        float F = 0.02 + 0.98 * pow(1.0 - saturate(-dot(rd, n)), 5.0);
        vec3 rc = wvSky(rr, pw, C, airCol, air);
        vec4 rsh = wvSkyline(rr, 0.0, t, cWarm);
        rc = rc * (1.0 - rsh.w) + rsh.rgb * 0.6;
        rc += wvDrones(S, P, u, pw, rr, pix * 1.6, size * 1.2, nr, 0.12, look, cAcc, sweepA);
        col = vec3(0.0008, 0.0010, 0.0016) + rc * F * mix(0.6, 1.0, fade);
    } else {
        // ---- the swarm ----
        col += wvDrones(S, P, u, ro, rd, pix, size, nr, 1.0, look, cAcc, sweepA);
    }

    // a fine grain so the dark sky never bands
    float ign = fract(52.9829189 * fract(dot(uv * u.resolution, vec2(0.06711056, 0.00583715))));
    col += (ign - 0.5) * 0.0018;
    return max(col, 0.0);
}
