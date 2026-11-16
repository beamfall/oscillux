<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# DSP music and edge-case vectors

This directory holds the OSC-DSP-MUSIC-VECTORS fixtures:

- edge-case frame vectors for both DSP behaviour versions;
- synthetic music scores with exact onset, beat and downbeat annotations.

It also holds the conformance vectors for two optional stages that consume analysis frames:

- `beat/`: the beat tracker (OSC-DSP-BEAT);
- `agc/`: the adaptive level normaliser (OSC-DSP-AGC).

Beat tracker versions 3 and 4 were tuned on annotated recorded music that is not distributed with
this repository. Everything asserted here runs on the synthetic scores and edge-case fixtures in
this directory, which are music-like but not music.

## Edge-case fixtures

Each fixture has these files:

- `<name>.wav`: the 16-bit PCM input.
- `<name>.spec`: its definition rows.
- `<name>.frames`: the version 1 expected frames.
- `v2/<name>.frames`: the version 2 expected frames.

The row format matches `conformance/dsp/*.frames`, with one difference: the spectrum has one
column per configured band.

| Fixture | Signal | Configuration | Frames | Flags |
| --- | --- | --- | --- | --- |
| kicks-44k1 | The kick signal of `../README.md`, 1.5 s | Defaults at 44.1 kHz | 126 | none |
| kicks-config-32k | Kick signal plus a 330 Hz sine (amplitude 0.2), 1.5 s | Non-default at 32 kHz (below) | 177 | gap and stall on one frame |
| stereo-antiphase | Two channels: kick signal plus a 220 Hz sine (0.1), with a 1 kHz sine (0.3) added left and subtracted right | Defaults | 90 | none |
| nan-replaced | Kick signal, 1 s, with seven samples replaced by NaN, ±infinity or 1e39 | Defaults | 90 | input replaced on 5 frames |

**kicks-44k1** pins band edges, spectral values and onsets at 44.1 kHz. The analytic
`silence-44k1-chunked` fixture cannot pin those.

**kicks-config-32k** sets every numeric configuration field except the fixed onset and RMS
constants:

| Field | Value |
| --- | --- |
| FFT window | 1024 |
| Hop | 256 |
| Bands | 16, over 50 to 12000 Hz |
| dB floor | -80 |
| Ballistics | 5 ms attack, 150 ms release |
| RMS window | 100 ms |
| Loudness reference | -14 LUFS |
| Onset band groups | 0-4, 5-10, 11-15 |
| Gap tolerance | 2 hops |

It is analysed in three 16000-sample chunks, at 0 ms, 516 ms and 1060 ms. The third chunk is
also stalled:

- The second chunk starts 1.5 hops after the expected time. That is inside the tolerance of 2
  hops, so it is not a gap; at a tolerance of 1 hop it would be.
- The third chunk starts 5 hops late, so its first frame carries gap and stall (flags 3).

**stereo-antiphase** checks the channel mixdown. The analyser averages the channels, so the
1 kHz component cancels and only the shared kick and 220 Hz content remain.

**nan-replaced** checks input replacement. The WAV holds 0 at each `replace` index. The test
pushes the decoded samples through `Analyzer::push` with the replacement values injected:

| Sample indices | Injected value |
| --- | --- |
| 100, 24575 | NaN |
| 3000, 47999 | +infinity |
| 10000 | -infinity |
| 10001, 24576 | 1e39, beyond the `f32` range |

The analyser replaces each with 0, which is exactly the WAV's value, so the features are those
of the WAV. The expected flags follow the replacement rule below.

### Definition rows

A `.spec` file starts with `# dsp-edge-spec v1` and a `# signal:` line, then holds these
rows:

- `channels <n>`
- `config <field> <value>`. `onset_band_groups` is written as `a-b,c-d,e-f`.
- `chunk <media_start_ms> <begin_sample> <end_sample> <stalled>`, where sample indices count
  sample frames.
- `replace <sample_index> <value>`

The `.frames` files repeat these rows, and the test checks that both copies agree. Without
`chunk` rows the whole file is one segment at 0 ms.

### Input-replaced flag rule

The Go reference has no input-replaced flag, so flag 4 in the version 1 vectors is defined
here. A replaced sample at segment-relative index `r` flags the first frame of its segment
whose window end lies after `r`. That window end is `fft_window_samples + k · hop_samples`. A
sample after the segment's last frame flags nothing. In nan-replaced:

| Replaced indices | Frame flagged |
| --- | --- |
| 100 | 0 |
| 3000 | 2 |
| 10000, 10001 | 16 |
| 24575 | 44 |
| 24576 | 45 |
| 47999 | none (after the last frame) |

The 24575/24576 pair sits on a window boundary.

### Generation

`tools/dsp-v2-vectors.py` writes the WAV and `.spec` inputs and the version 2 frames under
`v2/`. It uses the same independent oracle as `../v2/`, with its kick generator, its WAV
quantisation and multi-channel mixdown (sum over channels, divided by the count). Its `--check`
mode compares `v2/` and the inputs file by file, and `make gate` runs it.

The kick generator calls Python's `math.sin` and `math.exp`, whose last bit depends on the
platform's libm, and `--check` compares the WAVs byte for byte. On a platform whose libm rounds
differently, a 16-bit sample could round the other way and `--check` would report a changed WAV
although the committed files are still correct. The committed WAVs are the specification: the
Rust tests read them and never call the generator. A `--check` failure on a new platform should
be read as a libm difference first, and the WAVs should not be regenerated there. Making the
check tolerant would also need tolerant frame comparisons, so it is left exact.

The version 1 frames come from the pinned Go reference, never from Rust. The reference is
beamfall `0b4e16f5c`, `tools/visualsync/contract`. A scratch test outside this repository
(`edge_scratch_test.go`, `TestEdgeFixtures`) does the following:

1. Parses each `.spec`.
2. Decodes the WAV at its rate and channel count as the channel average of `int16 / 32768`.
   This is `PCMFromWAV` without its 48 kHz check.
3. Runs `AnalyzePCMChunks` with the configuration as a parameter. The reference's unmodified
   `analyzeChunk` does the work, with the gap test
   `start - expected > gap_tolerance_hops · hop_ms`.
4. Adds flag 4 by the rule above.

It was run from that package as
`EDGE_DIR=<oscillux>/conformance/dsp/music go test -run TestEdgeFixtures ./contract`.
Regeneration must use that reference, never Rust output.

Comparison uses the tolerances of `../README.md`. Recorded Rust output digests
(`dsp_conformance`, host and wasm32-wasip1):

| Fixture | Version 1 | Version 2 |
| --- | --- | --- |
| kicks-44k1 | `9b52551adb634604` | `ab34dceb82b20f47` |
| kicks-config-32k | `6ee6ebe6d05c74a2` | `ce786fb91be6a92b` |
| stereo-antiphase | `52151edee53f6ded` | `32298356f6194fa0` |
| nan-replaced | `1f7925acb2c29d1a` | `5152561a7f599519` |

## Synthetic music scores

`scores/*.score` are five arrangements of 28 to 37 s at 48 kHz, written by
`tools/dsp-music-vectors.py`:

| Score | Length | Tempo | Content | Onsets | Beats |
| --- | --- | --- | --- | --- | --- |
| music-tempo-steps | 33.6 s | 96, then 128, then 108 BPM (16, 24 and 20 beats) | Straight rock bar: kick on 1 and 3, snare on 2 and 4, eighth hats, bass on 1 and the off-beat of 2, crashes | 120 | 60 |
| music-syncopated-swing | 35.9 s | 112 BPM | Swung eighths (2:1), kick on the swung off-beat of 2, ghost snares, syncopated bass, open hats | 128 | 64 |
| music-pad-noise | 36.2 s | 90 BPM | Drums over a quiet noise bed (24 beats), then a slow-attack pad alone (12 beats with no onset), then drums, pad and a louder noise bed (16 beats) | 80 | 52 |
| music-ramp | 34.3 s | Linear per-beat ramp from 100 to 136 BPM | Four-on-the-floor kick, off-beat open hats and bass, snare on 2 and 4 | 128 | 64 |
| music-heldout-breakbeat | 28.6 s | 142 BPM | Formerly held out. Sixteenth hats, kick on 1, the off-beat of 2 and the last sixteenth of 3, a bass note on each kick, snare on 2 and 4 with ghost notes, open hats, a sixteenth snare fill every eighth bar, crashes; noise seed 30011 | 256 | 64 |

