<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## REMOVED Requirements

### Requirement: Partial-coverage red

**Reason**: Red is tracked per pixel at the auditor's step, so red covering part of a sub-block
counts by its pixels instead of a diluted block mean.

**Migration**: Hosts bind the `uTrack` state texture; see "Per-pixel transition trackers".

## MODIFIED Requirements

### Requirement: Rationed red transitions

The frame limiter SHALL admit a large-area saturated-red transition, in either direction, only
when its red token is full, and SHALL then empty it; the token SHALL refill at one eighth of the
luma token's rate, so that no 1 s window holds more than one large-area red transition (no red
flash). The red token SHALL be full again by the first frame at which the intervals of the
frames after the last spend, each counted up to 1 / (2 x maxFlashHz) s, add up to
(65025 / 65024) x 8 / (2 x maxFlashHz) s; after a host write of `G` the first of them counts
nothing. A held red change SHALL be admitted on that frame, or, when the frame asks luma too, on
the first frame from it at which the luma token is ready as well: at most
(65025 / 65024) x 3 / (2 x maxFlashHz) s, counted the same way, after the last luma grant. The
red bound is per grant: a held change that needs red grants in both directions has its
second direction admitted within the same bound after the first.

#### Scenario: Red strobe

- **WHEN** a full-frame saturated-red and black square wave at 3 Hz or 10 Hz runs for 5 s
- **THEN** the pixel auditor counts at most 1 large-area red transition in every 1 s window of the
  output

#### Scenario: Lasting red change

- **WHEN** a full-frame saturated red changes to cyan and stays cyan, at a steady 60 frames a
  second
- **THEN** the output shows the cyan input within 1.5 s

#### Scenario: A mixed cadence

- **WHEN** a full-frame red rise spends the red token and black follows at intervals alternating
  250 ms and 10 ms at 3 Hz
- **THEN** the fall is admitted by the frame the capped intervals reach the bound, later than nine
  frames

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

- **WHEN** any sequence of frames runs through the limiter and the auditor reads its output, both
  starting from the same tracker state
- **THEN** every pixel's tracker makes the auditor's transition decisions for that pixel, on every
  frame, although a compressed tracker may decode to a different reference

#### Scenario: A host reset is conservative

- **WHEN** the host zeroes the trackers over a presented black frame, whose red memory is then
  unknown
- **THEN** the limiter may count red transitions the auditor, which saw the frames before, does
  not, and never fewer

#### Scenario: A fall below 0.8 after a bright start

- **WHEN** a full frame starts at grey 255 and shows 240, 255 and 229
- **THEN** the trackers count the fall from 255 to 229 as a large-area luma transition

#### Scenario: A reset keeps saturated-red memory

- **WHEN** a full frame shows (60, 0, 0), falls to black, the host starts a frame again with
  every pixel tracked black and then shows (110, 64, 0) and (60, 0, 0)
- **THEN** the pixel auditor counts at most 1 large-area red transition in every 1 s window of the
  output

#### Scenario: A red change after a reset counts when it saturates

- **WHEN** the tracker texture is reset to zero over black, a full frame shows (110, 64, 0) for
  100 frames at 60 Hz, then (90, 0, 0) for one frame, then black
- **THEN** the pixel auditor counts at most 1 large-area red transition in every 1 s window of the
  output

#### Scenario: An unchanged frame makes no transition

- **WHEN** red pixels fall in one area, the next frame raises an adjacent area and a far area, and
  the frame after that is unchanged
- **THEN** the pixel auditor records no transition on the unchanged frame

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
clear the grant state `G` or the trackers of a frame on screen, including when the viewing
geometry changes. They SHALL be replaced only by the start that follows a fade and a black
(Frame change).

#### Scenario: A geometry change on a live display

- **WHEN** the viewing geometry changes from `wcag` to `desktop` one frame after a granted red rise
- **THEN** the trackers are kept and a red fall on the next frame is held

### Requirement: Frame change

When the frame size, the display scale (physical pixels per frame texel) or the texels in view
change, the host SHALL take one path: fade the frame on screen to black through the limiter,
present black, then start a frame at the size, scale and view asked for then, tracked black with
`G` written fully spent. It SHALL NOT copy, resample or stretch the output or the trackers from
one frame to the next, a drop to a divisor of the scale included.

