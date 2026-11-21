<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: owed red changes expire at a host restart after 1.25 s of exact black (CORE-2869)

## 1. Design

- [x] 1.1 proposal, design (auditor and host pseudocode, `osOffRed` floor and byte checker,
      exclusions, NaN, WCAG 2.3.1 argument with the metric named) and spec deltas
- [x] 1.2 Codex design review: no P1 or P2 (two delta rounds, and a third approved 2026-11-21
      for the round 2 findings; round 3 resolved all of them and raised two P2s in the revised
      text, the host scenario's displayed time and the share rule's float32 gate, both fixed)

## 2. Model and auditor

- [x] 2.1 `limiter-model.mjs`: `RED_EXPIRE_MS`, `blackLongEnough`, `hostBlackLongEnough`,
      `BLACK_TEXEL`, `start: 'untracked' | 'zero' | 'black'`
- [x] 2.2 `limiter-audit.mjs`: per-pixel exact-black run; `restart(seed)`: a black seed reseeds
      pixels with `blackLongEnough` black at the next frame, a zero seed nothing; `lastRestart`
      replaced at every restart;
      nothing expires during playback
- [x] 2.3 `shaders/limiter/README.md`: the restart, the seeds and the black hold

## 3. Conformance

- [x] 3.1 `limiter-signals.mjs`: `runs` signal kind
- [x] 3.2 `limiter-vectors.mjs`: `reset: { at, seed }`; the CORE-2869 reset cases, both round 3
      repros, (1, 0, 0) near black, a red strobe after a black start
- [x] 3.3 `limiter-check.mjs` and `limiter-metal.swift`: the restart on WebGL 2 and Metal
- [x] 3.4 `test-limiter.mjs`: vectors audited with `restart(seed)`; restarts after 74, 75 and 90
      frames of black; exact black; the round 18 and 19 cases unchanged

## 4. Originals

- [x] 4.1 `osOffRed` with the near-black floor in `shaders/originals/common.glsl`; every original
      finishes through it
- [x] 4.2 `test-originals-red.mjs`: conservative byte checker at CI density with the round 1
      repro as positive control, NaN and infinity cases, GLSL form and wiring
- [x] 4.3 Calm the originals still holding over 0.5% of pixels a frame: ink lowers its dye gain;
      aurora, interference, laser-tunnel, photo-curtain, photo-liquid, plasma, ribbons,
      seismograph, vault and wave-cascade keep the palette still against the beat and the timbre,
      and all but laser-tunnel change hue but keep their brightness under the
      vivid palette tour

## 5. Verification

- [x] 5.1 `limiter-vectors.mjs --check`, `test-limiter.mjs`, `limiter-check.mjs` and `--metal`
- [x] 5.2 The 61 release visuals through the web player with a black start: no visual holding
      over 0.5% of pixels a frame (highest 0.4%, filament, 2026-11-21)
- [x] 5.3 Codex code review: no P1 or P2 (round 1 HOLD, delta round 2 HOLD on one P2, delta
      round 3 PASS)
- [x] 5.4 `make gate` on the exact head (19421f5, rc=0; released in v0.2.12)
