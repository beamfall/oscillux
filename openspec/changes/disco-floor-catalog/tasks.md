<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: Disco Floor in the release catalog (CORE-3263)

## 1. Catalog

- [ ] 1.1 `disco-floor` entry in `shaders/manifest.json`, last in `catalogOrder`
- [ ] 1.2 `overrides: true` on the original in `shaders/originals/manifest.json`
- [ ] 1.3 Counts and digests in the shader tests follow the new release set

## 2. Evidence

- [ ] 2.1 `make shader-test` and the leg build list 62 visuals
- [ ] 2.2 CHANGELOG entry under 0.2.20
