<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Design: red transitions by the u'v' chromaticity rule (CORE-2935)

## 1. The rule as zones

WCAG 2.1 and 2.2 (current Recommendations), "pair of opposing transitions involving a saturated
red", working definition: one transition is to or from a state with R / (R + G + B) >= 0.8, and
the two states differ by more than 0.2 in the CIE 1976 UCS (u', v') diagram. R, G and B are the
linearised sRGB channels, as in relative luminance.

A colour's u'v' depends only on its chromaticity (r, g, b) / (r + g + b). The saturated set
r >= 0.8 is a triangle in that chromaticity plane, with vertices P (1, 0, 0), RG (0.8, 0.2, 0) and
RB (0.8, 0, 0.2). The map to u'v' is projective, so it sends this triangle to a triangle. Under
the IEC 61966-2-1 matrix the vertices map to P (0.4508, 0.5229), RG (0.3078, 0.5403) and RB
(0.3904, 0.4428). Distance to a fixed point is convex, so a colour's largest distance to any
saturated chromaticity is its largest distance to one of the three vertices. So:

- A colour c makes a WCAG u'v' transition with some saturated state only if c is more than 0.2
  from some vertex.
- The triangle's diameter is 0.144, so two saturated states never make one.

Every colour falls into one of three zones:

| Zone | Colours | Examples |
|---|---|---|
| S | saturated red: `redSat`, the existing test, widened by the codes' rounding | (255, 0, 0), (60, 0, 0), (1, 0, 0) |
| F | far: not S, and more than 0.2 from some vertex | grey, white, green, blue, cyan, (255, 0, 255) |
| M | near: every other colour, black (0, 0, 0) included | (255, 150, 0), (255, 0, 180) |

Every WCAG u'v' transition is between an S state and an F state. M is within 0.2 of every
saturated chromaticity, so an S state and an M state never make one.

Black has no chromaticity: u' and v' are 0 / 0. It is M, so the u'v' rule neither starts nor ends a
transition at black. Changes to and from black stay with the luma rule and the 320 rule, which
already count every red change of 20 or more with a saturated side. The other reading, black as
the D65 white point, would make black F, and then any dark-red glow fading out would count. That
is not what the definition says, and it is not adopted.

The rule counts S/F alternations, not pairs of states 0.2 apart. So it over-counts:

- F colours that are within 0.2 of the particular S state they alternate with;
- the classifier's over-calls (section 2).

It never under-counts. This is the same stance as the 320 rule's widened codes.

## 2. The integer classifier

For vertex (u0, v0), with X, Y, Z linear in (R, G, B) and D = X + 15 Y + 3 Z > 0:

> (u' - u0)^2 + (v' - v0)^2 > 0.04  ⇔  (4X - u0 D)^2 + (9Y - v0 D)^2 - 0.04 D^2 > 0

The right-hand side is a quadratic form in (R, G, B), homogeneous of degree 2. So it can be
evaluated on the chromaticity scaled to 1024. The classifier, on the linear codes
R = LUMA_LUT[r][3] (and likewise G, B):

```
S = R + G + B                  // 0 only for black; LUMA_LUT[k][3] >= 20 for k >= 1
if S == 0: zone M
if redSat: zone S
nr = floor(1024 R / S); ng = floor(1024 G / S); nb = 1024 - nr - ng
Q_k = c0 nr nr + c1 ng ng + c2 nb nb + c3 nr ng + c4 nr nb + c5 ng nb    // summed in this order
far = max(Q_P, Q_RG, Q_RB) >= -749628
zone F if far, else M
```

The coefficients are the IEC-matrix conics scaled so that the largest is 1900, then rounded:

| Vertex | c0 rr | c1 gg | c2 bb | c3 rg | c4 rb | c5 gb |
|---|---|---|---|---|---|---|
| P | -115 | 1900 | 613 | -718 | -258 | 711 |
| RG | -55 | -170 | 449 | -1194 | -337 | -490 |
| RB | -86 | 1256 | 317 | -834 | -489 | -344 |

