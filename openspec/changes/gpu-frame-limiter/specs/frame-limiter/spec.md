## ADDED Requirements

### Requirement: Zero red budget

The frame limiter SHALL hold every sub-block that requests a saturated-red transition while red
transitions in that direction cover more than the area limit, SHALL never grant such a transition
from any budget, and SHALL NOT let red requests consume or wait on the luminance budget.

#### Scenario: Full-frame red strobe

- **WHEN** a full-frame saturated-red/black square wave runs at 3 Hz or 10 Hz for 5 s at 60 Hz
- **THEN** no 1 s window contains an admitted large-area red transition

#### Scenario: Luminance unaffected

- **WHEN** a full-frame luminance-only square wave runs at 3 Hz
- **THEN** the limiter's output is byte-identical to the shared-budget limiter's output

### Requirement: 10° flash area

The frame limiter SHALL count a large-area transition when, in the worst window the size of a 10°
visual field for the host's reference geometry, the sub-blocks transitioning in one direction
cover more than 25% of that field.

#### Scenario: Strobe over half of a 10° field

- **WHEN** a 10 Hz strobe covers half of one 10° field at the TV geometry (under 20% of the frame)
- **THEN** the limiter holds it to at most 6 transitions in every 1 s window

### Requirement: Every pixel contributes

The frame limiter SHALL reduce each frame by box means over a 64×36 sub-block partition in which
every pixel belongs to exactly one sub-block, and SHALL track each sub-block separately.

#### Scenario: Phase reversal inside a cell

- **WHEN** a checkerboard of half-cell squares inverts at 10 Hz over the frame
- **THEN** the limiter holds it to at most 6 transitions in every 1 s window

#### Scenario: Resolution independence

- **WHEN** the same area-antialiased one-cell-wide bar moves across 1080p and 4K frames
- **THEN** the limiter counts the same transitions at both resolutions

### Requirement: Bit-identical GPU pass

The GLSL frame limiter SHALL reproduce the reference model's hold mask, grant and output exactly on
every case in `conformance/limiter/frame/`.

#### Scenario: WebGL2 vector check

- **WHEN** the gate runs the pass in WebGL2 over every vector case
- **THEN** every frame's hold mask, grant word and output digest equals the vector's
