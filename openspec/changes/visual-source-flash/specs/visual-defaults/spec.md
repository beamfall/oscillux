## ADDED Requirements

### Requirement: Visuals keep within the general flash limit on their own

Each visual in the reference set SHALL, under the catalog audit's loud audio
(`limiter-red-audit.mjs --audio loud`, 480 x 270, 60 fps, 12 beats), make at most 6 large-area
luma transitions in any one-second window and no large-area red transition on its own output,
before the frame limiter, unless an owner-recorded exception names it. `make visual-flash-check`
SHALL check this.

#### Scenario: Loud master

- **WHEN** a reference visual renders under loud audio
- **THEN** its own output makes at most 6 large-area luma transitions in any second and no red one

#### Scenario: A visual over budget

- **WHEN** a visual's own output makes 7 large-area luma transitions in one second
- **THEN** `make visual-flash-check` exits non-zero and names it
