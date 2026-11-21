// SPDX-License-Identifier: AGPL-3.0-only
// Photo Curtain.
// The photo printed across a kinetic curtain of glossy vertical slats hanging
// in a dark hall. Each slat is a slightly curved print on its own pivot and
// hangs at its own depth, so the picture breaks into parallax as the camera
// drifts. Waves of turning slats sweep across the curtain, twisting along
// their length and flashing their dark anodised backs, whose thin-film sheen
// walks between opposite ends of the palette, before the photo settles
// again; a hot backlight leaks through the seams into the haze.
// The big wave travels at a steady pace, easing only a little faster on the
// shared 32-beat speed profile's builds and bursts. Audio drives the light and
// the slats' sway softly: each slat follows the music's smoothed level with a
// little of its own spectrum band, the seams glow with it, builds shift the
// print's colour grade a touch. No beat flashes the prints or the seams, and
// the haze drifts slowly, the slats ripple gently, the camera glides level and
// the glints on the slat backs stay soft, so no large area pulses.
// param0 = Columns ; param1 = Sway ; param2 = Depth

const float PC_H = 1.2;   // half height of the photo on the curtain

// The palette is read once per pixel at its five stops and blended locally;
// each library read walks the whole stop table.
struct PcPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

PcPal pcPalLoad(VisualUniforms u) {
    PcPal P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 pcPal(PcPal P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

float pcSq(float x) { return x * x; }

// Keeps every red just off saturated red once tonemapped: green and blue
// rise together until they make 0.27 of red, so no red area can strobe.
float pcTone(float x) { return x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14); }
float pcToneInv(float y) {
    y = clamp(y, 0.0, 0.999);
    float a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y;
    return (-b + sqrt(b * b + 0.56 * a * y)) / (2.0 * a);
}
vec3 pcOffRed(vec3 c) {
    float r = pcTone(c.r), g = pcTone(c.g), b = pcTone(c.b);
    float need = 0.27 * r - g - b;
    if (need <= 0.0) return c;
    c.g = pcToneInv(g + 0.5 * need);
    c.b = pcToneInv(b + 0.5 * need);
    return c;
}

// Slat angle about its vertical pivot at height y.
// fr.x: the full-turn wave sweeping left to right; fr.y: a half-open swell
// running back the other way; ph: flight distance, which carries the
// travelling ripple.
float pcAngle(float j, float y, vec2 fr, float ph, float sway, float b, float t) {
    // the turning wave, slanted so slats twist along their length
    float pr = saturate((fr.x - j - y * 1.3) / 10.0);
    pr = pr * pr * pr * (pr * (pr * 6.0 - 15.0) + 10.0);
    float flip = 6.2831853 * pr;
    // the swell opens the slats to about 60 degrees and lets the backlight through
    float d2 = (j - fr.y + y * 1.1) / 3.2;
    float swell = 1.05 * exp(-d2 * d2);
    // a travelling ripple that never stops, plus each slat's own band
    float rip = sway * (0.12 * sin(j * 0.42 - ph * 0.5 + y * 1.3) + (0.05 + 0.05 * b) * sin(t * 0.4 + j * 0.47 + y * 1.6));

    return flip + swell + rip;
}

vec3 pcPhoto(vec2 c, VisualUniforms u, float aspect) {
    vec2 iuv = vec2(c.x / (2.0 * PC_H * aspect) + 0.5, 0.5 - c.y / (2.0 * PC_H));
    iuv = photoCover(clamp(iuv, vec2(0.001), vec2(0.999)), u.resolution, IMGSIZE);
    vec3 ph = max(IMG(clamp(iuv, vec2(0.001), vec2(0.999))).rgb, vec3(0.0));
    return ph * ph * (0.7 + 0.6 * ph);   // stored values to linear light, with a little extra contrast
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    p.y = -p.y;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float detail = osDetail(u);
    float t = mod(u.time, 600.0);
    PcPal P = pcPalLoad(u);

    float n = floor(mix(16.0, 42.0, u.param0));
    float sway = mix(0.45, 1.5, u.param1);
    float depthAmt = mix(0.3, 1.0, u.param2);
    float halfW = PC_H * aspect + 0.35;        // the curtain runs past the photo
    float w = 2.0 * halfW / n;

    // camera: a slow lateral glide and yaw on the shared speed profile
    vec2 fl = osFlight(u, 0.0, 0.03);
    fl.x += 0.15 * u.time;

    float ph = fl.x * 0.035;
    vec3 ro = vec3(0.55 * sin(ph), 0.08 * sin(ph * 0.71 + 1.3), -2.7 + 0.25 * sin(ph * 0.53));
    vec3 ta = vec3(0.12 * sin(ph - 0.6), 0.0, 0.0);
    vec3 rd = osCamera(ro, ta, 0.0, 2.35, p);
    // builds and bursts: 0 at cruise, 1 in a burst; it shifts the grade and the sheen
    float build = saturate((fl.y - 1.0) / 3.0);
    float hue = 0.04 * build + 0.05 * u.spectralCentroid;

    // the turning wave front, in slat units
    float cyc = n + 16.0;
    vec2 fr = vec2(mod(fl.x + 12.0, cyc) - 3.0, n + 4.0 - mod(fl.x + 12.0 + 0.5 * cyc, cyc));
    float rph = fl.x;

    // slat near the ray at the pivot plane, then nearby candidates
    float tz = -ro.z / max(rd.z, 1e-3);
    vec3 pz = ro + rd * tz;
    float j0 = floor((pz.x + halfW) / w);
    int rad = detail > 0.5 ? 2 : 1;
    // the seams breathe with the bass
    float gap = 0.94;

    float best = 1e4;
    float hj = -1.0, hs = 0.0, ha = 0.0, hfront = 1.0, hb = 0.0;
    vec3 hp = vec3(0.0);
    for (int k = -2; k <= 2; k++) {
        if (k < -rad || k > rad) continue;
        float j = j0 + float(k);
        if (j < 0.0 || j >= n) continue;
        float hsh = hash11(j * 7.31 + 2.0);
        float zj = depthAmt * (0.22 * (hsh - 0.5) + 0.08 * sin(j * 0.9));
        float xj = -halfW + (j + 0.5) * w;
        float b = 0.5 * u.level + 0.1 * bandAt(u, (j + 0.5) / n);
        // y where the ray meets this slat's depth, for the twist
        float ty = (zj - ro.z) / max(rd.z, 1e-3);
        float yj = ro.y + rd.y * ty;
        float a = pcAngle(j, yj, fr, rph, sway, b, t);
        vec3 nf = vec3(sin(a), 0.0, -cos(a));   // print side faces -z at rest
        vec3 tg = vec3(cos(a), 0.0, sin(a));
        float dn = dot(rd, nf);
        if (abs(dn) < 1e-4) continue;
        float th = dot(vec3(xj, 0.0, zj) - ro, nf) / dn;
        if (th <= 0.0 || th >= best) continue;
        vec3 h = ro + rd * th;
        float s = dot(h - vec3(xj, 0.0, zj), tg);
        if (abs(s) > 0.5 * w * gap) continue;
        best = th; hj = j; hs = s; ha = a; hp = h; hb = b;
        hfront = dn < 0.0 ? 1.0 : 0.0;
    }

    // key light high on the left, warm rim from behind
    vec3 ld = normalize(vec3(0.75 * sin(t * 0.11), 0.18, -1.0));
    // the backlight: two opposite palette colours, split across the hall
    vec3 hot = pcPal(P, 0.82 + hue);   // stays below the palette's wrap
    vec3 cold = pcPal(P, 0.3 + hue);
    vec3 col;
    float haze = 1.0;
    if (hj < 0.0) {
        // behind the slats: a black hall whose backlit haze burns through the seams
        float tb = (0.45 - ro.z) / max(rd.z, 1e-3);
        vec3 bp = ro + rd * tb;
        vec3 glow = mix(hot, cold, smoothstep(-1.2, 1.2, bp.x + 0.4 * sin(t * 0.07)));
        glow *= glow * 1.4;   // deeper, more saturated light
        float core = exp(-dot(bp.xy * vec2(0.45, 0.8), bp.xy * vec2(0.45, 0.8)));
        // haze streaks rising through the light, and the print's shadow on the back wall
        float streak = vnoise(vec2(bp.x * 7.0 + 0.5 * bp.y, bp.y * 4.5 - t * 0.08));
        haze = (0.12 + 1.8 * streak * streak) * (0.4 + 0.8 * core);
        vec3 back = pcPhoto(bp.xy * 0.9, u, aspect);
        col = glow * (0.004 + 1.3 * core * core * (0.15 + 1.2 * streak * streak))
                * (0.95 + 0.15 * u.level)
            + back * glow * 0.08;
    } else {
        float sn = hs / (0.5 * w);                 // -1..1 across the slat
        // the slat is a shallow curve: bend the normal across its width
        float bend = sn * 0.32;
        float a2 = ha + bend * (hfront > 0.5 ? 1.0 : -1.0);
        vec3 nrm = vec3(sin(a2), 0.0, -cos(a2)) * (hfront > 0.5 ? 1.0 : -1.0);
        vec3 v = -rd;
        float ndv = saturate(dot(nrm, v));
        float fres = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
        vec3 hv = normalize(ld + v);
        float ndh = saturate(dot(nrm, hv));
        float dif = 0.35 + 0.65 * saturate(dot(nrm, ld) * 0.5 + 0.5);
        if (hfront > 0.5) {
            // glossy photo print with a split-tone grade from the palette
            float xs = -halfW + (hj + 0.5) * w + hs;
            vec3 photo = pcPhoto(vec2(xs, hp.y), u, aspect);
            // shadows and mids lean to the palette's cool end, highlights keep their warmth
            float lum = luma(photo);
            vec3 tone = pcPal(P, 0.04 + hue);
            photo = mix(photo, lum * tone * 2.2, (0.3 + 0.25 * build) * (1.0 - smoothstep(0.08, 0.55, lum)));
            photo = max(photo - 0.012, vec3(0.0)) * 1.08;   // deeper blacks
            col = photo * (1.05 * dif) * (0.92 + 0.06 * hb);
            // a spotlight sweeps along the curtain; only its narrow glint runs over the prints
            float sweep = exp(-pcSq(hp.x - 1.6 * sin(t * 0.07 + 0.4 * sin(t * 0.03))) * 1.6);
            col += vec3(1.0, 0.95, 0.88) * pow(ndh, 600.0) * (0.03 + 0.9 * sweep);
            col += mix(pcPal(P, 0.15 + 0.6 * hj / n), cold, 0.4) * fres * 0.35;
        } else {
            // dark anodised back with a thin-film sheen: the colour walks between
            // opposite ends of the palette with viewing angle and height
            float film = 1.6 * (1.0 - ndv) + 0.75 * hp.y + 0.5 * hj / n + hue;
            vec3 tint = pcPal(P, 0.1 + film);
            vec3 tint2 = pcPal(P, 0.55 + film);
            float fband = 0.5 + 0.5 * cos(6.2831853 * (1.3 * film + 0.35 * sn));
            vec3 sheen = mix(tint, tint2, fband * fband);
            float brush = 0.6 + 0.4 * vnoise(vec2(hs * 70.0, hp.y * 2.5 + hj * 3.1));
            col = sheen * (0.015 + 0.10 * dif) * brush;
            col += sheen * (pow(ndh, 18.0) * (1.2 + 0.2 * hb) + pow(ndh, 140.0) * 0.6) * brush;
            col += sheen * fres * (0.25 + 0.35 * brush * brush);
        }
        // emissive seam light on the slat edges, one spectrum band each
        float edge = smoothstep(0.78, 0.98, abs(sn));
        col *= 0.45 + 0.55 * (1.0 - sn * sn);   // the pleat falls into shadow at its edges
        vec3 seamC = mix(pcPal(P, hj / n), hot, 0.35);
        col += seamC * edge * (0.05 + 0.35 * hb * hb);
        // depth haze toward the back slats
        col *= 1.0 - 0.25 * saturate((hp.z + 0.1) * 3.0);
    }

    // where slats stand open the backlight pours through into the haze
    float jc = clamp(j0, 0.0, n - 1.0);
    float bc = hj < 0.0 ? 0.5 * u.level + 0.1 * bandAt(u, (jc + 0.5) / n) : hb;
    float open = abs(sin(pcAngle(jc, pz.y, fr, rph, sway, bc, t)));
    float openSm = 0.0;
    if (detail > 0.5) {
        openSm = abs(sin(pcAngle(clamp(jc + 3.0, 0.0, n - 1.0), pz.y, fr, rph, sway, 0.0, t)))
               + abs(sin(pcAngle(clamp(jc - 3.0, 0.0, n - 1.0), pz.y, fr, rph, sway, 0.0, t)));
    } else {
        openSm = 2.0 * open;
    }
    // the light pours through the gaps; the prints only catch a little of its haze
    float beam = (0.5 * open * open + 0.12 * openSm) * (hj < 0.0 ? 1.1 : 0.35);
    float shimmer = vnoise(vec2(pz.x * 2.5, pz.y * 1.4 - rph * 0.15));
    shimmer = 0.15 + 1.9 * shimmer * shimmer;   // streaky light, deep shadow between the streaks
    vec3 beamC = mix(hot, cold, saturate(0.5 + 0.35 * pz.x + 0.3 * (bc - 0.3)));
    beamC *= beamC * 1.3;
    col += beamC * beam * shimmer * haze * 0.18 * exp(-0.35 * pz.y * pz.y);
    // light from the rod above, falling off to the floor; drifting haze shafts
    col *= 0.72 + 0.4 * smoothstep(-1.4, 1.2, p.y);
    float shaft = vnoise(vec2(p.x * 1.6 - p.y * 0.9 + t * 0.05, t * 0.03));
    if (detail > 0.5) shaft = 0.6 * shaft + 0.4 * vnoise(vec2(p.x * 3.7 - p.y * 2.0 - t * 0.07, 3.0));
    vec3 fog = pcPal(P, 0.7 + hue);
    col += mix(vec3(luma(fog) * 0.62), fog, 0.5) * shaft * shaft * 0.06 * smoothstep(-0.5, 1.2, p.y);
    col *= 0.3 + 0.7 * smoothstep(1.95, 0.55, length(p * vec2(0.85, 1.0)));
    return pcOffRed(max(col, vec3(0.0)));   // linear HDR; the host tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
