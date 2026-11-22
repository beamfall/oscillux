<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Design: red transitions by the u'v' chromaticity rule (CORE-2935)

Owner decision 2026-11-21, after Codex design round 1 held the zone design: "Widen limiter
memory". The tracker texel widens from RGBA16UI to RGBA32UI. Each pixel keeps two boxes of u'v'
codes in the high halves: the saturated states it showed since its last definite red fall, and
the far states since its last definite red rise. Section 12 maps every Codex finding to its fix.

## 1. The rule

WCAG 2.1 and 2.2 (current Recommendations), "pair of opposing transitions involving a saturated
red", working definition: one state of a transition is saturated red, R / (R + G + B) >= 0.8, and
the two states are more than 0.2 apart in the CIE 1976 UCS (u', v') diagram. R, G and B are the
linearised sRGB channels.

- A colour's u'v' depends only on its chromaticity. The saturated set is a triangle in the
  chromaticity plane with vertices P (1, 0, 0), RG (0.8, 0.2, 0) and RB (0.8, 0, 0.2). The map to
  u'v' is projective, so the set maps to a triangle, P (0.4508, 0.5229), RG (0.3078, 0.5403), RB
  (0.3904, 0.4428) under the IEC 61966-2-1 matrix. Its diameter is 0.144, so two saturated states
  never make a transition.
- Black has no chromaticity (0 / 0). The u'v' rule neither starts nor ends a transition at black,
  and black keeps the pixel's boxes. Changes to and from black stay with the luma rule and the 320
  rule. Reading black as the D65 white point would count every dark-red glow fading out; the
  definition does not say that and it is not adopted.

A transition is measured between the states a pixel shows, from any saturated state since the last
counted transition in the other direction, as `trackStep` measures luma from its extreme. Keeping
every such state (as a box, section 4) is what catches a flash whose extremes are reached through
intermediate states on different frames (P1-a, P1-1).

## 2. Integer codes

Every decision is integer arithmetic on 8-bit display values, identical in the model, the
auditor and the GLSL legs. No intermediate exceeds 2^32 - 1, so it runs in `uint` on GLSL ES 3.00.

```
LIN24[k] = round(linear(k / 255) * 2^24)            // a generated LUT, as LUMA_LUT
s = LIN24[r] + LIN24[g] + LIN24[b]; s == 0: black, no code
k = the least shift with (s >> k) < 2^18             // 0..8, a bounded loop: no findMSB in ES 3.00
c_i = LIN24[i] >> k; s2 = c_r + c_g + c_b
n_i = (c_i << 14) / s2                               // chromaticity in 2^-14, each term < 2^32
X = 6757 n_r + 5859 n_g + 2957 n_b
Y = 3483 n_r + 11718 n_g + 1183 n_b
D = 59954 n_r + 187485 n_g + 67420 n_b;  q = D >> 14
u = 4 X / q;  v = 9 Y / q                            // u' and v' in 2^-14 (Q = 16384), 14 bits each
```

The coefficients are the IEC rows times 2^14 and (X_i + 15 Y_i + 3 Z_i) times 2^14. Measured over
every 8-bit colour, against both the IEC matrix and the matrix derived from the sRGB primaries
and D65:

- the code is within E = 2.0443e-4 of the true (u', v') (worst at (254, 1, 8));
- the vertex codes VC, P (7386, 8567), RG (5044, 8852) and RB (6396, 7255), are within
  EV = 1.0144e-4 of the true vertices;
- the largest intermediate is 4287119360; u <= 7386 and v <= 9216.

The thresholds below use the bounds E = 2.5e-4 and EV = 1.5e-4, which the check asserts.

**Saturated.** `s24(c)`: non-black and `LIN24[r] + 1 >= 4 (LIN24[g] + LIN24[b])`. Over every
8-bit colour it accepts every colour whose float64 r / (r + g + b) >= 0.8 and no colour below
0.8 - 1e-12. The 320 rule keeps its own `redSat`.

`tools/shader/limiter-uv-check.mjs` reproduces every number in this section and the next over
all 2^24 colours (about 7 s) and runs in `make limiter-check`.

## 3. Thresholds

All in squared code units.

- **T = 10683798** = floor(((0.2 - 2E) Q)^2). A *possible* step is d^2 > T. Two states more than
  0.2 apart have codes more than 0.2 - 2E apart, so every WCAG transition is a possible step.
