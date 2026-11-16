<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Curve vectors

263 independently evaluated cases: 242 `smartPresetEval` samples extracted from
all positive vendored behavior fixtures at TypeScript revision `7caa4d1`, plus
21 explicit boundary cases. The original fixture basename and sample index are
retained in `source`; `reference_want` retains the original published value.
The deliberately perturbed negative fixture was excluded from valid inputs.

The pinned `evaluateCurve` was executed through Node's type stripping; its result
is `want`. The pinned Swift `evaluateSmartPresetCurve` at `ce290a3` was compiled
and executed on the same cases; its result is `swift_want`. The Swift source test
`testFullBehaviorMatrixReproducesReferenceTraces` checks those same published
curve samples. No Rust output generated an expected value.

Boundary cases cover negative-half rounding, signed zero, wrap, clamp, single
bounds, smoothing order, negative envelope time, optional envelope peak, every
easing and every LFO shape in beat units. TypeScript wins the two negative-half
rounding disagreements. Published comparison tolerance is 1e-6; the explicit
negative-half and signed-zero tests are exact.

The scratch generator/evaluator programs remain outside this repository. The
fixture file records both pinned revisions through this README and its metadata.
See `docs/portable-math.md` for tag meanings and rejected input behavior.
