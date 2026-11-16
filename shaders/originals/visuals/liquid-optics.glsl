// SPDX-License-Identifier: AGPL-3.0-only
// Liquid optics.
// A macro shot through a sheet of flowing liquid glass. Behind it, in the dark,
// hangs a neon light sculpture: a ring lit round its rim by the spectrum, and
// ribbons of light that stream past at different depths. The glass bends them
// into swimming loops with spectral fringes, focuses the light into a caustic
// web on the back wall, and its own surface carries crisp softbox and strip
// light reflections along every swell. The ribbons stream on the shared
// 32-beat speed profile (cruise, build, burst, brake, drift), the liquid runs
// slowly downward and every beat drops a ripple ring into it. Bass swells the
// ripples, the spectrum lights the ring and ribbons, mids the caustics, treble
// adds a fine shiver that sparks the highlights.
// param0 = Refraction ; param1 = Caustics ; param2 = Flow

float loFbm(vec2 p, int n) {
    float v = 0.0, a = 0.5, s = 0.0;
    for (int i = 0; i < 5; ++i) {
        if (i >= n) break;
        v += a * vnoise(p);
        s += a;
        p = FBM_OCTAVE * p;
        a *= 0.5;
    }
    return v / s;
}

// Ripple ring dropped by beat k at seeded position, age in beats.
float loRing(vec2 p, float k, float age, float amp) {
    vec2 c = (hash22(vec2(k * 0.37 + 3.1, k * 0.11 + 7.7)) - 0.5) * vec2(2.6, 1.4);
    float R = 0.06 + age * 0.55;
    float r = length(p - c);
    float x = r - R;
    float env = exp(-x * x * 140.0) * exp(-age * 1.6) * smoothstep(0.0, 0.12, age);
    return amp * env * sin(x * 52.0);
}

// Height of the liquid sheet. Large warped swells plus beat ripples and a
// treble shiver; flow slides the swells down the glass.
// The slow domain warp of the swells, at q.
vec2 loWarp(vec2 q, float tw) {
    return vec2(loFbm(q * 0.6 + vec2(0.0, tw), 2), loFbm(q * 0.6 + vec2(5.2, 1.3 - tw), 2));
}

// w is the warp at this point: the taps share one warp and its first-order
// change, since it is far smoother than the tap spacing.
float loHeight(vec2 p, vec2 flow, vec2 w, int oct, float rough, vec4 rip, vec4 hero) {
    vec2 q = p * 0.78 + flow;
    // Pools of liquid with rounded, meniscus edges over flat clear glass: the
    // flat glass shows the sculpture crisp, the pools lens it, the edges catch light.
    float n = vnoise(q + 1.7 * w) + rough * (loFbm(q * 2.0 + 2.2 * w + 4.0, oct) - 0.5);
    float bead = smoothstep(0.42, 0.68, n);
    float h = 0.30 * (sqrt(bead + 0.02) - 0.1414) + 0.05 * n;
    h += loRing(p, rip.x, rip.y, rip.z) + loRing(p, rip.x - 1.0, rip.y + 1.0, rip.w);
    // Every eight beats a broad swell runs out from the sculpture's ring.
    float xh = length(p - hero.xy) - 0.1 - 0.42 * hero.z;
    h += hero.w * exp(-xh * xh * 30.0) * sin(xh * 24.0);
    return h;
}

