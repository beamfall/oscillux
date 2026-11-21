<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Count red transitions by the WCAG 2.1/2.2 u'v' chromaticity rule

Ticket: **CORE-2935** (P1), Corvint Tasks, beamfall core queue. Owner decision 2026-11-21: "fix
CORE-2935 too": the limiter adopts the current reading.

## Why

The frame limiter and the pixel auditor count a red transition only by the WCAG 2.0 rule (and the
2018 edition of WCAG 2.1): a change of 20 on the 320 max(0, R - G - B) scale with one state
saturated red, R / (R + G + B) >= 0.8. The current WCAG 2.1 and WCAG 2.2 Recommendations give a
second working definition: a pair of opposing transitions where one state is saturated red and the
two states are more than 0.2 apart in the CIE 1976 UCS (u'v') chromaticity diagram.

Repro: a full-frame strobe between (60, 0, 0) and (0, 60, 0) at 10 Hz. The red codes are 11 and 0,
under the 15-code step, and the luma change is under 0.1, so the auditor counts no transition and
the limiter passes it whole. The two states are about 0.33 apart in u'v', so the current definition
counts five red flashes a second.

The model's header says the u'v' rule cannot be carried bit for bit in integer codes. It can: the
rule reduces to a three-zone classification of each colour, and the classification is three
integer conics with no overflow (design.md).

## What Changes

- **Red zones.** Every colour is saturated red (S, the existing `redSat`), far (F: not saturated
  red, and more than 0.2 in u'v' from some saturated-red chromaticity), or near (M, black
  included). One integer classifier (`redZone` in `limiter-model.mjs`, `limiterZone` in
  `shaders/limiter/common.glsl`) serves the limiter and the auditor. It may call a near colour
  far (0.085% of 8-bit colours), never a far one near and never a saturated one far, as checked
  over every 8-bit colour.
- **A side per pixel.** Each pixel remembers the side, S or F, it last showed. Showing S after F
  is a red transition up, and F after S a red transition down. Near states keep the side. Every
  WCAG u'v' transition is such an alternation (design.md, section 1), so the rule counts every
  one, and a few that are not.
- **Union with the 320 rule.** A red transition is counted where either rule counts one. The red
  step returns a direction mask, so one frame may count a red rise by one rule and a red fall by
  the other.
- **Tracker state.** The side lives in the red tracker word's free bits 13 and 14. The seeds keep
  their texels: zero (red memory unknown) decodes as side unknown, whose first S or F state counts.
  `BLACK_TEXEL` decodes as no side, so nothing is owed. A pixel's first value under `UNTRACKED`
  takes its zone as its side without counting.
- **Auditor.** `limiter-audit.mjs` keeps the same side per pixel, from the same `redZone`. It sets
  the side at its first frame, clears it at a black reseed, and keeps it at a zero restart.
- **Legs.** The GLSL limiter passes (`common.glsl`, `output.glsl`, `rows.glsl`) and the generated
  legs carry the classifier and the side.
- **Vectors.** The new cases are the 10 Hz (60, 0, 0) / (0, 60, 0) strobe, a saturated red against
  far colours, and dim red on black, which counts nothing. Every existing case keeps its outputs,
  holds and grants unless the new rule applies to it. Only its tracker digests change, because the
  side is stored.
- **Visuals.** The 61 release visuals are probed again in the web player. Any that the stricter
  rule pushes over 0.5% of pixels held per frame is calmed.
- **Docs.** The model and auditor headers, `shaders/limiter/README.md` and `CHANGELOG.md` name the
  rule. They stop calling it unmodelled.

## Impact

- Safety: the limiter now covers WCAG 2.0, the 2018 edition of WCAG 2.1, and the current WCAG
  2.1 and 2.2 red definitions.
- Hosts: no API change and no new seed. A host that starts at zero after a short black now holds
  far-coloured pixels until the red grant, about 1.33 s at 3 Hz. The web player always starts
  black, so it is not affected.
- Release: v0.2.13, then the core repin moves from v0.2.12 to v0.2.13.
