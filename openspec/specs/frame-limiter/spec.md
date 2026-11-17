# frame-limiter Specification

## Purpose
The frame flash limiter's rules for counting and limiting large-area flashes and saturated-red
transitions in the model and its GPU passes, which conformance vectors under
`conformance/limiter/frame/` pin.

## Requirements

### Requirement: Partial-coverage red

The frame limiter SHALL request a saturated-red transition for a sub-block when its mean red code
moves by at least 512 codes, one eighth of the pixel auditor's red step, so that red covering part
of a sub-block counts toward the area limit.

#### Scenario: Red stripes in every sub-block

- **WHEN** one-pixel red columns, one in every three, switch between `[110,0,0]` and black at 10 Hz
  over the whole frame
- **THEN** the pixel auditor counts at most 1 large-area red transition in every 1 s window of the
  output

#### Scenario: Luminance unchanged

- **WHEN** a luminance-only signal runs through the limiter
- **THEN** its output is byte-identical to the output with the previous red step

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
flash) and a held red change is admitted within 8 / (2 x maxFlashHz) s plus one frame.

#### Scenario: Red strobe

- **WHEN** a full-frame saturated-red and black square wave at 3 Hz or 10 Hz runs for 5 s
- **THEN** the pixel auditor counts at most 1 large-area red transition in every 1 s window of the
  output

#### Scenario: Lasting red change

- **WHEN** a full-frame saturated red changes to cyan and stays cyan
- **THEN** the output shows the cyan input within 1.5 s
