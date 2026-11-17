<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Model and passes

- [x] 1.1 Feathered output in `tools/shader/limiter-model.mjs`
- [x] 1.2 The same in `shaders/limiter/output.glsl`; READMEs
- [x] 1.3 Model tests for the feather; regenerate vectors

## 2. Evidence

- [x] 2.1 Catalog audit before and after
- [x] 2.2 Aurora probe worst frame before and after

## 3. Verify and close

- [x] 3.1 Run `make limiter-check`
- [x] 3.2 Run `make gate`
- [ ] 3.3 Run `openspec archive limiter-soft-hold` after landing
