// SPDX-License-Identifier: AGPL-3.0-only
// Page Curl: the outgoing frame is a sheet that peels from a seeded corner
// around a moving cylinder. Each pixel inverse-projects through the cylinder:
// the rising underside shows the page's face, shaded by its normal; over it the
// page's back rolls across, darkened, with the image bleeding through mirrored,
// a palette sheen and a lit rim on the curl. The lifted sheet casts a soft
// shadow onto the incoming frame and onto the page still lying flat.
float pcInside(vec2 q, float asp) {
    // distance (screen heights) from a uv point to the frame edge, >0 inside
    return min(min(q.x, 1.0 - q.x) * asp, min(q.y, 1.0 - q.y));
}

// The foil's tint: green beyond the red and blue goes to gold or violet, so a
// yellow or green palette lights the foil gold, never lime or olive.
vec3 pcFoil(vec3 c) {
    float x = max(c.g - 0.85 * max(c.r, c.b), 0.0);
    return c + vec3(0.3, -1.0, 0.55) * x;
}

vec3 transition(vec2 uv, float p, VisualUniforms u) {
    float asp = u.resolution.x / max(u.resolution.y, 1.0);
    float sd = u.presentation0.y;
    float win = 4.0 * p * (1.0 - p);
    float e = p * p * (3.0 - 2.0 * p);
    float px = 1.0 / max(u.resolution.y, 1.0);
    vec2 sa = vec2(asp, 1.0);
    vec2 a = (uv - 0.5) * sa;

    // peel direction: out of a seeded corner, mostly sideways like a page turn
    float qd = floor(sd * 4.0);
    float sx = mod(qd, 2.0) < 0.5 ? 1.0 : -1.0;
    float sy = qd < 1.5 ? 1.0 : -1.0;
    vec2 dir = normalize(vec2(sx, sy * (0.3 + 0.45 * fract(sd * 7.13))));
    float smax = 0.5 * (asp * abs(dir.x) + abs(dir.y));
    float r = 0.08 + 0.05 * win;
    const float PI = 3.14159265;
    // the rectangle's corners already ease the swept area in and out
    float xf = mix(smax + 0.01, -smax - 0.5 * PI * 0.08 - 0.03, mix(p, e, 0.35));
    float x = dot(a, dir);
    float qc = (x - xf) / r;
    float covS = clamp((xf + r - x) / px + 0.5, 0.0, 1.0);   // curl silhouette

    vec3 pc = suppressGreenCast(palVisual(0.2 + 0.55 * sd, u));
    float mx = max(pc.r, max(pc.g, pc.b)), mn = min(pc.r, min(pc.g, pc.b));
    vec3 comp = vec3(mx + mn) - pc;
    vec3 pcn = pc / max(mx, 0.02);
    float beat = 0.75 + 0.5 * clamp(u.bassImpact + 0.5 * u.beat, 0.0, 1.0);
    vec2 L = normalize(vec2(-0.45, 0.9));                     // light, (along dir, up)
    vec2 Hh = normalize(L + vec2(0.0, 1.0));

    // the incoming frame, shadowed by the lifted sheet
    vec3 col = TO(0.5 + (uv - 0.5) / (1.0 + 0.04 * (1.0 - e)));
    {
        float Xs = xf + 0.5 * PI * r;
        float ins = pcInside((a + dir * (Xs - x)) / sa + 0.5, asp);
        float dsh = max(x - xf - 0.6 * r, 0.0);
        float sh = exp(-dsh / (0.05 + 0.6 * r)) * smoothstep(-0.03, 0.03, ins) * smoothstep(xf - 0.02, xf + 0.02, x);
        col *= 1.0 - 0.72 * sh * win;
    }

    // lower layer: the page face, flat or rising around the cylinder
    if (qc < 1.0 + 2.0 * px / r) {
        float phi = qc < 0.0 ? 0.0 : asin(min(qc, 1.0));
        float X = qc < 0.0 ? x : xf + r * phi;
        vec2 su = (a + dir * (X - x)) / sa + 0.5;
        float cov = clamp(pcInside(su, asp) / px + 0.5, 0.0, 1.0);
        if (qc >= 0.0) cov *= covS;
        if (cov > 0.0) {
            vec3 f = FROM(su);
            vec2 n = vec2(-sin(phi), cos(phi));
            float shade = 1.0 + 0.9 * (dot(n, L) - L.y);
            shade *= 1.0 - 0.3 * sin(phi) * sin(phi);
            f *= max(shade, 0.1);
            float gl = pow(max(dot(n, Hh), 0.0), 40.0) * step(0.0, qc) * sin(phi);
            f += mix(comp, pc, 0.4) * gl * 0.3 * beat * win;
            f = mix(f, suppressGreenCast(f), min(gl * win * 4.0, 1.0));   // no lime glint
            // shadow of the back flap lying over the page
            float Xb = 2.0 * xf + PI * r - x;
            float insB = pcInside((a + dir * (Xb - x)) / sa + 0.5, asp);
            float sb = exp(-max(-insB, 0.0) / 0.035) * step(x, xf);
            f *= 1.0 - 0.55 * sb * win;
            col = mix(col, f, cov);
        }
    }

    // upper layer: the page's back, rolling over the top of the cylinder and
    // lying flipped beyond it
    if (qc < 1.0 + 2.0 * px / r) {
        float phi = qc < 0.0 ? PI : PI - asin(min(qc, 1.0));
        float X = qc < 0.0 ? 2.0 * xf + PI * r - x : xf + r * phi;
        vec2 su = (a + dir * (X - x)) / sa + 0.5;
        float ins = pcInside(su, asp);
        float cov = clamp(ins / px + 0.5, 0.0, 1.0);
        if (qc >= 0.0) cov *= covS;
        if (cov > 0.0) {
            vec3 f = FROM(su);
            // the back is a thin-film foil: the image bleeds through, mirrored,
            // under an iridescent palette sheen that drifts with the curl
            vec2 n = vec2(sin(phi), -cos(phi));
            float shade = 1.0 + 0.9 * (dot(n, L) - L.y);
            float spec = pow(max(dot(n, Hh), 0.0), 24.0) * step(0.0, qc);
            float th = 1.5 * X + 0.2 * phi + 0.22 * vnoise(su * vec2(asp, 1.0) * 3.0 + sd * 9.0) + 0.25 * p;
            vec3 film = suppressGreenCast(palVisual(fract(th), u));
            film = mix(film / max(max(film.r, max(film.g, film.b)), 0.05), pcn, 0.35); // lit foil, not mud
            film = pcFoil(film);
            float perp = dot(a, vec2(-dir.y, dir.x));
            float sw = (perp + 0.35 * x - mix(-1.1, 1.1, e)) / 0.12;
            float sheen = exp(-sw * sw) * (0.6 + 0.6 * beat - 0.45);
            vec3 back = 0.32 * f + film * (0.025 + 0.2 * luma(f) + 0.24 * sheen);
            back *= max(shade, 0.25);
            back += pcFoil(mix(pc, comp, 0.3)) * spec * 0.35 * beat + film * spec * 0.25;
            float edge = exp(-max(ins, 0.0) / (1.5 * px + 0.0015));
            back += pcFoil(pc) * edge * 0.35 * beat;
            // a green image under a warm sheen mixes to lime or olive: keep the
            // whole foil off it
            back = pcFoil(back);
            col = mix(col, back, cov * smoothstep(0.0, 0.02, win));
        }
    }

    // lit rim along the curl's silhouette
    float rim = exp(-abs(xf + r - x) / (1.5 * px + 0.002)) * covS;
    {
        float Xr = xf + 0.5 * PI * r;
        float ins = pcInside((a + dir * (Xr - x)) / sa + 0.5, asp);
        rim *= clamp(ins / px + 0.5, 0.0, 1.0);
    }
    col += pc * rim * 0.45 * beat * win;
    col = mix(col, suppressGreenCast(col), min(rim * win * 4.0, 1.0)); // nor a lime rim
    return col;
}
