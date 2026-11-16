// SPDX-License-Identifier: AGPL-3.0-only
// Event Horizon.
// A slow orbit around a black hole. Every pixel's light ray is bent through the
// hole's gravity, so the thin accretion disc wraps over the top and under the
// bottom of the black shadow, a thin photon ring hugs the shadow's edge, and
// the star field and galaxy band behind it smear and multiply as the camera
// moves. The shadow edge and photon ring are closed-form in the ray's conserved
// impact parameter, so the ring stays whole at every detail level and target.
// The disc turns differentially (inner gas faster), its approaching side
// Doppler-shifted to azure and beamed bright, the receding side crimson, its
// inner edge dimmed by gravitational redshift. Hot spots orbit at their own
// Kepler rates trailing sheared tails, each beat sends a density ripple out
// from the inner edge, and twin relativistic jets stream knots along the spin
// axis. The orbit and the disc's spin follow the 32-beat speed profile and the
// roll eases every eight beats; bass heats the inner disc, the jets and the
// photon ring, the spectrum lights the disc ring by ring (lows inside, highs
// outside) and the hot spots, and treble makes the stars glitter. Audio never
// moves the camera.
// param0 = Pull (how close the orbit is) ; param1 = Spin (disc speed) ;
// param2 = Disk Detail (streak contrast and fine structure)

const float EH_OUTER = 14.0;   // outer disc radius (horizon radius = 1)
const float EH_ISCO = 3.0;     // innermost stable orbit

// The palette, read once per pixel at fixed stops and blended locally.
struct EhPal { vec3 t0; vec3 t1; vec3 t2; vec3 t3; vec3 t4; vec3 sky; vec3 neb; };

// the disc's temperature ramp, palVisual(x) for x in 0.1..1 from five stops
vec3 ehTemp(EhPal P, float x) {
    float k = saturate((x - 0.1) / 0.9) * 4.0;
    vec3 c = mix(P.t0, P.t1, saturate(k));
    c = mix(c, P.t2, saturate(k - 1.0));
    c = mix(c, P.t3, saturate(k - 2.0));
    return mix(c, P.t4, saturate(k - 3.0));
}

vec3 ehHash33(vec3 p) {
    uint h = hashKey(p);
    return vec3(hashUnit(hashMix(h ^ 0x6294a626u)), hashUnit(hashMix(h ^ 0xbe633942u)),
                hashUnit(hashMix(h ^ 0xa97a7369u)));
}

float ehNoise3(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x);
    float b = mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x);
    float c = mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x);
    float d = mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

