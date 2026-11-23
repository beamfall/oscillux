// SPDX-License-Identifier: AGPL-3.0-only
// Neon run.
// A low, fast run down a curving, wet street between neon towers at night.
// Window grids, sign strips and holographic spectrum billboards glow in the
// palette; six lanes of flying traffic trail light through the canyon, and
// neon light gates span the street every thirty units so the speed reads as
// they flash past overhead. Past the towers a far skyline with aviation
// beacons stands in the city's glow under a cloud deck lit from below and
// swept by searchlights. The wet asphalt mirrors it all in puddles and
// stretches every light into long specular streaks; haze catches the glow.
// The camera's speed follows a 32-beat profile of cruise, build, burst, brake
// and drift; it banks into the curves and eases to a new side every eight
// beats. Audio drives the light, never the camera: tower window rows and
// billboards follow the spectrum; the roof bands, haze, alternate gates and
// searchlights pulse on the bass; the traffic glints on the treble.
// param0 = Flight Speed ; param1 = Banking ; param2 = Neon Intensity

// street centre line
float nrStreet(float z) { return 7.0 * sin(z * 0.021) + 3.0 * sin(z * 0.047 + 1.3); }

const float NR_HALF = 5.0;   // half street width
const float NR_CELL = 5.0;   // tower spacing along the street

float nrBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Tower half-size for a cell; id.x is the cell index along the street, id.y the side.
vec3 nrTowerSize(vec2 id) {
    float h = hash21(id * vec2(1.0, 7.31));
    float w = hash21(id * vec2(3.1, 1.7) + 4.0);
    return vec3(1.2 + 1.6 * w, 3.0 + 22.0 * h * h, 1.7 + 0.5 * hash21(id + 9.0));
}

// floorY moves the street plane; reflections drop it to march grazing rays fast.
float nrMap(vec3 p, float floorY) {
    float sx = p.x - nrStreet(p.z);
    float side = sx < 0.0 ? -1.0 : 1.0;
    float cz = floor(p.z / NR_CELL);
    vec2 id = vec2(cz, side);
    vec3 b = nrTowerSize(id);
    vec3 q = vec3(abs(sx) - NR_HALF - b.x, p.y - b.y, p.z - (cz + 0.5) * NR_CELL);
    // about one cell in four is an open plaza
    float d = hash21(id * vec2(5.3, 2.1) + 1.0) < 0.25 ? 1e3 : nrBox(q, b);
    // second, setback tier on tall towers
    float tall = step(10.0, b.y);
    d = min(d, mix(1e3, nrBox(q - vec3(0.4, b.y + 2.5, 0.0), vec3(b.x * 0.6, 2.5, b.z * 0.7)), tall));
    // the cell boundary bounds the step so neighbours are never jumped over
    float zb = (cz + 1.0) * NR_CELL - p.z;
    float za = p.z - cz * NR_CELL;
    d = min(d, max(min(za, zb), 0.0) + 0.3);
    return min(d, p.y - floorY);   // street plane at y = 0
}

vec3 nrNormal(vec3 p) {
    vec2 e = vec2(0.002, 0.0);
    return normalize(vec3(nrMap(p + e.xyy, 0.0) - nrMap(p - e.xyy, 0.0),
                          nrMap(p + e.yxy, 0.0) - nrMap(p - e.yxy, 0.0),
                          nrMap(p + e.yyx, 0.0) - nrMap(p - e.yyx, 0.0)));
}

float nrMarch(vec3 ro, vec3 rd, float tmax, int n, float floorY) {
    float t = 0.02;
    for (int i = 0; i < 128; i++) {
        if (i >= n) break;
        float d = nrMap(ro + rd * t, floorY);
        if (d < 0.002 * t) return t;
        t += d * 0.85;
        if (t > tmax) break;
    }
    return -1.0;
}

// Emission of a tower face: lit window grid, edge sign strips, a holographic
// spectrum billboard on some street faces, and the roof neon band.
// c recoloured to luminance l, negative palette channels dropped first: the
// music changes the colour of a light, not its brightness
vec3 nrAtLuma(vec3 c, float l) {
    c = max(c, vec3(0.0));
    float lc = luma(c);
    return lc < 1e-3 ? vec3(l) : c * (l / lc);
}

