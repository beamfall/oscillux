<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Export the palette tour and vivid present defaults

Ticket: **CORE-2369** (Corvint Tasks, beamfall core queue).

## Why

The reference hosts' vivid colour mode tours the sixteen vivid palettes (`palette.x < 0`, phase in
`palette.z`, read by `osPalVisual` in `shaders/originals/common.glsl`) and presents at saturation
1.35 and vibrance 1.2. That logic lives only in `tools/shader/palette-tour.mjs` and its Swift port
`hosts/apple/Sources/PaletteTour.swift`; no released package exports it. A product host
therefore either copies effect code, which ADR-0228 forbids, or runs every visual on its static
manifest palette at saturation 1 and vibrance 0, which looks dull next to the Oscillux preview.

## What Changes

- Add `oscillux_core::palette` with `tour(time_seconds, offset) -> [f64; 4]`, the tour constants
  (16 palettes, 6 s each) and the vivid present saturation and vibrance.
- Add the C exports `oscillux_palette_tour` (writes the `palette` uniform) and
  `oscillux_palette_vivid_present` (writes saturation and vibrance), plus
  `OSCILLUX_PALETTE_TOUR_COUNT` and `OSCILLUX_PALETTE_TOUR_SECONDS`. Additive: the ABI version
  stays 1.
- Bind both in the npm (wasm) package as `paletteTour` and `vividPresent`, and in the Java (JNI)
  adapter as `Oscillux.paletteTour` and `Oscillux.vividPresent`.
- Add conformance vectors `conformance/palette-tour/vectors.json`, checked against the Rust core
  and against `tools/shader/palette-tour.mjs`, which the web reference host keeps using.

## Non-goals

- Changing the vivid palettes, the shader read or the present pass.
- Choosing a colour mode for any host; hosts still decide whether to tour.
