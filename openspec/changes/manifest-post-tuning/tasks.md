<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: per-visual post tuning in the manifest (CORE-1507)

## 1. Schema

- [x] 1.1 `post` in `tools/shader/manifest.mjs`: exact keys, ranges, effect-off defaults
- [x] 1.2 `bundle-hosts.mjs` copies `post`; `import-visuals.mjs` carries it from upstream

## 2. Data

- [x] 2.1 Per-visual values for the 61 reference visuals in `shaders/manifest.json`

## 3. Checks and docs

- [x] 3.1 Rejection, range-end, default, import and coverage cases in `tools/shader/test-wrap.mjs`
- [x] 3.2 `docs/shader-toolchain.md` and `CHANGELOG.md`

## 4. Close

- [ ] 4.1 `make gate` on the stacked head
- [ ] 4.2 Archive this change (`openspec archive manifest-post-tuning`)
