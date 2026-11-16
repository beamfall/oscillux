// SPDX-License-Identifier: AGPL-3.0-only
// Dunes.
// A low, fast skim over a sea of sharp-crested dunes at sunset. The low sun
// rakes across the slip faces, so every ridge splits into a burning lit side
// and a cool shadow side; sand streams off the crests in the wind; heat haze
// shimmers and pools into a mirage at the horizon under a banded, cloud-torn
// sky. The camera's speed follows a 32-beat profile of cruise, build, burst,
// brake and drift, and the roll eases to a new side every eight beats. Audio
// drives the light: the bass lifts the crest streams, the spectrum fans the
// sun's rays across the sky and lights the crests by position, treble glints
// the sand.
// param0 = Speed ; param1 = Height (dune height) ; param2 = Dune Density

float dnPath(float z) { return 30.0 * sin(z * 0.006) + 12.0 * sin(z * 0.017 + 2.0); }

// Broad swells the dune field rides on.
float dnSwell(vec2 p) { return 3.0 * sin(p.x * 0.011 + 1.0) * sin(p.y * 0.008) + 2.0 * sin(p.y * 0.005 + p.x * 0.003); }

// Asymmetric dune profile: a long windward rise to a sharp crest at s = 0.72,
// then a steep slip face.
float dnProfile(float q) {
    float s = fract(q);
    float up = s / 0.72;
    up = up * up * (1.6 - 0.6 * up);
    float dn = (1.0 - s) / 0.28;
    return s < 0.72 ? up : dn * dn * (3.0 - 2.0 * dn);
}

// Ridge coordinate: crests run diagonally across the flight path and
// meander; the slip faces look along +DN_WIND.
const vec2 DN_WIND = vec2(0.5, -0.866);

float dnHeight(vec2 p, float amp, float dens, out float ridge) {
    float w1 = vnoise(p * 0.018);
    float w2 = vnoise(p * 0.05 + 3.0);
    // a slow field-scale noise bends the rows and sets their size, so the
    // distant crests never stack into even bands
    float w0 = 0.5 + 0.28 * sin(dot(p, vec2(0.0061, 0.0023)) + 1.7) + 0.22 * sin(dot(p, vec2(-0.0019, 0.0073)) + 4.1);
    float warp = 9.0 * w1 + 4.0 * w2 + 30.0 * w0;
    ridge = (dot(p, DN_WIND) + 12.0 * sin(dot(p, vec2(0.866, 0.5)) * 0.025 + 1.3) + warp) * dens / 22.0;
    float h = dnProfile(ridge) * (0.3 + 0.45 * w1 + 0.35 * w0);
    // a smaller crossing set breaks the rows into linked crescents
    float q2 = (dot(p, vec2(0.94, -0.34)) + warp * 0.8) * dens / 10.0;
    h = -osSmin(-h, -0.32 * dnProfile(q2), 0.12);
    return h * amp + dnSwell(p);
}

float dnH(vec2 p, float amp, float dens) {
    float r;
    return dnHeight(p, amp, dens, r);
}

