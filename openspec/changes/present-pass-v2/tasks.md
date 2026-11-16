<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: present pass v2 (CORE-0108)

## 1. Pass

- [x] 1.1 Hue-preserving luminance tone map in `shaders/present/present.glsl`
- [x] 1.2 TPDF dither with rectangular ends and exact black/white
- [x] 1.3 Radial chromatic aberration and integer-hash grain; grain 0 under reduced motion
- [x] 1.4 Five-level soft-knee bloom chain in `shaders/present/bloom.glsl` and its graph in `tools/shader/present.mjs`
- [x] 1.5 PresentBlock 368 bytes (`post0`, `post1`); bloom at texture 4

## 2. Hosts

- [x] 2.1 Web host: 368-byte block, dither 1, frame seed, trail decay 0 under reduced motion
- [x] 2.2 Apple host: the same

## 3. Checks and evidence

- [x] 3.1 `tools/shader/present-model.mjs` and `tools/shader/test-present-v2.mjs`
- [x] 3.2 `tools/shader/present-v2-check.mjs` and `tools/shader/present-v2-metal.swift` (GPU leg, timing, sheets)
- [x] 3.3 `present-v2-check` in `gate`
- [x] 3.4 CORE-0108 evidence record and contact sheets

## 4. Close

- [ ] 4.1 `make gate` on the stacked head
- [ ] 4.2 Archive this change (`openspec archive present-pass-v2`)
