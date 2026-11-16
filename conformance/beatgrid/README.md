<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Beat grid vectors

These are the OSC-BEAT-GRID fixtures for the offline whole-file beat and downbeat grid
(`oscillux_core::beatgrid`, C API `oscillux_beatgrid_*`). The grid reads a whole PCM file and
can look ahead, unlike the causal trackers in `conformance/dsp/`. It returns:

- the beat times;
- each beat's position in its bar and its bar counter;
- a local tempo per beat;
- a global tempo and a confidence.

A constant-time clock maps media time to beat phase, bar phase, beat index and tempo.

This README is the specification. `tools/beatgrid-vectors.py` is an independent
standard-library Python model written from it, and it writes every file here.
`crates/oscillux-core/tests/beatgrid_vectors.rs` renders the same audio and analyses it with
the Rust module. It compares the result with the model's grids within the tolerances below,
and with the scores' annotations.

## Files

For each vector:

- `<name>.score` is the synthesis score: header fields, then events, then the annotated beats as
  `beat <sample> <beat_in_bar>`. The audio is rendered at test time and is not committed. The
  renderer is described in the generator's docstrings. It uses only `+ − × ÷`, floor and
  comparisons on doubles, so Rust reproduces the 16-bit samples exactly; `pcm_fnv1a` is the
  FNV-1a 64 of their little-endian bytes. The analysed samples are `s / 32768` as `f32`, with
  channels interleaved and channel `c` scaled by `gain · pan[c]`.
- `<name>.grid` is the model's grid. It has:
  - the analysis configuration: `rate`, `channels`, and `beats_per_bar`, which is the score's
    meter hint (0 for auto); the other fields are the defaults;
  - the `info` counts, `tempo_bpm`, `confidence` and `duration_s`;
  - one `beat <time_s> <tempo_bpm> <beat_in_bar> <bar_index>` line per beat;
  - `clock <media_time_s> <beat_phase> <bar_phase> <tempo_bpm> <beat_index> <beat_in_bar>`
    samples taken 1.6 and 0.4 intervals before the first beat, midway between every pair of
    beats, and 0.3 and 2.7 intervals after the last beat.

  Floats are written with Python `repr`, which round-trips.

| Vector | Signal | Rate | Hint | Beats | Model beats | Beat F | Downbeat F | Offset mean / sd, ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| clicks-120-44k1 | 120 BPM clicks, accented 1 with a kick | 44100 | 4 | 40 | 40 | 1.000 | 1.000 | −0.13 / 0.22 |
| waltz-90-48k | 90 BPM 3/4, stereo, root on 1, chord on 2 and 3 | 48000 | auto | 25 | 25 (meter 3) | 1.000 | 1.000 | +3.45 / 1.45 |
| ramp-90-150-22k05 | groove, 90 BPM ramping to 150 over 22 s | 22050 | 4 | 59 | 74 | 0.872 | 0.909 | +1.46 / 1.06 |
| step-100-140-22k05 | groove, 100 then 140 BPM | 22050 | auto | 56 | 57 (meter 4) | 0.973 | 1.000 | +1.67 / 1.09 |
| fast-200-8k | 200 BPM four on the floor | 8000 | 4 | 47 | 47 | 1.000 | 1.000 | −3.48 / 0.82 |
| groove-110-44k1 | 110 BPM groove | 44100 | auto | 34 | 34 (meter 4) | 1.000 | 1.000 | +1.59 / 1.04 |

The scores use the ±70 ms window over the whole file, with greedy in-order matching, as in
`dsp_beat.rs`. On the ramp, the grid runs at twice the annotated tempo for part of the slow
section, which costs precision.

## Algorithm

All arithmetic is IEEE `f64`. In Rust the transcendentals come from `libm`, and sums are
taken in index order. `trunc`, `floor` and `ceil` have their usual meaning; `round` rounds half
away from zero.

### Configuration and tuning

The configuration fields are:

| Field | Range | Default |
| --- | --- | --- |
| `sample_rate_hz` | 8000 to 384000 | 44100 |
| `channels` | at least 1 | 2 |
| `min_bpm` | 20 to below 400 | 40 |
| `max_bpm` | above `min_bpm`, at most 400 | 240 |
| `beats_per_bar` | 0 (auto), or 2 to 16 | 0 |
| `reserved` | 0 | 0 |

A sample count that is not a multiple of `channels` is refused. The fixed tuning constants are:

| Constant | Value | Constant | Value |
| --- | --- | --- | --- |
| norm_half_s | 1.0 | tightness | 100 |
| low_weight | 1.0 | down_harmonic | 1.0 |
| prior_bpm | 140 | down_low | 1.0 |
| prior_octaves | 2.0 | down_jump | 4.0 |
| path_half_s | 4.0 | offset_s | 0.009 |
| path_span | 2.0 | path_change | 4.0 |
| path_pull | 1.0 | | |

### Onset features

