<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame flash limiter: exact output, no hold feather

Tickets: **CORE-2543** (P1), **CORE-2541**, with **CORE-2413** kept open for the hard edges this
brings back (Corvint Tasks, beamfall core queue).

## Why

The trackers count transitions in the input's sub-block means, but the pixels around a hold
showed a blend of the input and the previous output. A blended change therefore reached the
screen frames after the token it spent, sometimes after that token had refilled. A Codex review
(2026-11-18) reproduced 7 large-area luma transitions in 1 s at 128x72 from a steady gray, orange
or blue rise beside held sub-blocks; v0.2.8 does the same. Small red steps finished a red
transition late in the same way (CORE-2541). The owner's priority is no flashes, so the output
must make only the transitions the trackers counted.

## What Changes

- The output pass shows the previous output on a held pixel and the input exactly on every
  other pixel (per-pixel holds since limiter-pixel-trackers; this change first held whole
  sub-blocks). The hold field, its feather and the red feather guard are removed.
- `T1.w` holds only the hold bit. No pass gains or loses a texture or uniform; hosts take the
  change by re-vendoring the generated passes.
- The unreleased `limiter-red-feather` change is dropped.

## Non-goals

- Smooth hold edges. Feathering without delay needs the trackers to measure the feathered output
  (the previous frame's field applied before measurement), which adds a rows-pass binding in every
  host. CORE-2413 tracks it.

## Failure modes

- Hard sub-block edges at holds are visible again. Visuals now keep within the flash budget on
  their own (CORE-2492), so holds are rare.

## Acceptance evidence

- `make limiter-check` (model tests including the CORE-2543 rises and CORE-2541 red case,
  re-recorded vectors, WebGL2 and Metal passes bit-exact with the model), `make
  limiter-hold-check`, `make visual-flash-check`.

## Rollback

Revert the change and cut a patch release; hosts re-vendor.