// The neon sculpture behind the glass, in scene coordinates s.
vec3 loScene(vec2 s, VisualUniforms u, float drift, float tt, float glow, vec4 rib, vec3 pulse, float flare) {
    vec3 col = vec3(0.0);
    // Ribbons of light at four depths: nearer ones stream past faster.
    for (int i = 0; i < 4; ++i) {
        float fi = float(i);
        float x = s.x + drift * (0.55 + 0.3 * fi);
        float k1 = 1.15 + 0.33 * fi;
        float k2 = 2.9 - 0.35 * fi;
        float a1 = 0.20 - 0.025 * fi;
        float a2 = 0.06;
        float ph1 = k1 * x + fi * 2.1 + tt * 0.35;
        float ph2 = k2 * x - tt * 0.6 + fi * 1.3;
        float y = -0.78 + 0.52 * fi + 0.08 * sin(tt * 0.21 + fi * 1.7) + a1 * sin(ph1) + a2 * sin(ph2);
        float dy = a1 * k1 * cos(ph1) + a2 * k2 * cos(ph2);
        float d = abs(s.y - y) * inversesqrt(1.0 + dy * dy);
        float e = 0.35 + 2.4 * (i == 0 ? rib.x : i == 1 ? rib.y : i == 2 ? rib.z : rib.w);
        // Each beat fires a bright pulse along one ribbon, a comet with a tail.
        float pd = s.x - pulse.x;
        float pon = step(abs(pulse.y - fi), 0.5);
        e *= 1.0 + pon * pulse.z * (5.0 * exp(-pd * pd * 40.0) + 1.6 * exp(-max(-pd, 0.0) * 3.0) * step(pd, 0.0));
        vec3 c = palVisual(0.08 + 0.23 * fi, u);
        float wid = 1.0 + 0.6 * glow;
        col += c * e * (exp(-d * d * 7000.0 / wid) * 3.2 + exp(-d * 26.0) * 0.10 * wid);
    }
    // Neon ring: its rim is the spectrum, mirrored left and right.
    vec2 rc = s - vec2(0.42 * sin(tt * 0.043), 0.04 + 0.06 * sin(tt * 0.031));
    float rr = length(rc);
    float ang = abs(atan2_(rc.y, rc.x)) / 3.14159265;
    float R = 0.60 + 0.025 * glow;
    float dr = abs(rr - R);
    float sb = bandAt(u, 0.04 + 0.8 * ang);
    vec3 rcCol = mix(palVisual(0.98, u), palVisual(0.52, u), smoothstep(0.1, 0.9, ang));
    col += rcCol * (0.5 + 3.2 * sb) * (1.0 + flare + 1.2 * u.beat) * (exp(-dr * dr * 9000.0) * 3.5 + exp(-dr * 18.0) * 0.12);
    return col;
}

// Studio rig seen in the glass: softbox, two coloured strips, a top bar.
vec3 loRig(vec2 r, VisualUniforms u) {
    // a dim dome, graded top to bottom, so every swell shows its shape
    vec3 col = palRoleFog(0.62, u) * 0.025 * smoothstep(-0.6, 0.9, r.y);
    // the key softbox up-left: a broad soft lobe with a brighter core
    vec2 k = (r - vec2(-0.32, 0.38)) * vec2(1.0, 2.2);
    float kd = dot(k, k);
    col += vec3(1.0, 0.96, 0.92) * (exp(-kd * 14.0) * 1.2 + exp(-kd * 70.0) * 5.0) * (0.8 + 0.4 * u.level);
    // two coloured strip lights, lit by the low and high bands
    vec2 a1 = vec2((r.x - 0.58) * 7.0, (r.y + 0.05) * 1.4);
    vec2 a2 = vec2((r.x + 0.66) * 7.0, (r.y - 0.08) * 1.4);
    col += palRoleTrace(0.25, u) * exp(-dot(a1, a1) * 2.0) * (1.4 + 3.0 * band(u, 4));
    col += palRolePeak(0.55, u) * exp(-dot(a2, a2) * 2.0) * (1.4 + 3.0 * band(u, 26));
    return col;
}