music-heldout-breakbeat was written after every parameter of the onset picker, the beat tracker
and the normaliser was fixed. Its tempo, pattern and noise seed differ from the other four. The
beat tracker failed on it in version 2, and OSC-DSP-BEAT-HELDOUT tuned the tracker's phase
estimate and tempo jumps on it, so it is no longer held out: every benchmark asserts it like the
others. No score is held out now, so the tables below measure fit, not generalisation.

Every score has a 0.5 s lead-in and a 1 s tail. The downbeat is the first beat of every bar
(4/4).

### Score format

A score starts with `# dsp-music-score v1`. It has `rate`, `samples`, `gain` and `pcm_fnv1a`
rows, then one row per synthesis event:

- `tone start length attack release amp decay f_start f_end glide`
- `noise start length attack release amp decay seed highpass`

Then come the annotations: `onset <sample>` and `beat <sample> <downbeat 0|1>`.

The event rows define the renderer exactly. Floats are written as the shortest round-trip
decimal, and the renderer uses only `+ - × ÷`, floor and comparisons.

- **Envelope.** `amp · a_i · r_i · d_i`. The attack `a_i` is linear over `attack` samples and
  the release `r_i` is linear over the last `release` samples. The decay is
  `d_0 = 1, d_(i+1) = d_i · decay`.
- **Tone.** A parabolic sine of the phase, with
  `P_(i+1) = P_i + (f_end + (f_start - f_end) · g_i) / rate` and `g_(i+1) = g_i · glide`.
- **Noise.** Entries of a 65536-value table from the 64-bit LCG of `../README.md`, seeded with
  `20261020`. It is taken plain, or as a first or second difference.
- **Mix.** Events are summed in file order, scaled by `gain`, clamped to [-1, 1], and rounded
  `x · 32767` half away from zero.

`pcm_fnv1a` is the FNV-1a digest of the little-endian 16-bit samples. The Rust test re-renders
every score and asserts that digest.

The annotations are exact sample positions. An onset is the start of every percussive or bass
event. Pads and noise beds have no annotated onset. Starts closer than 25 ms are merged into
the first. The pad-only section of music-pad-noise keeps its beats but has no onsets.

### Rendering at test time

The WAVs are not committed. The five scores are 110 KB of text; their rendered 16-bit mono WAVs
would be 16.2 MB (8.09 million samples). `crates/oscillux-core/tests/dsp_music.rs` renders them
in memory, checks each digest, and analyses them with both behaviour versions.
`tools/dsp-music-vectors.py --check` regenerates the scores into a temporary directory and fails
on any changed, missing or extra file. `make gate` runs it.

The generator calls `math.exp` only to turn event parameters, such as a decay time, into the
per-sample factors written into the score as text. The renderer does not call it. Another libm
could change a factor's last digit and fail `--check`; the committed scores, which the Rust test
reads, are the specification.

### Onset benchmark

`dsp_music` picks onsets offline from the onset detection function `(low + mid + high) / 3` of
each frame. Frame `k` is an onset when all of these hold:

- No frame in `k-3 … k+2` is larger.
- Its value is at least `m + 0.1` and at least `3m`, where `m` is the mean over `k-10 … k+2`.
- It is at least 30 ms after the previous onset.

The onset time is the frame's media time. Detections and annotations are matched one to one,
in time order, within ±50 ms. Precision, recall and F are computed over the whole score. The
test asserts F ≥ 0.8 for every score, in both behaviour versions, and prints the per-score
values.

| Score | Version | F | Precision | Recall |
| --- | --- | --- | --- | --- |
| music-tempo-steps | v1, v2 | 0.979 | 1.000 | 0.958 |
| music-syncopated-swing | v1, v2 | 0.984 | 1.000 | 0.969 |
| music-pad-noise | v1 | 0.873 | 1.000 | 0.775 |
| music-pad-noise | v2 | 0.859 | 0.928 | 0.800 |
| music-ramp | v1, v2 | 1.000 | 1.000 | 1.000 |
| music-heldout-breakbeat | v1 | 0.807 | 1.000 | 0.676 |
| music-heldout-breakbeat | v2 | 0.812 | 1.000 | 0.684 |

The picker parameters were chosen on the first four scores and not changed since. On
music-heldout-breakbeat, which none of them was chosen on, the picker misses about a third of the onsets: most of
its onsets are quiet sixteenth hats 106 ms apart. Real music would need its own check.

## Beat tracker

`oscillux_core::dsp::BeatTracker` (`crates/oscillux-core/src/dsp/beat.rs`) is an optional,
streaming stage. It takes the analyser's frames in order and returns one `Beat` per frame:
tempo, beat phase, bar phase, confidence, a beat flag, a downbeat flag and the beat's index in
the bar. It allocates only in `new`. On version 1 and version 2 settings it runs the steps
below, and only its input differs. Version 3 settings use version 2 frames and change two steps
(see "Version 3" below). Version 4 settings use version 2 frames and replace the tracker with a
different model ("Beat tracker, version 4" below). Every analyser also runs one with
`BeatConfig::for_version(behavior_version)` on every hop, whichever push function is used, and `oscillux_dsp_push_ext_f32`/`_f64` write its
output as `OscilluxDspFrameExt.beat` (all zero when the analyser's frame rate puts that tempo
range outside the period limits below). C callers get only that configuration.

`BeatConfig` holds `min_bpm` (default 80), `max_bpm` (160) and `beats_per_bar` (4, at most 16).
`BeatConfig::for_version` returns 60–200 BPM in 4/4 for versions 3 and 4 and the default
otherwise.
Its constants depend on the frame rate `fr = sample_rate_hz / hop_samples`:

| Constant | Value |
| --- | --- |
| Shortest period `lo` | `floor(fr · 60 / max_bpm)`; it must be ≥ 8 |
| Longest period `hi` | `ceil(fr · 60 / min_bpm)`; it must be ≤ 1024 |
| Histogram decay | `1 − 1 / (2 · fr)` |
| Switch frames | `floor(0.5 · fr + 0.5)` |
| Preferred period | `fr · 0.5`, which is 120 BPM |

### Per-frame steps

Frame `t` counts from 0. In every step, sums run in ascending index order. "First maximum" means
a running best that starts at −1 and is replaced only by a strictly larger value. A decay
multiplies a value and flushes any result below 1e-12 to 0. An input reads as 0 unless it is
finite and positive.

1. **Gap or stall.** If the frame carries `FLAG_GAP` or `FLAG_STALLED`, the tracker forgets
   everything except the tempo. It clears:
   - the picker fill count and the last onset;
   - the onset ring;
   - the phase histogram, the previous phase and the phase anchor, which returns to 0;
   - the pending cue, the accents and the downbeat slot;
   - the bar position, which returns to `beats_per_bar − 1`.

   It keeps the period, the pending period, the interval histogram, the beat clock and the last
   beat frame. The free count (step 6) becomes `4p`, or 0 before the first lock.
2. **Onset detection function.**
   - `x_t = (low + 2 · mid) / 3`, from `onset.low` and `onset.mid`.
   - The bands of the first onset band group go into an 8-row ring.
   - The high group is left out: in behaviour v2, swung off-beat hats outweigh the beat there.
3. **Onset picker.** The picker needs 13 frames since the start or the last gap. It then judges
   the frame `k = t − 2`, with value `v = x_k`. Frame `k` is an onset only if all of these hold:
   - No frame in `k − 3 … k + 2` is larger than `v`.
   - With `m` the mean over `k − 10 … k + 2`, `v ≥ m + 0.1` and `v ≥ 3m`.
   - Frame `k` is at least 3 frames after the previous onset.

   The onset's strength is `s = v − m`.
