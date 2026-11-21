<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## MODIFIED Requirements

### Requirement: Red transition counting

Every red step SHALL move the red tracker. It SHALL count as a red transition when the new state
or a state since the previous step is saturated red, or, when it did not count, at the first
saturated state before the next step. Nothing SHALL expire during playback. The host SHALL tell
the pixel auditor of each restart (Frame change, or the first start) with the seed it wrote. At a
"black, nothing owed" restart the auditor SHALL reseed, before the restart's first frame, the luma
and red trackers of every pixel that has presented exact (0, 0, 0) for at least `RED_EXPIRE_MS`
(1250 ms) to that seed. A zero restart SHALL reseed nothing.

The black time SHALL run on the presented timeline from the first frame of the pixel's black run
to the restart, compared by the shared `blackLongEnough` threshold. Every pixel not reseeded SHALL
keep its history. For every restart, of either seed, the auditor SHALL report how many pixels
were reseeded and how many kept their history, replacing the report of the restart before. Any
other byte triple, (1, 0, 0) included, SHALL end a black run.

#### Scenario: A saturated state after an uncounted step
- **WHEN** a red step between unsaturated states is followed, before the next step, by a saturated state
- **THEN** the step counts as a red transition at that saturated state

#### Scenario: An uncounted fall forgotten at a restart after 1250 ms of black
- **WHEN** a pixel falls from (110, 64, 0) to black, shows black for 75 frames at 60 Hz, the host
  restarts at "black, nothing owed", and the pixel then shows (5, 0, 0)
- **THEN** the auditor counts no red transition at (5, 0, 0)

#### Scenario: A zero restart
- **WHEN** the same pixel shows black for 2 s, and the host restarts at zero
- **THEN** the auditor reseeds nothing and counts the fall at (5, 0, 0)

#### Scenario: The report follows the latest restart
- **WHEN** a one-pixel frame has a black restart that reseeds its pixel, and later a zero restart
- **THEN** after the zero restart's first frame the auditor reports 0 reseeded and 1 kept

#### Scenario: A restart one frame short of 1250 ms
- **WHEN** the same pixel shows black for 74 frames at 60 Hz before a "black, nothing owed" restart
- **THEN** the auditor keeps its history, reports the pixel as not reseeded, and counts the fall at
  (5, 0, 0)

#### Scenario: Nothing expires during playback
- **WHEN** a pixel falls from (110, 64, 0) to black and shows black for 2 s with no restart, then
  shows (5, 0, 0)
- **THEN** the auditor counts the fall at (5, 0, 0)

#### Scenario: A near-black red ends the black run
- **WHEN** a pixel shows black for 100 frames, then (1, 0, 0) for one frame, then black for 74
  frames, and the host restarts at "black, nothing owed"
- **THEN** the auditor keeps the pixel's history, because its black run is 74 frames long

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

### Requirement: Limiter state is never cleared

A host SHALL start the output black and the tracker state tracked black. It SHALL use the texel
"black, nothing owed" (x 0, y 32768, z 0, w 0: luma falling at 0, red at 0, red memory counted
with no saturated state since) only when `hostBlackLongEnough` holds for the exact (0, 0, 0)
black presented before the start, and zero (red memory unknown) otherwise. It SHALL tell the pixel
auditor, where one reads its output, which seed it wrote. It SHALL NOT clear the grant state `G`
or the trackers of a frame on screen, including when the viewing geometry changes.

They SHALL be replaced only by the start that follows a fade and a black (Frame change), or the
first start.

#### Scenario: A geometry change on a live display

- **WHEN** the viewing geometry changes from `wcag` to `desktop` one frame after a granted red rise
- **THEN** the trackers are kept and a red fall on the next frame is held

#### Scenario: A short black before the start

- **WHEN** a pixel falls from (110, 64, 0) to black, black is presented for 8 frames, the limiter
  starts at zero with `G` written fully spent, and after 100 frames of black the pixel shows
  (5, 0, 0) and then (255, 0, 0)
- **THEN** the pixel auditor counts at most one red transition in any one second of the output

#### Scenario: A long black before the start

- **WHEN** the same pixel shows black for 1.5 s before the limiter starts at "black, nothing owed"
- **THEN** no pixel is held at (5, 0, 0) and the pixel auditor counts at most one red transition in
  any one second of the output

#### Scenario: A red strobe after a black start

- **WHEN** a full-frame 10 Hz strobe between (255, 0, 0) and black follows a start at "black,
  nothing owed"
- **THEN** pixels are held and the pixel auditor counts at most one red transition in any one
  second of the output

### Requirement: Black before the start

After the fade, the host SHALL free the frame and present black, without running the limiter, for
longer than the coverage interval counted from the first black frame presented, and for as long
as the view shows no whole texel. The black SHALL be exact (0, 0, 0). A host that starts the
trackers at "black, nothing owed" SHALL present that black until `hostBlackLongEnough` holds,
before the first start as before every later one.

The host SHALL credit the black one presented frame at a time, each frame interval capped at
100 ms, from the first black frame. `hostBlackLongEnough(ms, longestMs)` SHALL be
`blackLongEnough(ms - longestMs)`, where `longestMs` is the longest single interval credited in
that black and `blackLongEnough` (`ms >= RED_EXPIRE_MS - 0.001`) is the threshold the pixel
auditor uses. The subtraction covers a credit that leads the display by one frame.

#### Scenario: Black after the fade

- **WHEN** the fade ends
- **THEN** the host presents black for longer than the coverage interval from the first black
  frame presented, then starts

#### Scenario: Black before a black start

- **WHEN** a host that starts the trackers at "black, nothing owed" mounts, or a fade ends
- **THEN** it presents exact black for at least 1250 ms plus its longest credited frame interval
  from the first black frame presented, then starts

#### Scenario: Black one frame short of the host threshold
- **WHEN** a host has credited 75 frame intervals of 1000/60 ms of exact black
- **THEN** `hostBlackLongEnough` is false, and the host either presents one more black frame or
  starts at zero
