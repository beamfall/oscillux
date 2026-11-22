<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# CD+G presentation

## ADDED Requirements

### Requirement: Legible graphics colours

The presenter SHALL draw each graphics colour that touches the backdrop and has less than a 3.5:1
contrast ratio against the backdrop's darkest or brightest point mixed toward white or black, by
the fewest sixteenths (white first) that reach 3.5:1, or by the best mix when none does, in
integer arithmetic (`conformance/cdg-present/README.md`, Colours).

#### Scenario: Low-contrast lyrics

- **WHEN** blue lyrics are drawn straight onto a red background
- **THEN** they are drawn in a lighter blue with at least 3.5:1 contrast to the backdrop

### Requirement: Outlined colours keep theirs

A graphics colour outlined by a contrasting colour that is itself legible on the backdrop SHALL
keep its disc colour until the background index or palette changes.

#### Scenario: Outlined lyrics

- **WHEN** a dark fill is outlined in white on a dark background
- **THEN** the fill keeps its disc colour

#### Scenario: Outline goes away

- **WHEN** the palette changes so the outline no longer contrasts with the fill
- **THEN** the fill is fixed exactly as a new presenter would fix it

## MODIFIED Requirements

### Requirement: Magnified graphics and shadow

The presenter SHALL magnify the 288 x 192 window with an ink-priority Scale2x on the colour index
buffer and draw each non-backdrop colour as blurred, bilinearly sampled, thresholded coverage in
rank order into a centred rectangle of the frame height and 3:2 aspect, feathered at its edges.
The threshold SHALL sit close to a straight edge's blurred level and its ramp SHALL be under one
frame pixel wide, so edges are crisp without fattening strokes. A twice-blurred mask of
high-contrast pixels SHALL be drawn as a translucent black shadow offset down and right, under
the graphics. The output SHALL be opaque RGBA8.

#### Scenario: Deterministic frames

- **WHEN** a conformance stream is presented at the sizes in `conformance/cdg-present/` on the
  host and on wasm32
- **THEN** each frame's digest equals the one recorded there

#### Scenario: No per-frame allocation

- **WHEN** `present` runs after `Presenter::new`, including after a backwards seek
- **THEN** it does not allocate
