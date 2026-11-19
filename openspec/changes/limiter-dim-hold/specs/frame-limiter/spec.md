<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## MODIFIED Requirements

### Requirement: Per-pixel holds

The frame limiter SHALL show the input at every pixel whose trackers would not fire on it in a
direction the grant did not admit. Every other pixel is held. At a held pixel the limiter SHALL
show a colour on which the pixel's trackers fire only in directions that the input fires and the
grant admitted, and SHALL step the trackers on that colour. It SHALL choose the first of these
that qualifies, in 8-bit display codes:

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
