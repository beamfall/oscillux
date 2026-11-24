<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Catalog visuals carry measured photosensitivity data

Ticket: **CORE-3417** (Corvint Tasks, beamfall core queue).

## Why

Hosts screen visuals for photosensitive viewers, but the catalog gives them nothing to screen by.
The Apple host kept hand-reviewed values for 7 of the 63 visuals and a default profile for the
other 56, so its photosensitivity setting judged most visuals on a guess. The numbers belong with
the visuals, measured from the shipped bodies, so every host reads the same data.

## What changes

- Each catalog visual in `shaders/manifest.json` carries `safety`: `maxFlashHz`, `maxRedFlashHz`,
  `maxLuminanceDelta` and `textSafeZone`. The loader requires it with the catalog fields, and
  `catalog.json` carries it.
- `limiter-red-audit.mjs` measures it, rendering through the shipped present pass's tone map: the visual's own flashes a second (half its large-area luma
  transitions in any second, before the limiter), its red flashes a second (half its
  large-area saturated-red transitions in any second, before the limiter), the largest change in mean relative luminance
  of a WCAG field window at any position within the limiter's coverage interval, and the mean luminance and
  frame-to-frame change of the center and upper bands. `--write-safety` writes the measured block
  and `--check-safety` fails a visual whose measures exceed what the manifest declares or whose
  declared text band is not dark and steady. Both fail when any visual was not measured.
- `make visual-safety-check` runs the check on the release set under loud audio.

## Not covered

Spatial patterns (WCAG 2.3 stripes) are not measured: no audit metric exists for them yet, and
hosts must not read the absence as a pattern clearance. Measuring them is a follow-up ticket.

The `android-gles` leg ships no `catalog.json`; its typed Kotlin contract does not carry the
block yet. Adding it is a contract version change with an Android consumer repin, a follow-up
ticket.

Oscillux applies no policy to the data (AGENTS.md invariant 1): hosts choose ceilings and
behaviour.
