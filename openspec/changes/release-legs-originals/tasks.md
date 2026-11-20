<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: release legs ship the rebuilt originals (CORE-2760)

## 1. Tooling

- [x] 1.1 `releaseSet` / `loadReleaseSet` in `tools/shader/manifest.mjs`
- [x] 1.2 `bundle-legs.mjs`, `emit.mjs` and the android-gles contract use per-visual wrappers
- [x] 1.3 `limiter-red-audit.mjs --release`; Makefile flash and hold checks use it

## 2. Tests

- [x] 2.1 `test-wrap.mjs`: merge fields, order, labels, failures
- [x] 2.2 `test-android-gles.mjs`: release-set digests

## 3. Verification

- [ ] 3.1 `make limiter-hold-check` and `make visual-flash-check` pass on the release set
- [ ] 3.2 `make gate` on the exact head
