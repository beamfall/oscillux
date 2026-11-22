<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: CD+G presentation (CORE-3150)

## 1. Presenter

- [x] 1.1 `cdg::present::Presenter`: background index, backdrop indices, eased stage
- [x] 1.2 Ink-priority Scale2x and layered coverage magnification
- [x] 1.3 Blurred offset ink shadow, cached graphics overlay
- [x] 1.4 Drifting glow backdrop with vignette and ordered dither

## 2. Command and release

- [x] 2.1 `crates/oscillux-cdg-render` WASI command
- [x] 2.2 `oscillux-cdg-render.wasm` release asset in `tools/artifacts.py`

## 3. Checks

- [x] 3.1 `conformance/cdg-present/` oracle, vectors, `make cdg-present-vectors-check` and the
      portable `cdg_present` test (host and wasm32)
- [x] 3.2 No allocation while presenting (`cdg_realtime`)
- [x] 3.3 Look at rendered frames from real-shaped streams

## 4. Close

- [ ] 4.1 `make gate`
- [ ] 4.2 Archive this change after release
