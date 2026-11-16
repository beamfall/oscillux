#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Check conformance/packing/reference.json and write conformance/packing/descriptors.json and
conformance/packing/levels.json.

The pinned TypeScript reference (revision 7caa4d1) produced every mapped value in
reference.json. In it, values[7] FLUX repeats values[5] ONSET in all 19 checkpoints and
values[8] CENTROID is a band-index centroid. Frames mapped without descriptors keep those
deprecated proxies. OSC-MAPPER-FEATURES maps both from the opt-in DSP descriptors when a frame
has them:

    FLUX     = clamp01(spectral_flux)
    CENTROID = clamp01(log10(centroid_hz / 20) / 3), or 0 when the summed band energy is at or
               below the 1e-6 centroid floor or centroid_hz <= 20 Hz

This script is an independent standard-library model of the mapper, written from
conformance/packing/README.md and docs/portable-math.md. It never changes reference.json: it
checks that the model reproduces all nine recorded slots (within 1e-12) and the float32 spectrum
(exactly), and that packing the recorded values with struct.pack('<f') gives the recorded bytes.
descriptors.json holds the descriptor path: two TypeScript cases with descriptor inputs added
(slots 0-6 and the spectrum as TypeScript recorded them, slots 7 and 8 from this model) and one
case of its own (every slot from this model), each checkpoint packed with struct.pack('<f')
into the zero-initialised block. Rust output is never used.

OSC-MAPPER-AGC-LEVELS adds the relative level source, an opt-in that maps BASS, MID, TREBLE
and the spectrum from the AGC's relative band levels exactly as the default maps the band
energies; every other slot still reads the frame. levels.json holds one case of its own on that
source (every slot from this model, "level_source": "relative"), each frame's input carrying
levels.relative_bands with one entry per band.

Usage: python3 tools/mapping-vectors.py
       python3 tools/mapping-vectors.py --check   (exit 1 if descriptors.json or levels.json
                                                   would change)
