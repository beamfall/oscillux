// SPDX-License-Identifier: AGPL-3.0-only
// Tunnel.
// A flight down a curving tube of pleated, translucent membrane lit from
// behind, like the inside of a vast paper lantern. Coloured light strips wind
// round the outside of the tube and glow through it in soft bands; every
// chevron pleat catches that backlight on one facet and turns the other away,
// so the folds read as a crisp faceted relief, and the dark lantern frame
// (rings and battens) stands out in silhouette between the bands. Slow packets
// of light travel along the strips, each pleat column brightens a little with
// its own spectrum band, and the strip colours drift slowly through the
// palette on the clock. The camera glides down the tube at a steady pace and
// leans only gently into the curves, with no banking or beat-timed roll. Audio
// drives only light, and only a little: the level and spectrum lift the strips
// and the pleat columns a few percent, so the lantern never pulses as a whole.
// Under the vivid palette tour the colours change hue but keep their brightness.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 = Flight Speed ; param1 = Twist (strip spiral) ; param2 = Pleat Count

const float TU_R = 3.0;      // tube radius at the inner folds
const float TU_PZ = 1.7;     // chevron period along the tube
const float TU_PA = 0.17;    // pleat depth
const float TU_RIB = 3.4;    // lantern frame ring pitch
const float TU_NS = 4.0;     // light strips round the outside

vec2 tuPath(float z) {
    return vec2(4.5 * sin(z * 0.075) + 1.5 * sin(z * 0.13 + 1.3),
                2.5 * sin(z * 0.06 + 0.7) + 0.8 * sin(z * 0.11));
}

vec2 tuPathD(float z) {
    return vec2(4.5 * 0.075 * cos(z * 0.075) + 1.5 * 0.13 * cos(z * 0.13 + 1.3),
                2.5 * 0.06 * cos(z * 0.06 + 0.7) + 0.8 * 0.11 * cos(z * 0.11));
}

float tuTri(float x) { return abs(fract(x) - 0.5) * 2.0; }

// Outward pleat displacement: chevron folds, np around the tube.
float tuPleat(vec2 q, float z, float np) {
    float a01 = atan2_(q.y, q.x) / 6.2831853 + 0.5;
    float u = a01 * np + 0.55 * (tuTri(z / TU_PZ) - 0.5);
    return TU_PA * tuTri(u);
}

// Distance to the membrane, positive in the air.
float tuMap(vec3 p, float np) {
    vec2 q = p.xy - tuPath(p.z);
    return TU_R + tuPleat(q, p.z, np) - length(q);
}

float tuMarch(vec3 ro, vec3 rd, int n, float np) {
    float t = 0.05;
    for (int i = 0; i < 128; i++) {
        if (i >= n) break;
        float d = tuMap(ro + rd * t, np);
        if (d < 0.0015 * t) return t;
        t += d * 0.8;
        if (t > 90.0) break;
    }
    return t;
}

// The palette read: the visual's own palette with no beat or spectral nudge.
// The vivid tour swaps whole palettes of very different brightness every few
// seconds, which swells the light across the frame, so this visual keeps its
// own colours there (as the calm visuals do); a host's manifest palette still
// replaces them.
vec3 tuPal(float t, VisualUniforms u) { return osPalCalm(t, 2, u); }

// Smooth cycle through four palette stops.
vec3 tuCyc(float h, vec3 a, vec3 b, vec3 c, vec3 d) {
    float x = fract(h) * 4.0;
    vec3 r = mix(a, b, smoothstep(0.0, 1.0, x));
    r = mix(r, c, smoothstep(1.0, 2.0, x));
    r = mix(r, d, smoothstep(2.0, 3.0, x));
    return mix(r, a, smoothstep(3.0, 4.0, x));
}

