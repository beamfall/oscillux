<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame limiter

## ADDED Requirements

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

## MODIFIED Requirements

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
