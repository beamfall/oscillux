<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: catalog metadata and an Android GLES leg (CORE-2208)

## 1. Schema and data

- [ ] 1.1 Catalog fields and `catalogOrder` in `tools/shader/manifest.mjs`
- [ ] 1.2 Values for the 61 reference visuals in `shaders/manifest.json`

## 2. Legs

- [ ] 2.1 `catalog.json` in the `msl` and `glsl300` legs
- [ ] 2.2 `android-gles` leg: port the contract generator and its tests

## 3. Checks and docs

- [ ] 3.1 Manifest rejection cases in `tools/shader/test-wrap.mjs`
- [ ] 3.2 Leg byte-identity and the v0.2.0 contract regression
- [ ] 3.3 `README.md`, `docs/shader-toolchain.md` and `CHANGELOG.md`

## 4. Close

- [ ] 4.1 `make gate` on the stacked head
- [ ] 4.2 Archive this change (`openspec archive shader-leg-catalog`)
