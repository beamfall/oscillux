<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## MODIFIED Requirements

### Requirement: Flash measure

The frame limiter and the pixel auditor SHALL measure flashes in the same integer codes:

- luma steps of 3275 15-bit codes, with the darker side below 26215;
- red steps of 15 codes of `(R - G - B) >> 8` of the linear channel codes, wherever `R > G + B`;
- the red chromaticity zones (Red chromaticity zones).

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

#### Scenario: Saturated red against white

- **WHEN** a full-frame 10 Hz strobe alternates between (255, 0, 0) and (255, 255, 255)
- **THEN** the pixel auditor counts at least 18 red transitions a second in the input and at most
  1 in the output

#### Scenario: A dim red on black

- **WHEN** a full-frame 10 Hz strobe alternates between (60, 0, 0) and black
- **THEN** the pixel auditor counts no red transitions in the input or the output

## ADDED Requirements

### Requirement: Red chromaticity zones

Every colour SHALL be in exactly one zone:

- saturated red (S, `redSat`);
- far (F): not S, and more than 0.2 in CIE 1976 u'v' from some saturated-red chromaticity under
  either the IEC 61966-2-1 matrix or the matrix derived from the sRGB primaries;
- near (M): every other colour, black included.

The integer classifier MAY call a near colour far. It SHALL NOT call a far colour near or an S
colour far.

#### Scenario: Every 8-bit colour

- **WHEN** the classifier runs over every 8-bit colour
- **THEN** every far colour is F, no S colour is far or F, and every partial sum fits a signed
  32-bit integer

#### Scenario: Black and grey

- **WHEN** a pixel shows (0, 0, 0), and then (128, 128, 128)
- **THEN** black is near and the grey is far

### Requirement: Red chromaticity transitions

Every pixel SHALL keep a side: S or F, whichever it last showed.

- An S colour shown on an F side SHALL count a red transition up.
- An F colour shown on an S side SHALL count a red transition down.
- An M colour SHALL keep the side and count nothing.

A red direction SHALL count where this rule or red transition counting counts it, including when
the two rules count opposite directions in the same frame.

#### Scenario: Black keeps the side

- **WHEN** a pixel shows (255, 0, 0), then black for 1.5 s with no restart, then (0, 255, 0)
- **THEN** the pixel auditor counts a red fall at black and another at (0, 255, 0)

#### Scenario: Both red directions in one change

- **WHEN** a full-frame 10 Hz strobe alternates between (5, 0, 0) and (255, 0, 230), each change
  counting a red rise by one rule and a fall by the other
- **THEN** the pixel auditor counts at most 1 red transition a second in the output

### Requirement: Red side at a start

- A pixel's first value with no state SHALL set its side to its zone and count nothing.
- The seed "black, nothing owed" SHALL leave the pixel with no side.
- The zero seed SHALL leave the side unknown, and the first S or F colour then SHALL count.

The pixel auditor SHALL set the side at its first frame, clear it where it reseeds a pixel black,
and keep it at a zero restart.

#### Scenario: A blue after a black start

- **WHEN** a pixel shows (255, 0, 0), then black for 75 frames at 60 Hz, the host restarts at
  "black, nothing owed", and the pixel shows (0, 0, 255)
- **THEN** neither the limiter nor the pixel auditor counts a red transition at (0, 0, 255)

#### Scenario: A blue after a zero start

- **WHEN** a pixel shows (255, 0, 0), then black for 8 frames, the host restarts at zero, and the
  pixel shows (0, 0, 255)
- **THEN** the limiter counts a red fall at (0, 0, 255), and so does the pixel auditor, which saw
  the red
