<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: red transitions by the u'v' chromaticity rule (CORE-2935)

## 1. Design

- [x] 1.1 Zone design and Codex design round 1: HOLD on P1-a and P1-b
- [x] 1.2 Owner decision 2026-11-21: "Widen limiter memory"
- [x] 1.3 Last-saturated reference and Codex round 1: HOLD on P1-1, P1-2, P1-3
- [x] 1.4 Rewrite the proposal, the design (codes, thresholds, saturated and far boxes, merged
      direction, RGBA32UI texel and host contract, auditor, vectors) and the spec delta
- [x] 1.5 Codex design round 2 (the last): HOLD on P1-A (verified flash) and P1-B (auditor)
- [x] 1.6 Fix in the model and auditor: the uncertain bits, the clip, unknown boxes at an auditor
      zero restart; design section 13; vectors `red-uncertain-box`, `red-zero-retained`
- [ ] 1.7 A further design round on section 13, which needs the coordinator's approval

## 2. Model, auditor and legs

- [x] 2.1 `limiter-model.mjs`: `LIN24`, `uvCode`, `s24`, the far tests and thresholds, the box
      step, the marker and validity, the merged direction, a `Uint32Array` tracker, `BLACK_TEXEL`
- [x] 2.2 `limiter-audit.mjs`: the boxes per pixel, one red event a frame
- [ ] 2.3 `shaders/limiter/common.glsl`, `output.glsl`, `rows.glsl`; `LIN24_LUT` in the generated
      `luma-lut.glsl`; RGBA32UI tracker textures in `limiter.mjs`, `limiter-check.mjs` and
      `limiter-metal.swift`
- [ ] 2.4 `tools/shader/limiter-uv-check.mjs` in `make limiter-check` (`UV_R` added)
- [ ] 2.5 `shaders/limiter/README.md`, `conformance/limiter/frame/README.md` and `CHANGELOG.md`

## 3. Conformance

- [x] 3.1 `limiter-signals.mjs`: the `bands` signal
- [x] 3.2 `limiter-vectors.mjs`: four-byte tracker digest; cases `red-green-dim-10hz`,
      `red-blue-10hz`, `red-mask-10hz`, `red-black-dim-10hz`, `red-flash-5hz-half`,
      `red-stagger`, `red-extremum`, `red-early-band`, `red-zero-constant`, `red-zero-mixed`
- [x] 3.3 Diff the new model's frames against the committed vectors and list each change
- [x] 3.4 `test-limiter.mjs`: the new cases' input and output counts, per-patch holds and
      crossing frames, the starts, black keeps the boxes, the marker
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
