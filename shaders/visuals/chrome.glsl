// SPDX-License-Identifier: AGPL-3.0-only
// Chrome / black-studio liquid metal.
// Dark metaballs reflect sparse neon softboxes. Most of the surface stays dark;
// only reflected strips, Fresnel rim, and transient glints enter HDR.
// param0 = Blob Count ; param1 = Reflection ; param2 = Surface Ripple
//
// Flash budget (CORE-2659): no brightness, colour or geometry here follows an instant
// kick/onset/flux/band value or reseeds on the beat. The music arrives through chromeSwell, a
// smooth beat envelope (about 0.4 beat attack, 0.6 beat release, continuous across the beat
// wrap), and through the loudness level. The swell warms and brightens the small bright parts
// (rim, glints, horizon line, pin lights) instead of flashing or resizing the whole metal.

// Smooth beat envelope in [0, 1]: rises over 0.4 beat to a peak just after the kick and falls over
// the rest of the beat, with zero slope at both ends so the wrap at the next beat is seamless.
float chromeSwell(VisualUniforms u) {
    float x = fract(u.beatPhase + 0.35);
    float e = x < 0.4 ? smoothstep(0.0, 0.4, x) : 1.0 - smoothstep(0.4, 1.0, x);
    return e * saturate(u.level * 1.2);
}

