<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Fractal Flight moves colour, not brightness

Ticket: **CORE-3272** (Corvint Tasks, beamfall core queue). Found in the owner's web preview
review, which showed ghosting after the CORE-3238 limiter change.

## Why

Under the red audit's loud audio, Fractal Flight's own output makes 49 large-area luma
transitions a second. Through the limiter model it holds 9% of its pixels on average and 31% in
the worst frame. Held pixels keep a dimmed copy of earlier frames, so the vault ghosts and the
flight stutters. The limiter is doing its job; the source is flashing.

Ablations (`limiter-red-audit.mjs --only fractal-flight --audio loud --beats 32`):

| Change | luma in /s | held mean | held max |
|---|---|---|---|
| Release body | 49 | 0.090 | 0.311 |
| No inscatter (sun shafts and haze) | — | 0.006 | — |
| Softer, wider shafts | worse | worse | worse |
| This change | 13 | 0.011 | 0.129 |

The sunlit shafts were the main source: air close to the camera is shared by every pixel, so a
beam brightening there brightens the whole frame at once. The second source was the window panes,
whose palette colours have very different luminances, so a beat that recoloured a handful of panes
stepped their brightness. The 13 transitions left come from flying past the fractal walls at
pace. Slowing the flight to remove them makes the visual dull, which the owner rejected.

## What Changes

- Every pane colour is set to one shared luminance (the mean of the palette's), so the panes turn
  through the palette with the bars and a beat flare swings them toward the complementary colour
  without changing their brightness. A fresh handful of panes swings all the way.
- The shafts fade out over the first few units in front of the camera, and their weight drops.
  A steady sunlit haze tinted from the palette at a fixed luminance carries the brightness the
  brighter shafts used to give, so the frame stays as bright as before (render mean luma 0.239
  before and after).
- The lace's beat wave recolours the lace at its own luminance instead of brightening it, and
  the near-miss glow answers the amplitude less.
- The hue follows the bars only. The pace follows `osFlight`'s 32-beat profile around a steady
  cruise, kept under twice cruise, and the field of view widens a little with it.

## Non-goals

- The limiter itself (CORE-3238), and the other flights (CORE-3273 Neon Run, CORE-3274 Space
  Flight, CORE-3275 Ocean Glide), which follow in their own changes.
- Gating every original's held fraction (CORE-2670).

## Failure modes

- If the vault reads flat, widen the hue swing between the pane and flare colours, not their
  luminance gap.
- If held fraction rises again, check the shafts near the camera first: measure with the audit
  before raising their weight.