- **Mono.** Each frame is the sum of its finite channel samples divided by `channels`.
- **Framing.**
  - The window length `n` is the smallest power of two that is at least
    `max(trunc(rate · 0.04), 4)`.
  - The hop is `max(trunc(rate / 100 + 0.5), 1)`.
  - There are `len(mono) // hop + 1` frames. Frame `i` covers samples `i·hop − n/2` onwards,
    with zeros outside the signal, and is weighted by `0.5 − 0.5 cos(2πj/n)`.
  - `fps = rate / hop`.
- **Filterbank.**
  - `top = min(16000, rate/2)` and `band(f) = trunc(12 log2(f / 27.5) + 0.5)`.
  - Bin `k` of `0..n/2` at `f = k·rate/n` belongs to `band(f)` when `27.5 ≤ f ≤ top`.
  - There are `band(top) + 1` bands. A band is *used* when a bin maps to it.
- **Band value.** A band's value is `ln(1 + 100 · Σ |X_k| · 4/n)` over its bins.
- **Flux.**
  - A used band's rise is `max(0, cur[b] − ref)`, where `ref` is the maximum of the previous
    frame's values at `b` and at its used neighbours `b ± 1`.
  - The broadband flux is the sum of the rises over used bands. The low-band flux is the same
    sum over bands below `min(band(150), bands)`.
  - Frame 0 has flux 0.
- **Pitch-class profile.** Each used band `b` in `band(60) ..= min(band(4000), bands − 1)` adds
  its value to class `b mod 12`.

### Tempo

- **Tempo range.**
  - `lo = 60·fps / max_bpm` and `hi = 60·fps / min_bpm`, in frames.
  - The grid is empty when there are fewer than `4·hi` frames or when `lo < 2`.
- **Normalise.**
  - With `half = round(norm_half_s · fps)`, subtract from each value the mean over the frames
    `[max(0, i − half), min(N, i + half + 1))`.
  - Then divide by `sqrt(Σ v² / N)` when that is above 0.
  - This gives `broad` from the broadband flux and `low` from the low-band flux.
- **Autocorrelation.**
  - `r[τ] = Σ_i broad[i]·broad[i+τ]` for `τ ≤ ceil(4·hi) + 2`, with 0 when `τ ≥ N`.
  - Divide by `r[0]` when it is above 0. The grid is empty when `r[0] = 0`.
- **Lag lookups.**
  - `at(r, x)` interpolates `r` linearly at a fractional lag. It is 0 when `x < 0` or
    `floor(x) + 1 ≥ len(r)`.
  - The salience is `sal(l) = Σ_{k=1..4} at(r, k·l)`.
- **Global period.**
  - Search the lags `lo + 0.25k` for `k = 0 ..= floor((hi − lo) / 0.25)`.
  - Score each lag by `sal(l) · exp(−½ (log2(l / c) / prior_octaves)²)`, with
    `c = 60·fps / prior_bpm`.
  - Take the first maximum. If it is an interior index, form `den = a − 2b + c` from its
    neighbours' scores. When `den < 0`, add `½(a − c)/den · 0.25`.
- **Tempo path.**
  - **Lag bins.**
    - `half = round(path_half_s · fps)`, with a hop of `max(round(fps/2), 1)` frames.
    - The lag bins are `lmin + 0.5b`, where `lmin = max(lo, g / path_span)` and
      `lmax = min(hi, g · path_span)` for the global period `g`. There are
      `max(floor((lmax − lmin)/0.5) + 1, 1)` bins.
  - **Local autocorrelation.**
    - Each centre `c·hop` has its own autocorrelation, for `c < max(ceil(N / hop), 1)` and
      `τ ≤ ceil(4·lmax) + 2`.
    - Over `i` from `start = max(centre − half, 0)` with `i + τ < end = min(centre + half + 1, N)`:
      `Σ w[i − centre + half] · broad[i] · broad[i+τ]`, divided by its own `r[0]` when above 0.
    - The weights are `w_j = 0.5 − 0.5 cos(2π(j+1)/(2·half+2))`.
  - **Viterbi decoding.**
    - A bin's local score is `0.5·sal(l) − path_pull · log2(l/g)²`.
    - A move from bin `a` to bin `b` costs `path_change · log2(l_b / l_a)²`.
    - The decoder takes the first strict maximum at each step and the first maximum at the end.
  - **Per-frame period.** Frame `i` interpolates linearly between centres `i // hop` and the next
    one, at `(i mod hop)/hop`. Past the last centre it holds that centre's lag.

### Beats

- **Envelope.** `env = broad + low_weight · low`.
- **Dynamic programme.**
  - For each frame `t`, with `τ` the path period at `t`, consider the predecessors `p` from
    `max(ceil(t − 2τ), 0)` to `floor(t − τ/2)`, provided `t − τ/2 ≥ 0`.
  - Each predecessor scores `score[p] − tightness · ln((t − p)/τ)²`.
  - `score[t] = env[t] + best`, where `best` starts at 0 with no predecessor and takes strictly
    greater candidates.
  - The last beat is the first frame with the maximum score; backtrack from it.
  - The grid is empty with fewer than two beats.
