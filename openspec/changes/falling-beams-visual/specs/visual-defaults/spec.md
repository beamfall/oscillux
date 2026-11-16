<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Visual defaults

## ADDED Requirements

### Requirement: Falling beams fill

The original Visual `falling-beams` SHALL light more shafts as `param0` (Fill) rises from 0 to 1,
and SHALL never light fewer shafts at a higher Fill than at a lower one.

#### Scenario: Empty and full

- **WHEN** `falling-beams` renders the same frame at Fill 0 and at Fill 1
- **THEN** the mean luminance at Fill 1 is higher than at Fill 0

### Requirement: Falling beams runs without audio

`falling-beams` SHALL draw a moving picture when `level` is 0 and no beat arrives, and SHALL NOT
change luminance on a beat.

#### Scenario: Silence

- **WHEN** `falling-beams` renders two frames one second apart with silent audio uniforms
- **THEN** both frames are non-black and they differ
