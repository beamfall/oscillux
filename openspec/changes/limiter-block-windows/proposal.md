<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame flash limiter: sub-block windows for the over test

Ticket: **CORE-3238** (Corvint Tasks, beamfall core queue).

## Why

A direction is over when a window that contains the field wherever it is placed holds more than a
quarter of the field's pixels. The window is made of whole cells of the 16 x 9 grid, so at 480 x
270 with the WCAG field (120 x 120 px, limit 3600 px) it is 7 x 4 cells, 25,200 px, 1.75 times the
field. Ordinary motion that is not a flash then fills a quarter of the field: on Disco Floor under
loud audio the auditor counts 2 luma transitions a second in the input, yet the limiter reads 63
frames over, one run lasting 37 frames. The token refills about every 10 frames, so 57 frames are
held. The held pixels are the ghost the owner reported, and their release is the jump.

## What Changes

- Hosts pass the window in whole sub-blocks of the 64 x 36 grid in `limiter1.z` (columns) and
  `limiter1.w` (rows), computed like the cell window from the field's texel extent. At 480 x 270
  the WCAG window is 23 x 13 sub-blocks, about 1.17 times the field.
- The cells pass marks each of its sub-block origins whose valid sub-block window holds more than
  the limit, in `C.z`; the windows pass reads that mark instead of summing cells when the host
  passes a sub-block window.
- A host that passes 0 and 0 keeps today's cell windows. No pass gains or loses a texture, a
  uniform or a binding.

## Non-goals

- Changing the hold itself (hold scope, grant or refill). A variant that held only the cells
  under over windows did not change Disco Floor's holds.

## Safety

Every placement of the field's touched texels lies inside some sub-block window of the stated
size, as it did inside a cell window, so the over test still never misses a field over the limit.
The auditor's budgets are unchanged.

## Acceptance evidence

- `make limiter-check` (model tests, re-recorded vectors including a cell-window fallback case,
  WebGL2 and Metal passes bit-exact with the model), `make limiter-hold-check`, `make
  visual-flash-check`.
- The 84 host-bundle originals under loud audio: no visual over 6 luma or 1 red transition per
  second at the output, and fewer held frames than with cell windows.

## Rollback

Hosts send 0 and 0 to restore cell windows without a release; otherwise revert and cut a patch
release.
