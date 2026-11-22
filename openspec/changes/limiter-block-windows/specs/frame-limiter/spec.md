<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## MODIFIED Requirements

### Requirement: Per-pixel transition trackers

The frame limiter SHALL keep, for every pixel, the pixel auditor's luma and red transition
trackers on the same codes and thresholds, step them on its output, and count toward the
area limit every pixel that fires now or fired within the coverage interval. A direction SHALL be
over when a window of whole sub-blocks that contains the field wherever it is placed holds more
than a quarter of the field's pixels, or, when the host passes no sub-block window, a window of
whole cells that does.

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
  starting from the same tracker state, and at every host restart that seeds "black, nothing
  owed" after 1250 ms of presented exact black the auditor is told of the restart
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

#### Scenario: Saturated red after a black start

- **WHEN** the limiter starts at "black, nothing owed" after 76 frames of black, and a full frame
  then shows 100 frames each of black, (60, 0, 0), black and (110, 64, 0), then (90, 0, 0) for one
  frame, then black
- **THEN** the pixel auditor, told of the restart, counts at most 1 large-area red transition in
  every 1 s window of the output

#### Scenario: A faint red after a black start

- **WHEN** the limiter starts at "black, nothing owed" after 100 frames of black, and a full frame
  then shows (5, 0, 0), (110, 64, 0) and (60, 0, 0) for 100 frames each
- **THEN** the pixel auditor, told of the restart, counts at most 1 large-area red transition in
  every 1 s window of the output

#### Scenario: An unchanged frame makes no transition

- **WHEN** red pixels fall in one area, the next frame raises an adjacent area and a far area, and
  the frame after that is unchanged
- **THEN** the pixel auditor records no transition on the unchanged frame

#### Scenario: Motion over less than a quarter of the field

- **WHEN** at 480 x 270, with the host passing a sub-block window, the pixels that fire now or
  fired within the coverage interval cover at most 20 % of the field's pixels in every window of
  whole sub-blocks that contains the field, each pixel firing at most twice a second
- **THEN** no direction is over and no pixel is held
