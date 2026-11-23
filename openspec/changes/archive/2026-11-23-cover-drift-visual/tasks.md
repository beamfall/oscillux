<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: Cover Drift visual (CORE-3286)

## 1. Visual and manifest

- [x] 1.1 Add `shaders/visuals/cover-drift.glsl` with SPDX header, `motionCentered`, 4 averaged quadrant fields, 90 s rotation, 40–120 s Lissajous drift, ±6% `u.level` breath, and slight vignette
- [x] 1.2 Add `cover-drift` entry and `catalogOrder` placement in `shaders/manifest.json`
- [x] 1.3 Register `cover-drift` in `hosts/categories.json` and `conformance/shaders/beat-lint.json`

## 2. Generated legs, counts, and docs

- [x] 2.1 Update `ANDROID_GLES_VISUAL_COUNT` (63) and regenerate Android GLES payload digests in `tools/shader/test-android-gles.mjs`
- [x] 2.2 Update visual counts in `tools/shader/test-wrap.mjs`, `README.md`, `docs/shader-toolchain.md`, and `CHANGELOG.md`

## 3. Verification and closeout

- [x] 3.1 Run `openspec validate --all --strict`, `make spdx`, `make shader-test`, `make shader-verify`, `make shader-render`, `make shader-beat-lint`, and `limiter-red-audit.mjs` on `cover-drift`
- [ ] 3.2 Run `make gate` on the exact head before merging
- [ ] 3.3 Run `openspec archive cover-drift-visual` after landing