4. **Interval histogram.** `H` has `4 · hi + 5` entries, and every entry decays each frame. For
   an onset, the tracker visits the 24 most recent onsets `(k_j, s_j)` in ring-slot order. For
   each lag `k − k_j` in `lo − 2 … 4 · hi + 2`, it adds `s · s_j / 9 · (3 − |i − 2|)` to
   `H[lag − 2 + i]` for `i = 0 … 4`. It then stores `(k, s)` in the next ring slot.
5. **Comb.** For each period `p` in `lo … hi`, the score is
   `(H[p] + H[2p] + H[3p] + H[4p]) / (1 + r · r)`, where `r = (p − 120 BPM period) / 120 BPM
   period`.
   - The best period `bp` is the first maximum.
   - If the best score is ≤ 0, there is no candidate.
   - Otherwise the tempo contrast is `(best − mean) / best`.
   - Strictly inside the range, a parabola through `bp − 1`, `bp` and `bp + 1` refines the
     candidate when its curvature `y0 − 2·best + y2` is negative. The refinement is
     `bp + 0.5 · (y0 − y2) / den`.
   - A jump needs a clear win. When a period `p` exists and the candidate differs from it by
     more than `0.06 · p`, the candidate is replaced by `p` unless its score `best` is at least
     1.2 times the score of period `floor(p + 0.5)`.
6. **Tempo follow.**
   - A candidate within 6% of the current period replaces it at once.
   - Any other candidate becomes pending. It must stay within 6% of the pending period for the
     switch frames, counted consecutively, before it replaces the period. Before the first lock,
     it must hold for twice the switch frames.
   - When a pending candidate replaces the period, including at the first lock, phases measured
     at the old period no longer line up with the clock: every phase histogram bin decays by
     0.5, and the free count becomes 4 times the new period.
   - With no candidate, the pending period and its count are cleared.
   - Until a period exists, every output is 0.
7. **Beat clock and phase.**
   - The clock advances by `frac(clock + 1/p)`, where `frac(x) = x − floor(x)` and a result of
     1 reads as 0.
   - The free count, when above 0, falls by 1.
   - The 48-bin phase histogram decays by `1 − 1/(8p)`.
   - An onset is placed at `pos = frac(clock − 2/p) · 48`. It adds `s · (1 − w)` to bin
     `floor(pos)` and `s · w` to the next bin, circularly, where `w = pos − floor(pos)`.
8. **Phase estimate.**
   - Each bin is smoothed as `Q[i] = P[i−1] + 2·P[i] + P[i+1]`, circularly. Its phase score is
     `S[i] = Q[i] + 0.5 · Q[i + 24]`: a beat's own eighth-note partner adds to it, which an
     off-beat sixteenth lacks.
   - `best` is the first maximum of `S` over bins 0 … 47, at bin `bi`.
   - The anchor follows its own peak. With `near = floor(anchor · 48 + 0.5)`, `local` is the
     first maximum of `S` over bins `near − 4 … near + 4` in ascending order, circularly, at
     bin `li`. When the free count is ≤ 0 and `1.3 · local ≥ best`, the peak is `local` at
     `li`; otherwise it is `best` at `bi`.
   - A parabola through `S` at the peak bin and its two neighbours, circularly at any bin,
     refines it: the offset is `0.5 · (y0 − y2) / den` when `den = y0 − 2·peak + y2` is
     negative, else 0. The peak bin plus that offset is the phase offset `φ`.
   - When `best` is above 0, the anchor becomes `frac(φ / 48)`. An empty histogram keeps the
     previous anchor, so the phases run on smoothly through a long silence.
   - The beat phase is `ψ = frac(clock − anchor)`.
   - The phase contrast is `(best − mean) / best` over `S`, or 0.
9. **Beat.** Onset recency is 1 up to two periods after the last onset, falls linearly to 0 at
   sixteen periods (`(16p − since) / (14p)`), and is 0 with no onset.
   - `ψ` wraps forward when it falls by more than 0.5 from the previous frame's `ψ`. The bar
     position then moves on by one, modulo `beats_per_bar`.
   - `ψ` wraps backward when it rises by more than 0.5. The bar position then moves back by one.
   - A forward wrap emits a beat when `best` is above 0, half a period has passed
     since the previous beat and onset recency is above 0. Beats therefore carry through a break
     of up to sixteen periods and stop in a longer silence, while the phases keep running.

   The beat is a downbeat when the bar position is the downbeat slot. A cue for that position
   is scheduled 3 frames later.
10. **Downbeat.** When a cue comes due, the tracker sums the low-group change between frames
    `t` and `t − 6`: `Σ |L_t − L_(t−6)|`. The cue's slot accent moves 30% of the way toward
    that change. The slot with the first-maximum accent becomes the downbeat slot when its
    accent exceeds 1.1 times the current slot's accent.
11. **Output.**
    - `tempo_bpm = 60 · fr / p`.
    - `beat_in_bar` is the bar position relative to the downbeat slot.
    - `bar_phase = (beat_in_bar + ψ) / beats_per_bar`. It advances smoothly on every frame and
      steps back only with a backward wrap of `ψ`.
    - `confidence` is tempo contrast × phase contrast × onset recency.

### Version 3

Version 3 (`DSP_BEHAVIOR_V3`, OSC-DSP-BEAT-REAL) analyses audio exactly as version 2, so its
frames and their vectors are version 2's. `DspSettings::default()` stays at version 2; hosts opt
in. Every step above holds except these:

| Constant | Version 3 value |
| --- | --- |
| Histogram decay | `1 − 1 / (4 · fr)` |
| Preferred period `p₁₁₀` | `fr · 60 / 110`, which is 110 BPM |
| Envelope mean rate | `1 / fr`, a one-second running mean |

- **Step 1.** A gap or stall also clears the envelope ring and the envelope mean.
- **Step 4, replaced.** The picker still runs, but its onsets no longer feed `H`. On every
  frame, with `e = onset.low + onset.mid + onset.high` (each read as 0 unless finite and
  positive):
  - the mean moves as `μ ← μ + c · (e − μ)`, starting from 0, where `c = 1 / fr` is computed
    once;
  - `z_t = max(0, e − 1.5 · μ)` goes into a ring of `4 · hi + 3` entries;
  - when `z_t > 0`, `H[lag] += z_t · z_(t − lag)` for each lag in `lo − 2 … 4 · hi + 2`,
    ascending, where ring entries not yet written read as 0.
- **Step 5, comb.** The score of `p` is `Σ_(n=1..4) max(H[np − 1], H[np], H[np + 1])`, taken as
  the first of the three in that order to be strictly larger, divided by `1 + 1.5 · r²` with
  `r = (p − p₁₁₀) / (p + p₁₁₀)`. That prior weighs half and double tempo alike. The rest of the
  step, including the refinement and the jump margin, is unchanged.
- **Step 7, deposit.** Once more than 2 frames have been taken since the start or the last gap,
  every frame deposits `s + onset.low` of frame `t − 2` at `pos`, where `s` is the picked
  strength or 0. Before that it deposits nothing. The phase therefore follows the bass between
  picked onsets.

Onset recency (step 9) still counts from the last picked onset.

The wider range raises the shortest frame rate with a tracker: `floor(fr · 60 / 200) ≥ 8` needs
`fr ≥ 26.67` frames per second, against 21.33 for 80–160 BPM. Below it the analyser's built-in
version 3 tracker is absent and `OscilluxDspFrameExt.beat` is all zero.

### Vectors

`beat/*.vectors` are written by `tools/dsp-beat-vectors.py`. It is a standard-library oracle
that shares no code with the Rust tracker. Each file holds:

- the analyser and tracker configuration;
- one `in` row per frame: flags, low and mid onset, and the bands, each quantised to `n / 256`;
- an `out` row for every eighth frame and every beat frame, with floats in shortest round-trip
  decimal;