#### Scenario: A resize during a strobe

- **WHEN** a view is resized at one display scale while a red/black pattern plays
- **THEN** the display falls to black through the grant and shows black for longer than the
  coverage interval, then content rises from black only through the grant, with no red transition
  granted within one second after the start

#### Scenario: A display-scale change during a strobe

- **WHEN** the device pixel ratio changes while a red/black pattern plays
- **THEN** the display falls to black through the grant at the old scale and shows black for
  longer than the coverage interval, then content rises from black only through the grant, with
  no red transition granted within one second after the start

#### Scenario: A drop to a divisor of the scale

- **WHEN** the display scale drops from 2 to 1 while red is shown
- **THEN** the host fades, presents black and starts at the new scale like any other change, and
  no texel is copied

### Requirement: Fade through the limiter

For the fade the host SHALL keep the frame's size, scale, place and trackers, write `G` fully
spent, pass an area limit of 0 and feed the limiter black, for longer than the red token's refill
in the time the limiter is credited with. Until the start the view of the frame SHALL only
shrink.

#### Scenario: A fall in a view that shrank

- **WHEN** a view clipped to one texel column of a red frame shrinks
- **THEN** the area limit is 0, and the column's fall to black waits for the red grant

#### Scenario: A view that shrinks and grows during the fade

- **WHEN** the view shrinks by a pixel column and grows back before the fade ends
- **THEN** the column stays hidden until the start, where it comes back black

### Requirement: A change during the fade moves the target

A change during the fade or the black SHALL change only the size, scale and view the next frame
starts at. The host SHALL NOT reallocate, write `G` or restart the fade or the black for it.

#### Scenario: A view dragged to a new size

- **WHEN** the view's size changes on every frame of a fade
- **THEN** there is one fade and one start, at the last size asked for

### Requirement: Black before the start

After the fade, the host SHALL free the frame and present black, without running the limiter, for
longer than the coverage interval counted from the first black frame presented, and for as long
as the view shows no whole texel.

#### Scenario: Black after the fade

- **WHEN** the fade ends
- **THEN** the host presents black for longer than the coverage interval from the first black
  frame presented, then starts

### Requirement: Whole texels in view

A frame SHALL present only the whole texels its view shows when it starts, on black, and the host
SHALL take the area limit from those texels. A texel the view cuts SHALL NOT be presented.

#### Scenario: A view that cuts a texel

- **WHEN** a frame starts at two physical pixels per texel in a view 3 pixels wide
- **THEN** one texel column is presented and the third pixel column shows black

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
below the dark limit. An onward rise not below the dark limit moves that level without firing; a
fall that ends at or above it keeps its high side. The pixel auditor SHALL count the same way.

#### Scenario: Staggered patches

- **WHEN** two adjacent patches, each under the area limit and over it together, step up a frame
  apart and then rise and fall together, repeating every 16 frames, in grey and in red
- **THEN** the pixel auditor counts at most 6 large-area luma and 1 red transition in every 1 s
  window of the output

#### Scenario: A dip short of a step, then a step up

- **WHEN** a full frame rises from black to (138, 0, 0), holds, then shows (127, 0, 0), (146, 0, 0)
  and (127, 0, 0) on consecutive frames
- **THEN** the pixel auditor counts at least 2 large-area red transitions in the input and at most
  1 in every 1 s window of the output

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

#### Scenario: The first frame

- **WHEN** the host starts, with `G` written fully spent or cleared to zero
- **THEN** the first frame refills nothing, as after any other write of `G`

#### Scenario: A tiny maximum flash rate

- **WHEN** maxFlashHz is 0.003, frames come 60 times a second and a red change spends the red
  budget
- **THEN** the red deficit falls within two frames, once the carried fraction earns a red unit

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

#### Scenario: A paused host settles

- **WHEN** a granted full-frame luma rise holds no pixel
- **THEN** the grant's held bits (`G.x` bits 4 to 7) are clear, although only the luma-up
  admission bit is set
