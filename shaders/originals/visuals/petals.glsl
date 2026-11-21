// SPDX-License-Identifier: AGPL-3.0-only
// Petals.
// A huge flower held against a lamp in a dark room: three rings of cupped
// petals, each one its own shape (broad or narrow, round, pointed or notched,
// with a ruffled rim), lit from behind so the light passes through the
// tissue and is filtered by its pigment. Thin rims and tips glow, the veins
// read as darker, denser lines in the glow, the base of each petal carries a
// deep blotch and dew drops on the near rings lens the glow and catch a
// glint. The lamp drifts very slowly behind the bloom, so the glow creeps
// across the petals. Within a ring each petal overlaps the one before it, like
// the blades of an iris. The rings sit at different depths: the camera's slow,
// level drift (no roll) slides them gently against each other, the bloom turns
// at a crawl and the far ring is out of focus; every sixteen beats the shot
// glides slowly to a slightly different framing. On every beat a faint ring of light
// runs out from the heart and the petals lift a touch as it passes, their
// rims stirring gently with the treble; waves of loose petals tear off at a
// slow steady pace and drift past at a distance, fading before they come
// close, with their own parallax. The light follows the music's smoothed
// level; the spectrum only barely stretches and tints each petal, so no
// petal or the bloom as a whole pulses with the beat.
// Its colours come from its own palette, unnudged by beat or centroid, so the host's vivid
// palette tour never swells the light across the frame.
// param0 = Petal Count ; param1 = Bloom ; param2 = Detail

// The palette read: the visual's own palette with no beat or spectral nudge.
// The vivid tour swaps whole palettes of very different brightness every few
// seconds, which swells the light across the frame, so this visual keeps its
// own colours there (as the calm visuals do); a host's manifest palette still
// replaces them.
vec3 ptPalSteady(float t, VisualUniforms u) { return osPalCalm(t, 8, u); }

const float PT_Z0 = 3.0;    // depth of the flower plane (screen units = world units there)
const int PT_WAVES = 6;      // waves of flying petals alive at once

// Petal in its own frame: x from base (0) to tip (1), y across. shp holds the
// petal's shape: x width, y tip taper (above 1 pointed), z tip notch depth,
// w the phase of the ripple running along its rim; ruf is the ripple depth.
// Returns (coverage, signed side -1..1 across the width, x, distance outside).
vec4 ptPetal(vec2 q, float soft, vec4 shp, float ruf) {
    float x = q.x;
    float xc = saturate(x);
    float w = 0.50 * shp.x * sqrt(xc) * pow(max(1.0 - xc * xc, 0.0), 0.5 * shp.y);
    w *= 1.0 + ruf * sin(xc * 17.0 + shp.w) * xc;
    w *= 1.0 - shp.z * exp(-q.y * q.y * 260.0) * smoothstep(0.7, 1.0, xc);
    float d = max(abs(q.y) - w, max(-x, x - 1.0) * 1.3);
    float cov = smoothstep(soft, -soft, d);
    float side = clamp(q.y / max(w, 1e-3), -1.0, 1.0);
    return vec4(cov, side, xc, d);
}

// The palette read once at five fixed stops; every colour in the frame is a
// cheap cyclic blend of these locals instead of a palette read per sample.
struct PtPal { vec3 c0; vec3 c1; vec3 c2; vec3 c3; vec3 c4; };
vec3 ptPal(PtPal P, float t) {
    float x = fract(t) * 5.0;
    float i = floor(x);
    float f = smoothstep(0.0, 1.0, x - i);
    vec3 a = i < 1.0 ? P.c0 : i < 2.0 ? P.c1 : i < 3.0 ? P.c2 : i < 4.0 ? P.c3 : P.c4;
    vec3 b = i < 1.0 ? P.c1 : i < 2.0 ? P.c2 : i < 3.0 ? P.c3 : i < 4.0 ? P.c4 : P.c0;
    return mix(a, b, f);
}

