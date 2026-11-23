<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: Disco Floor in the release catalog (CORE-3263)

## 1. Catalog

- [x] 1.1 `disco-floor` entry in `shaders/manifest.json`, last in `catalogOrder`
- [x] 1.2 `overrides: true` on the original in `shaders/originals/manifest.json`
- [x] 1.3 Counts and digests in the shader tests follow the new release set

## 2. Evidence

- [x] 2.1 `make shader-test` and the leg build list 62 visuals
- [x] 2.2 CHANGELOG entry under 0.2.20