// Far bokeh: soft discs of out-of-focus light well behind the sculpture, each
// with the faint bright rim of a real lens's bokeh, breathing with its band.
vec3 loBokeh(vec2 s, VisualUniforms u) {
    const float cells = 2.4;
    vec2 g = s * cells;
    vec2 id = floor(g);
    vec2 h = hash22(id + 41.0);
    if (h.x < 0.45) return vec3(0.0);
    vec2 d = fract(g) - 0.5 - (h - 0.5) * 0.3;
    float R = 0.16 + 0.16 * hash21(id + 5.3);
    float r = length(d) / R;
    float px = 2.0 * cells / max(u.resolution.y, 1.0) / R;
    float disc = smoothstep(1.0, 1.0 - 0.06 - px, r);
    float rim = disc * smoothstep(0.55, 1.0, r);
    float lvl = 0.25 + 1.4 * bandAt(u, hash21(id + 2.2));
    vec3 c = palVisual(fract(h.y * 3.1 + 0.2), u);
    return c * (disc * 0.035 + rim * 0.03) * lvl;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    int oct = detail > 0.5 ? 3 : 2;
    float rough = mix(0.06, 0.10, detail);

    float refr = mix(0.05, 0.20, u.param0);
    float causticAmt = mix(0.4, 1.8, u.param1);
    float flowRate = mix(0.25, 1.2, u.param2);

    // Ribbons stream on the speed profile; the liquid itself flows steadily.
    vec2 fl = osFlight(u, 1.0, 0.8);
    float drift = fl.x * 0.12;
    float tt = mod(u.time, 1200.0);
    vec2 flow = vec2(0.03 * sin(tt * 0.05), tt * 0.11 * flowRate);
    float tw = tt * 0.05 * flowRate;

    // Beat ripples: this beat's ring and the last one's, amplitude from bass.
    float bc = mod(floor(u.beatCount), 512.0);
    float age = saturate(u.beatPhase);
    float bass = saturate(u.bass);
    vec4 rip = vec4(bc, age, (0.006 + 0.010 * bass + 0.008 * u.bassImpact),
                    0.006 + 0.010 * bass);
    // Every eight beats the ring flares and a broad swell runs out from it.
    vec2 ringC = vec2(0.42 * sin(tt * 0.043), 0.04 + 0.06 * sin(tt * 0.031));
    float ageH = mod(floor(u.beatCount), 8.0) + age;
    float heroA = exp(-ageH * 0.55) * smoothstep(0.0, 0.15, ageH) * (0.010 + 0.016 * bass);
    vec4 hero = vec4(ringC, ageH, heroA);
    float flare = 2.2 * exp(-ageH * 2.5) * (0.5 + 0.5 * saturate(u.bassImpact + u.level));
    // A pulse runs along one ribbon per beat, left to right.
    vec3 pulse = vec3(-1.5 + 3.7 * age, mod(floor(u.beatCount), 4.0), 0.4 + 0.8 * saturate(u.beat + u.onset));
    float micro = 0.002 + 0.008 * saturate(u.treble);

    // Five taps: slope for refraction and highlights, curvature for caustics.
    float e = 0.012;
    vec2 wq = p * 0.78 + flow;
    vec2 w0 = loWarp(wq, tw);
    vec2 wdx = (loWarp(wq + vec2(0.04, 0.0), tw) - w0) * (0.78 * e / 0.04);
    vec2 wdy = (loWarp(wq + vec2(0.0, 0.04), tw) - w0) * (0.78 * e / 0.04);
    float h0 = loHeight(p, flow, w0, oct, rough, rip, hero);
    float hx1 = loHeight(p + vec2(e, 0.0), flow, w0 + wdx, oct, rough, rip, hero);
    float hx0 = loHeight(p - vec2(e, 0.0), flow, w0 - wdx, oct, rough, rip, hero);
    float hy1 = loHeight(p + vec2(0.0, e), flow, w0 + wdy, oct, rough, rip, hero);
    float hy0 = loHeight(p - vec2(0.0, e), flow, w0 - wdy, oct, rough, rip, hero);
    vec2 grad = vec2(hx1 - hx0, hy1 - hy0) / (2.0 * e);
    float lap = (hx1 + hx0 + hy1 + hy0 - 4.0 * h0) / (e * e);
    // The treble shiver tilts the surface only; kept out of the curvature so
    // the value-noise lattice never prints into the caustics.
    vec2 mq = p * 11.0 + flow * 4.0;
    float m0 = vnoise(mq);
    grad += micro * vec2(vnoise(mq + vec2(0.05, 0.0)) - m0, vnoise(mq + vec2(0.0, 0.05)) - m0) * (11.0 / 0.05);

    // Beads of liquid on the clear glass: each is a tiny ball lens that shows
    // the sculpture inverted and magnified, wide-angle toward its rim, with a
    // dark rim of total internal reflection. They ride the flow and merge into
    // the pools.
    vec2 gq = (p * 0.78 + flow) * 5.0;
    vec2 gid = floor(gq);
    vec2 gh = hash22(gid + 13.0);
    float dR = (0.12 + 0.22 * hash21(gid + 7.0) * hash21(gid + 9.0) + 0.06 * hash21(gid + 3.0)) / (0.78 * 5.0);
    vec2 dc = (gid + 0.5 + (gh - 0.5) * 0.3) / 5.0 / 0.78 - flow / 0.78;
    vec2 dd = p - dc;
    float dq = length(dd) / dR;
    float pxl = 2.0 / max(u.resolution.y, 1.0);
    float dropOn = step(0.62, gh.x) * (1.0 - smoothstep(0.05, 0.12, h0));
    float inDrop = dropOn * smoothstep(1.0, 1.0 - pxl / dR * 1.5, dq);
    float lam = 2.3 * inversesqrt(max(1.0 - dq * dq, 0.0) + 0.06);

    // Transmitted scene with dispersion: red bends least, blue most.
    float glow = saturate(u.mid);
    vec2 off = mix(-grad * refr, -dd * lam, inDrop);
    vec4 rib = vec4(bandAt(u, 0.06), bandAt(u, 0.26), bandAt(u, 0.46), bandAt(u, 0.66));
    vec3 col;
    col.r = loScene(p + off * 0.90, u, drift, tt, glow, rib, pulse, flare).r;
    col.g = loScene(p + off * 1.00, u, drift, tt, glow, rib, pulse, flare).g;
    col.b = loScene(p + off * 1.12, u, drift, tt, glow, rib, pulse, flare).b;

    // Back wall caustics: the glass focuses a cool wash into a web. Per-channel
    // focus depths split the web into spectral edges.
    float hue = 0.30 + 0.12 * sin(tt * 0.02) + 0.1 * h0;
    vec3 wash = palVisual(hue, u);
    float D = 0.02 * causticAmt;
    vec3 focus = vec3(1.0 / max(1.0 + D * 0.88 * lap, 0.25),
                      1.0 / max(1.0 + D * 1.00 * lap, 0.25),
                      1.0 / max(1.0 + D * 1.14 * lap, 0.25));
    focus = focus * focus * focus;
    col += loBokeh(p * 0.85 + off * 0.6 + vec2(drift * 0.22, 0.0), u);
    float wallLight = (0.022 + 0.04 * glow) * (1.0 - 0.35 * smoothstep(0.4, 1.6, length(p)));
    col += wash * focus * wallLight * causticAmt;

    // Thick beads tint the light they pass, like coloured glass.
    vec3 absorb = mix(vec3(1.0), palVisual(0.12, u) * 1.1, 0.35 * smoothstep(0.45, 0.85, h0));
    col *= absorb;
    // Deep backdrop: near-black, faintly graded so the sculpture has a room.
    col += mix(palRoleFog(0.05, u), palRoleFog(0.55, u), uv.x) * 0.006 * (1.2 - 0.5 * abs(p.y));

    // Surface: crisp studio reflections on the swells, Fresnel-weighted.
    vec3 n = normalize(vec3(-grad * 0.55, 1.0));
    vec2 dn = dd / dR * inversesqrt(max(1.0 - dq * dq, 0.0) + 0.04);
    n = normalize(mix(n, normalize(vec3(-dn * 0.8, 1.0)), inDrop));
    col *= 1.0 - inDrop * 0.85 * smoothstep(0.72, 0.97, dq);
    vec3 r = reflect(vec3(0.0, 0.0, -1.0), n);
    float fres = 0.05 + 0.95 * pow(1.0 - n.z, 2.0);
    col += loRig(r.xy, u) * (0.12 + fres);
    // Pin specular glints where the shiver catches the key light.
    float nh = saturate(dot(n, normalize(vec3(-0.35, 0.45, 1.0))));
    col += vec3(1.0, 0.97, 0.94) * pow(nh, 300.0) * (1.5 + 3.0 * saturate(u.treble));

    // Gentle lens falloff, not a black frame.
    col *= 1.0 - 0.35 * smoothstep(0.7, 1.9, length(p));

    col = feedbackTrail(col, uv, min(u.trailDecay, 0.40), 0.0, 0.0);
    return col; // LINEAR HDR
}
