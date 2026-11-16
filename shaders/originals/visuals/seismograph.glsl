// SPDX-License-Identifier: AGPL-3.0-only
// Seismograph: a low flight over a landscape drawn entirely in seismic traces.
// Each row of the terrain is one recording, a glowing pen line with a solid
// black curtain under it, so nearer rows hide the ones behind as in a
// hidden-line ridge plot. The camera runs down a quiet valley whose traces
// jitter with the treble, between jagged ranges of seismic spikes that burn
// hotter with height. Every beat sets off a quake: a ring wave spreads from an
// epicentre ahead, heaving the traces and lighting them as it passes, and the
// pen heads keep writing bright ink along every line.
// param0 Scroll Speed: flight speed.
// param1 Pen Gain: height of the seismic ranges and of the quake waves.
// param2 Ink Bleed: how far the ink glows and bleeds below each line.

const float SG_ROWS = 96.0;

float sgPath(float z) { return 3.0 * sin(z * 0.019) + 1.4 * sin(z * 0.043 + 0.9); }

// Value noise with its x derivative, for 2D (x along the row, y across rows).
vec2 sgNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = p - i;
    vec2 w = f * f * (3.0 - 2.0 * f);
    float dw = 6.0 * f.x * (1.0 - f.x);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    float k1 = b - a;
    float k4 = a - b - c + d;
    return vec2(a + k1 * w.x + (c - a) * w.y + k4 * w.x * w.y, dw * (k1 + k4 * w.y));
}

// Height of row k at offset x from the valley centre, and its slope.
// kk is the row index wrapped for hashing; q holds the quake ring (x = radius,
// y = strength) and amp the audio-driven amplitudes.
vec2 sgTrace(float x, float kk, float zr, vec4 q, vec4 amp, int oct, float t) {
    float ax = abs(x);
    // The ranges rise on both sides of the valley; their height wanders.
    float side = smoothstep(2.5, 9.0, ax);
    float dside = sign(x) * (ax > 2.5 && ax < 9.0 ? 6.0 * (ax - 2.5) * (9.0 - ax) / (6.5 * 6.5 * 6.5) : 0.0);
    vec2 h = vec2(0.0);
    float a = 1.0;
    vec2 p = vec2(x * 0.32, kk * 0.11);
    for (int i = 0; i < 4; i++) {
        if (i >= oct) break;
        vec2 n = sgNoise(p);
        // Ridged: sharp spikes like a seismogram's peaks.
        float s = 1.0 - abs(2.0 * n.x - 1.0);
        float ds = -sign(2.0 * n.x - 1.0) * 2.0 * n.y;
        // Fine octaves fade out with distance, so far crests do not alias.
        float lod = i < 2 ? 1.0 : saturate((62.0 - 18.0 * float(i) - t) / 10.0);
        h += a * lod * vec2(s * s, 2.0 * s * ds * 0.32 * pow(2.1, float(i)));
        p = p * 2.1 + vec2(1.7, 3.1);
        a *= 0.48;
    }
    float range = amp.x;
    vec2 m = vec2(h.x * side * range, (h.y * side + h.x * dside) * range);
    // Quiet valley trace: fine jitter that follows the treble.
    float jf = x * 3.1 + kk * 1.7;
    float jit = amp.y * (sin(jf) * 0.6 + sin(jf * 2.3 + 1.1) * 0.4) * (1.0 - side);
    m.x += jit + 0.05;
    m.y += amp.y * 3.1 * (0.6 * cos(jf) + 0.92 * cos(jf * 2.3 + 1.1)) * (1.0 - side);
    // Quake ring: a travelling wave packet around radius q.x.
    float r = length(vec2(x, zr));
    float e = r - q.x;
    float env = exp(-e * e * 0.18) * q.y;
    float wv = sin(e * 2.2);
    float dr = x / max(r, 1e-3);
    m.x += env * wv * amp.z * 0.7;
    m.y += env * (cos(e * 2.2) * 2.2 - wv * e * 0.36) * amp.z * 0.7 * dr;
    return m;
}

// Push a colour away from its grey by k, so hot lines keep their hue
// through the tone curve.
vec3 sgSat(vec3 c, float k) { return max(mix(vec3(dot(c, vec3(0.3, 0.55, 0.15))), c, k), 0.0); }

vec3 sgSky(vec3 rd, VisualUniforms u) {
    float h = max(rd.y, 0.0);
    vec3 col = vec3(0.0008, 0.001, 0.003);
    col += palVisual(0.95, u) * 0.05 * exp(-h * 9.0);
    // a violet backlight behind the ranges that swells with the bass, so the
    // crests stand out as a silhouette
    vec3 bl = mix(palVisual(0.78, u), vec3(0.5, 0.1, 1.0), 0.5);
    col += bl * (0.1 + 0.16 * saturate(u.bassImpact)) * exp(-h * 16.0) * (0.45 + 0.55 * exp(-rd.x * rd.x * 5.0));
    return col;
}

