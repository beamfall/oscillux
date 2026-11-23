# shader-legs Specification

## Purpose
The shader release legs (`msl`, `glsl300`, `android-gles`) that hosts consume as checksummed
release assets, and the per-visual catalog metadata in `shaders/manifest.json` that the legs'
`catalog.json` carries.

## Requirements

### Requirement: Catalog fields in the manifest

A shader manifest visual MAY carry `name`, `blurb`, `tier`, `input`, `overlay`, `calm` and
`imageCapable`. The manifest loader SHALL require the first six together, one-line non-empty
`name`, `blurb` and `input`, `tier` of `lite`, `standard` or `flagship`, and booleans for
`overlay`, `calm` and `imageCapable`, and SHALL reject a visual whose `input` names `image`
when its `imageInput` is false, or the reverse. A manifest MAY carry `catalogOrder`, which SHALL
list every visual id exactly once.

#### Scenario: Image input disagreement

- **WHEN** a manifest visual has `input` "frequency + image" and no `imageInput`
- **THEN** loading the manifest fails naming that visual's `input`

#### Scenario: Reference set

- **WHEN** `shaders/manifest.json` is loaded
- **THEN** each of its 62 visuals has the catalog fields and `catalogOrder` lists all 62 ids

### Requirement: Param labels

A visual with the catalog fields SHALL have a label for each of its three param uniforms: a read
param from its control, an unread one from `unreadParamLabels`. The loader SHALL reject a missing
label, an unread label for a param that has a control, and `imageCapable` or
`unreadParamLabels` without the catalog fields.

#### Scenario: Unlabelled param

- **WHEN** a visual with catalog fields reads `param0` and `param1` with controls and leaves
  `param2` unread with no `unreadParamLabels`
- **THEN** loading the manifest fails naming `param2`

### Requirement: Catalog in the msl and glsl300 legs

The `msl` and `glsl300` legs SHALL contain `catalog.json`, listed in `index.json` with its
SHA-256, holding the release, the rev, the licence and every release-set visual in
`catalogOrder` with its catalog fields, `params` (key, label and default for all three),
`postFX` (post tuning and trail decay), `palette` (index and phase), `imageCapable`,
`imageInput` and param controls.

#### Scenario: Leg contents

- **WHEN** `bundle-legs.mjs glsl300` runs on a checkout
- **THEN** the leg holds one shader file per release-set visual and `catalog.json` lists 62
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

### Requirement: Feedback is frame-rate independent

A visual's feedback (the `feedbackTrail` helper and Ink) SHALL advance per second, not per drawn
frame: its decay, zoom, rotation, advection and injection authored per 60 Hz frame SHALL be scaled
by `n = dt * 60`, capped at 4, with one step when the host gives no frame clock. History sampled
outside the frame SHALL fade to zero within 1/32 of the frame instead of repeating the edge texel.

#### Scenario: Same trail at 30, 60 and 120 Hz

- **WHEN** a feedback visual runs at 120 Hz and at 60 Hz for one second
- **THEN** its trail has turned and zoomed by the same amount at both rates

#### Scenario: No streaks from the edge

- **WHEN** a feedback trail rotates so that history is sampled outside the frame
- **THEN** that history contributes nothing past 1/32 of the frame outside the edge

### Requirement: High-precision samplers in GLSL ES 3.00

The GLSL ES 3.00 visual, present and bloom passes SHALL declare `precision highp sampler2D`.

#### Scenario: HDR feedback is read at high precision

- **WHEN** a GLSL ES 3.00 leg's visual, present or bloom pass is generated
- **THEN** it declares `precision highp sampler2D`

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