- an FNV-1a digest over every frame's output: four little-endian f64, then three u32.

| Vector | Configuration | Content |
| --- | --- | --- |
| beat-default | 48 kHz, hop 512, 24 bands; 80–160 BPM in 4/4 | 3400 frames: 120 BPM, then 100 BPM from frame 1100; a gap and stall at frame 1700; silence over frames 2000–3099, longer than sixteen beats |
| beat-config-32k | 32 kHz, hop 256, 16 bands, groups 0–4, 5–10, 11–15; 60–120 BPM in 3/4 | 2000 frames: 90 BPM, then 105 BPM from frame 1000; a gap at frame 1400 |
| beat-v3-default | 48 kHz, hop 512, 24 bands, version 3; 60–200 BPM in 4/4 | 4800 frames: 120 BPM, then 100 BPM from frame 1500; a gap and stall at frame 2400; silence over frames 2700–3799, after which it holds double tempo for a few seconds |
| beat-v3-config-32k | as beat-config-32k, version 3; 60–200 BPM in 3/4 | 3200 frames: 72 BPM (tracked at double tempo), then 174 BPM from frame 1600; a gap at frame 2600 |

`crates/oscillux-core/tests/dsp_beat.rs` runs all four on the host and on wasm32-wasip1
(`make test-wasi`). It checks:

- every sampled row bit for bit, and that every beat frame is sampled;
- the digest;
- a repeat after `reset()`, with no allocation in `update` or `reset`;
- output ranges, non-finite inputs and refused configurations;
- on a 120 BPM pulse with three minutes of silence: no beat from sixteen beats into the
  silence until the pulses return, confidence 0 there, a held tempo, and a `bar_phase` that
  advances by one frame's worth on every frame;
- that a frame with no tempo candidate clears a pending tempo.

`make gate` runs `tools/dsp-beat-vectors.py --check`. The oracle is a transliteration of this
specification, written beside the Rust tracker in the same operation order. A match proves that
the Rust tracker follows the specification as the oracle reads it; a misreading shared by both
would still match. It does not show that the algorithm tracks beats well; the beat benchmark
below measures that. The oracle uses only `+ − × ÷`, floor, ceil and comparisons, so its
`--check` does not depend on the platform's libm.

### Beat benchmark

`dsp_music` runs the tracker with `BeatConfig::for_version` on each score's frames, in all four
behaviour versions. It matches emitted beats one to one with the annotated beats within ±70 ms.
Beats before 5 s are ignored, because the tracker needs about a second of onsets to lock and a
few more to settle. For versions 1 and 2 the test asserts beat F ≥ 0.8 and a nonzero downbeat F
at ±70 ms for every score. Version 3 is tuned on recorded music (not distributed) and is held only to
beat F ≥ 0.7 here. Version 4 is tuned on recorded music too and is held to beat F ≥ 0.8 and a
nonzero downbeat F again (OSC-0001). It prints, without asserting:

- the largest error of a matched beat, and the beat F at ±35 ms;
- the share of frames whose tempo is within 4% of the annotated inter-beat tempo.

| Score | Version | Beat F | Largest matched error | F at ±35 ms | Downbeat F | Tempo within 4% |
| --- | --- | --- | --- | --- | --- | --- |
| music-tempo-steps | v1 | 0.868 | 69.6 ms | 0.811 | 0.519 | 83% |
| music-tempo-steps | v2 | 0.868 | 65.6 ms | 0.830 | 0.538 | 81% |
| music-tempo-steps | v3 | 0.725 | 65.6 ms | 0.686 | 0.320 | 67% |
| music-tempo-steps | v4 | 0.868 | 17.0 ms | 0.868 | 0.538 | 86% |
| music-syncopated-swing | v1 | 0.982 | 15.4 ms | 0.982 | 0.963 | 100% |
| music-syncopated-swing | v2 | 0.982 | 11.9 ms | 0.982 | 0.963 | 100% |
| music-syncopated-swing | v3 | 0.982 | 15.4 ms | 0.982 | 0.857 | 100% |
| music-syncopated-swing | v4 | 0.973 | 20.1 ms | 0.973 | 0.963 | 100% |
| music-pad-noise | v1 | 0.978 | 28.0 ms | 0.978 | 0.909 | 100% |
| music-pad-noise | v2 | 0.935 | 52.0 ms | 0.913 | 0.818 | 95% |
| music-pad-noise | v3 | 0.731 | 44.0 ms | 0.645 | 0.522 | 70% |
| music-pad-noise | v4 | 0.835 | 54.7 ms | 0.791 | 0.435 | 88% |
| music-ramp | v1 | 0.974 | 65.6 ms | 0.487 | 0.214 | 100% |
| music-ramp | v2 | 0.974 | 65.6 ms | 0.452 | 0.593 | 100% |
| music-ramp | v3 | 0.850 | 62.0 ms | 0.100 | 0.000 | 85% |
| music-ramp | v4 | 0.974 | 22.9 ms | 0.974 | 0.857 | 100% |
| music-heldout-breakbeat | v1 | 0.944 | 33.1 ms | 0.944 | 0.880 | 100% |
| music-heldout-breakbeat | v2 | 0.926 | 32.1 ms | 0.926 | 0.846 | 100% |
| music-heldout-breakbeat | v3 | 0.826 | 34.8 ms | 0.826 | 0.643 | 100% |
| music-heldout-breakbeat | v4 | 0.972 | 22.1 ms | 0.972 | 0.923 | 100% |

Margins and limits:

- The asserted margins are thin. Beat F is 0.868 on music-tempo-steps against the 0.8 bound,
  and the largest matched error, 69.6 ms on music-tempo-steps v1, sits just inside the 70 ms
  window. On music-ramp the beats lag the accelerating tempo: F falls from 0.97 to below 0.5
  when the window is halved to ±35 ms.
- Every parameter has now been tuned on all five scores, so the rows measure fit, not
  generalisation. Before OSC-DSP-BEAT-HELDOUT, version 2 of music-heldout-breakbeat scored beat
  F 0.453 and downbeat F 0 at the right tempo. Its onsets split almost equally between each
  beat and the sixteenth before it, so the phase peak flipped between them. The half-beat
  term of the phase score separates the two, and the anchor's hysteresis keeps it on one. No
  licensed real music has been measured.
- Downbeats rely on a low-band accent. On music-ramp the kick plays every beat, so there is no
  bar accent to find.
- A tempo range wider than one octave lets the tracker settle on half or double the tempo. The
  default 80–160 BPM is one octave.
- After a tempo step, the tracker needs about half a second of the new tempo before it switches.
- Version 3 trades these scores for recorded music. Its tempo histogram decays over four
  seconds instead of two, so after a step it keeps the old tempo for about four seconds, and on
  music-tempo-steps it first swings between 96 and 192 BPM before it locks at about 6 s. Its
  every-frame bass deposit follows the pad on music-pad-noise and lags the accelerating kick on
  music-ramp, where F at ±35 ms falls to 0.1 and no downbeat is found. After a long silence
  beat-v3-default holds double tempo for a few seconds before it returns.
- Version 4 has its own limits ("Beat tracker, version 4", "Measured behaviour").

## Beat tracker, version 4

Version 4 (`DSP_BEHAVIOR_V4`, OSC-BEAT-V4) analyses audio exactly as version 2, so its frames,
levels and adaptive levels are version 2's bit for bit; only the `Beat` outputs differ.
`DspSettings::default()` stays at version 2; hosts opt in. `BeatTracker` keeps its interface and
runs the model below instead of the steps above (`crates/oscillux-core/src/dsp/beat_v4.rs`).

