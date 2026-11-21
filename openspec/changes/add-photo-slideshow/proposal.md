<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Add a calm photo-slideshow pass

Ticket: CORE-2980 (OSC-PHOTO-SLIDESHOW-1).

## Why

Beamfall shows photo libraries full screen, alone or over music. The photo design asks for a
calm mode: a slow Ken Burns move aimed at what matters in each photo, a small set of quiet
transitions, portraits shown as a pair or on a blurred fill rather than between bars, and music
reactivity off by default. Visual effects live only in Oscillux (ADR-0228), so the math has to
live here, with generated web and Metal legs and conformance vectors like the switch passes.

## What changes

- One portable GLSL source, `shaders/slideshow/slideshow.glsl`, defines `SlideshowInputs` and
  `vec3 slideshow(vec2 uv, SlideshowInputs s)`: Ken Burns aimed at a supplied salient rect,
  three layouts (cover, blurred fill, portrait pair) and three transitions (dissolve, light
  sweep, iris). It returns linear HDR, before bloom, tone mapping and the flash limiter.
- Audio coupling (`amplitude`, default 0) moves only the Ken Burns path position, never light;
  at amplitude 0 the audio inputs are not read.
- 8x8 golden vectors under `conformance/slideshow/`, written by an independent
  standard-library model (`tools/slideshow-vectors.py`), and a check that renders the pass in
  WebGL2 and, on macOS, Metal, compares the goldens, proves amplitude-0 audio independence on
  the GPU, and runs a loud-audio worst-case sequence through the flash limiter model and audit
  (`tools/shader/slideshow-check.mjs`).
- `make slideshow-check`, in `make gate`; the pass is compiled by `tools/shader/verify.mjs` and
  shipped in the `glsl300` and `msl` legs.
- The host-pass contract in `shaders/slideshow/README.md`.

## Non-goals

- Slide timing, photo choice, face or saliency detection, decoding and Reduce Motion selection:
  hosts own those and pass the results in. Tempo-aligned slide changes reuse the existing
  transition scheduler.
- Bloom, tone mapping and the limiter itself are unchanged.

## Failure modes

- The math drifts from the model: the GPU comparison fails beyond the stated tolerance.
- A transition adds too much light: the model's added-light assertion fails.
- Audio leaks into the calm default: the amplitude-0 identity check fails.
- The source stops compiling on a target: the GLSL ES, GLSL 450, MSL and AIR legs fail.

## Rollback

Revert the commits; nothing else depends on the new files. The Makefile change is one target and
one `gate:` line, and the legs lose two files.
