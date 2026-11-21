// SPDX-License-Identifier: AGPL-3.0-only
// Strata Ridge.
// Blue-hour mountain ranges stacked into the distance under a huge rising moon.
// Each range is a filled silhouette whose crest is a glowing spectrum trace,
// in the spirit of the stacked-ridge album plate: the level gently lifts the
// peaks of every range and the spectrum softly lights each crest, faint strata
// lines echo each crest down its face, and cold mist pools in the valleys
// between ranges, thicker and paler with distance. The view trucks slowly and
// steadily sideways with no roll, so near ranges slide past faster than far
// ones; every four beats a faint shimmer eases along the thin cores of the
// front crests. A still lake below mirrors the moon, the ranges and their
// traces, broken by ripples and a moon glitter path. Audio drives light and
// shape only.
// param0 = Ridge Count ; param1 = Peak Drama ; param2 = Afterglow (crest glow and mist)

const float SR_SHB = 4.0;
const float SR_SHG = 0.4;

float srTri(float x) { return abs(fract(x) - 0.5) * 2.0; }

// Crest height of range `fi` at screen x; s returns its spectrum level there.
float srCrest(float x, float fi, float t, float shift, float drama, float oct3,
              VisualUniforms u, out float s, out float fq) {
    float freq = mix(2.4, 0.9, t) * (0.85 + 0.3 * fract(fi * 0.618));
    float q = (x + shift) * freq + fi * 17.3;
    // broad massifs with ridged peaks on top
    float n0 = vnoise(vec2(q * 0.45, fi * 3.1));
    float n1 = 1.0 - abs(2.0 * vnoise(vec2(q * 1.1 + 2.3, fi)) - 1.0);
    float n2 = 1.0 - abs(2.0 * vnoise(vec2(q * 2.7 + 5.1, fi * 1.3)) - 1.0);
    float n = 0.55 * n0 + 0.33 * n1 * n1 * (0.4 + n0) + 0.12 * n2 * n2;
    n += oct3 * 0.05 * vnoise(vec2(q * 7.0, fi * 1.7));
    fq = srTri((x + shift) * 0.11 + fi * 0.137);
    s = bandAt(u, fq);
    float base = mix(0.12, -0.47, pow(t, 1.1));
    float amp = mix(0.2, 0.4, t);
    // the level, not the kick, lifts the peaks, so the crests never jump
    float lift = 0.3 * saturate(u.level);
    return base + amp * (n + drama * lift * (0.2 + 0.6 * n));
}

