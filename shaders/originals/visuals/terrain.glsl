// SPDX-License-Identifier: AGPL-3.0-only
// Terrain.
// A low survey flight down a canyon of glowing columns toward an eclipsed
// sun. The ground is a grid of square pillars: smooth hills rise into canyon
// walls on both sides and the spectrum lifts the pillars by their distance
// from the flight line, bass in the valley floor and treble on the high
// walls. Pillar tops burn like embers by height and level. On every beat the
// craft sends a laser sheet ahead: it cuts one bright profile line through
// the whole canyon as it runs out, and the contours it has crossed glow cool
// behind it. The sun hangs eclipsed at the end of the valley; its corona and
// the rays through the haze reach out by the spectrum round its rim, bass at
// the crown and treble down the flanks. A slow swell rolls through the walls
// every four beats and the embers turn toward the palette's third colour as a
// build gathers speed. The camera follows the shared speed profile and banks
// into the curves; audio drives light and shape only.
// param0 = Flight Speed ; param1 = Relief ; param2 = Glow

const float TR_MOON = 0.085; // angular radius of the eclipsing moon

// valley centre line
float trPath(float z) { return 9.0 * sin(z * 0.019) + 4.0 * sin(z * 0.043 + 1.7); }

// Spectrum read once per frame at sixteen stops and blended locally: a band
// read per grid step cost far more than the whole blend.
float trSpec(float x, vec4 sa, vec4 sb, vec4 sc, vec4 sd) {
    float k = saturate(x) * 15.0;
    vec4 i0 = vec4(0.0, 1.0, 2.0, 3.0);
    return dot(max(1.0 - abs(vec4(k) - i0), 0.0), sa) + dot(max(1.0 - abs(vec4(k) - i0 - 4.0), 0.0), sb)
         + dot(max(1.0 - abs(vec4(k) - i0 - 8.0), 0.0), sc) + dot(max(1.0 - abs(vec4(k) - i0 - 12.0), 0.0), sd);
}

// Pillar height for cell c, and its spectrum level in s. tb is the beat clock.
float trHeight(vec2 c, vec4 sa, vec4 sb, vec4 sc, vec4 sd, float tb, float relief, out float s) {
    float dx = abs(c.x + 0.5 - trPath(c.y + 0.5));
    float hills = 2.6 + 1.5 * sin(c.x * 0.11 + 1.3 * sin(c.y * 0.045))
                + 1.1 * sin(c.y * 0.083 + c.x * 0.061) + 0.6 * sin((c.x - c.y) * 0.21);
    float wall = smoothstep(3.5, 15.0, dx);
    float jit = hash21(c);
    s = trSpec(dx / 22.0 + 0.04 * jit, sa, sb, sc, sd);
    float row = 0.65 + 0.35 * sin(c.y * 0.55 + c.x * 0.17);
    // the swell: a long diagonal wave rolling outward through the walls
    float sw = 0.5 + 0.5 * sin(c.y * 0.19 + dx * 0.23 - tb * 1.5708);
    float h = mix(0.3 + 0.22 * sw, (hills * 1.4 + 2.0 + 1.6 * sw * sw) * relief, wall) + 0.3 * jit;
    return h + s * s * row * mix(2.4, 4.0, wall) * relief;
}

