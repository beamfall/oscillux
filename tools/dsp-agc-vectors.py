#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write the adaptive level normaliser vectors under conformance/dsp/music/agc/ (OSC-DSP-AGC).

An independent standard-library model of the normaliser that conformance/dsp/music/README.md
("Adaptive levels") specifies. It shares no code with crates/oscillux-core/src/dsp/agc.rs. It
uses only IEEE double addition, subtraction, multiplication, division and comparisons, so the
Rust normaliser must reproduce every output bit for bit.

Each vector file holds a synthetic stream of band levels (quantised to n / 256 so they are
exact), the configuration, every eighth output row, and an FNV-1a digest over all output rows.

Usage: python3 tools/dsp-agc-vectors.py
       python3 tools/dsp-agc-vectors.py --check   (exit 1 if a generated file differs)
"""

import filecmp
import math
import os
import struct
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT_DIR = os.path.join(ROOT, "conformance", "dsp", "music", "agc")


def positive(v):
    """v if it is above 0, else +0."""
    return v if v > 0.0 else 0.0


def unit(v):
    """v limited to [+0, 1]."""
    return positive(v) if v < 1.0 else 1.0


def clean(v):
    """Finite inputs are limited to [0, 1]; anything else reads as 0."""
    return unit(v) if math.isfinite(v) else 0.0


class Range:
    """A running maximum and minimum that jump outward at once and relax toward the input, and a
    reference maximum that jumps up at once and relaxes more slowly."""

    def __init__(self, k, kr, floor, gate):
        self.k, self.kr, self.floor, self.gate = k, kr, floor, gate
        self.hi = self.lo = self.reference = 0.0

    def first(self, x):
        self.hi = self.lo = self.reference = x

    def relative(self, x):
        if x > self.reference:
            self.reference = x
        else:
            self.reference = self.reference + self.kr * (x - self.reference)
        self.hi = x if x > self.hi else self.hi + self.k * (x - self.hi)
        self.lo = x if x < self.lo else self.lo + self.k * (x - self.lo)
        return self.read(x)

    def read(self, x):
        span = self.hi - self.lo
        if span >= self.floor:
            base = self.lo
        else:
            span = self.floor
            base = positive((self.hi + self.lo - span) / 2.0)
        # Noise gate: 0 while the running maximum is the gate depth or more below the reference,
        # 1 from one minimum range closer.
        return unit((x - base) / span) * unit((self.hi - self.reference + self.gate) / self.floor)


class Agc:
    def __init__(self, sample_rate_hz, hop_samples, bands, groups, db_floor, time_constant_s,
                 min_range_db, gate_db, reference_time_constant_s):
        h = hop_samples / sample_rate_hz
        k = h / (time_constant_s + h)
        floor = min_range_db / -db_floor
        kr = h / (reference_time_constant_s + h)
        gate = gate_db / -db_floor
        self.bands, self.groups = bands, groups
        self.band_ranges = [Range(k, kr, floor, gate) for _ in range(bands)]
        self.group_ranges = [Range(k, kr, floor, gate) for _ in groups]
        self.primed = False

    def update(self, spectrum):
        """(relative_groups, absolute_groups, relative_bands) for one frame."""
        levels = [clean(spectrum[b]) for b in range(self.bands)]
        absolute = []
        for a, b in self.groups:
            total = 0.0
            for q in range(a, b + 1):
                total += levels[q]
            absolute.append(total / float(b - a + 1))
        if not self.primed:
            self.primed = True
            for r, x in zip(self.band_ranges, levels):
                r.first(x)
            for r, x in zip(self.group_ranges, absolute):
                r.first(x)
            rel_bands = [r.read(x) for r, x in zip(self.band_ranges, levels)]
            rel_groups = [r.read(x) for r, x in zip(self.group_ranges, absolute)]
        else:
            rel_bands = [r.relative(x) for r, x in zip(self.band_ranges, levels)]
            rel_groups = [r.relative(x) for r, x in zip(self.group_ranges, absolute)]
        return rel_groups, absolute, rel_bands


# --- Synthetic input streams --------------------------------------------------------------------

class Lcg:
    """The 64-bit LCG of conformance/dsp/README.md: uniform values in [0, 1)."""

    def __init__(self, seed):
        self.state = seed

    def next(self):
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        return (self.state >> 11) / 2.0 ** 53


def q256(v):
    return max(0, min(256, int(math.floor(v * 256.0 + 0.5))))


def stream(sections, bands, period, seed):
    """Quantised band levels per frame. Each section is (frames, kind, offset): "beat" is a
    decaying pulse every `period` frames over a band-dependent bed, shifted by `offset`; "steady"
    holds `offset` with slight noise; "hiss" is `offset` plus about 6 dB of uniform jitter;
    "sweep" moves a peak across the bands; "silence" is 0."""
    rng, rows, n = Lcg(seed), [], 0
    for frames, kind, offset in sections:
        for _ in range(frames):
            pulse = 0.9 ** (n % period)
            row = []
            for b in range(bands):
                tilt = 1.0 - 0.5 * b / bands
                if kind == "beat":
                    v = offset + 0.35 * tilt + 0.3 * pulse * tilt + 0.05 * rng.next()
                elif kind == "steady":
                    v = offset + 0.01 * rng.next()
                elif kind == "hiss":
                    v = offset + 0.07 * rng.next()
                elif kind == "sweep":
                    centre = (n % 200) * bands / 200.0
                    v = offset + 0.4 / (1.0 + (b - centre) * (b - centre)) + 0.05 * rng.next()
                else:
                    v = 0.0
                row.append(q256(v))
            rows.append(row)
            n += 1
    return rows


VECTORS = (
    {
        "name": "agc-default",
        "description": "default configuration (24 bands, groups 0-7, 8-15, 16-23), default "
                       "normaliser; beats, the same 30 dB quieter (half gated), silence, a "
                       "steady level, a moving peak, then quiet hiss (-87 to -81 dB) under the "
                       "noise gate",
        "config": {"sample_rate_hz": 48000, "hop_samples": 512, "spectrum_bands": 24,
                   "db_floor": -90.0, "onset_band_groups": ((0, 7), (8, 15), (16, 23))},
        "agc": {"time_constant_s": 4.0, "min_range_db": 12.0, "gate_db": 36.0,
                "reference_time_constant_s": 600.0},
        "sections": ((400, "beat", 0.15), (400, "beat", -0.18), (200, "silence", 0.0),
                     (300, "steady", 0.4), (300, "sweep", 0.3), (1200, "hiss", 0.03)),
        "period": 47, "seed": 4242,
    },
    {
        "name": "agc-config-32k",
        "description": "32 kHz, hop 256, 16 bands, groups 0-4, 5-10, 11-15, dB floor -80; "
                       "time constant 1.5 s, minimum range 18 dB, noise gate 20 dB below a "
                       "reference that relaxes over 10 s",
        "config": {"sample_rate_hz": 32000, "hop_samples": 256, "spectrum_bands": 16,
                   "fft_window_samples": 1024, "spectrum_min_hz": 50.0,
                   "spectrum_max_hz": 12000.0, "db_floor": -80.0,
                   "onset_band_groups": ((0, 4), (5, 10), (11, 15))},
        "agc": {"time_constant_s": 1.5, "min_range_db": 18.0, "gate_db": 20.0,
                "reference_time_constant_s": 10.0},
        "sections": ((300, "steady", 0.5), (500, "beat", 0.0), (200, "silence", 0.0),
                     (500, "sweep", 0.2)),
        "period": 83, "seed": 99,
    },
)


def config_value(v):
    if isinstance(v, tuple):
        return ",".join("%d-%d" % g for g in v)
    return repr(v) if isinstance(v, float) else str(v)


def fnv1a(data, h=0xcbf29ce484222325):
    for byte in data:
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def vector_text(spec):
    cfg, ac = spec["config"], spec["agc"]
    bands = cfg["spectrum_bands"]
    rows = stream(spec["sections"], bands, spec["period"], spec["seed"])
    agc = Agc(cfg["sample_rate_hz"], cfg["hop_samples"], bands, cfg["onset_band_groups"],
              cfg["db_floor"], ac["time_constant_s"], ac["min_range_db"], ac["gate_db"],
              ac["reference_time_constant_s"])
    lines = [
        "# dsp-agc-vectors v1",
        "# %s: %s" % (spec["name"], spec["description"]),
        "# expected values: tools/dsp-agc-vectors.py (independent oracle); floats are shortest "
        "round-trip decimal",
    ]
    lines += ["config %s %s" % (k, config_value(v)) for k, v in cfg.items()]
    lines += ["agc_config %s %s" % (k, config_value(v)) for k, v in ac.items()]
    lines.append("# in spectrum[%d] (each value n / 256)" % bands)
    lines += ["in " + " ".join(str(v) for v in row) for row in rows]
    lines.append("# out frame relative_groups[3] absolute_groups[3] relative_bands[%d] "
                 "(every 8th frame)" % bands)
    digest = 0xcbf29ce484222325
    for n, row in enumerate(rows):
        rel_groups, absolute, rel_bands = agc.update([v / 256.0 for v in row])
        values = rel_groups + absolute + rel_bands
        digest = fnv1a(struct.pack("<I%dd" % len(values), bands, *values), digest)
        if n % 8 == 0:
            lines.append("out %d %s" % (n, " ".join(repr(v) for v in values)))
    lines.append("digest %016x" % digest)
    print("%-15s %d frames, digest %016x" % (spec["name"], len(rows), digest))
    return "\n".join(lines) + "\n"


def generate(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for spec in VECTORS:
        with open(os.path.join(out_dir, spec["name"] + ".vectors"), "w") as handle:
            handle.write(vector_text(spec))


def check():
    with tempfile.TemporaryDirectory() as fresh:
        generate(fresh)
        wanted = sorted(os.listdir(fresh))
        have = sorted(os.listdir(OUT_DIR)) if os.path.isdir(OUT_DIR) else []
        _, changed, errors = filecmp.cmpfiles(fresh, OUT_DIR, wanted, shallow=False)
        extra = [n for n in have if n not in wanted]
        problems = changed + errors + extra
    if problems:
        sys.exit("conformance/dsp/music/agc/ differs from the oracle output (changed, missing or "
                 "extra: %s); regenerate it" % ", ".join(problems))
    print("conformance/dsp/music/agc/: %d files match the oracle" % len(wanted))


def main():
    if sys.argv[1:] == ["--check"]:
        check()
    elif sys.argv[1:]:
        sys.exit("usage: python3 tools/dsp-agc-vectors.py [--check]")
    else:
        generate(OUT_DIR)


if __name__ == "__main__":
    main()