// The sky and the ranges seen along screen point p.
vec3 srScene(vec2 p, float camX, float tm, float drama, float glow, float detail, VisualUniforms u) {
    // ---- sky: blue hour, a warm coral afterglow low on the horizon rising
    // through teal blue to deep navy overhead, and a cold moon
    vec2 moonP = vec2(0.55, 0.44);
    float mr = length(p - moonP);
    vec3 horizon = palVisual(0.42, u) * 0.07 + vec3(0.004, 0.003, 0.012);
    vec3 blue = palVisual(0.97, u) * 0.035 + vec3(0.003, 0.006, 0.03);
    vec3 col = mix(horizon, blue, smoothstep(-0.15, 0.45, p.y));
    col = mix(col, vec3(0.001, 0.0018, 0.012), smoothstep(0.4, 1.0, p.y));
    vec3 moonGlow = vec3(0.55, 0.72, 1.0);
    col += moonGlow * (0.09 * exp(-mr * 2.6) + 0.35 * exp(-mr * 9.0)) * glow;
    // a faint ice halo ring around the moon
    col += mix(palVisual(0.97, u), moonGlow, 0.5) * 0.03 * exp(-abs(mr - 0.52) * 30.0) * glow;
    // a hot gold-pink afterglow band right on the horizon
    col += palVisual(0.62, u) * 0.05 * exp(-abs(p.y - 0.1) * 7.0) * glow;
    // stars, fading into the horizon glow
    vec2 sg = floor(p * 70.0);
    float sh = hash21(sg);
    vec2 so = fract(p * 70.0) - 0.5 - 0.3 * (hash22(sg + 7.1) - 0.5);
    float tw = 0.6 + 0.4 * sin(tm * (1.0 + 2.0 * sh) + sh * 40.0);
    col += vec3(0.8, 0.85, 1.0) * step(0.965, sh) * smoothstep(0.08, 0.0, length(so))
         * tw * smoothstep(0.1, 0.6, p.y) * 0.9;
    // a meteor every eight beats: it eases across the high sky over about a
    // beat and a half, a thin cool streak that fades in and out, never a flash
    float mb = (u.beatCount + saturate(u.beatPhase)) / 8.0;
    float mk = floor(mb);
    float mt = (mb - mk) * 8.0 / 1.6;
    if (mt < 1.0) {
        vec2 mh = hash22(vec2(mod(mk, 97.0), 3.7));
        vec2 m0 = vec2(mix(-1.5, 1.2, mh.x), mix(0.55, 0.9, mh.y));
        vec2 md = normalize(vec2(mh.x < 0.5 ? 1.0 : -1.0, -0.42));
        float e = smoothstep(0.0, 1.0, mt);
        vec2 head = m0 + md * e * 0.9;
        vec2 rel = p - head;
        float al = dot(rel, -md);
        float ac = length(rel + md * clamp(al, 0.0, 0.28));
        float tail = exp(-max(al, 0.0) * 9.0) * step(-0.004, al);
        float fade = sin(3.14159 * mt);
        col += mix(vec3(0.6, 0.85, 1.0), vec3(1.4, 1.4, 1.5), tail) * smoothstep(0.004, 0.0, ac) * tail * fade * 0.6 * glow;
    }
    // moon disk with soft maria
    float md = smoothstep(0.185, 0.18, mr);
    float mar = vnoise((p - moonP) * 9.0 + 3.0) * 0.6 + vnoise((p - moonP) * 23.0) * 0.4;
    vec3 moonCol = vec3(0.92, 0.96, 1.05) * (1.5 - 0.5 * smoothstep(0.45, 0.8, mar));
    col = mix(col, moonCol, md);

    // ---- ranges, painted far to near
    const int MAXR = 13;
    int ranges = int(mix(7.0, 13.0, u.param0) * mix(0.62, 1.0, detail) + 0.5);
    vec3 mistCool = vec3(0.012, 0.034, 0.110) + palVisual(0.97, u) * 0.025;
    // the shimmer crosses the front crests once every SR_SHB beats, fading in
    // and out instead of riding the kick
    float shPh = fract((floor(u.beatCount) + saturate(u.beatPhase)) / SR_SHB);
    float shimmerX = mix(-2.2, 2.2, shPh);
    float shimAmt = sin(3.14159 * shPh);
    shimAmt *= shimAmt * (0.4 + 0.6 * saturate(u.level));
    float moonLit = exp(-abs(p.x - moonP.x) * 1.6);
    for (int i = 0; i < MAXR; i++) {
        if (i >= ranges) break;
        float fi = float(i);
        float t = fi / max(float(ranges - 1), 1.0); // 0 = far, 1 = near
        float d = mix(16.0, 1.2, t);
        float aer = 1.0 - exp(-(d - 1.0) * 0.17);
        float s, fq;
        float h = srCrest(p.x, fi, t, camX / d, drama, detail, u, s, fq);
        float dy = h - p.y;
        // screen gradient of dy: pd is the true distance to the crest in pixels
        float pxs = 2.0 / max(u.resolution.y, 1.0);
        float pgTrue = length(vec2(dFdx(dy), dFdy(dy)));
        float pg = clamp(pgTrue, 1e-6, 2.5 * pxs);
        float pd = abs(dy) / pg;
        // the crest trace itself: thin HDR core plus a soft halo above
        float g = smoothstep(0.05, 0.7, s);
        float shim = exp(-(p.x - shimmerX) * (p.x - shimmerX) * 6.0) * shimAmt * smoothstep(0.6, 1.0, t);
        float lw = mix(0.8, 1.6, t);
        float core = smoothstep(lw + 1.0, lw - 0.5, pd);
        float halo = exp(max(dy, -1.0) / (pxs * mix(3.0, 7.0, t))) * step(dy, 0.0);
        // the stack runs a sunset gradient: the far crests violet, the middle
        // ones magenta and coral, the near ones gold; the band each crest
        // draws nudges its hue, and loud stretches burn toward white
        vec3 tc = palVisual(mix(0.08, 0.72, t * t) + 0.08 * (fq - 0.5), u);
        tc = mix(tc, vec3(1.6, 1.5, 1.4), 0.08 * g * g);
        // distant crests cool toward blue, so depth reads warm to cold
        tc = mix(tc, vec3(0.25, 0.45, 1.0) * 0.7, aer * 0.6);
        if (dy > 0.0) {
            // silhouette: near-black up close, hazed toward the sky with distance
            vec3 fill = mix(vec3(0.0006, 0.0008, 0.0024), horizon * 0.25 + mistCool * 0.5, aer * aer);
            // valley mist between this range and the next, broken into drifting wisps
            float wisp = 0.55 + 0.45 * vnoise(vec2((p.x + camX / d) * 3.0 + tm * 0.04 + fi * 9.0, dy * 7.0));
            float mist = smoothstep(mix(0.03, 0.08, t), mix(0.14, 0.32, t), dy) * wisp * mix(0.8, 0.5, t);
            vec3 mistCol = mix(mistCool, palVisual(0.97, u) * 0.08, 0.2 + 0.3 * aer) * (0.5 + 1.2 * moonLit) * glow;
            fill = mix(fill, mistCol, mist * 0.6);
            // strata: faint traces echoing the crest down the face
            float sp = mix(0.014, 0.032, t);
            float k = dy / sp - tm * 0.15;
            // contours crowd together on steep flanks, so they fade out there
            float line = smoothstep(1.2, 0.0, abs(fract(k) - 0.5) * sp / pg) * exp(-dy * mix(16.0, 7.0, t))
                       * smoothstep(2.2 * pxs, 1.3 * pxs, pgTrue);
            fill += tc * line * (0.015 + 0.01 * saturate(u.level)) * glow * (1.0 - aer);
            // moon rim light catching the crest edge
            fill += moonGlow * exp(-pd / 5.0) * moonLit * 0.2 * (1.0 - 0.5 * aer);
            // the crest's own light spills a little way down the face below it
            fill += tc * exp(-dy / (pxs * mix(14.0, 30.0, t))) * (0.03 + 0.1 * g * g) * (1.0 - aer) * glow;
            col = fill;
        }
        float inten = (0.3 + (0.25 * saturate(u.level) + 0.3 * g * g) * drama) * mix(0.3, 1.0, t) * (1.0 - 0.6 * aer) * glow;
        // the halo only lifts what is still dark, so a crest passing behind
        // another never doubles into a glint where they meet; the shimmer
        // brightens the thin core only
        col += tc * inten * (core * 1.4 * (1.0 + SR_SHG * shim) + halo * 0.3 * saturate(1.0 - 3.0 * luma(col)));
    }
    return col;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float drama = mix(0.4, 1.5, u.param1);
    float glow = mix(0.5, 1.6, u.param2);

    // no roll; the truck is slow and steady
    float tm = mod(u.time, 600.0);
    float camX = tm * 0.14;

    // a still lake below the ranges mirrors them, with perspective ripples
    const float lakeY = -0.37;
    float below = max(lakeY - p.y, 0.0);
    float inLake = step(p.y, lakeY);
    float zl = 1.0 / (below + 0.04);
    vec2 rq = vec2(p.x * zl * 0.6 + camX * 2.0, zl * 1.1 - tm * 0.15);
    float rip = (vnoise(rq) - 0.5) + 0.5 * (vnoise(rq * 2.3 + 4.0) - 0.5);
    vec2 q = p;
    q.y = mix(p.y, 2.0 * lakeY - p.y + rip * 0.012 * below * 2.0, inLake);
    q.x += inLake * rip * 0.01;
    vec3 col = srScene(q, camX, tm, drama, glow, detail, u);
    if (inLake > 0.5) {
        float fres = 0.35 + 0.45 * exp(-below * 4.0);
        col *= fres * vec3(0.85, 0.9, 1.05);
        // moon glitter path, sparkling on the ripples
        float path = exp(-abs(p.x - 0.55) * mix(10.0, 3.0, saturate(below * 2.0)));
        vec2 gq = vec2(p.x * zl * 4.0 + camX * 3.0, zl * 9.0 - tm * 0.4);
        vec2 gc = floor(gq);
        vec2 gf = fract(gq) - 0.5;
        float glint = step(0.5, hash21(gc)) * smoothstep(0.5, 0.0, abs(gf.x) * 1.2 + abs(gf.y) * 3.0);
        col += mix(vec3(0.55, 0.72, 1.0), palVisual(0.97, u), 0.3) * path * (glint * 0.7 + 0.06) * 0.85 * glow;
    }
    // a thin band of shore mist on the waterline
    float ay = abs(p.y - lakeY);
    float shore = exp(-ay * 18.0) * 0.5 + exp(-ay * 5.0) * 0.5;
    float drift = vnoise(vec2(p.x * 2.2 + camX * 0.8 + tm * 0.05, ay * 9.0));
    col += vec3(0.014, 0.022, 0.065) * shore * (0.35 + 0.65 * drift) * glow;
    return col; // LINEAR HDR — post chain tonemaps
}
