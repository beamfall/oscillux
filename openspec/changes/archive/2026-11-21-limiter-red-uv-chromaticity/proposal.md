<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Count red transitions by the WCAG 2.1/2.2 u'v' chromaticity rule

Ticket: **CORE-2935** (P1), Corvint Tasks, beamfall core queue. Owner decisions 2026-11-21: "fix
CORE-2935 too", and after Codex design round 1 held the zone design, "Widen limiter memory".

## Why

The frame limiter and the pixel auditor count a red transition only by the WCAG 2.0 rule (and the
2018 edition of WCAG 2.1): a change of 20 on the 320 max(0, R - G - B) scale with one state
saturated red, R / (R + G + B) >= 0.8. The current WCAG 2.1 and 2.2 Recommendations give a second
working definition: one state saturated red and the two states more than 0.2 apart in the CIE 1976
UCS (u'v') chromaticity diagram.

Repro: a full-frame 10 Hz strobe between (60, 0, 0) and (0, 60, 0). The red codes are 11 and 0,
under the 15-code step, and the luma change is under 0.1, so the auditor counts nothing and the
limiter passes it whole. The two states are 0.328 apart in u'v': 20 red transitions, 10 flashes,
a second.

A sound u'v' rule measures from every saturated state a pixel showed since its last counted fall,
so a flash reached through intermediate states on different frames still counts (design.md,
section 12, P1-a and P1-1). That needs per-pixel chromaticity memory; the current tracker texel
has 4 free bits.

## What Changes

- **Integer u'v' codes.** Every non-black colour gets a 14-bit (u', v') code from a new 24-bit
  linear LUT, in 32-bit unsigned arithmetic, within 2.5e-4 of the true value under both sRGB
  matrices. A new saturated test, `s24`, matches float64 r >= 0.8 over every 8-bit colour.
- **Two boxes per pixel.** Each pixel keeps a box of the saturated codes it showed since its last
  definite fall and a box of the far codes since its last definite rise. A changed colour counts
  down when it may be more than 0.2 from the saturated box, and a changed saturated colour up when
  the far box may be more than 0.2 from it. A box clears only at a step surely over 0.2. Black
  changes nothing. A zero seed leaves both boxes unknown, which counts on a superset.
- **One red direction per pixel.** The u'v' direction when it fires, else the 320 rule's.
- **Tracker texel: RGBA32UI.** The low 16 bits of each word keep the current texel plus two
  known bits in z; the high 16 bits hold the boxes and a marker. "Black, nothing owed" becomes
  (0, 32768, 2147508224, 0); zero is unchanged and `UNTRACKED` is matched exactly. A texel without
  the marker (a 16-bit store) fires every direction at a changed colour.
- **Auditor.** `limiter-audit.mjs` keeps the same state from the same functions.
- **Legs.** `common.glsl`, `output.glsl`, `rows.glsl`, the generated LUT and every generated leg.
- **Checks.** `tools/shader/limiter-uv-check.mjs` verifies the codes, thresholds and zones over all
  2^24 colours in `make limiter-check`.
- **Vectors.** Dim red/green, red/blue, the 320/u'v' direction mask, dim red on black, a 5 Hz red
  flash over half the frame, the Codex repros (staggered stripes, extremum patches, early band,
  constant red and mixed history after a zero start). Existing cases keep holds and grants; six
  change held colours or a zero-start's output, each explained in design.md section 9.
- **Visuals.** The 61 release visuals are probed once in the web player; any over 0.5% of pixels
  held a frame is calmed.
- **Docs.** The model and auditor headers, `shaders/limiter/README.md` and `CHANGELOG.md`.

## Impact

- Safety: the limiter covers the WCAG 2.0, 2018 WCAG 2.1 and current WCAG 2.1 and 2.2 red
  definitions.
- **Host contract change.** Tracker textures become RGBA32UI: 16 bytes a pixel per copy, 265 MB
  for both copies at 3840 x 2160 (was 133 MB). The new "black, nothing owed" seed has z
  2147508224. A host checks the format at start (clear, read back, black on mismatch) and binds
  `uHist` to the rows pass. The web renderer changes with the core repin to v0.2.13; Apple and
  Android change at their repins.
- A host that starts at zero after a short black updates pixels whose colour keeps changing
  between saturated and far codes about once per red grant (1.33 s) until their boxes are known.
  The web player always starts black.
- Release: v0.2.13.
