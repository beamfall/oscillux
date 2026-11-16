// SPDX-License-Identifier: AGPL-3.0-only
// Cloud Sea.
// Dawn above a sea of cloud, seen from a mountain top. The cloud tops roll
// out to the horizon in soft, slowly turning heaps, lit gold on the sides
// that face the low sun and cool blue in their hollows; above them the sky
// runs from a warm band at the horizon to a clear pale blue. The sea drifts
// toward the viewer at walking pace. The clouds keep to the lower half and
// the sky above stays clear. Audio breathes the light: the loudness warms the
// sun's glow and the rims of the clouds, and the level lifts the haze.
// param0 = Heaps (cloud scale) ; param1 = Drift (cloud speed) ; param2 = Sun (position)

vec3 visual(vec2 uv, VisualUniforms u) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float x = (uv.x - 0.5) * aspect;
    float y = 1.0 - uv.y;
    float breath = osCalmBreath(u);
    float t = u.time * mix(0.01, 0.05, u.param1);

    vec3 skyHi = osPalCalm(0.35, 13, u);
    vec3 skyLo = osPalCalm(0.65, 13, u);
    vec3 sun = mix(osPalCalm(0.8, 13, u), vec3(1.0, 0.85, 0.6), 0.5);
    float horizon = 0.46;

    // sky
    float sy = saturate((y - horizon) / (1.0 - horizon));
    vec3 col = mix(skyLo * 0.12, skyHi * 0.06, smoothstep(0.0, 0.8, sy));
    vec2 sp = vec2(mix(-0.55, 0.55, u.param2) * aspect, horizon + 0.05);
    float sr = length(vec2(x, y) - sp);
    col += sun * (exp(-sr * 5.0) * (0.10 + 0.05 * breath) + exp(-sr * 25.0) * 0.25);

    // the cloud sea: a height field in perspective below the horizon
    if (y < horizon + 0.01) {
        float depth = max(horizon - y, 0.004);
        float z = 0.08 / depth;                  // distance into the sea
        vec2 wp = vec2(x * z, z + t * 4.0) * mix(1.4, 0.8, u.param0);
        float h = fbm(wp * 0.5 + vec2(0.0, u.time * 0.003));
        float hx = fbm(wp * 0.5 + vec2(0.06, u.time * 0.003)) - h;
        // heaps rise bright and lit toward the sun; hollows sink cool and dim
        float heap = smoothstep(0.3, 0.75, h);
        float lit = saturate(0.5 + hx * 9.0 * clamp((sp.x - x) * 4.0, -1.0, 1.0));
        vec3 shade = mix(skyHi * 0.035, mix(skyLo, vec3(0.9), 0.5) * 0.13, heap);
        vec3 cloud = shade + sun * lit * heap * 0.08 * (0.85 + 0.3 * breath);
        // haze thickens toward the horizon
        float haze = exp(-depth * 12.0) * (0.75 + 0.25 * saturate(u.level));
        cloud = mix(cloud, skyLo * 0.12 + sun * 0.03, haze);
        col = mix(col, cloud, smoothstep(horizon + 0.01, horizon - 0.01, y));
    }
    return col; // LINEAR HDR — post chain tonemaps
}
