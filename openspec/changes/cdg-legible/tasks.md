<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: legible CD+G (CORE-3242)

## 1. Presenter

- [x] 1.1 Sharper edge threshold and ramp
- [x] 1.2 Contrast fix against the backdrop range, white or black mixes
- [x] 1.3 Outline protection, reset on background or palette change

## 2. Checks

- [x] 2.1 README spec, oracle and regenerated `conformance/cdg-present/` vectors
- [x] 2.2 Protection reset test in `cdg_present`
- [x] 2.3 Look at rendered frames from real-shaped streams

## 3. Close

- [ ] 3.1 `make gate`
- [ ] 3.2 Release, then archive this change
