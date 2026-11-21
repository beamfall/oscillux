// SPDX-License-Identifier: AGPL-3.0-only
// Comets.
// A meteor storm over the limb of a dark planet at sunrise. Four depth layers
// of comets streak across the whole frame as long motion-blurred trails:
// white-hot heads in a warm coma, tails that cool through the palette and
// widen as they fade. Behind them an emission nebula of coloured gas, dark
// dust lanes and bright filaments drifts with the storm; the planet's
// atmosphere glows in two layers and the rising sun flares on its limb.
// The storm drifts at one steady pace on a fixed heading, with a constant
// trail length, so no audio surge ever sweeps bright streaks across the
// frame. Audio only breathes: the smoothed level and each comet's band warm
// its head and coma a little, beats barely touch the heads, a few faint
// sparks shed off the dust tails, and the atmosphere and sunrise hold steady.
// param0 = Count ; param1 = Spread (heading swing and scatter) ; param2 = Tail Length

const float CM_CELL = 4.8;    // spacing of comets along a lane, in screen units
const float CM_WRAP = 512.0;  // lanes repeat every CM_WRAP cells

// fbm with a detail-scaled octave count (2..4)
float cmFbm(vec2 p, int oct) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        if (i >= oct) break;
        v += a * vnoise(p); p = FBM_OCTAVE * p; a *= 0.5;
    }
    return v;
}

// The palette read once at five fixed stops (warm coma .. cool tail) and blended
// locally: a palVisual call at a varying position per comet costs far more.
struct CmPal { vec3 c0; vec3 c1; vec3 t0; vec3 t1; vec3 t2; };
vec3 cmComa(CmPal P, float t) { return mix(P.c0, P.c1, t); }
vec3 cmTail(CmPal P, float t) {
    return t < 0.5 ? mix(P.t0, P.t1, t * 2.0) : mix(P.t1, P.t2, t * 2.0 - 1.0);
}