The model is a causal beat-pointer hidden Markov model. Its states are pairs `(q, k)`: a beat
period of `q` frames and a phase `k` in `0 … q − 1`, read as "beats fall on the frames
`t ≡ k (mod q)`". Each frame weighs the states whose beat is near the frame by how strongly the
onset envelope stands out, and moves the states whose beat is now to nearby periods. Tempo,
phase and lock follow from the most probable state, so a new tempo or a return from silence is
re-acquired as soon as the evidence favours it, without a histogram to decay first. An octave
cue (OSC-BEAT-V4-OCTAVE) compares the onsets on the beat with those between beats and penalises
the periods of the wrong metrical level. A separate bar-position stage finds downbeats from the
accents of each position in the bar.

### Creation

With `fr = sample_rate_hz / hop_samples`:

| Constant | Value |
| --- | --- |
| Shortest period `lo` | `floor(fr · 60 / max_bpm)`; it must be ≥ 8, else `InvalidConfig("max_bpm")` |
| Longest period `hi` | `ceil(fr · 60 / min_bpm)`; it must be ≤ 512, else `InvalidConfig("min_bpm")` |
| Periods | every integer `q` in `lo … hi`, ascending; index `i` |
| States `S` | the sum of all periods: 4087 at 48 kHz and 3528 at 44.1 kHz for 60–200 BPM |
| Observation half-width `w_q` | `floor(0.04 · q)` |
| Transition weight `T[j][i]` | `exp(−100 · |q_i / q_j − 1|)` for `i` in `j − 3 … j + 3` (within the periods), divided by its row sum |
| Prior factor `g_q` | `exp(−0.5 · z² · 2 · q / fr)` with `z = ln(q / p) / 0.6` and `p = fr · 60 / 100`: a log-Gaussian tempo prior around 100 BPM, applied per second of the period so it presses alike on every tempo |
| Jump range of `i` | the first and last index `j` with `|ln(q_i / q_j)| ≤ 0.3`, and their count `n_i` |
| Envelope mean rate `c` | `1 / (2 · fr)`, a two-second running mean |
| Spectrum lag `L` | `floor(d / hop_samples + 0.5)` with `d` the version 2 bass delay in samples (`conformance/dsp/v2`), or 0 when the configuration has no decimated bass analysis: 8 frames by default |

`exp` and `ln` are evaluated with fixed-iteration series, never the platform's libm:

- `exp(y)`: halve `y` until `|y| < 0.5`, sum `s = 1 + y · s / n` for `n = 20 … 1`, then square
  `s` once per halving;
- `ln(x)`: scale `x` by powers of 2 into `[1, 2)` with exponent `e`, and once more by ½ if it is
  above √2; with `u = (m − 1) / (m + 1)`, sum `a = 1 / (2n + 1) + u² · a` for `n = 12 … 0` and
  return `2 · u · a + e · ln 2`.

Creation and `reset()` set every state to `1 / S`, each period's mass `M_q` to `q / S`, the frame
counter `t` and the envelope mean to 0, and "locked" to false, then apply the soft reset below.

### Per-frame steps

Sums run in ascending index order; "first maximum" keeps the first of equal values. An onset
reads as `unit(v)`: `v` clamped to `[0, 1]`, or 0 unless finite. A spectrum value reads as 0
unless finite and positive.

1. **Gap or stall: soft reset.** If the frame carries `FLAG_GAP` or `FLAG_STALLED`, every
   period keeps its mass `M_q` (from step 6 of the previous frame), spread evenly over its
   phases. The tracker forgets the frames since activity (they become "never"), the last beat,
   the bar position and phase (both 0), the four-frame onset rings (all 0), the whole octave cue
   and the whole downbeat stage. It keeps `t`, the envelope mean and "locked".
2. **Envelope.** `l = unit(onset.low)`, `o = 2 · l + unit(onset.mid) + unit(onset.high)`. The
   frames since activity become 0 if `o ≥ 0.1` and grow by one otherwise (saturating). The mean
   moves as `μ ← μ + (o − μ) · c`. Then `x = o / (3 · μ + 0.001)` and `r = (0.5 + x) / 1.5`:
   `r > 1` where the envelope stands out from three times its mean. The rings of the last four
   frames keep `l` and `h = unit(onset.mid) + unit(onset.high)` at slot `t mod 4`.
3. **Observe.** For every period `q`, with `w = w_q`, and for `s = 0 … 2w`: the state
   `k = (t mod q + q + w − s) mod q` is multiplied by `1 + (r − 1) · (1 − |s − w| / (w + 1))`.
   That is a triangle around the beat: weight 1 for the state whose beat is `t`, falling
   linearly for beats up to `w` frames before or after it.
4. **Advance.** For every period `i`, the state at its beat, `a_i = t mod q_i`, gives up its
   mass: `m_i = mass(i, a_i) · g_i`, times 0.05 if the octave cue penalises period `i`, and
   `mass(i, a_i) = 0`. Then, for every source `j` in
   ascending order and every target `i` in its transition row in ascending order,
   `mass(i, a_i) += m_j · T[j][i] · 0.99`. Finally, with prefix sums `P_0 = 0`,
   `P_(j+1) = P_j + m_j / n_j`, every period gets `mass(i, a_i) += 0.01 · (P_(last_i + 1) −
   P_(first_i))` over its jump range. The moved mass keeps its beat at `t` in the new period, so
   the phase is continuous through a tempo change; the 1% jump lets the tracker re-acquire a
   tempo up to 35% away within a beat or two.
5. **Normalise.** With `total` the sum of all states, every state becomes
   `v · ((1 − 10⁻⁶) / total) + 10⁻⁶ / S`.
6. **Best state.** The first maximum over the periods in ascending order and, within each, the
   phases in ascending order gives `(b, k_b)`, period `q = q_b`. The same pass records each
   period's mass `M_q`, the sum of its phases.
7. **Beat.** The beats elapsed since the best state's last beat, in frames, are
   `e = (t mod q + q − k_b) mod q`. The envelope lags the media time of the window end by 1.5
   frames, so the phase at the media time is `π = e + 1.5`, less `q` if it reaches `q`, and its
   signed distance from the beat instant is `d = π − q` if `π > q / 2` and `π` otherwise. The
   frame is a beat if all hold:
   - the frames since activity are at most `4 · q`;
   - `−0.5 < d ≤ 2.5`, so the beat falls on the frame nearest the compensated beat instant, or
     up to 2.5 frames late when the best state has just jumped;
   - no beat was emitted in the last `0.5 · q` frames (strictly fewer than `0.5 · q` frames
     ago blocks it).

   A beat records `t` as the last beat and sets "locked".
8. **Octave cue.** Runs (below) if the frames since activity are at most `q`; otherwise it is
   cleared as by its soft reset (no period penalised), so a pause or a song change decides the
   octave afresh. The periods it penalises apply from the next frame's step 4.
9. **Downbeat stage.** Runs on every frame (below) with the best period `q` and, on a beat,
   returns the beat's position.
10. **Tempo.** Over the periods `b − 2 … b + 2` (within the periods), `tempo_bpm = 60 · fr /
   (Σ M_q · q / Σ M_q)`.
11. **Outputs.** `t` advances. Until the first beat ("locked" false) every output is 0.
    Otherwise:
    - `beat_phase` is 0 on a beat with `d ≤ 0` and `π / q` otherwise: the phase at the frame's
      media time;
    - the bar position becomes the downbeat stage's position on a beat; without a beat, a
      phase that falls by more than 0.5 from the previous frame's advances it by one (modulo
      `beats_per_bar`), so the bar keeps running through a missed beat;
    - `bar_phase = (position + beat_phase) / beats_per_bar`, `beat_in_bar = position`, and
      `downbeat` is set on a beat at position 0;
    - `confidence` is `min(1, Σ)` times a fade, where `Σ` sums over the periods `b − 2 … b + 2`
      the five phases centred on `(t mod q_i + q_i − e mod q_i) mod q_i`, and the fade is 1 up to
      `q` frames since activity, 0 from `4 · q`, and `(4q − since) / (3q)` in between.

Time to the next beat is `(1 − beat_phase) · 60000 / tempo_bpm` ms; version 4 adds no output
fields.

### Octave cue

