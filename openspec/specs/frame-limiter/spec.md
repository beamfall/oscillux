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
- **THEN** the pixel auditor counts 0 large-area red transitions in every 1 s window of the output

#### Scenario: Luminance unchanged

- **WHEN** a luminance-only signal runs through the limiter
- **THEN** its output is byte-identical to the output with the previous red step

### Requirement: Feathered holds

The frame limiter's output SHALL show the previous output frame on every pixel of a held
sub-block, and SHALL blend toward the previous output frame on the pixels of a sub-block that is
not held and adjoins a held one, with a weight that falls from the held sub-block's edge to zero
at the far edge of the pixel's own sub-block. It SHALL NOT blend a pixel whose input, previous
output or blend is red-dominant (`r > g + b` in 8-bit); such a pixel shows the input.

#### Scenario: A held sub-block has no hard edge

- **WHEN** a sub-block is held while its neighbours are not, and the input differs from the
  previous output
- **THEN** every pixel of the held sub-block shows the previous output, the neighbours' pixels
  beside it show a value between the input and the previous output, and pixels further than one
  sub-block from it show the input

#### Scenario: Red pixels are not blended

- **WHEN** a pixel beside a held sub-block is red-dominant in the input or in the previous output
- **THEN** it shows the input
