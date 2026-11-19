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
steps of 3275 15-bit codes with the darker side below 26215, and red steps of 15 codes of
`(R - G - B) >> 8` of the linear channel codes wherever `R > G + B`, each the WCAG threshold less
the codes' measured error over every 8-bit colour.

#### Scenario: A fall to zero keeps its direction

- **WHEN** a pixel falls from (80, 0, 0) to black and holds, then shows (110, 60, 0), (45, 0, 0),
  (80, 0, 0) and black for one frame each
- **THEN** the limiter's trackers equal the auditor's and both count the saturated rise and fall

#### Scenario: An unsaturated reversal before a saturated change

- **WHEN** a pixel shows (110, 0, 0), then (65, 40, 0) for 1.5 s, then (110, 60, 0), (45, 0, 0)
  and (110, 60, 0)
- **THEN** the auditor counts the red fall to (45, 0, 0) and the limiter counts it too

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

### Requirement: Red transition counting

Every red step SHALL move the red tracker. It SHALL count as a red transition when the new state
or a state since the previous step is saturated red, or, when it did not count, at the first
saturated state before the next step.

#### Scenario: A saturated state after an uncounted step
- **WHEN** a red step between unsaturated states is followed, before the next step, by a saturated state
- **THEN** the step counts as a red transition at that saturated state

### Requirement: Supported frame size

The frame limiter SHALL support frames from 64 x 36 to 8192 x 8192 pixels, and hosts SHALL clamp
larger frames to 8192 on each side, because the area limit is passed as a float, exact only under
2^24.

#### Scenario: A frame larger than the supported size

- **WHEN** the reference model is asked for a 16384 x 9216 frame
- **THEN** it refuses the size

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

When the display scale (physical pixels per frame texel) changes, the host SHALL first fade the
output to black through the limiter at the old size and geometry, keeping the old view size, for
at most a bounded wait. It SHALL NOT resample or stretch the output or the trackers.

#### Scenario: A display-scale change during a strobe

- **WHEN** the device pixel ratio changes while a red/black pattern plays
- **THEN** the display shows black for longer than the coverage interval, then content rises from
  black only through the grant, with no red transition granted within one second after the
  switch

### Requirement: Display-scale switch

After the fade, the host SHALL switch to the new size with the whole output and tracker state
tracked black and `G` written fully spent, and SHALL present black, without running the limiter,
for longer than the coverage interval counted from the first black frame presented at the new size.

#### Scenario: Black after the switch
- **WHEN** the host switches to a new display scale
- **THEN** it presents black for longer than the coverage interval from the first black frame presented

### Requirement: Combined area

The frame limiter SHALL count, per window, the pixels that fire in any channel and direction now
or within the coverage interval, and SHALL put every direction over the limit when that count is
over it.

#### Scenario: Opposite-phase patches

- **WHEN** two adjacent patches inside one field toggle in opposite phases, each direction under
  the limit and both together over it
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

#### Scenario: Adjacent luma and red patches

- **WHEN** two adjacent 5 x 8 patches inside one 21 x 12 field toggle at 10 Hz, one black and gray
  and one black and (100, 0, 0), each under the limit of 63 and both together over it
- **THEN** the pixel auditor counts at most 6 large-area transitions in every 1 s window of the
  output

### Requirement: Joint channel grant

A frame asking both the luma and the red budget SHALL be admitted only when both are ready, and
when both red directions are asked the grant SHALL admit one, the other than at the last red grant.

#### Scenario: Red rising then falling at 120 Hz

- **WHEN** a frame shows black, then (100, 0, 0), then (255, 0, 0), then black forever at 120 Hz
- **THEN** the output reaches black within 8 / (2 maxFlashHz) s plus one luma refill period

### Requirement: Recent channels pay for the combined area

When some direction fires now and the frame is over the limit, the grant SHALL also ask each
channel that fires nowhere now but fired within the coverage interval, rising when it rose
within the interval and falling otherwise, so that channel's own budget pays for the combined
area.

#### Scenario: Red a frame ahead of luma

- **WHEN** red stripes and luma stripes, each under the limit and both together over it, toggle at
  5 Hz with red one frame ahead of luma
- **THEN** the pixel auditor counts at most 1 large-area red transition in every 1 s window of the
  output

### Requirement: Each threshold step is a transition

A tracker SHALL fire on a full step back from its extreme since its last transition, or on a
further full step onward from the level at its last transition, in each case with the darker side
below the dark limit; an onward step that is not dark enough moves that level without firing. The
pixel auditor SHALL count the same way. Pixels that started changing at different times can then
complete a step together, and their joint change is measured over the area.

#### Scenario: Staggered patches

- **WHEN** two adjacent patches, each under the area limit and over it together, step up a frame
  apart and then rise and fall together, repeating every 16 frames, in grey and in red
- **THEN** the pixel auditor counts at most 6 large-area luma and 1 red transition in every 1 s
  window of the output

#### Scenario: Rise, plateau, rise, fall

- **WHEN** a full frame goes from black to (110, 0, 0), holds, rises to (220, 0, 0) and returns to
  black, 2.5 times a second
- **THEN** the pixel auditor counts at most 1 large-area red transition in every 1 s window of the
  output

### Requirement: Red refills at any rate

The red budget SHALL refill by exactly an eighth of the luma refill, carrying the remainder to the
next frame, and the host SHALL carry the fraction of a refill unit to the next frame so a small
maxFlashHz refills at any frame rate. The host SHALL earn one unit under a token a token period, so
the carried fraction cannot complete a token early, and SHALL refill nothing on the first frame
after it writes the budget.

#### Scenario: A tiny maximum flash rate

- **WHEN** maxFlashHz is 0.003 and a red change spends the red budget
- **THEN** the red deficit falls on the next frame

#### Scenario: A tiny maximum flash rate at a high frame rate

- **WHEN** maxFlashHz is 0.003, frames come 480 times a second and a red change spends the red
  budget
- **THEN** the red deficit falls within 40 frames

#### Scenario: A carried fraction

- **WHEN** a full frame turns white after 1/60 s and then alternates black and white at intervals
  just under 1/6 s
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

#### Scenario: A tiny frame interval

- **WHEN** frames come every 10 µs at maxFlashHz 3 and a red change spends the red budget
- **THEN** after 0.33 s the red deficit is still above 60% of a token

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
