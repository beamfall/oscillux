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
- The `reduce` pass requests luma up and down for a sub-block where at least 7/16 of its pixels
  rose and at least 7/16 fell. The grant admits the pair together once the token has also
  stood unspent for a refill period, and the pair leaves two tokens of deficit.
- Host binding: `rows` samples `uHist` at texture unit 1. Hosts bind the previous output there.
- A `fine-checker-10hz` conformance case; vectors re-recorded.

## Non-goals

- Changing how a uniform change in one direction is counted: it moves the mean and the trackers
  catch it as before.

## Failure modes

- Real moving texture that reverses half its pixels can be held more often. The 7/16 threshold was
  chosen over 1/4 and 3/8 because the catalog's held fractions under loud audio stay at baseline
  (mean 0.0046 vs 0.0047; the same four visuals over 6 transitions/s); 1/4 more than doubled them.
- A host that does not bind `uHist` to the `rows` pass reads an unbound sampler. android-ui
  (CORE-2520), apple-ui (CORE-2521) and core web bind it when they adopt the release.

## Acceptance evidence

- Model test: a 10 Hz 4 px checker of at least 10 transitions/s in comes out at <= 6.
- `make limiter-check` (WebGL2 and Metal match all vectors) and `make limiter-hold-check`.
- Catalog `limiter-red-audit.mjs --audio loud` before and after.

## Rollback

Revert the change and cut a patch release; hosts re-vendor and drop the `uHist` binding.
