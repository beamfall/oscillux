<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Per-visual post tuning in the manifest

Ticket: **CORE-1507** (Corvint Tasks, beamfall core queue).

## Why

The post chain belongs to Oscillux, but each visual's post tuning (bloom gain and threshold,
chromatic aberration, vignette, grain) is not in the Oscillux manifest. A host keeps it in its own
catalog, next to policy, so it cannot drop that copy. `trailDecay` already moved; the other post
values have no field to move into.

## What Changes

- `tools/shader/manifest.mjs` accepts an optional `post` object per visual with exactly the keys
  `bloomStrength` (0 to 2), `bloomThreshold` (0 to 4), `chroma` (0 to 0.05), `vignette` (0 to 1)
  and `grain` (0 to 0.25). Unknown, missing or out-of-range keys fail with a path. A visual without
  `post` takes defaults that turn every effect off (strength 0, threshold 1, the rest 0).
- `shaders/manifest.json` gives all 61 reference visuals their values, copied unchanged from the
  current host catalog (all within the ranges). The originals keep the defaults.
- `bundle-hosts.mjs` copies `post` into each bundled visual; `import-visuals.mjs` carries it from
  an upstream catalog's per-visual post block.
- `tools/shader/test-wrap.mjs` covers each rejection, both range ends, the defaults, the import and
  the reference set's coverage. `docs/shader-toolchain.md` documents the field.

## Non-goals

- Wiring the values into the present pass or the reference hosts. The pass still uses a fixed
  bloom threshold and has no vignette; hosts keep bloom, aberration and grain at 0.
- Releasing. A host drops its copy only after an Oscillux release carries this change.

## Rollback

Revert the change. `post` is optional, so manifests without it load as before.