// fp is the width of one pixel on the facade and mv the distance the camera
// travels in one frame, both in world units
vec3 nrFacade(vec3 pos, vec3 n, float fp, float mv, VisualUniforms u) {
    float sx = pos.x - nrStreet(pos.z);
    float side = sx < 0.0 ? -1.0 : 1.0;
    float cz = floor(pos.z / NR_CELL);
    vec2 id = vec2(cz, side);
    vec3 b = nrTowerSize(id);
    float hue = hash21(id + 2.7);

    // face coordinates: along the face and up
    vec2 f = abs(n.x) > 0.5 ? vec2(pos.z, pos.y) : vec2(pos.x, pos.y);
    vec2 cell = floor(f * vec2(5.0, 3.5));
    vec2 g = fract(f * vec2(5.0, 3.5));
    float win = smoothstep(0.14, 0.22, g.x) * (1.0 - smoothstep(0.78, 0.86, g.x)) *
                smoothstep(0.2, 0.3, g.y) * (1.0 - smoothstep(0.7, 0.8, g.y));
    float wr = hash21(cell + id * 13.0);
    // lit floors come in bands, so towers read as buildings rather than LED boards
    float floorOn = step(0.35, hash21(vec2(cell.y, id.x * 3.0 + id.y)));
    float on = step(0.5, wr) * floorOn;
    // most windows take the tower's hue, a few run warm or cold against it
    vec3 winCol = palVisual(hue + 0.15 * hash21(cell) + step(0.9, wr) * 0.45, u);
    // the spectrum colours window rows by height, at the windows' own
    // luminance: the same band lights a row on every tower at once, so
    // brightening it would flash a large part of the frame
    int bi = int(clamp(pos.y / max(b.y, 1.0), 0.0, 1.0) * float(NBANDS - 1));
    float wl = 1.1 * luma(max(winCol, vec3(0.0)));
    vec3 hotC = nrAtLuma(palRolePeak(hue + 0.5 + 0.1 * float(bi), u), wl);
    vec3 col = mix(nrAtLuma(winCol, wl), hotC, smoothstep(0.15, 0.85, band(u, bi))) * win * on;
    // where a window is smaller than a pixel, or the camera passes more than
    // a window in a frame, the grid would strobe as it streams past, flipping
    // much of the frame between lit and dark each frame. Along the street the
    // lit floors smear into light streaks at speed (half the windows of a lit
    // floor, two thirds of each cell glass); where even the floors are below
    // a pixel the facade glows with the grid's mean.
    // the mean is the tower's, the same in every cell, or the filtered facade
    // would still step in brightness from window to window
    float hot = smoothstep(0.15, 0.85, band(u, bi));
    vec3 towerC = palVisual(hue + 0.075, u);
    float wlT = 1.1 * luma(max(towerC, vec3(0.0)));
    vec3 meanC = mix(nrAtLuma(towerC, wlT), nrAtLuma(palRolePeak(hue + 0.5 + 0.1 * float(bi), u), wlT), hot);
    float along = max(fp, abs(n.x) > 0.5 ? mv : 0.0) * 5.0;
    float winY = smoothstep(0.2, 0.3, g.y) * (1.0 - smoothstep(0.7, 0.8, g.y));
    col = mix(col, meanC * winY * floorOn * 0.32, smoothstep(0.3, 0.9, along));
    col = mix(col, meanC * 0.104, smoothstep(0.3, 0.9, fp * 3.5));

    // vertical sign strips on the street-facing corners
    float edge = max(abs(abs(sx) - NR_HALF), abs(abs(pos.z - (cz + 0.5) * NR_CELL) - b.z));
    float strip = (1.0 - smoothstep(0.0, 0.07, edge)) * step(pos.y, b.y * 1.6);
    float flick = 0.6 + 0.4 * sin(u.time * 7.0 + hue * 40.0) * step(0.8, hash21(id + 5.0));
    col += palRoleTrace(hue + 0.5, u) * strip * 6.0 * flick * (0.6 + u.bassImpact);

    // holographic billboard: spectrum bars on the street face of one tower in three
    if (abs(n.x) > 0.5 && hash21(id + 17.0) < 0.34 && b.y > 5.0) {
        float zc = pos.z - (cz + 0.5) * NR_CELL;
        float y0 = b.y * 0.55;
        vec2 bp = vec2(zc / (b.z * 0.85), (pos.y - y0) / 2.6);
        if (abs(bp.x) < 1.0 && bp.y > 0.0 && bp.y < 1.0) {
            float bx = (bp.x * 0.5 + 0.5) * 16.0;
            // the board streams past along z, so its detail is filtered over the
            // pixel's footprint and the frame's travel: bars that get narrower than
            // that blend to their mean, and the rim keeps its energy as it widens
            float fz = max(fp, mv) / (b.z * 0.85);
            float bar = smoothstep(0.1, 0.2, fract(bx)) * (1.0 - smoothstep(0.8, 0.9, fract(bx)));
            bar = mix(bar, 0.7, smoothstep(0.03, 0.1, fz));
            float lv = saturate(0.08 + 1.3 * bandAt(u, floor(bx) / 16.0));
            // the bar's top glows off over a quarter of its height and the unlit
            // segments stay faintly on, so a bar rising or falling with the music
            // brightens and dims its column smoothly instead of switching it
            float fill = 1.0 - smoothstep(lv - 0.25, lv + 0.05, bp.y);
            float scan = 0.75 + 0.25 * sin(pos.y * 40.0 - u.time * 6.0);
            vec3 bc = palVisual(hue + 0.3 + bp.y * 0.35, u);
            float fw = max(0.03, max(fp / 2.6, fz) * 1.5);
            float frame = (1.0 - smoothstep(0.0, fw, min(1.0 - abs(bp.x), min(bp.y, 1.0 - bp.y)))) * 0.03 / fw;
            col = col * 0.15 + bc * (bar * (fill * 2.0 + 0.35) * scan + 0.12) + palRolePeak(hue + 0.3, u) * frame * 3.0;
        }
    }

    // horizontal neon band under the roofline, pulsing on the beat
    float roof = (1.0 - smoothstep(0.0, 0.12, abs(pos.y - (b.y * 2.0 - 0.6))));
    col += palRolePeak(hue + 0.25, u) * roof * (2.0 + 6.0 * u.bassImpact);
    return col;
}

