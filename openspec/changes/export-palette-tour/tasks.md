<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: export the palette tour (CORE-2369)

## 1. Core and C interface

- [ ] 1.1 `oscillux_core::palette` with the tour and the vivid present defaults
- [ ] 1.2 `oscillux_palette_tour`, `oscillux_palette_vivid_present` and the two constants in the
      FFI crate, `ffi/include/oscillux.h` and `ffi/abi-snapshot.txt`

## 2. Bindings

- [ ] 2.1 npm (wasm) `paletteTour` and `vividPresent`
- [ ] 2.2 Java (JNI) `Oscillux.paletteTour` and `Oscillux.vividPresent`
- [ ] 2.3 Binding-coverage rows in `docs/packaging.md`

## 3. Conformance

- [ ] 3.1 `conformance/palette-tour/vectors.json` checked by the core tests and against
      `tools/shader/palette-tour.mjs`
