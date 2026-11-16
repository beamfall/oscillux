<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Feature mapping and explicit layout vectors

The pinned TypeScript `audioFrameToVisualInputs` at `7caa4d1` produced all expected
mapped values in `reference.json`. Its source test cases supply group/onset/centroid mapping, dBFS
amplitude, attack/release, unavailable output, and actual reference-DSP input.
Additional cases pin normal → unavailable → normal state, empty/single-band
resampling, and finite out-of-range clamping. Nineteen checkpoints cover 518 frame
evaluations; `repeat` retains long-release coverage without duplicated rows.

The source DSP executed a synthetic 440 Hz signal for the end-to-end case.
Mapped values were packed independently with JavaScript `DataView.setFloat32`
using explicit little-endian writes into a zero-initialized 352-byte block.
The schema includes all nine scalar inputs, all 64 spectrum bins, two host values,
strided fields and padding. Rust output was never used as a golden.

### FLUX and CENTROID with descriptors (OSC-MAPPER-FEATURES)

In `reference.json` `values[7]` FLUX repeats `values[5]` ONSET in all 19 checkpoints and
`values[8]` CENTROID is a band-index centroid. Frames mapped without descriptors keep these
deprecated proxies bit-identically. With the opt-in DSP descriptors (`OscilluxDspFrameExt`)
FLUX is `clamp01(spectral_flux)` and CENTROID is `clamp01(log10(centroid_hz / 20) / 3)`, 0
when the summed band energy is at or below the 1e-6 centroid floor or `centroid_hz` ≤ 20 Hz.

`descriptors.json` pins that path with the same layout. `tools/mapping-vectors.py`, an
independent standard-library model, wrote it: two TypeScript cases with an
`input.descriptors` (`centroid_hz`, `spectral_flux`) added keep their recorded slots 0–6 and
spectrum and take slots 7 and 8 from the model, and the
`OSC-MAPPER-FEATURES:flux-centroid-edges` case (every slot from the model) pins the 20 Hz,
632.46 Hz and 20 kHz points, clamping, the centroid floor, a frame without descriptors and
unavailable input. Each checkpoint is packed with `struct.pack('<f')`; ten checkpoints cover
ten evaluations. The model also reproduces all nine slots of every `reference.json`
checkpoint within 1e-12 and its packed bytes exactly, without changing it. `make gate` runs
`tools/mapping-vectors.py --check`.

### Relative levels (OSC-MAPPER-AGC-LEVELS)

`oscillux_mapping_set_level_source(OSCILLUX_MAPPING_LEVELS_RELATIVE)` is an opt-in per mapper.
BASS, MID and TREBLE become the mean of each configured band group over the ext frame's
`levels.relative_bands`, clamped to [0, 1], and the 64-bin spectrum resamples those levels
exactly as the default resamples the band energies. AMPLITUDE, LEVEL, ONSET, BASS_IMPACT,
FLUX and CENTROID still read the frame and descriptors; CENTROID keeps the band energies. The
relative source refuses available input without levels, with a levels band count other than
the frame's, or with a non-finite relative band, and a refusal leaves the level envelope
unchanged. Unavailable input still writes all zeros. The default source is unchanged, so
`reference.json` and `descriptors.json` are unchanged.

`levels.json` pins that path with the same layout and `"level_source": "relative"`. Its
`OSC-MAPPER-AGC-LEVELS:relative-levels` case, every slot from the model, gives each frame's
input a `levels.relative_bands` with one entry per band. It covers quiet band energies under
full relative contrast, a ramp across the spectrum, clamping above 1 and below 0, a level
release over 20 repeats, flux above 1, zero band energy and unavailable input: seven
checkpoints over 26 evaluations. Every frame carries descriptors, because the C call reads
them from any ext frame.

Scalar tolerance is 1e-12. The float32 spectrum, all packed bytes, padding and
layout checks are exact. The schema is a task-local fixture for the typed packing
API; future `visual-uniforms.v1` goldens do not exist and were not invented.
Malformed geometry, overlap, arithmetic overflow, float32 overflow, insufficient
buffers and failure-without-partial-writes have separate focused regressions.

## VisualUniforms layout

`visual-uniforms.schema.json` declares the shader `VisualUniforms` block (see
`docs/shader-toolchain.md`). `visual-uniforms.json` is generated from it by
`tools/shader/uniforms.mjs`: std140 member offsets (equal to Metal for the allowed
types), the Packer fields, and one 448-byte block packed with JavaScript
`DataView.setFloat32` from distinct float32-exact inputs. Its offsets were checked
against glslangValidator 16.6.0 reflection and Metal `offsetof` assertions when
recorded. It pins the layout only, not
mapped values, and is not a `visual-uniforms.v1` golden. Bytes are exact.
