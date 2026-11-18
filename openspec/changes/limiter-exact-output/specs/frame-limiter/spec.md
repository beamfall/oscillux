<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## REMOVED Requirements

### Requirement: Feathered holds

**Reason**: A blended pixel showed a change after the token it spent had refilled, so the output
could exceed the luma and red budgets (CORE-2543, CORE-2541).

**Migration**: None for hosts beyond re-vendoring the generated passes. Output beside a hold is
now the input; see "Exact output".

## ADDED Requirements

### Requirement: Exact output

The frame limiter's output SHALL show the previous output frame on every pixel of a held
sub-block and the input exactly on every other pixel.

#### Scenario: Held and live pixels

- **WHEN** some sub-blocks are held and the input differs from the previous output
- **THEN** every pixel of a held sub-block equals the previous output and every other pixel equals
  the input

#### Scenario: An admitted rise is not delayed

- **WHEN** a steady gray, orange or blue rise runs beside sub-blocks that are held
- **THEN** the pixel auditor counts at most 6 large-area luma transitions and at most 1 red
  transition in every 1 s window of the output
