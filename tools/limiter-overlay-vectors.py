#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write conformance/limiter/overlay-sequences.json, the flash-analyzer overlay vectors.

An independent standard-library model of the overlay rule (OSC-OVERLAY), written from
conformance/limiter/README.md ("Overlay regions") and conformance/overlay/README.md. Rust output
is never used. The analyzer's general rule is modelled as in tools/limiter-region-vectors.py
(red is 0 in every frame here); on top of it:

  - every region also has an overlay tracker, stepped on its luminance with the overlay channel
    (the set overlay's luminance_change, inclusive, and darker_limit; the default overlay's
    0.05 and 1.0 while none is set) and committed only when the frame is admitted;
  - the overlay covers the grid cells its MODE_DAMP_FLASH regions with nonzero strength overlap,
    feather included (conformance/packing/overlay-uniforms.json flashMask);
  - a frame is an overlay transition when more than max_area * cells covered cells complete an
    overlay change; admit also refuses a frame whose overlay transition would put more than
    2 * max_flash_hz overlay transitions in the one-second window;
  - the overlay ring follows the gap and window rules of the general ring.

Usage: python3 tools/limiter-overlay-vectors.py
       python3 tools/limiter-overlay-vectors.py --check   (exit 1 if the file would change)
"""

import json
import math
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
VECTORS = os.path.join(ROOT, "conformance", "limiter", "overlay-sequences.json")

WINDOW_MS = 1000.0
MAX_CREDITED_GAP_MS = 250.0
LUMINANCE_CHANGE = 0.1
DARKER_LIMIT = 0.8
DAMP_FLASH, LIGHT = 32, 1
DEFAULT_OVERLAY = {"luminanceChange": 0.05, "darkerLimit": 1.0, "maxFlashHz": 1.0,
                   "maxArea": 0.0}
CONFIG = {"columns": 6, "rows": 6, "fieldWidth": 1 / 3, "fieldHeight": 1 / 3,
          "maxFieldArea": 0.25, "maxFlashHz": 3, "maxRedFlashes": 3, "redRule": 0}
CAPTION = {"x": 0.1, "y": 0.8, "width": 0.8, "height": 0.15, "corner_radius": 0.01,
           "feather": 0.0, "strength": 1.0, "mode": LIGHT | DAMP_FLASH, "reserved": 0}
MENU = {"x": 0.0, "y": 0.0, "width": 0.3, "height": 0.5, "corner_radius": 0.0,
        "feather": 0.02, "strength": 0.5, "mode": DAMP_FLASH, "reserved": 0}


def quarter(ms):
    return math.floor(ms * 4 + 0.5) / 4


def grid60(count):
    return [quarter(i * 1000 / 60) for i in range(count)]


class Tracker:
    def __init__(self, v):
        self.kind, self.a, self.b, self.counted = "steady", v, v, False

    def copy(self):
        t = Tracker(0)
        t.kind, t.a, t.b, t.counted = self.kind, self.a, self.b, self.counted
        return t

    def begin(self, kind, a, b):
        self.kind, self.a, self.b, self.counted = kind, a, b, False

    def step(self, v, change, darker_limit):
        if self.kind == "steady":
            if v - self.a >= change:
                self.begin("rise", self.a, v)
            elif self.b - v >= change:
                self.begin("fall", self.b, v)
            else:
                self.a, self.b = min(self.a, v), max(self.b, v)
                return False
        elif self.kind == "rise":
            if v >= self.b:
                self.b = v
            elif self.b - v >= change:
                self.begin("fall", self.b, v)
        else:
            if v <= self.b:
                self.b = v
            elif v - self.b >= change:
                self.begin("rise", self.b, v)
        darker = self.a if self.kind == "rise" else self.b
        if not self.counted and darker < darker_limit:
            self.counted = True
            return True
        return False


def covers(r, column, row, columns, rows):
    c0, c1 = column / columns, (column + 1) / columns
    r0, r1 = row / rows, (row + 1) / rows
    f = r["feather"]
    return (r["width"] > 0 and r["height"] > 0 and r["x"] - f < c1
            and r["x"] + r["width"] + f > c0 and r["y"] - f < r1
            and r["y"] + r["height"] + f > r0)


def mask_of(regions, columns, rows):
    return [any(r["mode"] & DAMP_FLASH and r["strength"] > 0 and covers(r, c, w, columns, rows)
                for r in regions)
            for w in range(rows) for c in range(columns)]


def window(field, regions):
    return min(max(math.floor(field * regions + 0.5), 1), regions)


def concurrent(flags, config):
    cols, rows = config["columns"], config["rows"]
    w, h = window(config["fieldWidth"], cols), window(config["fieldHeight"], rows)
    limit = config["maxFieldArea"] * w * h
    return any(
        sum(flags[(y + dy) * cols + x + dx] for dy in range(h) for dx in range(w)) > limit
        for y in range(rows - h + 1) for x in range(cols - w + 1))


def run(config, frames, mode):
    n = config["columns"] * config["rows"]
    general = overlay_t = None
    ring, oring = [], []
    previous, discontinuity = None, False
    rules, mask = None, [False] * n
    reports = []
    for f in frames:
        if "setOverlay" in f:
            rules = f["setOverlay"]["overlay"]
            assert 0 < rules["luminanceChange"] <= LUMINANCE_CHANGE
            assert DARKER_LIMIT <= rules["darkerLimit"] <= 1
            assert 0 <= rules["maxFlashHz"] <= config["maxFlashHz"]
            assert 0 <= rules["maxArea"] <= config["maxFieldArea"]
            mask = mask_of(f["setOverlay"]["regions"], config["columns"], config["rows"])
        if f.get("clearOverlay"):
            rules, mask = None, [False] * n
        if f.get("reset"):
            discontinuity = previous is not None
        now = f["t"]
        lum = f["luminance"] if isinstance(f["luminance"], list) else [f["luminance"]] * n
        cells = sum(mask)
        if previous is None:
            general = [Tracker(v) for v in lum]
            overlay_t = [Tracker(v) for v in lum]
            previous = now
            reports.append(entry(now, True, False, 0, 0, False, rules, False, 0, cells, 0,
                                 False))
            continue
        if discontinuity or now - previous > MAX_CREDITED_GAP_MS:
            ring = [now - (previous - t) for t in ring]
            oring = [now - (previous - t) for t in oring]
        discontinuity, previous = False, now
        ring = [t for t in ring if now - t < WINDOW_MS]
        oring = [t for t in oring if now - t < WINDOW_MS]
        channel = rules or DEFAULT_OVERLAY
        change, darker = channel["luminanceChange"], channel["darkerLimit"]
        new_general = [t.copy() for t in general]
        new_overlay = [t.copy() for t in overlay_t]
        flags = [t.step(v, LUMINANCE_CHANGE, DARKER_LIMIT) for t, v in zip(new_general, lum)]
        stepped = [t.step(v, change, darker) for t, v in zip(new_overlay, lum)]
        oflags = [bool(rules) and m and s for m, s in zip(mask, stepped)]
        g = concurrent(flags, config)
        o = bool(rules) and sum(oflags) > rules["maxArea"] * cells
        admitted = mode == "measure" or (
            (not g or len(ring) + 1 <= 2 * config["maxFlashHz"])
            and (not o or len(oring) + 1 <= 2 * rules["maxFlashHz"]))
        if admitted:
            general, overlay_t = new_general, new_overlay
            if g:
                ring.append(now)
            if o:
                oring.append(now)
        exceeds = len(ring) > 2 * config["maxFlashHz"]
        oexceeds = bool(rules) and len(oring) > 2 * rules["maxFlashHz"]
        reports.append(entry(now, admitted, g, sum(flags), len(ring) / 2, exceeds, rules, o,
                             sum(oflags), cells if rules else 0, len(oring) / 2, oexceeds))
    return reports


def entry(t, admitted, general, general_regions, flashes, exceeds, rules, transition, regions,
          cells, overlay_flashes, overlay_exceeds):
    return {"t": t, "admitted": admitted, "general": general, "generalRegions": general_regions,
            "flashes": flashes, "exceeds": exceeds,
            "overlay": {"active": bool(rules), "transition": transition, "regions": regions,
                        "cells": cells if rules else 0, "flashes": overlay_flashes,
                        "exceeds": overlay_exceeds}}


def bottom(lit, rest, rows=(4, 5)):
    """Luminance per cell: `lit` in the given rows of the 6x6 grid, `rest` elsewhere."""
    return [lit if r in rows else rest for r in range(6) for _ in range(6)]


def corner(lit, rest, count):
    """`lit` in the first `count` cells of the bottom row, `rest` elsewhere."""
    return [lit if r == 5 and c < count else rest for r in range(6) for c in range(6)]


def flicker(times, period_frames, low, high, at=bottom):
    return [{"t": t, "luminance": at(high if (i // period_frames) % 2 else low, 0.1)}
            for i, t in enumerate(times)]


def with_overlay(frames, overlay=None, regions=(CAPTION,)):
    first = dict(frames[0])
    first["setOverlay"] = {"overlay": overlay or DEFAULT_OVERLAY, "regions": list(regions)}
    return [first] + frames[1:]


def case(name, derivation, mode, frames, check=None):
    reports = run(CONFIG, frames, mode)
    if check:
        check(reports)
    if mode == "admit":
        # Re-measuring what was shown never exceeds either the config or the overlay.
        shown, image = [], None
        for f, r in zip(frames, reports):
            if r["admitted"]:
                image = f["luminance"]
            g = {k: v for k, v in f.items() if k != "luminance"}
            g["luminance"] = image
            shown.append(g)
        again = run(CONFIG, shown, "measure")
        assert not any(r["exceeds"] or r["overlay"]["exceeds"] for r in again), name
    return {"name": name, "derivation": derivation, "config": CONFIG, "mode": mode,
            "frames": frames, "expected": reports}


def overlay_transitions(reports):
    return sum(r["overlay"]["transition"] for r in reports)


def cases():
    times = grid60(90)
    small = flicker(times, 3, 0.05, 0.12)  # 0.07 swings at 10 Hz in the caption rows
    bright = flicker(times, 6, 0.85, 0.95)  # darker end above the general limit

    def inert(reports):
        assert not any(r["overlay"]["active"] for r in reports)
        assert not any(r["general"] for r in reports)

    def small_flicker(reports):
        assert not any(r["general"] for r in reports)
        assert overlay_transitions(reports) > 20
        assert any(r["overlay"]["exceeds"] for r in reports)
        assert all(r["overlay"]["cells"] == 12 for r in reports)

    def refused(reports):
        assert sum(not r["admitted"] for r in reports) > 20
        assert max(r["overlay"]["flashes"] for r in reports) <= 1

    def bright_end(reports):
        assert not any(r["general"] for r in reports)
        assert overlay_transitions(reports) > 0

    def no_transition(reports):
        assert overlay_transitions(reports) == 0

    out = [
        case("no-overlay-is-inert",
             "The small caption flicker with no overlay set: no general transitions, no "
             "overlay report.", "measure", small, inert),
        case("caption-small-flicker-measure",
             "0.05 to 0.12 swings at 10 Hz in the 12 caption cells: below the 0.1 general "
             "change, at least the 0.05 overlay change, so overlay transitions only.",
             "measure", with_overlay(small), small_flicker),
        case("caption-small-flicker-admit",
             "The same under admit: overlay transitions beyond 2 a second are refused and the "
             "last admitted image stays.", "admit", with_overlay(small), refused),
        case("bright-darker-end",
             "0.85 to 0.95 at 5 Hz: the darker end is above the general 0.8 limit, below the "
             "overlay's 1.0.", "measure", with_overlay(bright), bright_end),
        case("area-fraction",
             "max_area 0.25 over the caption: flicker in 3 of its 12 cells is not more than a "
             "quarter, so no overlay transition; 4 cells is.", "measure",
             with_overlay(flicker(times, 3, 0.05, 0.12, lambda v, rest: corner(v, rest, 3)),
                          dict(DEFAULT_OVERLAY, maxArea=0.25)), no_transition),
        case("area-fraction-over",
             "The same with 4 flickering cells.", "measure",
             with_overlay(flicker(times, 3, 0.05, 0.12, lambda v, rest: corner(v, rest, 4)),
                          dict(DEFAULT_OVERLAY, maxArea=0.25)), bright_end),
        case("set-and-clear-mid-sequence",
             "The overlay is set at frame 30 and cleared at frame 60; trackers carry over.",
             "admit", set_and_clear(small)),
        case("menu-feather-and-gap",
             "A feathered menu region over the top-left cells, a 400 ms gap and a reset.",
             "measure", gap_frames(), None),
    ]
    return out


def set_and_clear(frames):
    frames = [dict(f) for f in frames]
    frames[30]["setOverlay"] = {"overlay": DEFAULT_OVERLAY, "regions": [CAPTION]}
    frames[60]["clearOverlay"] = True
    return frames


def gap_frames():
    top_left = lambda v, rest: [v if r < 3 and c < 2 else rest for r in range(6) for c in range(6)]
    times = grid60(40)
    frames = flicker(times, 2, 0.2, 0.27, top_left)
    later = [dict(f, t=f["t"] + 1066.75) for f in flicker(grid60(20), 2, 0.2, 0.27, top_left)]
    later[0]["reset"] = True
    frames = frames[:20] + [dict(frames[20], t=frames[19]["t"] + 400.0)] + later
    return with_overlay(frames, dict(DEFAULT_OVERLAY, maxFlashHz=2.0), [MENU])


def refusals():
    base = dict(DEFAULT_OVERLAY)
    return [
        {"name": "zero-change", "overlay": dict(base, luminanceChange=0.0), "regions": [],
         "refused": "LuminanceChange"},
        {"name": "looser-change", "overlay": dict(base, luminanceChange=0.2), "regions": [],
         "refused": "LuminanceChange"},
        {"name": "looser-darker", "overlay": dict(base, darkerLimit=0.5), "regions": [],
         "refused": "DarkerLimit"},
        {"name": "above-one-darker", "overlay": dict(base, darkerLimit=1.5), "regions": [],
         "refused": "DarkerLimit"},
        {"name": "looser-rate", "overlay": dict(base, maxFlashHz=4.0), "regions": [],
         "refused": "MaxFlashHz"},
        {"name": "looser-area", "overlay": dict(base, maxArea=0.5), "regions": [],
         "refused": "MaxArea"},
        {"name": "bad-region", "overlay": base,
         "regions": [dict(CAPTION, mode=LIGHT | 2 | DAMP_FLASH)], "refused": "RegionMode"},
        {"name": "too-many-regions", "overlay": base, "regions": [CAPTION] * 9,
         "refused": "RegionCount"},
    ]


def build():
    doc = {
        "description": "Flash-analyzer overlay sequences (OSC-OVERLAY). Written by "
                       "tools/limiter-overlay-vectors.py; see conformance/limiter/README.md.",
        "sequences": cases(),
        "refusals": refusals(),
    }
    return json.dumps(doc, separators=(",", ":")) + "\n"


def main():
    text = build()
    if "--check" in sys.argv[1:]:
        try:
            with open(VECTORS) as f:
                current = f.read()
        except FileNotFoundError:
            current = None
        if current != text:
            print("overlay-sequences.json differs from tools/limiter-overlay-vectors.py output")
            return 1
        print("overlay-sequences.json matches the model")
        return 0
    with open(VECTORS, "w") as f:
        f.write(text)
    print("wrote", os.path.relpath(VECTORS, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
