<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame flash limiter: feather red holds too

Ticket: **CORE-2413** (P2, Corvint Tasks, beamfall core queue). Owner report 2026-11-18: the web
player's visualizations still show blocky, smeared tiles with hard rectangular edges under loud
music on v0.2.8 (Murmuration, orange on dark).

## Why

The output pass feathers the picture around a held sub-block (`limiter-smooth-hold`), but it
skips any pixel whose input, history or blend is red-dominant in 8-bit (`r > g + b`). That test
is far wider than red: orange (255, 128, 0) and most warm palettes pass it, so around every hold
on a warm visual the feather is switched off and the hold's sub-block edges show as hard tiles.
A Codex review (2026-11-18) reproduced a 76-level step at a sub-block boundary on smooth moving red
bands where neither input nor history stepped.

The exemption existed so the blend could never add a red transition the red token did not grant.
That only needs each blended pixel's red to stay between its history's and its input's.

## What Changes

- The output pass blends every pixel beside a hold, red included. After blending it compares
  red codes as the reduction sums them (`R - G - B` on linear codes when the pixel is saturated
  red, `5R >= 4(R + G + B)` and `R > G + B`, else 0): if the pixel's red code changes by more
  than `RED_STEP` (the red tracker's step), or the blend's falls outside the range between the
  history's and the input's, the pixel shows the input instead. A red change the red token
  admitted is never hidden by the feather, and a delayed small change stays under one step.
- The `output` pass now reads `LUMA_LUT` for the linear codes. No pass gains a texture or a
  uniform; hosts take the change by re-vendoring the generated passes.
- Held sub-blocks, the hold field and luminance are unchanged.

## Non-goals

- Making holds local to the windows that went over (a Codex suggestion): tried, it raised the
  pixel auditor's large-area luminance transitions on five catalog visuals (wave-cascade 12 to 21
  a second), so it is not taken.

## Failure modes

- A blend could add red change: the guard compares against the input's red step per pixel, so
  the output's red change is never larger than the input's at a blended pixel. The model test and
  the red audit check it.

## Acceptance evidence

- `make limiter-check` (model tests including a red-background feather case, vectors, WebGL2 and
  Metal passes bit-exact with the model).
- Catalog red audit under loud audio before and after: luminance outputs unchanged, red outputs
  no higher on any visual (volumetric-light red transitions 1 to 0 a second).
- Murmuration's worst held frame before and after (orange tiles gone).

## Rollback

Revert the change and cut a patch release; hosts re-vendor.
