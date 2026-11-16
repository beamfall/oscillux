#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write conformance/switch-transition/vectors.json from an independent model of the host
switch transitions.

The model is written from conformance/switch-transition/README.md ("Model"), in binary64 with
the math module; shader output is never used. The GPU check
(tools/shader/switch-transition-check.mjs) renders shaders/switch/switch.glsl over the same
inputs and compares within the tolerance stated in the file.

Before writing, the model asserts the contract on every case: the endpoints, Luma Key and Photo
Key with motion 0 equal the plain dissolve, the per-pixel added light stays within 0.04 of the
style's reference, and after the ACES fitted tone map no pixel (and so no cell) adds more than
0.08 luminance.

Usage: python3 -I tools/switch-transition-vectors.py
       python3 -I tools/switch-transition-vectors.py --check   (exit 1 if vectors.json would change)
"""

import json
import math
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
VECTORS = os.path.join(ROOT, "conformance", "switch-transition", "vectors.json")

N = 8
TOLERANCE = 1e-3
ADDED_LIGHT = 0.04
CELL_CAP = 0.08
Y = (0.2126, 0.7152, 0.0722)
PI = 3.14159265
STYLES = ["lumaKey", "photoKey", "melt", "downbeatCutLightLeak", "beatIris"]
PROGRESS = [0.0, 0.25, 0.5, 0.75, 1.0]
PARAMS = [
    {"beatPhase": 0.25, "energy": 0.75, "focus": 0.5, "motion": 1.0, "aspect": 1.75},
    {"beatPhase": 0.25, "energy": 0.75, "focus": 0.5, "motion": 0.0, "aspect": 1.75},
    {"beatPhase": 0.875, "energy": 0.0, "focus": 1.0, "motion": 0.5, "aspect": 1.0},
]


def q(v):
    """Quantise to 1/256 so every input is exact in binary32 and in decimal."""
    return round(v * 256.0) / 256.0


def inputs():
    frm, to, photo = [], [], []
    for y in range(N):
        for x in range(N):
            frm.append([q(0.05 + 0.6 * x / 7), q(0.1 + 0.3 * y / 7), q(0.2 * ((x + y) % 3))])
            to.append([q(0.5 * ((x * y) % 5) / 4), q(0.02 + 0.5 * (7 - x) / 7 * y / 7), q(0.6 * ((x + 2 * y) % 4) / 3)])
            v = max(0.0, 1.0 - math.hypot(x - 3.5, y - 3.5) / 4.0)
            photo.append([q(v), q(0.8 * v), q(0.6 * v)])
    frm[5 * N + 2] = [3.0, 2.5, 1.5]
    to[1 * N + 6] = [4.0, 3.5, 2.0]
    to[6 * N + 1] = [0.0, 0.0, 0.0]
    return frm, to, photo


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def mix3(a, b, t):
    return [a[i] + (b[i] - a[i]) * t for i in range(3)]


def clamp(v, lo, hi):
    return min(max(v, lo), hi)


def smooth(e0, e1, x):
    s = clamp((x - e0) / (e1 - e0), 0.0, 1.0)
    return s * s * (3.0 - 2.0 * s)


def guard(c, ref):
    d = [c[i] - ref[i] for i in range(3)]
    added = dot([max(v, 0.0) for v in d], Y)
    if added > ADDED_LIGHT:
        return [ref[i] + d[i] * (ADDED_LIGHT / added) for i in range(3)]
    return c


def sample(img, u, v):
    """Bilinear, clamp-to-edge, texel centres at (i + 0.5) / N."""
    fx, fy = u * N - 0.5, v * N - 0.5
    ix, iy = math.floor(fx), math.floor(fy)
    ax, ay = fx - ix, fy - iy

    def at(i, j):
        return img[clamp(j, 0, N - 1) * N + clamp(i, 0, N - 1)]

    top = mix3(at(ix, iy), at(ix + 1, iy), ax)
    bottom = mix3(at(ix, iy + 1), at(ix + 1, iy + 1), ax)
    return mix3(top, bottom, ay)


def key(c, focus):
    y = max(dot(c, Y), 0.0)
    k = y / (y + 0.18)
    return clamp(0.5 + (k - 0.5) * (1.0 + 3.0 * focus), 0.0, 1.0)


def luma_key(t, photo):
    k = key(t["photo"] if photo else t["from"], t["focus"])
    m = clamp(t["p"] + t["motion"] * 0.6 * (0.5 - k) * math.sin(PI * t["p"]), 0.0, 1.0)
    ref = mix3(t["from"], t["to"], t["p"])
    c = mix3(t["from"], t["to"], m)
    if photo:
        g = 4.0 * m * (1.0 - m) * t["motion"] * (0.06 + 0.06 * t["energy"])
        c = [c[i] + max(t["photo"][i], 0.0) / (1.0 + max(t["photo"][i], 0.0)) * g for i in range(3)]
    return guard(c, ref), ref


def melt(u, v, t, frm):
    x = u * t["aspect"]
    delay = 0.5 + 0.25 * math.sin(11.0 * x + 1.3) + 0.15 * math.sin(23.0 * x + 4.1) + 0.1 * math.sin(41.0 * x + 2.2)
    order = delay + (0.55 * delay + 0.45 * v - delay) * t["motion"]
    spread = 0.8 + 1.2 * t["focus"]
    qq = clamp(t["p"] * (1.0 + spread) - order * spread, 0.0, 1.0)
    sag = t["motion"] * (0.08 + 0.06 * t["energy"]) * qq * qq
    outgoing = sample(frm, u, v - sag)
    c = mix3(outgoing, t["to"], qq * qq * (3.0 - 2.0 * qq))
    ref = mix3(t["from"], t["to"], t["p"])
    return guard(c, ref), ref


def light_leak(u, v, t):
    p, a = t["p"], t["aspect"]
    env = smooth(0.0, 0.06, p) * (1.0 - p) * (1.0 - p)
    dx = u * a - (0.15 + 0.5 * t["motion"] * p) * a
    dy = v - 0.2
    glow = math.exp(-(dx * dx + dy * dy) / 0.18)
    s = dy + 0.35 * dx
    streak = math.exp(-s * s / 0.012)
    warm = [1.0, 0.62, 0.34]
    wy = dot(warm, Y)
    amount = (0.7 * glow + 0.3 * streak) * env * (0.026 + 0.012 * t["energy"])
    c = [t["to"][i] + warm[i] / wy * amount for i in range(3)]
    return guard(c, t["to"]), list(t["to"])


def beat_iris(u, v, t):
    a, p = t["aspect"], t["p"]
    d = math.hypot((u - 0.5) * a, v - 0.5)
    r_max = 0.5 * math.sqrt(a * a + 1.0)
    w = 0.04 - 0.034 * t["focus"]
    win = math.sin(PI * p)
    kick = 1.0 - t["beatPhase"]
    r = -w + (r_max + 2.0 * w) * p + t["motion"] * (0.02 + 0.02 * t["energy"]) * kick * kick * win
    mask = 1.0 - smooth(r - w, r + w, d)
    ref = mix3(t["from"], t["to"], mask)
    e = (d - r) / (2.0 * w + 0.01)
    rim = [1.0, 0.9, 0.78]
    ry = dot(rim, Y)
    glow = math.exp(-e * e) * win * (0.026 + 0.012 * t["energy"])
    return guard([ref[i] + rim[i] / ry * glow for i in range(3)], ref), ref


def evaluate(style, u, v, t, frm):
    if style == "photoKey":
        return luma_key(t, True)
    if style == "melt":
        return melt(u, v, t, frm)
    if style == "downbeatCutLightLeak":
        return light_leak(u, v, t)
    if style == "beatIris":
        return beat_iris(u, v, t)
    return luma_key(t, False)


def aces(x):
    return clamp(x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0)


def close(a, b, tol=1e-6):
    return all(abs(a[i] - b[i]) <= tol for i in range(3))


def build():
    frm, to, photo = inputs()
    cases = []
    worst_linear = worst_display = 0.0
    for params in PARAMS:
        for style in STYLES:
            for p in PROGRESS:
                out = []
                display_added = 0.0
                for j in range(N):
                    for i in range(N):
                        k = j * N + i
                        u, v = (i + 0.5) / N, (j + 0.5) / N
                        t = dict(params, p=p, **{"from": frm[k], "to": to[k], "photo": photo[k]})
                        c, ref = evaluate(style, u, v, t, frm)
                        added = dot([max(c[n] - ref[n], 0.0) for n in range(3)], Y)
                        assert added <= ADDED_LIGHT + 1e-12, (style, p, params, k, added)
                        dy = dot([aces(c[n]) - aces(ref[n]) for n in range(3)], Y)
                        assert dy <= CELL_CAP, (style, p, params, k, dy)
                        display_added += dy
                        worst_linear, worst_display = max(worst_linear, added), max(worst_display, dy)
                        if p == 0.0 and style != "downbeatCutLightLeak":
                            assert close(c, frm[k]), (style, params, k, c)
                        if p == 1.0 or (p == 0.0 and style == "downbeatCutLightLeak"):
                            assert close(c, to[k]), (style, p, params, k, c)
                        if params["motion"] == 0.0 and style in ("lumaKey", "photoKey"):
                            assert close(c, mix3(frm[k], to[k], p)), (style, p, k, c)
                        out.append(c)
                assert display_added / (N * N) <= CELL_CAP
                cases.append({"style": style, "styleId": STYLES.index(style), "p": p, **params, "expected": out})
    return frm, to, photo, cases, worst_linear, worst_display


def num(v):
    s = f"{v:.6f}"
    return "0.000000" if s == "-0.000000" else s


def rows(img, indent):
    lines = []
    for j in range(N):
        row = ", ".join("[" + ", ".join(num(c) for c in img[j * N + i]) + "]" for i in range(N))
        lines.append(f"{indent}{row}")
    return ",\n".join(lines)


def render():
    frm, to, photo, cases, worst_linear, worst_display = build()
    lines = [
        "{",
        '  "comment": "Written by tools/switch-transition-vectors.py; see README.md. Images are row-major, '
        'top row first, linear RGB.",',
        f'  "size": {N},',
        f'  "tolerance": {TOLERANCE},',
        f'  "addedLight": {{"perPixelLinear": {ADDED_LIGHT}, "cellDisplay": {CELL_CAP}, '
        f'"worstPerPixelLinear": {num(worst_linear)}, "worstPerPixelDisplay": {num(worst_display)}}},',
        f'  "styles": {json.dumps(STYLES)},',
        f'  "progress": {json.dumps(PROGRESS)},',
    ]
    for name, img in (("from", frm), ("to", to), ("photo", photo)):
        lines.append(f'  "{name}": [\n{rows(img, "    ")}\n  ],')
    lines.append('  "cases": [')
    body = []
    for c in cases:
        head = ", ".join(f'"{k}": {json.dumps(c[k])}' for k in ("style", "styleId", "p", "beatPhase", "energy", "focus", "motion", "aspect"))
        body.append(f'    {{{head}, "expected": [\n{rows(c["expected"], "      ")}\n    ]}}')
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
            print("conformance/switch-transition/vectors.json is stale; run tools/switch-transition-vectors.py")
            return 1
        print("conformance/switch-transition/: vectors.json matches the model; contract assertions hold")
        return 0
    os.makedirs(os.path.dirname(VECTORS), exist_ok=True)
    with open(VECTORS, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote conformance/switch-transition/vectors.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
