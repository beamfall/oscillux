<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Limiter conformance

This limiter ports the owner's scalar onset reference at `0b4e16f5c`. It maintains
fixed three-entry general/red flash windows. Frame processing and reset do not
allocate, lock or perform I/O. A host supplies the frame signals and applies the
attenuated result to its renderer. These proxy signals do not measure rendered
pixels or establish physical display compliance.

The frame flash limiter, which measures rendered pixels on the GPU, has its own model and vectors
in [`frame/`](frame/README.md) and its passes in [`shaders/limiter/`](../../shaders/limiter/README.md).

## Oracle and vectors

The uncommitted scratch Go test `TestZZDumpLimiterVectors` calls the pinned
`AnalyzeFlashSequence`, `ClampFlashSequence` and `ValidatePhotosensitivityManifest`
against the reference tests and conformance cases. Regeneration ran with
`GOWORK=off`, `LIMITER_DUMP_DIR` pointing to scratch storage, and
`go test "$REFERENCE_PACKAGE" -run '^TestZZDumpLimiterVectors$' -count=1`.
Only case provenance labels were omitted when wrapping the generated arrays in
this directory's existing `description`, `tolerance` and `cases` envelope.

The regenerated arrays differ from the preserved arrays in exactly one scalar:
`reference-sequences.json`, case `regular-triplet-third-flash-blocked`, third
clamped frame (500 ms), `broadband`: **0.8 → 0.4**. The oracle's `attenuateFlash`
sets this to half its 0.8 flash threshold; the reference test requires the third
regular flash below threshold. Its existing clamped analysis already expected
two flashes. Every other value and case was retained.

The 48 vectors comprise five Go sequence cases, fifteen Go policy-validation
cases, five explicit red/area extension sequences, five tighten-only policy
cases, seven timeline cases (see Untrusted timelines) and eleven cadence cases
(see Real cadences). Comparisons are exact (tolerance zero), including negative policy cases
and analysis before/after limiting. Input references have red=0 and area=1;
red/area vectors specify the added behavior independently of the Go oracle.
Fixtures are embedded, so identical tests run on host and WASI.

## Defaults and standards mapping

The three numeric Go maxima are retained. The red budget extends its model.
Primary sources were checked against WCAG 2.2 and BT.1702-3 (11/2023).

| Policy default | Mapping and limit of the mapping |
| --- | --- |
| `max_flash_hz = 3` | WCAG SC 2.3.1 and BT.1702-3 Annex 1, Guideline 1 use a three-flash threshold per second. |
| `max_luminance_delta = 0.8` | Go's onset proxy ceiling. WCAG's 0.80 describes the darker image, alongside opposing changes ≥0.10; it is not a permitted luminance delta. BT.1702 uses physical luminance/contrast thresholds. No clause equates the Go proxy to those measurements. |
| `max_flash_area = 0.25` | BT.1702-3 Annex 1, Guideline 1 uses displayed-screen area. WCAG's threshold instead concerns 25% of any 10-degree visual field (0.006 sr). Hosts must measure the applicable geometry. |
| `max_red_flashes = 3` | WCAG's general/red flash threshold and BT.1702-3 Annex 1, Guideline 1 address saturated-red transitions. The scalar `red >= 0.8` input is an extension proxy, not a chromaticity detector. |
| `strobe_banned = true` | The reference additionally suppresses near-regular general-flash triplets. Neither standard requires that exact three-event/25%-spacing heuristic; it is a stricter reference rule. |

