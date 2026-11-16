<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# DSP vectors

The owner's Go reference at revision `0b4e16f5c` generated these vectors, except
`silence-44k1-chunked` (see below). Its `DefaultDSPConfig`, `AnalyzeWAV` and
`AnalyzePCMChunks` are the oracle. All audio is synthetic, mono, signed 16-bit PCM, and
at most two seconds long. The Go vectors are 48 kHz. They specify DSP behaviour version 1;
version 2 has its own vectors under `v2/` (see "Behaviour version 2"). Edge cases (44.1 kHz, a
non-default configuration, stereo anti-phase, replaced non-finite input) and synthetic music
scores are under `music/`, described in `music/README.md`.

| Fixture | Signal | Duration | Frames |
| --- | --- | --- | --- |
| sine-440 | 440 Hz sine, amplitude 0.5 | 0.5 s | 43 |
| sines-low-mid-high | 60/1000/6000 Hz sines, amplitudes 0.25/0.2/0.15 | 0.5 s | 43 |
| noise-white | Uniform noise, amplitude ±0.4 | 0.5 s | 43 |
| kicks-120bpm | Decaying pitch sweep every 0.5 s, offbeat noise | 2 s | 184 |
| silence | Digital silence | 0.25 s | 20 |
| sweep-40-16k | Exponential 40–16000 Hz sine sweep, amplitude 0.4 | 1 s | 90 |
| chunked-gap-stall | 0.7 × kick signal plus 330 Hz sine, amplitude 0.2 | 1.5 s | 127 |
| silence-44k1-chunked | Digital silence at 44.1 kHz, two chunks (analytic) | 0.25 s | 14 |

## Analytic 44.1 kHz fixture

`silence-44k1-chunked` is not Go output. Its expected values are closed-form, so no
reference analyzer is involved. The input is 11025 zero samples (0.25 s), mono 16-bit PCM
at 44.1 kHz, analyzed with the default configuration at `sample_rate_hz = 44100`. There
are two chunks: samples 0–5000 at 0 ms, then samples 5000–11025 at 300 ms with
`stalled` set. Each chunk emits a frame for each window end `2048 + 512k` that fits
inside it, so 6 and 8 frames. Each frame's time is
`chunk_start_ms + (2048 + 512k) / 44100 · 1000`, published with six decimals (half
away from zero). RMS, onsets and bands are 0, and loudness is
`20·log10(1e-9) + 18 = -162`. The first frame of the second chunk carries gap and
stall (flags 3), because 300 ms is far past the previous frame plus one hop
(104.49 + 11.61 ms). The fixture pins sample-rate-dependent frame count, timing, gap
accounting and floors. It cannot pin band edges or spectral and onset values, which
still need the Go reference run at 44.1 kHz. `music/kicks-44k1` is that run.

## Generation

An uncommitted scratch Go test in the reference package synthesized each signal,
called `WAV16Mono`, decoded that WAV through `PCMFromWAV`, then called `AnalyzeWAV`
or `AnalyzePCMChunks`. The test was run with `DSP_FIXTURE_OUT` selecting this
output directory and `-run TestScratchDSPFixtures -count=1 -timeout 30m`.
The scratch generator is deliberately outside this repository. Regeneration must
use the pinned reference, never Rust output as the expected result.

Encoding clamps samples to [-1, 1], rounds `sample * 32767` with Go's half-away
rule, and decodes signed samples by dividing by 32768. Noise uses a 64-bit LCG:
`state = state * 6364136223846793005 + 1442695040888963407` (wrapping), then
`(state >> 11) / 2^53 - 0.5`. The noise fixture uses seed
`0x9e3779b97f4a7c15` and multiplier 0.8; the kick signal uses seed 12345.
For each kick, `t` is time since the half-second boundary, phase is
`2π(50t + 100(1-exp(-30t))/30)`, and amplitude is `0.9 exp(-12t)`.
Offbeat noise has amplitude `0.25 exp(-80th)`, with `th` offset by 0.25 s.
The sweep phase is `2π · 40 / log(400) · (exp(t log(400)) - 1)`.