"""

import copy
import json
import math
import os
import struct
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
REFERENCE = os.path.join(ROOT, "conformance", "packing", "reference.json")
DESCRIPTORS = os.path.join(ROOT, "conformance", "packing", "descriptors.json")
LEVELS = os.path.join(ROOT, "conformance", "packing", "levels.json")

# MappingConfig::for_dsp(DspConfig::default()), as docs/portable-math.md states it.
LOUDNESS_REFERENCE = -18.0
DB_FLOOR = -60.0
HOP_SECONDS = 512 / 48000
RELEASE_SECONDS = 0.2
CENTROID_FLOOR = 1e-6
GROUPS = ((0, 7), (8, 15), (16, 23))
SPECTRUM_BINS = 64
CENTROID_MIN_HZ = 20.0
CENTROID_DECADES = 3.0
FLUX, CENTROID = 7, 8
TS_PREFIX = "TS-source-test:"
TOLERANCE = 1e-12

# Descriptor inputs added to TypeScript cases, one entry per frame (None: mapped without).
TS_DESCRIPTORS = {
    "TS-source-test:band-groups-onsets-centroid": [
        {"centroid_hz": 1000, "spectral_flux": 0.35},
    ],
    "TS-source-test:clamp-overshoot": [
        {"centroid_hz": 40000, "spectral_flux": 2},
    ],
}


def edge_case():
    """FLUX and CENTROID boundaries, a frame without descriptors between frames with them, and
    unavailable input."""
    bands = [0.5] * 8 + [0.25] * 8 + [0.125] * 8
    base = {"rms": 0.1, "loudness_db": -2, "bands": bands, "broadband": 0.6, "low": 0.1}

    def frame(descriptors, **changes):
        item = dict(base, unavailable=False)
        item.update(changes)
        if descriptors is not None:
            item["descriptors"] = {"centroid_hz": descriptors[0], "spectral_flux": descriptors[1]}
        return {"repeat": 1, "input": item}

    frames = [
        frame((20, 0)),  # the lower edge maps to 0
        frame((20 * 10**1.5, 0.25)),  # 632.46 Hz, half way
        frame((20000, 1)),  # the upper edge maps to 1
        frame((10, -0.5)),  # below 20 Hz and negative flux clamp to 0
        frame((1000, 0.5), bands=[0.0] * 24),  # no band energy: centroid 0, flux kept
        frame((1000, 0.5), bands=[CENTROID_FLOOR]),  # energy equal to the floor: centroid 0
        frame(None),  # mapped without descriptors: the onset and band-index proxies
        frame((1000, 0.5), unavailable=True),  # unavailable: all 0
    ]
    return {"source": "OSC-MAPPER-FEATURES:flux-centroid-edges", "frames": frames}


def levels_case():
    """The relative level source: band groups and spectrum from the relative levels, clamping,
    a level release over repeats and unavailable input. Every frame carries descriptors: the C
    call reads them from any ext frame, so a relative frame always has them."""
    bands = [0.5] * 8 + [0.25] * 8 + [0.125] * 8
    ramp = [i / 23 for i in range(24)]
    base = {"rms": 0.1, "loudness_db": -2, "bands": bands, "broadband": 0.6, "low": 0.1}

    def frame(relative, repeat=1, descriptors=(1000, 0.5), **changes):
        item = dict(base, unavailable=False)
        item.update(changes)
        item["descriptors"] = {"centroid_hz": descriptors[0], "spectral_flux": descriptors[1]}
        item["levels"] = {"relative_bands": relative}
        return {"repeat": repeat, "input": item}

    frames = [
        # Quiet absolute bands, full relative contrast: groups 1, 0.5, 0.
        frame([1.0] * 8 + [0.5] * 8 + [0.0] * 8, bands=[0.01] * 24),
        frame(ramp),  # a ramp, resampled across the 64 bins
        frame([1.5] * 8 + [-0.25] * 8 + [0.75] * 8),  # above 1 and below 0 clamp
        frame(ramp[::-1], repeat=20, loudness_db=-30),  # the level releases from the frame
        frame([0.25] * 24, descriptors=(5000, 1.25)),  # flux above 1 clamps
        frame([0.0] * 24, bands=[0.0] * 24),  # no band energy: centroid 0, groups 0
        frame([0.5] * 24, unavailable=True),  # unavailable: all 0
    ]
    return {"source": "OSC-MAPPER-AGC-LEVELS:relative-levels", "frames": frames}


def clamp01(value):
    return min(max(value, 0.0), 1.0) if math.isfinite(value) else 0.0


def f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


class Mapper:
    def __init__(self):
        self.alpha = 1.0 - math.exp(-HOP_SECONDS / RELEASE_SECONDS)
        self.previous = None

    def map(self, item, relative=False):
        if item["unavailable"]:
            self.previous = 0.0
            return [0.0] * 9, [0.0] * SPECTRUM_BINS
        bands = item["bands"]
        # BASS, MID, TREBLE and the spectrum read the shaped levels; the rest read the frame.
        shaped = item["levels"]["relative_bands"] if relative else bands
        if len(shaped) != len(bands):
            sys.exit("mapping-vectors: relative_bands needs one entry per band")
        rms = item["rms"]
        if rms > 0:
            amplitude = clamp01((item["loudness_db"] + LOUDNESS_REFERENCE - DB_FLOOR) / -DB_FLOOR)
        else:
            amplitude = 0.0
        previous = amplitude if self.previous is None else self.previous
        if amplitude > previous:
            level = amplitude
        else:
            level = previous + self.alpha * (amplitude - previous)
        values = [0.0] * 9
        values[0] = amplitude
        values[1] = clamp01(level)
        for slot, (low, high) in zip((2, 3, 4), GROUPS):
            chosen = shaped[low : high + 1]
            values[slot] = clamp01(math.fsum(chosen) / len(chosen)) if chosen else 0.0
        values[5] = clamp01(item["broadband"])
        values[6] = clamp01(item["low"])
        descriptors = item.get("descriptors")
        total = math.fsum(bands)
        if descriptors is not None:
            values[FLUX] = clamp01(descriptors["spectral_flux"])
            hz = descriptors["centroid_hz"]
            if total <= CENTROID_FLOOR or hz <= CENTROID_MIN_HZ:
                values[CENTROID] = 0.0
            else:
                values[CENTROID] = clamp01(math.log10(hz / CENTROID_MIN_HZ) / CENTROID_DECADES)
        else:
            # The deprecated proxies: the broadband onset, and the energy-weighted band index
            # as a fraction of the band range.
            values[FLUX] = clamp01(item["broadband"])
            if total <= CENTROID_FLOOR or len(bands) < 2:
                values[CENTROID] = 0.0
            else:
                weighted = math.fsum(i * v for i, v in enumerate(bands))
                values[CENTROID] = clamp01(weighted / total / (len(bands) - 1))
        spectrum = []
        for i in range(SPECTRUM_BINS):
            if not shaped:
                spectrum.append(0.0)
            elif len(shaped) == 1:
                spectrum.append(f32(clamp01(shaped[0])))
            else:
                position = i / (SPECTRUM_BINS - 1) * (len(shaped) - 1)
                low = math.floor(position)
                high = min(low + 1, len(shaped) - 1)
                t = position - low
                spectrum.append(f32(clamp01(shaped[low] * (1.0 - t) + shaped[high] * t)))
        self.previous = values[1]
        return values, spectrum


def pack(fields, block_size, values, spectrum, host):
    block = bytearray(block_size)
    sources = (values, spectrum, host)
    for field in fields:
        source = sources[field["source"]]
        for k in range(field["components"]):
            value = source[field["source_offset"] + k]
            struct.pack_into("<f", block, field["offset"] + k * field["stride"], value)
    return list(block)


def number(value):
    """JavaScript Number.prototype.toString, which wrote the TypeScript-recorded file."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int) or value == int(value) and abs(value) < 1e21:
        return str(int(value))
    sign = "-" if value < 0 else ""
    mantissa, exponent = repr(abs(value)).lower().partition("e")[::2]
    whole, _, fraction = mantissa.partition(".")
    digits = (whole + fraction).lstrip("0")
    point = len(whole) + int(exponent or 0) - (len(whole + fraction) - len(digits))
    digits = digits.rstrip("0")
    if 0 < point <= 21:
        return sign + digits[:point] + ("." + digits[point:] if digits[point:] else "")
    if -6 < point <= 0:
        return sign + "0." + "0" * -point + digits
    tail = ("." + digits[1:]) if len(digits) > 1 else ""
    return f"{sign}{digits[0]}{tail}e{'+' if point - 1 >= 0 else '-'}{abs(point - 1)}"


