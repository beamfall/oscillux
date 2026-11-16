<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Pixel auditor counts sustained flashing

Ticket: **CORE-1623** (Corvint Tasks, beamfall core queue).

## Why

The catalog red audit reported more large-area luma transitions a second after the frame limiter
than before it on several visuals (for example tunnel 2 to 17 and wave-tunnel 2 to 13 on the
reference host). The region `FlashAnalyzer` oracle, run on the same frames, does not agree: it
counts the limiter's output at or below its input on 8 of the 10 listed visuals and one higher,
within budget, on the other two, and it counts the inputs at up to 60 transitions a second where
the auditor counted 2.

The fault is in the pixel auditor (`tools/shader/limiter-audit.mjs`). It counted a large-area
transition only at the rising edge of its over-area condition: pixels that made the transition
within the coverage interval (1000/15 ms) covering more than a quarter of a field window. While
flashing is sustained, either at more than 15 Hz or as a moving pattern that keeps a large area
changing, that condition never clears, so the auditor counted one transition for the whole run.
The limiter breaks such runs into separate admitted steps, each of which the auditor then
counted, so the limiter appeared to add transitions.

## What Changes

- The auditor counts a large-area transition at every frame where the pixels that made the
  transition within the coverage interval, and after the direction's previous large-area
  transition, cover more than the limit. Each pixel change counts toward at most one large-area
  transition; a single change of a large area still counts once.
- `tools/shader/test-limiter.mjs` gains 15 Hz and 30 Hz full-frame cases: the auditor must count
  2 x hz transitions a second on the input, and the limiter's output no more than 6 and no more
  than its input. Both fail with the previous auditor, which counts 2.
- The CORE-1623 evidence record holds the oracle and auditor measurements.

The limiter model, its GPU passes and the conformance vectors are unchanged.

## Non-goals

- Re-running beamfall-visual-shaders' flash-check and updating its `flash-known.json`. That needs
  an Oscillux release carrying this change (CORE-1895, then CORE-1911).
- The limiter defect the 61-visual sweep found with the fixed auditor and the oracle: on a few
  visuals the output has more transitions a second than the input, and on many it stays above
  6. Fixing that changes the limiter model, its GPU passes and the vectors, and is tracked as
  CORE-1915 (see the evidence page).

## Rollback

Revert the change. Only the audit tools and their tests change.
