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
- Luma and red are measured in integer codes, and the codes are the measure: luma in 15 bits, red
  as `(R - G - B) >> 8` of the linear codes wherever `R > G + B`, a red step counting only when the
  new state or one since the pixel's last red fire is saturated red (a superset of WCAG's
  saturated-red transitions; orange to orange is not red), with WCAG's thresholds at the nearest
  code. Bit 15 of the luma-hi word carries the saturated state. The auditor measures with the
  same codes and thresholds, so the limiter's trackers equal the auditor's.
- A channel's pixels changing in either direction count together (combined area), and a
  viewing-geometry change writes `G` fully spent (Codex round 12).
- Recency stamps live 5 units, so the coverage interval's whole span counts.
- The area gate counts pixels (firing now or recently) per cell. The window is the fewest whole
  cells that contain the field wherever it is placed; the limit is a quarter of the field's pixels.
  `windowOf` takes the frame size.
- The clock counts ticks modulo 240 (15 units of 16 ticks); stamps hold units.
- Holds are per pixel: a pixel whose trackers would fire on the input in a direction the grant
  did not admit shows the previous output, and every other pixel the input, so holds no longer
  show as sub-block tiles (CORE-2492). The output pass no longer reads the sub-block counts.
- Six passes (rows, reduce, cells, windows, grant, output); the state pass and the sub-block state
  textures go. The output pass writes the frame and the new tracker state (two outputs).
- The Particles hold budget (`visual-defaults`) moves from 5% of sub-blocks to 20% of the frame's
  pixels, since holds are now counted per pixel (`make limiter-hold-check --max-held 0.20`).
- Memory: 8 bytes per pixel, twice for the ping-pong (133 MB at 3840 x 2160), in place of 64 x 36
  sub-block state.

## Non-goals

- A less conservative area test (CORE-2617): the covering window and recent stamps after a grant
  hold some pixels of visuals that keep within the flash limit.

## Failure modes

- Hosts must bind and ping-pong `uTrack`, start it at zero (tracked black) with the output
  black and `G` written fully spent, and never clear it or `G` under a frame on screen. Any change
  to the frame (its size, its display scale or the texels in view) takes one path: fade the frame
  to black through the limiter (`G` written fully spent, an area limit of 0, black fed in, until
  a frame of the fade shows black at every pixel, which the grant word's held bits report; a
  host that does not read the word fades for more than two frames past the red token's refill,
  in the time the limiter is credited with, and no host fades for longer than that), present
  black without running the limiter for longer than
  the coverage interval, counted from the first black frame presented, then start again at the
  latest size. A change during the fade or the black only moves that target. Nothing is copied
  from one frame to the next, and a lost context restored starts the same way, from the black.
- A change to the frame costs the picture: it is held until the limiter grants its fall, black
  until the start, and then rises through the grant like a first frame. The times are the
  limiter's credited time, not the clock's. The Beamfall web host cannot read the display's
  refresh period, or measure it from its animation frames, and credits half of each interval at
  a steady cadence, so at 60 frames a second
  and the default 3 Hz its 0.1 s of black is about 0.2 s on the clock; a frame with luma to drop
  is held about 0.7 s before it and a saturated red one about 2.7 s (the red token's refill of
  1.33 s credited); and the cap on the fade, 2 s credited, is about 4 s. A frame whose
  trackers hold nothing a step above black is black within a frame or two and starts after the
  0.2 s; a dark frame that still holds an earlier peak waits for its fall like a lit one.
- A display-scale change is the user's: the browser rescales the last frame before the host can
  react, which the limiter does not control.
- More holds where many small areas change at once, since partial coverage now counts in full.

## Acceptance evidence

- `make limiter-check` (model tests including both round 7 reproducers, re-recorded vectors,
  WebGL2 and Metal passes bit-exact with the model), `make limiter-hold-check`, `make
  visual-flash-check`, and a randomized model-versus-auditor run.

## Rollback

Revert the change and cut a patch release; hosts re-vendor and drop the `uTrack` binding.
