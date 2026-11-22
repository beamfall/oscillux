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

### Requirement: Flash measure

The frame limiter and the pixel auditor SHALL measure flashes in the same integer codes:

- luma steps of 3275 15-bit codes, with the darker side below 26215;
- red steps of 15 codes of `(R - G - B) >> 8` of the linear channel codes, wherever `R > G + B`;
- red chromaticity codes (Red chromaticity codes).

Each step is the WCAG threshold less the codes' measured error over every 8-bit colour.

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

#### Scenario: A dim red and green strobe

- **WHEN** a full-frame 10 Hz strobe alternates between (60, 0, 0) and (0, 60, 0)
- **THEN** the pixel auditor counts at least 18 red transitions a second in the input and at most
  1 in the output

#### Scenario: A red and blue strobe

- **WHEN** a full-frame 10 Hz strobe alternates between (255, 0, 0) and (0, 0, 255)
- **THEN** the pixel auditor counts at least 18 red transitions a second in the input and at most
  1 in the output

#### Scenario: A dim red on black

- **WHEN** a full-frame 10 Hz strobe alternates between (60, 0, 0) and black
- **THEN** the pixel auditor counts no red transitions in the input or the output

### Requirement: Red transition counting

Every red step SHALL move the red tracker. It SHALL count as a red transition when the new state or
a state since the previous step is saturated red, or, when it did not count, at the first saturated
state before the next step. Nothing SHALL expire during playback.

#### Scenario: A saturated state after an uncounted step
- **WHEN** a red step between unsaturated states is followed, before the next step, by a saturated state
- **THEN** the step counts as a red transition at that saturated state

#### Scenario: Nothing expires during playback
- **WHEN** a pixel falls from (110, 64, 0) to black and shows black for 2 s with no restart, then
  shows (5, 0, 0)
- **THEN** the auditor counts the fall at (5, 0, 0)

### Requirement: Auditor reseeding at a restart

The host SHALL tell the pixel auditor of each restart (Frame change, or the first start) with the
seed it wrote. At a "black, nothing owed" restart the auditor SHALL reseed, before the restart's
first frame, the luma and red trackers of every pixel that has presented exact (0, 0, 0) for at
least `RED_EXPIRE_MS` (1250 ms) to that seed. A zero restart SHALL reseed nothing. Every pixel not
reseeded SHALL keep its history.

#### Scenario: An uncounted fall forgotten at a restart after 1250 ms of black
- **WHEN** a pixel falls from (110, 64, 0) to black, shows black for 75 frames at 60 Hz, the host
  restarts at "black, nothing owed", and the pixel then shows (5, 0, 0)
- **THEN** the auditor counts no red transition at (5, 0, 0)

#### Scenario: A zero restart
- **WHEN** the same pixel shows black for 2 s, and the host restarts at zero
- **THEN** the auditor reseeds nothing and counts the fall at (5, 0, 0)

#### Scenario: A restart one frame short of 1250 ms
- **WHEN** the same pixel shows black for 74 frames at 60 Hz before a "black, nothing owed" restart
- **THEN** the auditor keeps its history, reports the pixel as not reseeded, and counts the fall at
  (5, 0, 0)

### Requirement: Auditor black runs and the restart report

The black time SHALL run on the presented timeline from the first frame of the pixel's black run to
the restart, compared by the shared `blackLongEnough` threshold. Any other byte triple, (1, 0, 0)
included, SHALL end a black run. For every restart, of either seed, the auditor SHALL report how
many pixels were reseeded and how many kept their history, replacing the report of the restart
before.

#### Scenario: The report follows the latest restart
- **WHEN** a one-pixel frame has a black restart that reseeds its pixel, and later a zero restart
- **THEN** after the zero restart's first frame the auditor reports 0 reseeded and 1 kept

#### Scenario: A near-black red ends the black run
- **WHEN** a pixel shows black for 100 frames, then (1, 0, 0) for one frame, then black for 74
  frames, and the host restarts at "black, nothing owed"
- **THEN** the auditor keeps the pixel's history, because its black run is 74 frames long

### Requirement: Supported frame size

The frame limiter SHALL support frames from 64 x 36 to 8192 x 8192 pixels, and hosts SHALL clamp
larger frames to 8192 on each side, because the area limit is passed as a float, exact only under
2^24.

#### Scenario: A frame larger than the supported size