Sources: [WCAG SC 2.3.1 and threshold definitions](https://www.w3.org/WAI/WCAG22/Understanding/three-flashes-or-below-threshold.html),
[BT.1702-3, Annex 1 Guideline 1](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.1702-3-202311-I!!PDF-E.pdf).
Rendered transitions, colorimetry, area and output scaling remain host
responsibilities for this proxy interface; the region flash analyzer below
measures luminance and area from host-supplied per-region values. Neither
interface analyzes HDR luminance or detects spatial patterns.

## Tightening and boundary behavior

Looser policies are refused, never silently clamped. Numeric ceilings must be
positive and finite, no higher than their defaults. Red counts accept 0 through
3; zero admits no above-area red flash. The strobe flag must stay enabled; its C
representation accepts exactly `uint32_t(1)`, avoiding invalid Rust booleans.

Reference corrections for arbitrary tightened policies are deliberate:

- A fractional rate admits only an integer count within that budget; a rate
  below one admits no qualifying general flash. Testing the prospective count
  prevents the reference's fractional-ceiling overshoot.
- Flashes are detected on the input, before the luminance cap. A cap below the
  0.8 flash threshold therefore cannot hide flashes from the budget: admitted
  flashes are lowered to the cap and refused ones to 0.4 and then the cap, so
  tightening the cap never raises an output onset or changes which flashes are
  admitted. (Judging the capped signal made a 0.79 cap admit every 60 Hz flash
  at 0.79; refusing caps below 0.8 instead would forbid tightening the cap.)
- Luminance caps are rounded down to six decimals, never above the configured
  value; tiny positive caps may therefore yield zero. Analysis retains the exact
  peak so an excess smaller than 1e-6 cannot disappear through rounding.
- Non-finite or decreasing timestamps and scalars outside finite [0,1] are
  rejected before state mutation. The C and WASM APIs then write the fail-safe
  frame (every scalar 0, `time_ms` from the input), which the host renders.

Windows exclude events exactly 1000 ms old, matching Go. Equal timestamps are
allowed. Input/output frame storage may alias in the C API.

## Untrusted timelines

The limiter has no clock, so it trusts a timestamp only as far as a continuous
stream needs:

- A forward gap of at most 250 ms (`MAX_CREDITED_GAP_MS`, a quarter window) is
  elapsed time. A larger gap is a discontinuity and credits none: admitted
  flashes keep their age. A far-future timestamp therefore cannot empty the
  window, and emptying a full window takes at least four frames. A host that
  presents below 4 Hz, or resets before every frame, never credits time: once
  its window is full (after two flashes when strobes are banned), every later
  flash is attenuated.
- Reset starts a new timeline, as at a seek: the next frame may carry any finite
  timestamp, including an earlier one, and is a discontinuity. Admitted
  flashes are kept at their age because the viewer's exposure does not restart.
  Resetting every frame cannot admit more than the budget. Create a new limiter
  to forget the history.
- The real length of a gap that spans a discontinuity is unknown, so under the
  strobe ban it counts as regular: a flash that would form a triplet across
  such a gap is attenuated.
- A decreasing timestamp without a reset is still refused; the host recovers
  with reset.

The bound holds only for a host that reports its gaps truthfully. Inflated gaps
of 250 ms or less are credited in full: at 60 Hz, a 10x unit mistake (167 ms per
frame) admits 30 flashes per real second, and timestamps falsified to 250 ms per
frame admit 40. Only a mistake above 15x (gaps above 250 ms) credits
nothing. Closing this needs a trusted clock, which the limiter does not have.
Continuous streams are processed exactly as before, so every earlier vector is
unchanged.

`timeline-sequences.json` specifies resets, gaps on both sides of 250 ms, the
strobe ban across discontinuities and fail-safe output for refused frames. Its values are derived by hand from these
rules.

## Real cadences

For each frame the limiter applies these rules, in order, to the input:

1. A general flash (broadband ≥ 0.8 over more than the flash area) is admitted
   unless the flashes already admitted less than 1000 ms ago, plus this one,
   would exceed `max_flash_hz`, or, under the strobe ban, this one and the two
   most recently admitted flashes in that window are a regular triplet (outer
   span under 1000 ms, gaps within 25% of the larger). A refused flash has its
   broadband set to 0.4 and its other onsets lowered to 0.4.
2. A red flash (red ≥ 0.8 over more than the flash area) is admitted unless
   `max_red_flashes` red flashes were admitted less than 1000 ms ago; a refused
   one has its red set to 0.4. There is no red strobe rule.
3. Every onset is lowered to the luminance cap.

`cadence-sequences.json` runs these rules at real frame rates: every-frame
flashes at 60, 120 and 144 Hz with timestamp jitter (one spacing 0.0625 ms inside
the 25% strobe boundary), regular flashes at 2.9 and 3.1 Hz on a
60 Hz grid, slow onset ramps below and through the threshold, mixed general,
red, combined and small-area frames, a mid-stream change from 60 to 144 to 30
to 4 Hz, and tightened caps of 0.79 and 0.6. Every gap is at most 250 ms. Each
case's `derivation` gives its admitted flashes, worked out by hand from the
rules above. `tools/limiter-cadence-vectors.py` writes the file only when those
agree with its own model of the rules, written from this README rather than
the Rust source; times are multiples of 0.25 ms, so every comparison is exact.
Regenerate with `python3 tools/limiter-cadence-vectors.py >
conformance/limiter/cadence-sequences.json`.

`crates/oscillux-core/tests/limiter_properties.rs` feeds 400 fixed-seed random
sequences (mixed cadences, jitter, uncredited gaps, tightened policies) through
the limiter and back through `analyze`, and requires that no window exceeds the
policy, that the same holds with the cap relaxed to 0.8, and that tightening
the cap only lowers onsets to it.

Focused tests cover all vectors, fractional/tiny ceilings, zero red, exact window
expiry, reset abuse, fast or far-future timestamps, invalid input without
mutation, fail-safe output, C policy validation, and zero
allocations over 2000 C process calls plus reset. The existing automatic export
and compiled layout probes include the new limiter module and structures.

## Region flash analyzer

`FlashAnalyzer` (C: `OscilluxFlashAnalyzer`) measures flashes from what is on
screen instead of proxies. For every frame the host supplies, per region of a
uniform row-major grid of `columns` by `rows` (each 1 to 16, so at most 256
regions in fixed storage), the region's mean relative luminance and its
saturated-red level, both in [0, 1]. `measure` and `admit` do not allocate,
lock or perform I/O; only create allocates.

### Standards mapping

- **General flash** (WCAG 2.0-2.2 "general flash and red flash thresholds"): a pair
  of opposing changes in relative luminance of 10% or more where the relative
  luminance of the darker image is below 0.80. Here a change of at least 0.1 is
  `>= 0.1` and the darker image must be `< 0.8`.
- **Red flash**: WCAG 2.0, 2.1 and 2.2 all define a red flash as "any pair
  of opposing transitions involving a saturated red" and give a numeric
  working definition in a note (Note 3). The analyzer implements both notes;
  `red_rule` (C `OSCILLUX_FLASH_RED_RULE_*`, Rust `RedRule`) selects one.
  - **WCAG 2.0** (`red_rule = 0`, the default, and the only rule a config of
    the first released size, 48 bytes, can select): the Harding/Binnie rule. A
    saturated red has `R / (R + G + B) >= 0.8` and the change in
    `(R - G - B) * 320`, negatives set to 0, exceeds 20. With channels
    normalized to [0, 1] the change is in `R - G - B` and must exceed
    `20 / 320 = 0.0625` (exact in binary). A region's red level is
    `(R - G) - B` when `R / (R + G + B) >= 0.8` and 0 otherwise, so a change
    from an unsaturated color is measured from 0. That can only overstate a
    change (it ignores the unsaturated side's own `R - G - B`), never hide one.
  - **ISO 9241-391** (`red_rule = 1`), the rule the WCAG 2.1 and 2.2 notes
    cite: a pair of opposing transitions in which each transition has a
    saturated red (`R / (R + G + B) >= 0.8`) at one end and its two states
    differ by more than 0.2 in the CIE 1976 UCS (u'v') chromaticity diagram. A region's state is then a color, not a level,
    so this rule takes whole colors (`measure_rgb` / `admit_rgb`) and refuses
    the sample path. See Model step 2a.
- **Area**: flashes fail only when their combined area occupies more than 25%
  of any 10-degree visual field, 0.006 sr at typical viewing distance
  (a 10-degree cone is about 0.024 sr; 25% of it is 0.006 sr). WCAG
  approximates the field as a 341 by 256 pixel rectangle on a 1024 by 768
  screen, a third of each axis and so about 11.1% of the screen; the 25%
  threshold is a quarter of that rectangle, about 2.8% of the screen. (It is
  not 25% of the screen.)
- **Rate**: more than three general or three red flashes in any one-second
  window fails.

### Model

1. **Relative luminance and red.** `oscillux_flash_region_from_linear_rgb`
   (Rust `RegionSample::from_linear_rgb`) takes a region's mean linear-light
   color, channels in [0, 1], and returns luminance
   `min(1, (0.2126 R + 0.7152 G) + 0.0722 B)` and the red level above
   (`R + G + B = 0` gives red 0). Linearizing sRGB or other encodings, and
   averaging a region, are host responsibilities.
2. **Per-region changes.** Each region tracks its luminance and its red level
   separately. The first frame sets the baseline. A tracker is *steady* with
   the low and high seen since the baseline, or follows a *rise* or a *fall*
   from a start value to the running extreme:
   - steady: a value at least the change above the low starts a rise from the
     low; at least the change below the high starts a fall from the high;
     otherwise the low and high take in the value;
   - rise: a value at or above the extreme becomes the extreme; a value at
     least the change below the extreme starts a fall from the extreme;
     anything else (a smaller dip) is ignored;
   - fall: the mirror image.

   The change is `>= 0.1` for luminance and `> 0.0625` for red. A run of either
   kind *completes a change* on the first frame at which its darker end is
   below 0.8 (luminance: the start of a rise or the extreme of a fall; red:
   always, on the frame the run starts). Each run completes at most once, so
   completed changes alternate in direction and two make one flash.

   **2a. ISO 9241-391 red changes.** Under `red_rule = 1` the red channel of
   step 2 is replaced; luminance is unchanged and still comes from the color
   as in step 1. Chromaticity uses the sRGB/D65 matrix the WCAG 2.2
   Understanding page gives, applied to the linear channels and evaluated left
   to right without fused multiply-add:
   `X = (0.4124564 R + 0.3575761 G) + 0.1804375 B`,
   `Y = (0.2126729 R + 0.7151522 G) + 0.0721750 B`,
   `Z = (0.0193339 R + 0.1191920 G) + 0.9503041 B`,
   `D = (X + 15 Y) + 3 Z`, `u' = 4X / D`, `v' = 9Y / D`. A state is saturated
   red when `R / ((R + G) + B) >= 0.8`, and *black* when `D = 0` (R = G = B
   = 0). Each region keeps the set of states since its last red change, as a
   bounding box of the chromatic states, a bounding box of the saturated ones
   and a black flag. A new state C completes a red change when, against some
   state in the set, one of the pair is saturated red and the two differ by
   more than 0.2 in u'v':
   - C black: when the set holds a saturated red;
   - C saturated red: when the set holds black or any chromatic state
     farther than 0.2;
   - otherwise: when the set holds a saturated red farther than 0.2.

   "Farther" uses the box's farthest corner from C,
   `sqrt(du^2 + dv^2) > 0.2` with `du = max(|u - u0|, |u - u1|)` and `dv`
   likewise, so it can report a change that no single held state makes but
   never misses one. On a change the set becomes {C}; otherwise C joins it.
   Every red change counts as a completed change for the field window, and
   two make one red flash, exactly as in step 2.

   Ambiguities in the ISO note, resolved conservatively (toward counting):
   - *Linear or encoded RGB.* The Understanding page's matrix converts linear
     sRGB to XYZ, so R, G and B are the same linear-light channels as step 1;
     the 0.8 saturation ratio is taken on them too.
   - *Black.* Black has no chromaticity. A change between black and a
     saturated red counts, since it is the strongest red flash.
   - *No luminance floor.* The ISO note has none; neither does this rule, so a
     very dark saturated red can count. The general flash rule's 0.8 darker-
     image condition does not apply to red.
   - *Matrix rows.* The matrix Y row (0.2126729, 0.7151522, 0.0721750) is not
     step 1's luminance (0.2126, 0.7152, 0.0722). It is used only for
     chromaticity, so luminance and the general flash rule are unchanged.
   - *Opposing transitions.* Chromaticity has no direction, so any two
     consecutive red changes are taken as opposing and make one flash.
   - *Small steps.* A drift of many steps each 0.2 or less still counts once
     its total distance from a held saturated red exceeds 0.2.
3. **Field window.** The 10-degree field is a policy input: `field_width` and
   `field_height` are the fractions of the viewport width and height it covers,
   in (0, 1], default 1/3 each (the WCAG 341 by 256 rectangle on 1024 by 768).
   A host that knows its viewing distance and screen size computes them; a
   screen smaller than the field uses 1. The window is
   `clamp(floor(field_width * columns + 0.5), 1, columns)` by the same for rows,
   in whole regions, and slides over every grid position. On each frame and
   for each channel, if some window position holds more than
   `max_field_area * window_regions` regions completing a change
   (`max_field_area` in (0, 0.25], default 0.25 = 0.006 sr / 0.024 sr), the
   frame is one screen-level *transition*.
4. **Rate.** Transitions are kept per channel; a transition stays in the window
   while it is less than 1000 ms old. A frame *exceeds* when the general window
   holds more than `2 * max_flash_hz` transitions (`max_flash_hz` in (0, 3]) or
   the red window more than `2 * max_red_flashes` (`max_red_flashes` 0 to 3).
   Reports give flashes as half the transitions, so 3.5 flashes (seven
   transitions) exceeds three.
5. **Measure and admit.** `measure` always commits the frame. `admit` refuses a
   frame whose transition would put more than the allowed transitions in its
   window: the frame is reported with `admitted = 0`, every region keeps its
   tracker state and the windows keep every unexpired transition, and the host
   must keep presenting the last admitted image, so the next frame is compared
   with that image. The refused frame's time still counts: it becomes the
   previous frame time for the gap rule, it ends a pending discontinuity (step
   6), and transitions 1000 ms old at that time leave the windows. A frame with no transition,
   or one within budget, is committed. Re-measuring the displayed images
   therefore never exceeds.
6. **Timelines.** Timestamps follow the limiter rules (Untrusted timelines): a
   forward gap above 250 ms, and the first frame after reset, credit no elapsed
   time, so transitions keep their age; reset keeps each region's last image.
   Invalid input (non-finite or decreasing time, a region count other than
   `columns * rows`, a value outside finite [0, 1], or region samples under
   the ISO 9241-391 rule) is refused before any state changes; the C API then
   writes a zeroed report with `admitted = 0`. Under WCAG 2.0, `measure_rgb`
   and `admit_rgb` give exactly the reports of `from_linear_rgb` followed by
   `measure` and `admit`.

Thresholds compare `f64` differences exactly as computed, so a decimal step
can land on the wrong side of a threshold: `0.6 - 0.5` is
`0.09999999999999998`, which is not a change of at least 0.1. Hosts and
vectors that need a change to sit exactly on a threshold should use dyadic
levels (such as 0.5, 0.25, 0.125 or 0.0625), whose differences are exact.

The three ceilings are tighten-only; the grid and field are measurements and
are only range-checked. Defaults: 16 by 16 grid, field 1/3 by 1/3 (a 5 by 5
region window, so seven flashing regions are a flash), `max_field_area` 0.25,
`max_flash_hz` 3, `max_red_flashes` 3, `red_rule` WCAG 2.0.

**Pattern detection is not supported.** WCAG 2.3.1 and BT.1702 also restrict
regular spatial patterns (stripes, checkerboards). This analyzer counts only
temporal luminance and red changes; hosts must check patterns separately.

**Limits.** Concurrency is judged per frame, so changes in one window that
complete on different frames are not combined. A region's mean can dilute a
flash that covers part of it; finer grids reduce this. The grid is at most
16 by 16. Each window holds at most 256 transitions and then drops the oldest,
which still reports far more than any allowed count. The analyzer measures the
values it is given; it does not see the rendered output.

### Vectors

`region-sequences.json` holds sequence cases, `from_linear_rgb` colors and
config validation. Each sequence case gives its config, mode (`measure` or
`admit`), frames (`t` in ms, `luminance` and `red` as one value for every
region or a row-major array, or `rgb` as one linear `[r, g, b]` for every
region or a row-major array of them, optional `reset`) and the expected report
for every frame. `config.redRule` is 0 (WCAG 2.0) or 1 (ISO 9241-391); `rgb`
frames go through `measure_rgb` / `admit_rgb`. Times are multiples of 0.25 ms; 60 Hz frames fall at `50k`,
`50k + 16.75` and `50k + 33.25`. Most cases use a 6 by 6 grid with the default
field, so the window is 2 by 2 regions and more than one flashing region in
any 2 by 2 block is a transition.

Derivations by hand (transition times; `k` counts from 1):

- `full-screen-0.15-10hz-measure`: every region alternates 0 and 0.15 every
  50 ms (0.15 when `floor(t / 50)` is odd), 60 Hz, 0 to 1983.25 ms. Each
  alternation is a change of 0.15 >= 0.1 whose darker image is 0, so all 36
  regions complete a change at every `50k`, k = 1 to 39. The window holds
  `min(k, 20)` transitions at 50k, so it first exceeds at 350 (seven
  transitions, 3.5 flashes) and peaks at 20 (10 flashes).
- `full-screen-0.15-10hz-admit`: the same frames admitted. Transitions at 50
  to 300 fill the window (six). Every later 0.15 frame would rise from the
  held 0 image and is refused; 0 frames match it and are admitted. At 1050 the
  transition at 50 is 1000 ms old and has left, so 1050 is admitted, then 1100,
  1150, 1200, 1250 and 1300 as each earlier one leaves; from 1350 the window is
  full again. Admitted transitions: 50, 100, 150, 200, 250, 300, 1050, 1100,
  1150, 1200, 1250, 1300. The displayed sequence never holds more than six
  transitions (three flashes).
- `localized-block-10hz-measure`: regions 14, 15, 20 and 21 (rows 2 and 3,
  columns 2 and 3; 4 of 36 regions, 11.1% of the screen) alternate 0 and 0.5
  every 50 ms to 1133.25 ms; the rest stay 0. The 2 by 2 window at that block
  holds four completing regions, more than one, so every `50k`, k = 1 to 22, is
  a transition: exceeds from 350, peak 10 flashes. The proxy limiter's screen
  area rule (more than 25% of the screen) would not count this block.
- `localized-block-10hz-admit`: as above, admitted: 50 to 300, then 1050 and
  1100.
- `single-region-not-a-flash`: region 14 alternates 0 and 1 every 50 ms. One
  region is 25% of a 2 by 2 window, not more, so no transition.
- `distant-regions-not-concurrent`: regions 0 and 35 (opposite corners) flash
  together; no window holds both, so no transition.
- `regions-straddling-window-tiles`: regions 1 and 2 (row 0, columns 1 and 2)
  flash together; the window at column 1 holds both, so 50, 100 and 150 are
  transitions.
- `diagonal-regions-in-one-window`: regions 0 and 7 ((0, 0) and (1, 1)); the
  window at (0, 0) holds both: 50, 100, 150.
- `darker-image-boundary` (1 by 1 grid, window 1 region): 0.8, 1, 0.8, 1, 0.75,
  1, 0.75, 1, 0.85, 0.78125 at 100 ms steps. Changes between 0.8 and 1 have a
  darker image of 0.8, not below 0.8: no transition. 0.75 counts (400, 500,
  600, 700). The fall from 1 to 0.85 (800) has its darker end at 0.85 and
  completes only when the fall reaches 0.78125 at 900. Transitions: 400, 500,
  600, 700, 900.
- `change-boundary-and-small-dips` (1 by 1): 0, 0.09375, 0, 0.1, 0.0625,
  0.046875, 0.125, 0.25, 0.1875, 0.3125, 0.1875 at 100 ms steps. 0.09375 is
  below the change; 0.1 above the low of 0 completes a rise at 300. Dips of
  0.0375 and 0.053125 below the extreme are ignored, the rise extends to
  0.3125, and the fall to 0.1875 (0.125) completes at 1000. Transitions: 300,
  1000.
- `red-8hz-measure` (2 by 1 grid, window 1 region): region 0 alternates red 0
  and 0.25 (luminance 0 and 0.05315, the color (0.25, 0, 0)) every 125 ms to
  1500 ms; region 1 alternates red 0 and 0.0625. Region 0's change of 0.25 >
  0.0625 completes at every `125k`, k = 1 to 12, with no general transition
  (0.05315 < 0.1); region 1's 0.0625 is not more than 0.0625. The red window
  holds `min(k, 8)`: exceeds from 875 (seven), peak 4 red flashes.
- `red-8hz-admit-one-red-flash` (`max_red_flashes` 1): 125 and 250 admitted;
  red frames refused until 125 has left; 1125 and 1250 admitted, 1375 refused.
- `uncredited-gap-and-reset` (1 by 1): 0 and 1 alternate at 100 ms steps from
  0 to 400 (transitions 100 to 400), then 1 at 2000. The 1600 ms gap credits
  nothing, so the four transitions keep their ages (now 1700 to 2000) and 2000
  is the fifth; 2100 and 2200 make seven, which exceeds. Reset, then 0 at 50:
  the earlier transitions keep their ages (-450 to 50) and 50 is the eighth.
- `default-grid-six-vs-seven-regions` (default 16 by 16 grid and field): the
  window is `floor(16 / 3 + 0.5) = 5` regions a side, 25 regions, so the area
  limit is `0.25 * 25 = 6.25` regions. Six regions (rows 0 and 1, columns 0 to
  2) rise from 0 to 0.5 at 50 and fall at 100: 6 is not more than 6.25, no
  transition. Seven (adding row 0, column 3, still inside the 5 by 5 window at
  (0, 0)) rise at 150 and fall at 200: 7 > 6.25, transitions at 150 and 200.
  Flashes per frame: 0, 0, 0, 0.5, 1.
- `red-rule-*` (1 by 1, frames every 125 ms). Hand chromaticities from the
  matrix above: a red primary `(r, 0, 0)` has `D = 3.6605516 r` and u'v'
  (0.45070, 0.52289) for every r > 0; a blue primary (0.17544, 0.15789); grey
  (0.19784, 0.46834), the D65 white point; pink (0.25, 0.03125, 0.03125) has
  `R / (R + G + B) = 0.8` exactly, so it is saturated, at (0.34234, 0.49951).
  Distances: red-blue 0.45715, pink-grey 0.14782, pink-blue 0.38020. No case
  changes luminance by 0.1, so none has a general transition.
  - `red-rule-scale-wcag20` and `red-rule-scale-iso` **separate the rules**:
    (0.5, 0, 0) and (0.25, 0, 0) alternate. WCAG 2.0 red levels 0.5 and 0.25
    differ by 0.25 > 0.0625: a red transition at every `125k`, k = 1 to 12,
    exceeding from 875, peak 4 red flashes. ISO 9241-391: both are the red
    primary's chromaticity, 0 apart: no red transition.
  - `red-rule-hue-wcag20` and `red-rule-hue-iso` separate them the other way:
    (0.0625, 0, 0) and (0, 0, 0.0625). WCAG 2.0: a change of 0.0625, not more
    than 0.0625: none. ISO: saturated red against blue, 0.45715 apart: every
    `125k`, exceeding from 875, peak 4.
  - `red-rule-wander-*`: grey, blue, pink, grey, blue, pink at 0 to 625.
    WCAG 2.0 red levels 0, 0, 0.1875, 0, 0, 0.1875: 250, 375, 625. ISO: 250
    (pink 0.38020 from blue), not 375 (grey 0.14782 from pink), 500 (blue
    0.38020 from pink), 625 (pink against blue): 250, 500, 625.
  - `red-rule-black-iso-admit` (`maxRedFlashes` 1): black and (0.25, 0, 0)
    alternate; black against saturated red counts. Admitted transitions 125
    and 250, red frames refused until 125 leaves, then 1125 and 1250.
  - Red plus grey, `(0.25, c, c)`, lies on the line from the red primary to
    the white point and is saturated while `c <= 0.03125`. At `c = 403/4096`
    it is (0.255220, 0.480715), 0.199982 from red; at `404/4096`,
    (0.255039, 0.480676), 0.200167 from red.
  - `red-rule-threshold-under-iso`: (0.25, 0, 0) and `c = 403/4096` alternate;
    0.199982 is not more than 0.2: no red transition.
    `red-rule-threshold-over-iso`: the same with `c = 404/4096`, 0.200167:
    every `125k`, exceeding from 875, peak 4.
  - `red-rule-drift-iso`: `c = j/128` at `125j`, j = 0 to 13, steps of at
    most 0.03746. The held saturated states (j = 0 to 4) put the box's
    farthest corner at the red primary, so each state is compared with its
    true distance from red: 0.19635 at j = 12, 0.20235 at j = 13. One red
    transition, at 1625 (the small-steps rule above).
  - `red-rule-box-corner-iso` pins the **conservative bounding-box
    behaviour, not strict Note 3**: (0.5, 0, 0.25) at (0.35167, 0.39157),
    (0.5, 0.125, 0.125) at (0.28979, 0.48817), then the red primary. Neither
    held state is more than 0.2 from red (0.16447, 0.16461), but the box
    corner (0.28979, 0.39157) is 0.20769 away, so 250 counts.
- `gap-250-credited` (1 by 1): 0 at 0, then 1 at 50 (a transition), 300, 550,
  800 and 1050. Each 250 ms gap is not above 250 and is credited, so at 1050
  the transition is 1000 ms old and has left: flashes 0, 0.5, 0.5, 0.5, 0.5, 0.
- `gap-250.25-uncredited` (1 by 1): as above but the steady frames are at
  300.25, 550.25, 800.25, 1050.25 and 1300.25. The 250.25 ms gap is above 250
  and credits nothing, so the transition is still age 0 at 300.25; at 1050.25
  it is 750 ms old and counts, at 1300.25 it is 1000 ms old and has left:
  flashes 0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.

The hand lists above are the independent check.
`tools/limiter-region-vectors.py` produces the reports from a Python model of
this section and asserts each hand list (and, for measure cases, the first
exceeding frame and the peak, and for the three cases just above the flashes
at every frame); it refuses to write the file if any disagree. Its per-region tracker follows the same steps as the Rust
analyzer and mirrors its logic, so it cross-checks the window, ring and
timeline bookkeeping rather than giving an independent reading of the tracker.
It also checks that re-measuring each admit case's displayed images never
exceeds. It writes
`from_linear_rgb` results from the documented expression and checks each within
1e-15 of its hand-computed decimal. Regenerate with `python3
tools/limiter-region-vectors.py > conformance/limiter/region-sequences.json`;
`python3 tools/limiter-region-vectors.py --check` exits 1 if the file differs.
`crates/oscillux-core/tests/limiter_regions.rs` compares every report exactly.

## Overlay regions

Opt-in (OSC-OVERLAY). `FlashAnalyzer::set_overlay` (C `oscillux_flash_analyzer_set_overlay`)
holds the grid cells covered by `MODE_DAMP_FLASH` overlay regions with nonzero strength
(`conformance/overlay/README.md`) to a stricter `FlashOverlay`:

| Field | Range | Default |
|---|---|---|
| `luminance_change` | (0, 0.1] | 0.05, inclusive |
| `darker_limit` | [0.8, 1] | 1.0 (any darker end counts) |
| `max_flash_hz` | [0, config `max_flash_hz`] | 1 |
| `max_area` | [0, config `max_field_area`] | 0 (one cell is a transition) |

Every cell keeps a second tracker on the overlay channel, committed with the frame, so an
overlay set later starts from the image shown. A frame is an overlay transition when more than
`max_area * cells` covered cells complete an overlay change. `admit` also refuses a frame
whose overlay transition would put more than `2 * max_flash_hz` overlay transitions in the
one-second window; the overlay ring follows the general ring's gap and window rules. `measure`
reports are unchanged by an overlay, and an analyzer without one measures exactly as before:
every existing vector is untouched. `overlay_report` gives the overlay outcome of the last
frame. A refused overlay keeps the previous one.

`overlay-sequences.json` holds 8 sequences (each frame as in `region-sequences.json`, plus
optional `setOverlay` and `clearOverlay`, and the expected general and overlay report) and 8
refusals. Regenerate with `python3 tools/limiter-overlay-vectors.py`; `--check` exits 1 if the
file differs.