// Sky over the canyon: light pollution glowing up from the horizon, a cloud
// deck lit from below in two neon hues, a far skyline of silhouetted towers
// with window dots and aviation beacons, and searchlight beams. drift is the
// flight distance, so the clouds stream past with the speed profile.
vec3 nrSky(vec3 rd, float drift, float clouds, VisualUniforms u) {
    float h = saturate(rd.y);
    vec3 warm = palVisual(0.02, u);
    vec3 cool = palVisual(0.55, u);
    // zenith deep blue-violet, horizon a hot band of city glow
    vec3 col = mix(cool * 0.05 + vec3(0.004, 0.003, 0.012), vec3(0.002, 0.002, 0.007), smoothstep(0.0, 0.7, h));
    col += warm * 0.30 * exp(-h * 9.0) + mix(warm, cool, 0.5) * 0.06 * exp(-h * 3.0);
    // cloud deck, lit from below: brighter near the horizon, two hues by density
    // (skipped in the rippled road mirror, where it would only smear)
    if (clouds > 0.5) {
        vec2 cp = rd.xz / (h + 0.12) * 0.8 + vec2(0.0, drift * 0.004);
        float cl = vnoise(cp) * 0.6 + vnoise(cp * 2.6 + vec2(4.0, -drift * 0.002)) * 0.4;
        float deck = smoothstep(0.32, 0.8, cl) * smoothstep(0.02, 0.12, h) * (1.0 - smoothstep(0.4, 0.85, h));
        col += mix(warm, cool, smoothstep(0.45, 0.9, cl)) * deck * (0.16 + 0.30 * exp(-h * 5.0)) * (1.0 + 0.3 * u.bassImpact);
    }
    // the far skyline: two layers of tower silhouettes along the horizon
    float a = atan2_(rd.x, rd.z);
    for (int l = 0; l < 2; l++) {
        float fl = 1.0 - float(l);           // far layer first, near layer over it
        float k = mix(24.0, 52.0, fl);
        float ca = a * k + fl * 17.0;
        float id = floor(ca);
        float hh = hash11(mod(id, 512.0) * 0.731 + fl * 3.1);
        float top = mix(0.11, 0.055, fl) * (0.3 + hh * hh);
        float bx = fract(ca) - 0.5;
        float slim = step(abs(bx), 0.3 + 0.18 * hash11(id * 1.3 + 2.0));
        if (h < top && slim > 0.5) {
            vec2 gw = vec2(fract(ca) * 7.0, h * k * 1.4);
            float w = step(0.6, hash21(floor(gw) + id * 3.0)) * step(0.35, fract(gw.x)) * step(0.4, fract(gw.y));
            // far towers sink into the glow, near ones are dark against it
            vec3 sil = mix(warm, cool, 0.35) * mix(0.02, 0.07, fl) * (1.0 + 3.0 * exp(-h * 30.0));
            sil += palVisual(hash11(id * 0.37 + fl) * 0.6 + 0.2, u) * w * mix(0.35, 0.18, fl);
            col = sil;
        }
        // a blinking red beacon on the taller towers
        float by = (h - top) * k * 0.5;
        col += vec3(2.0, 0.25, 0.15) * step(0.72, hh) * exp(-(bx * bx + by * by) * 300.0) * (0.55 + 0.45 * sin(u.time * 3.0 + id));
    }
    // searchlight beams sweeping the cloud deck
    float beams = pow(saturate(cos(a * 7.0 + u.time * 0.4)), 60.0) * smoothstep(0.0, 0.25, h) * (1.0 - h);
    col += mix(cool, warm, 0.3) * beams * 0.2 * (1.0 + 0.3 * u.bassImpact);
    return col;
}

