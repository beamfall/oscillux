<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Model and passes

- [ ] 1.1 Feathered output in `tools/shader/limiter-model.mjs`
- [ ] 1.2 The same in `shaders/limiter/output.glsl`; READMEs
- [ ] 1.3 Model tests for the feather; regenerate vectors

## 2. Evidence

- [ ] 2.1 Catalog audit before and after
- [ ] 2.2 Aurora probe worst frame before and after

## 3. Verify and close

- [ ] 3.1 Run `make limiter-check`
- [ ] 3.2 Run `make gate`
- [ ] 3.3 Run `openspec archive limiter-soft-hold` after landing