// The sky is chart paper too: a few faint recordings run across it, cyan
// against the hot ranges, their wiggle following the spectrum at that bearing
// and swelling as each quake rolls through.
vec3 sgSkyTraces(vec3 rd, VisualUniforms u, float tm, float pixel, float quake) {
    float hz = length(rd.xz);
    float e = rd.y / max(hz, 1e-3);
    float a = atan(rd.x, max(rd.z, 1e-3));
    vec3 c = vec3(0.0);
    vec3 cyan = palVisual(0.985, u);
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float ei = 0.035 + 0.042 * fi + 0.004 * fi * fi;
        float fr = 24.0 - 3.0 * fi;
        float s = a * fr - tm * (0.8 + 0.25 * fi) + fi * 7.3;
        // Bursts of activity drift along each record; between them it is a
        // quiet hairline.
        float burst = pow(0.5 + 0.5 * sin(a * 4.0 - tm * 0.45 + fi * 2.1), 5.0);
        float env = 0.12 + (0.5 + 2.4 * bandAt(u, saturate(0.5 + a * 0.9 + 0.12 * (fi - 1.5)))) * burst;
        env *= 1.0 + 1.6 * quake * exp(-a * a * 3.0);
        float amp = 0.0075 * env * (1.0 - 0.15 * fi);
        float w = sin(s * 3.1) * 0.6 + sin(s * 7.3 + fi) * 0.4;
        float dw = (cos(s * 3.1) * 1.86 + cos(s * 7.3 + fi) * 2.92) * fr * amp;
        float d = abs(e - ei - amp * w) / sqrt(1.0 + dw * dw);
        float lw = pixel * 0.75;
        float line = exp(-d * d / (lw * lw));
        float glow = exp(-d / (lw * 4.0)) * 0.08;
        float fade = smoothstep(0.0, 0.03, e) * (1.0 - 0.18 * fi);
        c += cyan * (line * (0.35 + 0.9 * burst) + glow * (0.4 + burst)) * fade;
    }
    return c;
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 pc = centered(uv, u.resolution);
    pc.y = -pc.y;
    float detail = osDetail(u);
    float tm = mod(u.time, 600.0);
    float gain = mix(0.5, 1.5, u.param1);
    float bleed = mix(0.4, 1.8, u.param2);

    float cruise = mix(3.0, 8.0, u.param0);
    vec2 fl = osFlight(u, cruise, 1.0 * mix(0.6, 1.4, u.param0));
    float z = fl.x;
    float rush = saturate((fl.y - 1.0) / 3.5);
    float lull = saturate(1.0 - fl.y);
    float alt = 2.7 + 0.3 * sin(tm * 0.13);
    vec3 ro = vec3(sgPath(z), alt, z);
    vec3 ta = vec3(sgPath(z + 10.0), 0.45, z + 10.0);
    float curve = sgPath(z + 14.0) - 2.0 * sgPath(z + 7.0) + sgPath(z);
    float roll = -0.07 * curve + osBank(u, 0.12);
    float fov = 1.25 - 0.18 * rush + 0.08 * lull;
    vec3 rd = osCamera(ro, ta, roll, fov, pc);

    float bass = bandRange(u, 0, 8);
    float treble = bandRange(u, 32, 64);
    vec4 amp = vec4(gain * (2.1 + 0.5 * bass), 0.04 + 0.22 * treble, gain, 0.0);
    // Quake: epicentre 22 ahead of the camera; the ring runs out with the beat.
    float age = saturate(u.beatPhase);
    float qa = (0.4 + 0.9 * saturate(u.bassImpact)) * exp(-age * 1.8);
    vec4 q = vec4(1.0 + 26.0 * age, qa, 0.0, 0.0);
    float zEpi = z + 22.0;

    float sp = 0.55;
    float pixel = 2.0 / (u.resolution.y * fov);
    vec3 col = sgSky(rd, u);
    vec3 acc = vec3(0.0);
    float vis = 1.0;
    float dz = max(rd.z, 0.05);
    float k = floor(ro.z / sp) + 1.0;
    int rows = osSteps(40.0, SG_ROWS, detail);
    int oct = osSteps(2.0, 4.0, detail);
    // the quake is the cool complement of the hot ranges: electric cyan on
    // even beats, ultraviolet on odd ones
    float par = mod(floor(u.beatCount), 2.0);
    vec3 quakeCol = mix(palVisual(0.97, u), par < 0.5 ? vec3(0.0, 0.55, 1.0) : vec3(0.42, 0.08, 1.0), 0.8) * 1.7;
    // Height ramp, sampled once: deep valley, slopes, crests.
    vec3 pc0 = palVisual(0.06, u);
    vec3 pc1 = palVisual(0.31, u);
    vec3 pc2 = sgSat(palVisual(0.6, u), 1.5);
    vec3 pc3 = palVisual(0.8, u);
    // the far ranges recede into a saturated violet, not a pale wall
    pc3 = sgSat(pc3, 1.8);
    pc3 = mix(pc3, vec3(0.55, 0.12, 1.0), 0.35);
    // builds push the ramp hotter, lulls cool it
    float build = rush - 0.6 * lull;
    // Upper bound of any trace: ranges, jitter and the quake wave.
    float hTop = amp.x * 1.82 + amp.y + 0.05 + q.y * amp.z * 0.7;
    float mg = 0.25 + 0.3 * bleed;
    float tHit = 80.0;
    for (int i = 0; i < 96; i++) {
        if (i >= rows) break;
        float zr = k * sp;
        float t = (zr - ro.z) / dz;
        if (t > 70.0) break;
        vec3 pos = ro + rd * t;
        float x = pos.x - sgPath(zr);
        // A rising ray already clear of every trace can see nothing more.
        if (rd.y > 0.0 && pos.y > hTop + mg) break;
        // Rows whose highest point is well below the ray are skipped cheaply.
        float hb = smoothstep(2.5, 9.0, abs(x)) * amp.x * 1.82 + amp.y + 0.05 + q.y * amp.z * 0.7;
        if (pos.y > hb + mg) { k += 1.0; continue; }
        float kk = mod(k, 4096.0);
        vec2 h = sgTrace(x, kk, zr - zEpi, q, amp, oct, t);
        float d = (pos.y - h.x) / sqrt(1.0 + h.y * h.y);
        float fp = t * pixel * 1.2;
        float lw = 0.016 + 0.0016 * t;
        float hw = max(lw, fp);
        float line = (1.0 - smoothstep(hw - fp, hw + fp, abs(d))) * lw / hw;
        float fog = exp(-t * 0.045);
        float heat = saturate(h.x / (2.4 * gain));
        // Colour by height: deep red valley, orange slopes, white-hot crests.
        // Distance cools the lines toward magenta, so the far ranges read as
        // depth instead of a white wall.
        float hh = heat * 2.0;
        vec3 lc = (hh < 1.0 ? mix(pc0, pc1, hh) : mix(pc1, pc2, hh - 1.0)) * (0.4 + (0.6 + 0.3 * build) * heat * heat);
        float far = saturate((t - 12.0) / 30.0);
        // the breakdown cools the low valley toward the far violet
        lc = mix(lc, pc3 * (0.35 + 0.45 * heat), saturate(far * 0.9 + 0.45 * lull * (1.0 - heat)));
        float qr = length(vec2(x, zr - zEpi)) - q.x;
        float qlit = exp(-qr * qr * 0.25) * q.y;
        // the ring takes the line over instead of greying it with a half mix
        lc = mix(lc, quakeCol * (0.6 + 0.5 * heat), smoothstep(0.12, 0.55, qlit));
        // Pen heads: ink pulses run outward along every line.
        float pen = pow(0.5 + 0.5 * sin(abs(x) * 0.7 - tm * 2.4 + hash11(kk) * 6.28), 12.0);
        lc *= 1.0 + 1.5 * pen * (1.0 - 0.5 * heat);
        float halo = exp(-abs(d) * (14.0 / bleed)) * 0.035 * bleed;
        acc += lc * vis * fog * (line * 2.2 + halo);
        if (d < 0.0) {
            // The curtain under the line: ink bleeding down into black.
            acc += lc * vis * fog * exp(d * (7.0 / bleed)) * 0.05 * bleed;
            tHit = t;
            vis = 0.0;
            break;
        }
        k += 1.0;
    }
    if (vis > 0.5) {
        // Sparse stars above the ranges, twinkling slowly.
        vec2 sp2 = rd.xy / max(rd.z, 0.3) * 70.0;
        vec2 cell = floor(sp2);
        vec2 cm = mod(cell, 97.0);
        float sr = hash21(cm);
        vec2 off = vec2(hash21(cm + 13.1), hash21(cm + 41.7)) * 0.6 + 0.2;
        float sd = length(sp2 - cell - off);
        float tw = 0.6 + 0.4 * sin(tm * (0.7 + sr * 1.3) + sr * 40.0);
        float star = step(0.955, sr) * exp(-sd * sd * 30.0) * tw * smoothstep(0.02, 0.2, rd.y);
        col += mix(vec3(0.8, 0.85, 1.0), palVisual(0.9, u), 0.4) * star * 0.35;
        col += sgSkyTraces(rd, u, tm, pixel, qa);
    } else {
        col = mix(vec3(0.0004, 0.0003, 0.0006), col, 1.0 - exp(-tHit * 0.045));
    }
    col += acc;
    return max(col, vec3(0.0));
}
