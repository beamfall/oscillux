// SPDX-License-Identifier: AGPL-3.0-only
// Phosphor Scope — a macro shot of a vector CRT with a two-colour phosphor.
// The beam writes a tumbling 3D Lissajous figure; where it lands the phosphor
// flashes cool and white-hot, then settles into a long afterglow (amber and
// violet on alternate figures), so every stroke carries its own age as a
// colour ramp behind the write head.
// The write speed follows the beat-locked flight profile (cruise, build,
// burst, brake), each kick rings the deflection so the figure records the
// beat as a ripple that trails round the loop in an accent colour, and every
// eight beats the figure unfolds into a new frequency ratio. Curved glass
// carries softbox reflections, an etched graticule and halation; a graphite
// bezel catches the glow. The far side of the tube falls out of focus.
//
// param0 Persistence → how long the afterglow lasts along the trace
// param1 Figure Complexity → frequency ratios of the figures
// param2 Beam Fuzz → beam softness and treble jitter

const float PS_W = 1.45;   // tube face half width
const float PS_H = 1.0;    // tube face half height
const float PS_R = 0.16;   // corner radius
const float PS_BUL = 0.07; // glass bulge
const float PS_LIP = 0.22; // bezel width

float psBox(vec2 q, vec2 b, float r) {
    vec2 d = abs(q) - b + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

// Studio environment seen in the glass: a cool overhead softbox, a warm
// vertical strip light to one side, and a faint room.
vec3 psEnv(vec3 r) {
    vec2 bq = (r.xy - vec2(-0.42, 0.33)) / vec2(0.28, 0.09);
    float box = smoothstep(1.0, 0.55, max(abs(bq.x), abs(bq.y))) * (0.45 + 0.55 * exp(-dot(bq, bq) * 1.5));
    float strip = smoothstep(0.007, 0.002, abs(r.x - 0.40)) * smoothstep(0.55, 0.30, abs(r.y + 0.02));
    float room = 0.02 * smoothstep(-0.6, 0.6, r.y);
    return vec3(0.70, 0.85, 1.0) * box * 2.2 + vec3(1.0, 0.82, 0.62) * strip * 4.0 + vec3(room);
}

// Frequencies of the figure shown in bar k: x and y are always coprime, so
// each figure is a single closed loop; complexity c raises both.
vec3 psRatio(float k, float c) {
    float h1 = hash11(k * 3.7 + 1.3), h2 = hash11(k * 7.1 + 4.1), h3 = hash11(k * 1.3 + 9.7);
    float a = 1.0 + floor(h1 * 2.99) + c;
    float b = a + 1.0 + ((mod(a, 2.0) > 0.5 && h2 > 0.5) ? 1.0 : 0.0);
    vec2 xy = h3 > 0.5 ? vec2(a, b) : vec2(b, a);
    return vec3(xy, 1.0 + floor(hash11(k * 5.3 + 2.2) * 2.99));
}

vec2 psRotStep(vec2 v, vec2 s) { return vec2(v.x * s.x - v.y * s.y, v.y * s.x + v.x * s.y); }

const int PS_SUB = 4; // fine steps per coarse chord near the trace

// Beam deflection for raw oscillator values q: the kick ring scales it, then
// the figure is sized and tumbled; returns the screen position and the depth.
vec3 psDeflect(vec3 q, float ring, vec3 amp, vec2 cy, vec2 cx) {
    q *= (1.0 + ring) * amp;
    q.xz = vec2(q.x * cy.x - q.z * cy.y, q.x * cy.y + q.z * cy.x);
    q.yz = vec2(q.y * cx.x - q.z * cx.y, q.y * cx.y + q.z * cx.x);
    return vec3(q.xy * (1.0 + 0.12 * q.z), q.z);
}

vec3 visual(vec2 uv, VisualUniforms u) {
    vec2 p = centered(uv, u.resolution);
    p.y = -p.y;
    float detail = osDetail(u);
    float tm = mod(u.time, 600.0);

    // ---- camera: a slow, eased drift across the tube face ----
    float fd = mod(osFlight(u, 0.05, 0.02).x, 600.0);
    float sw = sin(fd * 0.27 + 0.8);
    float yaw = (0.14 + 0.10 * abs(sw)) * sign(sw) * smoothstep(0.0, 0.35, abs(sw)) + 0.05 * sin(fd * 0.13);
    float pitch = 0.09 * sin(fd * 0.23 + 2.0);
    float dist = 1.86 + 0.12 * sin(fd * 0.17);
    vec3 ro = vec3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * dist;
    vec3 ta = vec3(-0.22 * sin(yaw), -0.15 * sin(pitch), 0.0);
    vec3 rd = osCamera(ro, ta, osBank(u, 0.035), 2.45, p);

    // ---- hit the phosphor plane (z = 0) and the glass above it ----
    float tz = rd.z < -1e-3 ? -ro.z / rd.z : 1e3;
    vec2 sp = (ro + rd * tz).xy;
    float sd = psBox(sp, vec2(PS_W, PS_H), PS_R);
    float inScreen = 1.0 - smoothstep(-0.004, 0.004, sd);
    vec2 nq = sp / vec2(PS_W, PS_H);
    float bul = max(1.0 - 0.5 * dot(nq, nq), 0.0);
    float tg = rd.z < -1e-3 ? (0.045 * bul - ro.z) / rd.z : 1e3;
    vec2 gp = (ro + rd * tg).xy;
    float focusD = dist - 0.05 + 0.12 * sin(fd * 0.19);
    float blur = abs(tz - focusD) * 0.045;

    // ---- the beam's state ----
    float pers = saturate(u.param0);
    float cpx = floor(saturate(u.param1) * 2.99);
    float fuzz = saturate(u.param2);
    // write speed in loops: beat-locked, so it builds, bursts and brakes
    vec2 wr = osFlight(u, 0.0, 0.30);
    float build = saturate((wr.y - 1.0) / 3.5);
    // beats of music written per loop of trace, for the kick ripples
    float kB = 1.0 / max(wr.y * 0.30 + 0.02, 0.05);
    // The figure for this bar glides into the next bar's frequency ratio over
    // its last beats. The beam angle is counted from a whole loop at the bar's
    // start, so the glide is continuous and both ends meet integer ratios.
    float bar = (u.beatCount + saturate(u.beatPhase)) / 8.0;
    float kb = mod(floor(bar), 64.0);
    float morph = smoothstep(0.70, 1.0, fract(bar));
    VisualUniforms ub = u;
    ub.beatCount = floor(bar) * 8.0;
    ub.beatPhase = 0.0;
    float hRef = floor(osFlight(ub, 0.0, 0.30).x);
    float th = 6.2831853 * (wr.x - hRef + tm * 0.04);
    vec3 fq3 = mix(psRatio(kb, cpx), psRatio(kb + 1.0, cpx), morph);
    float kick = u.onset;
    float ringAmp = (0.035 + 0.06 * u.bassImpact + 0.03 * u.bass) * (0.6 + 0.4 * u.sensitivity);
    vec3 amp = vec3(0.80 + 0.20 * u.bass, 0.76 + 0.24 * u.mid, 0.5 + 0.4 * u.treble)
             * vec3(PS_W * 0.50, PS_H * 0.46, 0.70);
    // slow tumble of the figure, a little livelier while it unfolds
    float ry = tm * 0.11 + 0.6 * morph, rx = 0.35 + 0.25 * sin(tm * 0.047);
    vec2 cy = vec2(cos(ry), sin(ry)), cx = vec2(cos(rx), sin(rx));

    float bw = 0.0034 + 0.004 * fuzz + blur * 0.4;
    float hw = 0.05 + 0.03 * fuzz + blur * 1.5;
    float bw2 = bw * bw, hw2 = hw * hw, bc2 = bw2 * 9.0;
    float jit = 0.005 * fuzz * (0.3 + 1.2 * u.treble);

    // the phosphor's two emissions and the kick accent, read at fixed stops
    vec3 cFlash = palVisual(0.20 + 0.10 * build + 0.04 * u.spectralCentroid, u);
    // alternate figures settle into amber or violet; the kick accent takes the
    // other warm stop, and both glide across with the figure's own unfolding
    float par = mod(floor(bar), 2.0);
    float alt = mix(par, 1.0 - par, morph);
    vec3 cAmber = palVisual(0.97, u), cViolet = palVisual(0.74, u);
    vec3 cGlow = mix(cAmber, cViolet, alt);
    vec3 cKick = mix(palRolePeak(0.52, u), cAmber * 1.3, alt);
    // the cool flash runs further down the trace when the music builds
    float iFlash = 1.0 / (0.07 + 0.10 * build + 0.05 * u.treble);
    float gK = 3.0 / mix(0.25, 1.4, pers);

    // The trace is walked back from the write head in coarse chords (about
    // six per period of the fastest axis). Far from a chord its glow is summed
    // from the chord; near one, the chord is refined into PS_SUB fine steps,
    // walked forward again from its older end, for the sharp core; the two
    // are blended so no seam shows. Every per-step quantity is a recurrence.
    float fMax = max(fq3.x, fq3.y);
    int m = int(clamp(ceil(fMax * mix(6.0, 8.0, detail)), 14.0, 48.0));
    float fm = float(m);
    float dc = 6.2831853 / fm, df = dc / float(PS_SUB);
    float phx = tm * 0.13, phz = tm * 0.09 + 1.3;
    vec2 ax = vec2(cos(fq3.x * th + phx), sin(fq3.x * th + phx)), ay = vec2(cos(fq3.y * th), sin(fq3.y * th));
    vec2 az = vec2(cos(fq3.z * th + phz), sin(fq3.z * th + phz));
    vec2 vj = vec2(cos(tm * 1.3), sin(tm * 1.3));
    vec2 cax = vec2(cos(fq3.x * dc), -sin(fq3.x * dc)), cay = vec2(cos(fq3.y * dc), -sin(fq3.y * dc));
    vec2 caz = vec2(cos(fq3.z * dc), -sin(fq3.z * dc)), cj = vec2(cos(37.0 * dc), sin(37.0 * dc));
    // fine steps run toward the head (younger), the opposite way to the coarse walk
    vec2 fax = vec2(cos(fq3.x * df), sin(fq3.x * df)), fay = vec2(cos(fq3.y * df), sin(fq3.y * df));
    vec2 faz = vec2(cos(fq3.z * df), sin(fq3.z * df)), fj = vec2(cos(37.0 * df), -sin(37.0 * df));
    float bp0 = saturate(u.beatPhase);
    float dbp = kB / fm;
    float cbp = bp0, cenv = exp2(-bp0 * 9.0), envUp = exp2(9.0 * dbp);
    vec2 rg = vec2(cos(bp0 * 25.13), sin(bp0 * 25.13)), rgs = vec2(cos(dbp * 25.13), -sin(dbp * 25.13));
    float glow = 1.0, glowStep = exp2(-gK / fm), envPrev = cenv;
    float dbpF = dbp / float(PS_SUB), envDnF = exp2(-9.0 * dbpF), glowUpF = exp2(gK / (fm * float(PS_SUB)));
    vec2 rgsF = vec2(cos(dbpF * 25.13), sin(dbpF * 25.13));
    float dsF = 1.0 / (fm * float(PS_SUB));

    float best = 1e4;
    float hAcc = 0.0, hT = 0.0, hK = 0.0, hZ = 0.0, wAcc = 0.0;
    float cW = 1e-6, cM = 0.0, cT = 0.0, cK = 0.0, cZ = 0.0;
    vec2 headPos = vec2(0.0);
    vec3 prevC = vec3(0.0);
    if (sd < 0.15) {
        for (int j = 0; j <= 48; j++) {
            if (j > m) break;
            float s = float(j) / fm;
            vec3 pt = psDeflect(vec3(ax.y, ay.y, az.y), cenv * rg.y * ringAmp, amp, cy, cx);
            if (j == 0) {
                headPos = pt.xy;
            } else {
                vec2 ab = pt.xy - prevC.xy;
                float ab2 = max(dot(ab, ab), 1e-8);
                vec2 dv = sp - prevC.xy - ab * saturate(dot(sp - prevC.xy, ab) / ab2);
                float d2 = dot(dv, dv);
                float sm = s - 0.5 / fm;
                float mw = (0.10 + 0.90 * glow * inversesqrt(glowStep)) * sqrt(ab2);
                float kw = 0.05 / (d2 + 0.05);
                wAcc += kw * kw * mw;
                float rf = smoothstep(0.05, 0.022, d2);
                if (rf < 1.0) {
                    float hk = hw2 / (d2 + hw2);
                    float w = hk * hk * mw * (1.0 - rf);
                    hAcc += w;
                    hT += w * saturate(sm * iFlash);
                    hK += w * cenv * envPrev * (1.0 - 0.6 * sm);
                    hZ += w * 0.5 * (prevC.z + pt.z);
                }
                if (rf > 0.0) {
                    // walk this chord from its older end (sample j) toward the head
                    vec2 rax = ax, ray = ay, raz = az, rj = vj, frg = rg;
                    float fbp = cbp, fenv = cenv, fgl = glow, fs = s;
                    float segLen = sqrt(ab2) / float(PS_SUB);
                    vec3 fp = vec3(0.0);
                    for (int k = 0; k <= PS_SUB; k++) {
                        vec3 qf = vec3(rax.y, ray.y, raz.y);
                        qf.xy += vec2(rj.y, rj.x) * jit;
                        vec3 fq = psDeflect(qf, fenv * frg.y * ringAmp, amp, cy, cx);
                        if (k > 0) {
                            vec2 fb = fq.xy - fp.xy;
                            float fb2 = max(dot(fb, fb), 1e-8);
                            vec2 fv = sp - fp.xy - fb * saturate(dot(sp - fp.xy, fb) / fb2);
                            float e2 = dot(fv, fv);
                            best = min(best, e2);
                            float fmw = 0.10 + 0.90 * fgl;
                            float tcf = saturate(fs * iFlash);
                            float kcf = fenv * fenv * (1.0 - 0.6 * fs);
                            float hk = hw2 / (e2 + hw2);
                            float w = hk * hk * fmw * segLen * rf;
                            hAcc += w;
                            hT += w * tcf;
                            hK += w * kcf;
                            hZ += w * fq.z;
                            float kc = bc2 / (e2 + bc2);
                            kc *= kc;
                            kc *= kc;
                            cW += kc;
                            cM += kc * fmw;
                            cT += kc * tcf;
                            cK += kc * kcf;
                            cZ += kc * fq.z;
                        }
                        fp = fq;
                        rax = psRotStep(rax, fax); ray = psRotStep(ray, fay); raz = psRotStep(raz, faz);
                        rj = psRotStep(rj, fj);
                        frg = psRotStep(frg, rgsF);
                        fbp += dbpF;
                        fenv *= envDnF;
                        if (fbp >= 1.0) { fbp -= 1.0; fenv *= 512.0; }
                        fgl *= glowUpF;
                        fs -= dsF;
                    }
                }
            }
            prevC = pt;
            ax = psRotStep(ax, cax); ay = psRotStep(ay, cay); az = psRotStep(az, caz);
            vj = psRotStep(vj, cj);
            // step the ring back one chord; it restarts at each earlier beat
            envPrev = cenv;
            cbp -= dbp;
            cenv *= envUp;
            if (cbp < 0.0) { cbp += 1.0; cenv *= 0.001953125; }
            rg = psRotStep(rg, rgs);
            glow *= glowStep;
        }
    }
    // resolve the nearest trace's age, kick and depth into colour
    float ic = 1.0 / cW;
    float depth = saturate(0.5 - 0.6 * cZ * ic);
    vec3 tc = mix(mix(cFlash, cGlow, cT * ic), cKick, saturate(cK * ic * 1.4)) * (0.40 + 0.60 * depth) * (cM * ic);
    vec3 core = tc * (bw2 / (best + bw2) + 0.25 * (bw2 * 6.0) / (best + bw2 * 6.0));
    float ih = 1.0 / max(hAcc, 1e-6);
    float hDepth = saturate(0.5 - 0.6 * hZ * ih);
    vec3 halo = mix(mix(cFlash, cGlow, hT * ih), cKick, saturate(hK * ih * 1.4)) * (0.40 + 0.60 * hDepth);
    // overlapping strokes saturate the phosphor instead of summing to white
    float hSum = hAcc / hw;
    halo *= hSum / (1.0 + 0.12 * hSum);
    // phosphor emission is purer than the palette's display mix
    core = max(mix(vec3(luma(core)), core, 1.3), 0.0);
    halo = max(mix(vec3(luma(halo)), halo, 1.3), 0.0);
    float energy = (0.8 + 1.0 * u.amplitude + 0.35 * u.bassImpact) * (1.0 + 0.22 * u.beat);
    // a faint aperture grille that only shows where the phosphor is lit
    vec2 mg = sp * vec2(260.0, 150.0);
    float mask = 0.86 + 0.14 * (0.5 + 0.5 * sin(mg.x)) * (0.6 + 0.4 * sin(mg.y + 1.57 * step(0.0, sin(mg.x * 0.5))));
    // the core of the beam runs whiter than its glow
    float coreHot = saturate(1.5 * bw2 / (best + bw2));
    core = mix(core, vec3(luma(core)) * vec3(1.9, 2.0, 2.1), 0.18 * coreHot);
    vec3 phos = (core * 0.85 * mask + halo * 0.30 + cGlow * wAcc * 0.03) * energy;
    // the write head: a white-hot spot with a thin anamorphic flare
    vec2 dh = sp - headPos;
    float hotHead = 1.3 + 1.5 * u.amplitude + 1.2 * kick + 0.8 * build;
    phos += peakWhite(cFlash, 0.8) * (bw2 * 4.0) / (dot(dh, dh) + bw2 * 4.0) * hotHead;
    phos += cFlash * 0.5 * (0.012 / (dot(dh, dh) + 0.012)) * (0.3 + 0.5 * kick + 0.3 * build);
    phos += peakWhite(cFlash, 0.4) * exp(-abs(dh.y) * 260.0) * exp(-abs(dh.x) * 4.0) * 0.14 * hotHead;
    float tubeShade = 1.0 - 0.6 * smoothstep(0.4, 1.15, length(nq));
    vec3 tube = (palRoleFog(0.35, u) * 0.003 + phos) * tubeShade;

    // graticule: fine etched lines lit edge-on by the trace
    vec2 gq = gp / 0.2;
    vec2 gl = abs(fract(gq + 0.5) - 0.5) * 0.2;
    float grid = max(aaLine(gl.x, 0.0012), aaLine(gl.y, 0.0012));
    vec2 tk = abs(fract(gp / 0.04 + 0.5) - 0.5) * 0.04;
    float ticks = max(aaLine(tk.y, 0.0013) * step(abs(gp.x), 0.025),
                      aaLine(tk.x, 0.0013) * step(abs(gp.y), 0.025));
    float gBox = 1.0 - smoothstep(-0.02, 0.0, psBox(gp, vec2(PS_W - 0.12, PS_H - 0.1), 0.05));
    vec3 glowAvg = (cGlow * 0.6 + cFlash * 0.4) * energy;
    tube += (grid * 0.5 + ticks) * gBox * (glowAvg * 0.003 + halo * 0.25);

    // glass: fresnel softbox reflections on the bulged face
    vec3 gn = normalize(vec3(PS_BUL * nq.x / PS_W, PS_BUL * nq.y / PS_H, 1.0));
    vec3 rr = reflect(rd, gn);
    float cosv = saturate(-dot(rd, gn));
    float fres = 0.035 + 0.965 * pow(1.0 - cosv, 5.0);
    float smudge = 0.75 + 0.5 * vnoise(sp * 3.1 + 7.0);
    vec3 col = (tube + psEnv(rr) * fres * smudge) * inScreen;

    // ---- bezel: graphite with a polished chamfer round the glass ----
    float outer = psBox(sp, vec2(PS_W + PS_LIP, PS_H + PS_LIP), PS_R + PS_LIP);
    if (sd > -0.004 && outer < 0.0) {
        float lip = saturate(sd / 0.06);
        vec2 gdir = sp / max(length(sp), 1e-4);
        float bevel = 1.0 - smoothstep(0.0, 0.22, lip);
        vec3 bn = normalize(vec3(-gdir * bevel * 0.9, 1.0));
        vec3 br = reflect(rd, bn);
        float bf = 0.08 + 0.92 * pow(1.0 - saturate(-dot(rd, bn)), 5.0);
        float brush = 0.85 + 0.15 * vnoise(vec2(dot(sp, vec2(0.7, 0.7)) * 60.0, sd * 4.0));
        vec3 metal = vec3(0.010, 0.011, 0.012) * brush + psEnv(br) * bf * mix(0.30, 0.05, saturate(lip * 4.0)) * brush;
        // the chamfer and the lip pick up the trace's own glow
        metal += (halo * 0.08 + glowAvg * 0.02) * (bevel * 0.8 + 0.2) * exp(-sd * 14.0);
        col += metal * (1.0 - inScreen) * (1.0 - smoothstep(-0.01, 0.0, outer));
    }
    float outside = smoothstep(-0.004, 0.004, outer);
    col += outside * (vec3(0.004, 0.005, 0.006) + glowAvg * 0.004 * exp(-outer * 2.0));

    col = accentize(col, u.accent, 0.08);
    return col; // LINEAR HDR — post chain tonemaps
}
