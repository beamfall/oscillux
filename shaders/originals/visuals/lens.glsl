// SPDX-License-Identifier: AGPL-3.0-only
// Lens.
// Sound as mass. Three dark bodies, weighed by the smoothed level, hang in
// front of a bright, deep field: a saturated emission nebula cut by black dust
// lanes, a dense star field and a scatter of small spiral galaxies. Each body
// bends that light with an exact thin-lens point-mass deflection, so stars and
// galaxies smear into arcs and Einstein rings, and farther layers bend more
// than nearer ones. Each body shows its black shadow and a thin photon ring.
// The field drifts past at a crawl behind the lenses and the bodies wander
// at a crawl with dimmer, slowly turning discs of soft streaks, so the arcs creep,
// and the view sways in a slow fixed roll. A slow cycle draws the bodies
// into an unhurried inspiral that merges them into one larger lens, then
// releases them; the level barely nudges it, so swells never jolt them. Each beat sends a faint gravitational ripple across the field; the
// level only breathes the masses, nebula, stars and rings a little, so the
// lensed field never lurches or flickers with the music.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 = Gravity ; param1 = Merge Eagerness ; param2 = Background Richness

// The palette read: the visual's own palette (1) with no beat or spectral
// nudge and no palette tour, so the host's vivid tour never swells the light;
// a host's manifest palette still replaces it. The fog tint is rebuilt on it.
vec3 lnPalSteady(float t, VisualUniforms u) { return osPalCalm(t, 1, u); }
vec3 lnPalSteadyFog(float t, VisualUniforms u) {
    vec3 c = lnPalSteady(t, u);
    return mix(vec3(luma(c) * 0.62), c, 0.42);
}

