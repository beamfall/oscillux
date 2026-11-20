<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# shader-legs

## ADDED Requirements

### Requirement: Release set

The legs SHALL be built from the release set: the visuals of `shaders/manifest.json` in its
order, where each one that `shaders/originals/manifest.json` marks `overrides: true` takes the
original's shader and effect data and keeps the catalog's descriptive fields and place in
`catalogOrder`. Building the set SHALL fail when an override's `imageInput` differs from its
catalog entry or an override has no catalog entry.

#### Scenario: Fields of an overridden visual

- **WHEN** an original overrides a catalog visual
- **THEN** the release visual has the original's body, wrapper, header, targets, palette, params,
  controls, tunables, trail decay and post, the catalog's name, blurb, tier, input, overlay, calm
  and imageCapable, and param labels from the original's controls, else the catalog's

#### Scenario: Overridden visual

- **WHEN** `bundle-legs.mjs glsl300` runs on a checkout whose originals override `event-horizon`
- **THEN** the leg's `event-horizon.web.frag` equals the originals' GLSL ES 3.00 wrap of the
  original's body, and its `catalog.json` entry keeps the catalog's name and blurb with the
  original's params, palette and post

#### Scenario: Override without a catalog entry

- **WHEN** an original marked `overrides: true` has an id that `shaders/manifest.json` lacks
- **THEN** building the release set fails naming that id

## MODIFIED Requirements

### Requirement: Catalog in the msl and glsl300 legs

The `msl` and `glsl300` legs SHALL contain `catalog.json`, listed in `index.json` with its
SHA-256, holding the release, the rev, the licence and every release-set visual in
`catalogOrder` with its catalog fields, `params` (key, label and default for all three),
`postFX` (post tuning and trail decay), `palette` (index and phase), `imageCapable`,
`imageInput` and param controls.

#### Scenario: Leg contents

- **WHEN** `bundle-legs.mjs glsl300` runs on a checkout
- **THEN** the leg holds one shader file per release-set visual and `catalog.json` lists 61
  visuals in `catalogOrder`

#### Scenario: Web lab parity

- **WHEN** the `glsl300` leg is generated
- **THEN** each `catalog.json` visual has the id, name, tier, input, overlay, calm, blurb and
  imageCapable of the matching catalog entry, in `catalogOrder`, and an overridden visual's shader
  file is the one the lab renders for that id

### Requirement: Android GLES leg

`bundle-legs.mjs android-gles` SHALL write `AndroidGlesShaders.kt` and `index.json` from the
release set. The Kotlin file SHALL keep contract version 1.0.0, package
`com.beamfall.kit.visuals`, object `AndroidGlesShaders`, the domains
`beamfall.android-gles.catalog.v1` and `beamfall.android-gles.source.v1` and their payload
format, and SHALL name the Oscillux tag and rev on its second line.

#### Scenario: v0.2.0 regression

- **WHEN** the leg is generated from the release set with tag v0.2.0 and rev
  ea319a10f2c4e90cbcf5d64f928a85bd97ae197e
- **THEN** its catalog and source digests equal those pinned in `test-android-gles.mjs`

## REMOVED Requirements
