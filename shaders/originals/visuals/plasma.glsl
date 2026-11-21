// SPDX-License-Identifier: AGPL-3.0-only
// Plasma.
// A domain-warped, self-folding sheet of ionized gas, lit as a glossy surface.
// Two nested warps of a smooth rotated-octave fbm fold the field into broad lobes,
// shaded on a temperature ramp (black void, vivid body, hot crest). The field
// is also a height: a key light rakes across it, so lobes read as raised,
// wet folds with specular sheen. The palette's opposite hue is the ion colour:
// a sheath on the gas edge and clean pixel-width contour lines that nest
// round every lobe and creep outward, with packets of charge streaming along
// them. The flow advances on the shared 32-beat speed profile, so it
// cruises, surges, brakes and drifts, and the gas runs hotter through bursts;
// the view turns slowly on the eased bank. Bass deepens the fold, mids steer
// the flow, treble frays crests into glints, and each beat sends a crisp
// discharge line through the gas from a re-seeded point, lighting the
// contours it crosses; it eases in and spreads slowly, so it never sweeps a
// large area at once (never a full-frame pulse).
// param0 = Scale ; param1 = Turbulence ; param2 = Filaments

float plzNoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// Rotated octaves: no axis-aligned grain. n octaves (3 or 4), normalised.
float plzFbm(vec2 p, int n) {
    const mat2 R = mat2(0.80, 0.60, -0.60, 0.80);
    float v = 0.0, a = 0.5, s = 0.0;
    for (int i = 0; i < 4; ++i) {
        if (i >= n) break;
        v += a * plzNoise(p);
        s += a;
        p = R * p * 2.03 + vec2(1.7, 9.2);
        a *= 0.5;
    }
    return v / s;
}

// Complementary accent: the colour reflected through the grey axis (a 180
// degree hue turn), renormalised so its brightest channel is 1. Derived from
// the palette, so every palette gets its own opposite.
vec3 plzOpposite(vec3 c) {
    vec3 o = max(vec3(2.0 * dot(c, vec3(0.33333))) - c, vec3(0.0));
    return o / max(max(o.r, max(o.g, o.b)), 0.08);
}

// The palette read once per pixel at its five stops and blended here; the
// library read walks the whole stop table on every call.
struct PlzPalette { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };

PlzPalette plzPalLoad(VisualUniforms u) {
    PlzPalette P;
    P.c0 = palVisual(0.0, u);
    P.c1 = palVisual(0.26, u);
    P.c2 = palVisual(0.52, u);
    P.c3 = palVisual(0.78, u);
    P.c4 = palVisual(0.999, u);
    return P;
}

vec3 plzPal(PlzPalette P, float t) {
    t = fract(t) * 4.0;
    vec3 c = mix(P.c0, P.c1, smoothstep(0.0, 1.0, t));
    c = mix(c, P.c2, smoothstep(1.0, 2.0, t));
    c = mix(c, P.c3, smoothstep(2.0, 3.0, t));
    return mix(c, P.c4, smoothstep(3.0, 4.0, t));
}

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float PLZ_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 plzFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * PLZ_RUN[32] + PLZ_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

