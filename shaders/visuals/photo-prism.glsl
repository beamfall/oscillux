// SPDX-License-Identifier: AGPL-3.0-only
// Photo Prism — the photo seen through a slowly turning prism. Full-frame chromatic
// dispersion wedges surround a clean magnified circular waveform lens, so the
// photo stays the hero while the spectrum ring plays the music.
// param0 = Shard Spin ; param1 = Refraction ; param2 = Glow
//
// Flash budget: the music moves the prism (a beat ratchet, dispersion and the
// lens outline) rather than flashing it. The wedges turn slowly enough that the
// seams sweep only a small area per frame, and every beat-driven term rides a
// swell with a ~150 ms attack and a long release (`prismSwell`) instead of the kick's
// instant attack, so no large area changes brightness in one step.

// Beat swell: rises over the last 30% of the beat into the downbeat, releases
// over the first 60%. Equal at beatPhase 0 and 1, so it never steps.
float prismSwell(VisualUniforms u) {
    float p = u.beatPhase;
    float env = p < 0.6 ? 1.0 - smoothstep(0.0, 0.6, p) : smoothstep(0.7, 1.0, p);
    return env * saturate(u.level * 1.2);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float r = length(p);
    float rS = max(r, 1e-3);
    float a = atan2_(p.y, p.x);

    float spinAmt = mix(0.006, 0.055, u.param0);
    float refr    = mix(0.35, 1.30, u.param1);
    float glow    = mix(0.55, 1.60, u.param2);
    float sw      = prismSwell(u);

    // spectrum-driven lens radius (identity: circular waveform lens). The
    // spectrum is mirrored round the circle so the ring has no seam.
    float t = fract(a / 6.2831853 + 0.5 + u.time * 0.02);
    float b = bandAt(u, 1.0 - abs(2.0 * t - 1.0));
    float ringR = 0.46 + b * 0.06 + sw * 0.025;

    // ---- prism wedges (outside the lens) ----
    // a slow drift plus a gentle ratchet each beat, eased so it never jumps
    float ratchet = u.beatCount + smoothstep(0.0, 0.55, u.beatPhase);
    float spin = u.time * spinAmt + ratchet * 0.005;
    float segs = 10.0;
    float wedgeF = (a + spin * 6.2831853) * segs / 6.2831853;
    float wid = floor(wedgeF);
    float wfr = fract(wedgeF);
    float wh = hash11(fract(wid / segs) * 37.7 + 5.1);

    // per-wedge dispersion strength; the beat swell pushes the split harder
    float disp = refr * (0.010 + 0.045 * wh) * (0.85 + 0.5 * b + 0.45 * sw);
    vec2 dir = p / rS;
    vec2 baseUV = uv + dir * 0.010 * sin(u.time * 0.30 + wh * 6.2831853);
    float cr = IMG(photoCover(clamp(baseUV + dir * disp * 1.45, 0.0, 1.0), u.resolution, IMGSIZE)).r;
    float cg = IMG(photoCover(clamp(baseUV + dir * disp * 0.85, 0.0, 1.0), u.resolution, IMGSIZE)).g;
    float cb = IMG(photoCover(clamp(baseUV + dir * disp * 0.30, 0.0, 1.0), u.resolution, IMGSIZE)).b;
    vec3 outPhoto = max(vec3(cr, cg, cb), vec3(0.0));
    // facet lighting so each shard reads as cut glass; a narrower range than
    // before, so a wedge edge sweeping past is a tone change, not a flash
    float facet = 0.70 + 0.18 * wh + 0.16 * sin(wfr * 3.14159);
    outPhoto *= facet;

    // ---- clean magnified photo inside the lens ----
    vec2 lp = p / max(ringR, 1e-3);
    float lr2 = dot(lp, lp);
    vec2 lensUV = (uv - 0.5) * (0.80 + 0.03 * sin(u.time * 0.05));
    lensUV *= 1.0 + 0.14 * lr2; // gentle barrel bulge
    vec3 inPhoto = max(IMG(photoCover(clamp(lensUV + 0.5, 0.0, 1.0), u.resolution, IMGSIZE)).rgb, vec3(0.0));
    inPhoto *= 0.86 + 0.30 * exp(-lr2 * 1.8); // lens hot-center
    inPhoto *= 1.0 - 0.42 * smoothstep(0.55, 1.0, lr2); // glass-edge falloff

    float inside = smoothstep(ringR + 0.012, ringR - 0.012, r);
    vec3 col = mix(outPhoto * 0.55, inPhoto * 0.62, inside);

    // rainbow fringe seams; their glow follows the swell, not the kick's step
    // (analytic AA width: fwidth would read the atan branch cut as a wide line)
    float seamAA = segs / 6.2831853 * 2.0 / (max(u.resolution.y, 1.0) * rS);
    float seam = 1.0 - smoothstep(0.020, 0.020 + seamAA, abs(wfr - 0.5));
    col += palVisual(t + wh * 0.3, u) * seam * (1.0 - inside) * glow * (0.14 + 0.08 * b + 0.16 * sw);

    // ---- HDR spectrum ring ----
    float ring = aaLine(r - ringR, 0.006 + 0.005 * b);
    vec3 ringCol = peakWhite(palVisual(t, u), 0.20 + 0.25 * sw);
    col += ringCol * ring * glow * (1.1 + 0.3 * b + 0.5 * sw);
    // dispersive halo hugging the ring
    col += palVisual(t + 0.15, u) * exp(-abs(r - ringR) * 30.0) * glow * (0.08 + 0.04 * b + 0.06 * sw);

    // cinematic vignette, frame stays full
    col *= 0.30 + 0.70 * smoothstep(1.60, 0.45, r);
    col = feedbackTrail(col, uv, min(u.trailDecay, 0.55), 0.002 + 0.002 * sw, 0.001);
    return col; // LINEAR HDR — post chain tonemaps
}
