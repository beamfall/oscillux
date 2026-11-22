<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: CD+G presentation (CORE-3150)

## 1. Presenter

- [ ] 1.1 `cdg::Presenter`: background detection, eased gradient stage
- [ ] 1.2 Scale4x and fixed-point bilinear magnification, keyed background
- [ ] 1.3 Box-blurred offset shadow and composite

## 2. Command and release

- [ ] 2.1 `crates/oscillux-cdg-render` WASI command
- [ ] 2.2 `oscillux-cdg-render.wasm` release asset in `tools/artifacts.py`

## 3. Checks

- [ ] 3.1 `conformance/cdg-present/` vectors and the portable `cdg_present` test (host and wasm32)
- [ ] 3.2 Look at rendered frames from real-shaped streams

## 4. Close

- [ ] 4.1 `make gate`
- [ ] 4.2 Archive this change after release