- **TH = 10791225** = ceil((0.2 + 2E) Q)^2. A *definite* step is d^2 > TH: the two states are more
  than 0.2 apart. Pairs between the two thresholds are the early band: they fire but never clear
  memory (section 4).
- **TF = 10634475** = floor(((sqrt(T) / Q - E - EV - 1 / Q) Q)^2). A code is *far* when its d^2 to
  some vertex code exceeds TF.
- **TVF = 12233465** = ceil((R Q)^2), R = sqrt((sqrt(TH) / Q + E + 1 / Q)^2 + (L / 2)^2) + EV,
  L = 0.143999 the longest edge of the vertex-code triangle. A code is *very far* when its d^2 to
  every vertex code exceeds TVF: every saturated code lies within E + EV of the vertex-code
  triangle, and a point more than R from all three vertices is more than sqrt(TH) / Q + E + EV
  from the triangle.

The check takes the convex hull of the 788060 distinct saturated codes (20 vertices) and asserts
over every distinct code:

- every code with d^2 > T to some hull point is far (farBad = 0), so a code that is not far can
  never make a possible step with any saturated state;
- every very-far code has d^2 > TH to every hull point (vfBad = 0), so it makes a definite step
  with every saturated state.

Saturated codes are never far: the triangle's diameter is under the far distance.

## 4. Per-pixel boxes and the step

Each pixel keeps two boxes of codes, each either *known* (it holds every code it should) or
*unknown* (a zero seed lost them):

- **SB**, the saturated codes shown since the last definite red fall, in 8-code cells from
  (5044, 7254): 293 by 200 cells cover every saturated code;
- **FB**, the far codes shown since the last definite red rise, in 64-code cells from
  (2048, 2587): 84 by 104 cells cover every code.

A box is an axis-aligned rectangle of cells, so it holds every code it was built from and possibly
more. Two tests use it:

- *possibly over* (c, box): the box's farthest corner is more than T from c. Every code the box was
  built from that is more than 0.2 from c passes, and so may codes it was not built from.
- *definitely over* (c, box): one of the box's four edge strips, one cell wide, lies wholly more
  than TH from c. Each strip holds a code the box was built from, so that code is more than 0.2
  from c.

The step on a shown colour c, after the previous output p:

| c | fires | then |
|---|---|---|
| black | nothing | boxes unchanged |
| non-black, c == p | nothing | c joins the boxes |
| saturated, c != p | up if FB is unknown, or non-empty and possibly over | on an up: FB := known, empty if FB is certain and definitely over, else clipped (section 13); c joins SB |
| other, c != p | down if SB is known and possibly over, or unknown and c far | on a down: SB := known, empty if c is very far or SB is certain and definitely over, else clipped (section 13); c joins FB if far |

c joins SB when saturated and FB when far. A union is the cellwise bounding box.

- **Up.** An up transition from a state x to a saturated s exists only if x is more than 0.2 from s,
  and then x is far (farBad = 0) and in FB unless a definite rise since cleared it. A definite rise
  at s' means x' more than 0.2 from s' was in FB, and that rise was counted; x then pairs only with
  states after s'. So every up transition fires.
- **Down.** Symmetric, with SB holding every saturated state since the last definite fall.
- **Possible only.** A fire that is not definite (the early band, or a corner of the box no state
  sits at) keeps the box, so a true crossing later still fires (P1-2). It may fire again at the
  next different colour: an over-count, never a miss.
- **Only a changed colour fires.** A pixel that keeps its colour after a possible-only fire would
  otherwise ask every frame. A colour equal to the previous output has the same chromaticity, so
  it makes no transition the previous output did not.
- **The unknown boxes** (zero seed) fire on a superset: up at every changed saturated colour, down
  at every changed far colour. SB leaves unknown at a very-far colour (definite from every
  saturated state) or a definite fall from codes it gained since; FB at a definite rise from far
  codes it gained since.
- **Black** changes nothing. So (255, 0, 0), black for 1.5 s with no restart, then (0, 255, 0)
  counts a fall at black (320 rule) and another at green (u'v' rule).

A pixel with no state yet (`UNTRACKED`) takes its first colour without firing: both boxes known,
holding it where it is saturated or far.

## 5. One red direction per pixel

The red direction a pixel fires is the u'v' direction when that fires, else the 320 rule's.
`fires()`, the output's fired bits and stamps, and the auditor's count all use this merged
direction.

