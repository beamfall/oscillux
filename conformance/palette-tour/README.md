<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Palette tour vectors

15 cases of the vivid colour mode's `palette` uniform, evaluated by the reference host's
`paletteTour` in `tools/shader/palette-tour.mjs` (Node, IEEE-754 doubles). No Rust output
generated an expected value. `vividPresent` holds that file's `VIVID_SATURATION` and
`VIVID_VIBRANCE`.

The cases cover offset 0, negative and fractional offsets, the wrap at 16 palettes from both
sides, a palette boundary (5.999 s and 6 s at offset 15), tiny positive and negative times, and
large times. `z` (`want[2]`) is compared within `tolerance`; the other components are exact.

Checked by `crates/oscillux-ffi/tests/palette_ffi.rs` (core and C export),
`tools/shader/test-palette-tour.mjs` (the reference host) and `tools/test-wasm-package.mjs`
(the npm package).
