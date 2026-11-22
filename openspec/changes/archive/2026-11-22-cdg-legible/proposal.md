<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Legible CD+G: sharper edges and contrast fixed on the fly

Ticket: **CORE-3242** (Corvint Tasks, beamfall core queue).

## Why

The CD+G presenter (CORE-3150) smooths letters with a soft ramp about one and a quarter frame
pixels wide, so edges look slightly blurred at 1080p. Discs also pair colours that read poorly
on the new backdrop, for example blue lyrics on a red background or pure red on dark blue: the
disc relied on its flat colour and a CRT, and the darker, glowing backdrop lowers the contrast
further. The owner asked for sharper, more legible lyrics and for poor contrast to be detected
and fixed while the song plays.

## What Changes

- Sharpen the coverage cut: the edge threshold moves from 100 to 112 of 255 (just under the
  113 a lone window pixel reaches after the blur, close to the 127.5 of a straight edge), and the
  ramp narrows to about 0.6 frame pixels (`rw * 256 / 150`). Strokes stay their weight, counters
  stay open, and edges are crisp but still anti-aliased.
- Fix contrast per palette: when the window, background or palette changes, each graphics colour
  that touches the backdrop is measured against the backdrop's darkest point (base in the
  vignette corner) and brightest point (base under both glows). Below a 3.5:1 contrast ratio
  (WCAG formula, gamma-2 luminance in integers), it is mixed toward white or black by the fewest
  sixteenths that reach 3.5, white first, so it keeps its hue where it can.
- Keep outlined text as authored: a colour whose window boundary with a contrasting,
  stage-legible graphics colour is at least a third of its boundary with the backdrop is
  protected. Protection lasts until the background or palette changes, so a fill does not flip
  colour while its outline wipes in.
- Spec, oracle and vectors updated; a test proves protection resets on a palette change.

## Non-goals

- Changing the decoder, ranks, ink or shadow selection (they use the disc's colours).
- Per-pixel or per-region contrast; a colour's fix applies everywhere it is drawn.
- Reaching 3.5:1 on every backdrop: on a near-white stage the best mix is taken.
