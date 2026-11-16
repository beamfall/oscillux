<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# visual-uniforms.v1 goldens

Specification: `docs/visual-uniforms.md`.

`inputs/` holds two AudioFrame v1 frame goldens copied byte for byte from the core repository
(`inputs/provenance.json` names the source path, commit and sha256 of each). They are read-only
inputs here; the producer owns them, and a change there is re-vendored with a new provenance
entry, never edited in place.

| Golden | Input | Frames | sha256 |
|---|---|---|---|
| `sine-440.uniforms.golden.json` | `inputs/sine-440.frames.golden.json` | 12 | `d3802e572823e0f85e8080fac11a0469b84d3c777bc8d6c45866ffbfd1cb8692` |
| `gap-stall-latency.uniforms.golden.json` | `inputs/gap-stall-latency.frames.golden.json` | 10 | `c65ca4dd7edead5c51468abe55253f4336d8b3c899e622bdee6c1757bee9c9e4` |

Each frame maps at `dt = 1/60 s` with the default mapping otherwise, without descriptors (the
AudioFrame carries none, so `flux` repeats `onset` and `spectralCentroid` is the band-index
proxy), on the absolute level source. A frame flagged `analysis-gap` or `analysis-stalled`
resets the level envelope first; one flagged `live-analysis-unavailable` maps as unavailable.
Each golden frame records the input flags, whether it reset, whether it was unavailable, the nine
named uniforms and the 64-bin float32 spectrum.

Tolerance: scalars within 1e-12, spectrum bins bit-exact as float32.

Regenerate with `python3 tools/uniforms-vectors.py`; `make uniforms-vectors-check` fails on any
byte difference or input hash mismatch. `crates/oscillux-core/tests/uniforms_goldens.rs` checks
the Rust mapper against these files.
