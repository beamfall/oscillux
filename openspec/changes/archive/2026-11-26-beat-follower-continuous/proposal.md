<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Keep the beat follower continuous across small backward clock steps and tracker resyncs

Ticket: **CORE-3277** (Corvint Tasks, beamfall core queue).

## Why

The web player runs `ReactionSampler` in tracker mode (no `BeatClock`), driving visuals from
continuous beat position (`beat_count + beat_phase`). Two behaviours caused visible stuttering:

1. Host clock jitter (such as `AudioContext.currentTime` sampled at `requestAnimationFrame`) can
   produce small backward steps in sample time. Because `sample_beat` resynchronised on any
   `t < last_t`, even tiny backward jitter snapped the follower back to tracker resync.
2. On a tracker-mode resynchronisation (for example after a tempo dropout or backward seek),
   setting `beats = floor(prev.beats) + frac(target)` dropped a whole beat whenever the tracker
   phase had wrapped ahead of `frac(prev.beats)`, moving continuous beat position backwards.

## What Changes

- Hold the beat follower state unchanged when sample time steps backwards by at most
  `HOLD_BACK_MS` (`100.0` ms), unless an explicit resync is active or a newly set host clock's
  target time precedes the follower's last sample time. Backward steps larger than
  `HOLD_BACK_MS` and forward jumps larger than `RESYNC_MS` (`500.0` ms) still resynchronise.
- On a tracker-mode resynchronisation from an existing follower state, keep the tracker's
  fractional phase and land on the whole beat nearest the position the output would have reached
  from its previous state (`prev.beats + max(t - prev.last_t, 0) * prev.rate`), advancing by one
  beat if rounding falls behind `prev.beats` so continuous beat position never moves backwards.
- Mirror the rule in `tools/reaction-vectors.py`, regenerate `conformance/reaction/vectors.json`,
  and update `conformance/reaction/README.md`.

## Impact

- `crates/oscillux-core/src/reaction.rs` (`HOLD_BACK_MS`, `sample_beat`, module docs, tests).
- `tools/reaction-vectors.py`, `conformance/reaction/vectors.json`, `conformance/reaction/README.md`.
- `CHANGELOG.md` (`[Unreleased]`).
- No C ABI or public struct layout changes.
