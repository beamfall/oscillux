<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Beat follower bends its rate instead of racing and stalling

Ticket: **CORE-3215** (Corvint Tasks, beamfall core queue).

## Why

The owner sees beat-driven visuals in the Beamfall web player as jerky (CORE-3215; CORE-2215
closed without a cause). Replaying the web player's analysis (Dsp, Mapper, `ReactionSampler`) at
60 Hz on a low-confidence track shows the cause. The tracker's reference tempo flips between
candidates (62.5 and 83 BPM on the "Floor Pressure" test track), and the follower closes each
phase error with a 50 ms slew clamped to 0.5 to 2 times the nominal rate. The output beat phase
races and stalls: about a quarter of frames sit on a clamp, and the frame-to-frame rate steps by
up to 300%. Every visual driven by `beat_phase` or `beat_count` lurches with it.

## What Changes

- The follower keeps its own output rate, which slews towards the reference tempo with a 1 s
  time constant.
- The phase error is closed by a correction of at most ±15% of that rate, aimed to close the
  error over 500 ms and itself slewed with a 250 ms time constant, so the output rate never
  steps.
- A residual phase error under 1e-9 beats is taken exactly, and never backwards, so rounding
  never moves a steady clock's wrap by a frame.
- `beat_count` counts output wraps in both modes, so it never goes down between resyncs. A newly
  set host clock is authoritative: the next sample takes its tempo and moves the count to its
  beat index by whole beats, while the phase still slews. No host sets a beat clock today.
- The beat pulse's rise and decay use the output phase speed, rate times one plus the correction.
- Resync behaviour (first sample, reset, a seek back or a jump over 500 ms) is unchanged.
- `tools/reaction-vectors.py` mirrors the change, `conformance/reaction/vectors.json` is
  regenerated, and the Beat section of `conformance/reaction/README.md` describes it.

## Evidence

- Offline replay at 60 Hz: rate against its local median, p1 to p99, goes from 0.29–3.98 to
  0.89–1.11 on "Floor Pressure" and to 0.93–1.08 on "Night Drive". The largest frame-to-frame
  step goes from 2.98 to 0.031 and from 3.0 to 0.022.
- `make reaction-photon`:
  - A known clock still peaks the pulse at the beat (0.003 ms mean offset).
  - The followed tracker vectors meet criterion 2 (mean |offset| 4.32 ms, jitter 2.74 ms).
  - Phase step against nominal ranges 0.856–1.992 (was 0.5–2.0).
- Cost: the tempo-error vectors, which are reported and not gated, worsen.
  - Mean |offset| goes from 32.8 to 63.0 ms, and missed beats from 128 to 149.
  - When the tracker's tempo is wrong, the follower no longer chases it at up to twice the rate.

## Impact

- `crates/oscillux-core/src/reaction.rs` (follower state, constants, module doc).
- Reaction conformance vectors and their README.
- Hosts pick the change up through a release; no API or ABI change.
