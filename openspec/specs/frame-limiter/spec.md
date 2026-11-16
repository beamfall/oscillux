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