vec3 dnSky(vec3 rd, vec3 sunDir, VisualUniforms u, float tm) {
    float h = rd.y;
    float sd = saturate(dot(rd, sunDir));
    float sdw = saturate(dot(normalize(vec3(rd.x, 0.0, rd.z) + 1e-4), normalize(vec3(sunDir.x, 0.0, sunDir.z))));
    vec3 hot = palVisual(0.58, u) * vec3(1.25, 0.7, 0.45);
    vec3 band = palVisual(0.3, u) * vec3(0.9, 0.3, 0.42) + vec3(0.06, 0.0, 0.05);
    vec3 zen = vec3(0.008, 0.012, 0.05) + palVisual(0.1, u) * 0.015;
    // the horizon burns toward the sun and cools to crimson away from it
    vec3 hor = mix(band * 0.9, hot, pow(sdw, 3.0));
    vec3 col = mix(hor, band * 0.5, smoothstep(0.0, 0.12, h));
    col = mix(col, zen, smoothstep(0.06, 0.5, h));
    // the sun: a white-hot disc in an amber glow
    col += hot * pow(sd, 14.0) * 0.5 + palVisual(0.85, u) * pow(sd, 120.0) * 1.6;
    col += vec3(7.0, 5.2, 3.2) * smoothstep(0.99925, 0.99955, sd);
    // rays fanned around the sun, each lit by its spectrum band
    vec3 sx = normalize(cross(sunDir, vec3(0.0, 1.0, 0.0)));
    vec3 sy = cross(sx, sunDir);
    float ang = atan2_(dot(rd, sy), dot(rd, sx));
    float fan = ang * 0.15915 + 0.5;
    float ray = vnoise(vec2(fan * 44.0, tm * 0.08));
    ray = smoothstep(0.4, 0.95, ray);
    float rb = bandAt(u, abs(fract(fan * 2.0) * 2.0 - 1.0));
    col += hot * ray * (0.04 + 0.5 * rb) * pow(sd, 7.0) * smoothstep(-0.02, 0.06, h);
    // torn cloud bands: dark bellies with burning edges toward the sun
    // high cirrus: long thin wind-combed streaks, dark undersides and
    // hairline silver-gold edges, instead of soft painted cloud
    vec2 cp = rd.xz / max(h + 0.05, 0.03);
    vec2 cq = cp * vec2(0.22, 1.9) + vec2(tm * 0.015, 0.0);
    cq.y += 0.9 * vnoise(cp * 0.35);
    float c = vnoise(cq) * 0.62 + vnoise(cq * vec2(2.3, 3.1) + 4.0) * 0.38;
    float cm = smoothstep(0.6, 0.7, c) * smoothstep(0.08, 0.16, h) * (1.0 - smoothstep(0.25, 0.55, h));
    float edge = smoothstep(0.6, 0.65, c) - smoothstep(0.65, 0.76, c);
    vec3 cl = mix(vec3(0.02, 0.01, 0.035) + band * 0.08, hot * 0.35, pow(sd, 3.0));
    cl += hot * edge * (0.5 + 3.0 * pow(sd, 5.0));
    col = mix(col, cl, cm * 0.85);
    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float tm = mod(u.time, 600.0);

    float speed = mix(6.0, 18.0, u.param0);
    float amp = mix(1.6, 4.4, u.param1);
    float dens = mix(0.6, 1.5, u.param2);
    vec2 fl = osFlight(u, speed, 1.8 * mix(0.5, 1.5, u.param0));
    float z = fl.x;
    float rush = saturate((fl.y - 1.0) / 3.5);
    float lull = saturate(1.0 - fl.y);
    vec3 ro = vec3(dnPath(z), 0.0, z);
    // ride the broad swell, clear of every crest; the audio never moves it
    ro.y = dnSwell(ro.xz) + amp * 1.6 + 2.2;
    vec3 ta = vec3(dnPath(z + 24.0), 0.0, z + 24.0);
    ta.y = dnSwell(ta.xz) + amp * 1.0 + 0.8;
    float roll = osBank(u, 0.12) - 0.01 * (dnPath(z + 30.0) - 2.0 * dnPath(z + 15.0) + dnPath(z));
    float fov = 1.35 - 0.2 * rush + 0.08 * lull;
    vec3 rd = osCamera(ro, ta, roll, fov, p);

    // heat haze: a shimmer that thickens toward the horizon
    float shimmer = exp(-abs(rd.y) * 22.0);
    rd.y += shimmer * 0.0035 * (vnoise(vec2(p.x * 22.0, p.y * 90.0 - tm * 6.0)) - 0.5);
    rd = normalize(rd);

    vec3 sunDir = normalize(vec3(-0.62, 0.075, 1.0));
    float par = mod(floor(u.beatCount), 2.0);
    vec3 col = vec3(0.0);

    float tmax = 520.0;
    float t = 0.3;
    float tPrev = t;
    float hit = 0.0;
    float spray = 0.0;
    int nMax = osSteps(44.0, 92.0, detail);
    for (int i = 0; i < 92; i++) {
        if (i >= nMax) break;
        vec3 pos = ro + rd * t;
        float rg;
        float dh = pos.y - dnHeight(pos.xz, amp, dens, rg);
        if (dh < 0.0015 * t) { hit = 1.0; break; }
        if (rd.y >= 0.0 && pos.y > amp * 1.5 + 5.5) break;
        // sand blown off a crest the ray skims over
        float cs = fract(rg) - 0.72;
        float step_ = max(dh * 0.42, 0.02 + 0.008 * t);
        spray += exp(-cs * cs * 500.0 - dh * 3.0) * step_ * exp(-t * 0.012);
        tPrev = t;
        t += step_;
        if (t > tmax) break;
    }
    if (hit > 0.5) {
        for (int i = 0; i < 5; i++) {
            float tb = 0.5 * (t + tPrev);
            vec3 pb = ro + rd * tb;
            if (pb.y - dnH(pb.xz, amp, dens) < 0.0) t = tb; else tPrev = tb;
        }
        vec3 pos = ro + rd * t;
        float ridge;
        float hc = dnHeight(pos.xz, amp, dens, ridge);
        float e = 0.02 + 0.0015 * t;
        vec3 n = normalize(vec3(hc - dnH(pos.xz + vec2(e, 0.0), amp, dens), e,
                                hc - dnH(pos.xz + vec2(0.0, e), amp, dens)));
        // wind ripples, near the camera only
        float rf = saturate(1.0 - t / 45.0);
        float rp = dot(pos.xz, DN_WIND) * 11.0 + 0.9 * sin(dot(pos.xz, vec2(0.866, 0.5)) * 1.7) + 2.0 * vnoise(pos.xz * 0.6);
        float rpl = sin(rp);
        rpl = rpl * abs(rpl);
        n = normalize(n + vec3(DN_WIND.x, 0.0, DN_WIND.y) * rpl * 0.28 * rf);

        // long shadows from the low sun
        float sh = 1.0;
        if (detail > 0.0) {
            float ts = 0.4;
            int ns = osSteps(6.0, 12.0, detail);
            for (int i = 0; i < 12; i++) {
                if (i >= ns) break;
                vec3 ps = pos + sunDir * ts;
                float d = ps.y - dnH(ps.xz, amp, dens);
                sh = min(sh, saturate(8.0 * d / ts));
                if (sh < 0.01) break;
                ts += max(d * 0.6, 0.6 + 0.18 * ts);
            }
        }
        // cloud shadows roll across the field with the wind
        float cloud = smoothstep(0.42, 0.72, vnoise(pos.xz * 0.011 + vec2(tm * 0.55, tm * 0.2)));
        sh *= 1.0 - 0.75 * cloud;
        float dif = saturate(dot(n, sunDir));
        vec3 sunCol = palVisual(0.6, u) * vec3(1.9, 1.05, 0.6);
        // shade is lit by the burning sky: rose low, violet from above
        // the shade takes the cool sky: lilac on the slopes, deep blue
        // under the crests, the complement of the burning lit sides
        vec3 shadeCol = mix(vec3(0.32, 0.06, 0.42), vec3(0.04, 0.1, 0.62), saturate(n.y * 1.2 - 0.1)) + palVisual(0.2, u) * 0.03;
        vec3 sand = mix(vec3(0.8, 0.46, 0.27), palVisual(0.7, u), 0.35);
        vec3 sandShade = mix(sand, vec3(0.75), 0.5);
        // plus warm light bounced off the sunlit slopes into the shade
        vec3 lit = sand * sunCol * dif * sh * 1.6 + sandShade * shadeCol * 0.38 * (0.85 + 0.3 * rpl * rf)
                 + sand * sunCol * 0.025 * (1.0 - dif * sh) * (0.6 + 0.4 * n.y);
        // glossy sheen: the backlit sand mirrors the sun
        vec3 hv = normalize(sunDir - rd);
        float spec = pow(saturate(dot(n, hv)), 36.0);
        lit += sunCol * spec * (0.25 + 0.5 * sh) * 0.8 * exp(-t * 0.008);

        // the crest line burns, lit by the spectrum across the view
        float s = fract(ridge);
        float crest = exp(-(s - 0.72) * (s - 0.72) * 30000.0 / (1.0 + t * 0.05));
        crest *= 0.35 + 0.65 * hash11(mod(floor(ridge), 512.0) + 0.37);
        float xb = saturate(0.5 + 0.35 * p.x);
        float drive = 0.3 + 1.4 * bandAt(u, 0.05 + 0.8 * xb) + 1.4 * u.bassImpact;
        vec3 crestCol = mix(sunCol * 1.3, palRolePeak(0.8, u), 0.25 + 0.4 * u.bassImpact);
        // far crests break into lit segments and fade, so the rows near the
        // horizon never stack into even bands
        float brk = smoothstep(0.3, 0.7, vnoise(vec2(dot(pos.xz, vec2(0.866, 0.5)) * 0.06, floor(ridge) * 3.7)));
        crest *= mix(1.0, brk, saturate(t / 50.0));
        lit += crestCol * crest * drive * (0.3 + 0.9 * sh) * exp(-t * 0.04);
        // the cool sky rims the shadowed flanks: the complement of the burning
        // crests, flaring on every other beat
        float rim = pow(1.0 - saturate(dot(n, -rd)), 5.0) * saturate(0.2 - 2.0 * dot(n, sunDir)) * sh;
        vec3 cool = mix(vec3(0.2, 0.32, 1.0), palRolePeak(0.3, u), 0.25);
        lit += cool * rim * (0.05 + 0.6 * u.beat * par + 0.15 * u.bassImpact) * exp(-t * 0.01);
        // treble glints in the sand near the camera
        vec2 gc = floor(pos.xz * 26.0);
        float g = step(0.992, hash21(gc + floor(mod(tm * 6.0, 100.0)))) * rf * sh * (0.15 + 4.0 * spec + dif);
        lit += vec3(4.5, 3.6, 2.4) * g * (0.3 + 2.0 * u.treble);

        // dusty aerial perspective, warm toward the sun
        float fog = 1.0 - exp(-t * 0.0055);
        // far rows melt into the dust so the horizon never stacks into bands
        fog = max(fog, 0.75 * smoothstep(70.0, 260.0, t));
        vec3 dust = mix(palVisual(0.3, u) * vec3(0.35, 0.12, 0.16), palVisual(0.6, u) * 0.9, pow(saturate(dot(rd, sunDir)), 4.0));
        col = mix(lit, dust, fog);
        // the mirage: far sand near the horizon turns into a shimmering sky mirror
        float mir = smoothstep(80.0, 300.0, t) * exp(-abs(rd.y) * 45.0);
        vec3 mrd = normalize(vec3(rd.x, abs(rd.y) + 0.01, rd.z));
        if (mir > 0.01) col = mix(col, dnSky(mrd, sunDir, u, tm) * 0.9, mir * 0.85);
    } else {
        col = dnSky(rd, sunDir, u, tm);
    }
    // blown sand glowing in the low sun, streaked by the wind
    float sw = 0.3 + 1.2 * vnoise(vec2(p.x * 7.0 - tm * 2.5, p.y * 4.0 + tm * 0.5));
    col += palVisual(0.62, u) * vec3(1.3, 0.8, 0.5) * spray * sw * (0.06 + 0.25 * u.bass + 0.45 * u.bassImpact)
         * (0.4 + 1.2 * pow(saturate(dot(rd, sunDir)), 2.0));
    // the low sun's glare spills over the dunes, lifted a little by the beat
    col += palVisual(0.6, u) * pow(saturate(dot(rd, sunDir)), 40.0) * (0.15 + 0.25 * u.bassImpact);
    return col; // LINEAR HDR — post chain tonemaps
}
