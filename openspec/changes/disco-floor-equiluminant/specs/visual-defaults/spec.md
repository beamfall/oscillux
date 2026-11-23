<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Visual defaults

## ADDED Requirements

### Requirement: Disco Floor moves colour, not brightness

Disco Floor (`shaders/originals/visuals/disco-floor.glsl`) SHALL answer the beat on large areas
(the LED floor, the dancers, the beams) by changing colour at a near-constant luminance, and
SHALL keep the spots and sequins that sweep across it under the 0.1 relative luminance step
that counts as a flash.

#### Scenario: Still answers the beat

- **WHEN** `beat-lint` runs on the release-leg Disco Floor
- **THEN** it passes

### Requirement: Disco Floor needs almost no limiting

Under the red audit's loud audio Disco Floor's own output SHALL make at most 6 large-area luma
transitions in any second and no red one. Through the limiter model it SHALL hold at most 1% of
its pixels on average and at most 15% in any frame.

#### Scenario: Loud audio

- **WHEN** `tools/shader/limiter-red-audit.mjs --only disco-floor --audio loud --beats 32` runs
- **THEN** the visual makes at most 6 large-area luma transitions in any second before the
  limiter, none of them red, the mean held fraction of pixels is at most 0.01 and the largest
  at most 0.15
