<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Visual defaults

## ADDED Requirements

### Requirement: The streaming flights move colour, not brightness

Neon Run, Space Flight and Ocean Glide (`shaders/originals/visuals/neon-run.glsl`,
`space-flight.glsl`, `ocean-glide.glsl`) SHALL answer the music by changing the colour of what
streams past at a near-constant luminance, and SHALL filter detail that streams past at a pixel
or less over the pixel's footprint and the frame's travel instead of letting it strobe.

#### Scenario: Still answers the beat

- **WHEN** `tools/shader/beat-lint.mjs --only V` runs on the originals manifest for each of
  `neon-run` and `ocean-glide`
- **THEN** it passes

#### Scenario: Space Flight keeps its phrase

- **WHEN** `tools/shader/beat-lint.mjs --only space-flight` runs on the originals manifest
- **THEN** it reports no flash, and Space Flight's verdict is no worse than the release body's:
  it follows the 32-beat flight profile rather than each kick (CORE-3276 tracks a beat answer)

### Requirement: The streaming flights need little limiting

Under the red audit's loud audio, Neon Run, Space Flight and Ocean Glide SHALL make no red
transition, and through the limiter model each SHALL show at most 6 large-area luma transitions
in any second. Neon Run SHALL hold at most 6% of its pixels on average and 20% in any frame,
Space Flight at most 12% and 40%, and Ocean Glide at most 2.5% and 15%.

#### Scenario: Loud audio

- **WHEN** `tools/shader/limiter-red-audit.mjs --only V --audio loud --beats 32` runs for each of
  the three
- **THEN** no transition is red, the limiter's output makes at most 6 large-area luma transitions
  in any second, and the mean and largest held fractions are within the bounds above