- **Refinement.**
  - Within `[max(b−2, 0), min(b+2, N−1)]`, start at `b` and move to strictly greater `env`.
  - At an interior `m` whose neighbours `a` and `d` are both at most `c = env[m]`, with
    `den = a − 2c + d < 0`, the peak is `m + ½(a − d)/den`. Otherwise it is `m`: a window
    maximum at the edge of a rising slope would put the vertex outside the window.
  - The beat time is `peak / fps + offset_s`.

### Bars

- **Beat profiles.** Beat `i`'s profile sums the pitch-class profiles of frames
  `[min(b_i, F), max(min(b_{i+1} or F, F), start))`, then scales them to unit length when the
  norm is above 0.
- **Cues.**
  - The harmonic cue is `1 − dot(p_{i−1}, p_i)`, and 0 for the first beat.
  - The bass cue is `max(0, max low[max(b−2, 0) .. min(b+3, N)])`.
  - Both are standardised to zero mean and unit population deviation, or set to 0 when constant.
    The cue is `down_harmonic · h + down_low · l`.
- **Decoding under meter `m`.**
  - The positions run `0 .. m−1`, where position 0 emits the cue and the others emit 0.
  - Position `pos` follows `(pos − 1) mod m` at no cost. Any other position costs `down_jump`
    and is taken only when strictly better, in position order.
  - The final position is the first maximum.
- **Contrast.** It is the mean cue at position 0 minus the mean elsewhere, with each count at
  least 1.
- **Meter.** A hint of 2 or more is used as given. Otherwise meters 4 then 3 are decoded, and
  the strictly higher contrast wins. A two-beat bar reads as half of a four-beat bar, so meter 2
  is only produced on request.

### Grid and clock

- **Per beat.**
  - `bar_index` counts downbeats after the first beat.
  - `tempo_bpm = 60 / span`, or 0 when `span ≤ 0`. The span is `t1 − t0` for the first beat,
    `t_i − t_{i−1}` for the last, and `½(t_{i+1} − t_{i−1})` otherwise.
- **Summary.**
  - `beat_count` and `bar_count`, the latter counting beats at position 0.
  - `beats_per_bar`.
  - `tempo_bpm = 60·fps / g`.
  - `confidence = clamp(at(r, g), 0, 1)`.
  - `duration_s = frames / rate`.
  - An empty grid has only `duration_s`.
- **Clock at `t`.**
  - With fewer than two beats or a non-finite `t`, every field is 0 except
    `beat_index = −1`.
  - Before the first beat, the grid extends at the first interval: `k = floor((t − t0)/iv)`,
    the beat is `k` (negative), its start is `t0 + k·iv`, and its position is
    `(pos0 + k) mod meter`.
  - From the last beat on, it extends the same way at the last interval, counting from
    `beat_count − 1`.
  - Otherwise the beat is the last one with `t_i ≤ t`.
  - `beat_phase = clamp((t − start)/iv, 0, 1 − 2⁻⁵³)`.
  - `bar_phase = min(((pos mod meter) + beat_phase)/meter, 1 − 2⁻⁵³)`.
  - `tempo_bpm` is the beat's tempo.

## Tolerances

Rust matches the model within these tolerances:

- **Times:** 1e-6 s.
- **Tempos:** relative 1e-6, against `max(|expected|, 1)`.
- **Confidence and phases:** 1e-6 absolute.
- **Integer fields:** exact.

The model computes differently where this specification allows:

- an rfft through a half-length complex FFT;
- correctly rounded sums;
- direct window means;
- a linear scan in the clock.

Grids that agree to 1e-6 therefore come from the same discrete decisions. On these vectors, the
largest measured difference is 3.6e-15 s.

## Determinism

The Rust grid is bit-identical on every target. `beatgrid_vectors.rs` checks this test digest
of each grid on the host and on wasm32-wasip1 (`make test-wasi`). The digest is FNV-1a 64 over
the little-endian `u64` words of:

- the summary;
- each beat's time, tempo, bar position and bar;
- the clock fields at every `.grid` sample time.

| Vector | Rust grid digest |
| --- | --- |
| clicks-120-44k1 | 303c1730b6d8b96c |
| waltz-90-48k | 86f0c53a88e61daf |
| ramp-90-150-22k05 | c03cbc911a291846 |
| step-100-140-22k05 | 9af0cbc9a335dd0f |
| fast-200-8k | 3a9b45d69c7d5b86 |
| groove-110-44k1 | 3cea8b96a3078458 |

`make beatgrid-vectors-check` (part of `make gate`, about 35 s) regenerates every file into a
temporary directory and fails on any difference.
