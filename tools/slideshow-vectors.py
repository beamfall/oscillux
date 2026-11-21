#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write conformance/slideshow/vectors.json from an independent model of the photo slideshow.

The model is written from conformance/slideshow/README.md ("Model"), in binary64 with the math
module; shader output is never used. The GPU check (tools/shader/slideshow-check.mjs) renders
shaders/slideshow/slideshow.glsl over the same inputs and compares within the tolerance stated in
the file.

Before writing, the model asserts the contract on every case: every transition meets both
endpoints, the dissolve and iris never leave the span of the two slides, the light sweep adds at
most 0.04 linear luminance over its plain wipe (0.08 after the ACES fitted tone map), motion 0
holds a slide still, amplitude 0 gives the same output with and without beat inputs, and with
tempo coupling at full amplitude the Ken Burns path never moves back over a slide.

Usage: python3 -I tools/slideshow-vectors.py
       python3 -I tools/slideshow-vectors.py --check   (exit 1 if vectors.json would change)
"""

import json
import math
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
VECTORS = os.path.join(ROOT, "conformance", "slideshow", "vectors.json")

N = 8
TOLERANCE = 1e-3
ADDED_LIGHT = 0.04
CELL_CAP = 0.08
Y = (0.2126, 0.7152, 0.0722)
PI = 3.14159265
STYLES = ["dissolve", "lightSweep", "iris"]
LAYOUTS = ["cover", "fill", "pair"]
PROGRESS = [0.0, 0.25, 0.5, 0.75, 1.0]
ZOOM, MARGIN, PACE = 0.18, 1.2, 0.9
GUTTER, GUTTER_COLOR = 0.012, 0.003
BLUR, FILL_DIM, FILL_SAT = 0.05, 0.42, 0.7
TINT = (1.0, 0.95, 0.86)

# Each parameter set gives the pass inputs other than style and p, and two slides.
PARAMS = [
    {  # calm default: cover both, amplitude 0 with loud audio, salient rects off centre
        "aspect": 1.75, "motion": 1.0, "amplitude": 0.0, "beatPhase": 0.25, "beatsPerSlide": 24.0,
        "a": {"k": 0.8, "layout": "cover", "direction": 0.0, "aspect0": 1.5, "aspect1": 1.5,
              "rect0": [0.55, 0.2, 0.8, 0.5], "rect1": [0.0, 0.0, 0.0, 0.0]},
        "b": {"k": 0.1, "layout": "cover", "direction": 1.0, "aspect0": 1.0, "aspect1": 1.0,
              "rect0": [0.1, 0.55, 0.35, 0.85], "rect1": [0.0, 0.0, 0.0, 0.0]},
    },
    {  # tempo coupling on: portrait on a blurred fill, then a portrait pair
        "aspect": 1.75, "motion": 0.5, "amplitude": 1.0, "beatPhase": 0.3, "beatsPerSlide": 1.0,
        "a": {"k": 0.6, "layout": "fill", "direction": 0.0, "aspect0": 0.75, "aspect1": 0.75,
              "rect0": [0.3, 0.15, 0.7, 0.45], "rect1": [0.0, 0.0, 0.0, 0.0]},
        "b": {"k": 0.3, "layout": "pair", "direction": 0.0, "aspect0": 0.6, "aspect1": 0.8,
              "rect0": [0.2, 0.1, 0.6, 0.4], "rect1": [0.0, 0.0, 0.0, 0.0]},
    },
    {  # still: motion 0, square frame, pair then fill, unknown rects
        "aspect": 1.0, "motion": 0.0, "amplitude": 0.0, "beatPhase": 0.7, "beatsPerSlide": 30.0,
        "a": {"k": 0.35, "layout": "pair", "direction": 1.0, "aspect0": 0.7, "aspect1": 0.5,
              "rect0": [0.0, 0.0, 0.0, 0.0], "rect1": [0.4, 0.6, 0.7, 0.9]},
        "b": {"k": 0.9, "layout": "fill", "direction": 1.0, "aspect0": 1.8, "aspect1": 1.8,
              "rect0": [0.0, 0.0, 0.0, 0.0], "rect1": [0.0, 0.0, 0.0, 0.0]},
    },
    {  # partial coupling, zoom out of a large rect, landscape cover into a portrait cover
        "aspect": 1.6, "motion": 1.0, "amplitude": 0.5, "beatPhase": 0.8, "beatsPerSlide": 6.5,
        "a": {"k": 0.45, "layout": "cover", "direction": 1.0, "aspect0": 2.0, "aspect1": 2.0,
              "rect0": [0.05, 0.1, 0.9, 0.95], "rect1": [0.0, 0.0, 0.0, 0.0]},
        "b": {"k": 0.7, "layout": "cover", "direction": 0.0, "aspect0": 0.66, "aspect1": 0.66,
              "rect0": [0.35, 0.25, 0.6, 0.4], "rect1": [0.0, 0.0, 0.0, 0.0]},
    },
]


def q(v):
    """Quantise to 1/256 so every input is exact in binary32 and in decimal."""
    return round(v * 256.0) / 256.0


def photos():
    """Four 8x8 linear photos: outgoing primary and secondary, incoming primary and secondary."""
    imgs = [[], [], [], []]
    for y in range(N):
        for x in range(N):
            imgs[0].append([q(0.05 + 0.7 * x / 7), q(0.1 + 0.5 * y / 7), q(0.3 * ((x + y) % 3) / 2)])
            imgs[1].append([q(0.4 * ((x * y) % 5) / 4), q(0.6 * (7 - y) / 7), q(0.2 + 0.1 * (x % 2))])
            v = max(0.0, 1.0 - math.hypot(x - 2.5, y - 4.5) / 5.0)
            imgs[2].append([q(0.9 * v), q(0.7 * v + 0.05), q(0.5 * (7 - x) / 7)])
            imgs[3].append([q(0.3 + 0.4 * ((x + 2 * y) % 4) / 3), q(0.2 * x / 7), q(0.6 * y / 7)])
    imgs[0][2 * N + 5] = [2.5, 2.0, 1.25]
    imgs[2][5 * N + 2] = [3.0, 2.75, 2.0]
    imgs[3][1 * N + 1] = [0.0, 0.0, 0.0]
    return imgs


def dot(a, b):
    return sum(a[n] * b[n] for n in range(3))


def mix(a, b, t):
    return a * (1.0 - t) + b * t


def mix3(a, b, t):
    return [mix(a[n], b[n], t) for n in range(3)]


def clamp(x, lo, hi):
    return min(max(x, lo), hi)


def smooth(e0, e1, x):
    s = clamp((x - e0) / (e1 - e0), 0.0, 1.0)
    return s * s * (3.0 - 2.0 * s)


def aces(x):
    x = max(x, 0.0)
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0)


def close(a, b):
    return all(abs(a[n] - b[n]) <= 1e-12 for n in range(3))


def tap(img, u, v):
    """Bilinear at photo uv, texel centres at (i + 0.5) / N, indices clamped to the edge."""
    fx, fy = u * N - 0.5, v * N - 0.5
    bx, by = math.floor(fx), math.floor(fy)
    ax, ay = fx - bx, fy - by
    x0, x1 = clamp(bx, 0, N - 1), clamp(bx + 1, 0, N - 1)
    y0, y1 = clamp(by, 0, N - 1), clamp(by + 1, 0, N - 1)
    top = mix3(img[y0 * N + x0], img[y0 * N + x1], ax)
    bot = mix3(img[y1 * N + x0], img[y1 * N + x1], ax)
    return mix3(top, bot, ay)


def path(k, s):
    """Ken Burns path position: k, its pace swung by the beat only when amplitude > 0."""
    e = clamp(k, 0.0, 1.0)
    if s["amplitude"] > 0.0:
        c = PACE * clamp(s["amplitude"], 0.0, 1.0) / (2.0 * PI * max(s["beatsPerSlide"], 1.0) + PI)
        e += c * math.sin(2.0 * PI * s["beatPhase"]) * math.sin(PI * e)
    return e


def assert_monotone(amplitude, beats):
    """Over one slide (k = t / T, beat phase = frac(beats t / T)) the path never moves back."""
    m = 20000
    prev = -1.0
    for i in range(m + 1):
        k = i / m
        e = path(k, {"amplitude": amplitude, "beatsPerSlide": beats, "beatPhase": (beats * k) % 1.0})
        assert e > prev, (amplitude, beats, k, e, prev)
        prev = e
    assert abs(prev - 1.0) < 1e-7


def salient(rect):
    """(centre, framed lower corner, framed upper corner) of a salient rect, per axis."""
    a = [min(rect[0], rect[2]), min(rect[1], rect[3])]
    b = [max(rect[0], rect[2]), max(rect[1], rect[3])]
    if (b[0] - a[0]) * (b[1] - a[1]) <= 0.0:
        a, b = [0.3, 0.3], [0.7, 0.7]
    sc = [clamp(0.5 * (a[n] + b[n]), 0.0, 1.0) for n in range(2)]
    sh = [0.5 * MARGIN * (b[n] - a[n]) for n in range(2)]
    return sc, [clamp(sc[n] - sh[n], 0.0, 1.0) for n in range(2)], [clamp(sc[n] + sh[n], 0.0, 1.0) for n in range(2)]


def centre(target, hs, s0, s1):
    """Per axis: nearest the target with the framed rect in view, then inside the photo."""
    out = []
    for n in range(2):
        lo, hi = s1[n] - hs[n], s0[n] + hs[n]
        c = clamp(target[n], min(lo, hi), max(lo, hi)) if hi >= lo else 0.5 * (s0[n] + s1[n])
        out.append(0.5 if hs[n] >= 0.5 else clamp(c, min(hs[n], 0.5), max(1.0 - hs[n], 0.5)))
    return out


def window(photo_aspect, region_aspect, rect, contain, e, direction, motion):
    """(centre, half size) of the photo window at path position e."""
    r = max(region_aspect, 1e-4) / max(photo_aspect, 1e-4)
    full = [max(1.0, r), max(1.0, 1.0 / r)] if contain else [min(1.0, r), min(1.0, 1.0 / r)]
    h0 = [0.5 * f for f in full]
    _, s0, s1 = salient(rect)
    sc = [0.5 * (s0[n] + s1[n]) for n in range(2)]
    half = [max(0.5 * (s1[n] - s0[n]), 1e-4) for n in range(2)]
    m = clamp(motion, 0.0, 1.0)
    z = clamp(min(h0[0] / half[0], h0[1] / half[1]), 1.0, 1.0 + ZOOM * m)
    h1 = [h / z for h in h0]
    c0 = centre([0.5, 0.5], h0, s0, s1)
    c1 = centre([mix(c0[n], sc[n], m) for n in range(2)], h1, s0, s1)
    f = e if direction < 0.5 else 1.0 - e
    return [mix(c0[n], c1[n], f) for n in range(2)], [mix(h0[n], h1[n], f) for n in range(2)]


def cover(img, qu, qv, region_aspect, photo_aspect, rect, e, direction, motion):
    c, h = window(photo_aspect, region_aspect, rect, False, e, direction, motion)
    return tap(img, c[0] + (qu - 0.5) * 2.0 * h[0], c[1] + (qv - 0.5) * 2.0 * h[1])


def blur(img, u, v, photo_aspect):
    sx, sy = BLUR / max(photo_aspect, 1e-4), BLUR
    acc = [0.0, 0.0, 0.0]
    for y in (-1, 0, 1):
        for x in (-1, 0, 1):
            w = (2 - abs(x)) * (2 - abs(y))
            t = tap(img, u + sx * x, v + sy * y)
            acc = [acc[n] + w * t[n] for n in range(3)]
    return [a / 16.0 for a in acc]


def fill(img, qu, qv, region_aspect, photo_aspect, rect, e, direction, motion, size):
    c, h = window(photo_aspect, region_aspect, rect, True, e, direction, motion)
    pu, pv = c[0] + (qu - 0.5) * 2.0 * h[0], c[1] + (qv - 0.5) * 2.0 * h[1]
    pxu, pxv = 2.0 * h[0] / max(size[0], 1.0), 2.0 * h[1] / max(size[1], 1.0)
    cov = clamp(min(pu, 1.0 - pu) / pxu + 0.5, 0.0, 1.0) * clamp(min(pv, 1.0 - pv) / pxv + 0.5, 0.0, 1.0)
    bc, bh = window(photo_aspect, region_aspect, rect, False, 0.0, 0.0, 0.0)
    back = blur(img, bc[0] + (qu - 0.5) * 2.0 * bh[0], bc[1] + (qv - 0.5) * 2.0 * bh[1], photo_aspect)
    grey = dot(back, Y)
    back = [mix(grey, back[n], FILL_SAT) * FILL_DIM for n in range(3)]
    return mix3(back, tap(img, pu, pv), cov)


def layer(imgs, u, v, sl, first, s):
    e = path(sl["k"], s)
    lay = sl["layout"]
    if lay == "pair":
        hw = 0.5 - 0.5 * GUTTER
        ra = s["aspect"] * hw
        if u < hw:
            return cover(imgs[first], u / hw, v, ra, sl["aspect0"], sl["rect0"], e, sl["direction"], s["motion"])
        if u > 1.0 - hw:
            return cover(imgs[first + 1], (u - (1.0 - hw)) / hw, v, ra, sl["aspect1"], sl["rect1"], e, sl["direction"], s["motion"])
        return [GUTTER_COLOR] * 3
    if lay == "fill":
        return fill(imgs[first], u, v, s["aspect"], sl["aspect0"], sl["rect0"], e, sl["direction"], s["motion"], (N, N))
    return cover(imgs[first], u, v, s["aspect"], sl["aspect0"], sl["rect0"], e, sl["direction"], s["motion"])


def sweep(u, v, a, b, p, aspect):
    """Returns (colour, plain wipe reference)."""
    x = (u * aspect + 0.4 * v) / (aspect + 0.4)
    w = 0.14
    s = mix(-w, 1.0 + w, p)
    ref = mix3(a, b, 1.0 - smooth(s - w, s + w, x))
    e = (x - s) / (0.7 * w)
    ty = dot(TINT, Y)
    amount = 0.035 * math.exp(-e * e) * 4.0 * p * (1.0 - p)
    c = [ref[n] + TINT[n] / ty * amount for n in range(3)]
    d = [c[n] - ref[n] for n in range(3)]
    added = dot([max(x, 0.0) for x in d], Y)
    if added > ADDED_LIGHT:
        c = [ref[n] + d[n] * (ADDED_LIGHT / added) for n in range(3)]
    return c, ref


def iris(u, v, a, b, p, s):
    f = [0.5, 0.5]
    sb = s["b"]
    if sb["layout"] == "cover":
        c, h = window(sb["aspect0"], s["aspect"], sb["rect0"], False, path(sb["k"], s), sb["direction"], s["motion"])
        sc = salient(sb["rect0"])[0]
        f = [clamp(0.5 + (sc[n] - c[n]) / (2.0 * h[n]), 0.0, 1.0) for n in range(2)]
    ar = (s["aspect"], 1.0)
    r_max = math.hypot(max(f[0], 1.0 - f[0]) * ar[0], max(f[1], 1.0 - f[1]) * ar[1])
    w = 0.08
    r = mix(-w, r_max + w, p)
    d = math.hypot((u - f[0]) * ar[0], (v - f[1]) * ar[1])
    return mix3(a, b, 1.0 - smooth(r - w, r + w, d))


def blend(style, u, v, a, b, p, s):
    """The transition formula itself, with no endpoint shortcut."""
    if style == "lightSweep":
        return sweep(u, v, a, b, p, s["aspect"])
    if style == "iris":
        c = iris(u, v, a, b, p, s)
        return c, c
    c = mix3(a, b, p)
    return c, c


def evaluate(imgs, style, u, v, s):
    p = clamp(s["p"], 0.0, 1.0)
    a = layer(imgs, u, v, s["a"], 0, s)
    b = layer(imgs, u, v, s["b"], 2, s)
    if p <= 0.0:
        return a, a, a, b
    if p >= 1.0:
        return b, b, a, b
    c, ref = blend(style, u, v, a, b, p, s)
    return c, ref, a, b


def build():
    for beats in (1.0, 2.0, 6.5, 24.0, 180.0):
        assert_monotone(1.0, beats)
    imgs = photos()
    cases = []
    worst_linear = worst_display = 0.0
    for params in PARAMS:
        silent = dict(params, beatPhase=0.0, beatsPerSlide=1.0)
        for style in STYLES:
            for p in PROGRESS:
                s = dict(params, p=p)
                out = []
                display_added = 0.0
                for j in range(N):
                    for i in range(N):
                        u, v = (i + 0.5) / N, (j + 0.5) / N
                        c, ref, a, b = evaluate(imgs, style, u, v, s)
                        added = dot([max(c[n] - ref[n], 0.0) for n in range(3)], Y)
                        assert added <= ADDED_LIGHT + 1e-12, (style, p, i, j, added)
                        dy = dot([aces(c[n]) - aces(ref[n]) for n in range(3)], Y)
                        assert dy <= CELL_CAP, (style, p, i, j, dy)
                        display_added += dy
                        worst_linear, worst_display = max(worst_linear, added), max(worst_display, dy)
                        if style != "lightSweep":
                            assert all(min(a[n], b[n]) - 1e-12 <= c[n] <= max(a[n], b[n]) + 1e-12 for n in range(3)), (style, p, i, j)
                        for pe, want in ((0.0, a), (1.0, b)):
                            assert close(blend(style, u, v, a, b, pe, s)[0], want), (style, pe, i, j)
                        if params["amplitude"] == 0.0:
                            assert close(c, evaluate(imgs, style, u, v, dict(silent, p=p))[0]), (style, p, i, j)
                        if params["motion"] == 0.0 and params["amplitude"] == 0.0:
                            for key, first in (("a", 0), ("b", 2)):
                                moved = dict(params[key], k=1.0 - params[key]["k"])
                                assert close(layer(imgs, u, v, params[key], first, s), layer(imgs, u, v, moved, first, s)), (key, i, j)
                        out.append(c)
                assert display_added / (N * N) <= CELL_CAP
                cases.append({"style": style, "styleId": STYLES.index(style), "p": p, "params": params, "expected": out})
    return imgs, cases, worst_linear, worst_display


def num(v):
    s = f"{v:.6f}"
    return "0.000000" if s == "-0.000000" else s


def rows(img, indent):
    lines = []
    for j in range(N):
        row = ", ".join("[" + ", ".join(num(c) for c in img[j * N + i]) + "]" for i in range(N))
        lines.append(f"{indent}{row}")
    return ",\n".join(lines)


def slide_json(sl):
    return json.dumps({**sl, "layoutId": LAYOUTS.index(sl["layout"])})


def render():
    imgs, cases, worst_linear, worst_display = build()
    lines = [
        "{",
        '  "comment": "Written by tools/slideshow-vectors.py; see README.md. Images are row-major, '
        'top row first, linear RGB.",',
        f'  "size": {N},',
        f'  "tolerance": {TOLERANCE},',
        f'  "addedLight": {{"perPixelLinear": {ADDED_LIGHT}, "cellDisplay": {CELL_CAP}, '
        f'"worstPerPixelLinear": {num(worst_linear)}, "worstPerPixelDisplay": {num(worst_display)}}},',
        f'  "styles": {json.dumps(STYLES)},',
        f'  "layouts": {json.dumps(LAYOUTS)},',
        f'  "progress": {json.dumps(PROGRESS)},',
        '  "photos": [',
        ",\n".join(f'    [\n{rows(img, "      ")}\n    ]' for img in imgs),
        "  ],",
        '  "cases": [',
    ]
    body = []
    for c in cases:
        pr = c["params"]
        head = ", ".join(f'"{k}": {json.dumps(v)}' for k, v in (
            ("style", c["style"]), ("styleId", c["styleId"]), ("p", c["p"]), ("aspect", pr["aspect"]),
            ("motion", pr["motion"]), ("amplitude", pr["amplitude"]), ("beatPhase", pr["beatPhase"]),
            ("beatsPerSlide", pr["beatsPerSlide"])))
        body.append(f'    {{{head},\n     "a": {slide_json(pr["a"])},\n     "b": {slide_json(pr["b"])},\n'
                    f'     "expected": [\n{rows(c["expected"], "      ")}\n    ]}}')
    lines.append(",\n".join(body))
    lines.append("  ]")
    lines.append("}")
    text = "\n".join(lines) + "\n"
    json.loads(text)
    return text


def main():
    text = render()
    if "--check" in sys.argv[1:]:
        try:
            with open(VECTORS, encoding="utf-8") as f:
                current = f.read()
        except FileNotFoundError:
            current = None
        if current != text:
            print("conformance/slideshow/vectors.json is stale; run tools/slideshow-vectors.py")
            return 1
        print("conformance/slideshow/: vectors.json matches the model; contract assertions hold")
        return 0
    os.makedirs(os.path.dirname(VECTORS), exist_ok=True)
    with open(VECTORS, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote conformance/slideshow/vectors.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
