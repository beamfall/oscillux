// SPDX-License-Identifier: AGPL-3.0-only
// Glass Album Monoliths — the photo displayed across a skyline of glass
// towers on a wet black floor: the image spans the whole equalizer skyline so
// it reads as one picture, with true mirrored reflection and floor sheen.
// param0 = Towers ; param1 = Height ; param2 = Reflection

float sdRoundRect2(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    p.y = -p.y; // y-up world (display convention: raw +p.y is down-screen)
    float count   = floor(mix(18.0, 34.0, u.param0) + 0.5);
    float hAmt    = mix(0.45, 1.15, u.param1);
    float reflAmt = mix(0.25, 1.00, u.param2);

    float floorY = -0.50;
    vec3 col = vec3(0.003, 0.005, 0.011);

    // wet-floor sheen + horizon glow along the floor line
    float floorGlow = exp(-abs(p.y - floorY) * 9.0);
    col += palVisual(0.62 + 0.06 * u.spectralCentroid, u) * floorGlow
         * (0.05 + 0.14 * u.level);

    float span = 1.62;
    float soft = 0.10;
    // The photo is pinned to the screen, not stretched to each tower's height, so a tower that
    // grows or shrinks only uncovers or covers the picture at its top instead of rescaling it.
    float sky = 1.50;
    float hy = clamp((p.y - floorY) / sky, 0.0, 1.0);
    for (int i = 0; i < 34; i++) {
        float fi = float(i);
        if (fi >= count) { break; }
        float x = mix(-span, span, (fi + 0.5) / count);
        float w = span / count * mix(0.62, 0.92, hash11(fi * 9.1));
        float b = bandAt(u, fi / max(count - 1.0, 1.0));
        float h = (0.28 + b * 1.00 + hash11(fi * 2.7) * 0.34) * hAmt;
        vec2 halfSz = vec2(w, h * 0.5);
        vec2 cq = vec2(p.x - x, p.y - (floorY + h * 0.5));
        float sd = sdRoundRect2(cq, halfSz, 0.012);
        // Frosted top: the glass thins out over its upper part, so when the spectrum moves a
        // tower's top the pixels there brighten or dim by a little instead of switching.
        float top = floorY + h;
        float frost = smoothstep(top, top - soft, p.y);
        float rect = aaFill(sd) * frost;
        float edge = aaLine(sd, 0.004) * frost;

        vec2 imgUV = vec2((x + cq.x + span) / (2.0 * span), 1.0 - hy);
        vec3 photo = max(IMG(photoCover(clamp(imgUV, 0.001, 0.999), u.resolution, IMGSIZE)).rgb, vec3(0.0));

        // glass shading: photo carries the tower, lit toward the sky
        col = mix(col, photo * (0.78 + 0.22 * hy + 0.10 * u.level), rect);
        col += edge * palVisual(fi / count + 0.05 * u.time, u) * (0.80 + 0.30 * b);

        // mirrored photo reflection under the floor, rippled and fading
        vec2 rq = vec2(cq.x, (2.0 * floorY - p.y) - (floorY + h * 0.5));
        float refl = aaFill(sdRoundRect2(rq, halfSz, 0.012));
        float ry = clamp((floorY - p.y) / sky, 0.0, 1.0);
        vec2 rimg = vec2(imgUV.x + sin(p.y * 60.0 + u.time * 1.4) * 0.004, 1.0 - ry);
        vec3 rphoto = max(IMG(photoCover(clamp(rimg, 0.001, 0.999), u.resolution, IMGSIZE)).rgb, vec3(0.0));
        float rfade = exp(-max(floorY - p.y, 0.0) * 4.5);
        col += refl * rphoto * reflAmt * 0.30 * rfade;
    }

    // below-floor darkening keeps the mirror moody
    col *= 1.0 - 0.45 * (1.0 - smoothstep(floorY - 0.55, floorY, p.y));
    col *= 0.42 + 0.58 * smoothstep(1.70, 0.55, length(p));
    return col; // LINEAR HDR — post chain tonemaps
}
