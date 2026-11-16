# Frame flash limiter: zero red budget and a 10° flash-area model

Tickets: CORE-0125 (red budget of zero, P1, launch-blocking) and CORE-0121 (WCAG 10° flash-area
model), both in `queue:core:main`.

## Why

Hosts limit flashes on the presented frame with a per-frame GPU pass that has so far lived in a
host (the web host's 16×9 cell limiter). That pass has two defects. A red transition over the area
threshold is admitted by the same token that rations luminance flashes, so a saturated-red strobe
gets up to six red transitions a second (CORE-0125). The area gate asks for 20% of the whole frame
from 16 point taps per cell, so a strobe over a quarter of a 10° visual field but under a fifth of
the frame passes, a checkerboard that inverts inside a cell reads as a constant mean, and a thin
moving edge counts differently at 1080p and 4K (CORE-0121).

## What Changes

- A portable GLSL frame limiter under `shaders/limiter/` (box reduction, cell counts, grant, state,
  output), generated for GLSL ES 3.00 and, through the pinned glslang + SPIRV-Cross, for Metal.
- A deterministic reference model, `tools/shader/limiter-model.mjs`, and conformance vectors under
  `conformance/limiter/frame/`. The gate checks the model and the WebGL2 pass against them.
- Red over the area limit has its own budget with refill 0: it is always held and never takes or
  waits for the luminance token. Luminance behaviour is unchanged.
- The area gate is the worst window the size of a 10° field, at 25% of that field, with a
  documented reference geometry per device class. Every pixel contributes to a 64×36 sub-block
  grid, and each sub-block is tracked, so phase reversal inside a 16×9 cell is seen.

## Non-goals

- Changing the CPU `FlashAnalyzer` (`crates/oscillux-core/src/limiter/`) or its vectors.
- Partial holds: a held sub-block shows the previous output frame, where the web host blended
  toward a cell mean.
- Detecting patterns finer than one sub-block (1/64 of the width, 1/36 of the height); they
  average out in the box reduction.
- Wiring the pass into a reference host; hosts consume it in their own changes.

## Failure modes

- Large-area saturated red can never rise more than one red step above its running minimum: a
  visual that turns most of a 10° field deep red is frozen in those sub-blocks. This is the red-0
  rule's cost; the catalog audit reports how often it happens.
- A host that does not clear the state textures on start or resize reads stale trackers; the pass
  holds nothing until a tracker is live, so a cleared state is safe and an uncleared one is not.
- A source narrower than 64 or shorter than 36 pixels has empty sub-blocks; hosts must not run the
  pass below that size.
- JS and GPU results agree bit for bit because every decision uses integer codes; a change to the
  luminance table or quantization breaks that and fails the vector check.

## Acceptance evidence

- `make limiter-check`: the model reproduces `conformance/limiter/frame/`, the model tests pass
  (red 0 per 1 s window at 3 Hz and 10 Hz; luminance 3 Hz unchanged; 10° TV strobe, half-cell
  checkerboard and 1080p/4K bar), and the WebGL2 pass matches the vectors in Chromium.
- The three CORE-0121 cases fail against the parent commit's model.
- The CORE-0125 and CORE-0121 evidence records.

## Rollback

Revert the commits. No host consumes the pass yet, and no stored state or wire contract depends
on it.

## Capabilities

### New Capabilities

- `frame-limiter`: the per-frame GPU flash limiter, its reference model and its vectors.

### Modified Capabilities

None.
