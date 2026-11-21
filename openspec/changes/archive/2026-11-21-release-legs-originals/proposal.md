<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Release legs ship the rebuilt originals

Ticket: **CORE-2760** (Corvint Tasks, beamfall core queue).

## Why

The `msl`, `glsl300` and `android-gles` legs are built from `shaders/manifest.json` alone, the
imported catalog. The rebuilt visuals in `shaders/originals/manifest.json` mark 61 of those ids
`overrides: true`, but only the reference hosts and the lab merge them in. Every Beamfall client
therefore ships the old shaders: Event Horizon and others render broken or blurry on the web
player, while the lab shows the fixed visual.

## What Changes

- `tools/shader/manifest.mjs` adds `releaseSet(catalog, originals)` and `loadReleaseSet(root)`.
  The set keeps the catalog's visuals, order and transitions. A catalog visual that an original
  overrides takes the original's body, wrapper, header, targets, palette, params, controls,
  tunables, trail decay and post, and keeps the catalog's name, blurb, tier, input, overlay,
  calm, imageCapable and place in `catalogOrder`. Param labels come from the original's controls,
  falling back to the catalog's label. An `imageInput` mismatch, or an override with no catalog
  entry, fails.
- `bundle-legs.mjs` builds every leg from the release set. `emit.mjs` and the android-gles
  contract wrap each visual with its own wrapper.
- `limiter-red-audit.mjs --release` audits the release set; `make limiter-hold-check` and
  `make visual-flash-check` use it, so the legs' shaders are what the flash checks measure.
- Nebula ships the original's detail ladder (seven layers, three to five octaves), so the
  `visual-defaults` nebula requirement changes with it.
- Tests: `test-wrap.mjs` covers the merge; `test-android-gles.mjs` pins the new digests.

## Non-goals

- Shipping the 23 originals with no catalog entry. They need catalog metadata first (follow-up).
- Changing the reference hosts or the lab, which already merge the originals.
