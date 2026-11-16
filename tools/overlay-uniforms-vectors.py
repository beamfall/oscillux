#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write conformance/packing/overlay-uniforms.json, the OverlayUniforms packing vectors.

An independent standard-library model of the overlay contract (OSC-OVERLAY), written from
conformance/packing/overlay-uniforms.schema.json and conformance/overlay/README.md. It reads the
schema for every offset, so the schema and the vectors cannot drift apart, and packs each value
with struct.pack('<f') into a zero-initialised 320-byte block. Rust output is never used.

    ceiling  = 1.05 / ratio - 0.05 - 1e-4          (light text, WCAG)
    floor    = 0.05 * ratio - 0.05 + 1e-4          (dark text, WCAG)
    frames   = min(frame_interval_ms / (1000 / 60), 1)
    keep(k)  = 1 - (1 - k) * frames
    outside regions, reduced motion: keep(0.6), step 0.04 * frames; otherwise 0 and 1
    regions: keep(0.9), step 0.01 * frames; blur radius 0.012 viewport heights
    presentation intensity = intensity * (0.5 if reduced motion else 1)

Cases that must be refused carry the refusal name instead of bytes. flash_mask cases pin which
flash-analyzer grid cells MODE_DAMP_FLASH regions cover.

Usage: python3 tools/overlay-uniforms-vectors.py
       python3 tools/overlay-uniforms-vectors.py --check   (exit 1 if the file would change)
