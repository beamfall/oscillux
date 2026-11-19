<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Feedback visuals: frame-rate independent, no edge streaks, high-precision samplers

Ticket: **CORE-2480** (P2), found with CORE-2413 in the same review (owner report 2026-11-18, web visualizations
blocky and smeared, with streaks at the left and right edges). Codex review 2026-11-18 findings 3,
4 and 6.

## Why

- `feedbackTrail` scales its decay by `dt * 60` but applies its zoom and rotation once per drawn
  frame, so a trail turns and zooms twice as fast at 120 Hz as at 60 and half as fast at 30. Ink
  advects, bleeds and injects dye once per drawn frame the same way.
- Rotated or advected history coordinates leave the frame. With clamp-to-edge sampling the edge
  texel repeats across the outside footprint and feedback carries it inward frame after frame:
  streaks that start at the frame's edges.
- The GLSL ES 3.00 visual, present and bloom wrappers leave `sampler2D` unqualified, which
  defaults to `lowp`; HDR feedback reads can then quantize on mobile GPUs. The switch and limiter
  wrappers already qualify their samplers.

## What Changes

- `feedbackTrail` scales zoom as `(1 - zoom)^n` and rotation as `rotAmt * n`, `n = dt * 60`
  capped at 4 (1 without a clock), and fades history sampled outside the frame to zero over 1/32
  of the frame.
- Ink scales its advection step, bleed (`keep^n`, `0.0016 n`) and dye injection by the same `n`,
  and fades history sampled outside the frame the same way.
- The GLSL ES 3.00 visual, present and bloom wrappers declare `precision highp sampler2D`.
- At 60 Hz the trail and Ink are unchanged away from the frame's edges.

## Non-goals

- Other visuals' per-frame feedback integration beyond `feedbackTrail` and Ink.

## Failure modes

- A stalled frame (`dt` large) would jump the trail; `n` is capped at 4.

## Acceptance evidence

- `make shader-test` and the leg regeneration checks.
- Web player screenshots before and after on the Tower at DPR 1 and 2.

## Rollback

Revert the change and cut a patch release; hosts re-vendor.
