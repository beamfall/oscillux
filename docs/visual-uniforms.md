<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# visual-uniforms.v1

This page specifies how one analysed audio frame becomes the audio-derived members of the shader
`VisualUniforms` block. It is normative. Where it and the code disagree, the conformance vectors
decide: `conformance/packing/` (reference, descriptor and relative-level paths) and
`conformance/uniforms/` (the two frame-sequence goldens). The implementation is
`crates/oscillux-core/src/mapping.rs`, exposed in C as `oscillux_mapping_*`.

## Inputs

The mapper reads one frame at a time. Hosts that receive the AudioFrame v1 wire form fill a
`DspFrame` from it field for field:

| AudioFrame v1 | `DspFrame` | Used for |
|---|---|---|
| `rms` | `rms` | amplitude gate (`rms > 0`) |
| `loudnessDb` | `loudness_db` | amplitude |
| `spectrum` (24 bands, `[0, 1]`) | `spectrum[..24]`, `band_count = 24` | bass, mid, treble, spectrum, centroid proxy |
| `onset.broadband` | `onset.broadband` | onset, flux proxy |
| `onset.low` | `onset.low` | bassImpact |
| `onset.mid`, `onset.high` | `onset.mid`, `onset.high` | validated only; not mapped |
| `flags` `analysis-gap`, `analysis-stalled` | `flags` `FLAG_GAP`, `FLAG_STALLED` | reset (below) |
| `flags` `live-analysis-unavailable` | the `unavailable` argument | neutral (below) |

`DspFrame`s from Oscillux's own analyzer (`Analyzer::push`) need no translation. AudioFrame v1
carries no DSP descriptors, so its frames are mapped with `Mapper::map` (no descriptors) and
FLUX and CENTROID take the descriptor-less proxies below. A host on Oscillux's analyzer should
use `Mapper::map_with` with the descriptors `Analyzer::push_ext` writes.

A host also supplies, outside the frame:

- the interval at which it calls the mapper, as `MappingConfig::hop_seconds` (the analyzer hop
  when it maps every analysis frame; the render interval, such as 1/60 s, when it maps once per
  rendered frame);
- a Reduce Motion boolean;
- a tap of the decoded PCM being played, from which the frames are analysed, or the
  `live-analysis-unavailable` state when it has none.

Which operating-system setting feeds Reduce Motion, and where each platform taps decoded PCM,
are host policy and belong in the consuming host's documentation.

## Configuration

`MappingConfig::for_dsp(&DspConfig::default())`, equal to `MappingConfig::default()`:

| Field | Value | Meaning |
|---|---|---|
| `loudness_reference` | −18 dB | the analyzer's LUFS reference, added back to `loudness_db` to give dBFS |
| `db_floor` | −60 dB | dBFS that maps to amplitude 0 |
| `hop_seconds` | 512 / 48000 s | interval between mapper calls, `dt` below |
| `release_seconds` | 0.2 s | level release time constant |
| `centroid_floor` | 1e-6 | summed band energy at or below which the centroid is 0 |
| `groups` | [0, 7], [8, 15], [16, 23] | inclusive band ranges for bass, mid, treble |
| level source | absolute | `LevelSource::Relative` is an opt-in (`conformance/packing/README.md`) |

## Uniforms

`clamp01(x)` is `x` clamped to `[0, 1]`, and 0 when `x` is not finite. Slot is the
`Mapped::values` index; member is the `VisualUniforms` field it feeds
(`conformance/packing/visual-uniforms.schema.json` gives offsets).

