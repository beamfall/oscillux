<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Particles stops tiling under the frame limiter

Ticket: **CORE-2409** (Corvint Tasks, beamfall core queue).

## Why

The catalogue Particles (`shaders/visuals/particles.glsl`, the one the msl, glsl300 and
android-gles legs carry) multiplies its bass ring by up to 10x on a beat, its treble ring by
up to 7x on an onset, and throws a 0.2 to 0.5 burst on bass impacts. Each beat is a large-area
luminance flash, so the frame limiter holds up to 23% of its 64 x 36 sub-blocks. The red-dominant
emberIce embers are exempt from the hold feather, so those holds show as hard square tiles: the
mosaic seen on the Beamfall web player at 1280 px (CORE-2409). Neither `beat-lint` nor the red
audit measured this leg: both default to the merged host bundle, where
`shaders/originals/visuals/particles.glsl` overrides it.

## What Changes

- Particles' bass ring brightens by at most 2x on a beat and bass impact (was 10x), the other
  rings by 1.3x (was 2.6x), the treble ring by 2.1x on onset and treble (was 7x), and the
  burst scale is 0.06 to 0.15 (was 0.2 to 0.5). It still passes `beat-lint`.
- The per-particle streak fades in behind the particle over its core instead of a hard
  `along < 0` cut, whose seam the feedback trail smeared into wedges (from CORE-2392).
- The feedback trail no longer rotates on beats and bass impacts: turning the whole trail
  field changed every pixel at once (from CORE-2392).
- Bass embers take a fixed 35% of the ember tint (was 70% to 95% with bass impact), so less of
  the frame is red-dominant and exempt from the limiter's hold feather (from CORE-2392).
- `limiter-red-audit.mjs` gains `--audio loud` (a kick-driven loud mix) and `--max-held F`
  (exit 3 when any frame holds more than F of the sub-blocks). `make limiter-hold-check` runs
  the release-leg Particles with a 5% budget and is part of `make gate`.
- `beat-lint.mjs` parses its command line only when run directly, so importers keep their own.

Measured with `limiter-red-audit.mjs shaders/manifest.json --only particles --beats 24` at
480 x 270 (720 frames), before and after:

| Audio | Red-over frames in / out | Luma over in / out | Held mean | Held max |
|---|---|---|---|---|
| lint | 24 / 5 to 35 / 3 | 5 / 8 to 2 / 4 | 0.0062 to 0.0026 | 0.102 to 0.062 |
| loud | 1 / 1 to 0 / 0 | 8 / 8 to 3 / 4 | 0.031 to 0.0012 | 0.231 to 0.020 |

Without the ember tint the calmer brightness left more of the frame red-dominant on the lint
audio (152 / 13 red-over frames, held mean 0.012), so the tint change is part of the fix.
