<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Reaction sampler

## MODIFIED Requirements

### Requirement: Beat count follows wraps and a newly set host clock

`beat_count` SHALL count output wraps and SHALL not decrease between resyncs. A newly set host
beat clock SHALL set the output rate and move the output by whole beats within half a beat while
the phase slews. Without a host clock, a resync SHALL keep the tracker's phase at the whole beat
nearest the reached position, never behind the prior output.

#### Scenario: Replacement clock at another tempo

- **WHEN** a host replaces a 120 BPM clock with a 60 BPM clock of the same origin after 2 s
- **THEN** the next sample reports the new clock's beat 2, and the count then only goes up by
  one at each wrap, reaching 10 at 10 s

#### Scenario: Tracker resync after dropout never loses a beat

- **WHEN** the tracker drops out and later resumes while the output advances near or past a beat
  boundary
- **THEN** the resynchronised output keeps the tracker's fractional phase, selects the whole beat
  nearest the position reached at its previous rate, and never lands behind the prior output

## ADDED Requirements

### Requirement: Beat follower holds small backward sample-time steps

When a follower state exists and sample target time steps backwards by at most `100` ms without
a pending resync flag or a newly set host clock targeting an earlier time, the beat follower
SHALL hold its output state unchanged. Steps back over `100` ms or jumps forward over `500` ms
SHALL still resynchronise.

#### Scenario: Backward clock jitter holds while larger seeks resynchronise

- **WHEN** the sampler samples backwards by up to 100 ms relative to the follower's last sample
  time under steady tracking or a steady clock
- **THEN** the follower holds its previous beat count, phase, and rate unchanged, while a step
  back larger than 100 ms or forward jump over 500 ms resynchronises
