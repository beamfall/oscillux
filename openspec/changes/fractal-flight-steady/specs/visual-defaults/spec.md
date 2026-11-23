<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Visual defaults

## ADDED Requirements

### Requirement: Fractal Flight moves colour, not brightness

Fractal Flight (`shaders/originals/visuals/fractal-flight.glsl`) SHALL answer the beat by
changing the colour of its panes, lace and haze at a near-constant luminance, with at most a
gentle swell of the dim sunlit haze, and SHALL NOT let the sun shafts in the air near the camera,
which every pixel shares, follow the beat.

#### Scenario: Still answers the beat

- **WHEN** `tools/shader/beat-lint.mjs --only fractal-flight` runs on the originals manifest
- **THEN** it passes

### Requirement: Fractal Flight needs little limiting

Under the red audit's loud audio, Fractal Flight SHALL make no red transition, and through the
limiter model it SHALL show at most 6 large-area luma transitions in any second, hold at most
1.5% of its pixels on average and at most 15% in any frame.

#### Scenario: Loud audio

- **WHEN** `tools/shader/limiter-red-audit.mjs --only fractal-flight --audio loud --beats 32` runs
- **THEN** no transition is red, the limiter's output makes at most 6 large-area luma transitions
  in any second, the mean held fraction of pixels is at most 0.015 and the largest at most 0.15
