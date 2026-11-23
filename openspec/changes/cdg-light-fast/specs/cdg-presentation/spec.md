<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# CD+G presentation

## ADDED Requirements

### Requirement: Real-time presentation

Presenting the worst-case stream of the frame budget bench (every colour inked, a tile changed
by every pack) at 960 x 540 SHALL take at most 1/120 of a CPU second per frame natively, so the
wasm32 render command keeps above 60 frames per CPU second.

#### Scenario: Busy disc

- **WHEN** the frame budget bench presents its worst-case stream at 960 x 540
- **THEN** the median CPU time per frame is at most 8.3 ms

## MODIFIED Requirements

### Requirement: Magnified graphics and shadow

The presenter SHALL magnify the 288 x 192 window with an ink-priority Scale2x on the colour index
buffer and draw each non-backdrop colour as blurred, bilinearly sampled, thresholded coverage in
rank order into a centred rectangle of the frame height and 3:2 aspect, feathered at its edges.
A colour SHALL draw at a frame pixel only where it lies inside the blur support of that pixel's
samples, so a colour never fringes the edges of another. A twice-blurred mask of high-contrast
pixels SHALL be drawn as a translucent black shadow offset down and right, under the graphics.
The output SHALL be opaque RGBA8.

#### Scenario: Deterministic frames

- **WHEN** a conformance stream is presented at the sizes in `conformance/cdg-present/` on the
  host and on wasm32
- **THEN** each frame's digest equals the one recorded there

#### Scenario: No per-frame allocation

- **WHEN** `present` runs after `Presenter::new`, including after a backwards seek
- **THEN** it does not allocate

#### Scenario: No fringe

- **WHEN** white lyrics are drawn and red graphics are elsewhere in the window
- **THEN** no red is mixed into the edges of the white lyrics

### Requirement: Sharp edges

The coverage threshold SHALL put a straight edge slightly inside the unblurred edge, so strokes
are drawn at regular weight, while a lone window pixel still draws. The ramp SHALL be under one
frame pixel wide at magnified sizes, and SHALL take a fully inked area to full coverage at every
frame size.

#### Scenario: Crisp letter edges

- **WHEN** a glyph edge is drawn at a magnified frame size
- **THEN** its coverage goes from none to full in less than one frame pixel, no further out than
  the unblurred edge

#### Scenario: Lone pixel

- **WHEN** a single window pixel of a graphics colour is surrounded by background
- **THEN** it is drawn with some coverage

#### Scenario: Solid interiors at small sizes

- **WHEN** a frame is smaller than the 288 x 192 window
- **THEN** the inside of a filled area is drawn in its exact colour