- **Safety.** The area test counts pixels firing in any direction and channel, and every granted
  red event spends the red token, which takes at least 1.33 s to refill. So no area makes two
  large-area red changes within 1.33 s, whichever rule each pixel's change is under.
- **Liveness (P1-b).** A constant (1, 0, 0) after a zero start asks for red up only (unknown FB),
  where the zone design also asked down from the unknown 320 memory. It is granted at the first
  red grant and fires nothing after: it equals the previous output. A constant colour never asks
  for both directions.

## 6. Tracker texel and host contract

The tracker textures (`uTrack`, `oTrack`) become RGBA32UI. The low 16 bits of each word keep the
existing texel, and z gains two bits, so every existing masked read is unchanged:

| Word | Bits 0 to 15 | Bits 16 to 31 |
|---|---|---|
| x | luma extreme, `RED_MEM_HI` | SB u min (9 bits), FB u min (7 bits) |
| y | luma distance, `LUMA_UP`, `UNTRACKED`, `RED_MEM_LO` | SB u max (9), FB u max (7) |
| z | red extreme and distance, `RED_UP`, SB known (bit 13), FB known (bit 14), SB uncertain (bit 15) | SB v min (8), FB v min (7), marker (bit 31) |
| w | stamps | SB v max (8), FB v max (7), FB uncertain (bit 31) |

A min is stored as N - cell and a max as cell + 1 (N = 511, 255 or 127), so the empty box is zero
and a union is the bitwise field maximum.

- **Seeds.** Zero is valid and means both boxes unknown (with the existing zero meaning for the
  low halves). "Black, nothing owed" becomes (0, 32768, 2147508224, 0): both boxes known and
  empty, marker set. `UNTRACKED` is exactly (0, 8192, 0, 0).
- **Validity (P1-3).** Every texel the legs write sets the marker. A texel is valid when its marker
  is set or it is all zero. Any other texel (a host that stored 16 bits, clamped or truncated)
  fires every direction at a changed colour and counts toward the area limit (the format check
  keeps such a store off screen); `UNTRACKED` is matched
  exactly, so a clamped 65535 never reads as untracked.
- **Format check.** At start a host clears a texel of each tracker attachment to a value with bit
  31 set in every word, reads each back, and presents black if any word differs (P3, section 13),
  all before it writes the seed over the probed texel. WebGL `RGBA32UI`, Metal
  `.rgba32Uint`, GLES `GL_RGBA32UI`; seeds and clears are 32-bit. Memory is 16 bytes a pixel per
  copy: two copies are 265 MB at 3840 x 2160, up from 133 MB.
- **Rows pass.** The rows pass evaluates `fires()`, which now reads the previous output, so a host
  binds `uHist` to it as it does to the output pass.
- **Rollout.** The web renderer changes in the core repin to v0.2.13. The Apple and Android hosts
  change when they repin; until then they stay on v0.2.12 legs.
- **Why not a second texture.** A second tracker texture would add an output attachment, a
  sampler and a ping-pong pair per leg and host. Widening the format changes one allocation, one
  seed and one check per host.

## 7. The auditor

`limiter-audit.mjs` keeps the same boxes per pixel with the model's exported `uvStep`, comparing
each frame with the previous input frame:

- at its first frame (`!live`) each pixel takes its colour as the limiter does at `UNTRACKED`;
- a black reseed makes both boxes known and empty, as `BLACK_TEXEL` does;
- a zero restart makes both boxes unknown, as the zero seed does, so the auditor and the limiter
  step the same chromaticity state from it (P1-B, section 13). Unknown boxes are a superset of any
  history, so this never hides a transition the auditor kept;
- a zero restart before its first frame gives each pixel the zero texel's whole state (both
  trackers falling at 0, the red memory and the boxes unknown) and steps that frame from black,
  as the limiter steps its first output from the zero seed (section 13).

Its red direction per pixel and frame is the u'v' one when that fires, else the 320 rule's. It
records at most one large-area red transition a frame (up when both directions are over the
limit): the limiter admits one red direction a frame, and pixels rising and falling at the same
frame change together (P2-1).

The auditor measures in the integer codes, as it does for luma. It does not under-count a float
measure: every pair more than 0.2 apart is a possible step, and a box clears only at a definite
step, which is more than 0.2.

## 8. Consequences