Each `.frames` file contains a signal description, optional `chunk` rows
(`media_start_ms begin_sample end_sample stalled`), and `frame` rows:
sequence, flags, media time, RMS, loudness, broadband/low/mid/high onset, then
24 smoothed spectrum bands. Flags are gap=1 and stalled=2. Feature values are
Go's published six-decimal outputs. Chunk boundaries deliberately include a
sub-window stalled chunk that produces no frames, a gap plus stall, and a
following contiguous chunk. The row count and exact flags are checked.

## Comparison and reference differences

Published absolute tolerances are 0.02 ms for time and 1e-6 for RMS, loudness,
every onset and every spectrum band. Rust retains full floating-point outputs;
the test reports both raw error and error after rounding to six decimals.
It also prints per-fixture output digests for host/WASI comparison.

All numeric configuration defaults match the Go reference. Its fixed algorithm
constants (RMS floor 1e-9, onset peak decay 0.995 and peak floor 1e-9) are exposed
as configuration fields. Hann windowing, average channel mixdown and the onset
algorithm are the reference algorithms. Rust uses a radix-2 FFT instead of Go's
direct DFT, precomputes tables, and owns all streaming buffers after creation.
Transcendentals use `libm`; no fast-math or explicit fused multiply-add is used.
FFT summation-order differences are checked against Go, within its tolerances.
Gap accounting uses Go's published timestamp rounding before the next segment.
The analyser has no tempo or beat estimator. The optional beat tracker and adaptive
levels in `music/README.md` consume its frames and have no Go reference.

The secondary TypeScript reference at `7caa4d1` has identical numeric defaults and
feature formulas. Differences from Go are:

- Its spectrum transform is a radix-2 FFT with cached Hann/scratch buffers;
  Go uses a direct DFT.
- JavaScript `Math.round` rounds negative exact halves toward positive infinity;
  Go rounds away from zero. This affects negative half cases in feature
  publication and WAV quantization. These vectors come from Go.
- TypeScript omits descriptive configuration strings and the tolerance metadata.
- A zero host-step option is preserved by TypeScript's nullish default; Go treats
  zero as unspecified. Host scheduling metadata is outside this DSP ABI.
- TypeScript adds explicit streaming state and a start-offset for RMS history.
  Rust's streaming ring preserves history within each segment; explicit segment
  boundaries follow Go's independent chunk windows and retained feature state.

## Behaviour version 2

Version 2 is Oscillux's own revision of the analysis (OSC-DSP-LOW-BANDS, OSC-DSP-ONSET-NORM,
OSC-DSP-HOP-COST). Everything above describes version 1, which stays frozen bit for bit: the
ABI-1 functions `oscillux_dsp_config_default` and `oscillux_dsp_create` always run it, and
`OscilluxDspVersionedConfig` selects it with `behavior_version = OSCILLUX_DSP_BEHAVIOR_V1`.
`oscillux_dsp_versioned_config_default` selects version 2. The vectors above keep their
expected values and digests and pass at version 1.

Version 2 keeps version 1's configuration fields, framing, segments, gap and stall flags, Hann
main window, magnitude scaling (`|X_k| / (N/2)`), dB mapping, ballistics, loudness and
publication. Only the items below differ. `fs` is `sample_rate_hz`, `N` is
`fft_window_samples`, and band `b` spans `[lo, hi)` with `lo = spectrum_min_hz · r^b`,
`hi = lo · r`, `r = (spectrum_max_hz / spectrum_min_hz)^(1 / spectrum_bands)`.

- **Band weights.** A band reads a triangle over the bins whose frequency `f` lies strictly
  inside `(lo, hi)`: `(f - lo) / (c - lo)` up to the apex `c = sqrt(lo · hi)`, then
  `(hi - f) / (hi - c)`, normalised to sum 1. A band with no bin inside reads the magnitude
  linearly interpolated at `c` between bins `floor(c / Δf)` and the next (clamped to the last
  pair). The raw level is the dB mapping of the weighted magnitude sum. At the default
  configuration no two bands share a bin.