The threshold is set from the exhaustive scan below, as the least margin that keeps every far
colour far.

**Exhaustive check.** `tools/shader/limiter-zone-check.mjs` runs over all 2^24 8-bit colours and is
part of `make limiter-check`, about 12 s. For each colour it computes "far" in float64 from the
exact sRGB curve, under both the IEC 61966-2-1 matrix and the matrix derived from the sRGB
primaries. A colour is far if it is more than 0.2 from a vertex under either matrix. The check
asserts four things:

1. every far colour classifies F;
2. no `redSat` colour is far, and none classifies F;
3. every partial sum in the order above stays within ±(2^31 - 1);
4. the over-call count is unchanged: 14344 colours, 0.085%, all of them classify F though not far.

The largest term or partial sum is 1992294400 < 2^31 - 1. So GLSL `highp int` and JavaScript
numbers agree with no wrap. The floors are exact in both:

- GLSL ES 3.00 divides non-negative ints by truncation.
- JavaScript computes `Math.floor(1024 * R / S)` on integers under 2^27. Its float quotient is
  at least 1/S ≥ 2^-18 from any integer it is not equal to, far more than one rounding.

**Soundness.** By section 1, any colour c that makes a WCAG u'v' transition with a saturated state
is far. By check 1 it classifies F, and by check 2 it is not S. The saturated state itself is
`redSat`, because the widening admits every exactly saturated colour. So every WCAG pair is an
S/F pair, under either matrix.

## 3. The side tracker

Every pixel keeps a side: none, S, F, or unknown. When the pixel shows a colour in zone z:

| z | Fires | Side after |
|---|---|---|
| M | nothing | unchanged |
| S | red up if the side is F or unknown | S |
| F | red down if the side is S or unknown | F |

A pixel's first value under `UNTRACKED` takes its zone as its side (none for M) and fires nothing,
as the trackers already do.

**Union.** The red step returns a direction mask: bit 0 for up, bit 1 for down. Each bit is set
where the 320 rule (unchanged: the red tracker and its saturation memory) or the side fires in that
direction. Both bits can be set together. For example, (5, 0, 0) to (255, 0, 230) is a red-code
rise with a saturated state seen, so the 320 rule fires up. It is also S to F, so the side fires
down. The mask replaces the signed count everywhere the count was read:

- `fires`, which feeds requests, area, holds and the dim search;
- the output pass's stamps and `fired` stats;
- the auditor.

The grant admits one red direction a frame, so a pixel that fires both is held. The dim search then
shows the nearest colour that fires only what was admitted. It converges over the next grants:
the example above passes after two red grants.

The held-pixel search needs no change. The previous output fires nothing, so it stays the search's
safe end. Grey and white are F, so on an S-side pixel the grey fallback is unsafe unless red down
was admitted, and the search then moves from the previous output toward the input, as it does for
any unsafe grey.

## 4. Encoding

The red tracker word z has bits 13 to 15 free: bits 0 to 7 are the extreme, 8 to 11 the distance,
and 12 is `RED_UP`. The side is stored in bits 13 and 14 (`RED_SIDE_SHIFT` = 13):

| Code | Side |
|---|---|
| 0 | unknown while the red memory is unknown (x and y high bits both 0), else none |
| 1 | unknown |
| 2 | S |
| 3 | F |

After the step, side unknown writes code 0 while the red memory is still unknown and code 1 once
it is known. The red memory never returns to unknown. A side of none occurs only with a known
memory, from `BLACK_TEXEL`, or from an `UNTRACKED` start, which writes the memory known.

The texels that hosts write keep their meaning:

| Texel | Decodes as |
|---|---|
| zero | red memory unknown and side unknown: conservative |
| `BLACK_TEXEL` [0, 32768, 0, 0] | memory counted and side none: nothing owed |
| `UNTRACKED` | unchanged |

