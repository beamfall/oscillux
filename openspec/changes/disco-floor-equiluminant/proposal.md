<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Disco Floor moves colour, not brightness

Ticket: **CORE-3263** (Corvint Tasks, beamfall core queue). Found in the CORE-3238 web review.

## Why

Under the red audit's loud audio, Disco Floor's own output makes 55 large-area luma transitions
a second against a budget of 6. The frame limiter then holds up to half the frame. Held pixels
keep a dimmed copy of earlier frames, so the floor's grid shows through the dancers ("ghosts")
and their motion jumps. The visual is broken at its source. The limiter is doing its job.

Ablations on the release body (`limiter-red-audit.mjs --audio loud --beats 32`):

| Change | luma in /s | held max |
|---|---|---|
| Release body | 55 | 0.51 |
| No kick pump, no LED pattern flips, no palette motion, no spot motion | 9 | 0.24 |
| Only the LED pattern flips put back | 51 | 0.47 |
| Only the kick pump put back | 33 | 0.52 |

Every one of the floor's flashes is a large-area brightness step. Each LED tile switches between
3% and full, and the whole floor's brightness is scaled by the kick. The 9 transitions that are
left come from motion: dark dancer silhouettes and beams sweeping across a bright floor.

Dimming the visual until it fits (the calm-originals approach) loses the excitement. Instead,
the large areas change colour at a fixed luminance, which the limiter does not count.

## What Changes

- LED tiles keep one luminance on and off. A pattern step swaps a tile's hue, the palette steps on every
  beat at that luminance and the floor fades from one pattern to the next over a beat instead of
  cutting, and the kick tints the whole floor hot without changing its luminance.
  The floor has no white sparks.
- The floor's light no longer scales with the kick. Glow lifts it a little. The wall, halo and
  crowd hold steady.
- The dancers are a solid colour at a luminance near the floor's, in the complement of the
  floor's palette, so they stand apart by hue. Their motion no longer steps the light, and the
  floor never shows through them.
- The rim light is a neon edge in the rig's colours at about the figure's luminance. The kick
  turns it hot without brightening it. A bright edge sweeping with the dance would count as a
  flash over all the area it crosses: the bright rims alone made 9 of the 13 transitions left
  after the floor change.
- The mirror ball's spots and the dress sequins are coloured, and add less than the 0.1 relative
  luminance step that makes a flash to whatever they cross, measured on the displayed frame after
  the present pass's grade and tone map. Spots fade out over the dresses, so a spot and a sequin
  together stay within one glint's budget. Palette colours are clamped at zero before they are set to a luminance, so a
  palette that swings a channel negative cannot brighten a tile when the display clips it. A white spot sweeping a pixel lit and
  darkened it in under a second, so each pass counted as a flash and the limiter held the pixels
  it crossed. The sequins are placed in the dress's own frame, so they move with it.
- Strong reds (red share above 0.7) ease halfway toward grey at their own luminance. When the
  palette tour passed red, the vivid present graded the floor, beams and figures into saturated
  red, and the limiter's slower red budget held whole windows of the room. CORE-3269 tracks the
  shared fix in `osOffRed` and the present grade.
- Beams hold a fixed luminance and answer the kick less. The spots turn more slowly.
- The manifest sets `trailDecay` 0 for Disco Floor.

## Non-goals

- The limiter itself (CORE-3238), and the other originals that are over budget. They follow the
  same approach in their own changes.
- Gating every original's held fraction (CORE-2670).

## Failure modes

- If the floor reads flat, raise the hue contrast between the on and off palettes, not the
  luminance gap.
- If held fraction stays above budget, the dancers' luminance is too far from the floor's.
  Measure it with `limiter-red-audit.mjs --only disco-floor` before changing anything else.
