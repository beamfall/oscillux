<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# CD+G presentation

Ticket: **CORE-3150** (Corvint Tasks, beamfall core queue).

## Why

Beamfall composes CD+G karaoke into an H.264 picture on the server (ADR-0057), which every
client plays. Today ffmpeg magnifies the 300 x 216 indexed screen with xBR and fills the
pillarbox with black. Lyrics read, but the disc's flat background, its hard border and the
missing depth look dated next to the rest of the app. Open-source players (bhj/cdgraphics,
mik3y/cdgraphics) expose the detected background colour so a host can key or extend it, and
karaoke software commonly adds an offset drop shadow under the lyric text. Oscillux is the only
source of visual effects, so the look belongs here, not in ffmpeg filter strings in core.

## What Changes

- Add `cdg::Presenter` in `oscillux-core`. It allocates once in `Presenter::new(width, height)`
  and `present(&decoder, seconds, out)` writes one opaque RGBA8 frame with no allocation, lock
  or I/O, in integer arithmetic only.
- Detect the background index from the window edge ring: the Memory Preset colour when it covers
  at least half the ring, otherwise the most common ring index (ties to the lowest index).
- Draw the stage, which fills the whole frame, in the background colour as a soft vertical
  gradient (lighter at the top, darker at the bottom). When the background colour changes the
  stage eases to the new colour over 300 ms of media time; a backwards seek or the first frame
  snaps.
- Magnify the window with Scale4x (EPX applied twice) on the index buffer, then sample it
  bilinearly in fixed point into a centred 3:2 rectangle of the frame height. Background-index
  pixels are transparent, so the stage shows through and the frame has no pillarbox or border.
- Add a soft drop shadow: the non-background mask, box blurred, offset down and right and drawn
  in translucent black under the graphics.
- Add the `oscillux-cdg-render` command (WASI): it reads a `.cdg` stream on stdin and writes raw
  RGBA frames at a fixed rate to stdout for a given size, start time and tempo, holding the last
  frame until stdout closes. Release it as `oscillux-cdg-render.wasm` (wasm32-wasip1).
- Add `conformance/cdg-present/` vectors (background choice and frame digests) checked by a
  portable test on the host and on wasm32.

## Non-goals

- Client-side rendering of the `.cdg` stream (the decision for CORE-3150 is server video).
- Changing the decoder, its key modes or the existing CD+G composite shader.
- Colour grading or any effect beyond background, gradient, shadow and magnification.