No host code or seed changes.

## 5. The auditor

`limiter-audit.mjs` adds a side per pixel, none, S or F, and imports `redZone` from the model, as
it already imports `redCode` and `redSat`. A float u'v' auditor would decide some colours
differently from the limiter. It would then charge transitions at frames the limiter did not, and
the limiter could not be checked bit for bit (frame-limiter "Per-pixel transition trackers").

The auditor's side follows the limiter's:

- at the auditor's first frame (`!live`), the side is the zone;
- at a black reseed, the side is none;
- a zero restart keeps it;
- at every frame, it steps as in section 3.

A red direction is recorded (`last[2]` up, `last[3]` down) when either rule fires it. The auditor
never has an unknown side. The limiter's unknown, after a zero seed, fires where the auditor may
not: more, never fewer, as with the unknown red memory ("A host reset is conservative").

## 6. Consequences for hosts and visuals

**Zero starts.** After a zero start every F pixel fires red down on its first frame. Over the area
limit that is held until the red grant: `G` is written spent, so about 1.33 s at 3 Hz. Most of the
frame stays black that long. The web player always starts after `BLACK_S` of black at
`BLACK_TEXEL`, so it never takes a zero start in playback. Hosts that start at zero after a short
black see the longer black. That is the cost of not knowing what was shown before. Black starts
are unaffected.

**Dark noise.** Dithering between (1, 0, 0) and (0, 0, 1) is an S/F alternation, and it counts.
The definition has no luminance floor, and none is added. Originals already present no saturated
red bytes (`osOffRed`, visual-defaults), so their S states come only from the vivid grade and the
post chain. Image inputs and catalog visuals can present S. The probe (section 8) measures what the
stricter rule holds.

## 7. Vectors

New cases in `tools/shader/limiter-vectors.mjs`, written with `--write` and run on every leg:

| Case | Strobe | What it checks |
|---|---|---|
| `red-green-dim-10hz` | 10 Hz, (60, 0, 0) / (0, 60, 0) | The CORE-2935 repro. The u'v' rule alone counts it: the input makes ≥ 18 red transitions a second, the output at most 1. |
| `red-white-10hz` | 10 Hz, (255, 0, 0) / (255, 255, 255) | Both rules count every change in the same direction. The output still makes at most 1 red transition a second. |
| `red-mask-10hz` | 10 Hz, (5, 0, 0) / (255, 0, 230) | Every change fires both red directions (section 3). The output makes at most 1 red transition a second, and the legs carry the mask bit for bit. |
| `red-black-dim-10hz` | 10 Hz, (60, 0, 0) / black | S and M: the input counts no red transitions. |

**No regressions.** Storing the side changes every existing case's tracker digest. A one-off
script compares the old and new vector files case by case and frame by frame: outputs, hold
masks, grants and grant state. The cases whose input holds no S/F alternation must match exactly.
The cases that change are listed in the code review with the reason for each.

## 8. Probe and calming

The probe has two stages:

1. `limiter-red-audit.mjs --release --audio loud`, before and after, on the model at 480 × 270. It
   gives each visual's input red transitions and held fraction under both rules.
2. The web player probe (`zz-pause-probe-player.spec.ts`, the calm brief's settings) on a build that
   vendors the candidate legs. It must find no visual over 0.5% of pixels held a frame.

A visual that ends up over is calmed in its shader. The usual fixes are smoothing the level instead
of following onsets, slowing the motion, and keeping reds just off saturated. Each calmed visual is
listed in `tasks.md`.

## 9. Not done

- **A float u'v' test in the auditor:** rejected (section 5).
- **A luminance floor for the u'v' rule:** rejected (section 6). The probe decides calming instead.
- **Black as D65 white:** rejected (section 1).
- **Counting only S/F pairs that are more than 0.2 apart:** a per-pixel 2-D distance against a
  stored state would need the state's chromaticity in the texel, and the texel has no room for it.
  The zones over-count by a small set instead.