- **Bass spectrum.** The decimation factor `D` is the smallest power of two with
  `fs ≤ 6000 · D`; above 256 there is no bass analysis. The decimated rate is `fd = fs / D`,
  the window `L = min(1024, floor(fd · 1024 / 6000))` decimated samples, and the FFT length
  `M` is `L` rounded up to a power of two. Bass bands are the longest leading run of bands
  with `(hi - lo) · N / fs < 4` and `hi ≤ 0.1 · fd`. There is no bass analysis when the run is
  empty or `L · D ≤ N`. Decimated sample `j` of a segment is
  `Σ_t h_t · x[(j + 1)D - 1 - t]`, with `x = 0` before the segment start and `h` the
  coefficients of `((1 + z + … + z^(D-1)) / D)^4`. A frame whose main window ends after `e`
  samples of the segment takes the newest `min(floor(e / D), L)` decimated samples into the
  last slots of an `L`-sample Hann window (zeros before them), zero-pads to `M`, and divides
  magnitudes by `L / 2`. Bass bands use the triangle rule on bins `k · fs / (D · M)`, and each
  unit-sum weight is multiplied by the droop correction `1 / H(f)`,
  `H(f) = (sin(D x) / (D sin x))^4`, `x = π f / fs`, `H(0) = 1`.
- **Onsets.** Four detectors: broadband over `[spectrum_min_hz, spectrum_max_hz)`, and each band
  group over `[lo of its first band, hi of its last band)`. Each sums `|X_k|²` of the main bins
  with `lo ≤ k · fs / N < hi`, multiplies by `N / Σ w_n²` (Hann `w`) and maps the square root
  to a dB level as the bands do. The analyzer's first frame outputs 0 and stores the levels.
  Later frames output `flux / max(peak, onset_peak_floor, 0.01)` with
  `flux = max(0, level - previous)` and `peak = max(flux, peak · onset_peak_decay)` starting
  at 0. Previous levels and peaks persist across segments, as in version 1.
- **RMS** has version 1's definition. Squared samples are summed in 64-sample blocks as they
  arrive, which changes only rounding order.
- **Transforms.** Both spectra use a real-input FFT (a half-length complex FFT of packed
  samples). The specification is the DFT; the transform affects rounding only.

At 48 kHz `D = 8`, `fd = 6000 Hz`, `L = M = 1024` (8192 input samples) and bands 0–8 read
the bass spectrum. Their Hann-plus-FIR group delay is `1023 · 8 / 2 + 4 · 7 / 2 = 4106`
samples (85.5 ms), against 21.3 ms for the main window. 44.1 kHz also has 9 bass bands. At
16 kHz and below the main window already resolves the low bands, and bass analysis is off.

### Oracle and fixtures

`tools/dsp-v2-vectors.py` writes `conformance/dsp/v2/`. It is an independent standard-library
Python model of this section. It shares no code with the Rust analyzer and computes with a full
complex FFT, direct sums and direct FIR convolution. Expected values come only from it; Rust
output is compared within the published tolerances and is never copied in. The script first
checks that its kick generator reproduces `kicks-120bpm.wav` byte for byte. With `--check` it
writes into a temporary directory instead and exits 1 if any file in `conformance/dsp/v2/` is
changed, missing or not generated; `make gate` runs it. The version 2 `.frames` files use the
same row format, inputs and chunk rows as the version 1 fixtures, plus:

| Fixture | Signal | Duration | Frames |
| --- | --- | --- | --- |
| kicks-120bpm-long | The kick signal above, extended | 6 s | 559 |
| sine-60-full | 60 Hz sine at 16-bit full scale | 0.5 s | 43 |

Recorded Rust output digests (`dsp_conformance`, host and wasm32-wasip1):

| Fixture | Version 1 (unchanged) | Version 2 |
| --- | --- | --- |
| sine-440 | `74c868cd5273acf1` | `0def95f952ebe422` |
| sines-low-mid-high | `dcf705f6eea59063` | `23c21dbdc56eceb2` |
| noise-white | `5a73e7b341770481` | `2ecf414eb8d88a99` |
| kicks-120bpm | `a71546da9bc34982` | `74b3def0fc89c3cc` |
| silence | `07b662d4d723c2f2` | `07b662d4d723c2f2` |
| sweep-40-16k | `c748664d459d22e0` | `ce0581de1b4b5212` |
| chunked-gap-stall | `d7f4b8cc937ee90d` | `3703c2d3dd1fca96` |
| silence-44k1-chunked | `1d08652ff1a4e6d9` | `1d08652ff1a4e6d9` |
| kicks-120bpm-long | (none) | `c04862bf9dcdf474` |
| sine-60-full | (none) | `e98a49f12ba53c27` |

