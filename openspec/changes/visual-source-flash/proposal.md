<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Visuals keep within the general flash limit before the limiter

Ticket: **CORE-2492** (P1); related CORE-2484 (high-hold visuals) and CORE-1915 (limiter output
above 6/s). Owner request 2026-11-18: avoid flashes so visuals are not uncomfortable; find them
and reduce or remove them.

## Why

- Under loud audio, 28 of the 61 reference visuals make more than 6 large-area luma transitions a
  second on their own output (laser-tunnel 56, murmuration 47, photo-topo 42, ripple 42 ...), and
  volumetric-light makes red transitions. The frame limiter catches them by holding sub-blocks,
  which shows as stale tiles: comfort and artifacts share one cause.

## What Changes

- Each offending visual moves its beat response from large-area brightness into motion, scale or
  thin accents, softens attacks, or slows and lowers the contrast of large moving patterns. Every
  visual still passes the beat-response lint.
- `limiter-red-audit.mjs --max-luma N` fails (exit 4) a visual whose own output makes more than N
  large-area luma transitions in any second or any red transition.
- `make visual-flash-check` runs the audit under loud audio with a budget of 6. It is not part of
  `make gate` (it takes minutes on SwiftShader).

## Non-goals

- Changing the limiter; it remains the safety net.

## Failure modes

- A visual becomes dull; motion carries the beat instead, checked by beat lint and on renders.

## Acceptance evidence

- `make visual-flash-check` passes on every reference visual, or an owner-recorded exception.
- Beat lint passes; no visual's limiter held fraction rises.

## Rollback

Revert the source changes. Release and host adoption remain with the orchestrator.
