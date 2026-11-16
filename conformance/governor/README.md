<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Governor vectors

`reference.json` records 18 sequences evaluated by the pinned TypeScript
`PerfGovernor` at `7caa4d1`. Each step repeats its cyclic `samples` list `count`
times and records the resulting level, EMA and refresh estimate. It ports source
cases for default level, sustained/isolated overload, jitter, 60/120 Hz recovery,
hysteresis, pause gaps, outlier capping, floor/ceiling, settling and reset. Added
boundary cases pin exact threshold comparisons and the 250 ms pause boundary.
Tolerance is 1e-12 for measurements and exact for levels/initialization state.

`validation.json` is an Oscillux extension; the TypeScript reference has no such
check. Create is refused unless `targetFrameMs` times each promote factor is
strictly below `targetFrameMs` times `demoteFactor`. Without that band one EMA
can satisfy both promotion and demotion targets, so the level oscillates. Cases
pin the boundary at, just below and above the demote factor, and a subnormal
target whose products collapse to one value.

`swift-comparison.json` comes from executing the actual Swift `FPSGovernor` at
`ce290a3`, with only its external tier enum stubbed in the scratch harness. Its
indices are normalized to ascending levels (`3 - index`). Shared cases port:

- `testSingleHitchDoesNotDemote`: 30 on-budget frames, 500 ms hitch, 30 on-budget.
- `testSustainedOverBudgetDemotes`: 200 frames at twice the target interval.
- `testPromotionStopsAtTopRung`: the matching initial level and 5000 frames at
  0.3 times the target interval.

The source `testSustainedHeadroomPromotes` scenario (400 frames at 0.4× target,
matching initial level) also runs in both evaluators: Swift finishes at level 3,
TypeScript at 2. Additional measured differences are 60 Hz recovery (Swift 1,
TypeScript 3) and paused cadence (Swift 0, TypeScript 3). These differences are
expected; TypeScript is authoritative. Full controller differences and the newer
Swift quality governor's non-equivalent host test families are documented in
`docs/portable-math.md`. No thermal, device or persistence authority is added.
