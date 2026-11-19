<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame flash limiter: per-pixel transition trackers

Ticket: **CORE-2543** (P1) (Corvint Tasks, beamfall core queue).

## Why

The limiter tracked transitions on 64 x 36 sub-block means, but the pixel auditor tracks every
pixel. Codex review round 7 (2026-11-18) found two changes the auditor counts that the sub-block
trackers miss, both beside red holds:

- A grey cycling 124, 140, 153, 140 on every other row. No single frame moves a luma step, but
  each pixel's tracker accumulates one over two frames: 30 large-area luma transitions a second.
- Changes covering a fifth of some sub-blocks. Each sub-block is under the quarter-of-pixels rule,
  but together they cover 26⅔% of the frame: 20 transitions a second.

The cell window was also smaller than the field it stands for (5 x 3 cells for a 5.33 x 3 field),
so a field straddling cell edges could hold more than a quarter changed pixels while no window
did. The owner's priority is no flashes, so the limiter must count what the auditor counts.

## What Changes

- Every pixel has the auditor's luma and red trackers and four recency stamps, packed in a new
  frame-size RGBA16UI state texture (`uTrack`, ping-ponged). Pixels request a direction when the
  frame would fire their tracker in it; the trackers step on the output.
- Luma and red are measured in 16-bit codes: luma as before, red as `(R - G - B) >> 8` of the
  linear codes when saturated. The auditor measures with the same codes and thresholds, so the
  limiter's trackers equal the auditor's.
- The area gate counts pixels (firing now or recently) per cell. The window is the fewest whole
  cells that contain the field wherever it is placed; the limit is a quarter of the field's pixels.
  `windowOf` takes the frame size.
- The clock counts ticks modulo 240 (15 units of 16 ticks); stamps hold units.
- Holds are per pixel: a pixel whose trackers would fire on the input in a direction the grant
  did not admit shows the previous output, and every other pixel the input, so holds no longer
  show as sub-block tiles (CORE-2492). The output pass no longer reads the sub-block counts.
- Six passes (rows, reduce, cells, windows, grant, output); the state pass and the sub-block state
  textures go. The output pass writes the frame and the new tracker state (two outputs).
- Memory: 8 bytes per pixel, twice for the ping-pong (133 MB at 3840 x 2160), in place of 64 x 36
  sub-block state.

## Non-goals

- A less conservative area test (CORE-2617): the covering window and recent stamps after a grant
  hold some pixels of visuals that keep within the flash limit.

## Failure modes

- Hosts must bind and ping-pong `uTrack`, clear it to "no state yet" (luma lo 65535, hi 0, red
  255 | 0 << 8, stamps 0) on creation, and carry it across a resize (1:1 from the view's anchor at one display
  scale, nearest-neighbour rescaled when the display scale changes).
- More holds where many small areas change at once, since partial coverage now counts in full.

## Acceptance evidence

- `make limiter-check` (model tests including both round 7 reproducers, re-recorded vectors,
  WebGL2 and Metal passes bit-exact with the model), `make limiter-hold-check`, `make
  visual-flash-check`, and a randomized model-versus-auditor run.

## Rollback

Revert the change and cut a patch release; hosts re-vendor and drop the `uTrack` binding.
