<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: limiter rations large-area red (CORE-2382)

## 1. Limiter

- [x] 1.1 Red token in `shaders/limiter/grant.glsl` and `tools/shader/limiter-model.mjs`
- [x] 1.2 Regenerate `conformance/limiter/frame/vectors.json`
- [x] 1.3 Red strobe tests allow at most one red transition a second; new lasting-change test

## 2. Close

- [ ] 2.1 `make gate` on the release head
- [ ] 2.2 Archive this change (`openspec archive limiter-red-token`)