### Divergence from the Go reference

The Go reference `0b4e16f5c` implements version 1 only. Version 2 diverges from it in the
band mapping (triangular weights, decimated bass spectrum), the onset detector (range energy
flux with a 0.01 floor instead of band-delta flux), and RMS rounding order. Its vectors
therefore come from the in-repo oracle above, not from Go. Until the upstream contract adopts
version 2, a host that needs Go-identical features selects version 1.

Run host fixtures with `cargo test -p oscillux-core --test dsp_conformance -- --nocapture`.
Run WASI with `CARGO_TARGET_WASM32_WASIP1_RUNNER=wasmtime cargo test -p oscillux-core
--target wasm32-wasip1 -- --nocapture` (one shell command).

`cargo test -p oscillux-ffi` discovers exports recursively in every Rust module,
compares parameter order, exact types, constness, pointer depth and return types
against the header, and verifies constants. A host C11 compiler checks Rust's
actual structure sizes, alignments, field offsets and field types against the
header. Mutation regressions reject same-arity signatures and structure drift.

## Behaviour version 3

Version 3 (OSC-DSP-BEAT-REAL) produces version 2's frames bit for bit, so the `v2/` vectors also
specify its analysis. Only its beat tracker differs; `music/README.md`, "Beat tracker" and
"Version 3", specify it, and `music/beat/beat-v3-*.vectors` hold its vectors.

## Descriptors

`oscillux_dsp_push_ext_f32` / `_f64` (Rust `Analyzer::push_ext`) write an
`OscilluxDspDescriptors` beside every frame (OSC-DSP-DESCRIPTORS). The analyzer computes them on
every hop whichever push function is called, so frames from `push` and `push_ext` are
bit-identical, and behaviour version 1 and 2 frames and their vectors above are unchanged. The
header defines each field and its range.

`descriptors/` holds the vectors. `tools/dsp-descriptors-vectors.py` writes them using only the
Python standard library; `make dsp-descriptors-vectors-check` (part of `make gate`, about 10 s)
fails when the directory differs from a fresh run. The oracle shares no code with the analyzer
and computes differently where the definitions allow: direct-form I filters instead of
transposed direct form II, exact `math.fsum` window sums instead of differences of quantised
cumulative sums, and one complex FFT of two real windows. `crates/oscillux-core/tests/dsp_descriptors.rs`
compares the analyzer with them on the host and on wasm32-wasip1 (`make test-wasi`).

| File | Content | Rust tolerance |
| --- | --- | --- |
| `k-weighting.json` | Shelf and RLB high-pass biquads at 8, 11.025, 16, 22.05, 32, 44.1, 48, 88.2, 96 and 192 kHz | 1e-12 per coefficient |
| `tech3341.json` | Momentary and short-term LUFS, width and balance per frame for 14 signals at 48 and 44.1 kHz (28 cases, 2,476 frames) | mean power within 1e-9 relative plus `channels · 2^-50`; width and balance within 1e-6 |
| `centroid.json` | Centroid by the librosa definition, centroid and flux by the analyzer's definition, per frame, for the 9 mono WAV fixtures and a 44.1 kHz sweep (704 frames) | librosa centroid 2 % relative; analyzer definition 1e-9 relative; flux 1e-9 |

### Loudness

K-weighting is the BS.1770-4 high shelf followed by the RLB high-pass, which also removes DC.
Both biquads are derived for the configured sample rate from the analog prototype parameters
with the libebur128 formulas. At 48 kHz they reproduce the coefficients published in BS.1770-4
within 1e-12 (checked by the oracle and by a unit test). As in libebur128, the high-pass
numerator stays (1, -2, 1) at every rate. The analyzer and the oracle share this derivation, so
the oracle also checks it against the published filter, evaluated on its own as |H(e^jw)| of
the BS.1770-4 48 kHz biquads: the derived response is within 0.05 dB of it at 1 kHz for every
listed rate, and from 10 Hz to 20 kHz (or 0.45 times the rate, if lower) for rates of 32 kHz and
above; at 44.1 kHz the largest difference up to 19.8 kHz is 0.0053 dB. `k-weighting.json`
records each rate's largest difference. Below 32 kHz the bilinear transform compresses the shelf, and the
response differs by up to 0.48 dB near 3 kHz at 8 kHz, so loudness at those rates is
approximate. Below 8 kHz loudness is not measured: it reads -120 LUFS, and width and balance
read 0.

