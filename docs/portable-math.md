<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Portable numerical interfaces

The numerical authority for these modules is the owner's TypeScript reference
at `7caa4d1`. Swift `ce290a3` supplies independent curve execution and comparable
governor scenarios. Host decisions remain caller data. No device detection,
persistence, renderer policy, shader compilation or arbitrary expressions run here.

## Curves

`Curve` is a typed configuration for constant, easing, envelope and LFO evaluation.
Its C layout uses integer kind/unit/easing/shape tags and explicit presence bits
for optional value/from/to/min/max. The header lists those tag values. The default
is constant zero. Clamp/wrap applies only when both bounds are present; exponential
smoothing follows clamp/wrap and may leave the bounds when previous value lies
outside them. Beat-unit LFOs include the caller's beat phase.

Publication rounds to six decimals with JavaScript's half-toward-positive-infinity
rule, including negative zero. Swift rounds negative exact halves away from zero.
All 263 executed cases agree except the two explicit negative-half probes; the
TypeScript result wins. Non-finite configuration/input fields, invalid tags/flags,
missing required values and non-finite evaluation results are rejected. This is
stricter than the references' incomplete NaN validation. The evaluator owns no
mutable history; previous value and delta are caller input.

## Governor

`GovernorConfig` parameterizes every numerical threshold: 1000/60 ms target,
0.1 EMA alpha, 250 ms pause cutoff, 4× sample cap, 1.002 refresh-estimate drift,
4 ms refresh floor, 1.25× demotion budget, 1.1× refresh/0.75× target promotion
thresholds, 45 demotion frames, 300 promotion frames and 30 settling frames.
Defaults expose four ascending levels, starting at 3; the host supplies the
meaning of levels and may change the maximum and initial levels.

Nonpositive, non-finite and pause samples are ignored without changing state.
The first counted sample initializes the EMA. Refresh tracks a decaying minimum;
strict threshold comparisons drive consecutive streaks, with counters cleared
inside the hysteresis band. A step clears both streaks and begins settling.
Reset clears history and clamps the requested level to the configured maximum.
Counts saturate rather than overflowing. The host owns rung labels, scales,
post-processing settings, initial device estimates and persistence.

### Swift differences

| Behavior | TypeScript-selected behavior | Swift FPS reference |
| --- | --- | --- |
| Precision/input | Double milliseconds | Float seconds |
| Initial EMA | First counted sample | Target budget |
| Refresh estimate | Decaying minimum with 4 ms floor | None |
| Demotion/promotion streaks | 45 / 300 | 12 / 90 |
| Promotion threshold | max(refresh × 1.1, target × 0.75) | target × 0.65 |
| Pause / zero sample | Ignore | Clamp seconds to [0,1], count zero and capped pauses |
| Post-step settling | Skip streak counting for 30 frames | No counting pause; 150 unchanged calls mark persistence readiness |
| Ladder | Ascending levels; host data | Descending indices; different scale/detail/bloom values |
| Seeding/reset | Caller levels, explicit reset | Device-tier or persisted-name seed; no equivalent reset API |

Executed source-test scenarios agree on isolated-hitch stability, sustained
overload and promotion ceiling. Exact cases are named in the governor README.
Measured divergences include healthy 60 Hz recovery, pause gaps, and the shorter
Swift promotion streak. These are recorded; no numeric Swift parity is claimed
for its different controller.

The newer Swift quality governor is a different scheduler: p95/p99 measured
cost, starvation and presented cadence; two coupled quality/Hz ladders; display,
thermal, power and motion clamps; 30/300 streaks and a five-second cooldown;
prospective next-rate headroom; completion-error queue recreation; a ten-second
floor-pressure terminal fallback; and clamped-state persistence suppression.
Its warm-up, coupled-ladder, environmental-clamp, recreation, terminal and Hz-memory
test families have no equivalent input/output in the TypeScript delta controller.
Those host behaviors are intentionally not claimed or silently approximated here.

## Mapping

`Mapper` accepts an existing DSP frame plus explicit availability. Its nine
Double scalar outputs are amplitude, level, bass, mid, treble, onset, bass impact,
flux and normalized centroid. Its 64 spectrum outputs are float32. Defaults match
the reference: -18 loudness reference, -60 dB floor, 512/48000 second hop, 0.2 second
release, 1e-6 centroid floor and inclusive groups [0,7], [8,15], [16,23]. Every
numeric parameter is configurable. Attack is immediate; release is exponential.
Spectrum resampling interpolates linearly before float32 narrowing.

