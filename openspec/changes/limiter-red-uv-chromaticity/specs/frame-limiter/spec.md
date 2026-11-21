<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## MODIFIED Requirements

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

## ADDED Requirements

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

Every pixel SHALL keep a box of the saturated codes it showed since its last definite red fall and
a box of the far codes since its last definite rise. At a changed colour it SHALL count down when
the saturated box may hold a code more than a possible step away, and at a changed saturated colour
up when the far box may. A box SHALL clear only at a definite step. Black SHALL change nothing. A
pixel firing a direction by this rule SHALL count that direction only.

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
until a definite step makes it known. The auditor SHALL keep its boxes at a zero restart and count
at most one large-area red transition a frame.

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

### Requirement: Tracker texel format

A host SHALL allocate both tracker textures RGBA32UI, seed and clear them with 32-bit values, check
at start that a cleared texel with bit 31 set in every word reads back unchanged and present black
if not, and bind `uHist` to the rows pass. Every texel a leg writes SHALL set bit 31 of z. A texel
without it that is not all zero SHALL count every direction at a changed colour.

#### Scenario: A host keeps its trackers across frames

- **WHEN** a pixel shows (60, 0, 18), then (35, 0, 32) for 1 s, then (0, 0, 60)
- **THEN** the limiter counts a red fall at (0, 0, 60) on every leg

#### Scenario: A host that stores 16 bits

- **WHEN** a tracker texel reads (65535, 65535, 65535, 65535) and the pixel's colour changes
- **THEN** the limiter counts every direction for that pixel
