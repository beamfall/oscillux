#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write or check the visual-uniforms.v1 goldens in conformance/uniforms/.

Each golden maps one vendored AudioFrame v1 frame golden (conformance/uniforms/inputs/, sha256
pinned in provenance.json) through the mapper, one frame per 60 Hz render tick, as
docs/visual-uniforms.md specifies:

- MappingConfig::default() with hop_seconds = 1/60, so the level release runs at dt = 1/60 s;
- rms, loudnessDb, the 24-band spectrum and onset.broadband/low feed the frame; AudioFrame v1
  carries no DSP descriptors, so FLUX and CENTROID take the descriptor-less proxies;
- a frame flagged analysis-gap or analysis-stalled resets the level envelope before it is
  mapped; one flagged live-analysis-unavailable maps as unavailable (all zeros).

The mapper model is the independent standard-library one in tools/mapping-vectors.py, which
reproduces conformance/packing/reference.json; Rust output is never used. The Rust mapper is
checked against these goldens by crates/oscillux-core/tests/uniforms_goldens.rs.

Usage: python3 tools/uniforms-vectors.py
       python3 tools/uniforms-vectors.py --check   (exit 1 if an input hash or a golden differs)
"""

import hashlib
import importlib.util
import json
import math
import os
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.join(TOOLS, "..", "conformance", "uniforms")
INPUTS = os.path.join(DIR, "inputs")
CASES = ("sine-440", "gap-stall-latency")
DT_SECONDS = 1 / 60
TOLERANCE = {"scalar": 1e-12, "spectrum": 0}
# Mapped::values slot order and the VisualUniforms member each slot feeds.
UNIFORMS = ("amplitude", "level", "bass", "mid", "treble", "onset", "bassImpact", "flux",
            "spectralCentroid")
RESET_FLAGS = ("analysis-gap", "analysis-stalled")
UNAVAILABLE_FLAG = "live-analysis-unavailable"

spec = importlib.util.spec_from_file_location("mapping_vectors", os.path.join(TOOLS, "mapping-vectors.py"))
model = importlib.util.module_from_spec(spec)
spec.loader.exec_module(model)


def read_input(name, provenance):
    entry = next((f for f in provenance["files"] if f["name"] == name), None)
    if entry is None:
        sys.exit(f"uniforms-vectors: {name} is not listed in inputs/provenance.json")
    with open(os.path.join(INPUTS, name), "rb") as handle:
        data = handle.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != entry["sha256"]:
        sys.exit(f"uniforms-vectors: inputs/{name} sha256 {digest} != provenance {entry['sha256']}")
    return json.loads(data), digest


def golden(case, provenance):
    name = f"{case}.frames.golden.json"
    doc, digest = read_input(name, provenance)
    if doc["version"] != "audio-frame.v1":
        sys.exit(f"uniforms-vectors: {name} is {doc['version']!r}, want 'audio-frame.v1'")
    mapper = model.Mapper()
    mapper.alpha = 1.0 - math.exp(-DT_SECONDS / model.RELEASE_SECONDS)
    frames = []
    for frame in doc["frames"]:
        flags = frame.get("flags", [])
        reset = any(f in flags for f in RESET_FLAGS)
        unavailable = UNAVAILABLE_FLAG in flags
        if reset:
            mapper.previous = None
        values, spectrum = mapper.map({
            "unavailable": unavailable,
            "rms": frame["rms"],
            "loudness_db": frame["loudnessDb"],
            "bands": frame["spectrum"],
            "broadband": frame["onset"]["broadband"],
            "low": frame["onset"]["low"],
        })
        frames.append({
            "sequence": frame["sequence"],
            "flags": flags,
            "reset": reset,
            "unavailable": unavailable,
            "uniforms": dict(zip(UNIFORMS, values)),
            "spectrum": spectrum,
        })
    return {
        "contract": "visual-uniforms.v1",
        "generator": "tools/uniforms-vectors.py",
        "spec": "docs/visual-uniforms.md",
        "input": f"inputs/{name}",
        "input_sha256": digest,
        "mapping": {
            "loudness_reference": model.LOUDNESS_REFERENCE,
            "db_floor": model.DB_FLOOR,
            "dt_seconds": DT_SECONDS,
            "release_seconds": model.RELEASE_SECONDS,
            "centroid_floor": model.CENTROID_FLOOR,
            "groups": [list(g) for g in model.GROUPS],
            "level_source": "absolute",
            "descriptors": False,
        },
        "tolerance": TOLERANCE,
        "frames": frames,
    }


def main():
    check = sys.argv[1:] == ["--check"]
    if sys.argv[1:] not in ([], ["--check"]):
        sys.exit(__doc__)
    with open(os.path.join(INPUTS, "provenance.json"), encoding="utf-8") as handle:
        provenance = json.load(handle)
    for case in CASES:
        doc = golden(case, provenance)
        text = model.dump(doc) + "\n"
        path = os.path.join(DIR, f"{case}.uniforms.golden.json")
        sha = hashlib.sha256(text.encode()).hexdigest()
        if check:
            try:
                with open(path, encoding="utf-8") as handle:
                    current = handle.read()
            except FileNotFoundError:
                current = None
            if current != text:
                sys.exit(f"uniforms-vectors: conformance/uniforms/{case}.uniforms.golden.json is "
                         "stale; run python3 tools/uniforms-vectors.py")
            print(f"uniforms-vectors: {case}.uniforms.golden.json matches "
                  f"({len(doc['frames'])} frames, sha256 {sha})")
        else:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
            print(f"uniforms-vectors: wrote {case}.uniforms.golden.json "
                  f"({len(doc['frames'])} frames, sha256 {sha})")


if __name__ == "__main__":
    main()
