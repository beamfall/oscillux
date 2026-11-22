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

- Add `cdg::present::Presenter` in `oscillux-core`. `Presenter::new(width, height)` allocates
  once, and `present(&decoder, millis)` returns one opaque RGBA8 frame with no allocation, lock
  or I/O, in integer arithmetic only (`conformance/cdg-present/README.md` is the exact
  algorithm).
- Detect the background index from the window edge ring: the Memory Preset colour when it covers
  at least half the ring, otherwise the most common ring index (ties to the lowest index). Any
  index covering at least a quarter of the ring also joins the backdrop set, so a painted
  backdrop of two colours is not drawn as graphics.
- Replace the disc's flat colour with a modern backdrop that fills the whole frame: a dark base
  tinted by the background colour, two soft glows (one lighter, one warmer) that drift slowly
  with media time, and a vignette. It is evaluated every 8 pixels and interpolated, and ordered
  dithered to 8 bits. When the background colour changes the backdrop eases to the new tint over
  300 ms of media time; a backwards seek or the first frame snaps.
- Magnify the window with an ink-priority Scale2x on the index buffer, then draw it as layered
  coverage: each colour, in rank order, gets a box-blurred mask sampled bilinearly in fixed point
  into a centred 3:2 rectangle of the frame height and thresholded with a ramp scaled to the
  output size. Letters get round corners and smooth edges without dark seams between colours,
  and the rectangle's edges feather into the backdrop, so there is no pillarbox or border.
- Add a soft drop shadow: the mask of high-contrast ("ink") pixels, blurred twice, offset down
  and right and drawn in translucent black under the graphics.
- Cache the graphics and shadow composite until the decoder's screen or colours change, so a
  steady frame only redraws the backdrop.
- Add the `oscillux-cdg-render` command (WASI): it reads a `.cdg` stream on stdin and writes raw
  RGBA frames at a fixed rate to stdout for a given size, start time and tempo, either a given
  number of frames (`--frames`) or until stdout closes. Release it as
  `oscillux-cdg-render.wasm` (wasm32-wasip1).
- Add `conformance/cdg-present/` vectors (background and backdrop choice, frame digests) made by
  an independent Python oracle, checked by a portable test on the host and on wasm32 and by
  `make gate`.

## Non-goals

- Client-side rendering of the `.cdg` stream (the decision for CORE-3150 is server video).
- Changing the decoder, its key modes or the existing CD+G composite shader.
- Audio-reactive motion. The backdrop drifts with media time only.
