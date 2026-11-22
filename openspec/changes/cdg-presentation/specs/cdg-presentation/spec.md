<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# CD+G presentation

## ADDED Requirements

### Requirement: Background detection

The presenter SHALL choose one background colour index per frame from the window edge ring
(`Region::Edge`). It SHALL choose the Memory Preset colour when that index covers at least half
of the ring, and otherwise the index with the most ring pixels, ties going to the lowest index.

#### Scenario: Preset background

- **WHEN** the screen was cleared with Memory Preset colour 3 and lyrics in colour 7 cross the
  ring but cover less than half of it
- **THEN** the background index is 3

#### Scenario: Painted background

- **WHEN** the preset colour covers less than half of the ring and colour 5 covers the most
- **THEN** the background index is 5

### Requirement: Stage and easing

The presenter SHALL fill the whole output frame with the background colour as a vertical
gradient, lighter at the top and darker at the bottom. When the background colour changes it
SHALL ease from the previous stage colour to the new one over 300 ms of media time. On the first
frame, or when media time moves backwards, the stage SHALL take the new colour at once.

#### Scenario: Colour change

- **WHEN** the background changes from blue to red and frames are presented 100 ms apart
- **THEN** the stage colour reaches red on the third frame after the change and lies strictly
  between blue and red on the frames before it

### Requirement: Magnified graphics and shadow

The presenter SHALL magnify the 288 x 192 window with Scale4x on the colour index buffer and
sample the result bilinearly into a centred rectangle of the frame height and 3:2 aspect.
Background-index pixels SHALL be transparent. A box-blurred mask of the other pixels SHALL be
drawn as a translucent black shadow offset down and right, under the graphics. The output SHALL
be opaque RGBA8.

#### Scenario: Deterministic frames

- **WHEN** a conformance stream is presented at 640 x 360 on the host and on wasm32
- **THEN** each frame's digest equals the one recorded in `conformance/cdg-present/`

#### Scenario: No per-frame allocation

- **WHEN** `present` runs after `Presenter::new`
- **THEN** it does not allocate

### Requirement: Render command

`oscillux-cdg-render` SHALL read a CD+G stream on stdin and write raw RGBA8 frames of the given
width and height to stdout, frame `n` showing source time `start + n / fps * tempo`. After the
stream ends it SHALL keep writing the last frame until a write fails, then exit 0. Invalid
arguments SHALL exit non-zero with a message on stderr and write no frames.

#### Scenario: Frame size

- **WHEN** it runs with `--width 640 --height 360 --fps 30` and stdout is read for 10 frames
- **THEN** exactly 10 x 640 x 360 x 4 bytes arrive before the reader closes
