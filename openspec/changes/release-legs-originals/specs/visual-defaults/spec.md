<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## MODIFIED Requirements

### Requirement: Nebula scales with the host's detail reduction

The nebula visual SHALL draw all seven of its layers at every detail level, so the lowest level
keeps the composition, and SHALL run `int(3 + 2 * detail + 0.5)` noise octaves, where `detail` is
`1 - clamp(presentation1.y, 0, 1)`. The legs ship the rebuilt original
(`shaders/originals/visuals/nebula.glsl`), which trims octaves instead of the catalog body's
volumetric shells.

#### Scenario: Full detail

- **WHEN** a host renders nebula with `presentation1.y` 0
- **THEN** it draws seven layers with five noise octaves

#### Scenario: Lowest detail

- **WHEN** a host renders nebula with `presentation1.y` 1
- **THEN** it draws seven layers with three noise octaves