// Flying traffic: up to six lanes of glowing craft above the street, some slots
// empty. stretch > 1 smears each light vertically, for the wet-road mirror.
// mv is the distance the camera flies in one frame.
vec3 nrTraffic(vec3 ro, vec3 rd, float tMax, float stretch, float tw, float mv, int lanes, VisualUniforms u) {
    vec3 acc = vec3(0.0);
    for (int i = 0; i < 6; i++) {
        if (i >= lanes) break;
        float fi = float(i);
        float hi = step(1.5, fi);
        float lo = step(3.5, fi);
        float dir = mod(fi, 2.0) < 0.5 ? 1.0 : -1.0;
        // two mid lanes, two high lanes, and a fast low lane hugging each wall
        float yL = mix(mix(6.5, 11.0, hi), 3.6, lo);
        float off = dir * mix(mix(1.7, 3.0, hi), 3.9, lo);
        if (abs(rd.y) < 1e-3) continue;
        float tp = (yL - ro.y) / rd.y;
        if (tp < 0.0 || tp > tMax) continue;
        vec3 P = ro + rd * tp;
        float spacing = mix(mix(11.0, 15.0, hi), 9.0, lo);
        float vel = dir * mix(mix(16.0, 22.0, hi), 30.0, lo);
        float shift = vel * tw;
        // the distance a craft closes on the camera in one frame: oncoming craft
        // pass a light's width every frame, so each light is blurred along its
        // run over the frame, keeping its energy, or it would strobe
        float blur = abs(vel * clamp(u.dt, 1.0 / 60.0, 0.1) - mv);
        float k = floor((P.z - shift) / spacing + 0.5);
        for (int j = -1; j <= 1; j++) {
            float kk = k + float(j);
            float keep = step(0.5, hash21(vec2(mod(kk, 997.0), fi * 7.1 + 3.0)));
            if (keep < 0.5) continue;
            float cz = kk * spacing + shift;
            vec3 C = vec3(nrStreet(cz) + off, yL + 0.4 * sin(kk * 1.7), cz);
            vec3 w = C - ro;
            float tc = dot(w, rd);
            if (tc < 0.0 || tc > tMax) continue;
            vec3 perp = w - rd * tc;
            // each craft is a light bar with a long light trail streaming behind it
            float tz = perp.z * dir;
            float zs = tz > 0.0 ? 0.25 : 0.012;
            float r = 0.13 + 0.004 * tc;
            float rz2 = r * r / zs;
            float rzb = rz2 + blur * blur * 0.25;
            float d2 = perp.x * perp.x + perp.z * perp.z * r * r / rzb + (perp.y / stretch) * (perp.y / stretch);
            // and it fades out over the last few units before it passes the
            // camera instead of vanishing at once
            float near = smoothstep(0.0, 3.0 + 4.0 * blur, tc);
            float core = exp(-d2 / (r * r)) * sqrt(rz2 / rzb) * near;
            float halo = r * r / (d2 + r * r) * 0.16 * near;
            // tail lights going away, headlights coming on
            vec3 lc = dir > 0.0 ? palVisual(0.02, u) * vec3(1.7, 0.45, 0.45) : vec3(0.85, 0.95, 1.15) * 1.5;
            acc += lc * (core * 5.0 + halo) * (1.0 + 1.5 * u.treble) * exp(-tc * 0.010);
        }
    }
    return acc;
}