- **WHEN** the reference model is asked for a 16384 x 9216 frame
- **THEN** it refuses the size

### Requirement: Limiter state is never cleared

A host SHALL NOT clear the grant state `G` or the trackers of a frame on screen, including when the
viewing geometry changes. They SHALL be replaced only by the start that follows a fade and a black
(Frame change), or the first start.

#### Scenario: A geometry change on a live display

- **WHEN** the viewing geometry changes from `wcag` to `desktop` one frame after a granted red rise
- **THEN** the trackers are kept and a red fall on the next frame is held

### Requirement: Tracker seed at a start

A host SHALL start the output black and the tracker state tracked black. It SHALL use the texel
"black, nothing owed" (x 0, y 32768, z 2147508224, w 0) only when `hostBlackLongEnough` holds for the
exact (0, 0, 0) black presented before the start, and zero (red memory and chromaticity unknown)
otherwise. It SHALL tell the pixel auditor, where one reads its output, which seed it wrote.

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

#### Scenario: A constant dark red after a zero start

- **WHEN** the limiter starts at zero with `G` written fully spent and a full frame shows
  (1, 0, 0)
- **THEN** every pixel shows (1, 0, 0) from the first red grant on

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
as the view shows no whole texel. The black SHALL be exact (0, 0, 0). A host that starts the
trackers at "black, nothing owed" SHALL present that black until `hostBlackLongEnough` holds,
before the first start as before every later one.

#### Scenario: Black after the fade

- **WHEN** the fade ends
- **THEN** the host presents black for longer than the coverage interval from the first black
  frame presented, then starts

### Requirement: Black credit before a black start

The host SHALL credit the black one presented frame at a time, each frame interval capped at
100 ms, from the first black frame. `hostBlackLongEnough(ms, longestMs)` SHALL be
`blackLongEnough(ms - longestMs)`, where `longestMs` is the longest single interval credited in
that black and `blackLongEnough` (`ms >= RED_EXPIRE_MS - 0.001`) is the threshold the pixel
auditor uses. The subtraction covers a credit that leads the display by one frame.

#### Scenario: Black before a black start

- **WHEN** a host that starts the trackers at "black, nothing owed" mounts, or a fade ends
- **THEN** it credits exact black until `hostBlackLongEnough` holds, 76 intervals of 1000/60 ms at
  60 Hz, then starts, and the black displayed before the start, which the credit may lead by one
  frame, is at least 1250 ms, 75 frames at 60 Hz, so the auditor reseeds every pixel

#### Scenario: Black one frame short of the host threshold
- **WHEN** a host has credited 75 frame intervals of 1000/60 ms of exact black
- **THEN** `hostBlackLongEnough` is false, and the host either presents one more black frame or
  starts at zero

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

The frame limiter SHALL show the input at every pixel whose trackers would not fire on it in a
direction the grant did not admit. Every other pixel is held. At a held pixel the limiter SHALL
show a colour on which the pixel's trackers fire only in directions that the input fires and the
grant admitted, and SHALL step the trackers on that colour.

#### Scenario: Choosing the output colour for a held pixel

- **WHEN** the frame limiter holds a pixel
- **THEN** it SHALL choose the first of these that qualifies, in 8-bit display codes:

  1. the input with its luma code moved into the band the pixel's luma tracker allows. Below the
     floor: the input mixed with the least of the previous output that reaches the floor. Above
     the ceiling: the previous output mixed toward the input as far as a limit allows, then
     mixed 32/256 of the way toward the input scaled toward black to the limit, or that scaled
     input alone when the mix is above the limit. With L the luma code of the previous output,
     V that of the input and C the ceiling, the limit is C when L is not below C, else
     C - (((C - L) * floor(min(256, floor(768 * L / C)) * (V - C) / V)) >> 8);
  2. the mix of colour 1 and the grey of its luma that is nearest colour 1;
  3. the mix of the input and the previous output that is nearest the input.

  A mix has 256 steps between its two colours, each rounded to display codes, so the steps that
  qualify need not be contiguous. The limiter SHALL search each mix above from the input's end
  without assuming they are: the 16 steps nearest the input in order, then every 16th step, then
  the 15 steps between the first of those that qualifies and the step tested before it, again from
  the input's end. It SHALL take the first step that qualifies, and the mix's other end when none
  does.

  The band's floor is 0 when a fall is allowed, else the lower of the dark threshold and one code
  more than a step below the tracker's high. Its ceiling is the top code when a rise is allowed or
  the tracker's low is at or above the dark threshold, else one code less than a step above the
  tracker's low.

