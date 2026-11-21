<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## ADDED Requirements

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
  at least 0.05, and green plus blue at least 0.55 of red
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
