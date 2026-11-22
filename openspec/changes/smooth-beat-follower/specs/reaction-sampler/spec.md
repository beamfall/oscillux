<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Reaction sampler

## ADDED Requirements

### Requirement: Beat follower rate never steps

Between resyncs, the reaction sampler's output beat phase SHALL advance at a rate that slews
towards the reference tempo, with the phase error closed by a slewed correction of at most 15% of
that rate. A change of reference tempo or phase SHALL then bend the output's speed over several
frames and never step it from one frame to the next. A residual phase error under 1e-9 beats
SHALL be taken exactly.

#### Scenario: Tracker tempo flips

- **WHEN** a tracked reference flips between two tempos while the sampler is sampled at 60 Hz
- **THEN** the output beat phase only moves forward, and its per-frame advance changes by a few
  percent per frame at most, never by a factor of two

#### Scenario: Steady known clock

- **WHEN** a host beat clock at 120 BPM is sampled at 60 Hz for 10 s
- **THEN** the output wraps exactly 20 times, and the beat pulse peaks at each beat

#### Scenario: Replacement clock half a beat away

- **WHEN** a host replaces the beat clock with one half a beat away
- **THEN** the output phase does not jump; it converges over the following frames at no more
  than 15% above or below its rate
