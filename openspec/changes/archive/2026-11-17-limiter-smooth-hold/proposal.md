<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame flash limiter: holds blend smoothly in space

Ticket: **CORE-2328** (P1, Corvint Tasks, beamfall core queue). Owner report 2026-11-17: the web
player's Aurora visual still shows staircases of large solid squares during music on v0.2.3.

## Why

The v0.2.3 feather (`limiter-soft-hold`) blends a sub-block beside a hold toward its own history,
at up to 15/16. That is a temporal filter, so after a few held frames the neighbour's picture is
nearly as stale as the hold and the edge is hard again, one sub-block further out. The weight
also takes the largest of the eight neighbours, which steps where two holds meet. On a grey wave
travelling at 6 Hz (320 x 180) the output steps up to 91 levels across a sub-block boundary where
the input steps none.

The shipped Aurora (`shaders/originals/visuals/aurora.glsl`) also trips the limiter constantly:
on the default synthetic audio at 960 x 540 it holds part of the frame on 136 of 300 frames (87
sub-blocks on average). The beat response is only part of it. With all audio inputs off the
limiter still holds on about a sixth of the frames, because the curtain is bright and its thin
sheets and rays sweep across sub-blocks. So the limiter is a constant effect on it, not a safety
net.

## What Changes

- The output pass blends by a hold field that is continuous in space and round. The `state` pass
  writes the field for each sub-block, 0..64: the largest over the held sub-blocks within four of
  it on each axis of `clamp(72 - 4 d2, 0, 64)`, `d2` the squared distance in sub-blocks. It is 64
  at a held sub-block and its eight neighbours and reaches 0 a little past four sub-blocks away.
  The `output` pass takes it bilinearly between the four nearest sub-block centres, scales it to
  `t` in 0..4096, eases it (`w = ((t^2 >> 12) (12288 - 2 t)) >> 12`), and shows
  `(input * (4096 - w) + history * w + 2048) >> 12` per channel. The weight is already 1 where a
  hold begins and falls off with distance in every direction, so no sub-block boundary carries a
  step and a held region has no corners.
- Held sub-blocks are unchanged: every pixel shows history. The blend only ever holds back more
  of the picture, never less.
- Red is unchanged. A pixel is not blended when its input, its history or the blend is
  red-dominant in 8-bit (`r > g + b`); it shows the input.
- No pass gains a texture or a uniform and no texture changes format, so hosts take the change by
  re-vendoring the generated passes. The `state` and `output` passes change. `T1.w` now carries
  the hold in bit 0 and the hold field above it (`hold + 2 * field`).
- A model test bounds the step across sub-block boundaries on a held travelling wave; regenerated
  conformance vectors.
- Aurora is calmed so the limiter rarely holds on it: the curtain is about half as bright
  (`5.0 / n` to `2.4 / n`), the beat and bass terms on the rim, the climbing front, the fold
  pulses and the ripple are reduced, the light and ray reach depend less on the spectrum, and the
  rays are finer (24 to 36 across a fold unit).

## Non-goals

- Changing what is held. Requests, the grant and the tracker state are untouched.
- The host releases and repins (tracked on the ticket).

## Failure modes

- The picture within about four sub-blocks of a hold lags its input while the hold lasts, which
  is wider than before. The catalog audit bounds the effect on the flash counts: see the
  acceptance evidence.
- The `state` pass reads `S` 81 times a sub-block (2304 fragments). The `output` pass reads `T1`
  five times a pixel instead of nine.

## Acceptance evidence

- `make limiter-check`: model tests, WebGL2 and Metal legs bit-identical to the regenerated
  vectors.
- The boundary-step test fails on the v0.2.3 model (`test-limiter.mjs --model`) and passes here.
- The catalog audit (`limiter-red-audit.mjs`, 84 visuals, 360 frames, 480 x 270), v0.2.3 against
  this change, before the Aurora edit: red output transitions unchanged in every visual; frames
  over the red limit 1 to 0; output luminance transitions per second summed over the catalog 858
  to 687, lower in 38 visuals and higher by 1 or 2 in 10 (space-flight, ink, memory-tunnel,
  photo-curtain, photo-gallery, photo-liquid, photo-prism, photo-veil, starfield, strata-ridge),
  none of them newly over 6; visuals over 6 a second 46 to 42.
- The Aurora probe (300 frames, 960 x 540, this limiter): frames with a hold 136 to 20 on the
  default audio (mean held sub-blocks 86.6 to 6.6 of 2304) and 47 on the hard-beat audio (mean
  8.0). The worst limited frame shows no rectangles.

## Rollback

Revert the commits and repin the previous release. No texture format changes; `T1.w` returns to
the hold alone.
