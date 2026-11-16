// SPDX-License-Identifier: AGPL-3.0-only
// Drift.
// A macro shot of liquid-glass droplets drifting over a caustic pool in the
// dark. The pool light is two crossing caustic nets (the walls of churning,
// curved Voronoi cells) with sharp white-hot cores, spectral fringes and a
// wandering focus that thickens some lines and thins others. The droplets
// merge and part, wobble as they go, magnify and split the net beneath them,
// carry studio-softbox reflections, hot glints and beaded bubbles, and throw
// focused spots and soft shadows onto the floor. Once a bar a ripple ring runs
// out across the pool, bending and brightening the caustics; the bursts of
// the shared 32-beat speed profile throw the biggest rings and the fastest
// drift. Bass swells and jolts the droplets and their inner glow, colour lanes
// riding the floor each follow their own band, treble sparks the glints. The
// artwork becomes the low-frequency tint of the glass and the light it lets
// through.
// param0 = Flow (drift speed) ; param1 = Lens Pulse (bass swell) ; param2 = Edge Spectra (dispersion)

// The palette, read once per pixel at fixed stops and blended locally.
struct DrPal { vec3 h0; vec3 h1; vec3 h2; vec3 teal; vec3 g0; vec3 g1; };

vec3 drHue(DrPal P, float t) {
    return t < 0.5 ? mix(P.h0, P.h1, t * 2.0) : mix(P.h1, P.h2, t * 2.0 - 1.0);
}

// One layer of the caustic net: the walls of a churning Voronoi pattern, where
// the light under a rippled surface focuses into lines. Returns the gap to the
// nearest wall (F2 - F1). The cell points trace Lissajous loops on whole
// multiples of ang, so the clock wraps without a seam.
float drNet(vec2 q, float ang, float k) {
    vec2 ip = floor(q);
    vec2 fp = q - ip;
    float f1 = 9.0, f2 = 9.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 o = vec2(float(x), float(y));
            vec2 h = hash22(ip + o);
            vec2 pt = o + 0.5 + 0.36 * sin(vec2(ang, ang * k) + 6.2831853 * h);
            vec2 d = pt - fp;
            float dd = dot(d, d);
            f2 = min(f2, max(f1, dd));
            f1 = min(f1, dd);
        }
    }
    return sqrt(f2) - sqrt(f1);
}

