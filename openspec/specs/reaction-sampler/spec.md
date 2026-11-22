# reaction-sampler Specification

## Purpose
How the reaction sampler's beat follower tracks a reference tempo and a host beat clock: the output
rate slews toward the reference, phase error closes by a bounded slewed correction, and a newly set
beat clock is taken at the next sample, which `conformance/reaction/vectors.json` pins.

## Requirements

### Requirement: Beat follower rate never steps

Between resyncs, the reaction sampler's output beat phase SHALL advance at a rate that slews
towards the tracker's tempo, with the phase error closed by a slewed correction of at most 15% of
that rate. A change of reference tempo or phase SHALL then bend the output's speed over several
frames and never step it from one frame to the next. A residual phase error under 1e-9 beats
SHALL be taken exactly unless that moves the phase backwards.

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

### Requirement: Beat count follows wraps and a newly set host clock

`beat_count` SHALL count output wraps, so it never goes down between resyncs. A newly set host
beat clock SHALL be taken at the next sample: its tempo becomes the output rate, and the output
position moves by whole beats to within half a beat of the clock's, while the phase still slews.
The count then reaches the clock's beat index at the output's own wrap.

#### Scenario: Replacement clock at another tempo

- **WHEN** a host replaces a 120 BPM clock with a 60 BPM clock of the same origin after 2 s
- **THEN** the next sample reports the new clock's beat 2, and the count then only goes up by
  one at each wrap, reaching 10 at 10 s
