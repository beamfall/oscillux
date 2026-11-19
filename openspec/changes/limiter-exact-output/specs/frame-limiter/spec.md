<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## REMOVED Requirements

### Requirement: Feathered holds

**Reason**: A blended pixel showed a change after the token it spent had refilled, so the output
could exceed the luma and red budgets (CORE-2543, CORE-2541).

**Migration**: None for hosts beyond re-vendoring the generated passes. Output beside a hold is
now the input; see "Exact output".

## ADDED Requirements

### Requirement: Exact output

The frame limiter's output SHALL show the input exactly on every pixel that is not held (a held
pixel is one whose trackers would fire in a direction the grant did not admit), including pixels
that share a sub-block with a held one. "Per-pixel holds" states what a held pixel shows.

#### Scenario: Held and live pixels

- **WHEN** a strobe whose edges fall inside sub-blocks is held while the background beside it
  changes below a step
- **THEN** every background pixel, in the same sub-blocks too, equals the input

#### Scenario: An admitted rise is not delayed

- **WHEN** a steady gray, orange or blue rise runs beside sub-blocks that are held
- **THEN** the pixel auditor counts at most 6 large-area luma transitions and at most 1 red
  transition in every 1 s window of the output