// Soft single line at d == 0 of half width hw with footprint w.
float tuBar(float d, float hw, float w) {
    w = max(w, 1e-4);
    return saturate((hw - abs(d)) / w + 0.5);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float tt = mod(u.time, 600.0);

    float cruise = mix(6.0, 20.0, u.param0);
    vec2 fl = osFlight(u, 0.0, 0.0);
    fl.x += 0.012 * cruise * u.time;
    float z = mod(fl.x, 2400.0);   // the path is not periodic; wrap far apart
    float twist = mix(0.0, 0.06, u.param1);
    float np = floor(mix(14.0, 30.0, u.param2) + 0.5);

    vec3 ro = vec3(tuPath(z) + vec2(0.0, -0.35), z);
    vec3 ta = vec3(tuPath(z + 8.0) + vec2(0.0, -0.15), z + 8.0);
    vec2 bend = tuPath(z + 16.0) - 2.0 * tuPath(z + 8.0) + tuPath(z);
    float roll = -0.25 * bend.x;
    float fov = 1.2;
    vec3 rd = osCamera(ro, ta, roll, fov, p);
    float px = 2.0 / (u.resolution.y * fov);

    // palette read once at fixed stops, blended locally
    vec3 cA = tuPal(0.02, u);
    vec3 cB = tuPal(0.25, u);
    vec3 cC = tuPal(0.50, u);
    vec3 cD = tuPal(0.77, u);
    // the strip colours walk on the clock, not the beat counter, which can jump
    // when the beat tracker re-locks and would recolour every strip at once
    float hue = tt / 24.0;

    // a fixed step count: the image must not change when the host lowers detail
    float t = tuMarch(ro, rd, 72, np);
    vec3 pos = ro + rd * t;
    vec2 q = pos.xy - tuPath(pos.z);
    float r = max(length(q), 1e-4);
    vec2 er = q / r;
    float a = atan2_(q.y, q.x);
    float a01 = a / 6.2831853 + 0.5;

    // ---- analytic pleat normal, creases softened to the pixel footprint ----
    float zz = pos.z / TU_PZ;
    float zig = tuTri(zz) - 0.5;
    float uu = a01 * np + 0.55 * zig;
    float cosv = saturate(dot(-rd, vec3(-er, 0.0)));
    float foot = t * px / max(cosv, 0.12);                  // world units per pixel on the wall
    float fu = foot * np / (6.2831853 * TU_R) + 0.002;
    float fz = foot / TU_PZ + 0.002;
    float gu = fract(uu) - 0.5;
    float gz = fract(zz) - 0.5;
    float su = gu / (abs(gu) + 1.5 * fu);                   // smoothed sign of the facet slope
    float sz = gz / (abs(gz) + 1.5 * fz);
    float dhdu = TU_PA * 2.0 * su;
    float dudz = 0.55 * 2.0 / TU_PZ * sz;
    vec3 ea = vec3(-er.y, er.x, 0.0);
    vec3 nOut = normalize(vec3(er, -dot(er, tuPathD(pos.z)))
                        - ea * dhdu * np / (6.2831853 * r)
                        - vec3(0.0, 0.0, 1.0) * dhdu * dudz);
    float fine = saturate(1.0 - fu * 1.5);                  // detail that survives the footprint

    // ---- backlight: strips winding round the outside of the tube ----
    vec3 back = vec3(0.0);
    vec3 avgC = vec3(0.0);
    for (int k = 0; k < 4; k++) {
        float fk = float(k);
        float th = (fk + 0.5) * 6.2831853 / TU_NS + twist * pos.z + 0.04 * tt + 0.2 * sin(tt * 0.12 + fk * 1.7);
        vec2 sxy = vec2(cos(th), sin(th)) * (TU_R + 0.9);
        vec3 Ls = vec3(sxy - q, 0.0);
        float dl = length(Ls);
        float fall = exp(-dl * dl * 0.2) + 0.25 * exp(-dl * dl * 1.6);
        float facet = saturate(dot(nOut, Ls / max(dl, 1e-4)));
        float tr = fall * (0.42 + 0.6 * facet * facet);
        // strip level: its spectrum band and slow packets travelling along it
        float bk = bandAt(u, 0.08 + 0.24 * fk);
        float pk = pow(0.5 + 0.5 * sin(pos.z * 0.22 - tt * (0.2 + 0.05 * fk) + fk * 2.1), 8.0);
        float lvl = 0.66 + 0.05 * u.level + 0.02 * bk + pk * (0.2 + 0.03 * u.treble);
        vec3 sc = tuCyc(hue + fk * 0.31, cA, cB, cC, cD);
        back += sc * tr * lvl;
        avgC += sc * lvl;
    }

    // each pleat column brightens with its own spectrum band
    float col01 = fract((floor(uu) + 0.5) / np);
    float colB = bandAt(u, abs(col01 * 2.0 - 1.0));
    back *= 0.98 + 0.03 * colB * fine + 0.015 * (1.0 - fine);

    // lantern frame behind the paper: rings and battens in soft silhouette
    float rz = (fract(pos.z / TU_RIB) - 0.5) * TU_RIB;
    float ba = (fract(a01 * 6.0) - 0.5) * 6.2831853 * TU_R / 6.0;
    float frame = max(tuBar(rz, 0.05, foot + 0.05), tuBar(ba, 0.035, foot + 0.05) * 0.85);
    // paper fibre and a double layer along each crease
    float fibre = 1.0 + 0.22 * (vnoise(vec2(a01 * 260.0, pos.z * 7.0)) - 0.5) * fine;
    float crease = 1.0 - 0.2 * (1.0 - smoothstep(0.0, 0.06 + fu, abs(gu))) * fine
                       + 0.25 * (1.0 - smoothstep(0.0, 0.05 + fu, 0.5 - abs(gu))) * fine;
    vec3 col = back * fibre * crease * (1.0 - 0.45 * frame);

    // the glowing tube lights its own inner face a little
    col += avgC * 0.012 * (0.4 + 0.6 * saturate(-dot(rd, nOut)));
    // a faint sheen where the lit paper turns toward the eye
    col += back * 0.25 * pow(saturate(dot(reflect(rd, -nOut), vec3(-er, 0.0))), 6.0) * fine;

    // ---- dark interior haze, warmed by the strips ----
    vec3 hazeCol = avgC * 0.035;
    float fog = 1.0 - exp(-t * 0.035);
    col = mix(col, hazeCol, fog);

    return col; // LINEAR HDR
}
