<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# The frame limiter limits fine patterns that reverse inside a sub-block

Ticket: **CORE-2515** (P1). Found in the 2026-11-18 web visualizer review.

## Why

- The limiter box-reduces the frame to 64 x 36 sub-blocks and tracks each sub-block's mean. A
  pattern finer than a sub-block that inverts (a 10 Hz checkerboard of 4 px squares) keeps every
  mean constant, so it registered nothing and passed unlimited at 10 Hz over the whole frame.

## What Changes

- The `rows` pass also reads the previous output (`uHist`) and counts, per row segment, the
  pixels whose luma code rose by `LUMA_STEP` and those whose luma fell by it, the darker side below
  `LUMA_DARK`.
- The `reduce` pass requests luma up for a sub-block where at least a quarter of its pixels rose,
  and luma down where at least a quarter fell. When both are requested in one frame, the grant
  admits the pair together once the token has also stood unspent for a refill period, and the
  pair leaves two tokens of deficit. (The first cut required 7/16 rising and 7/16 falling; with
  the exact output of CORE-2543 that missed a change over part of a sub-block, which moves the
  mean less than a step but which the pixel auditor counts. Lens reached 7 transitions/s.)
- Host binding: `rows` samples `uHist` at texture unit 1. Hosts bind the previous output there.
- A `fine-checker-10hz` conformance case; vectors re-recorded.

## Non-goals

- Changing how a uniform change in one direction is counted: it moves the mean and the trackers
  catch it as before.

## Failure modes

- Moving texture is held more often. Catalog under loud audio (61 visuals, 480 x 270, with the
  exact output of CORE-2543): 7/16 both ways left Lens at 7 transitions/s (mean held 0.0046);
  3/8 left Dunes at 8 (0.0091); a quarter leaves none over 6 (mean held 0.019, max 0.162 for
  Nebula). Flashes come first, so a quarter ships; reducing the extra holds is a follow-up.
- At a threshold tie the whole-pixel counts can differ by one sub-block column between 1080p and
  4K.
- A host that does not bind `uHist` to the `rows` pass reads an unbound sampler. android-ui
  (CORE-2520), apple-ui (CORE-2521) and core web bind it when they adopt the release.

## Acceptance evidence

- Model tests: a 10 Hz 4 px checker of at least 10 transitions/s in comes out at <= 6, and so
  does a 10 Hz change over 2 of every 5 rows.
- `make limiter-check` (WebGL2 and Metal match all vectors) and `make limiter-hold-check`.
- Catalog `limiter-red-audit.mjs --audio loud` before and after.

## Rollback

Revert the change and cut a patch release; hosts re-vendor and drop the `uHist` binding.
