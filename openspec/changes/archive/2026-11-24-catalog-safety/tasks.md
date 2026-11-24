<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: catalog photosensitivity data (CORE-3417)

## 1. Data

- [x] 1.1 Loader requires `safety` with the catalog fields; `catalog.json` carries it
- [x] 1.2 Audit measures field luminance delta and band luminance; `--write-safety`, `--check-safety`
- [x] 1.3 Measured blocks written for all 63 visuals; `make visual-safety-check` passes

## 2. Release

- [ ] 2.1 Shader tests and `make gate`; release cut; Apple host repinned onto the catalog data