vec3 osBody(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float scale = mix(0.62, 1.45, u.param0);
    float turb = mix(0.6, 1.4, u.param1);
    float filGain = mix(0.4, 1.6, u.param2);
    float detail = osDetail(u);
    int oct = detail > 0.5 ? 3 : 2;

    float bass = saturate(u.bass);
    float mid = saturate(u.mid);
    float treble = saturate(u.treble);
    float level = saturate(u.level);

    // Flow distance on the speed profile: the gas advects faster in a burst and
    // nearly stalls in a brake, and the whole sheet drifts past along a slowly
    // turning heading. Audio never moves the view.
    PlzPalette P = plzPalLoad(u);
    vec2 fl = plzFlight(u, 0.7, 0.1);
    float t = fl.x * 0.028;
    float rush = saturate((fl.y - 1.0) / 3.5);
    float heading = 0.6 + 0.05 * u.time * 0.1 + osBank(u, 0.5);
    p = rot2(osBank(u, 0.12) + 0.004 * mod(u.time, 1570.0)) * p;
    vec2 sp = p * scale * 0.55 + vec2(cos(heading), sin(heading)) * t * 2.2;

    // First warp: large lobes. Mids steer them sideways (bounded offset).
    vec2 steer = vec2(0.35, -0.22) * mid;
    vec2 q = vec2(plzFbm(sp + vec2(t, -0.6 * t) + steer, oct),
                  plzFbm(sp + vec2(5.2, 1.3) + vec2(-0.7 * t, t) - steer, oct));

    // Second warp folds the lobes; bass deepens the fold on a smooth swell
    // through the beat (a sharp refold on the kick moves the whole sheet at once).
    float swell = sin(3.14159265 * saturate(u.beatPhase));
    swell *= swell;
    float warp = (1.75 + 0.15 * level + 0.1 * bass * swell) * turb;
    vec2 r = vec2(plzFbm(sp + warp * q + vec2(1.7, 9.2) + 0.8 * t, oct),
                  plzFbm(sp + warp * q + vec2(8.3, 2.8) - 0.9 * t, oct));
    vec2 fp = sp + warp * r;
    // the outer field is smooth (three octaves at most): broad glossy lobes
    // and clean contour lines
    int octO = oct;
    float f = plzFbm(fp, octO);

    // Surface slope: the outer fbm at two offsets with the warp held, which is
    // the dominant term of the true gradient and costs two fbm, not six.
    float e = 0.035;
    float fx = plzFbm(fp + vec2(e, 0.0), octO);
    float fy = plzFbm(fp + vec2(0.0, e), octO);
    vec2 grad = vec2(fx - f, fy - f) / e;

    // Treble adds a fine turbulent fbm to the field (ragged, lacy crests),
    // faded by the field's screen rate so it never aliases.
    float grain = plzFbm(sp * (5.5 + 2.0 * turb) + r * 3.0 + vec2(t * 6.0, -t * 4.0), 2);
    float aa = clamp(1.0 - fwidth(f) * 14.0, 0.2, 1.0);
    float fd = f + (grain - 0.5) * (0.012 + 0.07 * treble) * aa;

    // Palette drifts on builds and bursts: the gas runs hotter (the ramp walks
    // toward its warm end) as the flow surges and cools back in the drift, so
    // colour follows the song's arc.
    float hs = -0.08 * rush + 0.03 * sin(mod(u.time, 600.0) * 0.11);

    // Temperature ramp by density: black void -> vivid body -> hot core.
    // r and q shift the ramp so neighbouring lobes differ in hue.
    float dens = smoothstep(0.4, 0.84, fd);
    vec3 vivid = plzPal(P, 0.71 + 0.07 * r.x + 0.05 * mid + hs);
    vec3 warm = plzPal(P, 0.24 + 0.05 * r.y + hs);
    vec3 deep = plzPal(P, 0.02 + 0.04 * q.x + hs);
    // The opposite of the hot body is the ionisation colour: sheath, field
    // lines and the discharge front glow in it, so every frame carries a
    // complementary pair against black.
    vec3 ion = plzOpposite(mix(warm, vivid, 0.35));
    float shift = 0.22 * (r.x - 0.5);
    vec3 tint = mix(deep, vivid, smoothstep(0.05, 0.45, dens + shift));
    tint = mix(tint, warm, smoothstep(0.58, 1.0, dens - shift) * 0.8);
    // Shadowed folds where the first warp is strongest.
    float shadow = clamp(length(q) * 1.3 - 0.55, 0.0, 0.75);

    // Relief lighting: height grows with density, so hot lobes stand proud.
    float relief = 1.1 * (0.6 + 0.4 * turb) * aa;
    vec3 n = normalize(vec3(-grad * relief, 1.0));
    float la = 2.1 + 0.25 * sin(u.time * 0.07);
    vec3 L = normalize(vec3(cos(la), sin(la), 0.85));
    vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
    float ndl = saturate(dot(n, L));
    float diffuse = mix(0.55, 1.25, ndl);
    float nh = saturate(dot(n, H));
    float spec = pow(nh, 64.0) * 1.1 + pow(nh, 12.0) * 0.06;
    float rim = pow(1.0 - saturate(n.z), 2.0);

    vec3 col = tint * (0.004 + 0.2 * dens + 0.45 * dens * dens * dens) * (1.0 - shadow) * diffuse;

    // Beat discharge: each beat a shock front eases in at a re-seeded point and
    // spreads slowly outward through the gas over the beat, then fades; it lights only
    // the gas it crosses (a thin moving ring, far under a quarter of the frame).
    float bc = mod(u.beatCount, 256.0);
    float ph = saturate(u.beatPhase);
    vec2 seed = (hash22(vec2(bc * 1.37, 7.1)) - 0.5) * vec2(2.6, 1.3);
    float front = length(p - seed) - (0.15 + 0.8 * ph) + (r.x - 0.5) * 0.55 + (f - 0.5) * 0.3;
    float env = pow(1.0 - ph, 1.3) * smoothstep(0.0, 0.3, ph) * (0.6 + 0.3 * bass);
    float wave = exp(-front * front * 220.0) * env;
    float wake = exp(-max(-front, 0.0) * 9.0) * step(front, 0.0) * env * 0.3;
    // the front's own line: a crisp pixel-width core with a tight halo
    float fpx = abs(front) / max(fwidth(front), 1e-4);
    float frontLine = (exp(-fpx * fpx * 0.5) + 0.12 * exp(-front * front * 900.0)) * env * 0.7;
    float accent = swell * bass;

    // Ionized sheath: a thin electric glow where the gas thins into the void.
    // A bright edge with a soft halo in field space: thin where the gas
    // boundary is sharp, diffuse where it thins out slowly.
    float ed = f - 0.355;
    float sheath = exp(-ed * ed * 5000.0) + 0.05 * exp(-abs(ed) * 45.0);
    col += ion * sheath * (0.04 + 0.07 * mid + 0.3 * wave) * (0.4 + 0.6 * smoothstep(0.1, 0.9, r.y));

    // Field lines: fine iso-contours of the inner warp, so they run with the
    // folds like the plasma's magnetic striations, drawn in the ion colour
    // over the body and its fringe. Packets of charge stream along them; they
    // fade with their own screen density, so they never alias, and flare
    // where the discharge front passes.
    // Field lines: evenly spaced iso-contours of the gas density, so they
    // nest round every lobe like a contour map, drawn at a constant pixel
    // width with a soft halo; every fourth is a brighter major line. The
    // levels creep down the slopes with the flow, so the lines stream outward
    // from each hot core. They fade where they would crowd and alias.
    float lp = fd * (9.0 + 3.0 * turb) + fl.x * 0.12;
    float lw = max(fwidth(lp), 1e-4);
    float dpx = abs(fract(lp) - 0.5) / lw;
    float major = 1.0 - step(0.5, mod(floor(lp), 4.0));
    float lines = (exp(-dpx * dpx * 0.6) + 0.12 * exp(-dpx * 0.35)) * (1.0 - smoothstep(0.12, 0.3, lw))
                * (0.45 + 0.9 * major);
    float body = smoothstep(0.06, 0.3, dens) * (1.0 - 0.75 * smoothstep(0.65, 1.0, dens));
    float stream = 0.5 + 0.5 * sin(dot(fp, vec2(3.1, -2.3)) * 2.2 + r.x * 9.0 - fl.x * 0.9);
    stream *= stream;
    stream *= stream * stream;
    float lineGain = (0.2 + 1.3 * stream * (0.4 + 0.6 * level) + 1.0 * wave + 0.1 * wake) * filGain;
    col += mix(ion, vec3(1.0), 0.18 * stream) * lines * body * lineGain * (1.0 - 0.6 * shadow);

    float crest = smoothstep(0.74, 0.92, fd);
    // Hot crest colour: palette warm end, only slightly lifted toward white so
    // it stays saturated.
    vec3 hot = mix(plzPal(P, 0.30 + 0.08 * r.y + hs), vec3(1.0, 0.94, 0.86), 0.12);
    float heat = 0.65 + 0.25 * level + 0.1 * accent + 0.25 * wave / (0.15 + luma(hot));
    col += hot * crest * crest * crest * heat * filGain * mix(0.8, 1.2, ndl);

    // Specular sheen in the hot colour, strongest on the dense body.
    vec3 specCol = mix(hot, vec3(1.0, 0.97, 0.92), 0.08);
    float wet = smoothstep(0.3, 0.8, dens) * (1.0 - 0.6 * shadow);
    col += specCol * spec * wet * (0.22 + 0.18 * level + 0.25 * rush + 0.15 * wave);
    // Rim: the steep flanks of each lobe catch the ion-coloured back light.
    col += ion * rim * rim * smoothstep(0.05, 0.5, dens) * (0.06 + 0.08 * mid) * (1.0 - shadow);

    // The discharge front itself: the gas it crosses flares in the ion colour.
    col += mix(ion, vec3(1.0), 0.3) * frontLine * smoothstep(0.0, 0.25, dens) * (0.5 + 0.4 * level) * (1.0 - 0.5 * shadow);
    col += ion * wave * smoothstep(0.0, 0.25, dens) * 0.08;

    // Treble glints: the fine turbulence catches light inside the lobes.
    float glint = smoothstep(0.70, 0.86, grain) * dens * dens * aa;
    col += mix(ion, hot, 0.5) * glint * treble * 0.15 * filGain * (0.6 + 0.8 * nh);

    // Faint ion haze in the voids so silence is never dead black.
    col += ion * 0.003 * (1.0 - dens) * (1.0 - shadow);

    // Calm-but-alive in silence, gentle lift with level.
    col *= 0.85 + 0.25 * level;

    return col; // LINEAR HDR — post chain tonemaps
}

// Reds stay off saturated red through the vivid present (common.glsl).
vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }
