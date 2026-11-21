// SPDX-License-Identifier: AGPL-3.0-only
// Spectral City.
// A dawn flight high above the clouds, weaving between supertall glass spires.
// The towers rise out of a luminous cloud sea lit from below by the hidden
// city; each one carries vertical light columns that fill with its band of the
// spectrum like a giant level meter, crowned by a ring and an aviation beacon.
// Dark glass mirrors the dawn sky, corners catch the low sun, and the deck
// fades into a cold blue aerial haze. The camera glides at a steady, slow
// pace along a winding gap with a gentle bank into the turns. Audio drives
// light only, and softly: the meters fill with the smoothed level and a modest
// band term, lit and unlit segments sit close in brightness, the crown rings
// hold steady, the off-red beacons blink gently and the colours drift slowly
// with the palette, never shimmering with the music.
// param0 = Density ; param1 = Speed ; param2 = Reflection

// The palette read without the library's per-beat and spectral-centroid hue
// nudge, so large lit areas never shimmer with the music; under the host's
// palette tour the cross-fade between palettes is spread over the whole tour
// step, so the colours change slowly.
vec3 scPalStill(float t, VisualUniforms u) {
    if (u.palette.x >= 0.0) return palByIndex(t, int(floor(u.palette.x + 0.5)));
    int a = int(mod(floor(u.palette.z), 32.0));
    int b = int(mod(float(a + 1), 32.0));
    float blend = smoothstep(0.0, 1.0, fract(u.palette.z));
    return mix(palByIndex(t, a), palByIndex(t, b), blend);
}

const float SC_CELL = 11.0;
const float SC_CLOUD = 0.0;   // cloud deck height

float scPath(float z) { return 16.0 * sin(z * 0.010) + 7.0 * sin(z * 0.023 + 1.3); }

// Tower for a cell: xy = half widths, z = height (0 = empty), w = hash.
vec4 scTower(vec2 c, float density) {
    vec2 ctr = (c + 0.5) * SC_CELL;
    float h0 = hash21(c * vec2(1.0, 7.31) + 0.5);
    float keep = step(h0, density) * step(8.0, abs(ctr.x - scPath(ctr.y)));
    float h1 = hash21(c * vec2(3.1, 1.7) + 4.0);
    float h2 = hash21(c + 9.0);
    float hw = 1.5 + 2.2 * h1;
    float hh = 14.0 + 62.0 * h2 * h2;
    return vec4(hw, hw * mix(0.7, 1.3, hash21(c + 2.2)), hh * keep, hash21(c + 17.0));
}

float scBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Distance to the tower standing in cell c (1e3 when the cell is empty).
float scTowerSdf(vec3 p, vec2 c, vec4 tw) {
    vec2 l = p.xz - (c + 0.5) * SC_CELL;
    float d = 1e3;
    if (tw.z > 0.0) {
        float base = SC_CLOUD - 20.0;
        float hy = 0.5 * (tw.z - base);
        d = scBox(vec3(l.x, p.y - base - hy, l.y), vec3(tw.x, hy, tw.y));
        // slim setback crown and mast
        d = min(d, scBox(vec3(l.x, p.y - tw.z - 1.5, l.y), vec3(tw.x * 0.6, 1.5, tw.y * 0.6)));
        d = min(d, scBox(vec3(l.x, p.y - tw.z - 3.0 - 0.06 * tw.z, l.y), vec3(0.12, 0.06 * tw.z, 0.12)));
    }
    return d;
}

float scMap(vec3 p, float density) {
    vec2 c = floor(p.xz / SC_CELL);
    vec2 l = p.xz - (c + 0.5) * SC_CELL;
    float d = scTowerSdf(p, c, scTower(c, density));
    // never step past the cell boundary, so neighbours are not skipped
    vec2 bnd = 0.5 * SC_CELL - abs(l);
    return min(d, max(min(bnd.x, bnd.y), 0.0) + 0.3);
}

