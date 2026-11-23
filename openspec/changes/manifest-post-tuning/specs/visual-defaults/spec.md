<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Visual defaults

## ADDED Requirements

### Requirement: Per-visual post tuning fields

A shader manifest visual MAY carry a `post` object with exactly the keys `bloomStrength`
(0 to 2), `bloomThreshold` (0 to 4), `chroma` (0 to 0.05), `vignette` (0 to 1) and `grain`
(0 to 0.25). The manifest loader SHALL reject an unknown key, a missing key or an out-of-range
value with the path of the fault.

#### Scenario: Out-of-range value

- **WHEN** a manifest visual sets `post.grain` to 0.251
- **THEN** loading the manifest fails with `visuals[0].post.grain: must be a number in [0, 0.25]`

### Requirement: Effect-off post defaults

A visual without `post` SHALL take `bloomStrength` 0, `bloomThreshold` 1, `chroma` 0,
`vignette` 0 and `grain` 0.

#### Scenario: No post block

- **WHEN** a manifest visual has no `post`
- **THEN** the loaded visual's `post` is the effect-off defaults

### Requirement: Reference set post tuning

Every visual in the reference set (`shaders/manifest.json`) SHALL carry its own `post`, and the
host bundle SHALL copy each visual's `post` unchanged.

#### Scenario: Reference set

- **WHEN** `shaders/manifest.json` is loaded
- **THEN** each of its 62 visuals has a `post` object with all five keys, each within its range