Non-beat states receive no observation, so a faster level, which collects more beat factors, is
favoured, and the prior pulls the other way: alone they settle at half tempo on fast music with
a backbeat and at double tempo where off-beat hats and bass are strong. The
cue reads the mid-beat: snare or hi-hat onsets there without kick onsets mark the best period as
two beats; the same pattern on every other beat marks it as the true one.

It keeps decaying sums `L[p]` and `H[p]` of the low and mid-plus-high onset peaks at four
positions `p` of the best state's two-beat cycle (0 and 2 its beats, 1 and 3 the mid-beats after
them), a sample count `n`, a beat count `B`, the last sampled beat and mid-beat frames `t_B` and
`t_M`, an anchor `(t_a, q_a)` or none, a reference period `q_c` or none, and the penalised
periods: none, or every index from `cut` on. A soft reset clears it all: sums, `n`, `B`, `t_B`
and `t_M` 0, the anchor, `q_c` and the penalised periods none. With `q` and `e` from steps 6
and 7:

1. **Period change.** If `q_c` is set and `2 · q_c ≤ 5 · q ≤ 3 · q_c` (halved), the old beats
   and mid-beats become the new beats: `L ← [½ · (L[0] + L[2]), 0, ½ · (L[1] + L[3]), 0]`,
   likewise `H`, and the anchor becomes `(t_B, q_c)`. Otherwise, if `q_c` is set and
   `17 · q_c ≤ 10 · q ≤ 23 · q_c` (doubled), with `(u, v) = (0, 2)` if `L[0] ≥ L[2]` and
   `(2, 0)` otherwise, `L ← [L[u], L[v], L[u], L[v]]`, likewise `H` with the same `u` and `v`,
   and the anchor becomes none. Otherwise, if `q_c` is none, `10 · q > 13 · q_c` or
   `13 · q < 10 · q_c`, the cue is cleared as by a soft reset. Then `q_c = q`.
2. **Position.** If `e = 2` and `2 · (t − t_B) > q` (a beat; the second condition samples each
   beat once when a phase or period shift of the best state brings `e` back to 2): with an
   anchor `(t_a, q_a)`, `ρ = (t − t_a) mod q_a` gives `B = 1` if `q_a < 4ρ < 3 · q_a` and 0
   otherwise, and the anchor becomes none; without one, `B` grows by one. Then `t_B = t` and
   `p = 2 · (B mod 2)`. If `e = floor(q / 2) + 2` and `2 · (t − t_M) > q` (a mid-beat, likewise
   once), `t_M = t` and `p = 2 · (B mod 2) + 1`. On any other frame the cue stops here.
3. **Sample.** With `λ` and `η` the largest values in the low and mid-plus-high rings (starting
   from 0), all eight sums are multiplied by 0.95, then `L[p] += λ`, `H[p] += η` and `n` grows
   by one. While `n < 8` the cue stops here.
4. **Decision.** "Backbeat" holds if `H[1] + H[3] > 0.55 · (H[0] + H[2])` and
   `L[1] + L[3] < 0.4 · (L[0] + L[2])`. With `(u, v)` chosen as in step 1 from the current
   `L`, "alternate" holds if `H[v] > 0.55 · H[u]` and `L[v] < 0.4 · L[u]`. The comparisons are
   strict, so all-zero sums (no mid-plus-high onset, or none on the beats) are no evidence. If
   backbeat holds and `floor(q / 2) ≥ lo`, the penalised periods start at the first index whose
   period is at least `floor(3q / 4)`; otherwise, if alternate holds, at the first whose period
   is at least `floor(3q / 2)` (none if no period is that long); otherwise no period is
   penalised.

### Downbeat stage

The stage keeps, per bar position `i` in `0 … beats_per_bar − 1` and feature `f`, a decaying sum
`A[i][f]` and weight `W[i][f]` (starting at 0 and 10⁻⁹). Adding `v` sets `A ← 0.95 · A + v` and
`W ← 0.95 · W + 1`, so `A / W` is a bias-corrected mean that forgets over about 20 bars. The
features of a beat are:

| `f` | Feature | Weight |
| --- | --- | --- |
| 0 | the mean of the low-group spectrum sum over the beat's interval | 1 |
| 1 | the largest low onset from the frame before the beat to two frames after it | 0.5 |
| 2 | the change from the previous interval: the sum over bands of the absolute difference of the interval-mean spectra | 0.25 |
| 3 | the largest bass flux (the rise of the first three low-group bands, summed over rising bands) over the frame before the interval and its first three frames | 0.5 |

The spectrum features (0, 2 and 3) are read `L` frames late: an interval opens at the frame
`L` frames after its beat, so that the spectrum's delayed bass bands line up with the onsets.
Per frame, with `s` the position of the next beat and `c` that of the next lagged one:

0. On a beat, with `q` the best period and `q_r` the reference period (none after a soft
   reset): if `q_r` is none or `3 · q_r ≤ 4 · q` and `3 · q ≤ 4 · q_r`, `q_r = q` and the run
   count is 0. Otherwise the run count grows by one; when it reaches 4, the beats have moved to
   another metrical level, so every `A` becomes 0 and `W` 10⁻⁹, `q_r = q` and the run is 0.
1. The bass flux of the frame is computed and the first three low-group bands are kept.
2. On a beat, the previous beat's onset window is added to `A[s − 1][1]` (if there was one), and
   a new window opens with the previous frame's low onset. For three frames from the beat, the
   window keeps the largest low onset.
3. If the frame `L` frames ago was a beat, the interval it ends, if one was open, adds its
   features 0, 2 (0 for the first interval) and 3 to position `c − 1`; `c` advances, and a new
   interval opens with the previous frame's bass flux as its largest.
4. During an interval's first three frames, a larger bass flux replaces its largest.
5. On a beat, the feature means `m_f = Σ_i (A[i][f] / W[i][f]) / beats_per_bar` give each
   position the score `Σ_f weight_f · (A[i][f] / W[i][f]) / (m_f + 10⁻⁹)`. With `best` the first
   maximum, and `h` the position chosen at the previous beat (0 after a soft reset): if `h`'s
   score times 1.1 is at least `best`'s, `best = h`. Then `h = best`, the beat's position is
   `(s − best) mod beats_per_bar`, and `s` advances.
6. The frame's low-group sum and its spectrum are added to the open interval.

All positions are modulo `beats_per_bar`. A soft reset clears the whole stage.

### Determinism and cost

Creation uses only the series above, `floor` and `ceil`; the per-frame path uses only IEEE
double addition, subtraction, multiplication, division, absolute value and comparisons, and
allocates nothing (`dsp_beat_v4.rs` counts allocations through 4000 pushes with silence, a
stall and a seek). The per-frame work is two passes over the `S` states (steps 5 and 6), the
`Σ (2 · w_q + 1)` observed states, a few passes over the periods and the octave cue's constant
work. `frame_budget` measures 0.0441 ms per frame for version 4 against 0.0340 ms for version 3
(minimum round median, Apple M-series host, budget 0.5 ms; 0.0454 ms and 0.0352 ms before the
octave cue, the same within run-to-run noise).

### Vectors

`beat-v4/*.vectors` use the `beat/` format with `config behavior_version 4` and are written by
`tools/dsp-beat-v4-vectors.py`, a standard-library oracle that shares no code with the Rust
tracker. It evaluates `exp` and `ln` with the same series and accumulates in the specified order
(explicit loops), so the Rust tracker reproduces every output bit for bit.

| Vector | Configuration | Content |
| --- | --- | --- |
| beat-v4-default | 48 kHz, hop 512, 24 bands, version 4 (93.75 frames/s, spectrum lag 8); 60–200 BPM in 4/4 | 120 BPM, then 140 BPM from frame 900; a gap and stall at frame 1500; silence over frames 1600–1899; 100 BPM after it |
| beat-v4-config-16k | 16 kHz, hop 256, 16 bands, window 1024, 50–7000 Hz, groups 0–4, 5–10, 11–15 (62.5 frames/s, spectrum lag 5); 60–200 BPM in 3/4 | 90 BPM, then 174 BPM from frame 1000; a gap at frame 1500 |

