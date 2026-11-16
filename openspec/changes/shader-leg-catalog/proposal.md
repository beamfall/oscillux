<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Catalog metadata and an Android GLES leg in the shader release legs

Ticket: **CORE-2208** (Corvint Tasks, beamfall core queue).

## Why

Beamfall keeps a separate repository, beamfall-visual-shaders, whose only remaining jobs are to
join its catalog copy (name, blurb, tier, input, overlay, calm, imageCapable and the catalog
order) with the Oscillux manifest and to generate the Android GLES contract
(`AndroidGlesShaders.kt`) from the Oscillux wrapper. Every shader in that contract already comes
from Oscillux (ADR-0228). Moving the descriptive fields and the generator into Oscillux lets
hosts take everything from the release legs and retires the extra repository.

## What Changes

- `tools/shader/manifest.mjs` accepts optional per-visual `name`, `blurb`, `tier`
  (`lite`, `standard` or `flagship`), `input`, `overlay`, `calm` and `imageCapable`. The first six
  come together or not at all; `input` names `image` exactly when `imageInput` is true. A
  top-level `catalogOrder` lists every visual id once, in display order.
- `shaders/manifest.json` carries those fields for all 61 visuals and the order, copied unchanged
  from the beamfall-visual-shaders catalog. Visual order in the manifest and every emitted shader
  byte stay as they are.
- `tools/shader/bundle-legs.mjs` adds `catalog.json` to the `msl` and `glsl300` legs and a third
  leg, `android-gles`, holding `AndroidGlesShaders.kt` (contract 1.0.0, package
  `com.beamfall.kit.visuals`, the same domains and payload format), released as
  `oscillux-android-gles.zip`.
- The contract generator and its tests move from beamfall-visual-shaders to
  `tools/shader/android-gles-contract.mjs` and `tools/shader/test-android-gles.mjs`, run by
  `make shader-test`.

## Non-goals

- Changing any shader, the manifest's visual order, the host bundle or the C interface.
- Changing the Android contract's version, domains, payload layout or Kotlin shape.
- Retiring beamfall-visual-shaders itself or repinning consumers; that follows a release.

## Failure modes

- A manifest whose catalog fields are partial, mistyped, or disagree with `imageInput` fails to
  load with the path of the fault; `bundle-legs.mjs` then emits nothing.
- A visual with no catalog fields, or a param with no control that the 1.0.0 contract has no
  label for, fails the `android-gles` leg instead of emitting a partial contract. Contract 1.0.0
  lists three params per visual; two visuals (cymatics-prism, spectral-city) read none, so their
  1.0.0 labels stay in the generator as a fixed table rather than becoming manifest controls.

## Acceptance evidence

- The `msl` and `glsl300` legs are byte-identical to the previous head apart from the new
  `catalog.json` and its index entry.
- The `android-gles` leg, run with tag v0.2.0 and rev
  ea319a10f2c4e90cbcf5d64f928a85bd97ae197e, matches beamfall-visual-shaders'
  `contracts/android-gles/v1/AndroidGlesShaders.kt` after its first (generator) line.
- `make shader-test` passes.

## Rollback

Revert the change. The new manifest fields are optional and the new leg is additive.
