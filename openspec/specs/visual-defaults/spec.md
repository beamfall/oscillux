# visual-defaults Specification

## Purpose
The default parameters and palettes of the reference visuals in `shaders/manifest.json`, which
hosts take as each visual's starting look before user or preset overrides.

## Requirements

### Requirement: Red-free default palettes

Each visual in the reference set (`shaders/manifest.json`) SHALL have a default palette under which
the catalog red audit (`tools/shader/limiter-red-audit.mjs`, 480 x 270, 60 fps, 12 beats at
120 BPM) counts 0 large-area saturated-red transitions in every 1 s window of its unlimited output.

#### Scenario: Vault, laser-tunnel, reactor and loom

- **WHEN** the catalog red audit renders vault, laser-tunnel, reactor and loom with their default
  palettes and params
- **THEN** the pixel auditor counts 0 large-area red transitions on the input and on the limiter's
  output

#### Scenario: Not frozen

- **WHEN** the same audit runs vault and laser-tunnel through the frame limiter
- **THEN** their mean held fraction is below the 96% and 88% they reach with their v0.1.0 palettes

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

### Requirement: Particles holds little under loud audio

The catalogue Particles (`shaders/manifest.json`) SHALL keep its beat response under the frame
limiter's area budget: through the limiter model with the red audit's loud audio, no frame SHALL
hold more than 5% of the limiter's sub-blocks. It SHALL still pass `beat-lint`.

#### Scenario: Loud audio

- **WHEN** `make limiter-hold-check` runs the release-leg Particles through
  `tools/shader/limiter-red-audit.mjs --audio loud --max-held 0.05`
- **THEN** the largest held fraction of any frame is at most 0.05 and the check exits 0

#### Scenario: Beat response kept

- **WHEN** `beat-lint` runs on the release-leg Particles
- **THEN** it passes