`crates/oscillux-core/tests/dsp_beat.rs` runs both with the `beat/` vectors, on the host and on
wasm32-wasip1 (`make test-wasi`), with the same checks, and also checks that version 4 refuses
a period longer than 512 frames. `make gate` runs `tools/dsp-beat-v4-vectors.py --check`
(`make dsp-beat-v4-vectors-check`). As for `beat/`, a match proves that the tracker follows this
specification as the oracle reads it; the benchmarks measure how well it tracks.

### Measured behaviour

- **Synthetic scores** (`dsp_music`, the table under "Beat benchmark"): beat F 0.835 to 0.974
  and downbeat F 0.435 to 0.963 on all five scores, against 0.725 to 0.982 and 0 to 0.857 for
  version 3. The tempo is within 4% on 86% to 100% of the frames.
- **Recorded music.** The octave cue and downbeat constants were chosen on annotated recorded
  music that is not distributed here, so those results cannot be re-measured from this
  repository.
- **Timing** ("Beat timing" below): mean offset +3.4 ms (standard deviation 9.1 ms) on click and
  kick trains.
- **Lock and recovery** (`dsp_beat_v4.rs`, 48 trains at 48 and 44.1 kHz). A lock starts at the
  first annotated beat from which the next 8 each have an emitted beat within 70 ms, no emitted
  beat in that stretch is unmatched, and the tempo is within 4% on every frame of it. From a cold
  start the lock starts after 1 beat on 32 trains, 2 on 9, 3 on 4, 4 on 2 (60 BPM) and 5 on one
  (60 BPM clicks at 44.1 kHz). After 3 s of silence it holds the tempo and the phase (locked
  from the first returning beat); after 3.2 s, which shifts the phase by 0.4 beat, it re-locks
  within 1000 ms. After a 120 to 140 BPM step it re-locks within 1286 ms, after 100 to 140 BPM
  within 1714 ms.
- **Cold lock on music.** The `dsp_music` cold lock (same measure, from the first beat) is 1 to
  2 beats on three scores but 7 on music-ramp and 8 on music-heldout-breakbeat: the tracker
  first settles at double tempo (music-ramp, 2.0–4.1 s) or at two thirds of it (the breakbeat,
  1.8–3.7 s) before the evidence moves it.
- **Octave.** The octave cue moves fast music with a backbeat (about 180 to 200 BPM) from half
  tempo to the annotated tempo on most frames, at the cost of a small beat F loss on a few slower
  tracks. It does not shorten cold lock (it decides only after eight samples, four beats), and no
  wider prior tried did so without a regression. Its evidence does not
  outlive the music (`dsp_beat_v4.rs`): after 30 s of a 181 BPM backbeat and a 2 s gap, a 75
  BPM kick and hat locks at 75 BPM after 5 beats, and low-band pulses with no mid or high onset
  (80.4 and 100 BPM) give one beat per pulse at their own tempo.
- Downbeats are weak on the trains, whose first beat of four is 3 dB louder: mean downbeat F
  0.447 over the 48 trains, 0 on 12 of them, where the stage settles on another position.
  The stage was tuned on recorded music. A likely cause, not yet verified: the
  spectrum features are read `L` frames late to match the delayed bass bands, and a click's
  undelayed upper bands then fall into the previous position's interval.

## Beat timing

The beat outputs of a frame describe the media time `media_time_ms` of its analysis window end.
The analysis latency of a version is the mean signed offset, emitted beat frame time minus the
onset, of the beats matched one to one within ±70 ms from 5 s on, pooled over the click and kick
trains of `dsp_beat_v4.rs` (60 to 200 BPM, silences and steps, 48 and 44.1 kHz). Each version
runs `BeatConfig::for_version` on its own frames. The constants are those means rounded to a
millisecond; `BEAT_LATENCY_V1_MS` to `_V4_MS` in Rust and `OSCILLUX_DSP_BEAT_LATENCY_V1_MS` to
`_V4_MS` in C carry them. A host that times a reaction to a beat subtracts the constant of the
version it runs.

| Version | Trains: mean offset | Standard deviation | Matched beats | Constant |
| --- | --- | --- | --- | --- |
| v1 | +15.5 ms | 8.7 ms | 2070 | 16 ms |
| v2 | +13.9 ms | 8.9 ms | 2072 | 14 ms |
| v3 | +16.3 ms | 9.5 ms | 2286 | 16 ms |
| v4 | +3.4 ms | 9.1 ms | 2435 | 3 ms |

- Versions 1 to 3 emit a beat when a picked onset or the phase histogram says so, two frames
  after the onset reaches the envelope. Version 4 emits on the frame nearest the compensated
  beat instant, so what remains is the onset's rise within the frame and the hop quantisation
  (one frame is 10.7 ms at 48 kHz, 11.6 ms at 44.1 kHz).
- On recorded music the offset differs from track to track by tens of milliseconds. The
  annotations mark the perceived beat, which sits before or after the strongest onset depending
  on the instrument; no constant removes that.
- `beat_latency_constants_match_the_trains` in `dsp_beat_v4.rs` re-measures every row of the
  trains column and checks the constants (it is ignored by default; run it with `--release
  -- --ignored`). The version 4 row is also checked by the default test.

## Adaptive levels

`oscillux_core::dsp::Agc` (`crates/oscillux-core/src/dsp/agc.rs`) is an optional,
Milkdrop-style normaliser. It returns a `Levels` per frame, with these values, each in [0, 1]:

- each band's level relative to its own recent range;
- each onset band group's level relative to its own recent range;
- each onset band group's absolute level.

It allocates nothing and ignores frame flags. It uses the analyser's `onset_band_groups`, not
the mapper's `MappingConfig::groups`, because it runs beside the analyser and needs no mapper.
The two group sets are equal by default, but they are configured separately. Every analyser
also runs one with `AgcConfig::default()` on every hop, whichever push function is used, and
`oscillux_dsp_push_ext_f32`/`_f64` write its output as `OscilluxDspFrameExt.levels` (all zero
when `db_floor` is above -12 dB). C callers get only that default configuration. The mapper
does not read these levels. Feeding them to it should be an explicit opt-in later,
because using them by default would change mapped outputs.

The spectrum is already in dB, mapped from `db_floor … 0` to `[0, 1]`, so every range here is a
range in dB. `AgcConfig` holds four values:

- `time_constant_s`: default 4 s; finite and positive;
- `min_range_db`: default 12 dB; positive and ≤ `−db_floor`;
- `gate_db`: the noise gate depth, in dB below each level's reference; default 36 dB; finite and
  ≥ `min_range_db`;
- `reference_time_constant_s`: how fast each reference relaxes; default 600 s; finite and
  positive.

With `h = hop_samples / sample_rate_hz`, the follow rate is `k = h / (time_constant_s + h)`, the
reference rate is `kr = h / (reference_time_constant_s + h)`, the floor is
`f = min_range_db / −db_floor` and the gate is `g = gate_db / −db_floor`.

Per frame:

1. **Levels.** A band level reads as 0 unless it is finite. A finite level is limited to
   [0, 1]. A group's absolute level is the sum of its band levels, in ascending order, divided
   by its band count.
2. **Range update.** Every band and group has a range `(hi, lo)` and a reference `r`.
   - On the first frame after `new` or `reset`, `hi = lo = r = x`.
   - After that, in this order: `r = x` when `x > r`, else `r + kr · (x − r)`; then `hi = x`
     when `x > hi`, else `hi + k · (x − hi)`; then `lo = x` when `x < lo`, else
     `lo + k · (x − lo)`.
3. **Read.** If `hi − lo ≥ f`, the base is `lo` and the span is `hi − lo`. Otherwise the span is
   `f` and the base is `positive((hi + lo − f) / 2)`. That window is centred on the range, so a
   level that holds steady reads 0.5. The relative level is `unit((x − base) / span)`, where
   `positive(v) = v` if `v > 0`, else +0, and `unit(v) = positive(v)` if `v < 1`, else 1.
