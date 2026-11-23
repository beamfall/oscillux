<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## MODIFIED Requirements

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
