<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame flash limiter: dim a held pixel instead of freezing it

Tickets: **CORE-2543** (the per-pixel limiter this corrects) and **CORE-2492** (visuals within
the flash budget at the source), for context (Corvint Tasks, beamfall core queue).

## Why

The owner tested v0.2.9 in Beamfall web. Under loud audio the visuals showed a patchwork of
frozen fragments (old ring segments, smears, stair-stepped wedges) over live content. The output
pass shows the previous output at every pixel whose trackers would fire in a direction the grant
did not admit. Grants are scarce (about three a second), so most moving pixels freeze one by one
at an old colour while calm pixels beside them keep updating. In the catalogue under loud audio
6 to 15 percent of the pixels are held on an average frame, up to 30 percent on the worst.

## What Changes

- A held pixel shows the input moved as little as needed so that its trackers fire only in
  directions the input fires and the grant admitted:
  1. the input's colour with its luma moved into the band the pixel's luma tracker allows,
     scaled toward black to lower it or mixed with the least of the previous output that raises
     it there (mixing toward white was tried: it turns the held remains of coloured content, and
     the whole frame during a fade, grey);
  2. if that colour still fires (a red transition, or a rounding edge), the largest safe mix of
     it from the grey of the same luma;
  3. if that grey fires too, the largest safe mix of the input from the previous output, which
     never fires.
- The guarantee is unchanged and holds by construction: on every frame a pixel's trackers fire
  on the output only what they fire on the input and the grant admitted, which is what v0.2.9
  guaranteed. Trackers still step on the colour shown.
- The reference model, `shaders/limiter/output.glsl` and `common.glsl` change together, and the
  vectors are re-recorded. The rows, reduce, cells, windows and grant passes, every texture
  binding, the uniforms and the ABI are unchanged; hosts take the change by re-vendoring the
  generated passes.
- The unarchived `limiter-exact-output` delta is reworded so that it requires the input on every
  pixel that is not held and leaves a held pixel to "Per-pixel holds".

## Non-goals

- More grants. The budget (6 luma, 1 red transition a second) and its counting do not change.
- Removing every trace of a held frame. A pixel denied a fall must stay within one luma step of
  its peak, so bright content that has moved away stays as a ghost one step dimmer until a fall
  is granted; a pixel denied a rise shows the input at most one step above its low. Smooth hold
  edges stay with CORE-2413.

## Failure modes

- Held regions show the current frame at reduced contrast, and a bright area that went dark
  stays lit one step lower, in the colour it had, until the next grant.
- The output pass does more work on a held pixel (up to three 8-step searches). The cost is
  measured and recorded in `shaders/limiter/README.md`.
- A held pixel whose tracker has no history (first frames, reset) falls back to the previous
  output, as in v0.2.9.

## Acceptance evidence

- `make limiter-check` (model tests for the dimmed hold and the unchanged bound, re-recorded
  vectors, WebGL2 and Metal passes bit-exact with the model), `make limiter-hold-check`, and the
  catalogue audit (`tools/shader/limiter-red-audit.mjs`): no visual's output over 6 luma or 1 red
  transition a second.
- Contact sheets of catalogue visuals under loud audio, v0.2.9 beside this change.

## Rollback

Revert the change and cut a patch release; hosts re-vendor.