#### Scenario: A held strobe beside a drifting background

- **WHEN** a 10 Hz white strobe over half the TV field is held while the background beside it
  drifts
- **THEN** every background pixel, including those in sub-blocks the strobe overlaps, shows the
  input

#### Scenario: A paused host settles

- **WHEN** a granted full-frame luma rise holds no pixel
- **THEN** the grant's held bits (`G.x` bits 4 to 7) are clear, although only the luma-up
  admission bit is set

#### Scenario: A denied rise shows the input dimmed

- **WHEN** a bright bar moves onto black pixels on a frame whose rise is not admitted
- **THEN** each of those pixels shows the bar's colour dimmed, with a luma code above black and
  less than a step above it, and not the black of the previous output

#### Scenario: A denied rise over a lit background keeps the background's hue

- **WHEN** a near-white line moves onto pixels showing a dim saturated colour on a frame whose
  rise is not admitted
- **THEN** each of those pixels shows a luma code less than a step above its tracker's low, with
  more than half the difference between its greatest and least channel that it showed

#### Scenario: A bright line over a lit background leaves little trace

- **WHEN** a near-white line moves onto pixels showing a colour whose luma code is over a third
  of their ceiling on a frame whose rise is not admitted
- **THEN** each of those pixels shows a luma code nearer the one it showed than its ceiling

#### Scenario: A denied fall stays a step below its peak

- **WHEN** a bright area turns black on a frame whose fall is not admitted
- **THEN** each of its pixels shows the colour it showed dimmed to less than a step below the luma
  it had, and the pixel auditor counts no transition there

#### Scenario: A mix that qualifies is found past ones that do not

- **WHEN** a frame of (240, 123, 247) turns (31, 167, 125) and the fall is not admitted, a frame
  of (23, 189, 209) turns (12, 250, 58) and the rise is not admitted, or a frame of
  (154, 194, 79) turns (251, 130, 9) and the red rise is not admitted
- **THEN** the pixels show (32, 167, 125), one step of the previous output; (10, 214, 50), the
  scaled input, the furthest mix under the limit being step 90 past three steps over it; and
  (247, 132, 16), the safe mix from the grey 12 steps from colour 1

#### Scenario: Nothing fires outside the grant

- **WHEN** any input runs through the limiter
- **THEN** on every frame each pixel's trackers fire on the output only in directions they fire
  on the input and the grant admitted

### Requirement: Red chromaticity codes

The limiter and the auditor SHALL give every non-black 8-bit colour an integer CIE 1976 u'v' code
in 2^-14 units, within 2.5e-4 of its u'v' under the IEC 61966-2-1 matrix and under the matrix
from the sRGB primaries. A colour SHALL be saturated red when its linear R / (R + G + B) is at
least 0.8, and never below 0.8 - 1e-12. A possible step SHALL be a squared code distance over
10683798 and a definite step one over 10791225.

#### Scenario: Every 8-bit colour

- **WHEN** the check runs over every 8-bit colour
- **THEN** every code is within 2.5e-4 of both matrices' u'v', every intermediate fits an
  unsigned 32-bit integer, and every colour with float64 R / (R + G + B) >= 0.8 is saturated

#### Scenario: Far and very far

- **WHEN** the check runs over every distinct code against the hull of the saturated codes
- **THEN** every code more than a possible step from some saturated code is far, and every
  very-far code is more than a definite step from every saturated code

### Requirement: Red chromaticity transitions

Every pixel SHALL keep a box of the saturated codes since its last definite red fall and one of the
far codes since its last definite rise. A changed colour SHALL count down when the saturated box may
hold a code over a possible step away, and a changed saturated one up when the far box may. A fire
SHALL clear a box only if definite from codes it owes, else clip it to cells within 3285 codes of
the colour per axis. Black SHALL change nothing. A fire SHALL set the pixel's red direction.

#### Scenario: Black keeps the boxes

- **WHEN** a pixel shows (255, 0, 0), then black for 1.5 s with no restart, then (0, 255, 0)
- **THEN** the pixel auditor counts a red fall at black and another at (0, 255, 0)

#### Scenario: Staggered intermediate states

