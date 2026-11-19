// SPDX-License-Identifier: AGPL-3.0-only
// Loom — "The Song, Woven"
// A tapestry plane receding to the horizon. The shuttle lays fresh weft from
// the live spectrum at the near edge; PREV is resampled with a small backward
// shift along the fabric direction so already-woven rows genuinely persist
// and recede — feedback = history. bassImpact ripples travel back through
// the cloth. Weave rows come from beat periodicity; chorus sections
// (beatCount/16) weave in a metallic thread. Individual warp strands are
// discrete band-driven threads with black gaps between them.
// param0 = Weave Density ; param1 = Scroll ; param2 = Ripple

vec3 visual(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float px = (uv.x * 2.0 - 1.0) * aspect;
    float pyUp = 1.0 - 2.0 * uv.y;

    float density = mix(24.0, 64.0, u.param0);
    float scroll = mix(0.35, 1.20, u.param1);
    float rippleAmt = mix(0.3, 1.6, u.param2);

    float f = 0.62, tilt = 0.50, camH = 1.15;
    vec3 rd = normalize(vec3(px * f, pyUp * f - tilt, 1.0));

    vec3 col = vec3(0.0);
    vec3 skyCol = palVisual(0.55 + 0.15 * u.spectralCentroid, u);

    if (rd.y < -0.02) {
        float tt = camH / (-rd.y);
        float x = rd.x * tt;
        float z = rd.z * tt;
        float across = x / 2.6 + 0.5;

        if (across > 0.0 && across < 1.0) {
            float shuttleZ = 1.18;

            // bass ripple traveling back through the woven history, driven by a
            // ~170 ms swell after each beat scaled by level: the instant kick
            // envelopes it used to follow lit and slid the whole cloth at once
            float bp = u.beatPhase;
            float swell = smoothstep(0.0, 0.34, bp) * (1.0 - smoothstep(0.34, 1.0, bp)) * u.level;
            float ripple = sin(z * 2.6 - u.time * 4.0)
                         * swell * rippleAmt * exp(-max(z - shuttleZ, 0.0) * 0.55);

            // ---- history: reproject where this cloth point was last frame ----
            float dtc = clamp(u.dt, 0.008, 0.05);
            float zp = max(z - scroll * dtc * 60.0 * 0.045, 0.30);
            // a small sideways sway: at 0.05 a bass hit slid the history a whole
            // strand pitch, flipping every thread on screen
            float xs = x + ripple * 0.006;
            float pxp = xs / (zp * f);
            float syp = (tilt - camH / zp) / f;
            vec2 uvPrev = vec2((pxp / aspect + 1.0) * 0.5, (1.0 - syp) * 0.5);
            vec3 history = PREV(clamp(uvPrev, vec2(0.0), vec2(1.0))).rgb;
            float hl = luma(history);
            // fade accelerates with distance (far cloth reprojects nearly
            // onto itself and would otherwise accumulate to white) + hard
            // whiteout guard
            // linear floor subtraction kills the diffused wash (real blacks
            // between threads) while bright strands survive as trails
            history = max(history - vec3(0.030), vec3(0.0));
            history *= mix(0.94, 0.55, smoothstep(1.8, 7.0, z));
            history *= 1.0 - 0.45 * smoothstep(0.8, 2.0, hl);

            // ---- fresh weave at the shuttle: discrete band-driven strands ----
            float strand = across * density;
            float sid = floor(strand);
            float bandE = bandAt(u, (sid + 0.5) / density);
            float thick = bandE * bandE;

            // thin warp filaments, black gaps between threads
            // band energy fattens the thread rather than pumping its brightness
            float warpLine = pow(abs(sin(strand * 3.14159265)), mix(12.0, 7.0, thick));
            // weft rows laid two per beat, marching back with the cloth
            float rowPhase = (u.beatCount + u.beatPhase) * 1.0 - z * 3.2;
            float rid = floor(rowPhase);
            float weftLine = pow(abs(sin(rowPhase * 3.14159265)), 14.0);
            float knot = warpLine * weftLine;

            vec3 warpCol = palVisual(0.12 + fract(sid * 0.113) * 0.55
                                     + 0.10 * u.spectralCentroid, u);
            warpCol = accentize(warpCol, u.accent, 0.12);
            vec3 weftCol = palVisual(0.16 + fract(rid * 0.171) * 0.28, u);

            // Swings stay modest: every row marches past each pixel several times a
            // second, so a bright weft or onset pump reads as a cloth-wide flicker.
            vec3 fresh = warpCol * warpLine * (0.62 + 0.28 * bandE);
            fresh += weftCol * weftLine * (0.05 + 0.05 * u.level);
            // crossing knots glint, swelling after the beat; kept dim because
            // the history streams them back along the warp several times a second
            fresh += peakWhite(warpCol, 0.25) * knot
                   * (0.15 + 0.05 * swell) * (0.3 + thick);

            // metallic chorus thread: every other 16-beat section gleams
            // eased over a beat: a hard section switch lit the whole cloth at once
            float sx = mod((u.beatCount + u.beatPhase) / 16.0, 2.0);
            float sect = smoothstep(0.94, 1.0, sx) - smoothstep(1.94, 2.0, sx);
            fresh += vec3(1.6, 1.25, 0.62) * weftLine * sect * thick * 0.45;

            // lay fresh cloth in the shuttle band, history beyond it
            float freshMask = 1.0 - smoothstep(shuttleZ, shuttleZ + 0.35, z);
            col = mix(history, fresh, freshMask);

            // ripple sheen glints on displaced rows
            col += palVisual(0.45, u) * abs(ripple) * 0.02;

            // depth haze: the tapestry recedes into darkness
            col *= 1.0 - smoothstep(4.0, 14.0, z) * 0.06;

            // the shuttle: bright line where thread is being laid
            float sh = exp(-abs(z - shuttleZ) * 45.0);
            vec3 shuttleCol = peakWhite(palVisual(0.30 + 0.20 * u.spectralCentroid, u), 0.12);
            col += shuttleCol * sh * (0.85 + 0.35 * swell) * (0.25 + bandE);
        }

        // fabric edges fall off into darkness
        col *= smoothstep(0.0, 0.06, across) * smoothstep(1.0, 0.94, across);
    } else {
        // dark sky: faint accent haze at the horizon
        float horizon = exp(-abs(rd.y + 0.02) * 20.0);
        col = skyCol * horizon * 0.20 * (0.35 + u.amplitude);
    }

    return col; // LINEAR HDR — PREV of this output is the woven history
}
