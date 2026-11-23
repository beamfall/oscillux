<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: lighter CD+G lettering, fast render (CORE-3260)

## 1. Look

- [x] 1.1 [1, 4, 1] layer blur, threshold 171
- [x] 1.2 Draw a layer only where its index lies in the taps' support
- [x] 1.3 Shadow alpha 110
- [x] 1.4 README spec, oracle and regenerated `conformance/cdg-present/` vectors
- [x] 1.5 Look at 960 x 540 frames from a real disc before and after

## 2. Speed

- [ ] 2.1 Faster presenter, frames bit-identical to 1
- [ ] 2.2 CPU-time guard on a worst-case stream in `frame_budget`
- [ ] 2.3 Measure wasm32 under wazero: 60 frames per CPU second or better on the worst case

## 3. Close

- [ ] 3.1 `make gate`, Codex review
- [ ] 3.2 Release, then archive this change
