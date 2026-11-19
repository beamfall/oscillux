<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Visuals fit the frame's aspect, from a portrait phone to ultrawide

Ticket: **CORE-2491** (P2). Owner requests 2026-11-18: visuals should understand the size and
format they run in (no squeezing many bars onto a phone), and all visuals should be aspect aware.

## Why

- Spectrum (58 columns), Terrain (56) and Spectral City (72 cells) draw their authored column
  count at any aspect: about 7 px columns on a 390 x 844 phone held upright.
- 44 of the 61 reference visuals build coordinates with `motionCentered()` and 7 with
  `centered()`. Both scale x by the aspect and keep y at -1..1, so a composition authored within
  radius 1 is cropped to x -0.46..0.46 on a portrait phone.
- The remaining visuals draw on raw `uv` and were never checked off 16:9.

## What Changes

- Library `columnFit(u)` and `fitColumns(u, authored, minimum)`: a column count from the frame
  aspect, never under the minimum nor over one column per 4 px. Spectrum, Terrain and Spectral
  City use them.
- `centered()` and `motionCentered()` lean toward the frame's short side (`shortSideFit`, scale
  aspect^-0.7 below aspect 1): on a 9:19.5 phone x spans about -0.8..0.8, so the subject stays in
  frame without shrinking to a dot. A full short-side fit (aspect^-1) left subjects too small on a
  phone. Unchanged at aspect 1 and wider.
- Raw-`uv` visuals are checked in portrait and fixed where their subject leaves the frame or
  their detail falls under about 4 px.
- `render.mjs --size WxH` renders at any frame size.

## Non-goals

- Changing any visual at 16:9 or wider: those frames render as before (largest difference 1/255).

## Failure modes

- A visual that relied on the crop shows more of its scene in portrait; reviewed on the contact
  sheets.

## Acceptance evidence

- Portrait contact sheets (196 x 424) of every reference visual before and after.
- 16:9 renders before and after match to within 1/255.
- `make shader-test` and the leg regeneration checks.

## Rollback

Revert the change and cut a patch release; hosts re-vendor.