// Speed over the shared 32-beat profile, as osFlight, with the cycle's
// running distance read from a table instead of summed per pixel.
const float PT_RUN[33] = float[33](0.0, 1.0, 2.0, 3.0, 4.15, 5.6, 7.35, 9.4, 12.25, 15.75, 19.25, 22.75, 25.3, 26.325, 27.0, 27.95, 29.0, 30.15, 31.4, 32.75, 33.75, 34.35, 34.95, 35.55, 36.6, 38.475, 41.1, 44.475, 48.6, 53.1, 57.6, 61.05, 62.75);
vec2 ptFlight(VisualUniforms u, float cruise, float surge) {
    float n = floor(u.beatCount);
    int k = int(mod(n, 32.0));
    float ph = saturate(u.beatPhase);
    float v0 = osBeatSpeed(n);
    float v1 = osBeatSpeed(n + 1.0);
    float beats = floor(n / 32.0) * PT_RUN[32] + PT_RUN[k] + v0 * ph + 0.5 * (v1 - v0) * ph * ph;
    return vec2(u.time * cruise * 0.2 + beats * (cruise * 0.4 + surge), mix(v0, v1, ph));
}

// Push a colour away from its grey (the rose-gold stops are soft on their own).
vec3 ptSat(vec3 c, float k) {
    return max(mix(vec3(dot(c, vec3(0.2126, 0.7152, 0.0722))), c, k), vec3(0.0));
}

// Keep the bloom off pure saturated red after the post chain's tonemap: lift
// green and blue together just enough that no deep rose reads as red.
float ptTone(float x) { return x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14); }
float ptToneInv(float y) {
    y = clamp(y, 0.0, 0.999);
    float a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y;
    return (-b + sqrt(b * b + 0.56 * a * y)) / (2.0 * a);
}
vec3 ptOffRed(vec3 c) {
    float r = ptTone(c.r), g = ptTone(c.g), b = ptTone(c.b);
    float need = 0.27 * r - g - b;
    if (need <= 0.0) return c;
    c.g = ptToneInv(g + 0.5 * need);
    c.b = ptToneInv(b + 0.5 * need);
    return c;
}

// The light on a petal: sun is the lamp behind the bloom at this pixel, rimC
// the cool rim light, dew (density, time) the drops, glint their sparkle,
// blot the depth of the dark base and thk the tissue thickness.
struct PtLight { vec3 sun; vec3 rimC; vec2 dew; float glint; float blot; float thk; };

