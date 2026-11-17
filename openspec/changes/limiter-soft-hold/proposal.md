<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame flash limiter: held sub-blocks blend into their neighbours

Ticket: **CORE-2231** (P1, Corvint Tasks, beamfall core queue). Owner report 2026-11-16: the web
player's Aurora visual shows rectangular blocks during music.

## Why

A sub-block whose transition is not admitted shows the previous output frame. The output pass
switches between history and input per sub-block, so every held sub-block is a hard-edged
1/64 x 1/36 rectangle of stale picture. On Aurora (480 x 270, 60 fps, 900 frames, synthetic beat
audio) 19 frames carry up to 52 such rectangles along the bright edges, and visuals the limiter
rations harder show them most of the time.

An earlier attempt admitted the sub-blocks that finish a granted rise late. It removed Aurora's
rectangles but raised the pixel auditor's output luminance count in 35 of 84 catalog visuals, so
it was dropped (owner decision 2026-11-16: hold, find another way).

## What Changes

- The output pass feathers each hold one sub-block outward. A pixel of a sub-block that is not
  held, next to a held one, shows `(input * (16 - w) + history * w + 8) >> 4` per channel, where
  `w` (0..15) falls linearly from the held neighbour's edge to the far edge of the pixel's own
  sub-block. Edge neighbours weigh `15 - f` or `f` (`f` the pixel's position in its sub-block in
  sixteenths); corner neighbours the product of the two, `>> 4`; the largest weight wins.
- Held sub-blocks are unchanged: every pixel shows history. The feather only ever holds back
  more of the picture, never less.
- Red is unchanged. A pixel is not blended when its input, its history or the blend is
  red-dominant in 8-bit (`r > g + b`), which every saturated-red pixel is; it shows the input as
  before.
- No pass gains a texture or a uniform and no state texture changes, so hosts take the change by
  re-vendoring the generated passes. Only the `output` pass changes.
- Model tests for the feather; regenerated conformance vectors (output digests change wherever a
  hold has a neighbour that is not held).

## Non-goals

- Changing what is held. Requests, the grant and the tracker state are untouched.
- The host releases and repins (tracked on the ticket).

## Failure modes

- A pixel next to a hold lags its input while the hold lasts and catches up when it ends. The
  trackers of its sub-block follow the input, so that catch-up is not counted. The catalog audit
  bounds it: see the acceptance evidence.
- The output pass reads `T1` nine times a pixel instead of once.

## Acceptance evidence

- `make limiter-check`: model tests, WebGL2 and Metal legs bit-identical to the regenerated
  vectors.
- The catalog audit (`limiter-red-audit.mjs`, 84 visuals) before and after: the sum of the
  per-visual worst-second output luminance counts falls from 1067 to 858; 45 visuals fall and 2
  rise by one, both under 6 a second (event-horizon 4 to 5, photo-veil 3 to 4); visuals over 6 a
  second fall from 49 to 46; the auditor's red counts are unchanged.
- The Aurora probe's worst frame, before and after.

## Rollback

Revert the commits and repin the previous release. No state format changes.
