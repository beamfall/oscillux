// SPDX-License-Identifier: AGPL-3.0-only
// Cover Drift — album artwork dissolved into four broad, softly overlapping
// colour fields that slowly drift and turn on a dark backdrop. Designed as a
// calm background behind white player typography: no sharp detail, no beat
// pulse, and only a gentle breath from the smoothed level.
// param0 = Speed ; param1 = Softness ; param2 = Glow

vec3 cdSampleField(vec2 center, VisualUniforms u) {
    vec3 sum = vec3(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 suv = clamp(center + vec2(float(i), float(j)) * 0.14, 0.02, 0.98);
            vec2 cuv = clamp(photoCover(suv, u.resolution, IMGSIZE), 0.001, 0.999);
            sum += max(IMG(cuv).rgb, vec3(0.0));
        }
    }
    vec3 c = sum * (1.0 / 9.0);
    // Soft-compress bright covers so white typography on top remains legible.
    c *= 0.14 / (0.35 + luma(c));
    // Black or missing artwork: lift toward a dim slate so the stage never reads
    // as an empty black frame (displayed luma stays inside the 0.08-0.35 band).
    return c + vec3(0.030, 0.032, 0.040) * (1.0 - smoothstep(0.0, 0.05, luma(c)));
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = motionCentered(uv, u);
    float speed  = mix(0.20, 1.80, saturate(u.param0));
    float radius = mix(0.65, 1.45, saturate(u.param1));
    float glow   = mix(0.45, 1.55, saturate(u.param2));

    // Sample 4 well-separated quadrant fields (mean colours only, no detail).
    vec3 c0 = cdSampleField(vec2(0.25, 0.25), u);
    vec3 c1 = cdSampleField(vec2(0.75, 0.25), u);
    vec3 c2 = cdSampleField(vec2(0.25, 0.75), u);
    vec3 c3 = cdSampleField(vec2(0.75, 0.75), u);

    float t = u.time * speed;
    // Whole arrangement turns one full revolution every 90 s at default speed (0.5).
    float rotAngle = t * (6.2831853 / 90.0);
    vec2 q = rot2(-rotAngle) * p;

    // Each blob drifts on its own slow Lissajous path (periods 47-113 s at default speed).
    vec2 b0 = vec2(-0.54, -0.36) + vec2(0.28 * sin(t * (6.2831853 / 47.0)  + 0.4), 0.22 * cos(t * (6.2831853 / 67.0)  + 1.1));
    vec2 b1 = vec2( 0.54, -0.36) + vec2(0.28 * sin(t * (6.2831853 / 59.0)  + 2.1), 0.22 * cos(t * (6.2831853 / 83.0)  + 0.7));
    vec2 b2 = vec2(-0.54,  0.36) + vec2(0.28 * sin(t * (6.2831853 / 73.0)  + 3.9), 0.22 * cos(t * (6.2831853 / 103.0) + 2.6));
    vec2 b3 = vec2( 0.54,  0.36) + vec2(0.28 * sin(t * (6.2831853 / 91.0)  + 5.2), 0.22 * cos(t * (6.2831853 / 113.0) + 4.3));

    float invR2 = 1.0 / (radius * radius);
    vec2 d0 = q - b0; float w0 = exp(-dot(d0, d0) * invR2);
    vec2 d1 = q - b1; float w1 = exp(-dot(d1, d1) * invR2);
    vec2 d2 = q - b2; float w2 = exp(-dot(d2, d2) * invR2);
    vec2 d3 = q - b3; float w3 = exp(-dot(d3, d3) * invR2);

    float wSum = w0 + w1 + w2 + w3;
    vec3 blobCol = (c0 * w0 + c1 * w1 + c2 * w2 + c3 * w3) / max(wSum, 1e-4);
    vec3 avgCol = (c0 + c1 + c2 + c3) * 0.25;
    vec3 baseCol = avgCol * 0.14 + vec3(0.002, 0.002, 0.003);
    float fieldMask = 1.0 - exp(-wSum * 0.85);

    vec3 col = mix(baseCol, blobCol, fieldMask);

    // Gentle breath from smoothed level only (at most +-6%), no beat or onset term.
    float breath = 1.0 + 0.06 * (2.0 * saturate(u.level) - 1.0);
    col *= glow * breath;

    // Slight vignette to keep edges settled behind overlay typography.
    col *= mix(1.0, 0.70, smoothstep(0.35, 1.85, length(p)));
    return col; // LINEAR HDR — post chain tonemaps
}