A frame mapped without descriptors (`oscillux_mapping_process`, npm `process` and
`processFrame`, Java `process`) keeps the reference's flux and centroid bit-identically:
flux repeats the broadband onset (all 19 recorded checkpoints) and centroid is the
energy-weighted band index as a fraction of the band range. Both are deprecated proxies.
With the opt-in DSP descriptors (`OscilluxDspFrameExt`, `conformance/dsp/README.md`,
"Descriptors") through the `_ext` mapping calls, flux is `clamp01(spectral_flux)` and
centroid is `clamp01(log10(centroid_hz / 20) / 3)`, so 20 Hz maps to 0, 632 Hz to 0.5 and
20 kHz to 1; it is 0 when the summed band energy is at or below the centroid floor or
`centroid_hz` is at or below 20 Hz. `conformance/packing/descriptors.json`, written by
`tools/mapping-vectors.py`, pins that path; `reference.json` keeps the reference rows.
The opt-in relative level source takes the band groups and spectrum from the AGC's relative
band levels instead of the band energies; `conformance/packing/levels.json` pins it.

Unavailable frames return all zeros and replace previous level with zero. The
next available frame therefore follows the reference's zero previous state.
Reset instead removes previous state and initializes from the next amplitude.
Used non-finite inputs or band counts above 64 fail without changing the envelope.
Finite-input arithmetic overflow follows the reference's zero clamp fallback.

The Swift legacy mapping differs: amplitude is clamped RMS rather than dBFS;
level equals amplitude without the release envelope; band resampling selects
nearest bins; scalar lanes narrow to Float; centroid uses 1e-9 rather than 1e-6;
and beat/prediction/sequence lanes are added by the host. Its group averages
assume the full 24-band array and do not clamp, unlike the selected reference.
This module adds no beat estimator; such lanes can be supplied as host values.

## Uniform block schema and C contract

A `Field` names mapped scalars (source 0), mapped spectrum (source 1), or host
scalars (source 2), with a source component offset, component count, byte offset
and byte stride. Layouts support up to 256 fields of 1–64 components. Every
component is a little-endian IEEE float32; there is no implicit backend layout.
Offsets/strides must be four-byte aligned, strides at least four, and block size
positive and four-byte aligned. Construction rejects overflow, overlap, invalid
sources and mapped-source bounds. Fields are copied at creation.

Packing validates referenced values, float32 overflow, host bounds and output
capacity before writing. Padding within the block is zero; bytes beyond the block
are untouched. Errors leave the full output unchanged. Non-referenced host values
are not consumed. Float32 underflow is allowed; negative zero is preserved.

C handles are opaque. Create allocates; steady-state calls perform no allocation,
locking or I/O. All pointers must be valid and aligned for their declared types,
handles exclusive, and writable buffers disjoint from input/handle storage.
Zero-length host arrays accept null. Buffer byte lengths are checked before Rust
slices are constructed. Flags are validated uint32 values, avoiding unchecked C
booleans. Panic guards and common status codes are shared with the earlier ABI.

The explicit packing fixtures specify this typed layout only. They are **not**
`visual-uniforms.v1` goldens. `packing::visual_uniforms` is the Packer layout of the
shader `VisualUniforms` block, generated from
`conformance/packing/visual-uniforms.schema.json` (`docs/shader-toolchain.md`). That future contract has no goldens in the pinned
references; `conformance/uniforms` is deliberately absent.

## DSP bit-exactness

The DSP conformance test asserts a bit-pattern digest of every fixture's full-precision output
(`crates/oscillux-core/tests/dsp_conformance.rs`), in addition to the published tolerance. The
same digests must hold on every target, so drift inside the tolerance still fails.

When the maths changes on purpose, the vectors under `conformance/` stay unchanged and must still
pass within tolerance. Run the test on the host and under `make test-wasi`, check that both print
the same new digests, then update the values in the test and record the old and new digests with
the reason in the change's description.

DSP behaviour version 1 is the analysis those vectors and digests specify, and it stays frozen.
Version 2 (`OscilluxDspVersionedConfig`) is a separate behaviour, not a change to version 1:
- its vectors are under `conformance/dsp/v2/`, with expected values from an independent oracle;
- its digests are in the same test.

A change to either version follows the rule above for that version's vectors and digests.