- **Zero starts.** After a zero start a pixel asks red up at every changed saturated colour and
  down at every changed far colour until its boxes become known (section 4). Over the area limit
  such pixels change about once per red grant (1.33 s); a held pixel shows the nearest safe colour,
  so the frame keeps moving. The web player starts black after `BLACK_S` and is not affected.
  Hosts should start black where they can.
- **Dark noise.** Dither between (1, 0, 0) and (0, 0, 1) is a saturated/far alternation, and it
  counts. The definition has no luminance floor and none is added. The probe (section 10)
  measures what this holds.
- **Held colours.** A held pixel's search starts from the grey of its luma band. After a saturated
  red that grey is more than 0.2 away and would fire a red fall, so the search mixes from the
  previous output toward the input instead: a held red rise shows dim red where it showed a pale
  red (section 9).
- **Cost.** The code costs five 32-bit divisions and up to eight shifts per non-black pixel and
  evaluation; held pixels evaluate it per search step, as they evaluate luma.

## 9. Vectors

New cases in `tools/shader/limiter-vectors.mjs`, written with `--write` and run on every leg:

| Case | Input | Checks |
|---|---|---|
| `red-green-dim-10hz` | 10 Hz, (60, 0, 0) / (0, 60, 0) | The CORE-2935 repro: only the u'v' rule counts it. |
| `red-blue-10hz` | 10 Hz, (255, 0, 0) / (0, 0, 255) | A full red flash: luma, 320 and u'v' all count. |
| `red-mask-10hz` | 10 Hz, (5, 0, 0) / (255, 0, 230) | Each change is a 320 rise and a u'v' fall: the merged direction. |
| `red-black-dim-10hz` | 10 Hz, (60, 0, 0) / black | No rule counts it; nothing is held. |
| `red-flash-5hz-half` | 5 Hz, (180, 0, 0) / (90, 90, 90), left half | A real red flash over half the frame. |
| `red-stagger` | P1-a | Two 16-column stripes: A (60, 0, 18), B (35, 0, 32) from frames 1 and 7, C (0, 0, 60) at 8, period 24. |
| `red-extremum` | P1-1, 64 x 36 | Two 8 x 5 patches: A (60, 0, 0), S (60, 25, 0) from frames 1 and 16, C (60, 50, 0) at 17, S after, period 34. |
| `red-early-band` | P1-2 | `red-extremum` with the outward S replaced by (61, 42, 0), 0.19957 from A. |
| `red-zero-constant` | P1-b, zero start, constant (1, 0, 0) | The frame shows (1, 0, 0) from the first red grant on. |
| `red-zero-mixed` | P2-1, orange left and blue right, black, zero start, (1, 0, 0) | One red transition a second at most in the output. |

`bands` is a new signal kind: rectangles, each with keyed colours over a period, on a background.
Each stripe of `red-stagger` covers 1280 pixels of a 140 x 80 limiter window, under its limit of
1605, and the two together 1920 pixels of a 107 x 60 auditor field, over it (P2-2). Each patch of
`red-extremum` is 40 pixels, the two together 80 of a 21 x 12 field, over its 63.

`test-limiter.mjs` asserts:

- input red transitions (at least 18 a second at 10 Hz, 9 at 5 Hz, 2 or 3 for the Codex repros)
  and at most 1 a second in the output;
- that each stripe or patch alone is never held, and that both ask red down at the crossing frame
  (8 or 17) and not at the intermediate frames (1 and 7, or 1 and 16);
- `red-black-dim-10hz` and a 0.094 saturated/far alternation (P2-3) are never held;
- `red-zero-constant` equals the input from the first grant on; black keeps the boxes; a clamped
  16-bit texel is invalid and fires every direction.

**No regressions.** The tracker digest hashes all four bytes of each word, so every case's digest
changes. `vecdiff` compares the new model with the committed one over every existing case, frame
by frame: outputs, hold masks, grants, grant state, held counts, and the low 16 bits of each
tracker word with z's two new bits masked. 23 cases match. Six differ, none in a hold mask or held
count:

- `red-3hz` (from frame 20), `red-10hz` (6), `red-stripes-10hz` (6), `black-start-red-10hz`
  (248), `reset-black-at-expiry` (276): held colours (section 8). The held red rise shows (68, 0, 0)
  where it showed (131, 47, 47), or (81, 26, 26) on the stripes; grey would fire a u'v' fall from
  the red the pixel showed. The luma trackers' low halves follow the shown colour.
