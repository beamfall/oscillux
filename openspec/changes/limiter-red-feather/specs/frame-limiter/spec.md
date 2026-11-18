## MODIFIED Requirements

### Requirement: Feathered holds

The frame limiter's output SHALL show the previous output frame on every pixel of a held
sub-block and SHALL blend toward it around held sub-blocks with a weight that is continuous in
space, reaching 0 a little past four sub-blocks away. The output SHALL NOT step across a
sub-block boundary where neither the input nor the previous output steps. A pixel beside a hold
SHALL show the input unless its linear red code (`R - G - B` when saturated red, else 0) is the
same in the previous output, the input and the blend.

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

- **WHEN** a pixel beside a held sub-block is red in the input or in the previous output
- **THEN** it is blended only where its red code is the same in the previous output, the input
  and the blend
- **THEN** the pixel auditor counts 0 large-area red transitions in every 1 s window of the output

#### Scenario: A small red step beside a hold is not delayed

- **WHEN** a red region steps by less than `RED_STEP` beside sub-blocks that luma holds, and then
  falls to black a little more than 1 s later
- **THEN** the pixel auditor counts at most 1 large-area red transition in every 1 s window of the
  output

#### Scenario: An admitted red change is not hidden

- **WHEN** a checkerboard of black and red sub-blocks inverts once, so red rises in some
  sub-blocks while it falls, held, in their neighbours
- **THEN** the pixel auditor counts at most 1 large-area red transition in every 1 s window of the
  output

#### Scenario: Luminance unchanged

- **WHEN** a luminance-only signal runs through the limiter
- **THEN** its output is byte-identical to the output with the previous red step
