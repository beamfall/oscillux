<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Owed red changes expire at a host restart after 1.25 s of exact black

Tickets: **CORE-2869** (P1, covers CORE-2484), Corvint Tasks, beamfall core queue.

## Why

A host starts the trackers at zero, whose red memory is unknown. Under unknown memory a red step
counts at once and again at the first saturated state. After every start, a dark red glow or an
unsaturated red change therefore asks the grant for red transitions the viewer never saw as a
flash, and the web player holds those pixels frame after frame (the post-start red trickle).

The owner approved "owed red changes expire after 1 s of black" (2026-11-21). The first build
expired them per pixel during playback, and Codex round 3 found two P1s:

1. The auditor expired a pixel's memory while the running limiter kept it. After a black start,
   100 frames each of black, (60, 0, 0), black and (110, 64, 0), then (90, 0, 0) and black, passed
   two red transitions 16.7 ms apart: the limiter charged the orange rise, the auditor charged the
   (90, 0, 0) state instead, and the refilled grant then admitted the fall.
2. The black predicate (luma code under one step, red code 0) accepted (5, 0, 0), which is
   saturated red. A saturated state shown after the black was then forgotten.

Both come from expiring during playback with a loose black. This change expires only where the
limiter itself restarts, and only after exact black.

## What Changes

- **Restart events only.** A host restarts the limiter at its first start and after every frame
  change (fade, black, start). Before a restart it presents exact black, without running the
  limiter. When that black has been on screen for at least `RED_EXPIRE_MS` = 1250 ms, it starts
  the trackers at "black, nothing owed" (`BLACK_TEXEL`); otherwise at zero, as before. `G` is
  written fully spent either way. During playback nothing expires, in the limiter or the auditor.
- **The auditor restarts with the host.** `createAuditor().restart(seed)` takes the seed the
  host wrote. A zero restart reseeds nothing. A black restart marks the next frame: there, each
  pixel that has shown exact (0, 0, 0) for at least 1250 ms, measured by the auditor on the bytes
  it reads, has both trackers reseeded to the black seed, and every other pixel keeps its history.
  `lastRestart` reports how many pixels were reseeded and how many were not. Host and auditor
  share one threshold, `blackLongEnough(ms)` in `limiter-model.mjs`, and the host credits black
  one presented frame at a time, each interval capped at 100 ms. The two therefore agree by
  construction for a host that keeps the contract, and the auditor judges a host that does not.
- **Black is exact.** Only the bytes (0, 0, 0) count as black. (1, 0, 0) and (5, 0, 0) are
  saturated-red bytes and break the run.
- **`osOffRed` near-black floor.** Every original finishes through `osOffRed`
  (`shaders/originals/common.glsl`). It replaces NaN by boolean selection, clamps the range,
  lifts green and blue to 0.55 of red, makes the colour exactly grey below a max channel of
  0.006, lowers red to the larger partner below 0.012, and ramps red's excess in up to 0.05. A
  conservative byte checker shows that no input then presents as a saturated-red byte triple such
  as (1, 0, 0) on the per-pixel present path, for grain 0 to 0.25 and dither of 1 or 0.5 code or
  none. This is a quality measure, not part of the safety claim: the limiter runs last on the
  presented bytes. Channel-split paths (present aberration, the Heat Haze transition) and pixel or
  frame mixes (bloom, blur, dissolves, damping) are excluded, with the reasons in design.md.
- **Metric named.** The safety argument (design.md, section 6) is stated for the WCAG 2.0 and 2.1
  red-flash definition and the general-flash luma rule. WCAG 2.2's chromaticity reading of red
  transitions is not covered; that gap predates this change and has its own ticket.
- **Tests.** Conformance vectors and auditor tests cover both round 3 repros, the CORE-2869 reset
  cases, a real red strobe after a black start, restarts after 74, 75 and 90 frames of black, and
  (1, 0, 0) near black. A shader test runs the byte checker at CI density, the NaN and infinity
  cases, and checks the GLSL form and the originals' wiring.
- **Host (core repin, not this repo).** The Beamfall web host presents 1.25 s of credited black
  before every start, the first included, and seeds `BLACK_TEXEL`.

## Non-goals

- Expiring anything during playback, in the limiter or the auditor.
- Changing the shaders' tracker logic, the grant, the area rules or the luma thresholds.
  "Black, nothing owed" is a texel the limiter already holds.
- Treating `osOffRed` as a safety mechanism.
