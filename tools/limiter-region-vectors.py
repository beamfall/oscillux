#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write conformance/limiter/region-sequences.json to stdout.

The independent check is the hand derivation: each case's transition times, recorded in its
`derivation` and in the README's derivation list, and for measure cases the first exceeding
frame and the peak (for some cases also the flashes at every frame), all worked out by hand.
A Python model of the README's "Region flash analyzer" produces the reports and must agree
with every hand value before anything is written. The model's per-region tracker follows the
same README steps as the Rust analyzer and mirrors its logic, so it is a cross-check of the
window, ring and timeline bookkeeping rather than an independent reading of the tracker.
Every admit case's displayed images are re-measured and must never exceed. Times are multiples of
0.25 ms and so are exact in binary, which keeps every window comparison exact.

The red-rule cases (redRule 1, ISO 9241-391 as quoted in WCAG 2.2 note 3) feed whole colors
(`rgb`). Their chromaticities come from the WCAG 2.2 Understanding page's matrix and u'v'
formulas, written out below in the same operation order as the README; each case's derivation
gives the u'v' points and distances by hand.

Usage: python3 tools/limiter-region-vectors.py > conformance/limiter/region-sequences.json
       python3 tools/limiter-region-vectors.py --check   (exit 1 if the file differs)
"""

import json
import math
import sys
from pathlib import Path

WINDOW_MS = 1000.0
MAX_CREDITED_GAP_MS = 250.0
LUMINANCE_CHANGE = 0.1
DARKER_LIMIT = 0.8
RED_CHANGE = 0.0625
RED_SATURATION = 0.8
RED_CHROMATICITY_CHANGE = 0.2
WCAG20, ISO = 0, 1
DEFAULT_CONFIG = {
    "columns": 16,
    "rows": 16,
    "fieldWidth": 1 / 3,
    "fieldHeight": 1 / 3,
    "maxFieldArea": 0.25,
    "maxFlashHz": 3,
    "maxRedFlashes": 3,
    "redRule": WCAG20,
}
SIX = dict(DEFAULT_CONFIG, columns=6, rows=6)
ONE = dict(DEFAULT_CONFIG, columns=1, rows=1)
REPORT = ("t", "admitted", "general", "red", "generalRegions", "redRegions", "flashes",
          "redFlashes", "exceeds")


def quarter(ms):
    """Rounds a time to the nearest 0.25 ms."""
    return math.floor(ms * 4 + 0.5) / 4


def grid60(end_ms):
    times, i = [], 0
    while quarter(i * 1000 / 60) < end_ms:
        times.append(quarter(i * 1000 / 60))
        i += 1
    return times


# ---- Model, from the README -------------------------------------------------------------


def general_change(d):
    return d >= LUMINANCE_CHANGE


def red_change(d):
    return d > RED_CHANGE


class Tracker:
    """README step 2: steady (low, high), or a rise/fall from a start to a running extreme."""

    def __init__(self, v, is_change, darker_limit):
        self.kind, self.start, self.extreme = "steady", v, v  # steady: start=low, extreme=high
        self.counted = False
        self.is_change, self.darker_limit = is_change, darker_limit

    def copy(self):
        t = Tracker(0, self.is_change, self.darker_limit)
        t.kind, t.start, t.extreme, t.counted = self.kind, self.start, self.extreme, self.counted
        return t

    def begin(self, kind, start, extreme):
        self.kind, self.start, self.extreme, self.counted = kind, start, extreme, False

    def step(self, v):
        """Advances to value v; returns whether this frame completes a change."""
        if self.kind == "steady":
            low, high = self.start, self.extreme
            if self.is_change(v - low):
                self.begin("rise", low, v)
            elif self.is_change(high - v):
                self.begin("fall", high, v)
            else:
                self.start, self.extreme = min(low, v), max(high, v)
                return False
        elif self.kind == "rise":
            if v >= self.extreme:
                self.extreme = v
            elif self.is_change(self.extreme - v):
                self.begin("fall", self.extreme, v)
        else:
            if v <= self.extreme:
                self.extreme = v
            elif self.is_change(v - self.extreme):
                self.begin("rise", self.extreme, v)
        darker = self.start if self.kind == "rise" else self.extreme
        if not self.counted and darker < self.darker_limit:
            self.counted = True
            return True
        return False


def chromaticity(r, g, b):
    """README model step 1 (ISO rule): (u, v, black, saturated) from linear sRGB."""
    x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
    y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
    d = x + 15 * y + 3 * z
    if d == 0:
        return (0.0, 0.0, True, False)
    return (4 * x / d, 9 * y / d, False, r / (r + g + b) >= RED_SATURATION)


class ChromaTracker:
    """README step 2 (ISO rule): bounding boxes of the chromatic and the saturated states shown
    since the last counted change, and whether black was shown."""

    def __init__(self, c):
        self.all, self.sat, self.black = None, None, False
        self.add(c)

    def copy(self):
        t = ChromaTracker((0.0, 0.0, True, False))
        t.all, t.sat, t.black = self.all, self.sat, self.black
        return t

    @staticmethod
    def grow(box, u, v):
        if box is None:
            return (u, u, v, v)
        return (min(box[0], u), max(box[1], u), min(box[2], v), max(box[3], v))

    @staticmethod
    def farther(box, u, v):
        if box is None:
            return False
        du = max(abs(u - box[0]), abs(u - box[1]))
        dv = max(abs(v - box[2]), abs(v - box[3]))
        return math.sqrt(du * du + dv * dv) > RED_CHROMATICITY_CHANGE

    def add(self, c):
        u, v, black, saturated = c
        if black:
            self.black = True
            return
        self.all = self.grow(self.all, u, v)
        if saturated:
            self.sat = self.grow(self.sat, u, v)

    def step(self, c):
        u, v, black, saturated = c
        if black:
            counts = self.sat is not None
        elif saturated:
            counts = self.black or self.farther(self.all, u, v)
        else:
            counts = self.farther(self.sat, u, v)
        if counts:
            self.all, self.sat, self.black = None, None, False
        self.add(c)
        return counts


def window_size(field, regions):
    return min(max(math.floor(field * regions + 0.5), 1), regions)


def concurrent(flags, config):
    """README step 3, by brute force over every window position."""
    cols, rows = config["columns"], config["rows"]
    w, h = window_size(config["fieldWidth"], cols), window_size(config["fieldHeight"], rows)
    limit = config["maxFieldArea"] * w * h
    for y in range(rows - h + 1):
        for x in range(cols - w + 1):
            n = sum(flags[(y + dy) * cols + x + dx] for dy in range(h) for dx in range(w))
            if n > limit:
                return True
    return False


def values(frame, key, n):
    v = frame.get(key, 0)
    return list(v) if isinstance(v, list) else [v] * n


def colors_of(frame, n):
    """One [r, g, b] for every region, or a row-major list of them."""
    rgb = frame["rgb"]
    return [tuple(c) for c in rgb] if isinstance(rgb[0], list) else [tuple(rgb)] * n


def inputs(frame, n, iso):
    """(luminance, WCAG 2.0 red, chromaticity or None) per region, as the analyzer derives them."""
    if "rgb" in frame:
        colors = colors_of(frame, n)
        levels = [from_linear_rgb(*c) for c in colors]
        return ([l for l, _ in levels], [r for _, r in levels],
                [chromaticity(*c) for c in colors])
    assert not iso, "the ISO rule refuses frames without colors"
    return values(frame, "luminance", n), values(frame, "red", n), None


def image_of(frame):
    return {k: frame[k] for k in ("luminance", "red", "rgb") if k in frame}


def run(config, frames, mode):
    """Returns (reports, committed general times, committed red times, displayed images)."""
    n = config["columns"] * config["rows"]
    iso = config["redRule"] == ISO
    general_limit = 2 * config["maxFlashHz"]
    red_limit = 2 * config["maxRedFlashes"]
    lum_t = red_t = None
    rings = {"general": [], "red": []}
    committed = {"general": [], "red": []}
    previous, discontinuity = None, False
    reports, shown, image = [], [], None
    for f in frames:
        now = f["t"]
        if f.get("reset"):
            discontinuity = previous is not None
        assert discontinuity or previous is None or now >= previous
        lum, red, chroma = inputs(f, n, iso)
        if previous is None:
            lum_t = [Tracker(v, general_change, DARKER_LIMIT) for v in lum]
            red_t = ([ChromaTracker(c) for c in chroma] if iso
                     else [Tracker(v, red_change, math.inf) for v in red])
            previous, image = now, image_of(f)
            shown.append(dict(f))
            reports.append(report(now, True, False, False, 0, 0, 0, 0, False))
            continue
        if discontinuity or now - previous > MAX_CREDITED_GAP_MS:
            for k in rings:
                rings[k] = [now - (previous - t) for t in rings[k]]
        discontinuity, previous = False, now
        for k in rings:
            rings[k] = [t for t in rings[k] if now - t < WINDOW_MS]
        new_lum = [t.copy() for t in lum_t]
        new_red = [t.copy() for t in red_t]
        lum_flags = [t.step(v) for t, v in zip(new_lum, lum)]
        red_flags = [t.step(v) for t, v in zip(new_red, chroma if iso else red)]
        g, r = concurrent(lum_flags, config), concurrent(red_flags, config)
        admitted = mode == "measure" or (
            (not g or len(rings["general"]) + 1 <= general_limit)
            and (not r or len(rings["red"]) + 1 <= red_limit))
        if admitted:
            lum_t, red_t, image = new_lum, new_red, image_of(f)
            for k, hit in (("general", g), ("red", r)):
                if hit:
                    rings[k].append(now)
                    committed[k].append(now)
        shown.append(dict(image, t=now))
        ng, nr = len(rings["general"]), len(rings["red"])
        reports.append(report(now, admitted, g, r, sum(lum_flags), sum(red_flags), ng / 2,
                              nr / 2, ng > general_limit or nr > red_limit))
    return reports, committed["general"], committed["red"], shown


def report(t, admitted, general, red, general_regions, red_regions, flashes, red_flashes,
           exceeds):
    return dict(zip(REPORT, (t, admitted, general, red, general_regions, red_regions, flashes,
                             red_flashes, exceeds)))


def from_linear_rgb(r, g, b):
    """README model step 1."""
    luminance = min(1.0, (0.2126 * r + 0.7152 * g) + 0.0722 * b)
    s = r + g + b
    red = (r - g) - b if s > 0 and r / s >= RED_SATURATION else 0.0
    return luminance, red


# ---- Cases --------------------------------------------------------------------------------


def case(name, derivation, config, mode, frames, general, red=(), first_exceeds=None,
         peak=None, red_peak=None, flashes=None, general_regions=None):
    reports, got_general, got_red, shown = run(config, frames, mode)
    if flashes is not None:
        assert [r["flashes"] for r in reports] == list(flashes), (name, reports)
    if general_regions is not None:
        assert [r["generalRegions"] for r in reports] == list(general_regions), name
    assert got_general == list(general), (name, got_general)
    assert got_red == list(red), (name, got_red)
    over = [r["t"] for r in reports if r["exceeds"]]
    assert (over[0] if over else None) == first_exceeds, (name, over[:1])
    if peak is not None:
        assert max(r["flashes"] for r in reports) == peak, name
    if red_peak is not None:
        assert max(r["redFlashes"] for r in reports) == red_peak, name
    if mode == "admit":
        remeasured, _, _, _ = run(config, shown, "measure")
        assert not any(r["exceeds"] for r in remeasured), name
    return {"name": name, "derivation": derivation, "config": config, "mode": mode,
            "frames": frames, "expected": reports}


def alternating(times, period, low, high):
    """`high` when floor(t / period) is odd."""
    return [(t, high if math.floor(t / period) % 2 else low) for t in times]


def cells(n, lit, level):
    return [level if i in lit else 0 for i in range(n)]


def full_screen_cases():
    frames = [{"t": t, "luminance": v} for t, v in alternating(grid60(2000), 50, 0, 0.15)]
    every = [50 * k for k in range(1, 40)]
    admitted = [50, 100, 150, 200, 250, 300, 1050, 1100, 1150, 1200, 1250, 1300]
    return [
        case("full-screen-0.15-10hz-measure",
             "Every region alternates 0 and 0.15 every 50 ms at 60 Hz: each alternation is a "
             "change >= 0.1 with darker image 0, so all 36 regions complete a change at every "
             "50k (k = 1..39). The window holds min(k, 20): exceeds from 350 (seven "
             "transitions), peak 10 flashes.",
             SIX, "measure", frames, every, first_exceeds=350, peak=10),
        case("full-screen-0.15-10hz-admit",
             "The same frames admitted. 50..300 fill the window; later 0.15 frames would rise "
             "from the held 0 image and are refused, 0 frames are admitted. 1050..1300 are "
             "admitted as 50..300 leave; from 1350 the window is full again. At most three "
             "flashes are ever displayed.",
             SIX, "admit", frames, admitted, peak=3),
    ]


def localized_cases():
    block = (14, 15, 20, 21)
    frames = [{"t": t, "luminance": cells(36, block, v)}
              for t, v in alternating(grid60(1150), 50, 0, 0.5)]
    return [
        case("localized-block-10hz-measure",
             "Regions 14, 15, 20, 21 (a 2 by 2 block, 11.1% of the screen) alternate 0 and 0.5 "
             "every 50 ms. The 2 by 2 window at the block holds four completing regions, more "
             "than one, so every 50k (k = 1..22) is a transition: exceeds from 350, peak 10 "
             "flashes. A screen-area rule (more than 25% of the screen) would miss it.",
             SIX, "measure", frames, [50 * k for k in range(1, 23)], first_exceeds=350,
             peak=10),
        case("localized-block-10hz-admit",
             "The same block admitted: 50..300, then 1050 and 1100 as 50 and 100 leave.",
             SIX, "admit", frames, [50, 100, 150, 200, 250, 300, 1050, 1100], peak=3),
    ]


def pair_cases():
    def lit(name, regions, expected, why):
        frames = [{"t": t, "luminance": cells(36, regions, v)}
                  for t, v in alternating(grid60(200), 50, 0, 1)]
        return case(name, why, SIX, "measure", frames, expected, peak=len(expected) / 2)

    return [
        lit("single-region-not-a-flash", (14,), [],
            "Region 14 alternates 0 and 1 every 50 ms. One region is 25% of a 2 by 2 window, "
            "not more, so no transition."),
        lit("distant-regions-not-concurrent", (0, 35), [],
            "Regions 0 and 35 (opposite corners) flash together; no 2 by 2 window holds both."),
        lit("regions-straddling-window-tiles", (1, 2), [50, 100, 150],
            "Regions 1 and 2 (row 0, columns 1 and 2) flash together; the sliding window at "
            "column 1 holds both, so 50, 100 and 150 are transitions."),
        lit("diagonal-regions-in-one-window", (0, 7), [50, 100, 150],
            "Regions 0 and 7 ((0, 0) and (1, 1)); the window at (0, 0) holds both."),
    ]


def steps(levels):
    return [{"t": 100 * i, "luminance": v} for i, v in enumerate(levels)]


def threshold_cases():
    return [
        case("darker-image-boundary",
             "1 by 1 grid. 0.8 <-> 1 has darker image 0.8, not below 0.8: no transition. 0.75 "
             "counts at 400, 500, 600, 700. The fall from 1 to 0.85 at 800 completes only when "
             "it reaches 0.78125 at 900.",
             ONE, "measure", steps([0.8, 1, 0.8, 1, 0.75, 1, 0.75, 1, 0.85, 0.78125]),
             [400, 500, 600, 700, 900], peak=2.5),
        case("change-boundary-and-small-dips",
             "1 by 1 grid. 0.09375 is below the 0.1 change; 0.1 above the low of 0 completes a "
             "rise at 300. Dips of 0.0375 and 0.053125 below the extreme are ignored, the rise "
             "extends to 0.3125, and the fall to 0.1875 (0.125) completes at 1000.",
             ONE, "measure",
             steps([0, 0.09375, 0, 0.1, 0.0625, 0.046875, 0.125, 0.25, 0.1875, 0.3125,
                    0.1875]),
             [300, 1000], peak=1),
    ]


def area_count_case():
    six, seven = (0, 1, 2, 16, 17, 18), (0, 1, 2, 3, 16, 17, 18)
    frames = [{"t": 0, "luminance": 0},
              {"t": 50, "luminance": cells(256, six, 0.5)},
              {"t": 100, "luminance": 0},
              {"t": 150, "luminance": cells(256, seven, 0.5)},
              {"t": 200, "luminance": 0}]
    return case("default-grid-six-vs-seven-regions",
                "Default 16 by 16 grid and field: the window is floor(16 / 3 + 0.5) = 5 regions "
                "a side, 25 regions, and the area limit is 0.25 * 25 = 6.25 regions. Six "
                "regions (rows 0-1, columns 0-2) rise to 0.5 at 50 and fall at 100: 6 is not "
                "more than 6.25, no transition. Seven (adding row 0, column 3; all inside the "
                "5 by 5 window at (0, 0)) rise at 150 and fall at 200: 7 > 6.25, transitions "
                "at 150 and 200.",
                DEFAULT_CONFIG, "measure", frames, [150, 200], peak=1,
                flashes=[0, 0, 0, 0.5, 1], general_regions=[0, 6, 6, 7, 7])


def gap_cases():
    def frames(after):
        return ([{"t": 0, "luminance": 0}, {"t": 50, "luminance": 1}]
                + [{"t": t, "luminance": 1} for t in after])

    return [
        case("gap-250-credited",
             "1 by 1 grid. A transition at 50, then steady frames 250 ms apart (300, 550, 800, "
             "1050). A gap of exactly 250 ms is not above 250, so it is credited: at 1050 the "
             "transition is 1000 ms old and has left the window.",
             ONE, "measure", frames([300, 550, 800, 1050]), [50], peak=0.5,
             flashes=[0, 0.5, 0.5, 0.5, 0.5, 0]),
        case("gap-250.25-uncredited",
             "1 by 1 grid. A transition at 50, then a 250.25 ms gap to 300.25: above 250, so "
             "it credits nothing and the transition keeps its age 0 (now at 300.25). The "
             "later 250 ms gaps are credited: at 1050.25 it is 750 ms old and still counts; "
             "at 1300.25 it is 1000 ms old and has left.",
             ONE, "measure", frames([300.25, 550.25, 800.25, 1050.25, 1300.25]), [50],
             peak=0.5, flashes=[0, 0.5, 0.5, 0.5, 0.5, 0.5, 0]),
    ]


def red_cases():
    lum = from_linear_rgb(0.25, 0, 0)[0]
    frames = []
    for i in range(13):
        on = i % 2 == 1
        frames.append({"t": 125 * i, "luminance": [lum if on else 0, 0],
                       "red": [0.25 if on else 0, 0.0625 if on else 0]})
    pair = dict(DEFAULT_CONFIG, columns=2, rows=1)
    return [
        case("red-8hz-measure",
             "2 by 1 grid, window 1 region. Region 0 alternates red 0 and 0.25 (luminance 0 "
             "and that of (0.25, 0, 0)) every 125 ms: 0.25 > 0.0625 completes at every 125k "
             "(k = 1..12), luminance 0.05315 < 0.1 never does; region 1's 0.0625 is not more "
             "than 0.0625. The red window holds min(k, 8): exceeds from 875, peak 4.",
             pair, "measure", frames, [], [125 * k for k in range(1, 13)],
             first_exceeds=875, peak=0, red_peak=4),
        case("red-8hz-admit-one-red-flash",
             "The same frames admitted with maxRedFlashes 1: 125 and 250 admitted; red frames "
             "refused until 125 leaves; 1125 and 1250 admitted, 1375 refused.",
             dict(pair, maxRedFlashes=1), "admit", frames, [], [125, 250, 1125, 1250],
             peak=0, red_peak=1),
    ]


def red_rule_cases():
    """WCAG 2.0 (redRule 0) against ISO 9241-391 (redRule 1), on whole colors, 1 by 1 grid.

    Hand values, from the WCAG 2.2 Understanding matrix: a red primary (r, 0, 0) has X, Y, Z =
    r * (0.4124564, 0.2126729, 0.0193339), X + 15Y + 3Z = 3.6605516r, so u'v' = (0.45070,
    0.52289) for every r > 0. A blue primary: (0.1804375, 0.0721750, 0.9503041) b, sum
    4.1139748b, u'v' = (0.17544, 0.15789). Grey (g, g, g): sums 0.9504700, 1.0000001,
    1.0888300, u'v' = (0.19784, 0.46834), the D65 white point. Pink (0.25, 0.03125, 0.03125):
    R / (R + G + B) = 0.25 / 0.3125 = 0.8 exactly, so saturated; X = 0.1199270, Y = 0.0777722,
    Z = 0.0382553, u'v' = (0.34234, 0.49951). Distances: red-blue 0.45715, pink-grey 0.14782,
    pink-blue 0.38020. Every color's luminance change stays below 0.1, so no general flash.

    Red plus grey, (0.25, c, c): X = 0.1031141 + 0.5380136c, Y = 0.0531682 + 0.7873272c,
    Z = 0.0048335 + 1.0694961c, on the straight line from the red primary to the white point,
    saturated while 0.25 / (0.25 + 2c) >= 0.8, that is c <= 0.03125. At c = 403/4096 X, Y, Z,
    D = 0.1560485, 0.1306323, 0.1100598, 2.4457124: u'v' (0.255220, 0.480715), 0.199982 from
    red. At c = 404/4096: 0.1561799, 0.1308245, 0.1103209, 2.4495104: (0.255039, 0.480676),
    0.200167 from red. At c = j/128: u'v' and distance from red, j = 0..13: (0.45070, 0.52289)
    0; (0.41408, 0.51499) 0.03746; (0.38515, 0.50874) 0.06706; (0.36171, 0.50369) 0.09104;
    (0.34234, 0.49951) 0.11086; (0.32606, 0.49600) 0.12752; (0.31218, 0.49300) 0.14171;
    (0.30022, 0.49042) 0.15395; (0.28979, 0.48817) 0.16461; (0.28063, 0.48620) 0.17399;
    (0.27251, 0.48445) 0.18229; (0.26527, 0.48288) 0.18970; (0.25877, 0.48148) 0.19635;
    (0.25291, 0.48022) 0.20235. Consecutive points are at most 0.03746 apart. (0.5, 0, 0.25):
    X, Y, Z = 0.2513376, 0.1243802, 0.2472430, D = 2.8587695, u'v' (0.35167, 0.39157).
    (0.5, 0.125, 0.125) is 2 (0.25, 0.0625, 0.0625), so it sits at the j = 8 point.
    """
    red_rule = dict(ONE, redRule=ISO)

    def toggle(low, high, count=13):
        return [{"t": 125 * i, "rgb": list(high if i % 2 else low)} for i in range(count)]

    every = [125 * k for k in range(1, 13)]
    scale = toggle((0.5, 0, 0), (0.25, 0, 0))
    hue = toggle((0.0625, 0, 0), (0, 0, 0.0625))
    grey, blue, pink = (0.03125,) * 3, (0, 0, 0.25), (0.25, 0.03125, 0.03125)
    wander = [{"t": 125 * i, "rgb": list(c)}
              for i, c in enumerate((grey, blue, pink, grey, blue, pink))]
    black = toggle((0, 0, 0), (0.25, 0, 0))
    red = (0.25, 0, 0)
    under = toggle(red, (0.25, 403 / 4096, 403 / 4096))
    over = toggle(red, (0.25, 404 / 4096, 404 / 4096))
    drift = [{"t": 125 * j, "rgb": [0.25, j / 128, j / 128]} for j in range(14)]
    corner = [{"t": 125 * i, "rgb": list(c)}
              for i, c in enumerate(((0.5, 0, 0.25), (0.5, 0.125, 0.125), (0.5, 0, 0)))]
    return [
        case("red-rule-scale-wcag20",
             "Separates the rules. (0.5, 0, 0) and (0.25, 0, 0) alternate every 125 ms "
             "(luminance 0.1063 and 0.05315, change 0.05315 < 0.1). WCAG 2.0: red levels 0.5 "
             "and 0.25 differ by 0.25 > 0.0625, so every 125k (k = 1..12) is a red transition; "
             "exceeds from 875, peak 4.",
             ONE, "measure", scale, [], every, first_exceeds=875, peak=0, red_peak=4),
        case("red-rule-scale-iso",
             "The same frames under ISO 9241-391: both are red primaries at u'v' (0.45070, "
             "0.52289), distance 0 (the power-of-two scale is exact), never more than 0.2: no "
             "red transition.",
             red_rule, "measure", scale, [], [], peak=0, red_peak=0),
        case("red-rule-hue-wcag20",
             "Separates the rules the other way. (0.0625, 0, 0) and (0, 0, 0.0625) alternate "
             "every 125 ms. WCAG 2.0: red levels 0.0625 and 0, a change not more than 0.0625: "
             "no red transition.",
             ONE, "measure", hue, [], [], peak=0, red_peak=0),
        case("red-rule-hue-iso",
             "The same frames under ISO 9241-391: saturated red (0.45070, 0.52289) against blue "
             "(0.17544, 0.15789), 0.45715 apart: every 125k (k = 1..12) is a red transition; "
             "exceeds from 875, peak 4.",
             red_rule, "measure", hue, [], every, first_exceeds=875, peak=0, red_peak=4),
        case("red-rule-wander-wcag20",
             "Grey, blue, pink, grey, blue, pink at 0, 125, .., 625. WCAG 2.0 red levels 0, 0, "
             "0.1875, 0, 0, 0.1875: rise at 250, fall at 375, rise at 625.",
             ONE, "measure", wander, [], [250, 375, 625], peak=0, red_peak=1.5),
        case("red-rule-wander-iso",
             "The same frames under ISO 9241-391. 250: pink (saturated) is 0.38020 from blue, "
             "shown since the baseline: a transition. 375: grey is 0.14782 from pink, not more "
             "than 0.2: none (WCAG 2.0 counts it). 500: blue is 0.38020 from pink: a "
             "transition. 625: pink against blue again: a transition.",
             red_rule, "measure", wander, [], [250, 500, 625], peak=0, red_peak=1.5),
        case("red-rule-black-iso-admit",
             "Black and (0.25, 0, 0) alternate every 125 ms under ISO 9241-391 with "
             "maxRedFlashes 1. Black has no chromaticity; the README counts black against a "
             "saturated red. 125 and 250 are admitted; red frames are refused (the held black "
             "image does not change) until 125 leaves; 1125 and 1250 admitted, 1375 refused.",
             dict(red_rule, maxRedFlashes=1), "admit", black, [], [125, 250, 1125, 1250],
             peak=0, red_peak=1),
        case("red-rule-threshold-under-iso",
             "Just under the threshold. (0.25, 0, 0) and (0.25, c, c) with c = 403/4096 "
             "alternate every 125 ms under ISO 9241-391. The red primary (0.45070, 0.52289) is "
             "saturated; the mixture (0.255220, 0.480715) is 0.199982 from it, not more than "
             "0.2: no red transition. Luminance 0.05315 and 0.13062, change 0.07747 < 0.1.",
             red_rule, "measure", under, [], [], peak=0, red_peak=0),
        case("red-rule-threshold-over-iso",
             "Just over the threshold. The same with c = 404/4096: the mixture (0.255039, "
             "0.480676) is 0.200167 from the red primary, more than 0.2: every 125k (k = 1..12) "
             "is a red transition; exceeds from 875, peak 4. Luminance change 0.07766 < 0.1.",
             red_rule, "measure", over, [], every, first_exceeds=875, peak=0, red_peak=4),
        case("red-rule-drift-iso",
             "Slow drift. (0.25, j/128, j/128) at 125j for j = 0..13 under ISO 9241-391, "
             "moving along the line from the red primary to the white point in steps of at "
             "most 0.03746. j = 0..4 are saturated and held; every later state has smaller u' "
             "and v' than the red primary, so the saturated box's farthest corner is the red "
             "primary and each later state is compared with its true distance from red: "
             "0.12752 at j = 5 rising to 0.19635 at j = 12, "
             "none more than 0.2, then 0.20235 at j = 13: one red transition, at 1625. "
             "Luminance rises from 0.05315 to 0.13312, by 0.07997 < 0.1.",
             red_rule, "measure", drift, [], [1625], peak=0, red_peak=0.5),
        case("red-rule-box-corner-iso",
             "The conservative bounding-box behaviour, not strict Note 3. (0.5, 0, 0.25), "
             "(0.5, 0.125, 0.125), (0.5, 0, 0) at 0, 125, 250 under ISO 9241-391. The first two "
             "are not saturated (R / (R + G + B) = 2/3) and count nothing. The third, the red "
             "primary (0.45070, 0.52289), is 0.16447 from (0.35167, 0.39157) and 0.16461 from "
             "(0.28979, 0.48817): no held state is more than 0.2 away, so Note 3 alone would "
             "not count it. The held box's farthest corner (0.28979, 0.39157) is du 0.16091, "
             "dv 0.13132, 0.20769 away, so the analyzer counts a red transition at 250 (an "
             "over-refusal it documents). Luminance 0.12435, 0.20473, 0.1063: the rise 0.08038 "
             "and fall 0.09843 are below 0.1.",
             red_rule, "measure", corner, [], [250], peak=0, red_peak=0.5),
    ]


def timeline_case():
    frames = steps([0, 1, 0, 1, 0]) + [
        {"t": 2000, "luminance": 1}, {"t": 2100, "luminance": 0}, {"t": 2200, "luminance": 1},
        {"t": 50, "luminance": 0, "reset": True}]
    return case("uncredited-gap-and-reset",
                "1 by 1 grid. Transitions at 100..400; the 1600 ms gap to 2000 credits nothing, "
                "so they keep their ages (1700..2000) and 2000 is the fifth; 2100 and 2200 make "
                "seven, which exceeds. After reset, 0 at 50 is the eighth (earlier ones at "
                "-450..50).",
                ONE, "measure", frames, [100, 200, 300, 400, 2000, 2100, 2200, 50],
                first_exceeds=2200, peak=4)


# Hand-computed decimals; each written value is the documented expression in binary64.
COLORS = [
    ((1, 0, 0), 0.2126, 1),
    ((0, 1, 0), 0.7152, 0),
    ((0, 0, 1), 0.0722, 0),
    ((0, 0, 0), 0, 0),
    ((1, 1, 1), 1, 0),
    ((0.25, 0, 0), 0.05315, 0.25),
    ((0.5, 0.0625, 0.0625), 0.1555125, 0.375),
    ((0.5, 0.0625, 0.0626), 0.15551972, 0),
]
INVALID_COLORS = [(1.5, 0, 0), (0, -0.25, 0)]


def colors():
    out = []
    for rgb, lum, red in COLORS:
        got_lum, got_red = from_linear_rgb(*rgb)
        assert abs(got_lum - lum) <= 1e-15 and got_red == red, (rgb, got_lum, got_red)
        out.append({"rgb": list(rgb), "luminance": got_lum, "red": got_red})
    return out


def validation():
    def v(name, error, **changes):
        return {"name": name, "config": dict(DEFAULT_CONFIG, **changes), "error": error}

    return [
        v("default", None),
        v("one-region", None, columns=1, rows=1),
        v("whole-screen-field", None, fieldWidth=1, fieldHeight=1),
        v("tightened", None, maxFieldArea=0.125, maxFlashHz=2.5, maxRedFlashes=0),
        v("columns-17", "grid", columns=17),
        v("rows-0", "grid", rows=0),
        v("field-width-0", "field", fieldWidth=0),
        v("field-height-1.5", "field", fieldHeight=1.5),
        v("field-area-0.3", "field-area", maxFieldArea=0.3),
        v("field-area-0", "field-area", maxFieldArea=0),
        v("flash-hz-3.5", "flash-hz", maxFlashHz=3.5),
        v("flash-hz-0", "flash-hz", maxFlashHz=0),
        v("red-flashes-4", "red-flashes", maxRedFlashes=4),
        v("red-rule-iso", None, redRule=ISO),
        v("red-rule-2", "red-rule", redRule=2),
    ]


def main():
    cases = (full_screen_cases() + localized_cases() + pair_cases() + threshold_cases()
             + [area_count_case()] + red_cases() + [timeline_case()] + gap_cases()
             + red_rule_cases())
    doc = {
        "description": "Region flash analyzer (README: Region flash analyzer). Each case's "
                       "derivation states how its transitions were worked out by hand; "
                       "tools/limiter-region-vectors.py checks them against a model of the "
                       "README and writes this file.",
        "tolerance": 0,
        "cases": cases,
        "colors": colors(),
        "invalidColors": [list(c) for c in INVALID_COLORS],
        "validation": validation(),
    }
    text = dump(doc)
    assert json.loads(text)["cases"][0]["name"] == cases[0]["name"]
    if sys.argv[1:] == ["--check"]:
        path = Path(__file__).resolve().parent.parent / "conformance/limiter/region-sequences.json"
        if path.read_text() != text:
            sys.exit(f"{path} differs from the generator output; regenerate it")
        print(f"{path.name}: {len(cases)} cases match the generator")
        return
    sys.stdout.write(text)


def number(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)) and float(v).is_integer():
        return str(int(v))
    if isinstance(v, list):
        return "[" + ", ".join(number(x) for x in v) + "]"
    if isinstance(v, dict):
        return inline(v)
    if isinstance(v, str):
        return json.dumps(v)
    return repr(v)


def inline(obj):
    return "{" + ", ".join(f'"{k}": {number(v)}' for k, v in obj.items()) + "}"


def block(key, items, indent, end):
    pad = " " * indent
    lines = [f'{pad}"{key}": [']
    for i, item in enumerate(items):
        lines.append(pad + "  " + inline(item) + ("," if i < len(items) - 1 else ""))
    lines.append(pad + "]" + end)
    return lines


def dump(doc):
    lines = ["{", f'  "description": {json.dumps(doc["description"])},',
             f'  "tolerance": {doc["tolerance"]},', '  "cases": [']
    for ci, c in enumerate(doc["cases"]):
        lines.append("    {")
        for k in ("name", "derivation", "mode"):
            lines.append(f'      "{k}": {json.dumps(c[k])},')
        lines.append(f'      "config": {inline(c["config"])},')
        lines += block("frames", c["frames"], 6, ",")
        lines += block("expected", c["expected"], 6, "")
        lines.append("    }" + ("," if ci < len(doc["cases"]) - 1 else ""))
    lines.append("  ],")
    lines += block("colors", doc["colors"], 2, ",")
    lines.append(f'  "invalidColors": {number(doc["invalidColors"])},')
    lines += block("validation", doc["validation"], 2, "")
    lines += ["}", ""]
    return "\n".join(lines)


if __name__ == "__main__":
    main()
