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

### Requirement: Originals keep reds off saturated red through the vivid present

Every original (`shaders/originals/visuals/`) SHALL finish its colour through `osOffRed`
(`shaders/originals/common.glsl`). It SHALL select 0 for each channel unequal to itself
(`notEqual(c, c)`), clamp each channel to [0, 16], and, where green plus blue is under 0.55 of
red in linear light, raise both by half the difference. Only on a target honouring IEEE NaN and
infinity is a NaN or infinite input's result specified. This is a quality measure; the frame
limiter carries the safety claim.

#### Scenario: Pure red

- **WHEN** an original's body returns linear (1, 0, 0)
- **THEN** the visual writes (1, 0.275, 0.275), which the vivid grade presents under a red share
  of 0.77

#### Scenario: Colours with enough green and blue

- **WHEN** an original's body returns a finite colour with every channel in [0, 16], max channel
  at least 0.05, and green plus blue at least 0.55 of red, each side rounded to float32 as the
  shader computes it, such as (0.05, 0.014, 0.014) or (0.75, 0.4125, 2^-26)
- **THEN** the visual writes it unchanged, bit for bit

#### Scenario: A NaN channel

- **WHEN** an original's body returns (0.1, NaN, 0) on a target whose comparisons honour IEEE NaN,
  or in the reference emulation
- **THEN** the visual writes (0.1, 0.0275, 0.0275), as for (0.1, 0, 0), and never pure red

### Requirement: Near-black originals present no saturated-red bytes

Below a max channel of 0.006, `osOffRed` SHALL return the exact grey of the colour's luminance.
From 0.006 to 0.012 it SHALL lower red to the larger of green and blue where red exceeds it,
from 0.012 to 0.05 ramp red's excess back in, and from 0.05 keep red. For finite inputs (NaN and
infinities only on IEEE targets), no byte triple of the per-pixel present path (design.md,
section 3) SHALL then be saturated red.

#### Scenario: A near-black red

- **WHEN** an original's body returns linear (0.001, 0, 0) or (0.01, 0, 0)
- **THEN** every channel the visual writes is equal, and no present dither yields (1, 0, 0)

#### Scenario: A dim colour without red excess

- **WHEN** an original's body returns linear (0, 0.007, 0)
- **THEN** the visual writes it unchanged

#### Scenario: A dim red on the ramp

- **WHEN** an original's body returns a linear colour with max channel from 0.012 to 0.05, and
  present runs with grain 0 to 0.25 and dither of 1 or 0.5 code or none
- **THEN** no present byte triple is saturated red

#### Scenario: Paths outside the claim

- **WHEN** present aberration, an authored channel-split transition, or a pixel or frame mix
  (bloom, blur, dissolve, damping) combines original colours
- **THEN** the claim does not apply, and the frame limiter alone governs the presented bytes

### Requirement: Disco Floor moves colour, not brightness

Disco Floor (`shaders/originals/visuals/disco-floor.glsl`) SHALL answer the beat on large areas
(the LED floor, the dancers, the beams) by changing colour at a near-constant luminance, and
SHALL keep the spots and sequins that sweep across it under the 0.1 relative luminance step
that counts as a flash, measured on the displayed frame after the present pass.

#### Scenario: Still answers the beat

- **WHEN** `tools/shader/beat-lint.mjs --only disco-floor` runs on the originals manifest
- **THEN** it passes

#### Scenario: Glints stay under the flash step

- **WHEN** Disco Floor renders with its default controls and the same frame renders again with
  only the mirror-ball spots, or only the sequins, removed
- **THEN** no pixel's displayed relative luminance differs between the two by 0.1 or more

### Requirement: Disco Floor needs almost no limiting

Under the red audit's loud audio Disco Floor's own output SHALL make at most 6 large-area luma
transitions in any second and no red one. Through the limiter model it SHALL hold at most 1% of
its pixels on average and at most 15% in any frame.

#### Scenario: Loud audio

- **WHEN** `tools/shader/limiter-red-audit.mjs --only disco-floor --audio loud --beats 32` runs
- **THEN** the visual makes at most 6 large-area luma transitions in any second before the
  limiter, none of them red, the mean held fraction of pixels is at most 0.01 and the largest
  at most 0.15
