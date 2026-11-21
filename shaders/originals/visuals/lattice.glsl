// SPDX-License-Identifier: AGPL-3.0-only
// Lattice: a flight through an endless braced crystal lattice. Polished struts
// and octahedral nodes run off in every direction and bend with the flight
// path. Nested cymatic shells of light stand around a focus ahead of the
// camera and ripple outward: wherever a strut crosses a shell it swells and
// burns in that shell's prismatic colour, with the spectrum mapped from the
// innermost shell (bass) to the outermost (treble). The inner shells show as
// glass bubbles carrying glowing Chladni figures, warm against cool, and the
// whole set drifts slowly outward. Each beat sends a faint gold shell out from
// the focus and lifts the shells' burn very slightly; the shells swell only
// gently with the level, so the lattice never pumps as a whole.
// The flight runs on a slow, steady clock, and the struts taper away inside a
// small bubble around the camera, so nothing whips past the lens.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 Contour Density: how closely the shells are packed.
// param1 Height: how far the shells swell the struts and how bright they burn.
// param2 Reflection: how polished the struts are.

// The palette read: the visual's own palette with no beat or spectral nudge.
// The vivid tour swaps whole palettes of very different brightness every few
// seconds, which swells the light across the frame, so this visual keeps its
// own colours there (as the calm visuals do); a host's manifest palette still
// replaces them.
vec3 ltPalSteady(float t, VisualUniforms u) { return osPalCalm(t, 31, u); }

const float LA_C = 8.0;
const float LA_FOCUS = 30.0;

vec2 laPath(float z) {
    return vec2(2.6 * sin(z * 0.019) + 1.1 * sin(z * 0.043 + 1.3),
                1.8 * sin(z * 0.015 + 0.6) + 0.8 * sin(z * 0.035 + 2.1));
}

// World to lattice space. The lattice bends with the path and is turned 45
// degrees about the vertical, so the camera flies diagonally through it: it
// stays midway between two floors (y = 0 and y = C) on the line x - z = C/2,
// which passes every column at the same safe distance.
vec3 laQ(vec3 p) {
    vec2 o = p.xy - laPath(p.z);
    return vec3((p.z + o.x) * 0.70710678 + 0.5 * LA_C, o.y + 0.5 * LA_C, (p.z - o.x) * 0.70710678);
}

// Shell coordinate: x = shells out from the focus, k = shell index, f = offset
// from that shell's centre (-0.5..0.5).
vec3 laShell(float r, float sp, float ph) {
    float x = r / sp - ph;
    float k = floor(x + 0.5);
    return vec3(x, k, x - k);
}

// Weights of the three shell hues for shell k: a smooth walk around the
// colour wheel, one third of a turn per shell.
vec3 laHue(float k) {
    vec3 w = 0.5 + 0.5 * cos(k * 2.0943951 - vec3(0.0, 2.0943951, 4.1887902));
    w *= w;
    return w * w * 1.7;
}

float laX(vec2 w) { return (abs(w.x) - abs(w.y)) * 0.70710678; }

// x = distance, y = node weight (0 strut, 1 node). sh is the shell profile at q (1 on
// a shell), which swells the struts, and shN the profile at the nearest node's
// centre, which swells that node evenly; keep scales everything to zero
// near the camera, and grow thickens far struts so they never break into
// sub-pixel dashes.
vec2 laMap(vec3 q, float sh, float shN, float swell, float keep, float grow) {
    vec3 l = q - LA_C * floor(q / LA_C + 0.5);
    float rs = mix(-0.06, 0.085 + swell * sh * 0.08, keep) + grow;
    float ax = min(min(length(l.yz), length(l.xz)), length(l.xy)) - rs;
    // X braces in a few floor squares only: a brace is never nearer than its
    // floor, so it is only looked up close to one.
    if (abs(l.y) < ax) {
        vec2 cell = floor(q.xz / LA_C);
        float hb = hash21(mod(cell, 53.0) * vec2(0.193, 1.913) + mod(floor(q.y / LA_C + 0.5), 61.0) * 1.37);
        if (hb > 0.86) {
            vec2 w = (fract(q.xz / LA_C) - 0.5) * LA_C;
            ax = min(ax, length(vec2(l.y, laX(w))) - rs * 0.6);
        }
    }
    vec3 a = abs(l);
    float nd = (a.x + a.y + a.z - mix(-0.2, 0.55 + swell * shN * 0.2, keep) - grow * 2.0) * 0.57735;
    float dn = osSmin(nd, ax, 0.2);
    return vec2(dn, saturate((ax - nd) * 5.0 + 0.5));
}