// Sky: deep teal-blue overhead, a warm sunset band at the horizon, and thin
// cloud streaks lit hot toward the sun and cool away from it.
vec3 trSky(vec3 rd, vec3 sun, VisualUniforms u, float clouds) {
    float h = rd.y;
    float sd = max(dot(rd, sun), 0.0);
    vec3 warm = palVisual(0.12, u);
    vec3 cool = palVisual(0.9, u);
    // orange at the horizon, through a magenta dusk band, to deep indigo
    vec3 col = mix(warm * 0.08, palVisual(0.5, u) * 0.045, smoothstep(-0.02, 0.07, h));
    col = mix(col, palVisual(0.97, u) * 0.035, smoothstep(0.07, 0.32, h));
    col = mix(col, vec3(0.001, 0.0015, 0.008), smoothstep(0.3, 0.8, h));
    // thin high cloud streaks, lit by the sun behind them
    // (skipped in the glossy-top reflection, where they would barely show)
    float lit = pow(sd, 4.0);
    if (clouds > 0.5) {
        vec2 q = rd.xz / max(h + 0.12, 0.05);
        float tw = mod(u.time, 1800.0);
        float cl = vnoise(q * vec2(0.6, 2.4) + vec2(0.0, tw * 0.03)) * 0.65
                 + vnoise(q * vec2(1.3, 5.0) - vec2(tw * 0.02, 0.0)) * 0.35;
        cl = smoothstep(0.45, 0.85, cl) * smoothstep(0.0, 0.08, h) * (1.0 - smoothstep(0.25, 0.6, h));
        col += cl * (palVisual(0.56, u) * 0.05 * (1.0 - lit) + palVisual(0.28, u) * 0.4 * lit);
    }
    // the sun is eclipsed: a black moon with a hot rim, so the glow and the
    // corona around it carry the light
    float ang = sqrt(max(2.0 - 2.0 * sd, 0.0));
    float moon = smoothstep(TR_MOON - 0.0012, TR_MOON + 0.0006, ang);
    col += palVisual(0.55, u) * 0.06 * pow(sd, 3.0) + warm * (0.07 * pow(sd, 9.0) + 0.25 * pow(sd, 40.0) * moon);
    float rq = (ang - TR_MOON) / 0.003;
    col += peakWhite(palVisual(0.32, u), 0.6) * exp(-rq * rq) * 1.6;
    col *= mix(0.04, 1.0, moon);
    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float relief = mix(0.6, 1.4, u.param1);
    float glow = mix(0.5, 1.7, u.param2);

    float speed = mix(5.0, 18.0, u.param0);
    vec2 fl = osFlight(u, speed, 1.4 * mix(0.5, 1.5, u.param0));
    float z = fl.x;
    float rush = saturate((fl.y - 1.0) / 3.5);
    float alt = 4.6 + 0.6 * sin(u.time * 0.21);
    vec3 ro = vec3(trPath(z) + 0.5, alt, z);
    vec3 ta = vec3(trPath(z + 16.0) + 0.5, alt - 1.6, z + 16.0);
    float curve = trPath(z + 20.0) - 2.0 * trPath(z + 10.0) + trPath(z);
    float roll = -0.05 * curve + osBank(u, 0.12);
    vec3 rd = osCamera(ro, ta, roll, 1.3 - 0.16 * rush, p);

    // spectrum stops and the beat clock, read once
    vec4 spA = vec4(bandAt(u, 0.0), bandAt(u, 1.0 / 15.0), bandAt(u, 2.0 / 15.0), bandAt(u, 3.0 / 15.0));
    vec4 spB = vec4(bandAt(u, 4.0 / 15.0), bandAt(u, 5.0 / 15.0), bandAt(u, 6.0 / 15.0), bandAt(u, 7.0 / 15.0));
    vec4 spC = vec4(bandAt(u, 8.0 / 15.0), bandAt(u, 9.0 / 15.0), bandAt(u, 10.0 / 15.0), bandAt(u, 11.0 / 15.0));
    vec4 spD = vec4(bandAt(u, 12.0 / 15.0), bandAt(u, 13.0 / 15.0), bandAt(u, 14.0 / 15.0), bandAt(u, 1.0));
    float tb = mod(u.beatCount, 256.0) + saturate(u.beatPhase);

    vec3 fw = normalize(ta - ro);
    vec3 sun = normalize(vec3(fw.x * 0.7 + 0.2, 0.1, 1.0));
    vec3 srt = normalize(cross(sun, vec3(0.0, 1.0, 0.0)));
    vec3 sup = cross(srt, sun);
    vec2 sp = vec2(dot(rd, srt), dot(rd, sup));
    // the corona's spectrum: bass at the crown, treble down the flanks
    float cf = saturate(abs(atan2_(sp.x, sp.y + 1e-5)) * 0.53);
    float clv = trSpec(cf, spA, spB, spC, spD);
    float pix = 2.0 / (u.resolution.y * (1.3 - 0.16 * rush));
    float bp = saturate(u.beatPhase);

    // grid walk through the pillar columns
    vec2 cell = floor(ro.xz);
    vec2 rdxz = vec2(abs(rd.x) < 1e-4 ? 1e-4 : rd.x, abs(rd.z) < 1e-4 ? 1e-4 : rd.z);
    vec2 stp = sign(rdxz);
    vec2 inv = 1.0 / abs(rdxz);
    vec2 tNext = (stp * (cell - ro.xz) + stp * 0.5 + 0.5) * inv;
    float tIn = 0.0;
    float hitT = -1.0;
    vec3 n = vec3(0.0, 1.0, 0.0);
    float hc = 0.0, sc = 0.0;
    float lastAxis = 1.0;
    int steps = osSteps(34.0, 120.0, detail);
    float tmax = mix(42.0, 90.0, detail);
    for (int i = 0; i < 120; i++) {
        if (i >= steps) break;
        float s;
        float h = trHeight(cell, spA, spB, spC, spD, tb, relief, s);
        float tOut = min(tNext.x, tNext.y);
        float yIn = ro.y + rd.y * tIn;
        float yOut = ro.y + rd.y * tOut;
        if (yIn < h) {
            hitT = tIn;
            n = lastAxis < 0.5 ? vec3(-stp.x, 0.0, 0.0) : vec3(0.0, 0.0, -stp.y);
            hc = h; sc = s;
            break;
        }
        if (yOut < h) {
            hitT = (h - ro.y) / min(rd.y, -1e-4);
            n = vec3(0.0, 1.0, 0.0);
            hc = h; sc = s;
            break;
        }
        // above every pillar and climbing: sky
        if (rd.y >= 0.0 && yOut > 20.0) break;
        if (tNext.x < tNext.y) { tIn = tNext.x; tNext.x += inv.x; cell.x += stp.x; lastAxis = 0.0; }
        else { tIn = tNext.y; tNext.y += inv.y; cell.y += stp.y; lastAxis = 1.0; }
        if (tIn > tmax) break;
    }

    vec3 col;
    float t;
    vec3 cool = palVisual(0.86, u);
    if (hitT < 0.0) {
        t = tmax * 1.4;
        col = trSky(rd, sun, u, 1.0);
        // corona streamers: their length follows the spectrum round the rim,
        // a build pushes them out and each hit brightens them
        float cr = length(sp);
        float ca = atan2_(sp.y, sp.x);
        float tws = mod(u.time, 600.0);
        float strm = 0.5 + 0.3 * vnoise(vec2(ca * 9.0, tws * 0.15)) + 0.2 * vnoise(vec2(ca * 31.0, tws * 0.3 + 5.0));
        float L = (0.03 + 0.32 * clv * clv + 0.08 * rush) * strm;
        float dr = max(cr - TR_MOON, 0.0);
        float cor = exp(-dr / max(L, 0.006)) * smoothstep(TR_MOON - 0.001, TR_MOON + 0.004, cr) * step(0.0, dot(rd, sun));
        vec3 corC = mix(palVisual(0.3, u), palVisual(0.7, u), smoothstep(0.15, 0.85, cf));
        col += peakWhite(corC, exp(-dr * 40.0)) * cor * (0.5 + 0.8 * clv + 0.7 * u.bassImpact) * glow;
    } else {
        t = hitT;
        vec3 pos = ro + rd * t;
        float hn = saturate(hc / (7.5 * relief + 2.0));
        // the ember ramp, read at three fixed stops and blended by height;
        // a build swings the whole ramp toward the palette's third colour
        vec3 eLo = palVisual(0.02, u), eHi = palVisual(0.3, u), eAlt = palVisual(0.47, u);
        float hh = saturate(hn + 0.14 * hash21(cell + 3.1));
        vec3 ember = mix(eLo, eHi, smoothstep(0.0, 1.0, hh));
        ember = mix(ember, eAlt * (0.6 + 0.6 * hh), 0.7 * rush * rush);
        // the survey: on every beat a laser sheet leaves the craft and runs
        // ahead, cutting a bright profile line through the land and leaving
        // the contours it has crossed glowing behind it
        float zf = z + 3.0 + 44.0 * pow(bp, 0.8);
        float dzs = pos.z - zf;
        float lw = max(0.09, t * pix * 2.2);
        float lead = exp(-dzs * dzs / (lw * lw));
        float halo = 0.08 * exp(-abs(dzs) * 2.0);
        float trail = dzs < 0.0 ? exp(dzs * 0.22) : 0.0;
        float sAmp = (0.45 + 1.4 * u.bassImpact + 0.4 * u.treble) * (1.0 - 0.55 * bp) * smoothstep(70.0, 30.0, t) * smoothstep(3.0, 10.0, t);
        vec3 scanCol = cool * 1.6;
        vec3 leadCol = peakWhite(cool, 0.45) * 6.0;
        float g = smoothstep(0.1, 0.75, sc);
        float lvl = 0.015 + 1.4 * g * g;
        vec3 rr = reflect(rd, n);
        if (n.y > 0.5) {
            vec2 f = fract(pos.xz) - 0.5;
            float e = max(abs(f.x), abs(f.y));
            float rim = smoothstep(0.42, 0.47, e) * (1.0 - smoothstep(0.48, 0.5, e));
            float core = 1.0 - smoothstep(0.05, 0.46, e);
            // glossy black glass top: it mirrors the teal sky overhead and the
            // sun glow at grazing angles
            float fres = 0.04 + 0.96 * pow(1.0 - saturate(-rd.y), 5.0);
            col = trSky(rr, sun, u, 0.0) * (0.12 + fres * 0.45);
            col += ember * glow * (lvl * (0.25 + 0.75 * core) + rim * (0.22 + 2.8 * g));
            col = mix(col, palVisual(0.3, u) * glow * 2.6 * (0.4 + 0.6 * core), saturate(g - 0.7) * 1.5);
            col += glow * sAmp * (leadCol * lead + scanCol * (halo + trail * rim * 0.9));
        } else {
            float below = hc - pos.y;
            float lip = exp(-below * 5.0);
            float fy = saturate(pos.y / max(hc, 0.1));
            float ao = 0.2 + 0.8 * fy;
            // obsidian glass: deep indigo faces with a rose sheen
            // where they turn toward the sun
            float fres = 0.04 + 0.96 * pow(1.0 - saturate(dot(-rd, n)), 5.0);
            float sh = pow(saturate(dot(rr, sun)), 6.0);
            col = (palVisual(0.97, u) * 0.05 * (0.4 + 2.0 * fres) + palVisual(0.5, u) * sh * (0.035 + 0.5 * fres)) * ao;
            col += ember * glow * lip * (0.02 + 0.5 * g * g);
            // contour lines at fixed heights, lit where the sheet has passed
            float cont = aaLineCyclic(pos.y * 2.0, 0.05) * smoothstep(45.0, 12.0, t);
            col += glow * sAmp * (leadCol * lead + scanCol * (halo + trail * (0.03 + cont * 0.9)));
            // a cool level meter pours down each face from its hot top with the
            // band level, cut into segments by fine strata seams, and a bright
            // line rides its lower edge
            float lv = smoothstep(0.04, 0.75, sc);
            float fill = 0.15 + 1.8 * lv * lv;
            float inMeter = 1.0 - smoothstep(fill - 0.03, fill, below);
            float seam = aaLineCyclic(pos.y * 4.0, 0.12);
            float line = exp(-abs(below - fill) * 9.0);
            vec3 mc = mix(cool, palVisual(0.74, u), saturate(below / fill));
            col += mc * glow * (inMeter * (1.0 - seam) * (0.015 + 0.25 * lv * lv) * ao + line * (0.04 + 1.2 * lv * lv));
            col += vec3(0.0005, 0.001, 0.002) * seam;
            // vertical edges catch a thin line of light
            vec2 f = fract(pos.xz) - 0.5;
            float side = n.x != 0.0 ? f.y : f.x;
            float edge = smoothstep(0.44, 0.5, abs(side));
            col += ember * edge * glow * (0.05 + 0.6 * g) * ao;
            // cool skylight on the shaded faces, against the hot tops
            col += palVisual(0.97, u) * 0.03 * ao * ao;
        }
    }

    // height haze, thicker in the valley, warm toward the sun and cool away
    float sd = max(dot(rd, sun), 0.0);
    float fog = hitT < 0.0 ? 0.0 : 1.0 - exp(-t * mix(0.05, 0.028, detail));
    vec3 fogCol = mix(palVisual(0.97, u) * 0.06, palVisual(0.55, u) * 0.05, smoothstep(0.5, 0.95, sd))
                + palVisual(0.12, u) * (0.1 * pow(sd, 9.0) + 0.8 * pow(sd, 40.0));
    col = mix(col, fogCol, fog);
    // god rays fanning out from the low sun through the haze; the bass
    // lengthens them a little, the flight never moves them
    vec2 sdir = sp / max(length(sp), 1e-4);
    float tw = mod(u.time, 1800.0);
    float rays = vnoise(sdir * 7.0 + vec2(tw * 0.05, 0.0)) * vnoise(sdir * 17.0 - vec2(0.0, tw * 0.07));
    rays = smoothstep(0.1, 0.75, rays) * (0.35 + 0.9 * clv);
    float air = hitT < 0.0 ? smoothstep(TR_MOON, TR_MOON + 0.03, length(sp)) : 0.1 + 0.9 * fog;
    col += palVisual(0.2, u) * rays * air * pow(sd, mix(7.0, 4.0, u.bassImpact)) * (0.12 + 0.08 * u.bass) * glow;
    // low mist pooled between the pillars
    float my = hitT < 0.0 ? 4.0 : max(ro.y + rd.y * t, 0.0);
    float mist = exp(-my * 0.9) * (1.0 - exp(-t * 0.1));
    col += palVisual(0.56, u) * mist * (0.05 + 0.07 * u.bassImpact) * glow;
    vec3 eLoS = palVisual(0.12, u), eHiS = palVisual(0.3, u);
    // drifting sparks streaming past, carried by the flight
    for (int k = 0; k < 3; k++) {
        float fk = float(k);
        float d = fract(fk / 3.0 + z * 0.012);
        vec2 q = (p - vec2(0.0, 0.1)) * mix(14.0, 1.6, d) + vec2(fk * 13.7, fk * 7.1);
        vec2 ci = floor(q);
        vec2 jit = hash22(ci + fk * 31.0);
        vec2 dq = fract(q) - (0.2 + 0.6 * jit);
        float r = length(dq);
        float spark = (1.0 - smoothstep(0.0, 0.06 * mix(0.5, 1.5, d), r)) * step(0.88, hash21(ci * 1.7 + fk * 5.3));
        float fade = smoothstep(0.0, 0.3, d) * (1.0 - smoothstep(0.75, 1.0, d));
        col += (jit.y < 0.35 ? cool : mix(eLoS, eHiS, jit.y)) * spark * fade * (1.0 + 2.5 * u.treble) * glow * detail;
    }
    return col; // LINEAR HDR — post chain tonemaps
}
