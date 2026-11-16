## ADDED Requirements

### Requirement: Nebula scales with the host's detail reduction

The nebula visual SHALL run `6 + round(6 * detail)` volumetric shells, where `detail` is
`1 - clamp(presentation1.y, 0, 1)`, and SHALL scale each shell's alpha by `12 / shells`. At
`presentation1.y` 0 its output SHALL equal its output before this requirement.

#### Scenario: Full detail

- **WHEN** a host renders nebula with `presentation1.y` 0
- **THEN** it runs 12 shells with unscaled alpha

#### Scenario: Lowest detail

- **WHEN** a host renders nebula with `presentation1.y` 1
- **THEN** it runs 6 shells, each with twice the alpha
