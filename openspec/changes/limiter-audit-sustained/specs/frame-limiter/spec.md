<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame limiter

## ADDED Requirements

### Requirement: Pixel auditor counts sustained flashing

The pixel auditor SHALL count a large-area transition at every frame where the pixels that made
that transition within the coverage interval, and after the direction's previous large-area
transition, cover more than the field window's limit, so that sustained flashing is counted at
its rate and not once per run.

#### Scenario: Strobe faster than the coverage interval

- **WHEN** a full-frame white and black square wave at 15 Hz or 30 Hz runs for 5 s
- **THEN** the pixel auditor counts 2 x hz large-area luma transitions in a 1 s window of the input

#### Scenario: Limiter output on a full-frame strobe

- **WHEN** the same square wave runs through the frame limiter
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output, and no more than in the input
