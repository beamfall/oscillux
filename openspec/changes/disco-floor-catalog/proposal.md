<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Disco Floor in the release catalog

Tickets: CORE-3263

## Why

The release legs ship only visuals with an entry in `shaders/manifest.json`. Disco Floor lives
only in `shaders/originals/manifest.json`, as one of 23 originals with no catalog entry, so its
CORE-3263 rework reaches the reference hosts and no client. The owner chose to ship it in 0.2.20.

## What Changes

- `shaders/manifest.json` gains a `disco-floor` catalog entry, and the original is marked
  `overrides: true`, so the release set draws the original's shader and effect data under the
  catalog's descriptive fields.
- Descriptive fields, chosen to match the catalog's comparable full-scene visuals (Laser Tunnel,
  Tunnel, Terrain):
  - `name` "Disco Floor".
  - `blurb` matching the original's header.
  - `tier` `flagship`: a full scene with dancers, a mirror ball and beams, like the catalog's
    other multi-element scenes.
  - `input` "frequency + beat": the body reads `bass`, `bassImpact`, `beatPhase` and
    `beatCount`.
  - `overlay` false and `calm` false: an opaque, beat-driven scene.
  - Placed last in `catalogOrder`, after the newest catalog additions.
- The params and their `visual.disco-floor.*` labelKeys (Glow, Sway, Sparkle) are the original's.
- The catalog entry's `body` names the original's file, because no catalog-only body exists. An
  override always draws the original's body with the original's wrapper. The reference-catalog
  test reads each entry's `body` path instead of assuming `visuals/<id>.glsl`.
- The entry carries `post` tuning like every catalog entry. The release set draws the original's
  effect data, which has no `post`, so the shipped look is unchanged.
- The catalog and leg counts go from 61 to 62 visuals, including `ANDROID_GLES_VISUAL_COUNT`; the
  android-gles catalog and source digests are repinned.

## Non-goals

- No change to the shader, its effect data or the 22 other uncatalogued originals.
- No host localization. Hosts resolve `labelKey` with `label` as the fallback, and core carries no
  per-visual strings today.

## Failure modes

- A host with a fixed list of 61 visuals sees a new id. Hosts already take the catalog as data and
  own selection, so they list it or gate it out. The one fixed count found is
  `beamfall-android-ui`'s EGL test harness (`expected 61 shaders`), which its repin to 0.2.20
  updates.