- `reset-short-black` (frames 308 to 329): the zero seed leaves both boxes unknown. At (5, 0, 0)
  the merged direction asks red up (u'v') where the 320 rule's unknown memory asked down; both
  spend the red grant. At (255, 0, 0), held, every saturated mix fires up and grey fires down, so
  the pixel keeps (5, 0, 0) where it showed (112, 65, 65).

## 10. Probe and calming

1. `limiter-red-audit.mjs --release --audio loud` on the model at 480 x 270: each visual's input
   red transitions and held fraction under both rules.
2. The web player probe (`zz-pause-probe-player.spec.ts`) once over the 61 release visuals, on a
   build that vendors the candidate legs. No visual may hold more than 0.5% of pixels a frame.
   A visual over it is calmed in its shader and only that visual is probed again. Calmed visuals
   are listed in `tasks.md`.

**Result (2026-11-21).** Four visuals were over 0.5% and were calmed; the largest of the 61 is
now 0.31% (photo-curtain).

- **Vault** held on no beat. Its eight-beat crossfade from a bright pattern to a dim one
  darkened the upper half of the screen faster than the reveal had brightened it: a smooth
  large-area fall that the luma rule counts. The crossfade now runs evenly over the slot, the
  bright patterns are dimmer and the projector colours sit near one luminance (0.99% to 0.00%).
- **Palette position.** Held fractions move with where the palette tour is during the probe
  window (z = time / 6 plus the manifest palette, mod 16), so runs differ by a few tenths. On
  one run, v0.2.12 and the candidate held the same or less on the candidate (ink 1.39% both,
  constellation 0.35% to 0.18%, filament 0.39% to 0.21%).
- **Wrap fix.** Seven visuals wrapped the tour index mod 32 against the 16-entry table, so the
  blend out of palette 15 read past its end. They now wrap at `OS_PAL_COUNT`.

## 11. Not done

- **Two metrics in one granted frame.** Read under a single metric, a granted frame can hold up
  and down areas made of different pixels. The token bounds large-area red changes either way
  (section 5).
- **The early band and box corners** over-count: pairs between 0.2 - 2E and 0.2, and corners of a
  box no state sat at, fire. As the 320 rule's widened codes do, this trades holds for safety.
- **A float auditor.** The auditor uses the integer codes, which are the measure, as for luma
  (section 7).
- **Zero-start liveness** (section 8).
- **Black as D65 white** (section 1).

## 12. Codex design findings

Round 1, zone design (HOLD):

- **P1-a, staggered intermediate state:** the boxes keep every saturated state since the last
  definite fall, so both stripes cross at C together; `red-stagger`.
- **P1-b, liveness from a zero seed:** the merged direction (section 5); `red-zero-constant`.
- **P2, the float saturated test:** the check asserts every non-black colour with float64
  r / (r + g + b) >= 0.8 is `s24` (section 2).
- **P2, seed changes in the no-regression rule:** allowed and listed (section 9).
- **P3, zero-start impact and flash counts:** section 8 and the proposal (20 transitions, 10
  flashes a second at 10 Hz).

Round 1, widened memory with a last-saturated reference (HOLD):

- **P1-1, a saturated intermediate replaced the reference:** SB keeps A and S, so C fires a
  definite fall from A in both patches together; `red-extremum`.
- **P1-2, an early-band fire latched:** a possible-only fire keeps the box, so C still fires;
  `red-early-band`.
- **P1-3, RGBA16UI clamp:** the marker, exact `UNTRACKED`, and the host format check (section 6).
- **P2-1, one grant, two auditor charges after a zero restart:** one red event a frame (section 7);
  `red-zero-mixed`.
- **P2-2, stripes over the window limit alone:** 16-column stripes and the per-stripe and
  frame-8 assertions (section 9).
- **P2-3, a 0.094 saturated/far alternation held 54 of 120 frames:** the up test now needs a far
  state possibly more than 0.2 away, not any far state; never held (section 9).

Round 2, widened memory with SB and FB boxes (HOLD); the fixes are in section 13.

## 13. Codex design round 2 and the certain bit