// One depth layer of comets in the streak frame q (x along the motion). Each
// comet carries the two tails of a real one: a straight, narrow ion tail with
// streamers flowing down it, and a broader warm dust tail that curves off to
// one side and fans out. Mid and near heads also light the gas around them
// (returned in lit), so the nebula flares up along the comets' paths.
vec3 cmLayer(vec2 q, float layer, float travel, float vel, VisualUniforms u,
             float count, float tailK, float px, CmPal P, inout vec3 lit) {
    float dz = layer / 3.0;                         // 0 far .. 1 near
    float laneW = mix(0.055, 0.30, dz * dz);
    float spd = mix(0.3, 1.5, dz);
    float len = min((0.1 + 0.62 * vel) * spd * tailK, CM_CELL * 0.85);
    float th0 = mix(0.0022, 0.02, dz * dz);
    // a longer streak spreads the same light thinner, as real motion blur does
    float tailN = inversesqrt(max(vel, 1.0));
    float bend = min(th0 * 14.0, laneW * 0.55);    // how far the dust tail curls off the path
    float reach = bend + th0 * 9.5 + px * 4.0;      // farthest any tail or glow reaches
    float lightR = laneW * 0.45;                    // radius of the gas a head lights
    bool lights = dz > 0.3;
    float lane = floor(q.y / laneW);
    // this lane and its two neighbours are the only ones in reach
    vec3 col = vec3(0.0);
    for (int j = -1; j < 2; j++) {
        float li = lane + float(j);
        if (hash21(vec2(mod(li, 997.0), layer * 7.13 + 1.0)) > count) continue;
        vec2 hh = hash22(vec2(mod(li, 997.0) * 1.31 + layer * 3.7, 5.0));
        float yC = (li + 0.5 + (hh.x - 0.5) * 0.3) * laneW;
        float dy = q.y - yC;
        bool near = abs(dy) <= reach;
        if (!near && !(lights && abs(dy) < lightR * 3.0)) continue;
        float jit = 0.75 + 0.5 * hh.y;
        float x = q.x - mod(travel * spd * jit + hh.x * CM_CELL, CM_CELL * CM_WRAP);
        float c = floor(x / CM_CELL);
        float f = fract(hh.y * 7.3 + layer * 0.21);
        float b = bandAt(u, f);
        float heat = 0.8 + 0.15 * u.level + 0.25 * b;
        float flare = 0.05 * phasePulse(u, hh.x, 0.1);
        // warm coma and dust, cool ion tail: gold/orange heads against cyan/magenta trails
        vec3 comaC = cmComa(P, hh.y);
        vec3 tailC = cmTail(P, saturate((0.36 * hh.x + 0.08 * u.spectralCentroid) / 0.44));
        tailC = accentize(tailC, u.accent, 0.15);
        vec3 hotC = peakWhite(comaC, 0.55);
        for (int k = 0; k < 2; k++) {
            float cc = c + float(k);
            float hc = hash21(vec2(mod(cc, CM_WRAP), li * 0.37 + layer * 31.0));
            float hx = (cc + 0.1 + 0.6 * hc) * CM_CELL;
            float dx = hx - x;                      // > 0 behind the head
            if (lights) {
                float rl = (dx * dx * 0.2 + dy * dy) / (lightR * lightR);
                lit += comaC * heat * (1.0 + 0.3 * flare) * exp(-rl) * dz;
            }
            if (!near || dx < -reach || dx > len + reach) continue;
            float s = dx / len;
            float ss = saturate(s);
            // ion tail: straight and narrow, streamers flowing away from the head
            float th = th0 * (0.75 + 1.1 * ss) * (0.95 + 0.1 * b);
            float tw = max(th, px * 0.9);
            float g = exp(-dy * dy / (tw * tw)) * (th / tw);
            float streamer = 0.8 + 0.2 * sin(dx / (th0 * 11.0) + hc * 6.2831853 + dy / th0 * 0.9);
            float along = smoothstep(-0.02, 0.0, s) * pow(saturate(1.0 - s), 1.4);
            vec3 ion = mix(hotC, tailC * 1.3, smoothstep(0.0, 0.07, s));
            ion = mix(ion, tailC * vec3(0.55, 0.7, 1.1), smoothstep(0.5, 1.0, s));
            // dust tail: shorter, curling away from the sun (up the frame) as it widens
            float sd = saturate(s * 1.45);
            float dyD = dy - bend * sd * sqrt(sd);
            float thD = th0 * (1.0 + 2.6 * sd) * (0.95 + 0.1 * b);
            float twD = max(thD, px * 0.9);
            float gD = exp(-dyD * dyD / (twD * twD)) * (thD / twD);
            float alongD = smoothstep(-0.02, 0.0, s) * pow(1.0 - sd, 1.2);
            vec3 dustC = mix(hotC, comaC * 1.2, smoothstep(0.0, 0.08, s));
            dustC = mix(dustC, comaC * vec3(1.0, 0.7, 0.55), smoothstep(0.25, 0.7, s));
            float r2 = (dx * dx + dy * dy) / (th0 * th0 + px * px);
            float core = exp(-r2 * 0.7) * (2.5 + 2.5 * flare);
            float coma = exp(-sqrt(r2) * 0.45) * (0.45 + 0.15 * flare);
            // faint sparks shed along the dust tail
            float scl = max(th0 * 9.0, px * 6.0);
            float sn = floor(dx / scl);
            vec2 sh2 = hash22(vec2(mod(sn, 251.0), li * 0.71 + cc * 0.13));
            vec2 sdv = vec2((fract(dx / scl) - sh2.x) * scl, dyD - (sh2.y - 0.5) * thD * 2.0);
            float sr = max(th0 * 0.7, px);
            float spark = step(0.85, sh2.y) * alongD * exp(-dot(sdv, sdv) / (sr * sr)) * (0.15 + 0.1 * u.level);
            col += (ion * along * g * streamer * 1.1 + dustC * alongD * gD * 0.35) * heat * tailN
                 + (peakWhite(comaC, 0.85) * core + comaC * coma) * heat * 0.6
                 + mix(tailC, comaC, sh2.x) * spark;
        }
    }
    // near layers are out of focus: softer and a little dimmer
    return col * mix(1.0, 0.75, dz);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float px = 2.0 / max(u.resolution.y, 1.0);

    float count = mix(0.25, 0.75, u.param0);
    float spread = mix(0.05, 0.4, u.param1);
    float tailK = mix(0.5, 1.6, u.param2);

    // a steady drift: faster travel sweeps the bright tails over every pixel
    // several times a second, which reads as large-area flashing
    float travel = 0.2 * u.time;
    float vel = 1.0;

    // the heading: a fixed shallow dive (turning the long streaks sweeps
    // them across the whole frame)
    float ang = -0.36 + spread * 0.04;
    vec2 q = rot2(-ang) * p;

    // the planet geometry (used by the sky for its sunrise glow)
    vec2 pc = vec2(0.55, -3.15);
    float pr = 2.45;
    vec2 toSun = vec2(-0.3090170, 0.9510565);
    vec2 sunP = pc + toSun * pr;                    // where the sun breaks the limb
    float d = length(p - pc) - pr;
    float sunD = length(p - sunP);
    float bass = 0.0;

    // deep sky: an emission nebula with dark dust lanes, drifting with the storm
    vec3 col = vec3(0.0004, 0.0005, 0.0016);
    vec2 np = p * 0.62 + vec2(mod(travel * 0.03, 100.0), 0.0);
    float n1 = cmFbm(np + vec2(3.1, 1.7), osSteps(2.0, 3.0, detail));
    float n2 = cmFbm(np * 2.3 + vec2(n1 * 1.8, -n1) + 7.3, osSteps(2.0, 4.0, detail));
    float gas = smoothstep(0.38, 0.78, n1);          // clouds, with black sky between
    float fil = 1.0 - abs(2.0 * n2 - 1.0);           // bright ridges inside the gas
    fil = fil * fil * fil * fil;
    float dust = smoothstep(0.5, 0.72, n2) * smoothstep(0.3, 0.6, n1);
    // hue drifts across the sky: cyan, violet-magenta and a warm core near the sunrise
    // separate regions, not a blend: complementary gases mixed would turn grey
    float hueK = smoothstep(-0.35, 0.35, sin(p.x * 1.1 - p.y * 0.6 + n1 * 5.0 + mod(travel * 0.02, 6.2831853)));
    vec3 gasC = mix(palVisual(0.76, u), palVisual(0.5, u) * vec3(0.8, 0.7, 1.15), hueK);
    gasC = mix(gasC, palVisual(0.16, u), 0.7 * exp(-sunD * 1.1));
    float glowSky = gas * (0.006 + 0.07 * fil) * (1.0 - 0.9 * dust);
    col += gasC * glowSky * (0.95 + 0.08 * u.level);
    col += mix(gasC, vec3(1.0), 0.25) * fil * fil * gas * gas * 0.06 * (1.0 - dust) * mix(0.5, 1.0, detail);

    // star dust in two parallax depths, drifting with the storm
    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        float sz = mix(34.0, 19.0, fi);
        vec2 sq = (q - vec2(mod(travel * (0.012 + 0.03 * fi), 400.0), 0.0)) * sz;
        vec2 sc = floor(sq);
        vec2 sh = hash22(sc + 13.0 + fi * 71.0);
        vec2 sd = sq - sc - 0.2 - 0.6 * sh;
        float sl = (0.004 + 0.05 * vel) * (1.0 + 2.0 * fi) * sh.y;
        sd.x = max(abs(sd.x) - sl, 0.0);
        float on = step(0.9, sh.x);
        float star = exp(-dot(sd, sd) * mix(1600.0, 900.0, fi)) * on * (0.2 + 1.3 * sh.y * sh.y);
        // the brightest few carry a soft four-point glint
        float glint = on * step(0.86, sh.y) * fi * (exp(-abs(sd.x) * 60.0 - abs(sd.y) * 900.0)
                                                + exp(-abs(sd.y) * 60.0 - abs(sd.x) * 900.0)) * 0.5;
        col += mix(vec3(0.7, 0.8, 1.0), vec3(1.0, 0.85, 0.75), fract(sh.y * 13.0))
             * (star + glint) * (0.6 + 0.05 * u.level) * (1.0 - 0.7 * dust);
    }

    // the planet: a night-side disc, a cloud-lit crescent, two-layer atmosphere
    float body = 1.0 - smoothstep(-px, px, d);
    vec2 rel = p - pc;
    float lit = saturate(dot(rel / max(length(rel), 1e-4), toSun) * 1.6 - 0.1);
    vec3 atmo = palVisual(0.46, u);                  // inner, hot scattering
    vec3 atmoOut = palVisual(0.74, u);               // outer, cool high air
    vec3 sunC = palVisual(0.2, u);
    if (body > 0.0) {
        // clouds banded along the surface, catching the sunrise near the limb
        float depthIn = max(-d, 0.0);
        vec2 sp = vec2(atan(rel.x, rel.y) * 6.0, depthIn * 9.0 + 0.0);
        float cl = vnoise(sp * vec2(1.0, 2.6) + vec2(mod(u.time * 0.01, 50.0), 0.0));
        cl = cl * 0.6 + 0.4 * vnoise(sp * vec2(2.3, 6.0) + 3.0);
        float term = exp(-depthIn * 7.0) * lit;
        vec3 surf = vec3(0.0015, 0.0015, 0.003) + mix(atmo, sunC, 0.5) * term * smoothstep(0.35, 0.8, cl) * 0.16;
        surf += atmoOut * exp(-depthIn * 30.0) * 0.05;
        col = mix(col, surf, body);
    }
    float dOut = max(d, 0.0);
    float rimIn = exp(-dOut * 26.0) * (1.0 - body) + exp(-max(-d, 0.0) * 50.0) * body;
    float rimOut = exp(-dOut * 7.0) * (1.0 - body);
    float swell = 1.0 + 0.1 * bass;
    col += mix(atmo, sunC, 0.7 * exp(-sunD * 2.2)) * rimIn * (0.35 + 1.6 * lit) * swell;
    col += atmoOut * rimOut * 0.12 * (0.25 + lit) * swell;
    // sunrise: a hot point on the limb, a wide glow and an anamorphic streak
    float sunUp = 0.85 + 0.1 * bass;
    col += peakWhite(sunC, 0.7) * exp(-sunD * 38.0) * 2.2 * sunUp;
    col += sunC * exp(-sunD * 4.0) * 0.08 * sunUp;
    vec2 sq2 = p - sunP;
    col += mix(sunC, atmoOut, 0.5) * exp(-abs(sq2.y) * 160.0) * exp(-abs(sq2.x) * 1.2) * 0.25 * sunUp;

    // the storm: far to near
    CmPal P;
    P.c0 = palVisual(0.1, u); P.c1 = palVisual(0.26, u);
    P.t0 = atmo; P.t1 = palVisual(0.68, u); P.t2 = palVisual(0.9, u);
    vec3 headLight = vec3(0.0);
    int layers = osSteps(2.0, 4.0, detail);
    for (int i = 0; i < 4; i++) {
        if (i >= layers) break;
        float layer = float(i) * 3.0 / max(float(layers - 1), 1.0);
        col += cmLayer(q, layer, travel, vel, u, count, tailK, px, P, headLight);
    }
    // the heads light the gas they pass: the nebula's filaments flare up behind them
    float gasLit = (gas * (0.35 + 1.6 * fil) * (1.0 - 0.85 * dust) + 0.04) * (1.0 - body);
    col += headLight * gasLit * 0.14;
    return col; // LINEAR HDR — post chain tonemaps
}
