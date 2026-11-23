<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Visual defaults

## ADDED Requirements

### Requirement: Cover Drift samples cover colours without detail

The catalog visual `cover-drift` (`shaders/visuals/cover-drift.glsl`) SHALL average 4 fixed,
well-separated quadrant fields from `IMG` via `photoCover` and render them as soft overlapping
radial blobs on a dark base with a slight vignette, using `motionCentered(uv, u)`. No image
detail, text, or hard edges SHALL appear, and displayed frame luma SHALL stay around 0.08–0.35 at
default settings.

#### Scenario: Still and dim enough for white text

- **WHEN** `cover-drift` renders at default params (`Speed = 0.5`, `Softness = 0.6`, `Glow = 0.5`)
- **THEN** the rendered frame is non-blank, clip-blob-free, shows no source image detail, and
  keeps mean displayed luma in the dim background range (~0.08–0.35)

### Requirement: Cover Drift moves calmly without beat response

`cover-drift` SHALL rotate the blob arrangement around the frame centre (90 s per turn at default
Speed 0.5) while drifting each blob on a slow Lissajous path (40–120 s periods), expose Speed
(`param0`, 0.5), Softness (`param1`, 0.6), and Glow (`param2`, 0.5), and scale brightness from
smoothed `u.level` by at most ±6% with no beat, onset, kick, or flux term.

#### Scenario: No beat or onset response

- **WHEN** `cover-drift` renders on a beat clock (`beat-lint.mjs` and `limiter-red-audit.mjs --audio loud`)
- **THEN** it is listed as ambient in `conformance/shaders/beat-lint.json` and triggers 0 red or
  luma flash transitions in any 1 s window
