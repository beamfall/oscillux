<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Neon Run, Space Flight and Ocean Glide hold their light steady

Tickets: **CORE-3273** (Neon Run), **CORE-3274** (Space Flight), **CORE-3275** (Ocean Glide)
(Corvint Tasks, beamfall core queue). Found in the owner's web preview review, which showed
ghosting after the CORE-3238 limiter change. Follows `fractal-flight-steady` (CORE-3272).

## Why

All three flights stream detail past the camera, and the music lit large areas at once. Each pixel
that flips between dark and bright trips the limiter's per-pixel transition, and once enough of a
window fires the limiter holds it. Held pixels keep a dimmed copy of earlier frames, so the
flights ghost and stutter. The limiter is doing its job; the source is flashing.

Audits (`limiter-red-audit.mjs --only V --audio loud --beats 32`; luma in /s is the visual's own
large-area transitions, held is the fraction of pixels the limiter holds):

| Visual | Change | luma in /s | held mean | held max |
|---|---|---|---|---|
| Neon Run | Release body | 62 | 0.089 | 0.204 |
| Neon Run | This change | 43 | 0.048 | 0.188 |
| Space Flight | Release body | 88 | 0.236 | 0.507 |
| Space Flight | This change, planet off | 36 | 0.052 | 0.261 |
| Space Flight | This change, rings off | 36 | 0.073 | 0.293 |
| Space Flight | This change, burst pace held under twice cruise | 37 | 0.096 | 0.348 |
| Space Flight | This change, streaks, stars, rocks and planets all off | 1 | 0.002 | 0.052 |
| Space Flight | This change | 40 | 0.105 | 0.365 |
| Ocean Glide | Release body | 81 | 0.203 | 0.433 |
| Ocean Glide | Mirror-luminance hold, broad sun sheen on top of it | 25 | 0.056 | 0.154 |
| Ocean Glide | Wave swell as the reference | 52 | 0.136 | 0.330 |
| Ocean Glide | This change | 8 | 0.018 | 0.115 |

Neon Run's sources were the window grid strobing as sub-pixel windows streamed past, the spectrum
brightening a window row on every tower at once, and oncoming traffic lights and billboard bars
stepping a light's width each frame. Space Flight's were sub-pixel streaks and stars blinking on and off the pixel
grid as the view banks, the treble brightening every star at once, and the planet's ringlets
shimmering as the planet swept past. What remains comes from the planet, the rocks, the streaks
and the stars streaming past together in the bursts, each a few points and none of them a flash:
no single change short of removing a layer takes off more than one point, so this change keeps
them and leaves the rest to the owner's review. Ocean Glide's water flipped
every facet between the dark deep and the bright sunset sky as the waves streamed past, and the
broad sun sheen rode on top of it.

## What Changes

- **Neon Run.** Windows and the spectrum rows are recoloured at a fixed luminance (`nrAtLuma`),
  so the music changes the colour of a light, not its brightness; billboard bars still fill with
  the spectrum. The
  window grid is filtered over the pixel's footprint and the frame's travel: lit floors smear into
  streaks at speed and sub-pixel grids glow at their mean. Billboard bars glow off at the top and
  keep their unlit segments faintly on. Oncoming craft lights blur along their run over the frame
  and fade over the last few units before passing the camera.
- **Space Flight.** Streaks and stars are never drawn thinner than a pixel: a thin one spreads
  to a pixel at the same energy. The streak field is sparser at cruise and fills in for a burst,
  and each streak fades before it leaves the frame. The treble swings each star between its warm
  and cool tint instead of brightening the field, and the brightest stars are less extreme. The
  rings are filtered over the pixel's footprint on the ring plane, so their edges, ringlets and
  division blend to their mean instead of shimmering.
- **Ocean Glide.** Each water pixel keeps its hue (amber where the sky shows, teal in the deep,
  foam and spray) but its luminance is pulled 85% of the way, in log space, to what a calm mirror
  shows there. The broad sun sheen sits under that hold; the sun's narrow glints stay on top so the sun path still sparkles.

Render mean luma before and after: Neon Run 0.095 → 0.105, Space Flight 0.206 → 0.193,
Ocean Glide 0.403 → 0.381.

## Non-goals

- The limiter itself (CORE-3238) and Fractal Flight (CORE-3272, `fractal-flight-steady`).
- Gating every original's held fraction (CORE-2670).

## Failure modes

- If a flight reads flat, widen the hue swing, not the luminance gap between what the music
  lights and what it leaves.
- If the held fraction rises again, look first at detail that streams past at a pixel or less,
  and at anything the music lights across a large area: measure with the audit before raising it.