- **WHEN** two 16-column stripes show (60, 0, 18), then (35, 0, 32) from frames 1 and 7, then
  (0, 0, 60) together at frame 8, every 24 frames
- **THEN** neither stripe alone is held, both ask red down at frame 8 and not at frames 1 or 7, and
  the pixel auditor counts at most 1 red transition a second in the output

#### Scenario: A saturated intermediate extreme

- **WHEN** two patches show (60, 0, 0), then (60, 25, 0) from frames 1 and 16, then (60, 50, 0)
  together at frame 17
- **THEN** both ask red down at frame 17 and not at frames 1 or 16, and the pixel auditor counts at
  most 1 red transition a second in the output

#### Scenario: An early-band intermediate

- **WHEN** the same patches show (61, 42, 0), 0.19957 from (60, 0, 0), in place of (60, 25, 0)
- **THEN** both still ask red down at frame 17

#### Scenario: A real red flash

- **WHEN** the left half of the frame alternates between (180, 0, 0) and (90, 90, 90) at 5 Hz
- **THEN** the pixel auditor counts at least 9 red transitions a second in the input and at most 1
  in the output

#### Scenario: Two patches after fires that crossed nothing

- **WHEN** two adjacent 8 x 5 patches at 240 Hz repeat a 58-frame cycle in which each fires once
  without a transition, then rises to saturated red and falls more than 0.2 away together
- **THEN** both patches together make at most one red flash a second, by a float u'v' reference

#### Scenario: A saturated and near-saturated alternation

- **WHEN** a pixel alternates between two colours 0.094 apart in u'v', one saturated and one far
- **THEN** it is never held

#### Scenario: A rise by one rule and a fall by the other

- **WHEN** a full-frame 10 Hz strobe alternates between (5, 0, 0) and (255, 0, 230)
- **THEN** the pixel auditor counts at least 18 red transitions a second in the input and at most
  1 in the output

### Requirement: Red chromaticity at a start

A pixel's first value with no state SHALL set known boxes and count nothing. "Black, nothing owed"
SHALL leave both boxes known and empty, and zero both unknown. An unknown saturated box SHALL count
down at every changed far colour, and an unknown far box up at every changed saturated colour,
until a definite step makes it known. The auditor SHALL take a zero restart's unknown boxes (before
its first frame, the zero texel's whole state) and count one large-area red transition a frame at most.

#### Scenario: A blue after a black start

- **WHEN** a pixel shows (255, 0, 0), then black for 75 frames at 60 Hz, the host restarts at
  "black, nothing owed", and the pixel shows (0, 0, 255)
- **THEN** neither the limiter nor the pixel auditor counts a red transition at (0, 0, 255)

#### Scenario: A blue after a zero start

- **WHEN** a pixel shows (255, 0, 0), then black for 8 frames, the host restarts at zero, and the
  pixel shows (0, 0, 255)
- **THEN** the limiter counts a red fall at (0, 0, 255), and so does the pixel auditor, which saw
  the red

#### Scenario: Mixed history before a zero start

- **WHEN** the left half shows orange and the right half blue, then black, the host restarts at
  zero, and the frame shows (1, 0, 0)
- **THEN** the pixel auditor counts at most 1 red transition a second in the output

#### Scenario: An alternation after a zero restart

- **WHEN** a pixel shows (42, 12, 36), black, a zero restart, (57, 42, 12), (48, 0, 3),
  (57, 21, 3), then (27, 0, 21) and (48, 0, 3) alternating every 3 frames at 60 Hz
- **THEN** the pixel auditor counts at most 1 red transition a second in the output

### Requirement: Tracker texel format

A host SHALL allocate both tracker textures RGBA32UI, seed and clear them with 32-bit values, check
at start that a texel of each, cleared with bit 31 set in every word, reads back unchanged and
present black if not, and bind `uHist` to the rows pass. Every texel a leg writes SHALL set bit 31
of z. A texel without it that is neither all zero nor exactly `UNTRACKED` SHALL count every
direction at a changed colour.

#### Scenario: A host keeps its trackers across frames

- **WHEN** a pixel shows (60, 0, 18), then (35, 0, 32) for 1 s, then (0, 0, 60)
- **THEN** the limiter counts a red fall at (0, 0, 60) on every leg

#### Scenario: A host that stores 16 bits

- **WHEN** a tracker texel reads (65535, 65535, 65535, 65535) and the pixel's colour changes
- **THEN** the limiter counts every direction for that pixel