float lnsFbm(vec2 p, int n) {
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

// Gaussian stars, one per cell. foot is the pixel's footprint in source units:
// where the lens squeezes the field, each star widens and dims (same energy),
// so the demagnified zones never sparkle.
float lnsStars(vec2 s, float cells, float seed, float foot, float tw) {
    vec2 g = s * cells + seed;
    vec2 id = floor(g);
    vec2 d = fract(g) - 0.5 - (hash22(id + seed * 1.3) - 0.5) * 0.5;
    float h = hash21(id + 0.37 * seed);
    float sig0 = 0.055;
    float sig = max(sig0, foot * cells * 0.5);
    float amp = (sig0 * sig0) / (sig * sig);
    float h2 = h * h * h;
    float b = (0.006 + 5.0 * h2 * h2 * h2 * h2) * step(0.45, hash21(id + 4.3));
    b *= 1.0 + tw * (hash21(id + 11.0) - 0.35);
    return b * amp * exp(-dot(d, d) / (2.0 * sig * sig));
}

// Small spiral galaxies, about half the cells: an inclined disc with two arms
// and a hot core. The lens stretches them into the classic arcs.
vec3 lnsGalaxies(vec2 s, float foot, VisualUniforms u) {
    const float cells = 2.6;
    vec2 g = s * cells + 0.5;
    vec2 id = floor(g);
    vec2 h = hash22(id + 17.0);
    vec2 d = fract(g) - 0.5 - (hash22(id + 3.7) - 0.5) * 0.35;
    // Fade before the cell edge so a wide disc is never clipped square.
    float win = smoothstep(0.5, 0.3, max(abs(fract(g).x - 0.5), abs(fract(g).y - 0.5)));
    d = rot2(h.y * 6.2831853) * d;
    d.y *= 1.3 + 1.1 * h.x;
    float sz = 0.06 + 0.06 * hash21(id + 9.1);
    float sig = max(sz, foot * cells * 0.6);
    float keep = (sz * sz) / (sig * sig);
    float r2 = dot(d, d) / (sig * sig);
    float r = sqrt(r2);
    float arms = 0.55 + 0.45 * sin(2.0 * atan2_(d.y, d.x) - 3.0 * log(r + 0.25) * 1.6);
    float disc = exp(-r2 * 0.7) * mix(0.55, arms, smoothstep(0.3, 1.2, r));
    float core = exp(-r2 * 5.0);
    vec3 c = lnPalSteady(fract(h.y * 2.7 + 0.15), u);
    float on = smoothstep(0.58, 0.64, h.x);
    return on * keep * win * (c * disc * 2.2 + vec3(1.0, 0.93, 0.84) * core * 3.0);
}

// The emission nebula: warped fbm clouds over black space, two palette hues,
// a brighter ionisation front along each cloud's edge, hot knots, and broad
// dust lanes that cut it to black.
vec3 lnsNebula(vec2 s, VisualUniforms u, int oct, float rich, float glow, float foot) {
    vec2 w = vec2(lnsFbm(s * 0.55, 2), lnsFbm(s * 0.55 + vec2(4.1, 2.3), 2));
    vec2 q = s * 1.1 + 1.8 * w;
    float n = lnsFbm(q, oct);
    float cloud = saturate((n - 0.47) * 3.2);
    cloud *= cloud;
    // Hue walks along the palette (never an RGB mix of opposite hues, which
    // greys out), squared so the emission is deep and saturated.
    float th = mix(0.04 + 0.25 * w.x, 0.62 + 0.30 * w.y, smoothstep(0.42, 0.58, w.x + 0.5 * (n - 0.5)));
    vec3 c = lnPalSteady(th, u);
    c *= c;
    vec3 cF = lnPalSteady(th + 0.04, u);
    cF = mix(cF * cF, vec3(1.0, 0.92, 0.85), 0.12);
    float gain = (0.55 + 0.45 * rich) * (0.8 + 0.5 * glow);
    // Inner structure: a finer field gives each cloud pillars and knots.
    float fine = lnsFbm(q * 2.3 + w * 2.0 + vec2(3.0, 8.0), max(oct - 1, 2));
    vec3 col = c * (0.05 * cloud + 0.36 * cloud * cloud) * mix(0.06, 2.0, saturate((fine - 0.34) * 3.0)) * gain;
    // Filaments: thin bright ridges of the fine field run through each cloud.
    float fil = 1.0 - abs(2.0 * fine - 1.0);
    fil *= fil;
    fil *= fil;
    col += mix(c, cF, 0.5) * fil * fil * cloud * 0.55 * gain;
    // Ionisation front: a thin bright skin where each cloud meets the void.
    float front = cloud * (1.0 - cloud);
    col += cF * front * (0.08 + 1.1 * front) * gain;
    col += mix(c, vec3(1.0, 0.9, 0.8), 0.25) * pow(smoothstep(0.70, 0.95, n), 2.0) * 1.3 * rich;
    // Broad dust: large dark lanes with soft, wispy edges.
    float dust = lnsFbm(s * 1.4 + 1.3 * w + vec2(7.0, 1.0), max(oct - 1, 2));
    col *= 1.0 - 0.96 * smoothstep(0.50, 0.64, dust);
    // Where the lens squeezes the field (inside the Einstein rings) the fine
    // structure would alias; it sinks into shadow instead.
    col *= 1.0 - 0.85 * smoothstep(0.012, 0.05, foot);
    // Faint cold space so nothing reads as flat black.
    col += lnPalSteady(0.75, u) * 0.003;
    return col;
}

// A thin accretion disc, seen in its own plane. b is the deprojected position
// in units of the body's Einstein radius and fr the pixel footprint along the
// radius in the same units. The disc runs in lanes; each lane turns rigidly at
// a whole number of turns per 1200 s (so the time wrap is seamless), inner
// lanes faster, Kepler-like but unhurried, and the lane gaps hide the seams
// between them; the lane streaks are soft so the turning disc never shimmers.
// The side turning toward the viewer is beamed brighter and bluer.
// Sparse bright stars with six-point diffraction spikes (three axes, the
// spike width and energy kept under the lens footprint so they never alias).
vec3 lnsSpiked(vec2 s, float foot, float treble, VisualUniforms u) {
    const float cells = 6.0;
    vec2 g = s * cells + 0.37;
    vec2 id = floor(g);
    float h = hash21(id + 23.0);
    if (h < 0.86) return vec3(0.0);
    vec2 d = fract(g) - 0.5 - (hash22(id + 8.1) - 0.5) * 0.2;
    float edge = smoothstep(0.5, 0.36, max(abs(fract(g).x - 0.5), abs(fract(g).y - 0.5)));
    float w0 = 0.006;
    float w = max(w0, foot * cells * 0.6);
    float amp = w0 / w;
    float sp = 0.0;
    for (int k = 0; k < 3; ++k) {
        float an = 0.5236 + 1.0471976 * float(k);
        vec2 e = vec2(cos(an), sin(an));
        float al = dot(d, e);
        float pe = dot(d, vec2(-e.y, e.x));
        sp += exp(-pe * pe / (w * w)) * exp(-abs(al) * 14.0);
    }
    float core = exp(-dot(d, d) / (w * w * 4.0)) * 6.0 + exp(-dot(d, d) * 900.0) * 0.6;
    float b = (0.2 + (h - 0.86) * 4.5) * (0.9 + 0.3 * treble);
    vec3 tint = mix(vec3(1.0, 0.96, 0.92), lnPalSteady(fract(h * 7.3), u), 0.35);
    return tint * b * edge * (core + 0.9 * sp) * amp;
}

vec3 lnsDisc(vec2 b, float fr, float tt, float seed, vec3 hot, vec3 warm, float hi) {
    const float rIn = 0.50, rOut = 1.22, lanes = 13.0;
    float rd = length(b);
    float x = (rd - rIn) / (rOut - rIn);
    if (x <= 0.0 || x >= 1.0) return vec3(0.0);
    float frx = fr / (rOut - rIn);
    float prof = smoothstep(0.0, 0.04 + frx, x) * pow(1.0 - x, 1.4) / (0.22 + 1.6 * x);
    float ln = x * lanes;
    float k = floor(ln);
    float f = ln - k;
    float rk = rIn + (k + 0.5) / lanes * (rOut - rIn);
    float turns = floor(16.0 * pow(rIn / rk, 1.5) + 0.5);
    vec2 q = rot2(turns * 0.0052359878 * tt + seed) * b;
    float n = vnoise(q * 6.0 + vec2(seed * 3.1 + k * 1.7, k * 0.9));
    if (hi > 0.5) n = 0.62 * n + 0.38 * vnoise(q * 15.0 + vec2(k * 2.3, seed));
    float laneC = saturate(1.6 - 2.2 * frx * lanes);
    float gap = mix(1.0, 0.55 + 0.45 * smoothstep(0.0, 0.22, f) * smoothstep(1.0, 0.78, f), laneC);
    float streak = mix(0.75, 0.6 + 0.7 * n * n, mix(0.5, 1.0, laneC));
    float dop = 1.0 - 0.45 * b.x / max(rd, 1e-3);
    vec3 c = mix(warm, hot, saturate(1.15 - 1.6 * x));
    c = mix(c, vec3(0.80, 0.90, 1.15) * dot(c, vec3(0.4)), 0.7 * saturate(dop - 1.0));
    c = mix(c, warm * vec3(1.0, 0.45, 0.35), 0.8 * saturate(1.0 - dop));
    return c * prof * gap * streak * dop * dop * dop;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    float detail = osDetail(u);
    int oct = detail > 0.5 ? 5 : 3;
    float hi = step(0.5, detail);

    float grav = mix(0.55, 1.60, u.param0);
    float eager = mix(-0.06, 0.10, u.param1);
    float rich = mix(0.2, 1.0, u.param2);

    float mid = saturate(u.mid);
    float treble = saturate(u.treble);
    float level = saturate(u.level);
    float tt = mod(u.time, 1200.0);

    // The field drifts steadily behind the lenses; slow eased roll.
    float dist = u.time * 0.05;
    p = rot2(0.02 * sin(tt * 0.0418879)) * p;
    vec2 head = vec2(0.96, 0.28);

    // Sustained energy inspirals the bodies; a slow cycle (7 turns per 1200 s)
    // sets its pace; the level only nudges it, so a swell never throws the
    // bodies inward in a lurch.
    float sustain = (0.5 + 0.5 * sin(tt * 0.0366519)) * (0.97 + 0.03 * level);
    float merge = smoothstep(0.55 - eager, 0.95 - eager, sustain);
    float orbit = 1.0 - 0.93 * merge;
    float ph = tt * 0.0104720;
    vec2 c0 = orbit * vec2(0.78 * sin(ph * 0.9 + 0.4), 0.34 * sin(ph * 1.3 + 1.1));
    vec2 c1 = orbit * vec2(0.92 * sin(ph * 0.7 + 2.6), 0.42 * sin(ph * 1.1 + 4.0));
    vec2 c2 = orbit * vec2(0.70 * sin(ph * 1.2 + 4.4), 0.46 * sin(ph * 0.8 + 2.2));
    // Einstein radii: the level, mids and treble give each body its mass
    // (shape, not camera).
    float t0 = grav * 0.30 * (0.97 + 0.03 * level);
    float t1 = grav * 0.23 * (0.97 + 0.03 * level);
    float t2 = grav * 0.17 * (0.97 + 0.03 * level);

    // Deflection and its analytic Jacobian; shadows and photon rings.
    vec2 a = vec2(0.0);
    vec3 jac = vec3(0.0); // (dax/dx, day/dy, dax/dy)
    float sd = 10.0; // signed distance to the union of the shadows
    float bw = 0.0, bs = 0.0;
    vec2 cm = vec2(0.0);
    float m2 = 0.0;
    float bp = saturate(u.beatPhase);
    float bell = sin(3.14159265 * bp);
    bell *= bell;
    for (int i = 0; i < 3; ++i) {
        vec2 c = i == 0 ? c0 : i == 1 ? c1 : c2;
        float te = i == 0 ? t0 : i == 1 ? t1 : t2;
        vec2 d = p - c;
        float r2 = dot(d, d) + 1e-4;
        float k = te * te / r2;
        a += k * d;
        jac += k / r2 * vec3(r2 - 2.0 * d.x * d.x, r2 - 2.0 * d.y * d.y, -2.0 * d.x * d.y);
        float r = sqrt(r2);
        float sdi = r - 0.34 * te;
        // Close passes blend the shadows like liquid, under one outline.
        sd = osSmin(sd, sdi, 0.04);
        // Each ring is brighter on its approaching side, which turns slowly.
        float sp = tt * (0.0523599 + 0.0130900 * float(i)) + 2.1 * float(i);
        float wi = exp(-max(sdi, 0.0) * 30.0);
        bs += wi * (0.45 + 0.55 * dot(d / r, vec2(cos(sp), sin(sp))));
        bw += wi;
        cm += te * te * c;
        m2 += te * te;
    }
    // As the bodies merge their shadows fuse into one larger body.
    cm /= max(m2, 1e-4);
    float tm = sqrt(m2);
    float fuse = smoothstep(0.6, 0.98, merge);
    sd = mix(sd, osSmin(sd, length(p - cm) - 0.34 * tm, 0.04), fuse);
    float beam = bs / max(bw, 1e-4);
    float shadow = smoothstep(-0.003, 0.004, sd);
    // A thin photon ring hugging the shadow, plus a soft glow just outside.
    float xr = (sd - 0.006) / 0.005;
    float ring = (exp(-xr * xr) + 0.12 * exp(-abs(sd) / 0.03)) * (0.35 + beam * beam);
    // Source footprint of one pixel: pixel size times the RMS stretch.
    float px = 2.0 / max(u.resolution.y, 1.0);
    float j00 = 1.0 - jac.x, j11 = 1.0 - jac.y, j01 = -jac.z;
    float foot = px * sqrt(0.5 * (j00 * j00 + j11 * j11 + 2.0 * j01 * j01));
    foot = min(foot, 0.5);

    // Gravitational waves: every beat one body (the merged one, once fused,
    // and harder) sends a ripple across the field, easing in and out within
    // the beat. It shifts the background
    // radially and slightly magnifies and demagnifies it as it passes.
    float bsel = mod(floor(u.beatCount), 3.0);
    vec2 gc = mix(bsel < 0.5 ? c0 : bsel < 1.5 ? c1 : c2, cm, fuse);
    vec2 gd = p - gc;
    float gr = length(gd) + 1e-4;
    float gx = (gr - 0.12 - 1.9 * bp) / 0.07;
    float genv = bell * (0.02 + 0.01 * level) * (1.0 + 0.5 * fuse);
    float gw = genv * exp(-gx * gx);
    a += gd / gr * (0.006 * gw * sin(gx * 2.6));
    float gmag = 1.0 + 0.08 * gw * cos(gx * 2.6);

    float glow = 0.4 + 0.15 * level;
    // Nebula (nearest of the sources, bends least).
    vec2 sN = p - a * 0.78 + head * dist * 0.045;
    int octN = foot > 0.02 ? 2 : oct;
    vec3 col = lnsNebula(sN, u, octN, rich, glow, foot);

    // Stars and galaxies, farther, bend more. Where the bending is strong each
    // channel of the star field bends a touch differently, a chromatic fringe
    // on the arcs; far from the bodies the stars stay clean.
    float disp = 0.035 * hi * smoothstep(0.10, 0.45, length(a));
    vec3 kc = vec3(1.0 - disp, 1.0, 1.0 + disp);
    vec3 starTint = mix(vec3(1.0), lnPalSteady(0.55, u), 0.25);
    vec2 dS = head * dist * 0.075;
    vec2 dG = head * dist * 0.060 + vec2(3.1, 7.7);
    float twk = 0.1;
    vec3 st, gxy;
    st.g = lnsStars(p - a * 0.92 * kc.y + dS, 38.0, 1.0, foot, twk);
    gxy = lnsGalaxies(p - a + dG, foot, u);
    if (hi > 0.5) {
        st.r = lnsStars(p - a * 0.92 * kc.x + dS, 38.0, 1.0, foot, twk);
        st.b = lnsStars(p - a * 0.92 * kc.z + dS, 38.0, 1.0, foot, twk);
        st += lnsStars(p - a * 0.95 + dS * 0.8, 21.0, 5.0, foot, twk) * 0.9;
    } else {
        st.r = st.g;
        st.b = st.g;
    }
    col += st * starTint * (1.0 + 0.1 * level) * (0.5 + 0.5 * rich);
    col += gxy * (0.6 + 0.4 * rich);
    // A few bright foreground stars with six-point diffraction spikes; they
    // are lensed with the field, so near a body the spikes bend into arcs.
    col += lnsSpiked(p - a * 0.9 + dS * 1.15, foot, 0.4 + 0.1 * level, u) * (0.6 + 0.4 * rich);
    col *= gmag;

    // The bodies: black shadows rimmed by a thin photon ring.
    col *= shadow;
    vec3 ringCol = mix(lnPalSteady(0.30, u), vec3(1.0, 0.92, 0.8), 0.45);
    col += ringCol * ring * (0.7 + 0.2 * level + 0.05 * bell);

    // Accretion discs, nearly edge on. The near half crosses in front of the
    // shadow; the far half is hidden behind it, but its light, bent over the
    // top and under the bottom of the shadow, wraps it as a halo. As the bodies
    // fuse, their discs settle into one disc around the merged body, which
    // flares as it forms.
    vec3 hotC = mix(lnPalSteady(0.25, u), vec3(1.0, 0.95, 0.85), 0.45);
    vec3 warmC = lnPalSteady(0.06, u);
    float flare = 0.5 * fuse * (1.0 - fuse) + 0.2 * fuse;
    vec3 discs = vec3(0.0);
    for (int i = 0; i < 3; ++i) {
        float fi = float(i);
        vec2 c = mix(i == 0 ? c0 : i == 1 ? c1 : c2, cm, fuse);
        float te = mix(i == 0 ? t0 : i == 1 ? t1 : t2, tm, fuse);
        float ci = mix(0.17 + 0.05 * fi, 0.19, fuse);
        float psi = mix(0.22 - 0.31 * fi + 0.05 * sin(tt * 0.0157080 + fi), 0.08, fuse);
        float gain = 1.0 * (0.9 + 0.1 * level) * mix(1.0, 0.3333, fuse) * (1.0 + 1.6 * flare);
        vec2 dl = rot2(-psi) * (p - c) / te;
        dl.y = -dl.y; // the image's y runs down; the far side is up on screen
        float rho = length(dl) + 1e-4;
        float pxe = px / te;
        float seed = fi * 1.7;
        // Direct image.
        vec2 b = vec2(dl.x, dl.y / ci);
        float rb = length(b) + 1e-4;
        float fr = pxe * length(vec2(b.x, b.y / ci)) / rb;
        float behind = step(0.0, b.y) * smoothstep(0.34, 0.34 + 1.5 * pxe, rho);
        float front = 1.0 - step(0.0, b.y);
        vec3 dc = lnsDisc(b, fr, tt, seed, hotC, warmC, hi) * (front + behind);
        // Halo: the far side over the top, a thinner underside image below.
        vec2 dir = dl / rho;
        float wh = 0.30 * pow(max(dir.y, 0.0), 0.8) + 0.08 * max(-dir.y, 0.0) + 0.05;
        float sh = (rho - 0.352) / wh;
        vec3 hc = vec3(0.0);
        if (sh > 0.0 && sh < 1.0) {
            vec2 bh = dir * (0.50 + sh * 0.72);
            hc = lnsDisc(bh, pxe * 0.72 / wh, tt, seed, hotC, warmC, hi);
            hc *= mix(0.5, 1.15, saturate(0.5 + 0.5 * dir.y));
        }
        // Soft corona of scattered disc light around the body.
        float cor = exp(-dot(b, b) * 1.6) * smoothstep(0.34, 0.6, rho);
        vec3 corona = hotC * cor * 0.05 * (1.0 - 0.35 * dl.x / rho);
        discs += (dc + hc + corona) * gain;
    }
    col += discs;

    // Gentle lens falloff.
    col *= 1.0 - 0.25 * smoothstep(0.9, 2.1, length(p));
    return col; // LINEAR HDR
}
