<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: red transitions by the u'v' chromaticity rule (CORE-2935)

## 1. Design

- [ ] 1.1 Write the proposal, the design (zones, classifier and its exhaustive check, side
      tracker, encoding, auditor, consequences, vectors, probe) and the spec delta
- [ ] 1.2 Codex design review: no P1 or P2 left, in at most two delta rounds

## 2. Model, auditor and legs

- [ ] 2.1 `limiter-model.mjs`:
  - [ ] `redZone` and its constants
  - [ ] the side in `redStep`, which returns a direction mask
  - [ ] the side written by `UNTRACKED`
  - [ ] the header
- [ ] 2.2 `limiter-audit.mjs`: a side per pixel and the union of the two rules
- [ ] 2.3 `shaders/limiter/common.glsl`, `output.glsl` and `rows.glsl`: `limiterZone`, the side
      and the mask
- [ ] 2.4 `tools/shader/limiter-zone-check.mjs`, the exhaustive check, added to
      `make limiter-check`
- [ ] 2.5 `shaders/limiter/README.md` and `CHANGELOG.md`

## 3. Conformance

- [ ] 3.1 `limiter-vectors.mjs`: add the cases `red-green-dim-10hz`, `red-white-10hz`,
      `red-mask-10hz` and `red-black-dim-10hz`
- [ ] 3.2 Diff the old and new vector files: outputs, holds and grants, case by case
- [ ] 3.3 `test-limiter.mjs`:
  - [ ] the zone examples
  - [ ] the side at each seed and restart
  - [ ] black keeps the side
  - [ ] both directions in one change
- [ ] 3.4 `limiter-check.mjs` and `--metal`

## 4. Visuals

- [ ] 4.1 Run `limiter-red-audit.mjs --release --audio loud` before and after the change
- [ ] 4.2 Probe the 61 release visuals in the web player on the candidate legs
- [ ] 4.3 Calm any visual over 0.5% of pixels held per frame

## 5. Verification and release

- [ ] 5.1 Codex code review: no P1 or P2 left, in at most two delta rounds
- [ ] 5.2 `make gate` on the exact head
- [ ] 5.3 Release v0.2.13, archive this change and record the evidence
- [ ] 5.4 Move the core repin to v0.2.13
