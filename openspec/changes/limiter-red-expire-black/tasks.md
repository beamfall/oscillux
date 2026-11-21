<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: owed red changes expire at a host restart after 1.25 s of exact black (CORE-2869)

## 1. Design

- [x] 1.1 proposal, design (auditor and host pseudocode, `osOffRed` floor and byte checker,
      exclusions, NaN, WCAG 2.3.1 argument with the metric named) and spec deltas
- [ ] 1.2 Codex design review: no P1 or P2 within two delta rounds

## 2. Model and auditor

- [ ] 2.1 `limiter-model.mjs`: `RED_EXPIRE_MS`, `blackLongEnough`, `BLACK_TEXEL`,
      `start: 'untracked' | 'zero' | 'black'`
- [ ] 2.2 `limiter-audit.mjs`: per-pixel exact-black run; `restart(seed)`: a black seed reseeds
      pixels with `blackLongEnough` black at the next frame, a zero seed nothing; `lastRestart`;
      nothing expires during playback
- [ ] 2.3 `shaders/limiter/README.md`: the restart, the seeds and the black hold

## 3. Conformance

- [ ] 3.1 `limiter-signals.mjs`: `runs` signal kind
- [ ] 3.2 `limiter-vectors.mjs`: `reset: { at, seed }`; the CORE-2869 reset cases, both round 3
      repros, (1, 0, 0) near black, a red strobe after a black start
- [ ] 3.3 `limiter-check.mjs` and `limiter-metal.swift`: the restart on WebGL 2 and Metal
- [ ] 3.4 `test-limiter.mjs`: vectors audited with `restart(seed)`; restarts after 74, 75 and 90
      frames of black; exact black; the round 18 and 19 cases unchanged

## 4. Originals

- [ ] 4.1 `osOffRed` with the near-black floor in `shaders/originals/common.glsl`; every original
      finishes through it
- [ ] 4.2 `test-originals-red.mjs`: conservative byte checker at CI density with the round 1
      repro as positive control, NaN and infinity cases, GLSL form and wiring
- [ ] 4.3 Calm the originals still over 0.5 held pixels a frame

## 5. Verification

- [ ] 5.1 `limiter-vectors.mjs --check`, `test-limiter.mjs`, `limiter-check.mjs` and `--metal`
- [ ] 5.2 The 61 release visuals through the web player with a black start: no visual over 0.5
      held pixels a frame
- [ ] 5.3 Codex code review: no P1 or P2
- [ ] 5.4 `make gate` on the exact head
