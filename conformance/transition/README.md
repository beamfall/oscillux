<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Transition scheduler vectors

`reference.json` is written by `tools/transition-vectors.py`, a standard-library model of the
scheduler written from this file. `make gate` runs it with `--check`. The expected values are
exact (tolerance 0): the model and every implementation use only `+ - * /`, `ceil`,
comparisons and the easing polynomial, in the order given below.

The vectors are checked by:

- the Rust core: `crates/oscillux-core/tests/transition_vectors.rs`
- the C interface: `crates/oscillux-ffi/tests/transition_ffi.rs`
- the web port `hosts/web/transition.js`: `tools/shader/test-transition.mjs`

The Swift port `hosts/apple/Sources/TransitionDirector.swift` is a line-for-line port of the
same model.

## Model

A clock is `(time_seconds, beat_phase, bar_phase, tempo_bpm, confidence)`. It is *confident*
when all of these hold:

- `confidence >= min_confidence`
- `30 <= tempo_bpm <= 300`
- both phases are in `[0, 1]`

NaN fails every comparison, so a NaN field makes the clock not confident. A confident clock
has `beat = 60 / tempo_bpm` and `bar = beat * beats_per_bar`.

`request(clock, quantise, max_wait)` is refused when `time_seconds` is not finite, when
`quantise` is above 2, or when `max_wait` is not `>= 0`. `max_wait` may be `+inf`. Otherwise,
with `r = time_seconds` and `earliest = r + pre_roll_seconds`:

- **No confident beat:** `start = earliest`, `duration = fallback_seconds` and the applied
  quantisation is none.
- **Confident beat:** `start = earliest` and applied = none to begin with.
  - For bar: `at = boundary(bar_phase, bar)`. If `at - earliest <= max_wait`, then
    `start = at` and applied = bar.
  - For bar not applied, or for beat: `at = boundary(beat_phase, beat)`. If
    `at - earliest <= max_wait`, then `start = at` and applied = beat.
  - `duration = min(max(duration_beats * beat, 0.8), 2.5)`.
- `boundary(phase, period)` is computed as:
  - `k = ceil((earliest - r) / period + phase)`
  - `at = r + (k - phase) * period`
  - the result is `earliest` if `at < earliest`, else `at`. This is the first boundary at or
    after the end of the pre-roll.
- `end = start + duration`. A request replaces any current schedule and clears the
  auto-advance anchor.

`progress(t)` is:

- 0 while idle or when `!(t > start)`
- 1 when `t >= end`
- otherwise `u = clamp((t - start) / (end - start), 0, 1)` with easing applied: `u` for
  linear, `u * u * (3 - 2 * u)` for smoothstep.

The state at `t` is checked in this order:

1. idle when there has been no request
2. done when `t >= end`
3. blending when `t >= start`
4. waiting when `t >= earliest`
5. pre-roll otherwise

`update(clock)` is refused when `time_seconds` is not finite. When `auto_advance_bars > 0` and
the scheduler is *settled* (idle, or `t >= end`), it works as follows:

1. The anchor is set if it is unset: to `t` when idle, else to `end`.
2. The bar length is `bar`, or `(60 / 120) * beats_per_bar` without a confident beat.
3. If `t - anchor >= auto_advance_bars * bar`, it issues `request(clock, bar, bar)`, which
   waits at most one bar, and reports `auto_requested = 1`.

The status of `update` is evaluated at `t` after any automatic request. `reset` returns to
idle and clears the anchor.

## Cases

- `no-beat-30hz`, `no-beat-60hz` and `no-beat-120hz`: one switch, updated every frame at three
  rates.
- Quantised starts at 120 BPM:
  - `quantise-bar-120bpm`, `quantise-beat-120bpm` and `quantise-none-120bpm`, each at eight
    bar phases.
  - `wait-limit-fallback`: the fallback from bar to beat, then from beat to none.
- `duration-clamp`: tempi from 30 to 300 BPM, including 96 BPM, where 4 beats is exactly
  2.5 s.
- `confidence-and-ranges`: clocks that do and do not count as a beat, including NaN and
  infinite fields.
- `smoothstep-beat-128bpm`: smoothstep easing with no pre-roll, updated at 60 Hz.
- `on-boundary-no-pre-roll`: a request exactly on a bar starts at once.
- `replace-and-reset`: a request during a blend replaces it, and reset returns to idle.
- Auto-advance:
  - `auto-advance-no-beat` and `auto-advance-100bpm`: every two bars, without a beat and on
    a 100 BPM clock.
  - `auto-advance-after-manual`: a manual request restarts the count.
- `refused-inputs`, and 11 `config-*` cases that are refused at creation.