float smin_chrome(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / max(k, 1e-5), 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

float sdf_chrome(vec3 p, VisualUniforms u, int nBlobs) {
    // The beat never resizes or moves the metal: every reflection on it would shift at once and
    // the whole surface would flash. The swell lives in the small bright parts instead (rim,
    // glints, horizon line, pin lights); size follows the loudness level only.
    float orbitR = mix(0.40, 0.62, u.level);
    float bassR = 0.03 * u.level;
    float d = 1e9;

    for (int i = 0; i < 7; i++) {
        if (i >= nBlobs) break;

        float fi = float(i);
        float phase = fi * 1.618;
        // Slow per-blob breathing in place of the instant band level.
        float bandEnergy = u.level * (0.55 + 0.45 * sin(u.time * 0.53 + phase * 2.1));

        vec3 center = vec3(
            sin(u.time * 0.42 + phase) * orbitR * (0.65 + bandEnergy * 0.30),
            cos(u.time * 0.36 + fi * 1.3) * orbitR * 0.42,
            sin(u.time * 0.31 + fi * 0.9) * orbitR * 0.34
        );

        float radius = 0.40 + bandEnergy * 0.11 + bassR;
        float blob = length(p - center) - radius;
        d = (i == 0) ? blob : smin_chrome(d, blob, 0.32);
    }

    return d;
}

vec3 calcNormal_chrome(vec3 p, VisualUniforms u, int nBlobs) {
    const float e = 0.001;
    vec3 n = vec3(
        sdf_chrome(p + vec3(e, 0.0, 0.0), u, nBlobs) - sdf_chrome(p - vec3(e, 0.0, 0.0), u, nBlobs),
        sdf_chrome(p + vec3(0.0, e, 0.0), u, nBlobs) - sdf_chrome(p - vec3(0.0, e, 0.0), u, nBlobs),
        sdf_chrome(p + vec3(0.0, 0.0, e), u, nBlobs) - sdf_chrome(p - vec3(0.0, 0.0, e), u, nBlobs)
    );
    float len = length(n);
    return len > 1e-6 ? n / len : vec3(0.0, 1.0, 0.0);
}

vec3 envChromeR2(vec3 r, VisualUniforms u, float swell) {
    float phi = atan2_(r.z, r.x);
    float y = r.y;
    vec3 env = vec3(0.0);

    // Vertical studio softboxes with soft spill. Bands light each box.
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float a = -2.35 + fi * 1.55 + 0.20 * sin(u.time * 0.22 + fi * 2.3);
        float ad = abs(atan2_(sin(phi - a), cos(phi - a)));
        float strip = exp(-ad * ad * 150.0) + exp(-ad * ad * 14.0) * 0.22;
        strip *= smoothstep(-0.88, -0.22, y) * (1.0 - smoothstep(0.55, 0.90, y));
        // Each box swells a little on its own share of the beat: a travelling shimmer, not a
        // whole-surface flash.
        float boxSwell = 0.5 + 0.5 * sin(6.2831853 * (u.beatPhase - fi * 0.25));
        float boxE = 0.85 + 0.45 * u.level + 0.18 * swell * boxSwell;
        env += palVisual(0.06 + fi * 0.21 + 0.09 * u.spectralCentroid, u) * strip * 2.6 * boxE;
    }

    // Dim colored dome so reflections never read as void.
    env += palVisual(0.55 + 0.10 * u.spectralCentroid + y * 0.10, u)
         * (0.018 + 0.035 * smoothstep(-1.0, 1.0, y)) * (0.6 + 0.8 * u.level);

    // A low horizon glow line in the palette's accent, warming and swelling gently on the beat.
    float horizon = exp(-abs(y + 0.10) * 90.0);
    vec3 horizonCol = mix(palVisual(0.80 + 0.06 * u.spectralCentroid, u) * vec3(0.6, 0.9, 1.1),
                          vec3(1.15, 0.66, 0.30), 0.6 * swell);
    env += horizonCol * horizon * (0.45 + 0.35 * swell);

    // Sparse pin lights for treble: fixed per sector (no reseed on the beat), drifting slowly.
    float sector = floor((phi / 6.2831853 + 0.5) * 42.0);
    float h = hash11(sector * 1.37);
    float pinPhi = h * 6.2831853 - 3.14159265 + 0.05 * sin(u.time * 0.4 + h * 9.0);
    float pinY = hash11(sector * 2.91 + 4.0) * 1.5 - 0.75;
    float pinD = abs(atan2_(sin(phi - pinPhi), cos(phi - pinPhi)));
    float pin = exp(-pinD * pinD * 600.0) * exp(-(y - pinY)*(y - pinY) * 50.0);
    float twinkle = 0.5 + 0.5 * sin(u.time * 1.3 + h * 40.0);
    env += palVisual(h + 0.2 * u.spectralCentroid, u)
         * pin * (0.25 + 0.35 * u.treble) * twinkle * (0.6 + 0.4 * swell);

    return env;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 sp = motionCentered(uv, u);
    float swell = chromeSwell(u);

    int nBlobs = int(mix(3.0, 7.0, u.param0));
    float reflStrength = mix(0.55, 1.35, u.param1);
    float rippleAmt = mix(0.0, 0.16, u.param2);

    vec3 ro = vec3(0.0, 0.10, 2.70);
    vec3 rd = normalize(vec3(sp * 0.86, -1.75));

    float t = 0.0;
    bool hit = false;
    for (int i = 0; i < 96; i++) {
        vec3 p = ro + rd * t;
        float d = sdf_chrome(p, u, nBlobs);
        if (d < 0.002) {
            hit = true;
            break;
        }
        t += d * 0.92;
        if (t > 12.0) break;
    }

    vec3 col = vec3(0.0);

    if (hit) {
        vec3 pos = ro + rd * t;
        vec3 nor = calcNormal_chrome(pos, u, nBlobs);

        // Slow travelling ripple; its depth, not its speed, follows the music.
        float ripplePhase = length(pos.xy) * 11.0 - u.time * 1.4;
        vec3 tangentPerturb = vec3(
            sin(ripplePhase + pos.z * 3.0),
            cos(ripplePhase + pos.x * 2.6),
            sin(ripplePhase * 0.7 + pos.y * 4.0)
        );
        float ripple = sin(ripplePhase) * (0.35 + 0.35 * u.treble + 0.30 * swell) * rippleAmt;
        // fade the perturbation at the silhouette — kills the "fuzz" halo
        ripple *= 0.25 + 0.75 * max(dot(nor, -rd), 0.0);
        vec3 nPerturbed = normalize(nor + tangentPerturb * ripple);

        vec3 refl = reflect(rd, nPerturbed);
        vec3 env = envChromeR2(refl, u, swell) * reflStrength;

        float NoV = max(dot(nPerturbed, -rd), 0.0);
        float fres = pow(1.0 - NoV, 5.0);

        vec3 baseMetal = vec3(0.012, 0.014, 0.020);
        vec3 darkReflection = env * (0.30 + 0.55 * (1.0 - fres));
        // Rim: cool cyan warming to amber on the beat swell (amber, never saturated red, and a
        // thin Fresnel band, so the colour turn stays a small-area change).
        vec3 rimCool = palVisual(0.62 + 0.10 * u.spectralCentroid, u) * vec3(0.55, 0.85, 1.10);
        vec3 rimWarm = vec3(1.20, 0.68, 0.30);
        vec3 rim = mix(rimCool, rimWarm, 0.75 * swell) * fres * (0.65 + 0.55 * swell);

        vec3 glints = vec3(0.0);
        for (int i = 0; i < 8; i++) {
            float fi = float(i);
            // Fixed lights that orbit slowly; no reseed on the beat.
            vec2 h = hash22(vec2(fi * 1.7, 2.0));
            h.x = fract(h.x + u.time * (0.012 + 0.008 * fi));
            vec3 dir = normalize(vec3(
                cos(h.x * 6.2831853) * sqrt(max(0.0, 1.0 - h.y * h.y)),
                h.y * 2.0 - 1.0,
                sin(h.x * 6.2831853) * sqrt(max(0.0, 1.0 - h.y * h.y))
            ));
            float spec = pow(max(dot(reflect(-dir, nPerturbed), -rd), 0.0), 80.0);
            glints += palVisual(fi * 0.13 + u.spectralCentroid * 0.2, u)
                    * spec * (0.30 + 0.30 * u.treble + 0.70 * swell) * 2.4;
        }

        vec3 base = baseMetal;
        // rim stays OUT of the trail: ghosted rims from previous frames read
        // as fuzz around the silhouette. Only the mirror streaks smear.
        vec3 glow = darkReflection + glints;
        vec3 trail = feedbackTrail(glow, uv,
                                   min(u.trailDecay, 0.50),
                                   0.002 + 0.002 * swell,
                                   0.0);
        col = base + trail + rim;
    } else {
        // studio backdrop: the environment itself, dim and defocused, plus a
        // floor glow beneath the sculpture. Keeps the frame composed.
        vec3 bgDir = normalize(rd + vec3(0.0, 0.06 * sin(u.time * 0.1), 0.0));
        // Black studio: the softboxes may be bright in the reflections, but
        // the backdrop itself stays near black for every palette -- scale by
        // the palette's own luminance so pale palettes (Porcelain) do not
        // turn the room mid-grey.
        float palLum = saturate(luma(palVisual(0.5, u)));
        vec3 bg = envChromeR2(bgDir, u, swell) * 0.03 * mix(1.0, 0.4, palLum);
        float floorGlow = exp(-(sp.y - 0.62)*(sp.y - 0.62) * 22.0) * smoothstep(1.4, 0.2, abs(sp.x));
        bg += palVisual(0.12 + 0.1 * u.spectralCentroid, u) * floorGlow
            * (0.03 + 0.02 * swell) * mix(1.0, 0.4, palLum);
        float vig = 1.0 - smoothstep(0.7, 1.9, length(sp)) * 0.7;
        col = bg * vig;
        col = feedbackTrail(col, uv, min(u.trailDecay, 0.50),
                            0.002 + 0.002 * swell, 0.0);
    }

    return col; // LINEAR HDR — post chain tonemaps
}
