<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Reaction sampler vectors

The reaction sampler (`crates/oscillux-core/src/reaction.rs`, C `oscillux_reaction_*`) turns
mapped analysis hops into the audio values of one display frame at the moment its light reaches
the viewer. This file specifies it; `vectors.json` pins it. `tools/reaction-vectors.py`, an
independent standard-library model written from this file, wrote `vectors.json`; Rust output
was never used as a golden. `make gate` runs `python3 -I tools/reaction-vectors.py --check`
(fails if the model would write a different file) and `crates/oscillux-core/tests/reaction_vectors.rs`
(fails if the sampler does not reproduce every step), which `make test-wasi` also runs on wasm32.

Tolerance: every float output within `1e-12` absolute (the model's `exp` and the core's
`libm::exp` may differ in the last place), every integer output and every call result exact.
Spectrum bins are compared after rounding to `f32`.

## Model

All times are media-timeline milliseconds. Slots: AMPLITUDE 0, LEVEL 1, BASS 2, MID 3, TREBLE 4,
ONSET 5, BASS_IMPACT 6, FLUX 7, CENTROID 8; transients are ONSET, BASS_IMPACT and FLUX (releases
`onset_release_ms`, `bass_impact_release_ms`, `flux_release_ms`), the other six are continuous.
`frac(x) = x - floor(x)`, `wrap(x) = x - floor(x + 0.5)`.

**Configuration.** `struct_size` 96, `capacity` in `1..=65536`, the five latencies (output,
display, render-ahead, analysis, onset) finite and `>= 0`, the three releases and the pulse
decay and rise finite and `> 0`, `phase_lock_gain` in `[0, 1]`. Defaults: capacity 256, no
output, display or render-ahead latency, releases 60 / 150 / 60, pulse decay `1000/9`, pulse
rise 30, gain 0.1, and DSP version 3's latencies. `for_dsp(version, rate)` takes the
(analysis, onset) row of version 1 (10.6, 16.0), 2 (7.7, 13.3), 3 (7.7, 13.3) or 4 (7.7, 13.3), each multiplied
by `48000 / rate`; another version or rate 0 has none.

**Push** `(m, mapped, beat?)` is refused (state unchanged) as *invalid* when `m` is not finite or
below the last pushed `m`, a mapped value or bin is not finite, or the beat has a non-finite
tempo, phase, bar phase or confidence, tempo `< 0`, a phase outside `[0, 1)` or
`beat_in_bar >= 16`; then as *full* when `capacity` hops are queued. Otherwise the hop is queued.

**Beat clock** `set(clock?)`: a clock is *invalid* unless its time, tempo and phases are
finite, tempo `> 0`, both phases in `[0, 1)`, `beats_per_bar` in `1..=16` and `reserved` 0.
A valid clock, or none, replaces the stored one. **Reset** empties the queue and returns every
state below to its initial value; the configuration stays.

**Sample** `(time)`: a non-finite time is *invalid* and changes nothing. Otherwise
`t = time + render_ahead + display - output`, then, in order:

1. *Transients.* Walk the queued hops not yet used for transients, oldest first, while
   `m - onset_latency <= t`. For each transient slot, if the hop's value `v >= level(peak, t)`
   the peak becomes `{value v, hold_until m, release_from none}`.
2. *Continuous.* Pop the oldest hop while `m - analysis_latency <= t`; if it was not yet used for
   transients, apply step 1's rule to it now. Then *accept* it (below) as the current hop.
3. *Values.* With a current hop `a` and a next queued hop `b` with `b.m > a.m`:
   `w = clamp((t - (a.m - analysis_latency)) / (b.m - a.m), 0, 1)` and each continuous slot is
   `x + (y - x) * w`; each bin is the same in double precision, rounded to `f32`. With no such
   `b` the slots and bins hold `a`'s. With no current hop they are 0. For each transient: if
   `release_from` is none and `t >= hold_until`, `release_from = t`; the slot is `level(peak, t)`,
   where `level` is `value * exp(-(t - from) / release)` when `release_from = from` and `t > from`,
   else `value`. The initial peak is `{0, -inf, none}`.
4. *Beat* (below).

