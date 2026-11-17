# palette-tour Specification

## Purpose
TBD - created by archiving change export-palette-tour. Update Purpose after archive.

## Requirements

### Requirement: Palette tour uniform

`oscillux_palette_tour(time_seconds, offset, out)` SHALL write the vec4 `palette` uniform of the
vivid colour mode: `[-1, 0, z, 0]` with `z = (time_seconds / 6 + offset)` wrapped into `[0, 16)`,
so a visual cross-fades through all sixteen vivid palettes, one every 6 s. It SHALL refuse a
non-finite argument or a null `out` and leave `out` unchanged. It SHALL NOT allocate.

#### Scenario: Conformance vectors

- **WHEN** the core, the C export, the npm `paletteTour` and `tools/shader/palette-tour.mjs`
  evaluate every case in `conformance/palette-tour/vectors.json`
- **THEN** each `z` matches the vector within 1e-9 and the other components are exactly -1, 0, 0

#### Scenario: Negative offset

- **WHEN** the offset is -3 at time 0
- **THEN** `z` is 13

### Requirement: Vivid present defaults

`oscillux_palette_vivid_present(out)` SHALL write the vivid colour mode's present-pass saturation
1.35 and vibrance 1.2, in that order. Manifest colour mode keeps saturation 1 and vibrance 0.

#### Scenario: Defaults

- **WHEN** a host reads the vivid present defaults
- **THEN** it gets saturation 1.35 and vibrance 1.2
