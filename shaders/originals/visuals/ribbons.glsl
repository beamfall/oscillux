// SPDX-License-Identifier: AGPL-3.0-only
// Ribbons.
// A sheaf of foil ribbons is drawn through a ring of light. The ribbons are
// cinched where they pass through the ring and fan out to both edges of the
// frame; the ring is the only key light, so every satin highlight leans
// towards it and the ribbons glow where they thread it. The foil shifts hue as
// each ribbon twists, and every ribbon has a spectral edge line tuned to its
// own band. Every beat the ring fires light packets outward along a new set of
// ribbons in both directions; the bass opens the ring and the sheaf breathes
// with it. The flow follows the shared 32-beat speed profile.
// param0 = Flow ; param1 = Width ; param2 = Layers

const float RB_TAU = 6.2831853;

// The palette read once per pixel at its five stops and blended here; the
// library read walks the whole stop table on every call.
struct RbPalette { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

RbPalette rbPalLoad(VisualUniforms u) {
    RbPalette P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 rbPal(RbPalette P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float RB_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 rbFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * RB_RUN[32] + RB_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

// One ribbon at q (its own layer space). The wave is squeezed towards ycen by
// the waist profile (wx = waist x, kw = waist sharpness, wmin = squeeze at the
// waist). Returns (coverage, signed distance across the ribbon in its
// half-width units, twist angle, centreline slope).
vec4 rbRibbon(vec2 q, float y0, float amp, float fr, float ph, float tw, float tph, float halfW, float aa,
              float wx, float ycen, float kw, float wmin) {
    float a1 = fr * q.x + ph;
    float a2 = 2.3 * fr * q.x - 1.7 * ph + 1.9;
    float yr = y0 - ycen + amp * (sin(a1) + 0.35 * sin(a2));
    float sr = amp * fr * (cos(a1) + 0.805 * cos(a2));
    float dx = q.x - wx;
    float g = exp(-dx * dx * kw);
    float spread = 1.0 - (1.0 - wmin) * g;
    float yc = ycen + yr * spread;
    float slope = sr * spread + yr * (1.0 - wmin) * g * 2.0 * kw * dx;
    float tau = tw * q.x + tph;
    // apparent half height: the face foreshortened by the twist plus the edge;
    // the ribbons narrow where the ring cinches them
    float hh = halfW * (1.0 - 0.45 * g) * (abs(cos(tau)) + 0.09 * abs(sin(tau))) + 0.0015;
    float dy = (q.y - yc) * inversesqrt(1.0 + slope * slope);
    float cov = 1.0 - smoothstep(hh - aa, hh + aa, abs(dy));
    return vec4(cov, dy / hh, tau, slope);
}

// The ring: an ellipse (a circle across the flow seen at a slant). Returns the
// distance to its line and which side of the ring the point is on (1 = near).
vec2 rbRing(vec2 d, float rx, float ry) {
    float f = length(vec2(d.x / rx, d.y / ry));
    vec2 gr = vec2(d.x / (rx * rx), d.y / (ry * ry)) / max(f, 1e-4);
    float dist = abs(f - 1.0) / max(length(gr), 1e-4);
    return vec2(dist, smoothstep(-0.004, 0.004, d.x));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float px = 1.5 / u.resolution.y;
    RbPalette P = rbPalLoad(u);

    float flow = mix(0.5, 1.6, u.param0);
    float widthK = mix(0.6, 1.5, u.param1);
    int layers = int(mix(5.0, 12.0, u.param2) + 0.5);

    // all motion is integer multiples of one wrapped phase, so it never jumps
    vec2 fl = rbFlight(u, 1.0, 0.45);
    float base = mod(fl.x * 0.16 * flow, RB_TAU);
    float rush = saturate((fl.y - 1.0) / 3.5);
    float tb = mod(u.time, 600.0);
    float bp = saturate(u.beatPhase);
    float bassG = saturate(u.bass);
    float lvl = saturate(u.level);
    float cyc = fract((u.beatCount + bp) / 32.0);

    // gentle diagonal composition
    vec2 pr = vec2(0.97 * p.x + 0.25 * p.y, -0.25 * p.x + 0.97 * p.y);

    // the ring drifts slowly left of centre; the bass opens it and the sheaf
    // breathes open with it
    vec2 rc0 = vec2(-0.16 + 0.1 * sin(tb * 0.031), 0.03 * sin(tb * 0.023));
    float ringR = 0.23 + 0.045 * bassG + 0.03 * lvl;
    float ringRx = ringR * (0.2 + 0.06 * sin(tb * 0.019));
    float wmin = ringR * 0.78;
    float kw = 6.5;
    vec2 rd = pr - rc0;

    // named stops: purple, pink, coral, gold, teal for this palette
    vec3 deep = P.c0;
    vec3 teal = P.c4;
    vec3 gold = P.c3;
    // the ring burns gold, warming to coral in the bursts and with the bass
    vec3 ringCol = peakWhite(mix(gold, P.c2, 0.35 * rush + 0.25 * bassG), 0.2);

    // black stage, one soft backlight whose hue walks the palette over the
    // 32-beat cycle, and the ring's glow
    vec3 backA = rbPal(P, 0.12 + 0.2 * (0.5 - 0.5 * cos(cyc * RB_TAU)));
    vec2 cB = vec2(0.55 + 0.2 * cos(tb * 0.043), -0.3 + 0.15 * sin(tb * 0.061));
    float gB = exp(-dot(p - cB, p - cB) * 3.0);
    vec3 col = deep * 0.003;
    col += backA * (0.025 + 0.04 * saturate(u.mid) + 0.02 * rush) * (gB + gB * gB * gB);
    float rr = length(rd / vec2(ringRx * 2.2, ringR));
    float ringGlow = exp(-rr * rr * 1.6) * (0.05 + 0.09 * bassG + 0.05 * rush);
    col += ringCol * ringGlow * 0.6;
    vec3 fogCol = mix(deep, backA, 0.3) * 0.03;

    // the back half of the ring, behind the ribbons
    vec2 ring = rbRing(rd, ringRx, ringR);
    float ringPulse = 0.45 + 0.55 * saturate(0.5 * bassG + 0.8 * (1.0 - bp) * (1.0 - bp) * saturate(u.beat + u.bassImpact));
    // a bright bead runs round the ring with the flow, so the hoop reads as metal
    float ang = atan(rd.y / ringR, rd.x / ringRx);
    float bd = mod(ang - base * 2.0 + 3.14159265, RB_TAU) - 3.14159265;
    float bead = 1.0 + 2.5 * exp(-bd * bd * 6.0);
    float ringLine = (exp(-ring.x / (px * 2.2)) + 0.3 * exp(-ring.x * 70.0)) * bead;
    // each beat a faint echo of the ring ripples outward and fades
    vec2 echo = rbRing(rd, ringRx * (1.0 + 0.5 * bp), ringR * (1.0 + 0.9 * bp));
    float echoLine = (exp(-echo.x / (px * 1.6)) + 0.2 * exp(-echo.x * 60.0)) * (1.0 - bp) * (1.0 - bp)
                   * (0.25 + 0.6 * saturate(u.beat + u.bassImpact));
    col += ringCol * (ringLine * ringPulse + echoLine) * (1.0 - ring.y) * 0.9;

    // teal rim light from the lower right; the key comes from the ring
    vec3 L2 = normalize(vec3(0.6, -0.55, 0.35));
    vec3 V = vec3(0.0, 0.0, 1.0);
    vec3 H2 = normalize(L2 + V);
    vec3 Lr = normalize(vec3(-rd, 0.35));
    vec3 Hr = normalize(Lr + V);
    float rDist = dot(rd, rd);
    float keyI = 0.35 + 1.1 / (1.0 + rDist * 5.0);
    float thread = exp(-rd.x * rd.x * 60.0);   // ribbons glow where they pass through

    float flare = (1.0 - bp) * (1.0 - bp) * (0.35 + 0.65 * saturate(u.beat + u.bassImpact));
    // Each beat the ring fires light packets outward along about a third of
    // the ribbons (a new set every beat): bright heads ease away from the ring
    // in both directions over the beat with tails back to it.
    float bcR = mod(floor(u.beatCount), 64.0);
    float head = 1.9 * (1.0 - (1.0 - bp) * (1.0 - bp));
    float pEnv = (1.0 - 0.7 * bp) * (0.45 + 0.55 * saturate(u.level + 0.3 * u.beat)) * (0.5 + 0.9 * u.beat);
    float adx = abs(rd.x) - head;
    float pShape = 1.6 * exp(-adx * adx * 220.0) + 0.6 * exp(min(adx, 0.0) * 2.2) * step(adx, 0.0);
    bool shadows = detail > 0.3;
    float cent = 0.03 * u.spectralCentroid;

    // back to front
    for (int i = 0; i < 12; i++) {
        if (i >= layers) break;
        float fi = float(i);
        float back = 1.0 - fi / max(float(layers - 1), 1.0);   // 1 farthest, 0 nearest
        float dep = i == layers - 1 ? 0.62 : mix(1.0, 2.8, back);   // far layers cover more space
        float h1 = hash11(fi * 3.17 + 0.5);
        float h2 = hash11(fi * 7.31 + 1.7);
        float h3 = hash11(fi * 1.93 + 4.1);
        float f = (fi + 0.5) / float(layers);
        float lv = bandAt(u, 0.04 + 0.9 * f);

        vec2 q = pr * dep;
        float y0 = (mix(-0.8, 0.8, fract(fi * 0.618 + 0.31)) + 0.1 * (h2 - 0.5)) * dep;
        float amp = (0.12 + 0.16 * h2) * dep * (1.0 + 0.2 * lv);
        float fr = (1.6 + 1.4 * h3) / dep;
        float ph = base * (1.0 + floor(h2 * 1.99)) + RB_TAU * h1;
        float tw = (1.1 + 1.6 * h1) / dep;
        float tph = base * (1.0 + floor(h3 * 1.99)) * -1.0 + RB_TAU * h3;
        float halfW = (0.045 + 0.05 * h3) * widthK * dep * (1.0 + 0.12 * lv);
        float blur = px * dep * (1.0 + 2.5 * back * back) + (i == layers - 1 ? 0.012 : 0.0);
        float wx = rc0.x * dep;
        float ycen = rc0.y * dep;
        float kwl = kw / (dep * dep);

        // soft shadow cast on everything already drawn
        if (shadows) {
            vec4 sh = rbRibbon(q + vec2(-0.02, 0.05) * dep, y0, amp, fr, ph, tw, tph, halfW * 1.15, 0.05 * dep,
                               wx, ycen, kwl, wmin);
            col *= 1.0 - 0.6 * sh.x;
        }

        vec4 rb = rbRibbon(q, y0, amp, fr, ph, tw, tph, halfW, blur, wx, ycen, kwl, wmin);
        // light spilling from the spectral edges onto the space around the ribbon
        float hh = halfW * (abs(cos(rb.z)) + 0.09 * abs(sin(rb.z))) + 0.0015;
        float outside = max(abs(rb.y) * hh - hh, 0.0) / dep;
        vec3 ec = rbPal(P, 0.1 + 0.8 * f);
        col += ec * exp(-outside * 28.0) * (0.012 + 0.22 * lv * lv) * (1.0 - 0.6 * back);
        float fire = step(0.64, hash11(fi * 5.31 + bcR * 1.73));
        float pulse = fire * pEnv * pShape;
        // packets are the warm accent (gold on most, teal on the rest), so the
        // cool satin always carries a complementary light
        vec3 pc = hash11(fi * 2.7 + 0.3) < 0.7 ? gold : teal;
        col += pc * exp(-outside * 60.0) * pulse * 0.3 * (1.0 - 0.6 * back);
        if (rb.x > 0.001) {
            float tau = rb.z;
            float c = cos(tau), s = sin(tau);
            float v = clamp(rb.y, -1.0, 1.0);
            vec3 T = normalize(vec3(1.0, rb.w, 0.0));
            // face normal from the twist, curved a little across the width
            vec3 N = vec3(rb.w * s, -s, c);
            N = normalize(N + vec3(0.0, 0.45 * v, 0.0));
            bool backFace = N.z < 0.0;
            N *= backFace ? -1.0 : 1.0;
            float face = abs(c);
            float edgeness = 1.0 - smoothstep(0.08, 0.35, face);   // seen nearly edge-on

            // foil faces in purple, hot pink, coral, gold or teal; the foil walks
            // to the neighbouring hue as the ribbon turns away; backs darker
            float pick = mod(fi * 3.0, 5.0);   // every hue appears in every stack
            float tF = pick < 0.5 ? 0.05 : (pick < 1.5 ? 0.26 : (pick < 2.5 ? 0.52 : (pick < 3.5 ? 0.999 : 0.78)));
            vec3 cF = rbPal(P, tF + cent + 0.2 * (1.0 - face) * (pick < 2.5 ? 1.0 : -1.0));
            vec3 cB = (pick < 2.5 ? P.c0 : P.c1) * 0.6;
            vec3 alb = backFace ? cB : cF;
            vec3 sheen = mix(ringCol * 0.6, cF * 1.4, 0.45);

            float diff = saturate(dot(N, Lr));
            // satin: a highlight stretched along the ribbon, leaning to the ring
            vec3 Na = normalize(N - T * dot(N, T) * 0.75);
            float nh = saturate(dot(Na, Hr));
            float spec = pow(nh, 90.0) * 1.6 + pow(nh, 14.0) * 0.18;
            float fres = pow(1.0 - saturate(N.z), 3.0);

            float diff2 = saturate(dot(N, L2));
            float spec2 = pow(saturate(dot(Na, H2)), 40.0);
            vec3 rcol = alb * (0.012 + 0.5 * diff * diff * keyI);
            rcol += teal * (0.05 * diff2 + 0.3 * spec2);
            rcol += sheen * spec * 1.8 * keyI * (backFace ? 0.5 : 1.0);
            rcol += mix(alb, teal, 0.3) * fres * 0.25;
            // the thin edge catches light when the ribbon turns side-on
            rcol += mix(alb, ringCol, 0.5) * edgeness * (0.2 + 0.6 * diff) * keyI;
            // threaded through the ring, the foil glows
            rcol += mix(cF, ringCol, 0.4) * thread * ringPulse * (0.25 + 0.5 * face);

            // spectral edge line along both borders, and a beat glint flowing
            // out of the ring along it
            float rim = smoothstep(0.72, 0.97, abs(v));
            float gd = abs(rd.x) - 1.4 * bp;
            float glint = exp(-gd * gd * 18.0) * flare;
            rcol += ec * rim * (0.15 + 3.0 * lv * lv + 2.5 * glint) * (1.0 - 0.5 * back);

            // the light packet: an emissive core in the packet colour
            float core = exp(-v * v * 5.0);
            rcol += mix(pc, vec3(1.0), 0.25 * core) * pulse * (0.35 + 2.2 * core) * (1.0 - 0.4 * back);

            // haze over far layers
            rcol = mix(rcol, fogCol, 0.7 * back * back);
            rcol *= 1.0 - 0.3 * back;
            col = mix(col, rcol, rb.x * (1.0 - 0.1 * back));
        }
    }

    // the near half of the ring, over the ribbons, with a white-hot core
    col += ringCol * (ringLine * ringPulse * ring.y + echoLine * echo.y);
    col += vec3(1.0, 0.9, 0.75) * exp(-ring.x / (px * 0.7)) * ringPulse * ring.y * 0.6;
    return col; // LINEAR HDR — post chain tonemaps
}