**Accept** a hop at `m`, `event = m - analysis_latency`. With a beat of tempo `> 0`: the bar
length is `n = floor((beat_in_bar + beat_phase) / bar_phase + 0.5)` when `bar_phase > 0`,
`1 <= n <= 16` and `beat_in_bar < n`, else `max(fallback, beat_in_bar + 1)` with fallback the
previous tracker reference's bar length or 4. If a previous tracker reference exists and the
tempo differs from its tempo by more than 6% of it, the lock offset becomes 0. The tracker
reference becomes `{origin event, tempo, beats beat_phase, bar_beats beat_in_bar + beat_phase,
bar length n, confidence, active confidence > 0}`. With a beat of tempo 0 the tracker reference
and the lock offset are cleared; a hop without a beat keeps both. Then the phase lock: with a
tracker reference that is active, gain `> 0`, this hop's ONSET `>= 0.5` and the previous accepted
hop's `< 0.5` (initially 0), `err = wrap(beats_at(event) + lock_offset)`; if `|err| < 0.15`,
`lock_offset = wrap(lock_offset - gain * err)`. A reference at `x` has
`beats_at(x) = beats + (x - origin) * tempo / 60000` and `bar_at(x)` the same from `bar_beats`.

**Reference.** A stored clock gives `{origin time, tempo, beats beat_index + beat_phase,
bar_beats bar_phase * beats_per_bar, beats_per_bar, confidence 1, active}` (absolute mode).
Otherwise the tracker reference with the lock offset added to `beats` and `bar_beats`.

**Beat.** Without a reference: set the resync flag and leave every beat output 0 (`locked` 0). With one, `p = tempo / 60000`, bar length `B`,
`bar_index(bb, ph) = min(k mod B, B - 1)` with `k = floor(bb - ph + 0.5)` (mod into `[0, B)`).
Storing a clock sets a re-anchor flag, which every sample clears. The follower resyncs when there is
none, the resync flag is set, `last_t - t > 100`, `t - last_t > 500`, or the re-anchor flag is
set with `t < last_t`; the resync flag is then cleared. When not resyncing and `t < last_t` (a
backward step of at most `100` ms), the follower state stays held. Resync: `beats = beats_at(t)`
in absolute mode; in tracker mode, `phase = frac(beats_at(t))`, `beats = phase` when there was no
previous follower, or `phase + floor(reached - phase + 0.5)` with `reached = prev_beats + max(t - prev_last_t, 0) * prev_rate`
(plus `1` if `beats < prev_beats`); `in_bar = bar_index(bar_at(t), frac(beats))`; `rate = p`, `corr = 0`; not pulsed. Otherwise with `dt = t - last_t`:
`R = beats_at(t)`; in absolute mode with the re-anchor flag set, `rate = p` and
`beats += floor(R - (beats + dt * rate) + 0.5)`; `rate += (p - rate) * (1 - exp(-dt / 1000))`; `err = wrap(R - (beats + dt * rate))`,
`corr += (clamp(err / (500 * rate), -0.15, 0.15) - corr) * (1 - exp(-dt / 250))` (target 0 when
`rate` is 0), `n = beats + dt * rate * (1 + corr)`, `s = R + floor(n - R + 0.5)`; `beats = s` when
`|n - s| < 1e-9` and `s >= beats`, else `beats = n`; when `floor(beats)` increased, `in_bar = bar_index(bar_at(t), frac(beats))`, `pulsed = active`,
`pulsed_down = active and in_bar == 0`. Either way `last_t = t` and `in_bar` is reduced mod `B`.
Outputs with `ph = frac(beats)` and `v = rate * (1 + corr)`: `decay = exp(-(ph / v) / pulse_decay)`,
`rise = exp(-(((1 - ph) / v) / pulse_rise)^2)`; `beat = max(pulsed ? decay : 0, active ? rise : 0)`,
`downbeat` the same with `pulsed_down` and `active and (in_bar + 1) mod B == 0`;
`beat_phase = ph`, `bar_phase = (in_bar + ph) / B`, tempo, confidence, `beat_in_bar = in_bar`,
`beat_count = floor(beats)`, `locked` 1.

## Vectors

`vectors.json` holds `for_dsp` rows, configuration validity cases and scenarios. A scenario has
a full `config` and `steps`: `push` (media time, nine values, optional 64-bin spectrum, optional
beat, expected `ok` / `invalid` / `full`), `clock` (a clock or null, expected result), `reset`,
and `sample` (time and either `invalid` or every output, the number of queued hops after it and,
when the scenario carries spectra, the 64 bins). Non-finite inputs are the strings `NaN`,
`Infinity` and `-Infinity`. The scenarios cover tracked click trains at 30, 60 and 120 Hz with
output, display and render-ahead latency, the phase lock, a host clock and its replacement and
removal, seeks back and forward, small backward jitter hold, tracker dropout resync, reset, tempo
changes, a zero-tempo beat, beats without a tracker output, bar-length inference and fallback,
onset latency below analysis latency, interpolated spectra, equal hop times and every refusal.
