<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Cover Drift: a calm, cover-coloured drifting background

Tickets: CORE-3286

## Why

The Beamfall tvOS music player needs a calm, default background behind white typography that takes
its palette from the active album cover without showing any artwork detail, text, or hard edges —
modelled on Tidal's Apple TV player background. Existing photo visuals in `shaders/manifest.json`
keep recognizable photo structure or beat-driven elements.

## What Changes

- Add `shaders/visuals/cover-drift.glsl`: samples 4 quadrant colour fields from `IMG` via
  `photoCover` using a 3×3 multi-tap average per quadrant (so only mean colours are read, never
  detail), renders them as 4 broad Gaussian radial blobs over a dark base with a slight vignette,
  rotates the arrangement around the frame centre (90 s per full turn at default Speed), drifts
  each blob on an independent slow Lissajous path (periods 47–113 s), and applies at most a ±6%
  brightness breath from `u.level` with zero beat, onset, kick, or flux terms.
- Add `cover-drift` to `shaders/manifest.json` (`imageInput: true`, `imageCapable: true`,
  `calm: true`, `overlay: true`, `input: "image + level"`, `tier: "lite"`, `targets` matching
  `photo-veil`, `palette: [10, 0, 10, 0]`, `params` Speed/Softness/Glow with
  `visual.cover-drift.*` label keys, `tunables: ["motion"]`, `trailDecay: 0`, and `post` tuning),
  and place it next to the other photo visuals in `catalogOrder`.
- Register `cover-drift` in `hosts/categories.json` (`["photo", "calm"]`) and as ambient in
  `conformance/shaders/beat-lint.json`.
- Update the release catalog visual count from 62 to 63 (`ANDROID_GLES_VISUAL_COUNT`,
  `test-wrap.mjs`, `test-android-gles.mjs` regenerated digests, `README.md`,
  `docs/shader-toolchain.md`, `CHANGELOG.md`).

## Non-goals

- No new uniform, uniform-packing schema change, or C ABI change.
- No host wiring or tvOS player UI code in Oscillux; hosts select `cover-drift` via the catalog.
- No change to the present pass, bloom, or frame flash limiter.

## Failure modes

- Bright or near-white album cover washing out white text: each sampled quadrant colour is
  soft-compressed by its luminance (`0.14 / (0.35 + luma(c))`) and multiplied by a slight
  vignette so displayed frame luma stays roughly 0.08–0.35 at default Glow.
- High-contrast cover text/edges leaking into the background: each field averages 9 fixed taps per
  quadrant independently of fragment position `uv`, and the spatial field is purely radial
  Gaussians, so no image detail can appear.
- Missing image or black artwork: each field is lifted toward a dim slate when its luma is under
  0.05, so a black or unbound cover renders at mean displayed luma ~0.13 (measured with
  `render.mjs --img` on an 8×8 black PNG) instead of an empty black frame.
- Silent audio: `u.level = 0` holds the breath at 0.94× and time-based drift continues smoothly.
- Reduce Motion: the visual derives drift and rotation from `u.time`, so it keeps moving unless
  the host pauses the visual clock; the hosts' Reduce Motion damping slows it but does not freeze
  it. A frozen frame needs a paused clock, which needs no feedback trail here.
- Consumers pinning exact catalog counts (e.g. `ANDROID_GLES_VISUAL_COUNT`, Android EGL tests)
  observe 63 visuals instead of 62 when repinning to the next release.

## Acceptance evidence

- `openspec validate --all --strict` passes.
- `make shader-test`, `make spdx`, `make shader-verify`, `make shader-render` (WebGL2 + Metal smoke),
  `make shader-beat-lint`, and `limiter-red-audit.mjs --release --only cover-drift --audio loud --max-luma 0`
  pass on the committed head.
- `render.mjs --only cover-drift --frames 1 --img <black|white 8×8 PNG>` keeps mean displayed
  luma inside 0.08–0.35 (0.132 black, 0.297 white).

## Rollback

Revert the `core-3286-cover-drift` commit (removing `shaders/visuals/cover-drift.glsl`, the
manifest/category/beat-lint entries, and restoring the 62-visual count and android-gles digests).
No persistent state or ABI changes are introduced.
