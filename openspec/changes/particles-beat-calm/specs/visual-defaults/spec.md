## ADDED Requirements

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
