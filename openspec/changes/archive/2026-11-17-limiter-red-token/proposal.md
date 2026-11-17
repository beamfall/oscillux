<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Limiter rations large-area red instead of freezing it

Ticket: **CORE-2382** (Corvint Tasks, beamfall core queue).

## Why

The grant pass applies the red-0 rule: a direction of saturated-red change over the area limit is
never admitted. A held sub-block's trackers do not advance, so it requests the same transition
on every later frame and stays held. Any lasting large-area red change, up or down, is therefore
frozen for as long as the content stays changed: on the web visualizer the petals visual left
pink and orange streaks on screen indefinitely after the palette tour moved it to cyan.

ADR-0232 R5 gives saturated-red *flashes* a budget of zero; R7 forbids frozen frames beyond the
transition duration. The red-0 rule meets R5 by violating R7. A flash is a pair of opposing
transitions, so admitting at most one large-area red transition in any 1 s window meets R5
without freezing.

## What Changes

- The grant pass keeps a red token deficit in `oG.z`. Its refill is the luma refill divided by 8
  (integer), so the token returns no sooner than 8 / (2 x maxFlashHz) s, 1.33 s at the default 3 Hz.
  Red up or red down over the limit is admitted when the red deficit is zero, which sets it to the
  full token. Red never takes or waits for the luma token.
- The reference model (`tools/shader/limiter-model.mjs`) does the same in integer arithmetic, and
  the conformance vectors are regenerated from it.
- Red strobe tests assert at most one large-area red transition in every 1 s window (no red
  flash), and a new test asserts a lasting full-frame red change reaches the output within 1.5 s.

No host uniform or texture format changes: `oG` is already RGBA16UI and its `z` was unused.

## Non-goals

- Calming the visuals that request large-area red changes on every frame (CORE-2382 follow-up).
- Repinning hosts; each host takes the fix with its next Oscillux repin.
