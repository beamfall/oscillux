<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Add portable switch-transition passes

Ticket: CORE-0141 (VISXFADE0927-SHADERS-1), re-homed to Oscillux under ADR-0228.

## Why

Hosts switch between visuals with four named styles (Luma Key with a photo-key variant, Melt,
Downbeat Cut + Light Leak and Beat Iris). Without one shared source, every host writes its own
math, and the added-light cap set for switch transitions (no more than 0.08 added cell
luminance over the style's plain reference) is not enforced anywhere.

## What changes

- One portable GLSL source, `shaders/switch/switch.glsl`, defines `TransitionInputs` and
  `vec3 transition(int style, vec2 uv, TransitionInputs t)`. It returns linear HDR and bounds
  every style's added light against that style's plain reference by construction.
- 8x8 golden vectors under `conformance/switch-transition/`, written by an independent
  standard-library model (`tools/switch-transition-vectors.py`), and a check that renders the
  shader in WebGL2 (and, on macOS, Metal) and compares (`tools/shader/switch-transition-check.mjs`).
- `make switch-transition-check`, in `make gate`.
- The host-pass contract in `shaders/switch/README.md`.

## Non-goals

- Host integration (scheduling, Reduce Motion selection, photo authorisation): hosts own those.
- Catalog transitions (`shaders/originals/transitions/`) and their manifests are unchanged.
- The host limiter's own 0.08 cell clamp; this change only keeps the passes below it.

## Failure modes

- A style's math drifts from the model: the GPU comparison fails beyond the stated tolerance.
- A style adds too much light: the model's `--check` fails its added-light assertion.
- The source stops compiling on a target: the offline GLSL ES / GLSL 450 / MSL / AIR legs fail.

## Acceptance evidence

The CORE-0141 evidence record (not part of this repository): check
output, a planted-red proof, the contact strip and per-style GPU timings at 1080p.

## Rollback

Revert the commit; nothing else depends on the new files, and the Makefile change is one target
and one `gate:` line.