// Light gates: neon bars spanning the canyon every 30 units, so the run's speed
// reads as gates flashing past overhead. Each glows in its own hue; the gate a
// beat lands on pulses. stretch smears the glow vertically for the wet road.
vec3 nrGates(vec3 ro, vec3 rd, float tMax, float stretch, int count, VisualUniforms u) {
    vec3 acc = vec3(0.0);
    if (abs(rd.z) < 1e-3) return acc;
    float k0 = floor(ro.z / 30.0);
    for (int j = 0; j < 4; j++) {
        if (j >= count) break;
        float k = k0 + float(j) + (rd.z > 0.0 ? 1.0 : 0.0) - (rd.z > 0.0 ? 0.0 : float(2 * j));
        float zk = k * 30.0;
        float tg = (zk - ro.z) / rd.z;
        if (tg < 0.0 || tg > tMax) continue;
        vec3 P = ro + rd * tg;
        float hk = hash11(mod(k, 512.0) * 0.618 + 0.2);
        float yG = 7.0 + 3.0 * hk;
        float ex = max(abs(P.x - nrStreet(zk)) - NR_HALF - 0.4, 0.0);
        float dy = (P.y - yG) / stretch;
        float d2 = dy * dy + ex * ex;
        float r = 0.06 + 0.0025 * tg;
        float glow = exp(-d2 / (r * r)) * 4.0 + r * r / (d2 + r * r) * 0.10;
        float pulse = 1.0 + 0.3 * u.bassImpact * step(0.5, hash11(mod(k, 512.0) + 3.0));
        acc += palVisual(hk, u) * glow * pulse * exp(-tg * 0.012);
    }
    return acc;
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;

    float speed = mix(6.0, 22.0, u.param0);
    float detail = osDetail(u);
    float surge = 1.6 * mix(0.5, 1.5, u.param0);
    vec2 fl = osFlight(u, speed, surge);
    float z = fl.x;
    float rush = saturate((fl.y - 1.0) / 3.5);
    float lull = saturate(1.0 - fl.y);
    float alt = 1.6 + 0.6 * sin(u.time * 0.37);
    vec3 ro = vec3(nrStreet(z), alt, z);
    vec3 ta = vec3(nrStreet(z + 9.0), alt * 0.8 + 0.4, z + 9.0);

    vec3 fw = normalize(ta - ro);
    // bank into the curve: the street's curvature ahead sets the lean
    float curve = nrStreet(z + 14.0) - 2.0 * nrStreet(z + 7.0) + nrStreet(z);
    float roll = -0.08 * curve + osBank(u, mix(0.0, 0.2, u.param1));
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(fw, up));
    vec3 cu = cross(rt, fw);
    float fov = 1.25 - 0.18 * rush + 0.08 * lull;
    vec3 rd = normalize(p.x * rt + p.y * cu + fov * fw);
    float pixAng = 2.0 * shortSideFit(u.resolution.x / max(u.resolution.y, 1.0)) / max(u.resolution.y, 1.0) / fov;
    // the distance flown in this frame (osFlight's velocity, taking the beat at
    // 150 BPM, so slower songs are slightly over-filtered and none under-filtered
    // up to that tempo); a frame is the host's dt, at least 1/60 s
    float frameDt = clamp(u.dt, 1.0 / 60.0, 0.1);
    float mv = (speed * 0.2 + fl.y * 2.5 * (speed * 0.4 + surge)) * frameDt;

    float tw = mod(u.time, 600.0);
    float neon = mix(0.5, 1.6, u.param2);
    vec3 haze = palVisual(0.5, u) * 0.014 + vec3(0.001, 0.001, 0.004);
    vec3 col;
    float t = nrMarch(ro, rd, 160.0, int(mix(56.0, 88.0, detail) + 0.5), 0.0);
    float tHit = t < 0.0 ? 160.0 : t;
    if (t < 0.0) {
        col = nrSky(rd, z, 1.0, u);
        t = 160.0;
    } else {
        vec3 pos = ro + rd * t;
        vec3 n = nrNormal(pos);
        if (pos.y < 0.01 + 0.003 * t) {
            // wet asphalt: mirror puddles and rough, streaky wet patches between them
            float puddle = smoothstep(0.42, 0.62, vnoise(pos.xz * vec2(0.45, 0.22) + 3.0));
            // ripples that vary fast along the street smear reflections into vertical streaks
            float sj = vnoise(pos.xz * vec2(1.5, 40.0) + vec2(0.0, tw * 0.5)) - 0.5;
            float sx2 = vnoise(pos.xz * vec2(12.0, 1.5)) - 0.5;
            float rough = mix(1.0, 0.15, puddle);
            vec3 rn = normalize(vec3(sx2 * 0.012 * rough, 1.0, sj * 0.4 * rough));
            vec3 rr = reflect(rd, rn);
            float fres = 0.3 + 0.7 * pow(1.0 - saturate(-rd.y), 5.0);
            float t2 = nrMarch(pos + rn * 0.01, rr, 120.0, int(mix(26.0, 52.0, detail) + 0.5), -50.0);
            vec3 refl;
            if (t2 < 0.0) {
                refl = nrSky(rr, z, 0.0, u);
                t2 = 120.0;
            } else {
                vec3 p2 = pos + rr * t2;
                vec3 n2 = nrNormal(p2);
                refl = nrFacade(p2, n2, (t + t2) * pixAng / max(abs(dot(n2, rr)), 0.15), mv, u) * neon;
                refl = mix(refl, haze, 1.0 - exp(-t2 * 0.025));
            }
            // the traffic overhead, stretched into long streaks on the wet road
            refl += nrTraffic(pos, rr, t2, mix(7.0, 2.5, puddle), tw, mv, 4, u);
            refl += nrGates(pos, rr, t2, mix(7.0, 2.5, puddle), 2, u);
            refl *= mix(0.55, 1.0, puddle);
            // a kerb glow along both sides
            float sx = pos.x - nrStreet(pos.z);
            float kerb = 1.0 - smoothstep(0.0, 0.08, abs(abs(sx) - NR_HALF + 0.15));
            vec3 asphalt = vec3(0.006, 0.006, 0.01) * (1.0 - puddle);
            col = refl * fres + asphalt + palRoleTrace(0.6, u) * kerb * 1.5;
        } else {
            vec3 em = nrFacade(pos, n, t * pixAng / max(abs(dot(n, rd)), 0.15), mv, u) * neon;
            // glossy facades pick up the street's glow at grazing angles
            float gr = pow(1.0 - saturate(abs(dot(n, rd))), 4.0);
            float amb = 0.02 + 0.03 * saturate(n.y);
            col = em + haze * amb * 8.0 + palVisual(0.5, u) * gr * 0.05 * (1.0 + u.bassImpact);
        }
    }
    // the traffic in the canyon, in front of whatever the ray hit
    col += nrTraffic(ro, rd, tHit, 1.0, tw, mv, 6, u);
    col += nrGates(ro, rd, tHit, 1.0, 4, u);

    // haze: distance fog plus glow that the neon throws into the air
    // the sky already carries its own atmosphere; only a thin veil of haze over it
    float fog = tHit >= 160.0 ? 0.2 : 1.0 - exp(-t * 0.018);
    col = mix(col, haze, fog);
    col += palRoleBass(0.2, u) * haze * 4.0 * u.bassImpact * fog;

    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
