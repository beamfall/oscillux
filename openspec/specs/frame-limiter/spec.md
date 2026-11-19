# frame-limiter Specification

## Purpose
The frame flash limiter's rules for counting and limiting large-area flashes and saturated-red
transitions in the model and its GPU passes, which conformance vectors under
`conformance/limiter/frame/` pin.

## Requirements

### Requirement: Feathered holds

The frame limiter's output SHALL show the previous output frame on every pixel of a held
sub-block and SHALL blend toward it around held sub-blocks with a weight that is continuous in
space, reaching 0 a little past four sub-blocks away. The output SHALL NOT step across a
sub-block boundary where neither the input nor the previous output steps. A pixel whose input,
previous output or blend is red-dominant (`r > g + b` in 8-bit) SHALL show the input.

#### Scenario: A held sub-block has no hard edge

- **WHEN** a sub-block is held while its neighbours are not, and the input differs from the
  previous output
- **THEN** every pixel of the held sub-block shows the previous output, the pixels within five
  sub-blocks of it show a value between the input and the previous output, and pixels further
  from it show the input

#### Scenario: Held regions blend smoothly in space

- **WHEN** a smooth luminance wave travels fast enough that parts of the frame are held
- **THEN** the largest step across any sub-block boundary side in the output exceeds the input's
  step there by no more than 12 of 255 levels

#### Scenario: Red pixels are not blended

- **WHEN** a pixel beside a held sub-block is red-dominant in the input or in the previous output
- **THEN** it shows the input
- **THEN** the pixel auditor counts 0 large-area red transitions in every 1 s window of the output

#### Scenario: Luminance unchanged

- **WHEN** a luminance-only signal runs through the limiter
- **THEN** its output is byte-identical to the output with the previous red step

### Requirement: Rationed red transitions

The frame limiter SHALL admit a large-area saturated-red transition, in either direction, only
when its red token is full, and SHALL then empty it; the token SHALL refill at one eighth of the
luma token's rate, so that no 1 s window holds more than one large-area red transition (no red
flash).

#### Scenario: Red strobe

- **WHEN** a full-frame saturated-red and black square wave at 3 Hz or 10 Hz runs for 5 s
- **THEN** the pixel auditor counts at most 1 large-area red transition in every 1 s window of the
  output

### Requirement: Red token refill

The red token SHALL be full again by the first frame at which the intervals of the
frames after the last spend, each counted up to 1 / (2 x maxFlashHz) s, add up to
(65025 / 65024) x 8 / (2 x maxFlashHz) s; after a host write of `G` the first of them counts
nothing.

#### Scenario: Refill after a host write

- **WHEN** the host writes `G` after a red spend
- **THEN** the first frame interval after the write adds nothing to the refill

### Requirement: Held red admission

A held red change SHALL be admitted on the frame its red token is full again, or, when the
frame asks luma too, on
the first frame from it at which the luma token is ready as well: at most
(65025 / 65024) x 3 / (2 x maxFlashHz) s, counted the same way, after the last luma grant. The
red bound is per grant.

#### Scenario: Red change in both directions

- **WHEN** a held change needs red grants in both directions
- **THEN** its second direction is admitted within the same bound after the first

#### Scenario: Lasting red change

- **WHEN** a full-frame saturated red changes to cyan and stays cyan, at a steady 60 frames a
  second
- **THEN** the output shows the cyan input within 1.5 s

#### Scenario: A mixed cadence

- **WHEN** a full-frame red rise spends the red token and black follows at intervals alternating
  250 ms and 10 ms at 3 Hz
- **THEN** the fall is admitted by the frame the capped intervals reach the bound, later than nine
  frames

### Requirement: Fine reversing patterns

The frame limiter SHALL limit reversing patterns finer than a sub-block, and changes over part
of each sub-block, as the pixel auditor counts them (per-pixel trackers: the
`limiter-pixel-trackers` change).

#### Scenario: Fine checkerboard

- **WHEN** a full-frame checkerboard of 4 px squares inverts between white and black at 10 Hz
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

#### Scenario: A change over part of each sub-block

- **WHEN** the top 2 of every 5 rows toggle between grey 124 and 153 at 10 Hz, so no sub-block's
  mean moves by a luma step
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

#### Scenario: Reference visuals

- **WHEN** the reference visuals render through the limiter under loud audio
- **THEN** none makes more than 6 large-area luma transitions in any 1 s window of the output

### Requirement: A paired luma grant spends two tokens

When luma up and luma down are both over the area limit and requested in one frame, the grant
SHALL admit them together only when the luma token has also stood unspent for one refill period,
and SHALL then leave two tokens of deficit, so no 1 s window holds more transitions than singles
allow.

#### Scenario: A full-frame flash before a fine pattern

- **WHEN** the frame steps from black to white and then a full-frame checkerboard of 4 px squares
  inverts at 10 Hz
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

#### Scenario: Full-frame flashes after a fine pattern

- **WHEN** a fine checkerboard inverts once after a quiet second and the frame then alternates
  full-frame black and white every 11 frames at 60 Hz
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

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
spent, pass an area limit of 0 and feed the limiter black, until a frame of the fade has shown
black at every pixel. Until the start the view of the frame SHALL only shrink.

#### Scenario: A fall in a view that shrank

- **WHEN** a view clipped to one texel column of a red frame shrinks
- **THEN** the area limit is 0, and the column's fall to black waits for the red grant

#### Scenario: A view that shrinks and grows during the fade

- **WHEN** the view shrinks by a pixel column and grows back before the fade ends
- **THEN** the column stays hidden until the start, where it comes back black

### Requirement: The fade ends when the frame is black

A host that reads the grant word SHALL end the fade once it has read, from one of the fade's
frames, a word that holds no direction: at the frame after that one at the soonest, and later if
it reads the word without waiting on the GPU.

#### Scenario: A dark frame fades in one frame

- **WHEN** the fade starts on a frame whose trackers hold nothing a luma or red step above black
  (no extreme when rising, no reference when falling)
- **THEN** the fade's first frame shows black with no direction held, and the fade can end at
  the next frame

#### Scenario: A dark frame that holds an earlier peak

- **WHEN** the fade starts on a frame with no pixel a luma step above black, whose luma trackers
  are rising with a peak a step above black
- **THEN** the fall to black is a transition from that peak, and the frame is held until it is
  granted

#### Scenario: A lit frame waits for its grant

- **WHEN** the fade starts on a frame with luma to drop and no saturated red
- **THEN** the frame is held until the two luma tokens are back, the fall is granted on one
  frame, and the fade ends at the next or once the host has read that frame's word

### Requirement: A fade with no clear word read ends at a cap

Without a read of a word that holds no direction (the host does not read the word, the word
never clears, or a word that cleared sits behind a read that has not finished) a host SHALL NOT
end the fade before it has run for longer than the red token's refill, 8 / (2 · maxFlashHz)
seconds, by more than two frames, in the time the limiter is credited with. It SHALL end the
fade at a cap it sets no sooner than that (the Beamfall web host: 2 s at the default 3 Hz).

#### Scenario: A fade timed to the red refill

- **WHEN** a host that does not read the grant word fades a red frame, drawing a frame each
  refill period, 1 / (2 · maxFlashHz) seconds
- **THEN** the first frame after the write refills nothing, the next eight earn 65,024 of the red
  token's 65,025 units, and the tenth grants the fall: the fade runs for more than two frames
  past the eight periods

#### Scenario: A cleared word that is never read

- **WHEN** a host that reads the grant word without waiting on the GPU fades a frame whose word
  clears, and no read of it finishes
- **THEN** the fade ends at the host's cap, as for a word that never clears

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
