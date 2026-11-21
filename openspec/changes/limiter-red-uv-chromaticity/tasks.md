<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: red transitions by the u'v' chromaticity rule (CORE-2935)

## 1. Design

- [x] 1.1 Zone design and Codex design round 1: HOLD on P1-a and P1-b
- [x] 1.2 Owner decision 2026-11-21: "Widen limiter memory"
- [ ] 1.3 Rewrite the proposal, the design (integer codes, thresholds, per-pixel reference, merged
      direction, RGBA32UI texel and host contract, auditor, vectors) and the spec delta
- [ ] 1.4 Codex design review: no P1 or P2 left, in at most two delta rounds

## 2. Model, auditor and legs

- [ ] 2.1 `limiter-model.mjs`: `LIN24`, `uvCode`, `s24`, the far tests and thresholds, the
      reference step, the merged direction, a `Uint32Array` tracker, `BLACK_TEXEL`, the header
- [ ] 2.2 `limiter-audit.mjs`: the reference per pixel and the merged count
- [ ] 2.3 `shaders/limiter/common.glsl`, `output.glsl`, `rows.glsl`; `LIN24_LUT` in the generated
      `luma-lut.glsl`; RGBA32UI tracker textures in `limiter.mjs`, `limiter-check.mjs` and
      `limiter-metal.swift`
- [ ] 2.4 `tools/shader/limiter-uv-check.mjs` in `make limiter-check`
- [ ] 2.5 `shaders/limiter/README.md`, `conformance/limiter/frame/README.md` and `CHANGELOG.md`

## 3. Conformance

- [ ] 3.1 `limiter-signals.mjs`: the `bands` signal
- [ ] 3.2 `limiter-vectors.mjs`: four-byte tracker digest; cases `red-green-dim-10hz`,
      `red-blue-10hz`, `red-mask-10hz`, `red-black-dim-10hz`, `red-stagger`,
      `red-zero-constant`
- [ ] 3.3 Diff the new model's frames against the committed vectors and list each change
- [ ] 3.4 `test-limiter.mjs`: the new cases' input and output counts, the starts, black keeps
      the reference
- [ ] 3.5 `limiter-check.mjs` on the GLSL leg and `--metal`

## 4. Visuals

- [ ] 4.1 `limiter-red-audit.mjs --release --audio loud`
- [ ] 4.2 Probe the 61 release visuals once in the web player on the candidate legs
- [ ] 4.3 Calm any visual over 0.5% of pixels held a frame, and probe only those again

## 5. Verification and release

- [ ] 5.1 Codex code review: no P1 or P2 left, in at most two delta rounds
- [ ] 5.2 `make gate` on the exact head
- [ ] 5.3 Release v0.2.13, archive this change and record the evidence
- [ ] 5.4 Core repin to v0.2.13 with the RGBA32UI renderer change
