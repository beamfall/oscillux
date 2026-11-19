<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## REMOVED Requirements

### Requirement: Partial-coverage red

**Reason**: Red is tracked per pixel at the auditor's step, so red covering part of a sub-block
counts by its pixels instead of a diluted block mean.

**Migration**: Hosts bind the `uTrack` state texture; see "Per-pixel transition trackers".

## ADDED Requirements

### Requirement: Per-pixel transition trackers

The frame limiter SHALL keep, for every pixel, the pixel auditor's luma and red transition
trackers on the same codes and thresholds, step them on its output, and count toward the
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

### Requirement: Flash measure

The frame limiter and the pixel auditor SHALL measure flashes in the same integer codes: luma
steps of 3276 15-bit codes with the darker side below 26215, and red steps of 16 codes of
`(R - G - B) >> 8` of the linear channel codes wherever `R > G + B`, where a red step counts only
when the new state, or a state since the pixel's red tracker last fired, is saturated red.

#### Scenario: A strobe one code over the luma step

- **WHEN** a full-frame 10 Hz strobe changes luma by 6553 of 65535
- **THEN** the pixel auditor counts at least 18 luma transitions a second in the input and at most
  6 in the output

#### Scenario: A strobe between saturated and unsaturated red

- **WHEN** a full-frame 10 Hz strobe alternates between (48, 0, 0) and (155, 0, 90)
- **THEN** the pixel auditor counts at least 18 red transitions a second in the input and at most
  1 in the output

#### Scenario: A change between two oranges

- **WHEN** a full-frame 3 Hz strobe alternates between (255, 160, 0) and (180, 110, 0)
- **THEN** the pixel auditor counts no red transitions in the input or the output

### Requirement: Supported frame size

The frame limiter SHALL support frames from 64 x 36 to 8192 x 8192 pixels, and hosts SHALL clamp
larger frames to 8192 on each side, because a sub-block's per-direction pixel counts are 16-bit.

#### Scenario: A frame larger than the supported size

- **WHEN** the reference model is asked for a 16384 x 9216 frame
- **THEN** it refuses the size instead of wrapping a sub-block's count to zero

### Requirement: Limiter state is never cleared

A host SHALL start the output black and the tracker state tracked black (zero), and SHALL NOT
clear the grant state `G` or the trackers after the start, including when the viewing geometry
changes.

#### Scenario: A geometry change on a live display

- **WHEN** the viewing geometry changes from `wcag` to `desktop` one frame after a granted red rise
- **THEN** the trackers are kept and a red fall on the next frame is held

### Requirement: Resize at one display scale

At an unchanged display scale a resize SHALL copy the output and tracker state 1:1 from the view's
anchor, start the newly exposed area tracked black, and write `G` fully spent.

#### Scenario: A strobe in an area that a resize exposes

- **WHEN** a left-anchored view alternates between 64 and 128 pixels wide at one display scale and
  its right half is drawn red whenever it is exposed
- **THEN** the exposed area starts tracked black, its red rise is held until the budget refills,
  and no more than one red transition a second is admitted

### Requirement: Display-scale change

When the display scale (physical pixels per frame texel) changes, the host SHALL switch to the new
size at once with the whole output and tracker state tracked black and `G` written fully spent,
and SHALL present black, without running the limiter, for longer than the coverage interval. It
SHALL NOT resample or stretch the output or the trackers.

#### Scenario: A display-scale change during a strobe

- **WHEN** the device pixel ratio changes while a red/black pattern plays
- **THEN** the display shows black for longer than the coverage interval, then content rises from
  black only through the grant, with no red transition granted within one second after the
  switch

### Requirement: Combined area

The frame limiter SHALL put both directions of a channel over the limit when a window holds more
than the limit of pixels that fire in either direction of that channel now or within the coverage
interval.

#### Scenario: Opposite-phase patches

- **WHEN** two adjacent patches inside one field toggle in opposite phases, each direction under
  the limit and both together over it
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

### Requirement: Geometry change spends the budget

When the viewing geometry changes, the host SHALL keep the trackers and write `G` fully spent.

#### Scenario: A geometry change that shrinks the window

- **WHEN** a red fall passes under the `wcag` limit and the geometry changes to `desktop` a frame
  later, putting the still-recent fall over the new limit
- **THEN** the red budget is spent and a red rise of the same pixels on the next frame is held

### Requirement: Per-pixel holds

The frame limiter SHALL show the previous output at exactly the pixels whose trackers would fire
on the input in a direction the grant did not admit, and the input at every other pixel.

#### Scenario: A held strobe beside a drifting background

- **WHEN** a 10 Hz white strobe over half the TV field is held while the background beside it
  drifts
- **THEN** every background pixel, including those in sub-blocks the strobe overlaps, shows the
  input