vec3 laNormal(vec3 q, float sh, float shN, float swell, float keep, float grow) {
    vec2 e = vec2(0.003, -0.003);
    vec3 n = e.xyy * laMap(q + e.xyy, sh, shN, swell, keep, grow).x + e.yyx * laMap(q + e.yyx, sh, shN, swell, keep, grow).x
           + e.yxy * laMap(q + e.yxy, sh, shN, swell, keep, grow).x + e.xxx * laMap(q + e.xxx, sh, shN, swell, keep, grow).x;
    return n / max(length(n), 1e-6);
}

// The beat shell: radius grows from the focus, brightness decays; the previous
// beat's shell is kept so nothing pops when the beat rolls over.
float laBeat(float r, vec4 bt) {
    float x0 = r - bt.x;
    float x1 = r - bt.z;
    return exp(-x0 * x0 * 0.3) * bt.y + exp(-x1 * x1 * 0.3) * bt.w;
}

// Cymatic figure on a shell: a standing wave on the sphere whose nodal lines
// glow. d is the unit direction from the focus; n sets the mode.
float laChladni(vec3 d, float n, float tw) {
    float w = cos(n * 3.14159 * d.x + tw) * cos(n * 3.14159 * d.y - tw * 0.7) * cos(n * 3.14159 * d.z);
    return exp(-w * w * 90.0);
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float sp = mix(12.5, 6.0, u.param0);
    float swell = mix(0.2, 1.6, u.param1);
    // the shells burn a little hotter just after each beat
    float bp = saturate(u.beatPhase);
    float bSw = smoothstep(0.0, 0.3, bp) * (1.0 - bp) * (1.0 - bp) * 2.0;
    float burn = mix(0.5, 1.6, u.param1) * (0.98 + 0.04 * bSw);
    float polish = mix(0.15, 1.0, u.param2);
    float tm = mod(u.time, 600.0);
    // The shells drift steadily outward; the phase wraps at a whole multiple
    // of three shells (30 at tm = 600), so hues never jump.
    float bAge = bp;
    float ph = tm * 0.05;

    // A slow, steady flight: fast motion of the bright struts would flash.
    float z = mod(u.time, 36000.0) * 0.32;
    float rush = 0.25;
    float lull = 0.1;
    vec3 ro = vec3(laPath(z), z);
    vec3 ta = vec3(laPath(z + 8.0), z + 8.0);
    vec2 bend = laPath(z + 16.0) - 2.0 * laPath(z + 8.0) + laPath(z);
    float roll = -0.06 * bend.x + 0.1 * sin(mod(u.time, 628.31853) * 0.05) + 0.12 * sin(tm * 0.031);
    float fov = 1.05 - 0.16 * rush + 0.08 * lull;
    vec3 rd = osCamera(ro, ta, roll, fov, p);

    // Spectrum by shell radius: inner shells bass, middle mids, outer treble.
    float sens = 0.6 + 0.4 * u.sensitivity;
    float aB = 0.45 + 0.6 * mix(u.level, bandRange(u, 0, 10), 0.1) * sens;
    float aM = 0.45 + 0.6 * mix(u.level * 0.9, bandRange(u, 10, 32), 0.1) * sens;
    float aT = 0.45 + 0.65 * mix(u.level * 0.8, bandRange(u, 32, 64), 0.1) * sens;

    // Three shell hues: a warm one against two cool ones, each swaying within
    // its family. (The green
    // stretch of a palette is skipped; the host greys it.)
    vec3 hA = ltPalSteady(fract(0.03 + 0.05 * sin(tm * 0.05) ), u);
    vec3 hB = ltPalSteady(0.56 + 0.05 * sin(tm * 0.037 + 1.0), u);
    vec3 hC = ltPalSteady(0.86 + 0.06 * sin(tm * 0.043 + 2.0) , u);
    // The beat shell burns a faint gold, the warm counterpoint to the shells.
    vec3 peak = mix(ltPalSteady(0.62, u), vec3(1.8, 0.7, 0.22), 0.75);
    // The cymatic source at the focus: a white-hot core with a coloured corona.
    float pulse = 0.95 + 0.08 * bSw;
    vec3 coreCol = mix(ltPalSteady(fract(0.86 + tm * 0.013), u), vec3(1.0, 0.9, 0.95), 0.15) * pulse;
    float bAmt = 0.07;
    // the gold shell leaves the focus at full heat and cools as it races out,
    // so the beat lands when it fires, not when the shell reaches the camera
    vec4 bt = vec4(2.0 + 32.0 * bAge, exp(-bAge * 4.5) * bAmt, 34.0 + 32.0 * bAge, exp(-(bAge + 1.0) * 4.5) * bAmt);
    // Chladni mode drifts slowly; mids twist the figure.
    float tw = tm * 0.12 + 0.3 * aM;

    vec3 fq = laQ(vec3(laPath(z + LA_FOCUS), z + LA_FOCUS));
    vec3 qc = laQ(ro);
    float tmax = 60.0;
    float t = 0.05;
    float hit = -1.0;
    float part = 0.0;
    float keepHit = 1.0;
    vec3 gw = vec3(0.0);
    vec3 mem = vec3(0.0);
    float gBeat = 0.0;
    float gCore = 0.0;
    float px = 1.6 / (u.resolution.y * fov);
    vec3 q0 = laQ(ro + rd * t);
    float rPrev = length(q0 - fq);
    float xPrev = rPrev / sp - ph;
    float tPrev = t;
    vec3 qPrev = q0;
    int steps = osSteps(28.0, 46.0, detail);
    for (int i = 0; i < 46; i++) {
        if (i >= steps) break;
        vec3 q = laQ(ro + rd * t);
        float r = length(q - fq);
        vec3 s = laShell(r, sp, ph);
        // Shell membranes: count each crossing of a shell centre once, brighter
        // where the ray grazes the sphere, so every shell reads as a bubble.
        float dr = abs(r - rPrev);
        float graze = min((t - tPrev) / max(dr, 1e-3), 7.0);
        if (floor(s.x) != floor(xPrev)) {
            float kk = max(floor(s.x), floor(xPrev));
            float R = (kk + ph) * sp;
            // Interpolate to the crossing so the figure is drawn sharply.
            vec3 qx = mix(qPrev, q, saturate((R - rPrev) / (r - rPrev + (r > rPrev ? 1e-4 : -1e-4))));
            vec3 d = qx - fq;
            d /= max(length(d), 1e-3);
            float am = R < 22.0 ? mix(aB, aM, R / 22.0) : aM;
            float fade = (1.0 - smoothstep(14.0, 27.0, R)) * smoothstep(1.0, 4.0, R) * smoothstep(3.0, 9.0, t);
            float fig = 0.035 + 1.5 * laChladni(d, 2.0 + mod(kk, 3.0), tw + kk);
            mem += laHue(kk) * (fig * graze * sqrt(graze) * am * fade * 0.03);
        }
        // The beat shell's membrane, in gold.
        if ((r - bt.x) * (rPrev - bt.x) < 0.0) {
            gBeat += graze * bt.y * (1.0 - smoothstep(18.0, 30.0, bt.x)) * smoothstep(3.0, 9.0, t) * 0.6;
        }
        rPrev = r;
        qPrev = q;
        xPrev = s.x;
        tPrev = t;
        float bw = 140.0 / (1.0 + t * 0.06);
        float shp = exp(-s.z * s.z * bw);
        vec3 sN = laShell(length(LA_C * floor(q / LA_C + 0.5) - fq), sp, ph);
        float shN = exp(-sN.z * sN.z * bw);
        float keep = smoothstep(2.0, 7.0, length(q - qc));
        float grow = t * px;
        vec2 h = laMap(q, shp, shN, swell, keep, grow);
        float step = max(h.x * 0.9, 0.04);
        float ms = min(step, 1.5);
        // Halo around lit struts and the core's light.
        float halo = exp(-h.x * 8.0);
        float lit = keep * exp(-t * 0.045) * ms;
        float a = r < 22.0 ? mix(aB, aM, r / 22.0) : mix(aM, aT, saturate((r - 22.0) / 30.0));
        gw += laHue(s.y) * (shp * a * halo * 0.06 * (1.0 - smoothstep(12.0, 38.0, t)) * lit);
        gBeat += laBeat(r, bt) * halo * lit * 0.5;
        gCore += (exp(-r * r * 0.02) * 0.03 + exp(-r * 1.1) * 0.35) * ms;
        if (h.x < 0.0025 * (1.0 + t)) { hit = t; part = h.y; keepHit = keep; break; }
        t += step;
        if (t > tmax) break;
    }
    vec3 glow = (hA * (gw.x + mem.x) + hB * (gw.y + mem.y) + hC * (gw.z + mem.z)) * burn + peak * (gBeat * 0.1) + coreCol * gCore;

    vec3 fogCol = ltPalSteady(0.86, u) * 0.004 + vec3(0.0002, 0.0002, 0.0005);
    vec3 col = fogCol;
    if (hit > 0.0) {
        vec3 pos = ro + rd * hit;
        vec3 q = laQ(pos);
        float r = length(q - fq);
        vec3 s = laShell(r, sp, ph);
        float bw = 140.0 / (1.0 + hit * 0.06);
        float shp = exp(-s.z * s.z * bw);
        float rN = length(LA_C * floor(q / LA_C + 0.5) - fq);
        vec3 sN = laShell(rN, sp, ph);
        float shN = exp(-sN.z * sN.z * bw);
        float grow = hit * px;
        vec3 n = laNormal(q, shp, shN, swell, keepHit, grow);
        float a = r < 22.0 ? mix(aB, aM, r / 22.0) : mix(aM, aT, saturate((r - 22.0) / 30.0));
        float near = keepHit;
        float sh = shp * a * near;
        vec3 wk = laHue(s.y);
        vec3 sc = (hA * wk.x + hB * wk.y + hC * wk.z) / max(wk.x + wk.y + wk.z, 1e-3);
        // Neighbouring shells light the strut from either side.
        vec3 wi = laHue(s.y - 1.0);
        vec3 wo = laHue(s.y + 1.0);
        vec3 scIn = (hA * wi.x + hB * wi.y + hC * wi.z) / max(wi.x + wi.y + wi.z, 1e-3);
        vec3 scOut = (hA * wo.x + hB * wo.y + hC * wo.z) / max(wo.x + wo.y + wo.z, 1e-3);
        // Shade in lattice space, where the normal lives.
        vec3 rq = laQ(pos + rd * 0.05) - q;
        rq /= max(length(rq), 1e-6);
        float ndv = saturate(dot(n, -rq));
        float fres = pow(1.0 - ndv, 4.0);
        vec3 refl = reflect(rq, n);
        vec3 toCore = fq - q;
        toCore /= max(length(toCore), 1e-6);
        float spec = pow(saturate(dot(refl, toCore)), 40.0);
        // Black chrome: the struts mirror the shells inward and outward of them.
        vec3 env = mix(scIn, scOut, 0.5 + 0.5 * refl.z) * 0.06 + sc * exp(-s.z * s.z * 10.0) * 0.3;
        float head = 1.0 / (1.0 + hit * hit * 0.01);
        vec3 alb = vec3(0.012, 0.012, 0.016);
        // Fine contour rings run along every strut between the shells, fading
        // out with distance before they would alias.
        float ring = pow(0.5 + 0.5 * cos(6.2831853 * s.x * 4.0), 16.0) * 0.1 * saturate(1.5 - hit * 0.04);
        // Far away the burning bands give way to a steady tint, so distant
        // struts read as whole lines instead of short lit dashes.
        float farF = 1.0 - smoothstep(12.0, 38.0, hit);
        // The burn: coloured edges with a white-hot middle where the shell is densest.
        vec3 em = sc * (sh * 2.6 * burn * farF + ring * a * near + (1.0 - farF) * 0.1 * a)
                + vec3(1.0, 0.92, 0.85) * (sh * sh * sh * 0.6 * burn * farF);
        em += peak * laBeat(r, bt) * near * 1.2;
        // Crystal nodes: a white-hot core when the shell crosses them.
        // The node takes its shell from its centre, so it lights evenly.
        vec3 wn = laHue(sN.y);
        vec3 scN = (hA * wn.x + hB * wn.y + hC * wn.z) / max(wn.x + wn.y + wn.z, 1e-3);
        float shn = shN * a * near * farF;
        vec3 emN = scN * (shn * 3.8 * burn + (1.0 - farF) * 0.1 * a + 0.02) + vec3(1.0, 0.95, 0.9) * shn * 0.9 * burn
                 + peak * laBeat(rN, bt) * near * 1.4;
        em = mix(em, emN, part);
        // Lit tubes read round: brighter toward the silhouette.
        em *= 0.65 + 0.9 * fres;
        col = alb * (ndv * head * 0.3 + 0.01) + env * (0.03 + fres) * polish * (0.5 + 0.5 * head) + em;
        // The core lights the struts that face it, strongest close by, so the
        // lattice stands lit around the source.
        col += coreCol * (saturate(dot(n, toCore)) * 0.5 / (1.0 + r * r * 0.03));
        // The core glints in every polished strut that faces it.
        col += coreCol * spec * (0.3 + 0.9 * polish) * 0.8 * head * farF;
    } else {
        hit = tmax;
    }
    float fog = 1.0 - exp(-hit * 0.05);
    col = mix(col, fogCol, fog);
    col += glow;
    return max(col, vec3(0.0));
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