"""

import json
import math
import os
import struct
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SCHEMA = os.path.join(ROOT, "conformance", "packing", "overlay-uniforms.schema.json")
VECTORS = os.path.join(ROOT, "conformance", "packing", "overlay-uniforms.json")

MARGIN = 1.0e-4
REFERENCE_FRAME_MS = 1000.0 / 60.0
REGION_KEEP, REGION_STEP = 0.9, 0.01
REDUCED_KEEP, REDUCED_STEP = 0.6, 0.04
REDUCED_INTENSITY = 0.5
BLUR_RADIUS = 0.012
LIGHT, DARK, DESAT, BLUR, DAMP_MOTION, DAMP_FLASH = 1, 2, 4, 8, 16, 32
MODE_MASK = 63

DEFAULT_CONFIG = {
    "viewport_width": 1920.0,
    "viewport_height": 1080.0,
    "contrast_ratio": 4.5,
    "intensity": 1.0,
    "frame_interval_ms": REFERENCE_FRAME_MS,
    "alpha": 1.0,
    "output_levels": 255,
    "reduced_motion": False,
    "premultiplied_alpha": False,
}


def region(x, y, w, h, radius=0.0, feather=0.0, strength=1.0, mode=LIGHT, reserved=0):
    return {"x": x, "y": y, "width": w, "height": h, "corner_radius": radius,
            "feather": feather, "strength": strength, "mode": mode, "reserved": reserved}


def unit(v):
    return 0.0 <= v <= 1.0


def refusal(config, regions):
    """The OverlayError name pack() refuses with, or None. Same order as the core."""
    def positive(v):
        return math.isfinite(v) and v > 0.0
    c = config
    if not positive(c["viewport_width"]) or not positive(c["viewport_height"]):
        return "Viewport"
    if not 1.0 <= c["contrast_ratio"] <= 21.0:
        return "ContrastRatio"
    if not unit(c["intensity"]):
        return "Intensity"
    if not (positive(c["frame_interval_ms"]) and c["frame_interval_ms"] <= 1000.0):
        return "FrameInterval"
    if not unit(c["alpha"]):
        return "Alpha"
    if c["output_levels"] == 1 or c["output_levels"] > 65535:
        return "OutputLevels"
    if len(regions) > 8:
        return "RegionCount"
    for r in regions:
        rect = (r["x"], r["y"], r["width"], r["height"])
        if not all(math.isfinite(v) for v in rect) or r["width"] < 0 or r["height"] < 0:
            return "RegionRect"
        if not unit(r["corner_radius"]) or not unit(r["feather"]):
            return "RegionShape"
        if not unit(r["strength"]):
            return "RegionStrength"
        m = r["mode"]
        if m & ~MODE_MASK or (m & LIGHT and m & DARK) or r["reserved"] != 0:
            return "RegionMode"
    return None


def pack(schema, config, regions):
    c = config
    frames = min(c["frame_interval_ms"] / REFERENCE_FRAME_MS, 1.0)

    def keep(k):
        return 1.0 - (1.0 - k) * frames

    reduced = c["reduced_motion"]
    values = {
        "regionCount": float(len(regions)),
        "luminanceCeiling": 1.05 / c["contrast_ratio"] - 0.05 - MARGIN,
        "luminanceFloor": 0.05 * c["contrast_ratio"] - 0.05 + MARGIN,
        "outputLevels": float(c["output_levels"]),
        "presentationIntensity": c["intensity"] * REDUCED_INTENSITY if reduced else c["intensity"],
        "temporalKeep": keep(REDUCED_KEEP) if reduced else 0.0,
        "maxLuminanceStep": REDUCED_STEP * frames if reduced else 1.0,
        "premultipliedAlpha": 1.0 if c["premultiplied_alpha"] else 0.0,
        "regionTemporalKeep": keep(REGION_KEEP),
        "regionMaxLuminanceStep": REGION_STEP * frames,
        "blurRadius": BLUR_RADIUS,
        "aspect": c["viewport_width"] / c["viewport_height"],
        "outputAlpha": c["alpha"],
        "viewportHeightPx": c["viewport_height"],
        "reducedMotion": 1.0 if reduced else 0.0,
        "reserved": 0.0,
    }
    region_values = {
        "x": "x", "y": "y", "width": "width", "height": "height",
        "cornerRadius": "corner_radius", "feather": "feather", "strength": "strength",
        "mode": "mode",
    }
    out = bytearray(schema["size"])
    for field in schema["fields"]:
        if "count" not in field:
            for i, name in enumerate(field["components"]):
                struct.pack_into("<f", out, field["offset"] + 4 * i, values[name])
            continue
        for index, r in enumerate(regions):
            for i, name in enumerate(field["components"]):
                at = field["offset"] + 16 * index + 4 * i
                struct.pack_into("<f", out, at, float(r[region_values[name]]))
    return bytes(out)


def covers(r, column, row, columns, rows):
    c0, c1 = column / columns, (column + 1) / columns
    r0, r1 = row / rows, (row + 1) / rows
    f = r["feather"]
    x0, x1 = r["x"] - f, r["x"] + r["width"] + f
    y0, y1 = r["y"] - f, r["y"] + r["height"] + f
    return r["width"] > 0 and r["height"] > 0 and x0 < c1 and x1 > c0 and y0 < r1 and y1 > r0


def flash_mask(regions, columns, rows):
    return [
        1 if any(r["mode"] & DAMP_FLASH and r["strength"] > 0 and covers(r, c, w, columns, rows)
                 for r in regions) else 0
        for w in range(rows) for c in range(columns)
    ]


def cfg(**changes):
    out = dict(DEFAULT_CONFIG)
    out.update(changes)
    return out


MENU = region(0.03, 0.05, 0.28, 0.6, radius=0.02, feather=0.015, strength=0.8,
              mode=LIGHT | DESAT | BLUR | DAMP_MOTION | DAMP_FLASH)
CAPTION = region(0.1, 0.82, 0.8, 0.12, radius=0.01, feather=0.01, strength=1.0,
                 mode=LIGHT | DAMP_FLASH)
LIGHT_CARD = region(0.6, 0.1, 0.35, 0.2, radius=0.03, feather=0.0, strength=0.5,
                    mode=DARK | DESAT)

PACK_CASES = [
    ("default-empty", cfg(), []),
    ("menu-and-caption", cfg(), [MENU, CAPTION]),
    ("dark-text-card", cfg(contrast_ratio=7.0), [LIGHT_CARD]),
    ("reduced-motion-30hz", cfg(reduced_motion=True, frame_interval_ms=1000.0 / 30.0,
                                intensity=0.8), [CAPTION]),
    ("reduced-motion-120hz", cfg(reduced_motion=True, frame_interval_ms=1000.0 / 120.0),
     [MENU]),
    ("float-target-premultiplied", cfg(output_levels=0, premultiplied_alpha=True, alpha=0.75,
                                       viewport_width=1080.0, viewport_height=1920.0),
     [CAPTION, LIGHT_CARD]),
    ("ten-bit-wcag-aaa", cfg(output_levels=1023, contrast_ratio=7.0, intensity=0.0), [CAPTION]),
    ("eight-regions", cfg(viewport_width=480.0, viewport_height=270.0),
     [region(0.1 * i, 0.05 * i, 0.1, 0.05, radius=0.005 * i, feather=0.001 * i,
             strength=i / 8.0, mode=(LIGHT if i % 2 else DARK) | (i * 4 & 60))
      for i in range(8)]),
    ("zero-size-region", cfg(), [region(0.5, 0.5, 0.0, 0.0, mode=0, strength=0.0)]),
    ("contrast-one", cfg(contrast_ratio=1.0), [CAPTION]),
    ("contrast-twenty-one", cfg(contrast_ratio=21.0), [LIGHT_CARD]),
    # refusals
    ("refuse-viewport", cfg(viewport_height=0.0), []),
    ("refuse-contrast", cfg(contrast_ratio=0.5), []),
    ("refuse-intensity", cfg(intensity=1.5), []),
    ("refuse-interval", cfg(frame_interval_ms=0.0), []),
    ("refuse-alpha", cfg(alpha=-0.1), []),
    ("refuse-levels", cfg(output_levels=1), []),
    ("refuse-count", cfg(), [CAPTION] * 9),
    ("refuse-rect", cfg(), [region(0.0, 0.0, -0.1, 0.1)]),
    ("refuse-shape", cfg(), [region(0.0, 0.0, 0.1, 0.1, radius=1.5)]),
    ("refuse-strength", cfg(), [region(0.0, 0.0, 0.1, 0.1, strength=2.0)]),
    ("refuse-both-text-modes", cfg(), [region(0.0, 0.0, 0.1, 0.1, mode=LIGHT | DARK)]),
    ("refuse-unknown-mode", cfg(), [region(0.0, 0.0, 0.1, 0.1, mode=64)]),
    ("refuse-reserved", cfg(), [region(0.0, 0.0, 0.1, 0.1, reserved=1)]),
]

MASK_CASES = [
    ("caption-4x4", [CAPTION], 4, 4),
    ("menu-caption-8x6", [MENU, CAPTION], 8, 6),
    ("no-damp-flash", [LIGHT_CARD], 4, 4),
    ("zero-strength", [region(0.0, 0.0, 1.0, 1.0, strength=0.0, mode=DAMP_FLASH)], 3, 3),
    ("edge-touch-excluded", [region(0.5, 0.0, 0.5, 0.5, mode=DAMP_FLASH)], 2, 2),
    ("feather-reaches", [region(0.55, 0.55, 0.2, 0.2, feather=0.1, mode=DAMP_FLASH)], 2, 2),
    ("full-16x16", [region(0.0, 0.0, 1.0, 1.0, mode=DAMP_FLASH | DARK)], 16, 16),
]


def build():
    with open(SCHEMA) as f:
        schema = json.load(f)
    cases = []
    for name, config, regions in PACK_CASES:
        case = {"name": name, "config": config, "regions": regions}
        refused = refusal(config, regions)
        if refused:
            case["refused"] = refused
        else:
            case["bytes"] = pack(schema, config, regions).hex()
        cases.append(case)
    masks = [{"name": name, "regions": regions, "columns": columns, "rows": rows,
              "mask": flash_mask(regions, columns, rows)}
             for name, regions, columns, rows in MASK_CASES]
    doc = {
        "description": "OverlayUniforms packing and flash-mask vectors (OSC-OVERLAY). Written by "
                       "tools/overlay-uniforms-vectors.py from overlay-uniforms.schema.json; "
                       "bytes are the 320-byte little-endian std140 block, hex.",
        "size": schema["size"],
        "pack": cases,
        "flashMask": masks,
    }
    return json.dumps(doc, indent=1, sort_keys=False) + "\n"


def main():
    text = build()
    if "--check" in sys.argv[1:]:
        try:
            with open(VECTORS) as f:
                current = f.read()
        except FileNotFoundError:
            current = None
        if current != text:
            print("overlay-uniforms.json differs from tools/overlay-uniforms-vectors.py output")
            return 1
        print("overlay-uniforms.json matches the model")
        return 0
    with open(VECTORS, "w") as f:
        f.write(text)
    print("wrote", os.path.relpath(VECTORS, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
