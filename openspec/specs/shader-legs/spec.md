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
- **THEN** each of its 61 visuals has the catalog fields and `catalogOrder` lists all 61 ids

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
SHA-256, holding the release, the rev, the licence and every visual in `catalogOrder` with its
catalog fields, `params` (key, label and default for all three), `postFX` (post tuning and
trail decay), `palette` (index and phase), `imageCapable`, `imageInput` and param controls.
Adding it SHALL NOT change any other file of either leg.

#### Scenario: Web lab parity

- **WHEN** the `glsl300` leg is generated from the v0.2.0 shaders
- **THEN** each `catalog.json` visual deep-equals the matching entry of Beamfall's web lab
  `LAB_VISUALS` in id, name, tier, input, overlay, calm, blurb, imageCapable, params, postFX and
  palette, in the same order

#### Scenario: Leg contents

- **WHEN** `bundle-legs.mjs glsl300` runs on a checkout
- **THEN** the leg's shader files are byte-identical to those of the same checkout without the
  catalog, and `catalog.json` lists 61 visuals in `catalogOrder`

### Requirement: Android GLES leg

`bundle-legs.mjs android-gles` SHALL write `AndroidGlesShaders.kt` and `index.json`. The Kotlin
file SHALL keep contract version 1.0.0, package `com.beamfall.kit.visuals`, object
`AndroidGlesShaders`, the domains `beamfall.android-gles.catalog.v1` and
`beamfall.android-gles.source.v1` and their payload format, and SHALL name the Oscillux tag and
rev on its second line.

#### Scenario: v0.2.0 regression

- **WHEN** the leg is generated from the v0.2.0 shaders with tag v0.2.0 and rev
  ea319a10f2c4e90cbcf5d64f928a85bd97ae197e
- **THEN** every line after the first matches beamfall-visual-shaders'
  `contracts/android-gles/v1/AndroidGlesShaders.kt`, digests included

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