- **P1-A, a clearing fire from a spent code.** A box's edge strip proves a stored code only while
  every code the box was built from is still a reference. After a fire that cleared nothing, the
  box keeps codes the fire already discharged beside live ones; a later definite step from a spent
  code cleared the live ones too, and two adjacent 8 x 5 patches at 240 Hz then flashed four times
  in 0.967 s with nothing held. Verified against an independent float reference (exact colours,
  cleared at each fire): 80 pixels crossed together at frames 31 to 263, over the field's limit
  of 63.
- **The certain bit.** Each box carries an *uncertain* bit (SB: z bit 15; FB: w bit 31), zero
  meaning certain, so the seeds are unchanged. A fire clears its box (known, empty, certain) only
  when the box is certain and definitely over, or, for SB, when c is very far. Otherwise it clips
  the box to the cells that overlap the closed interval [c - R, c + R] on each axis, c the current
  colour's code and R = 3285 codes (R squared = TH; 3285 / 16384 - 2E > 0.2), and the box is
  uncertain if any cell remains. While a box is certain, unions keep a live witness in each edge
  strip. A code more than R from c on either axis is more
  than 0.2 away, so it was a reference the fire discharged; the codes kept may be discharged too,
  which only over-counts. An unknown box stays unknown at a fire that does not clear it.
- **P1-B, a zero restart that kept the auditor's boxes.** After a zero restart the limiter's
  unknown boxes and the auditor's kept boxes cleared at different fires, and the auditor counted
  20 red transitions a second that the limiter never fired (the alternating pair is 0.183 apart,
  so this was a limit violation of the auditor, not a flash). The auditor now makes both boxes
  unknown at a zero restart (section 7).
- **P3, the format check reads one attachment.** A host writes and reads back an unsigned 32-bit
  value on each tracker attachment of the ping-pong pair before seeding (section 6).
- **P3, `UNTRACKED` against the marker.** The exact `UNTRACKED` texel takes precedence over the
  validity rule: it takes its first colour without firing.
- **Cost.** The clip keeps codes a definite step could discharge, so a box that has gone uncertain
  fires possible-only steps until a clip empties it. A 20 000-seed single-pixel fuzz against the
  float reference misses nothing on either rule; possible-only fires rise from 114 594 to
  145 514. The two P1-A patches are held for most of the cycle.
- **Vectors.** `red-uncertain-box` (the P1-A patches at 60 Hz), `red-zero-retained` (P1-B), and a
  240 Hz P1-A test with the float reference in `test-limiter.mjs`.
- **Round 3 (Codex, delta to this section).** No P1. P2: a zero restart before the auditor's
  first frame was overwritten by that frame's known boxes, so a limiter red fall from its unknown
  seed went uncounted (an auditor gap, not a flash); the auditor now steps its first frame from
  the zero seed as the limiter does, with a test. P3s: the clip interval above, the float
  reference's inclusive saturation test, and the 60 Hz regression named as the stored vector.
- **Code review round 1 (Codex).** No P1. P2: the auditor's zero-seeded first frame stepped the
  boxes but dropped the direction, so a first frame of (0, 0, 1) went uncounted where the limiter
  fell; the auditor now counts it, with a test. P3s: the invalid-texel wording (it fires and
  counts toward the area limit; the format check keeps it off screen), exact `UNTRACKED`, and the
  probe before the seed. The CORE-2869 restart-report test now expects the red transition at
  (5, 0, 0) after a zero restart as a rise: the zero seed's unknown boxes fire it (the merged
  direction), as the limiter does from the zero texel.
- **Code review delta round 1 (Codex).** No P1. P2: the auditor's zero-seeded first frame kept a
  counted red memory where the zero texel's is unknown, so after a zero start on (18, 0, 5) the
  limiter fell at the first saturated output (frame 81) and the auditor missed it. A zero restart
  before the first frame now seeds the auditor with the zero texel's whole state (both trackers
  falling at 0, the red memory and the boxes unknown) and steps the frame from black; the red
  memory gains the unknown state redStep has. A regression test fails on the old auditor. A fuzz
  of 200 zero-started full-frame runs (1 to 4 colour runs, saturation-edge reds among them) finds
  no frame where the limiter fires a channel the auditor does not record; on the same runs the old
  auditor missed red falls and the luma rise from black of a bright first output. P3s: the
  16-bit store wording (a zero seed survives) and the probe value (it passes the marker check,
  not a written state).
- **Code review delta round 2 (Codex).** PASS, no findings.
- **Status.** The design and code reviews are closed.