def dump(value, indent=0):
    """JSON.stringify(value, null, 2)."""
    pad, inner = "  " * indent, "  " * (indent + 1)
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = [f"{inner}{json.dumps(k, ensure_ascii=False)}: {dump(v, indent + 1)}" for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[]"
        return "[\n" + ",\n".join(inner + dump(v, indent + 1) for v in value) + "\n" + pad + "]"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    return number(value)


def check_reference(doc):
    """Checks reference.json against the model; returns its checkpoint and evaluation counts."""
    checkpoints = evaluations = 0
    for case in doc["cases"]:
        mapper = Mapper()
        for index, step in enumerate(case["frames"]):
            at = f"reference.json {case['source']} frame {index}"
            if "descriptors" in step["input"]:
                sys.exit(f"{at}: descriptor inputs belong in descriptors.json")
            for _ in range(step["repeat"]):
                values, spectrum = mapper.map(step["input"])
                evaluations += 1
            for slot, want in enumerate(step["values"]):
                if abs(values[slot] - want) > TOLERANCE:
                    sys.exit(f"{at} slot {slot}: model {values[slot]!r}, TypeScript {want!r}")
            if spectrum != step["spectrum"]:
                sys.exit(f"{at}: spectrum differs from TypeScript")
            packed = pack(doc["fields"], doc["block_size"], step["values"], step["spectrum"], step["host"])
            if packed != step["bytes"]:
                sys.exit(f"{at}: struct.pack of the recorded values differs from the recorded bytes")
            checkpoints += 1
    return checkpoints, evaluations


def record(reference):
    """Returns descriptors.json's document and its checkpoint and evaluation counts."""
    cases = [copy.deepcopy(c) for c in reference["cases"] if c["source"] in TS_DESCRIPTORS]
    if len(cases) != len(TS_DESCRIPTORS):
        sys.exit("mapping-vectors: a TypeScript case named in TS_DESCRIPTORS is missing")
    cases.append(edge_case())
    checkpoints = evaluations = 0
    for case in cases:
        recorded = case["source"].startswith(TS_PREFIX)
        added = TS_DESCRIPTORS.get(case["source"])
        mapper = Mapper()
        for index, step in enumerate(case["frames"]):
            item = step["input"]
            if recorded and added[index] is not None:
                item["descriptors"] = dict(added[index])
            for _ in range(step["repeat"]):
                values, spectrum = mapper.map(item)
                evaluations += 1
            if recorded:
                # reference.json's check already matched slots 0-6 and the spectrum.
                values = step["values"][:FLUX] + values[FLUX:]
                spectrum = step["spectrum"]
            step["values"] = values
            step["spectrum"] = spectrum
            step.setdefault("host", [2.5, 0.75])
            step["bytes"] = pack(reference["fields"], reference["block_size"], values, spectrum, step["host"])
            # The reference.json key order: repeat, input, values, spectrum, host, bytes.
            case["frames"][index] = {k: step[k] for k in ("repeat", "input", "values", "spectrum", "host", "bytes")}
            checkpoints += 1
    doc = {
        "generator": "tools/mapping-vectors.py",
        "tolerance": reference["tolerance"],
        "block_size": reference["block_size"],
        "fields": reference["fields"],
        "cases": cases,
    }
    return doc, checkpoints, evaluations


def record_levels(reference):
    """Returns levels.json's document and its checkpoint and evaluation counts."""
    case = levels_case()
    checkpoints = evaluations = 0
    mapper = Mapper()
    for index, step in enumerate(case["frames"]):
        for _ in range(step["repeat"]):
            values, spectrum = mapper.map(step["input"], relative=True)
            evaluations += 1
        step["values"] = values
        step["spectrum"] = spectrum
        step["host"] = [2.5, 0.75]
        step["bytes"] = pack(reference["fields"], reference["block_size"], values, spectrum, step["host"])
        checkpoints += 1
    doc = {
        "generator": "tools/mapping-vectors.py",
        "level_source": "relative",
        "tolerance": reference["tolerance"],
        "block_size": reference["block_size"],
        "fields": reference["fields"],
        "cases": [case],
    }
    return doc, checkpoints, evaluations


def write_or_check(path, text, check):
    name = os.path.basename(path)
    if check:
        try:
            with open(path, encoding="utf-8") as handle:
                current = handle.read()
        except FileNotFoundError:
            current = None
        if current != text:
            sys.exit(f"mapping-vectors: conformance/packing/{name} is stale; "
                     "run python3 tools/mapping-vectors.py")
        print(f"mapping-vectors: {name} matches")
        return
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def main():
    check = sys.argv[1:] == ["--check"]
    if sys.argv[1:] not in ([], ["--check"]):
        sys.exit(__doc__)
    with open(REFERENCE, encoding="utf-8") as handle:
        reference = json.load(handle)
    checkpoints, evaluations = check_reference(reference)
    print(f"mapping-vectors: reference.json {checkpoints} checkpoints, {evaluations} evaluations; "
          f"all nine TypeScript slots within {TOLERANCE:g}, spectrum and packed bytes exact")
    doc, checkpoints, evaluations = record(reference)
    print(f"mapping-vectors: descriptors.json {checkpoints} checkpoints, {evaluations} evaluations")
    write_or_check(DESCRIPTORS, dump(doc) + "\n", check)
    doc, checkpoints, evaluations = record_levels(reference)
    print(f"mapping-vectors: levels.json {checkpoints} checkpoints, {evaluations} evaluations")
    write_or_check(LEVELS, dump(doc) + "\n", check)


if __name__ == "__main__":
    main()
