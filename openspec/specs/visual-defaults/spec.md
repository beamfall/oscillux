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
hold more than 20% of the frame's pixels. It SHALL still pass `beat-lint`.

#### Scenario: Loud audio

- **WHEN** `make limiter-hold-check` runs the release-leg Particles through
  `tools/shader/limiter-red-audit.mjs --audio loud --max-held 0.20`
- **THEN** the largest held fraction of pixels in any frame is at most 0.20 and the check exits 0

#### Scenario: Beat response kept

- **WHEN** `beat-lint` runs on the release-leg Particles
- **THEN** it passes

### Requirement: Visuals fit the frame's aspect

Each visual in the reference set SHALL keep its main subject in frame and its repeated detail
(bars, columns, lines) at least about 4 px wide at any frame aspect from a portrait phone
(9:19.5) to ultrawide (21:9). The `centered()` and `motionCentered()` coordinate helpers SHALL
lean toward the frame's short side. Bar visuals SHALL choose their column count from the
frame aspect with `fitColumns`. At aspect 16:9 and wider a visual's output SHALL be unchanged by this fit.

#### Scenario: A phone held upright

- **WHEN** a centered visual renders at 390 x 844
- **THEN** coordinates scale by aspect^-0.7, so a subject authored within radius 0.8 fits the
  frame's width

#### Scenario: Bars on a narrow frame

- **WHEN** Spectrum renders at 390 x 844
- **THEN** it draws fewer, wider columns than at 16:9, each at least 4 px wide

#### Scenario: Landscape unchanged

- **WHEN** a visual renders at 480 x 270
- **THEN** its frame matches the frame before the change to within 1/255

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
