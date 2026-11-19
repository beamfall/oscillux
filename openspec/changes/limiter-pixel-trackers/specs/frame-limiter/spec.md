<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## REMOVED Requirements

### Requirement: Partial-coverage red

**Reason**: Red is tracked per pixel at the auditor's step, so red covering part of a sub-block
counts by its pixels instead of a diluted block mean.

**Migration**: Hosts bind the `uTrack` state texture; see "Per-pixel transition trackers".

## ADDED Requirements

### Requirement: Per-pixel transition trackers

The frame limiter SHALL keep, for every pixel, the pixel auditor's luma and red transition
trackers on the same 16-bit codes and thresholds, step them on its output, and count toward the
area limit every pixel that fires now or fired within the coverage interval. A direction SHALL be
over when a window of whole cells that contains the field wherever it is placed holds more than a
quarter of the field's pixels.

#### Scenario: A change that builds up over frames

- **WHEN** every other row cycles grey 124, 140, 153, 140 beside red holds at 128 x 72
- **THEN** the pixel auditor counts at most 6 large-area luma transitions and at most 1 red
  transition in every 1 s window of the output

#### Scenario: Changes over part of many sub-blocks

- **WHEN** some 5 x 5 sub-blocks toggle grey 124 and 153 whole and others only their first row,
  beside red holds at 320 x 180
- **THEN** the pixel auditor counts at most 6 large-area luma transitions and at most 1 red
  transition in every 1 s window of the output

#### Scenario: The limiter's trackers are the auditor's

- **WHEN** any sequence of frames runs through the limiter and the auditor reads its output
- **THEN** every pixel's decoded tracker state equals the auditor's for that pixel

### Requirement: Per-pixel holds

The frame limiter SHALL show the previous output at exactly the pixels whose trackers would fire
on the input in a direction the grant did not admit, and the input at every other pixel.

#### Scenario: A held strobe beside a drifting background

- **WHEN** a 10 Hz white strobe over half the TV field is held while the background beside it
  drifts
- **THEN** every background pixel, including those in sub-blocks the strobe overlaps, shows the
  input
