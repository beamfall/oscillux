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

### Requirement: Backdrop indices

Besides the background index, every index covering at least a quarter of the edge ring SHALL be
a backdrop index. Backdrop indices SHALL NOT be drawn as graphics or cast a shadow.

#### Scenario: Two-colour painted backdrop

- **WHEN** the window is tiled in colours 1 and 2, each covering about half of the ring, with
  lyrics in colour 7
- **THEN** only colour 7 is drawn over the backdrop

### Requirement: Backdrop and easing

The presenter SHALL fill the whole output frame with a backdrop derived from the background
colour: a dark tinted base, two soft glows that drift with media time and a vignette, ordered
dithered to 8 bits. When the background colour changes the backdrop tint SHALL ease from the
previous colour to the new one over 300 ms of media time. On the first frame, or when media time
moves backwards, it SHALL take the new colour at once.

#### Scenario: Colour change

- **WHEN** the background changes from blue to red and frames are presented 100 ms apart
- **THEN** the stage colour reaches red on the third frame after the change and lies strictly
  between blue and red on the frames before it

#### Scenario: Seek back

- **WHEN** media time moves backwards across a colour change
- **THEN** the stage colour equals the background colour on that frame

### Requirement: Magnified graphics and shadow

The presenter SHALL magnify the 288 x 192 window with an ink-priority Scale2x on the colour index
buffer and draw each non-backdrop colour as blurred, bilinearly sampled, thresholded coverage in
rank order into a centred rectangle of the frame height and 3:2 aspect, feathered at its edges.
A twice-blurred mask of high-contrast pixels SHALL be drawn as a translucent black shadow offset
down and right, under the graphics. The output SHALL be opaque RGBA8.

#### Scenario: Deterministic frames

- **WHEN** a conformance stream is presented at the sizes in `conformance/cdg-present/` on the
  host and on wasm32
- **THEN** each frame's digest equals the one recorded there

#### Scenario: No per-frame allocation

- **WHEN** `present` runs after `Presenter::new`, including after a backwards seek
- **THEN** it does not allocate

### Requirement: Render command

`oscillux-cdg-render` SHALL read a CD+G stream on stdin and write raw RGBA8 frames of the given
width and height to stdout. With `--frames N` it SHALL write exactly N frames and exit 0, or exit
non-zero if a write fails first. Otherwise it SHALL write frames until a write fails, then exit 0.
Invalid arguments SHALL exit non-zero with a message on stderr and write no frames.

#### Scenario: Frame size

- **WHEN** it runs with `--width 640 --height 360 --fps 30` and stdout is read for 10 frames
- **THEN** exactly 10 x 640 x 360 x 4 bytes arrive before the reader closes

#### Scenario: Truncated bounded render

- **WHEN** it runs with `--frames 40` and the reader closes after the first bytes
- **THEN** it exits non-zero

### Requirement: Render clock

Frame `n` of `oscillux-cdg-render` SHALL show source time `start + n / fps * tempo`, with a time
that is a rounding error below a pack or millisecond boundary counted as on it. Media time SHALL
stop 300 ms after the first frame that shows the stream's last pack.

#### Scenario: Pack on a frame boundary

- **WHEN** a pack is due at exactly frame 11 of a 30 fps render
- **THEN** frame 11 shows it

#### Scenario: Hold after the stream ends

- **WHEN** frames are written more than 300 ms after the first frame showing the last pack
- **THEN** they are identical, and any background change in that pack has finished easing