// The lit pool under the droplets, in floor coordinates: two crossing caustic
// nets with sharp white-hot cores and spectral fringes, bent and brightened by
// the ripple ring (rip = source, front radius, strength). scroll is how far
// the floor has drifted.
vec3 drPool(vec2 f, float scroll, float ang, float w, float dsp, vec4 rip, vec3 tint, DrPal P, float acc, VisualUniforms u) {
    vec2 rv = f - rip.xy;
    float rr = length(rv);
    float rx = (rr - rip.z) / 0.24;
    float env = exp(-rx * rx) * rip.w;
    float crest = env * max(sin(rx * 5.0 + 1.2), 0.0);
    f += rv / max(rr, 1e-3) * env * 0.2 * sin(rx * 5.0);
    vec2 q = f * 1.05;
    q += 0.42 * sin(q.yx * 1.3 + vec2(ang, -ang));     // bend the walls into curves
    // the focus wanders: some stretches of the net gather light into thick
    // bright lines, others thin out to faint threads
    float m = vnoise(f * 0.75 + 0.7 * vec2(sin(ang), cos(ang)) + 11.0);
    m = m * m * (3.0 - 2.0 * m);
    w *= 0.6 + 0.9 * m;
    float e1 = drNet(q, ang, 2.0);
    float e2 = drNet(mat2(0.8, -0.6, 0.6, 0.8) * q * 1.43 + 7.3, -ang, 1.0);
    // a Lorentzian line: a sharp core with a long soft glow; red runs a little
    // wider than blue, which leaves spectral fringes on every line
    vec3 sc = vec3(1.0 - dsp, 1.0, 1.0 + dsp);
    vec3 a1 = e1 * sc / w;
    vec3 a2 = e2 * sc / (w * 1.25);
    vec3 l1 = 1.0 / (1.0 + a1 * a1);
    vec3 l2 = 1.0 / (1.0 + a2 * a2);
    float mm = 0.25 + 1.5 * m;
    // colour lanes that ride along with the floor, each lit by its own band
    float lane = 0.5 + 0.5 * sin(f.x * 0.55 + 0.6 * sin(f.y * 0.8));
    float b = bandAt(u, lane);
    vec3 hue = drHue(P, lane) * tint;                      // the main net: rose to gold
    vec3 hue2 = P.teal * tint * (1.0 + 2.2 * acc);         // the finer net: teal, flaring cool on the beat
    vec3 x12 = l1 * l2;
    vec3 c = hue * l1 + hue2 * 0.42 * l2 + peakWhite(hue, 0.6) * 1.6 * x12;   // crossings focus white-hot
    // light pool: brightest mid-frame, falling to black at the edges (in view
    // space, so it never drifts away with the floor)
    vec2 fv = (f - vec2(scroll, 0.0)) * vec2(0.42, 0.75);
    float pool = exp(-dot(fv, fv));
    vec3 col = c * mm * (0.35 + 1.9 * b * b + 0.5 * u.level);
    col *= 1.0 + 1.5 * env + 3.0 * crest;
    col += peakWhite(hue, 0.4) * crest * 0.3;             // the crest catches the light
    // the faint wide glow of light scattered in the water
    col += mix(P.g0, P.g1, lane) * tint * 0.018 * (0.6 + u.mid);
    return col * pool;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float px = 2.0 / max(u.resolution.y, 1.0);

    float flow = mix(0.5, 1.6, u.param0);
    float swellK = mix(0.0, 0.16, u.param1);
    float disp = mix(0.15, 1.0, u.param2);

    vec2 fl = osFlight(u, flow, 0.6);
    float ang = mod(fl.x * 0.5, 6.2831853);            // the caustic clock, wrapped
    float drift = mod(fl.x * 0.09, 480.0);
    float rush = saturate((fl.y - 1.0) / 3.0);

    // The artwork as a soft, zoomed tint; never a picture, never the brightness.
    vec3 art = IMG(photoCover(uv * 0.2 + 0.4, u.resolution, IMGSIZE)).rgb;
    vec3 tint = mix(vec3(1.0), art / max(max(art.r, max(art.g, art.b)), 0.08), 0.45);

    DrPal P;
    P.h0 = palVisual(0.38, u);
    P.h1 = palVisual(0.56, u);
    P.h2 = palVisual(0.74, u);
    P.teal = palVisual(0.95, u);
    P.g0 = palVisual(0.1, u);
    P.g1 = palVisual(0.3, u);
    vec3 pal6 = palVisual(0.6, u);
    // the complementary accent: the cool net flares on the downbeats, softer
    // on the offbeats
    float acc = u.bassImpact * u.bassImpact * (mod(u.beatCount, 2.0) < 1.0 ? 0.9 : 0.35);

    // a gentle studio perspective on the floor: the top recedes
    float persp = 1.0 / (1.25 - 0.3 * p.y);
    vec2 f = vec2(p.x, p.y + 0.4) * persp * 1.6 + vec2(drift * 0.5, 0.0);

    // caustic line width in floor units, never thinner than about a pixel
    float lw = max(0.022, 2.6 * px);

    // a ripple ring once a bar: a drop of light falls into the pool, the ring
    // runs out across the floor bending and brightening the caustics; it rides
    // the floor as the floor drifts. The burst of the speed profile throws the
    // biggest rings.
    float bp = saturate(u.beatPhase);
    float b4 = (mod(u.beatCount, 4.0) + bp) * 0.25;
    float bar = floor(u.beatCount / 4.0);
    vec2 rh = hash22(vec2(mod(bar, 512.0), 4.1));
    float driftBack = 0.09 * b4 * 4.0 * ((flow * 0.4 + 0.6) * fl.y + flow * 0.1) * 0.5;
    vec2 rsrc = vec2(drift * 0.5 - driftBack + (rh.x - 0.5) * 2.2, 0.45 + (rh.y - 0.5) * 0.9);
    float ramp = (1.0 - b4) * (1.0 - b4) * smoothstep(0.0, 0.03, b4) * (0.45 + 0.7 * u.bassImpact + 0.8 * rush);
    vec4 rip = vec4(rsrc, 0.05 + 3.2 * sqrt(b4), ramp);
    // the next drop of light: over the bar's last beat a bead gathers where the
    // next ring will start, tightening and brightening until it lands
    vec2 nh = hash22(vec2(mod(bar + 1.0, 512.0), 4.1));
    float rate = driftBack / max(b4, 1e-3);
    vec2 nsrc = vec2(drift * 0.5 + rate * (1.0 - b4) + (nh.x - 0.5) * 2.2, 0.45 + (nh.y - 0.5) * 0.9);
    float gather = smoothstep(0.72, 1.0, b4);

    // ---- droplets: a smooth gaussian metaball field ----
    const float DR_THR = 0.42;
    vec2 L2 = normalize(vec2(-0.55, 0.8));
    float F = 0.0;
    vec2 G = vec2(0.0);
    float shadow = 0.0;
    float focus = 0.0;
    int nDrops = osSteps(4.0, 6.0, detail);
    float span = 5.0;
    float dc = mod(fl.x * 0.21, 6283.1853);            // the droplets' own orbit clock
    for (int k = 0; k < 6; k++) {
        if (k >= nDrops) break;
        float fk = float(k);
        vec2 h = hash22(vec2(fk * 3.17, 9.1));
        float sp = 0.45 + 1.1 * h.x;
        float x = mod(h.y * span - drift * sp, span) - span * 0.5;
        float bob = sin(mod(dc * (0.6 + 0.7 * h.y) + fk * 2.1, 6.2831853));
        vec2 c = vec2(x, mix(-0.5, 0.4, fract(h.x * 3.7 + fk * 0.37)) + 0.26 * bob);
        float b = bandAt(u, 0.1 + 0.12 * fk);
        float r = mix(0.21, 0.4, h.y) * (1.0 + swellK * (u.bassImpact + 0.5 * b));
        vec2 d = p - c;
        // the surface wobbles: a slow squash that breathes with the mids and
        // jolts on the bass, never at rest between beats
        float wa = mod(drift * 3.0 * sp + fk * 1.7, 6.2831853);
        float wob = (0.06 + 0.1 * b + 0.12 * u.bassImpact) * sin(wa * 2.0 + 6.0 * b4);
        vec2 wd = vec2(cos(wa), sin(wa));
        vec2 dq = d + wd * dot(d, wd) * wob;
        float e = exp(-dot(dq, dq) / (r * r));
        F += e;
        G += -2.0 * d / (r * r) * e;
        // floor shadow and the focused spot of light the droplet throws
        vec2 ds = d + L2 * r * 0.85;
        shadow += exp(-dot(ds, ds) / (r * r * 0.9));
        vec2 df = d + L2 * r * 1.0;
        focus += exp(-dot(df, df) / (r * r * 0.035)) * (0.6 + 2.0 * b);
    }

    // ---- the floor seen directly (outside the glass) ----
    vec3 pool = drPool(f, drift * 0.5, ang, lw, 0.06, rip, tint, P, acc, u);
    vec3 col = vec3(0.0015, 0.002, 0.003) + pool;
    col *= 1.0 - 0.75 * saturate(shadow) * (1.0 - smoothstep(DR_THR - 0.1, DR_THR, F));
    vec3 focusC = pal6 * tint;
    col += focusC * focus * (0.12 + 0.6 * luma(pool)) * (0.7 + 0.6 * u.level);
    if (gather > 0.0) {
        vec2 bd = f - nsrc;
        float bw = 0.004 + 0.05 * (1.0 - gather);
        float bead = exp(-dot(bd, bd) / bw) * gather * gather;
        col += peakWhite(P.h2, 0.6) * bead * 1.4 + P.h1 * exp(-dot(bd, bd) * 6.0) * gather * 0.12;
    }

    // ---- the glass ----
    float gl = length(G);
    float sd = (F - DR_THR) / max(gl, 1e-3);           // ~signed distance to the surface
    float cover = smoothstep(-px, px, sd);
    if (cover > 0.0) {
        float th = sqrt(max(F - DR_THR, 0.0));
        vec2 gh = G * 0.5 / max(th, 0.06);              // slope of the height field
        vec3 n = normalize(vec3(-gh * 0.11, 1.0));
        float ndv = saturate(n.z);
        vec2 off = n.xy * (0.55 + 0.35 * th) - p * 0.12; // refraction plus lens magnification
        // the lens magnifies the net, so its lines run wider and split further
        vec3 refr = drPool(f + off, drift * 0.5, ang, lw * 1.4, 0.08 + 0.3 * disp, rip, tint, P, acc, u);
        // the glass is a tinted, slightly absorbing body
        vec3 absorb = mix(mix(P.h0, P.h2, 0.47), art, 0.5);
        vec3 trans = exp(-th * 2.2 * (1.0 - clamp(absorb, 0.0, 1.0)));
        vec3 g = refr * 1.35 * trans;
        // inner glow, pulsing with bass and the beat
        float pulse = phasePulse(u, 0.0, 0.12);
        g += palRoleBass(0.3, u) * trans * th * (0.04 + 0.5 * u.bassImpact * u.bassImpact + 0.15 * pulse * u.beat);
        // studio reflection: two softboxes and a floor bounce
        vec3 rd = reflect(vec3(0.0, 0.0, -1.0), n);
        float box1 = smoothstep(0.12, 0.0, abs(rd.x + 0.38)) * smoothstep(0.1, 0.35, rd.y);
        float box2 = smoothstep(0.06, 0.0, abs(rd.y - 0.52)) * smoothstep(0.55, 0.2, abs(rd.x - 0.2));
        float fres = 0.04 + 0.96 * pow(1.0 - ndv, 4.0);
        vec3 env = vec3(1.0, 0.97, 0.93) * (box1 * 1.6 + box2 * 1.1) + palRoleRim(0.6, u) * 0.4 * smoothstep(0.0, -0.4, rd.y);
        g += env * (0.08 + 0.9 * fres);
        // spectral edges: dispersion fringe right at the silhouette
        float edge = exp(-sd / (px * 2.0 + 0.012));
        vec3 spec = hsv2rgb(vec3(fract(0.55 + 2.2 * sd + 0.15 * u.spectralCentroid), 0.85, 1.0));
        g += spec * edge * disp * (0.5 + 0.9 * u.treble);
        // key-light specular
        vec3 Lk = normalize(vec3(-0.45, 0.6, 0.66));
        float sp = pow(saturate(dot(rd, Lk)), 160.0);
        g += vec3(2.6, 2.45, 2.3) * sp * (1.0 + 0.6 * u.treble);
        // micro-bubbles caught in the glass, twinkling with the treble
        vec2 bq = (p + vec2(drift * 0.9, 0.0)) * 15.0;
        vec2 bc = floor(bq);
        vec2 bh = hash22(mod(bc, 512.0) + 3.0);
        vec2 bd = (bq - bc - 0.3 - 0.4 * bh) / 15.0;
        float br = (0.004 + 0.007 * bh.y);
        float bl = length(bd);
        // a hollow bead: bright rim, a pin glint offset toward the key light
        float bub = smoothstep(px * 1.2, 0.0, abs(bl - br)) * 0.6
                  + exp(-dot(bd - vec2(-0.4, 0.5) * br, bd - vec2(-0.4, 0.5) * br) / (px * px * 0.8));
        bub *= step(0.93, bh.x) * smoothstep(0.0, 0.3, th);
        g += peakWhite(pal6, 0.5) * bub * (0.2 + 1.4 * u.treble * bh.y);
        col = mix(col, g, cover);
    }

    // ---- out-of-focus motes in front ----
    int nMotes = osSteps(4.0, 10.0, detail);
    vec3 m0 = palVisual(0.5, u) * tint;
    vec3 m1 = palVisual(0.9, u) * tint;
    for (int k = 0; k < 10; k++) {
        if (k >= nMotes) break;
        float fk = float(k);
        vec2 h = hash22(vec2(fk * 7.31, 2.7));
        float x = mod(h.x * 5.0 - drift * (2.2 + 1.2 * h.y), 5.0) - 2.5;
        vec2 c = vec2(x, mix(-0.95, 0.95, fract(h.y * 5.7)) + 0.05 * sin(mod(drift * 2.0 + fk, 6.2831853)));
        float r = mix(0.04, 0.13, h.y);
        float dd = length(p - c);
        float disc = smoothstep(r, r - 0.012, dd);
        float ring = smoothstep(r, r - 0.01, dd) * smoothstep(r - 0.035, r - 0.008, dd);
        float b = bandAt(u, fract(h.x * 3.3));
        vec3 mc = mix(m0, m1, h.y);
        col += mc * (disc * 0.05 + ring * 0.06) * (0.4 + 2.0 * b);
    }

    // lens vignette
    float vig = 1.0 - 0.55 * smoothstep(0.6, 1.9, length(p * vec2(0.8, 1.0)));
    return col * vig; // LINEAR HDR — post chain tonemaps
}