// Backlit petal shading. pe from ptPetal, q the petal-frame position, R the
// petal-to-screen rotation (screen = q * R), face how squarely it faces us
// (1 flat, 0 edge on). base/mid/tip are its pigment along its length, lit its
// light level. The front is lit only by a dim raking key; most of the colour
// is the lamp behind shining through the tissue, filtered by the pigment
// more deeply where the petal is thick: at the base, along the spine and in
// the veins, which therefore read as darker, richer lines.
vec3 ptShade(vec4 pe, vec2 q, mat2 R, float face, vec3 base, vec3 mid, vec3 tip,
             PtLight Li, float lit, float detail, float glowT, float seed) {
    float x = pe.z;
    float e = pe.y;
    // surface slope in the petal frame: cup across, arch along
    vec2 sl = vec2(0.9 * (x - 0.45), 1.1 * e * (0.4 + 0.6 * x));
    float vein = 0.0;
    float crepe = 0.5;
    if (detail > 0.0) {
        // main veins fanning out from the base, branching toward the tip
        float vc = q.y / (q.x + 0.12) * 7.0 + 0.5 + 0.15 * sin(x * 5.0 + seed * 6.0) * x;
        float v1 = 1.0 - smoothstep(0.03, 0.11, abs(fract(vc) - 0.5));
        float v2 = 1.0 - smoothstep(0.02, 0.07, abs(fract(vc * 2.0 + 0.5 + 0.3 * x) - 0.5));
        vein = (v1 + 0.5 * v2 * smoothstep(0.4, 0.75, x)) * smoothstep(0.05, 0.3, x)
             * smoothstep(1.0, 0.75, abs(e)) * detail;
        sl.y += 0.08 * detail * sin(fract(vc) * 6.2831853) * x;
        crepe = mix(0.5, vnoise(vec2(e * 18.0 + seed * 7.0, x * 3.0)), detail);
    }
    vec2 ss = sl * R;
    vec3 n = normalize(vec3(-ss, 0.55 + 0.6 * face));
    // dim warm key from the upper left, in front
    vec3 L = vec3(-0.45, 0.55, 0.70);
    float dl = dot(n, L);
    float dif = max(dl, 0.0);
    vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
    float spec = pow(max(dot(n, H), 0.0), 48.0);
    vec3 alb = mix(base, mid, smoothstep(0.0, 0.55, x));
    alb = mix(alb, tip, smoothstep(0.55, 1.0, x) * 0.7);
    // a deep blotch at the base of every petal
    float blot = 1.0 - smoothstep(0.08, 0.26, x + 0.04 * sin(e * 11.0 + seed * 9.0));
    alb = mix(alb, base * base * 0.7, blot * Li.blot);
    // the lamp through the tissue, filtered by the pigment
    float thick = (0.15 + 0.95 * (1.0 - x * x) * (1.0 - 0.7 * e * e)) * Li.thk + 0.4 * vein;
    vec3 filt = pow(max(alb, vec3(0.002)), vec3(0.5 + 1.8 * thick)) * exp(-1.3 * thick) * (1.0 - 0.45 * vein);
    float thin = 1.0 + 0.9 * smoothstep(0.72, 1.0, abs(e)) * x + 0.6 * smoothstep(0.8, 1.0, x);
    float ao = 0.2 + 0.8 * smoothstep(0.0, 0.4, x);
    vec3 c = alb * (0.004 + 0.12 * dif * dif + 0.012 * (dl * 0.5 + 0.5)) * ao;
    c += Li.sun * filt * thin * (0.8 + 0.4 * crepe) * (0.5 + 0.5 * face + glowT);
    // the cool rim light wraps the thin edge: complementary to the warm glow
    float rim = smoothstep(0.78, 1.0, abs(e)) * (0.3 + 0.7 * x);
    c += mix(tip, Li.rimC, 0.7) * rim * rim * (0.22 + glowT);
    c += vec3(1.0, 0.93, 0.85) * spec * 0.18 * (0.4 + 0.6 * detail);

    // dew drops: little lenses that magnify the glow, with a dark meniscus, a
    // caustic away from the key and a glint toward it; they creep to the base
    if (Li.dew.x > 0.0 && x > 0.3 && x < 0.92) {
        vec2 dq = q / 0.13;
        float lane = floor(dq.y);
        dq.x += Li.dew.y * (0.1 + 0.25 * hash11(lane * 3.1 + seed * 11.0));
        vec2 cid = floor(dq);
        float hd = hash21(cid + seed * 37.0);
        if (hd < Li.dew.x) {
            float rad = 0.22 + 0.18 * fract(hd * 13.7);
            vec2 cc = cid + 0.5 + (hash22(cid + 3.1) - 0.5) * (1.0 - 2.0 * rad);
            vec2 dv = (dq - cc) / rad;
            float dd = dot(dv, dv);
            float m = 1.0 - smoothstep(0.75, 1.0, dd);
            vec2 lq = R * vec2(-0.63, 0.77);
            vec2 qc = dv + 0.45 * lq;
            vec2 qh = dv - 0.42 * lq;
            vec3 drop = c * (1.35 - 0.95 * smoothstep(0.45, 1.0, dd));
            drop += Li.sun * filt * 1.4 * exp(-dot(qc, qc) * 9.0);
            drop += vec3(1.0, 0.97, 0.92) * Li.glint * exp(-dot(qh, qh) * 80.0);
            c = mix(c, drop, m);
        }
    }
    return c * lit;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p0 = motionCentered(uv, u);
    p0.y = -p0.y;
    // slow camera: a steady drift, push-in and roll.
    // Each layer of the scene sees it at its own depth k (1 = the middle
    // ring): nearer layers slide and swell more, so the drift reveals depth.
    vec2 flc = ptFlight(u, 0.0, 0.0);
    flc.x += 0.06 * u.time;
    float camT = mod(flc.x, 600.0);
    vec2 camOff = 0.06 * vec2(sin(camT * 0.13), 0.7 * sin(camT * 0.09 + 1.3));
    float camZ = 0.06 * sin(camT * 0.07);
    // every ten seconds the shot is reframed, gliding slowly over the span
    // to a new pose: the whole bloom, or a little closer on one side of it.
    // It runs on the clock, so a pause or a skipped beat never jumps the frame.
    float sb8 = u.time / 10.0;
    float sk = floor(sb8);
    float se = smoothstep(0.0, 1.0, sb8 - sk);
    float hk0 = hash11(mod(sk, 251.0) * 1.37 + 0.4);
    float hk1 = hash11(mod(sk + 1.0, 251.0) * 1.37 + 0.4);
    vec3 pose0 = vec3(vec2(cos(sk * 2.39996), sin(sk * 3.1)) * 0.03 * step(0.3, hk0), 1.0 + 0.04 * hk0 * step(0.3, hk0));
    vec3 pose1 = vec3(vec2(cos((sk + 1.0) * 2.39996), sin((sk + 1.0) * 3.1)) * 0.03 * step(0.3, hk1), 1.0 + 0.04 * hk1 * step(0.3, hk1));
    vec3 pose = mix(pose0, pose1, se);
    camOff += pose.xy;
    p0 = p0 / pose.z;
    float detail = osDetail(u);
    float t = mod(u.time, 600.0);

    float nPet = floor(mix(5.0, 12.0, u.param0) + 0.5);
    float bloom = mix(0.85, 1.30, u.param1);
    float detailAmt = mix(0.3, 1.0, u.param2) * detail;
    float drift = 0.05 * u.spectralCentroid;
    // the spectrum, read once at eight stops
    float sb[9];
    for (int i = 0; i < 8; i++) sb[i] = bandAt(u, (float(i) + 0.5) / 8.0);
    sb[8] = sb[0];

    // the palette at five fixed stops: deep, rose, coral, gold, and the cool
    // far end that rims the bloom
    PtPal P = PtPal(ptPalSteady(0.02, u), ptPalSteady(0.24, u), ptPalSteady(0.48, u),
                    ptPalSteady(0.72, u), ptPalSteady(0.97, u));
    float bp = saturate(u.beatPhase);
    float kick = (1.0 - bp) * (1.0 - bp);
    vec3 cool = ptSat(P.c4, 1.35);
    vec3 gold = ptSat(ptPal(P, 0.60 + drift), 1.3);
    // the accent eases between a warm gold and an icy cool light, beat by beat
    float odd = 0.5 - 0.5 * cos(3.14159265 * (u.beatCount + bp));
    vec3 accent = mix(gold * vec3(1.15, 1.0, 0.8), mix(cool, vec3(0.75, 0.9, 1.0), 0.35), odd);
    // a ring of light runs out from the heart through the rings on each beat
    float front = (0.10 + 1.35 * bp) * bloom;
    float waveAmp = smoothstep(0.0, 0.25, bp) * (1.0 - bp) * (0.02 + 0.01 * u.level);

    // the lamp behind the bloom: warm white, its hot spot drifting slowly
    vec2 sunPos = 0.5 * bloom * vec2(cos(t * 0.07), sin(t * 0.05 + 1.0));
    vec2 sd = p0 - sunPos;
    float spot = exp(-dot(sd, sd) * 1.4);
    PtLight Li;
    Li.sun = mix(vec3(1.0, 0.86, 0.95), gold, 0.15) * (0.22 + 0.85 * spot) * (0.95 + 0.04 * u.level);
    Li.rimC = cool;
    Li.dew = vec2(0.0, 0.06 * t);
    Li.glint = 0.45 + 0.15 * u.level;
    Li.blot = 0.8;
    Li.thk = 1.0;

    // ---- backdrop: near black, the lamp just showing through the gaps ----
    vec2 pm = p0 / (1.0 + camZ) - camOff;
    float r = length(pm);
    float edgeR = 1.05 * bloom;
    vec3 col = ptSat(P.c0, 1.2) * 0.002 * exp(-r * 1.5);
    col += Li.sun * 0.03 * spot * smoothstep(edgeR * 1.1, 0.2, r);
    // far defocused lights, deep in the room behind
    vec2 pb = p0 / (1.0 + camZ * 0.3) - camOff * 0.3;
    for (int L = 0; L < 2; L++) {
        float fl = float(L);
        float sc = 2.2 + 1.6 * fl;
        vec2 bq = pb * sc + vec2(t * 0.03 * (1.0 + fl), -t * 0.02);
        vec2 cell = floor(bq);
        vec2 f = fract(bq) - 0.5;
        vec2 h = hash22(mod(cell, 113.0) + fl * 7.1);
        vec2 dv = f - (h - 0.5) * 0.3;
        float rad = 0.08 + 0.12 * h.y;
        float dl = length(dv);
        float disc = smoothstep(rad, rad - 0.05, dl) * (0.5 + 0.5 * smoothstep(rad - 0.07, rad - 0.01, dl));
        disc *= step(0.74, h.x);
        vec3 bc = h.y > 0.66 ? cool : h.y > 0.33 ? ptSat(ptPal(P, 0.22), 1.3) : gold;
        col += bc * disc * (0.010 + 0.010 * u.level) / (1.0 + fl);
    }

    // ---- the bloom: three rings of petals, back to front ----
    // the bloom turns slowly and the rings breathe open and shut, each ring
    // out of step with the next; the music never jolts the bloom's size
    float spin = 0.025 * flc.x;
    float breath = bloom;
    float shiver = 0.003 + 0.002 * u.level;
    for (int L = 0; L < 3; L++) {
        float fl = float(L);
        float kp = 0.82 + 0.18 * fl;
        vec2 pl = p0 / (1.0 + camZ * kp) - camOff * kp;
        float rl = length(pl);
        float al = atan2_(pl.y, pl.x + 1e-6);
        float n = nPet + fl;
        float sector = 6.2831853 / n;
        float phi = spin * (1.0 - 0.35 * fl) + fl * sector * 0.5 + 0.06 * sin(camT * 0.3 + fl);
        float lenL = breath * (1.18 - 0.34 * fl) * (1.0 + 0.02 * sin(camT * 0.9 - fl * 1.4));
        // focus on the middle ring: the far ring is soft and loses its veins
        float soft = L == 0 ? 0.034 : L == 1 ? 0.008 : 0.013;
        float dAmt = L == 0 ? 0.0 : detailAmt;
        float lit = 0.42 + 0.3 * fl;
        Li.dew.x = L == 0 ? 0.0 : 0.13 * step(0.5, detailAmt);
        // outer petals deep rose, inner ones coral running to gold
        float hb = 0.00 + 0.05 * fl + drift;
        // the beat's lift reaches this ring as the wave of light passes
        float puff = waveAmp * exp(-pow((0.6 * lenL - front) * 4.0, 2.0));
        // this sector's petal and both neighbours can cover the pixel; each
        // petal overlaps the one before it, like the blades of an iris, so the
        // stacking never changes across a sector boundary
        float idx0 = floor((al - phi) / sector + 0.5);
        for (int k = 0; k < 3; k++) {
            float idx = idx0 + float(k) - 1.0;
            float ia = phi + idx * sector;
            float iw = mod(idx, n);
            float hv = hash11(iw + fl * 13.0);
            float hv2 = hash11(iw * 1.7 + fl * 5.3 + 2.0);
            float hv3 = hash11(iw * 2.9 + fl * 3.1 + 7.0);
            float bf = fract(iw / n + 0.07 * fl) * 8.0;
            int bi = int(bf);
            float lvl = 0.6 * u.level + 0.15 * mix(sb[bi], sb[bi + 1], bf - float(bi));
            float len = lenL * (0.88 + 0.02 * lvl + 0.02 * sin(t * 0.15 + iw * 1.7))
                      * (0.9 + 0.2 * hv3) * (1.0 + 0.06 * puff);
            // beyond the tip and its shadow the petal adds nothing
            if (rl > len * 1.3) continue;
            // each petal its own shape: broad or narrow, round or pointed,
            // some notched, with a ripple running along the rim
            vec4 shp = vec4(mix(0.85, 1.25, hv2) * (1.0 - 0.08 * fl), mix(0.6, 1.7, hv3),
                            hv > 0.55 && hv3 < 0.45 ? 0.16 : 0.0, hv * 40.0 + t * 0.1 * (0.7 + 0.6 * hv2));
            float ruf = (0.015 + 0.045 * hv3) * (1.0 + 1.5 * puff);
            mat2 R = rot2(ia);
            vec2 q = R * pl / len;
            // the tip curls to one side, lifts with the beat, shivers with treble
            q.y += (0.05 * sin(iw * 2.1 + fl) + 0.08 * puff * (hv2 - 0.5)
                   + shiver * sin(t * 0.4 + iw * 1.3 + fl * 2.0)) * q.x * q.x;
            vec4 pe = ptPetal(q, soft / len, shp, ruf);
            float wv = waveAmp * exp(-pow((rl - front) * 7.0, 2.0));
            // soft shadow cast on what lies behind, and the cool rim light
            // bleeding round the silhouette
            float outD = max(pe.w, 0.0) * len;
            col *= 1.0 - 0.75 * exp(-outD * 14.0) * (1.0 - pe.x) * smoothstep(0.0, 0.3, pe.z);
            col += mix(cool, accent, wv) * exp(-outD * 30.0) * (1.0 - pe.x) * (0.025 + 0.08 * wv) * lit * (0.9 + 0.1 * lvl);
            if (pe.x > 0.001) {
                // each petal its own shade, and louder ones warmer and brighter
                float hp = hb + 0.1 * (hv - 0.5) + 0.02 * lvl;
                vec3 cBase = ptSat(ptPal(P, hp), 1.35) * 0.8;
                vec3 cMid = ptSat(ptPal(P, hp + 0.18), 1.35);
                vec3 cTip = ptSat(ptPal(P, hp + 0.30 + 0.03 * fl), 1.35);
                PtLight Lw = Li;
                Lw.rimC = mix(cool, accent, wv);
                vec3 pc = ptShade(pe, q, R, 1.0, cBase, cMid, cTip, Lw,
                                  lit * (0.85 + 0.2 * lvl), dAmt, 0.2 * wv, hv + fl);
                col = mix(col, ptSat(pc, 1.3), pe.x);
            }
        }
    }
    // glowing heart with a crown of anthers that sparkle with the treble
    vec2 ph = p0 / (1.0 + camZ * 1.1) - camOff * 1.1;
    float rh = length(ph);
    float ah = atan2_(ph.y, ph.x + 1e-6);
    vec3 coral = ptSat(P.c2, 1.3);
    float core = exp(-rh * rh / (0.010 * breath));
    col += mix(gold, coral, 0.35) * core * (0.26 + 0.12 * u.level);
    float sa = ah / 6.2831853 * 21.0;
    float si = floor(sa);
    float hA = hash11(si + 3.7);
    float stamR = 0.20 * breath * (0.82 + 0.30 * hA);
    float sf = (fract(sa) - 0.5) * 6.2831853 / 21.0 * rh;   // across the filament, in screen units
    col += gold * exp(-sf * sf * 9.0e4) * smoothstep(stamR, 0.03, rh) * step(0.03, rh) * 0.10;
    float ba = (si + 0.5) * 6.2831853 / 21.0;
    float db = length(ph - vec2(cos(ba), sin(ba)) * stamR);
    float rb = 0.011 * breath * (0.8 + 0.4 * hA);
    float tw = 0.5 + 0.5 * sin(t * (0.6 + 0.6 * hA) + hA * 40.0);
    float bead = smoothstep(rb, rb * 0.35, db);
    col = mix(col, gold * 0.15, bead * 0.6);
    col += mix(gold, vec3(1.0, 0.95, 0.85), 0.4) * smoothstep(rb * 0.8, 0.0, length(ph - vec2(cos(ba), sin(ba)) * stamR + vec2(0.3, -0.35) * rb))
         * (0.5 + 0.4 * u.level * tw);
    col += mix(gold, accent, 0.5) * exp(-db * db / (rb * rb * 2.5)) * (0.05 + 0.06 * u.level * tw + 0.03 * kick);

    // ---- loose petals tearing off and tumbling toward the camera ----
    // a slow steady clock: a new wave tears off every few seconds
    float T = 0.04 * u.time;
    float nw = floor(T);
    int perWave = osSteps(6.0, 12.0, detail);
    float pw = float(perWave);
    float sector = 6.2831853 / pw;
    float flare = 1.0;
    Li.dew.x = 0.0;
    Li.blot = 0.3;
    Li.thk = 0.6;
    for (int w = PT_WAVES - 1; w >= 0; w--) {
        float fw = float(w);
        float wave = nw - fw;
        float age = T - wave;                    // 0 .. PT_WAVES
        float wid = mod(wave, 997.0);
        float z = PT_Z0 - age * (PT_Z0 - 0.25) / float(PT_WAVES);
        float fadeIn = smoothstep(0.0, 0.5, age);
        float fadeOut = smoothstep(1.1, 2.0, z);
        float defocus = smoothstep(1.5, 0.45, z);   // near petals blur out
        float glowW = (w == 0 ? flare : 1.0) * (0.94 + 0.05 * u.level);
        float sc = PT_Z0 / z;
        // nearer petals slide further with the camera's drift
        float kp = min(1.0 + 0.3 * (sc - 1.0), 2.2);
        vec2 pw2 = p0 / (1.0 + camZ * kp) - camOff * kp;
        float r2 = length(pw2);
        // the wave's petals all lie in one annulus; skip it when the pixel is outside
        if (r2 < (0.35 + age * 0.20) * sc - 0.36 * sc || r2 > (0.80 + age * 0.45) * sc + 0.36 * sc) continue;
        float a2 = atan2_(pw2.y, pw2.x + 1e-6);
        // each wave tears from its own part of the bloom, so its colour varies
        float hw = 0.05 + 0.12 * hash11(wid * 1.31 + 0.5) + drift;
        vec3 fBase = ptSat(ptPal(P, hw), 1.35) * 0.8;
        vec3 fMid = ptSat(ptPal(P, hw + 0.18), 1.35);
        vec3 fTip = ptSat(ptPal(P, hw + 0.34), 1.35);
        PtLight Lw = Li;
        Lw.sun *= glowW * 0.55;
        Lw.rimC = cool;
        // each petal of a wave owns one angular sector, so only the pixel's
        // sector and its two neighbours can cover it
        float base = mod(wid * 2.39996, 6.2831853);
        float j0 = floor(mod((a2 - base) / sector, pw));
        for (int k = 0; k < 3; k++) {
            float fj = mod(j0 + float(k) - 1.0, pw);
            vec4 h = vec4(hash22(vec2(wid * 0.37 + fj * 3.1, fj + 1.7)),
                          hash22(vec2(fj * 7.7 + 2.0, wid * 0.53 + 9.0)));
            float th = sector * (fj + h.x) + base + age * 0.10 * (h.w - 0.5);
            float rr = 0.35 + 0.45 * h.y + age * (0.20 + 0.25 * h.z);
            vec2 c = vec2(cos(th), sin(th)) * rr * sc;
            float sz = (0.30 + 0.12 * h.z) * sc;
            vec2 dv = pw2 - c;
            if (dot(dv, dv) > sz * sz * 0.7) continue;
            // orientation: along the flight direction, tumbling and fluttering
            float tumble = h.w * 6.28 + age * (0.5 + 0.4 * h.x) + 0.08 * sin(t * 0.6 + h.y * 20.0);
            float ori = th + 1.2 * (h.z - 0.5) + age * 0.5 * (h.y - 0.5);
            mat2 R = rot2(ori);
            vec2 q = R * dv / sz;
            float flip = cos(tumble);
            q.y /= max(abs(flip), 0.18);
            q.x += 0.5;
            vec4 shp = vec4(mix(0.8, 1.2, h.x), mix(0.6, 1.6, h.y), h.z > 0.6 && h.y < 0.4 ? 0.16 : 0.0, h.w * 30.0 + t * 0.4);
            vec4 pe = ptPetal(q, 0.006 * z + defocus * 0.20, shp, 0.03 * (1.0 - defocus));
            float alpha = pe.x * fadeIn * fadeOut * (1.0 - 0.45 * defocus);
            // the petal's own shadow falls on the bloom behind it
            float outD = max(pe.w, 0.0) * sz;
            col *= 1.0 - 0.4 * exp(-outD * 10.0) * (1.0 - pe.x) * fadeIn * fadeOut * (1.0 - defocus);
            if (alpha > 0.001) {
                // a tumbling petal turns its cup through the key light, and the
                // edge-on moment lets a little more of the lamp through it
                vec2 qs = vec2(q.x, q.y * sign(flip));
                vec3 pc = ptShade(pe, qs, R, abs(flip), fBase, fMid, fTip, Lw,
                                  0.8 + 0.4 * h.y, defocus > 0.4 ? 0.0 : detailAmt * (1.0 - defocus),
                                  0.15 * (1.0 - abs(flip)), h.z * 3.0);
                pc = mix(pc, (fMid + fTip) * 0.10 * glowW, defocus * 0.5);   // soft bokeh body
                col = mix(col, ptSat(pc, 1.3), alpha);
            }
        }
    }

    // gentle vignette keeps the edges deep
    col *= 1.0 - 0.55 * smoothstep(0.9, 2.0, length(p0));
    col = ptSat(col, 1.15);
    return ptOffRed(max(col, vec3(0.0))); // LINEAR HDR — post chain tonemaps
}