vec3 scNormal(vec3 p, float density) {
    vec2 e = vec2(0.01, -0.01);
    return normalize(e.xyy * scMap(p + e.xyy, density) + e.yyx * scMap(p + e.yyx, density)
                   + e.yxy * scMap(p + e.yxy, density) + e.xxx * scMap(p + e.xxx, density));
}

vec3 scSky(vec3 rd, vec3 sun, VisualUniforms u) {
    float h = rd.y;
    float sd = max(dot(rd, sun), 0.0);
    vec3 zen = vec3(0.004, 0.010, 0.040);
    vec3 hor = mix(vec3(0.025, 0.05, 0.13), scPalStill(0.02, u) * 0.3, pow(sd, 3.0));
    vec3 col = mix(hor, zen, smoothstep(-0.02, 0.45, h));
    // a magenta band above the dawn glow, then the orange core over the sun
    col += scPalStill(0.27, u) * 0.05 * exp(-max(h, 0.0) * 7.0) * (0.4 + 0.6 * sd);
    col += scPalStill(0.04, u) * (0.3 * pow(sd, 8.0) + 1.4 * pow(sd, 70.0)) * smoothstep(-0.1, 0.05, h + 0.05);
    // stars still out overhead
    vec2 sp = rd.xz / max(h + 0.25, 0.05) * 60.0;
    float st = hash21(floor(sp));
    col += vec3(0.7, 0.8, 1.0) * step(0.985, st) * smoothstep(0.35, 0.0, length(fract(sp) - 0.5))
         * smoothstep(0.15, 0.5, h) * 0.6;
    return col;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float density = mix(0.25, 0.8, u.param0);
    float refl = mix(0.2, 1.0, u.param2);
    float tm = mod(u.time, 600.0);

    float speed = mix(0.5, 1.5, u.param1);
    // a slow glide: the shared beat profile only nudges the pace, because
    // faster flight over the dense LED meters reads as large-area flashing
    float z = 25.0 + speed * u.time * 0.8;
    float alt = 30.6 + 2.0 * sin(u.time * 0.07);
    vec3 ro = vec3(scPath(z), alt, z);
    vec3 ta = vec3(scPath(z + 24.0), alt, z + 24.0);
    float curve = scPath(z + 30.0) - 2.0 * scPath(z + 15.0) + scPath(z);
    float roll = -0.03 * curve;
    // a level camera with a shifted lens keeps the spires vertical; longer
    // focal length than a wide angle so edge towers do not lean
    float focal = 2.0;
    vec3 rd = osCamera(ro, ta, roll, focal, p - vec2(0.0, 0.11 * focal));
    vec3 fw = normalize(ta - ro);
    vec3 sun = normalize(vec3(fw.x * 0.6 + 0.35, -0.015, 1.0));

    // march the spires; rays heading down stop at the cloud deck
    float tCloud = rd.y < -1e-4 ? (SC_CLOUD - ro.y) / rd.y : 1e4;
    float tmax = min(mix(220.0, 320.0, detail), tCloud);
    int steps = osSteps(56.0, 110.0, detail);
    float t = 0.1;
    float hit = -1.0;
    float open = 0.0;   // 1 once the ray is clear of everything
    // walk the grid cell by cell: sphere-trace the cell's own tower, but never
    // step past the point where the ray leaves the cell
    vec2 dirS = step(0.0, rd.xz);
    vec2 invR = 1.0 / (mix(vec2(-1.0), vec2(1.0), dirS) * max(abs(rd.xz), vec2(1e-5)));
    for (int i = 0; i < 110; i++) {
        if (i >= steps) break;
        vec3 pp = ro + rd * t;
        vec2 c = floor(pp.xz / SC_CELL);
        vec2 tb = ((c + dirS) * SC_CELL - pp.xz) * invR;
        float tExit = max(min(tb.x, tb.y), 0.0) + 0.02;
        float d = scTowerSdf(pp, c, scTower(c, density));
        if (d < min(0.002 * t, 0.06)) { hit = t; break; }
        t += min(d, tExit);
        if (t > tmax || (rd.y > 0.0 && ro.y + rd.y * t > 90.0)) { open = 1.0; break; }
    }

    vec3 col;
    float dist;
    if (hit > 0.0) {
        dist = hit;
        vec3 pos = ro + rd * hit;
        vec3 n = scNormal(pos, density);
        vec2 c = floor(pos.xz / SC_CELL);
        vec2 l = pos.xz - (c + 0.5) * SC_CELL;
        vec4 tw = scTower(c, density);
        float fy = saturate((pos.y - SC_CLOUD) / max(tw.z - SC_CLOUD, 1.0));
        float vert = step(n.y, 0.5);
        float along = abs(n.x) > 0.5 ? l.y : l.x;
        float halfFace = abs(n.x) > 0.5 ? tw.y : tw.x;
        // curtain-wall panes, each set at a slightly different angle so the
        // dawn breaks into a mosaic instead of one flat dark face
        vec2 pc = vec2(along * 2.6, pos.y * 1.6);
        vec2 pf = fract(pc);
        float ph = hash21(floor(pc) + c * 7.0 + n.xz * 3.0);
        float nearF = exp(-hit * 0.03) * vert;
        vec3 rr = reflect(rd, n);
        rr.y += (ph - 0.5) * 0.09 * nearF;
        float fres = 0.06 + 0.94 * pow(1.0 - saturate(dot(-rd, n)), 4.0);
        vec3 skyR = rr.y > 0.0 ? scSky(rr, sun, u) : vec3(0.05, 0.06, 0.12) + scPalStill(0.3, u) * 0.03;
        col = vec3(0.002, 0.003, 0.009) + skyR * (0.13 + fres) * refl * mix(0.35, 1.0, ph * nearF + 0.5 * (1.0 - nearF));
        // the low sun glinting off the glass
        col += scPalStill(0.05, u) * pow(max(dot(rr, sun), 0.0), 90.0) * 4.0 * refl * vert;
        // sun-side faces catch a warm wash, the rest an uplight from the city under the clouds
        col += scPalStill(0.06, u) * 0.025 * pow(saturate(dot(n, sun) + 0.15), 2.0) * vert * (0.4 + 0.6 * fy);
        col += mix(scPalStill(0.36, u), scPalStill(0.74, u), ph) * 0.03 * exp(-(pos.y - SC_CLOUD) * 0.06) * vert;
        // mullions and floor lines
        float mull = max(smoothstep(0.1, 0.0, min(pf.x, 1.0 - pf.x)), smoothstep(0.12, 0.0, min(pf.y, 1.0 - pf.y)));
        col = mix(col, vec3(0.004, 0.006, 0.014) + skyR * 0.12, mull * nearF * 0.8);
        // a scatter of lit offices
        float lit = step(0.955, ph) * (0.25 + 0.75 * nearF);
        col += scPalStill(0.1, u) * lit * 0.14 * (1.0 - mull);
        // segmented level meters running up the faces, one per band
        float cols = halfFace > 2.6 ? 2.0 : 1.0;
        float cx = cols > 1.5 ? abs(abs(along) - halfFace * 0.45) : abs(along);
        float housing = smoothstep(0.44, 0.38, cx) * vert;
        float strip = smoothstep(0.32, 0.24, cx) * vert;
        float y0 = max(SC_CLOUD + 1.0, tw.z - 38.0);
        float fm = (pos.y - y0) / max(tw.z - 1.5 - y0, 1.0);
        float inM = step(0.0, fm) * step(fm, 1.0);
        float bi = fract(tw.w * 3.7 + (n.x + n.z) * 0.21 + 0.13 * cols * sign(along));
        float lvl = saturate(0.3 + 0.25 * u.level + 0.3 * bandAt(u, bi));
        float sidx = floor(fm * 14.0);
        float sf = fract(fm * 14.0);
        float segm = smoothstep(0.0, 0.12, sf) * smoothstep(1.0, 0.82, sf);
        float nLit = floor(lvl * 14.0 + 0.5);
        float on = step(sidx + 0.5, nLit);
        float topSeg = on * step(nLit - 1.5, sidx);
        // cool at the foot, through violet and magenta, amber at the peak
        vec3 sc = scPalStill(mix(0.84, 0.1, saturate(fm)), u);
        col *= 1.0 - 0.85 * housing * inM;
        float ledL = segm * (on * (0.6 + 0.3 * lvl) + (1.0 - on) * 0.3);
        col += sc * strip * inM * ledL;
        col += mix(sc, vec3(1.0), 0.55) * strip * inM * topSeg * segm * 0.8;
        // crown ring, warm against the cold columns, steady
        float ring = smoothstep(0.35, 0.0, abs(pos.y - tw.z - 2.6)) * step(n.y, 0.5);
        col += scPalStill(0.08, u) * ring * (1.5 + 0.05 * u.level);
        // vertical corners catch the low sun
        float edge = smoothstep(0.12, 0.0, halfFace - abs(along)) * vert;
        col += scPalStill(0.1, u) * edge * (0.08 + 0.5 * pow(saturate(dot(n, sun) + 0.3), 2.0));
        // aviation beacon on the mast tip, a slow gentle off-red blink
        float tipY = tw.z + 3.0 + 0.12 * tw.z;
        float bl = smoothstep(0.6, 1.0, sin(tm * 2.2 + tw.w * 30.0));
        col += vec3(1.0, 0.3, 0.15) * exp(-length(vec3(l.x, pos.y - tipY, l.y)) * 4.0) * (0.4 + 1.0 * bl);
        // cold mist creeping up the base from the clouds
        col = mix(col, vec3(0.06, 0.09, 0.2), exp(-(pos.y - SC_CLOUD) * 0.18) * 0.8);
    } else if (rd.y < -1e-4 && tCloud < tmax + 1.0) {
        // the cloud sea, lit by the dawn above and the city glowing beneath
        dist = tCloud;
        vec3 pos = ro + rd * tCloud;
        vec2 q = pos.xz * 0.035 + vec2(tm * 0.02, 0.0);
        float c1 = vnoise(q) * 0.55 + vnoise(q * 2.3 + 3.0) * 0.3;
        c1 += detail * vnoise(q * 5.1 - 1.0) * 0.15;
        float glowN = vnoise(pos.xz * 0.006 + 7.0);
        // billows: tops lit orange toward the sun, violet in their shadows
        float toward = pow(max(dot(normalize(vec3(rd.x, 0.0, rd.z) + 1e-4), sun), 0.0), 3.0);
        float lit = smoothstep(0.3, 0.75, c1);
        vec3 shade = vec3(0.012, 0.016, 0.05);
        vec3 sunlit = mix(vec3(0.05, 0.08, 0.2), scPalStill(0.03, u) * 0.45, toward);
        col = mix(shade, sunlit, lit);
        vec3 city = mix(scPalStill(0.3, u), scPalStill(0.72, u), glowN);
        // the hidden city shows through the gaps between billows
        col += city * smoothstep(0.45, 0.85, 1.0 - c1) * smoothstep(0.35, 0.75, glowN) * (0.55 + 0.03 * u.level);
        dist *= 0.55; // the deck shows through the haze further than the towers
    } else if (open < 0.5) {
        // out of steps among the spires: a distant silhouette, never a hole of sky
        dist = t;
        col = vec3(0.003, 0.005, 0.014);
    } else {
        dist = 1e4;
        col = scSky(rd, sun, u);
    }

    // aerial haze toward the horizon, warmer toward the sun
    float sd = max(dot(rd, sun), 0.0);
    vec3 hazeCol = mix(vec3(0.03, 0.045, 0.13) + scPalStill(0.3, u) * 0.012, scPalStill(0.03, u) * 0.32, pow(sd, 28.0));
    float fog = dist > 9e3 ? 0.0 : 1.0 - exp(-dist * mix(0.0075, 0.0055, detail));
    col = mix(col, hazeCol, fog);
    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