// value noise wrapping every `per` cells in y (per is a whole number)
float ehNoiseP(vec2 p, float per) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float y0 = mod(i.y, per), y1 = mod(i.y + 1.0, per);
    float a = hash21(vec2(i.x, y0)), b = hash21(vec2(i.x + 1.0, y0));
    float c = hash21(vec2(i.x, y1)), d = hash21(vec2(i.x + 1.0, y1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// disc streak texture: x = radial, y = angle in turns times per
float ehFbmP(vec2 p, float per, int oct) {
    float v = 0.0, a = 0.5, s = 0.0;
    for (int i = 0; i < 5; ++i) {
        if (i >= oct) break;
        v += a * ehNoiseP(p, per);
        s += a;
        p *= 2.0;
        per *= 2.0;
        a *= 0.55;
    }
    return v / max(s, 1e-3);
}

// Light the disc gives off where the ray crosses it at `hit`, travelling along v.
// Returns rgb and opacity.
vec4 ehDisc(vec3 hit, vec3 v, float t, float spotClock, int oct, EhPal P, VisualUniforms u) {
    float rr = length(hit.xz);
    float ang = atan2_(hit.z, hit.x) / 6.2831853;          // turns, -0.5..0.5
    float spin = mix(0.5, 2.4, u.param1);
    float omega = spin * 0.42 * pow(EH_ISCO / rr, 1.5);     // turns of 2pi per second / 2pi
    // two time-staggered samples so the differential shear never winds up
    float tc = 6.0;
    float ph = fract(t / tc);
    float ph2 = fract(ph + 0.5);
    float w1 = 1.0 - abs(2.0 * ph - 1.0);
    float rx = log(rr) * 9.0;
    float per = 10.0;
    float a1 = (ang - omega * tc * ph / 6.2831853) * per;
    float a2 = (ang - omega * tc * ph2 / 6.2831853) * per;
    float n1 = ehFbmP(vec2(rx, a1), per, oct);
    float n2 = ehFbmP(vec2(rx + 17.3, a2), per, oct);
    float n = mix(n2, n1, w1);
    float detail = mix(0.6, 1.5, u.param2);
    float streak = saturate(0.5 + (n - 0.5) * 2.6 * detail);
    streak = streak * streak;

    // orbiting hot spots: bright plasma clumps riding the flow, each a whole
    // number of turns per clock period so the wrap is seamless; the spectrum
    // pumps each one, and their sheared tails trail behind them
    float spots = 0.0;
    for (int i = 0; i < 4; ++i) {
        float fi = float(i);
        float kk = i == 0 ? 6.0 : i == 1 ? 4.0 : i == 2 ? 3.0 : 2.0;
        float ri = 3.0 * pow(0.0668 * 120.0 / kk, 0.6666667);
        float ai = fract(kk * spotClock / 120.0 + fi * 0.37 + 0.11);
        float da = fract(ang - ai + 0.5) - 0.5;              // turns, wrapped
        float al = da * 6.2831853 * rr;                       // arc length
        float tail = al < 0.0 ? 2.6 : 0.7;                    // longer behind
        float dr = rr - ri;
        float pump = 0.55 + 1.3 * bandAt(u, 0.08 + 0.2 * fi) + 0.6 * u.bassImpact;
        spots += exp(-dr * dr * 6.0 - al * al / (tail * tail)) * pump * (1.4 - 0.18 * fi);
    }

    // a density wave rolls outward from the inner edge on every beat
    float bp = saturate(u.beatPhase);
    float rw = EH_ISCO + 0.3 + 7.5 * bp;
    float rd0 = (rr - rw) / (0.35 + 0.9 * bp);
    float ripple = exp(-rd0 * rd0) * (1.0 - bp) * (1.0 - bp) * smoothstep(0.0, 0.06, bp) * (0.35 + 0.9 * u.bassImpact);

    // radial profile: sharp inner edge at the ISCO, long soft outer fade
    float prof = smoothstep(EH_ISCO - 0.35, EH_ISCO + 0.5, rr) * (1.0 - smoothstep(EH_OUTER * 0.45, EH_OUTER, rr));
    float inten = prof * pow(EH_ISCO / rr, 2.1);

    // Doppler beaming and gravitational redshift
    vec3 vdir = normalize(vec3(-hit.z, 0.0, hit.x) + vec3(1e-5, 0.0, 0.0));
    float beta = min(sqrt(0.5 / max(rr - 1.0, 0.5)), 0.7);
    float gam = 1.0 / sqrt(1.0 - beta * beta);
    float cosT = dot(vdir, -normalize(v));
    float g = sqrt(max(1.0 - 1.0 / rr, 0.0)) / (gam * (1.0 - beta * cosT));
    float beam = g * g * g;
    beam = mix(beam, 1.0, 0.06);

    // audio: spectrum by radius, bass heats the inner edge
    float sp = bandAt(u, saturate((rr - EH_ISCO) / (EH_OUTER * 0.6 - EH_ISCO)));
    float heat = 1.0 + 0.8 * u.bassImpact * exp(-(rr - EH_ISCO) * 0.8) + 0.25 * u.bass;
    float glow = inten * (0.12 + 1.9 * streak + 1.5 * spots + 1.4 * ripple * (0.4 + streak)) * (0.75 + 0.7 * sp) * heat;
    // the beat's density wave burns cool against the warm gas: the complementary accent
    float rdC = (rr - rw) / (0.2 + 0.35 * bp);
    float rippleC = exp(-rdC * rdC) * (1.0 - bp) * (1.0 - bp) * smoothstep(0.0, 0.06, bp) * (0.3 + 0.8 * u.bassImpact)
                  * prof * pow(EH_ISCO / rr, 1.2) * (0.5 + streak);

    float temp = pow(EH_ISCO / rr, 0.6) * g;               // seen temperature
    vec3 c = ehTemp(P, 0.1 + 0.62 * temp);
    c = peakWhite(c, smoothstep(0.95, 1.6, temp));
    // blue-shifted approaching side, crimson receding side
    float blueW = smoothstep(0.9, 1.35, g) * (1.0 - 0.6 * smoothstep(1.6, 2.4, temp));
    // hue walks the long way round (gold, rose, violet, azure) so it never greys
    float cmax = max(max(c.r, c.g), c.b);
    vec3 shifted = hsv2rgb(vec3(fract(1.1 - 0.52 * blueW), 0.8, 1.0)) * cmax * (0.8 + 0.3 * blueW);
    c = mix(c, shifted, smoothstep(0.0, 0.25, blueW));
    c = mix(c, vec3(1.0, 0.16, 0.34) * (0.4 + luma(c)), 0.6 * (1.0 - smoothstep(0.45, 0.9, g)));
    vec3 rgb = c * glow * beam * 2.4;
    // the clumps burn hotter than the gas around them
    rgb += peakWhite(c, 0.25) * spots * (0.25 + 1.5 * streak) * prof * pow(EH_ISCO / rr, 1.1) * beam * (1.0 + 0.6 * sp);
    rgb += vec3(0.3, 0.85, 1.7) * rippleC * beam * 3.0;
    float alpha = saturate(prof * (0.55 + 0.45 * streak));
    return vec4(rgb, alpha);
}

// The sky behind the hole along direction d: stars and a faint galaxy band.
vec3 ehSky(vec3 d, float pxa, float t, int layers, bool clouds, EhPal P, VisualUniforms u) {
    vec3 nG = normalize(vec3(0.35, 1.0, 0.28));
    float lat = dot(d, nG);
    float band = exp(-lat * lat * 22.0);
    vec3 col = P.sky * 0.012;
    if (clouds) {
        float cl = ehNoise3(d * 3.2) * 0.6 + ehNoise3(d * 8.5 + 3.1) * 0.4;
        float dust = smoothstep(0.45, 0.7, ehNoise3(d * 6.0 + 9.7));
        col += P.neb * 0.022 * band * (0.2 + cl) * (1.0 - 0.8 * dust);
        col += vec3(0.4, 0.5, 1.0) * 0.06 * band * cl * cl * (1.0 - 0.85 * dust);
    }
    float tw = 0.8 + 0.7 * u.treble;
    for (int l = 0; l < 2; ++l) {
        if (l >= layers) break;
        float sc = l == 0 ? 70.0 : 170.0;
        vec3 q = d * sc;
        vec3 ci = floor(q);
        float h = hash31(ci + float(l) * 31.0);
        float thr = l == 0 ? mix(0.975, 0.955, band) : mix(0.992, 0.975, band);
        if (h > thr) {
            vec3 sp = normalize(ci + 0.25 + 0.5 * ehHash33(ci + 7.0)) * sc;
            float dd = length(q - sp) / sc;
            float mag = pow((h - thr) / (1.0 - thr), 3.0);
            float rad = pxa * (0.7 + 0.9 * mag);
            float s = exp(-dd * dd / (rad * rad)) * (0.05 + 3.5 * mag) + mag * 0.06 * exp(-dd / (pxa * 3.0));
            float twk = 0.7 + 0.3 * sin(t * (1.5 + 4.0 * h) + h * 50.0);
            vec3 sc3 = mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.85, 0.65), hash31(ci + 3.0));
            col += sc3 * s * twk * tw * (l == 0 ? 1.0 : 0.45);
        }
    }
    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    int steps = osSteps(90.0, 160.0, detail);
    int oct = osSteps(2.0, 4.0, detail);
    int layers = osSteps(1.0, 2.0, detail);
    float t = mod(u.time, 600.0);

    EhPal P;
    P.t0 = palVisual(0.1, u);
    P.t1 = palVisual(0.325, u);
    P.t2 = palVisual(0.55, u);
    P.t3 = palVisual(0.775, u);
    P.t4 = palVisual(1.0, u);
    P.sky = palVisual(0.06, u);
    P.neb = palVisual(0.3, u);
    vec3 ringBase = palVisual(0.75, u);

    // camera: a slow orbit following the speed profile, gentle eased roll
    vec2 fl = osFlight(u, 0.05, 0.018);
    float phi = mod(fl.x, 6.2831853) + 0.6;
    float elev = 0.19 + 0.11 * sin(mod(fl.x * 0.37, 6.2831853));
    float camR = mix(20.0, 13.0, u.param0);
    vec3 ro = camR * vec3(cos(elev) * cos(phi), sin(elev), cos(elev) * sin(phi));
    float focal = 1.9;
    vec3 rd = osCamera(ro, vec3(0.0, -0.4, 0.0), 0.14 + osBank(u, 0.08), focal, p);
    float pxa = 2.0 / max(u.resolution.y, 1.0) / focal;

    // the gas runs on the beat-locked speed profile too: it surges in the
    // bursts and slows in the breakdowns
    float spin = mix(0.5, 2.4, u.param1);
    float clock = osFlight(u, 0.5, 0.05).x;
    float discT = mod(clock, 600.0);
    float spotClock = mod(clock * spin, 120.0);

    // impact parameter: conserved along the ray, so the shadow edge and photon
    // ring come from it directly instead of from the marched path
    float bImp = length(cross(ro, rd));
    const float EH_BC = 2.5980762;   // critical impact parameter, 1.5 * sqrt(3)
    float pxB = camR * pxa;          // one pixel in impact-parameter units

    // trace the bent ray: x'' = -1.5 h^2 x / r^5 (horizon radius 1)
    vec3 pos = ro;
    vec3 v = rd;
    vec3 hc = cross(pos, v);
    float h2 = dot(hc, hc);
    vec3 col = vec3(0.0);
    float trans = 1.0;
    vec3 hazeCol = mix(P.t1, P.t2, 0.778) * (1.0 + 0.5 * u.bassImpact);
    float minR = 1e3;
    bool escaped = false;
    for (int i = 0; i < 160; ++i) {
        if (i >= steps) break;
        float r = length(pos);
        if (r < 1.0) break;   // fell through the horizon
        if (r > camR + 6.0 && dot(pos, v) > 0.0) { escaped = true; break; }
        minR = min(minR, r);
        float dt = clamp(0.085 * (r - 0.6), 0.03, 2.0);
        // velocity Verlet keeps the bending accurate with few steps
        vec3 vh = v - 0.75 * h2 * pos / (r * r * r * r * r) * dt;
        vec3 np = pos + vh * dt;
        float r1 = max(length(np), 0.5);
        vec3 nv = vh - 0.75 * h2 * np / (r1 * r1 * r1 * r1 * r1) * dt;
        if (pos.y * np.y < 0.0 && trans > 0.02) {
            float f = pos.y / (pos.y - np.y);
            vec3 hit = mix(pos, np, f);
            float rr = length(hit.xz);
            if (rr > EH_ISCO - 0.4 && rr < EH_OUTER) {
                vec4 e = ehDisc(hit, nv, discT, spotClock, oct, P, u);
                col += trans * e.rgb;
                trans *= 1.0 - e.a;
            }
        }
        // thin hot haze hugging the disc, brighter on the approaching side
        float rxz = length(pos.xz);
        float hz = exp(-abs(pos.y) * 3.5) * smoothstep(2.4, 3.6, rxz) * (1.0 - smoothstep(5.0, EH_OUTER, rxz));
        if (hz > 0.002) {
            vec3 td = vec3(-pos.z, 0.0, pos.x) / max(rxz, 1e-3);
            float side = 1.0 + 0.9 * dot(td, -normalize(v));
            col += trans * hazeCol * hz * pow(EH_ISCO / max(rxz, 2.0), 2.0) * side * dt * 0.014;
        }
        pos = np;
        v = nv;
    }

    // Sky: rays that left, and rays still circling when the step budget ran
    // out, see the sky along their last direction; the shadow edge itself is
    // the smooth impact-parameter test, so it never depends on step count.
    float r = length(pos);
    float skyW = smoothstep(EH_BC - 1.5 * pxB, EH_BC + 1.5 * pxB, bImp) * (r > 1.0 ? 1.0 : 0.0);
    if (escaped || r > 1.0) {
        col += trans * skyW * ehSky(normalize(v), pxa, t, layers, detail > 0.4, P, u);
    }

    // relativistic jets along the spin axis, integrated in closed form along the
    // camera ray; knots stream outward on the speed profile and bass pumps them
    vec2 rxz = rd.xz;
    float A = max(dot(rxz, rxz), 0.04);
    float sS = max(-dot(ro.xz, rxz) / A, 0.0);
    vec3 cp = ro + rd * sS;
    float jy = abs(cp.y);
    float jw = 0.2 + 0.1 * jy;                    // soft sheath
    float jc = 0.045 + 0.022 * jy;                // hot core
    float dm2 = dot(cp.xz, cp.xz);
    float jetLine = (exp(-dm2 / (jw * jw)) * 0.6 + exp(-dm2 / (jc * jc)) * 1.6) / sqrt(A);
    float knots = 0.5 + 0.5 * sin(jy * 0.85 - mod(clock * 2.2, 6.2831853));
    knots = 0.35 + 0.65 * knots * knots * knots;
    float jetI = jetLine * smoothstep(2.7, 4.6, jy) * exp(-jy * 0.12) * knots;
    jetI *= (0.35 + 0.9 * u.bassImpact + 0.35 * u.bass) * (0.8 + 0.25 * saturate(fl.y - 1.0));
    vec3 jetCol = mix(vec3(0.3, 0.6, 1.7), vec3(0.8, 0.35, 1.7), smoothstep(4.0, 12.0, jy));
    jetCol = mix(jetCol, vec3(1.2, 1.6, 2.4), exp(-dm2 / (jc * jc)) * 0.5);
    col += jetCol * jetI * 0.22 * (cp.y < 0.0 ? trans * trans : 1.0);

    // photon ring: a thin hot line just outside the shadow edge plus a soft halo,
    // both closed-form in the impact parameter; the front of the disc hides it
    float ringHeat = 1.0 + 0.9 * u.bassImpact + 0.3 * u.bass;
    vec3 ringCol = peakWhite(ringBase, 0.5);
    float db = bImp - EH_BC;
    float rw = max(0.03, 1.1 * pxB);
    float ringLine = exp(-max(db, 0.0) / rw) * smoothstep(-1.5 * pxB, 0.5 * pxB, db);
    float ringHalo = exp(-max(db, 0.0) * 7.0) * smoothstep(-2.0 * pxB, 0.0, db);
    col += trans * (ringCol * ringLine * 1.1 + P.t2 * ringHalo * 0.12) * ringHeat;
    return col; // LINEAR HDR — post chain tonemaps
}