| Slot | Member | Formula | Smoothing | Clamp |
|---|---|---|---|---|
| 0 | `amplitude` | `dBFS = loudness_db + loudness_reference`; `(dBFS − db_floor) / −db_floor`, so −60 dBFS → 0 and 0 dBFS → 1; 0 when `rms ≤ 0` | none (the analyzer's 300 ms RMS window) | clamp01 |
| 1 | `level` | envelope of amplitude: `L = A` when `A > L_prev`, else `L_prev + α (A − L_prev)` with `α = 1 − exp(−dt / release_seconds)`; `L_prev = A` on the first frame and after a reset | instant attack, exponential release, τ = 0.2 s | clamp01 |
| 2 | `bass` | mean of bands 0–7 | none beyond the analyzer's band ballistics | clamp01 |
| 3 | `mid` | mean of bands 8–15 | as bass | clamp01 |
| 4 | `treble` | mean of bands 16–23 | as bass | clamp01 |
| 5 | `onset` | `onset.broadband` | none | clamp01 |
| 6 | `bassImpact` | `onset.low` | none | clamp01 |
| 7 | `flux` | with descriptors `spectral_flux`; without, `onset.broadband` (deprecated proxy) | none | clamp01 |
| 8 | `spectralCentroid` | with descriptors `log10(centroid_hz / 20) / 3` (20 Hz → 0, 632.46 Hz → 0.5, 20 kHz → 1; 0 at or below 20 Hz); without, `Σ i·b_i / Σ b_i / (n − 1)` (deprecated band-index proxy); 0 when `Σ b_i ≤ centroid_floor` | none | clamp01 |
| — | `spectrum` (16 × vec4) | 64 bins resampled linearly from the `n` bands (below) | none | clamp01, then float32 |

Group means of a range that runs past `band_count` average the bands present, and are 0 when
none is. A frame whose band count exceeds `MAX_BANDS`, or whose `rms`, `loudness_db`, onsets,
bands or descriptors are not finite, is refused (`MappingError`) and leaves the envelope as it
was; the host keeps the previous uniforms for that frame.

### Spectrum 24 → 64

For bin `i` in `0..64` and `n` bands:

- `n = 0`: 0;
- `n = 1`: `clamp01(b_0)`;
- otherwise `p = i / 63 · (n − 1)`, `k = floor(p)`, `t = p − k`, `k1 = min(k + 1, n − 1)`, and
  the bin is `clamp01(b_k · (1 − t) + b_k1 · t)`, computed in double precision and stored as
  float32.

Bin 0 is band 0 and bin 63 is band `n − 1` exactly; there is no nearest-band rounding.

## Reset events

`Mapper::reset` (`oscillux_mapping_reset`) forgets the previous level, so the next available
frame seeds the envelope with its own amplitude instead of releasing from a level that belongs to
other audio. It keeps the level source. The other slots are memoryless.

| Event | Rule |
|---|---|
| Track change | Reset before mapping the first frame of the new item. |
| Seek | Reset before mapping the first frame after the seek. |
| Analysis gap | A frame flagged `analysis-gap` (`FLAG_GAP`): reset, then map that frame. |
| Capture stall | A frame flagged `analysis-stalled` (`FLAG_STALLED`): reset, then map that frame. |
| Stall in progress | A render tick with no new frame reuses the last mapped uniforms. Once the host knows capture has stalled, it maps `unavailable` on each tick until frames resume. |
| Level source change | No reset. |
| Live analysis unavailable | Each unavailable frame sets the previous level to 0 (below); no separate reset. |

The flash limiter, transitions and beat tracking have their own reset rules in their modules;
this page covers only the mapper.

## Live analysis unavailable

A host with no decoded PCM to analyse is in the `live-analysis-unavailable` state. The two
cases are bitstream passthrough (encoded audio sent to an external decoder, so no PCM reaches the
host) and protected (DRM) playback whose PCM the host may not tap. The host signals it by marking
its frames `live-analysis-unavailable` and calling the mapper with `unavailable = 1`
(`Mapper::map(frame, true)`) each tick, with any frame (its contents are ignored).

The mapper then writes the neutral, `Mapped::ZERO`: all nine slots and all 64 bins are 0, and
the previous level becomes 0, so the first available frame attacks to its own amplitude at once.
Host-sourced members (`time`, `dt`, `resolution`, beat clock, palette, presets) are unaffected,
so a visual keeps rendering from time alone. Hosts must not synthesise audio-derived values in
this state.

## Reduce Motion

When the host's Reduce Motion boolean is true, v1 applies the following ceilings. The status
column records what Oscillux enforces today; rows it does not enforce are the host's to apply
until Oscillux encodes them.

| Quantity | v1 value | Oscillux today |
|---|---|---|
| Flashes per second | 0 | Not encoded at 0. The limiter refuses `max_flash_hz ≤ 0` (`Policy` and `FlashConfig` take `(0, 3]`), but its windows count whole events: `Limiter` admits a flash only while the flashes in the last second plus one stay at or below `max_flash_hz`, and `FlashAnalyzer` admits at most `2 · max_flash_hz` transitions a second (two make a flash), so any value below 1 admits no flash in any one-second window. Hosts pass `max_flash_hz = 0.5`, which is 0 flashes. `OverlayConfig::flash_config` under reduced motion caps it at `REDUCED_MOTION_MAX_FLASH_HZ = 1.0`, which admits one flash a second: a host must tighten its base below 1 itself. |
| Luminance ceiling | 0.54 | Not applied automatically. Hosts pass `Policy::max_luminance_delta = 0.54` (allowed: at most 0.8). |
| `bassImpact` | ≤ 0.2 | Not encoded; the mapper clamps to `[0, 1]` only. Hosts apply `min(bassImpact, 0.2)` after mapping. |
| Motion | 0.18 | Not encoded. `VisualUniforms.motion` is a host vec4 (angle, tx, ty, depth) from presets, with no single motion scalar to cap. |
| `trailDecay` | 0 | Not encoded; `trailDecay` is a host value. Hosts write 0. |
| Grain | 0 | No grain member exists in `VisualUniforms`. |
| Temporal keep | 0.6 per 60 Hz frame | Encoded: `REDUCED_MOTION_TEMPORAL_KEEP` (overlay). |
| Luminance step | 0.04 per 60 Hz frame | Encoded: `REDUCED_MOTION_MAX_LUMINANCE_STEP` (overlay). |
| Presentation intensity | × 0.5 | Encoded: `REDUCED_MOTION_INTENSITY` (overlay). |
| Field area, red flashes | ≤ 0.1, ≤ 1 per second | Encoded: `REDUCED_MOTION_MAX_FIELD_AREA`, `REDUCED_MOTION_MAX_RED_FLASHES` (overlay). |

The audio mapping itself does not change under Reduce Motion: the goldens below hold with it on
or off.

## Conformance

`conformance/uniforms/` holds two AudioFrame v1 frame goldens, vendored byte for byte with their
source, commit and sha256 in `inputs/provenance.json`, and the uniforms they map to:
`sine-440.uniforms.golden.json` and `gap-stall-latency.uniforms.golden.json`. They are mapped
one frame per render tick at `dt = 1/60 s` (`hop_seconds = 1/60`, every other field the
default), without descriptors, on the absolute level source, with the reset and unavailable
rules above. `gap-stall-latency` frame 5 is flagged `analysis-gap` and `analysis-stalled`, so its
level equals its amplitude rather than releasing from frame 4.

Tolerance: every scalar uniform within 1e-12 absolute, every spectrum bin bit-exact as float32.
The inputs are already rounded to six decimals by their producer, so the goldens pin the mapping,
not the analyzer.

`tools/uniforms-vectors.py`, using the independent standard-library mapper model of
`tools/mapping-vectors.py`, writes them; `make uniforms-vectors-check` (part of `make gate`)
fails when an input's sha256 or a golden would change. The `uniforms_goldens` test checks the Rust
mapper against the same files.