4. **Noise gate.** The relative level is multiplied by `unit(((hi − r) + g) / f)`: 1 while the
   range's maximum is within `gate_db − min_range_db` of the reference, falling linearly to 0
   at `gate_db` below it. Both maxima jump up at once, so the gate opens on the first loud
   frame. Once the maximum has relaxed onto quiet hiss after loud material, the hiss reads 0
   instead of being stretched to mid-scale. Entries past `band_count` are 0.

The gate is relative. It compares each level with its own loudest recent value, never with an
absolute level, so a quiet master reads like a loud one: the same input 20 dB quieter gives the
same relative levels up to rounding, as long as it stays above the analyser's floor. Below that
floor no normaliser setting helps. Band levels under `db_floor` reach the normaliser as 0, so at
−20 dB input gain the mid and high groups of the scores below lose span, gated or not (see "Gain
sweep" below). Lowering `db_floor` by the same amount restores them.

With the defaults:

- Material up to 24 dB below the loudest of the last few minutes reads in full. From 24 to 36 dB
  below, it is scaled down linearly, and from 36 dB below it is gated. A passage that much
  quieter than what came before reads low until the reference has relaxed, which takes minutes.
- Hiss around −84 dB after 10 s of material at −22.5 dB stays gated for about 275 s. It is fully
  open again after about 500 s, once the reference has relaxed to within 24 dB of it.
- A level that has never been louder is not gated: hiss from the start of a stream reads like
  any other steady level, about 0.5, because nothing distinguishes it from quiet music. Digital
  silence reads 0 either way, because the window's base cannot fall below 0.

### Vectors

`agc/*.vectors` are written by `tools/dsp-agc-vectors.py`. It is a standard-library oracle that
shares no code with the Rust normaliser. Each file holds:

- the configuration;
- one `in` row of band levels per frame, quantised to `n / 256`;
- an `out` row for every eighth frame: relative groups, absolute groups, then relative bands;
- an FNV-1a digest over every frame: the little-endian u32 band count, then every value as f64.

| Vector | Configuration | Content |
| --- | --- | --- |
| agc-default | default analyser; 4 s, 12 dB, gate 36 dB, reference 600 s | 2800 frames: beats, the same beats 30 dB lower (on the gate's ramp), silence, a steady level, a moving peak, then hiss at −87 to −81 dB under the gate |
| agc-config-32k | 32 kHz, hop 256, 16 bands, groups 0–4, 5–10, 11–15, dB floor −80; 1.5 s, 18 dB, gate 20 dB, reference 10 s | 1500 frames: a steady level, beats, silence, a moving peak |

In both vectors the gate is closed, on its ramp and fully open on some frames, and in agc-config-32k
the reference relaxes measurably within the vector.

`crates/oscillux-core/tests/dsp_agc.rs` runs on the host and on wasm32-wasip1 (`make test-wasi`).
It checks:

- the sampled rows bit for bit, and the digest;
- a repeat after `reset()`, with no allocation in `update` or `reset`;
- input cleaning and flags;
- the steady-level reading;
- that hiss around −84 dB (±3 dB) after 10 s of loud input reads below 0.02 from 15 s on, and
  that the next loud frame reads 1; with the gate opened past the whole range
  (`gate_db = −db_floor + min_range_db`) the same hiss reads a mean of 0.50;
- that one programme at 0 and −20 dB gives the same relative levels to within 1e-9 (measured
  2.1e-15). The programme is loud material, a passage 20 dB quieter, then 60 s of hiss 50 dB
  below the loud material. The test also checks that the quieter passage reaches 1 and that the
  hiss is gated at both gains;
- refused configurations.

`make gate` runs `tools/dsp-agc-vectors.py --check`. As with the beat oracle, it is a
transliteration of this specification in the Rust stage's operation order: a match proves that
the Rust normaliser follows the specification as the oracle reads it, not that the levels are
useful, which the span benchmark below measures. The normaliser part uses no libm function.
The input generator raises 0.9 to integer powers with Python's `**`, which calls the platform's
`pow`. The quantised inputs are written into the vectors and the Rust test reads them, so a `pow`
that rounds differently could change an input row and fail `--check` although the committed
vectors are still correct; read such a failure as a libm difference first.

### Span benchmark

`dsp_music` runs the default normaliser on each score's frames in both behaviour versions. From
5 s on, it measures the spread between the 5th and 95th percentile of each onset group's
relative level, and asserts a spread ≥ 0.6 for every score. The absolute group spread is
printed for comparison.

| Score | Version | Relative spread, low / mid / high | Absolute spread, low / mid / high |
| --- | --- | --- | --- |
| music-tempo-steps | v1 | 0.974 / 0.946 / 0.985 | 0.596 / 0.239 / 0.275 |
| music-tempo-steps | v2 | 1.000 / 0.984 / 0.986 | 0.512 / 0.219 / 0.275 |
| music-syncopated-swing | v1 | 0.983 / 0.953 / 0.983 | 0.516 / 0.236 / 0.279 |
| music-syncopated-swing | v2 | 1.000 / 0.982 / 0.983 | 0.434 / 0.215 / 0.280 |
| music-pad-noise | v1 | 0.929 / 0.851 / 0.941 | 0.513 / 0.227 / 0.315 |
| music-pad-noise | v2 | 0.983 / 0.896 / 0.941 | 0.480 / 0.227 / 0.315 |
| music-ramp | v1 | 0.995 / 0.926 / 0.989 | 0.244 / 0.254 / 0.263 |
| music-ramp | v2 | 1.000 / 0.970 / 0.990 | 0.265 / 0.240 / 0.264 |
| music-heldout-breakbeat | v1 | 0.987 / 0.964 / 0.988 | 0.496 / 0.244 / 0.236 |
| music-heldout-breakbeat | v2 | 1.000 / 0.977 / 0.988 | 0.401 / 0.225 / 0.236 |

The lowest relative spread is 0.851 (music-pad-noise v1, mid group). The relative gate takes at
most 0.0008 of span on these scores (music-pad-noise v2, low group).

#### Gain sweep

`agc_group_span_across_input_gain` analyses every score again at lower input gain:
at −12 and −20 dB in both versions, and at −30 dB in v2 with `db_floor` lowered to −120 dB. It
asserts the following:

- At every gain, the gate costs at most 0.01 of span against the gate opened past the whole
  range.
- Spans are ≥ 0.6 at 0 and −12 dB, and ≥ 0.4 at −20 dB, where the analyser floor clips the mid
  and high groups.
- At −30 dB with the lowered floor, spans are ≥ 0.6 and within 0.01 of the 0 dB spans.

| Input gain | `db_floor` | Lowest relative spread, low / mid / high |
| --- | --- | --- |
| 0 dB | −90 dB | 0.929 / 0.851 / 0.941 |
| −12 dB | −90 dB | 0.927 / 0.753 / 0.923 |
| −20 dB | −90 dB | 0.921 / 0.432 / 0.589 |
| −30 dB (measured once, not in the test) | −90 dB | 0.912 / 0.116 / 0.088 |
| −30 dB (v2) | −120 dB | 0.983 / 0.896 / 0.941, equal to v2 at 0 dB |

The lowest spreads come from music-pad-noise (low, and mid at −12 dB), music-tempo-steps v2 (mid
at −20 dB), music-syncopated-swing v2 (mid at −30 dB) and music-ramp (high at −20 and −30 dB).
The mid and high groups of these scores peak between −59 and −68 dB at 0 dB gain. At −20 dB they
are within 22 dB of the −90 dB floor, and their quieter frames are below it. The absolute gate
it replaces (12 dB above the floor) left v2 mid spans of 0.04–0.22 and high spans of 0.30–0.46
at −12 dB, and 0.000 for both at −20 dB.

These are synthetic scores, and their levels change faster than most recorded music. Real music
has not been measured.