Each sample's weighted power is rounded down to a multiple of 2^-50 and summed in wrapping
128-bit integers, so a window sum is an exact difference of two cumulative sums on every
target. Windows are 400 ms (momentary) and 3 s (short-term), rounded to whole samples, end at
the analysis-window end and are clipped to the current segment like `rms`. `begin_segment`
restarts them. Loudness is `-0.691 + 10 log10(mean weighted power)`, at least -120 LUFS.
Channel weights follow BS.1770-4: 1.41 for Ls and Rs and 0 for the LFE in 5-channel
(L R C Ls Rs), 6-channel (L R C LFE Ls Rs) and 8-channel (L R C LFE Ls Rs Lrs Rrs, the
ITU-R BS.2051 order) input, 1 for every other channel and layout. A 7.1 stream in the
WAVEFORMATEXTENSIBLE order, with the back pair before the side pair, weighs its back pair 1.41. With
hops shorter than 36 samples at 48 kHz, only every `stride`-th window start is kept and a
window may reach back up to `stride - 1` further hops; the default configuration is exact.

`tech3341.json` covers EBU Tech 3341 cases 1, 2, 6 (5.0), 9 (short-term, from 3 s) and 12
(momentary, from 0.4 s), case 6 as 5.1 with a -10 dBFS LFE that must not count, mono, anti-phase
(width 1), left only (width 0.5, balance -1), a 0.25 DC offset and DC alone (-120 LUFS once the
high-pass settles). Three analytic cases take their nominal loudness from the published 48 kHz
biquads' gain at the tone frequency rather than from the derived filters: stereo -23 dBFS sines
at 100 Hz (-24.82 LUFS) and 10 kHz (-19.65 LUFS), and case 6 as 7.1 with a -10 dBFS LFE and
-30 dBFS rear surrounds (-22.22 LUFS, BS.1770-4 weights written out in the case). Each case
states its nominal values and the first frame they hold from. The
oracle fails unless it meets them within 0.1 LU and 1e-3, and the Rust test checks the analyzer
against the same nominal values as well as against the oracle's frames. Integrated loudness,
loudness range and true peak are not descriptors, so the Tech 3341 cases for them are out of
scope.

`OscilluxDspFrame.loudness_db` is unchanged and is not LUFS. It is the RMS level of the mono
mixdown over `rms_window_ms`, unweighted, in dBFS minus `loudness_reference_lufs`
(`20 log10(max(rms, rms_floor)) + 18` by default). For a stereo -23 dBFS 1 kHz sine it reads
about -8 while `momentary_lufs` reads -23.0.

### Width and balance

Width and balance read the K-weighted channels 0 and 1 over the momentary window. Width is
`E_S / (E_M + E_S)` with `M = (L + R) / 2`, `S = (L - R) / 2`, so 0 for identical channels, 0.5
for one silent channel or uncorrelated equal channels, and 1 for anti-phase. Balance is
`(E_R - E_L) / (E_R + E_L)`. Both read 0 for mono input and silence.

### Centroid and flux

The centroid is `sum(f_k |X_k|) / sum(|X_k|)` over the analyzer's magnitude spectrum, bins 0 to
N/2, with `f_k = k · fs / N`. The analyzer windows with a symmetric Hann window (`N - 1` in the
denominator, the reference window of both behaviour versions). `librosa.feature.spectral_centroid`
uses the periodic Hann window, and on these inputs the two differ by at most 0.51 %; the
oracle evaluates both on the analyzer's frame grid (not librosa's centred frames), and the test
holds the analyzer within 2 % of the librosa definition. The flux is the half-wave rectified
magnitude increase over the previous frame divided by the current magnitude sum, clamped to 0
to 1. It is 0 on the analyzer's first frame and for a zero spectrum, and the previous spectrum
carries across `begin_segment` like the onset state.

### Novelty

A novelty (self-similarity) curve is left to hosts. It needs seconds of feature history and a
host-chosen kernel size, which do not fit a fixed per-frame output, and a host can build it from
the per-frame descriptors and bands that the ABI already returns.
