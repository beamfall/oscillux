<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Overlay conformance

Host UI (menus, captions, text) sits over the visuals in up to 8 **overlay regions**. The
contract guarantees text contrast inside them, calms motion and flashes there, and honours the
viewer's reduced-motion preference. Regions and the config are data: which UI is shown, and
where, stays with the host (OSC-OVERLAY).

## Contract

A region is a rounded rectangle in normalized viewport coordinates, origin top-left: `x`, `y`,
`width`, `height` (finite, >= 0), `corner_radius` and `feather` (in [0, 1], fractions of the
viewport height), `strength` in [0, 1] and `mode` bits:

| Bit | Name | Effect at full strength |
|---|---|---|
| 1 | light text | background luminance held at or below the ceiling |
| 2 | dark text | background luminance held at or above the floor |
| 4 | desaturate | chroma removed |
| 8 | blur | blur of 0.012 viewport heights |
| 16 | damp motion | keeps 0.9 of the previous presented frame per 60 Hz frame |
| 32 | damp flash | luminance step at most 0.01 per 60 Hz frame; stricter flash-analyzer area |

Light and dark text are exclusive; `reserved` is 0. The config holds the viewport, the WCAG
contrast ratio `r` in [1, 21] (default 4.5), the host's presentation intensity in [0, 1], the
frame interval in (0, 1000] ms, the output alpha, the output levels (0 for a float target or
2 to 65535) and the reduced-motion and premultiplied-alpha flags.

Bounds (WCAG relative luminance, tightened by 1e-4 so GPU rounding cannot cross them):

    ceiling = 1.05 / r - 0.05 - 1e-4      light text: 0.18323 at r = 4.5
    floor   = 0.05 * r - 0.05 + 1e-4      dark text:  0.17510 at r = 4.5

Damping is stated per 60 Hz frame and scaled by `frames = min(dt / (1000 / 60), 1)`:
`keep(k) = 1 - (1 - k) * frames` and `step(s) = s * frames`. Reduced motion applies
`keep(0.6)` and `step(0.04)` everywhere, halves the presentation intensity, and tightens a flash
config to at most 1 flash a second, 0.1 of the field and 1 red flash a second (never loosening
it).

## Vectors

- `conformance/packing/overlay-uniforms.schema.json`: the 320-byte std140 `OverlayUniforms`
  block `shaders/present/present.glsl` reads.
- `conformance/packing/overlay-uniforms.json`: packed bytes for 11 configs and 13 refusals, and 7
  flash-mask cases (which analyzer grid cells damp-flash regions cover, feather included). Written
  by `tools/overlay-uniforms-vectors.py`; checked by `crates/oscillux-core/tests/overlay_uniforms.rs`,
  the C API test `crates/oscillux-ffi/tests/overlay_ffi.rs` and the npm smoke
  `tools/test-wasm-package.mjs`.
- `conformance/limiter/overlay-sequences.json`: overlay regions as a stricter flash area
  (`conformance/limiter/README.md`, "Overlay regions"). Written by
  `tools/limiter-overlay-vectors.py`; checked by `crates/oscillux-core/tests/limiter_overlay.rs`.

`make overlay-vectors-check` (part of `make gate`) fails when either file differs from its
standard-library model.
