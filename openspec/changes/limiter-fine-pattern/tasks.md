<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Model and passes

- [x] 1.1 Up and down pixel counts and the paired request in `tools/shader/limiter-model.mjs`
- [x] 1.2 The same in `rows.glsl`, `reduce.glsl`, `grant.glsl` and `state.glsl`; harnesses bind `uHist`
- [x] 1.3 Fine-checker model test and `fine-checker-10hz` vector; READMEs and CHANGELOG

## 2. Verify and close

- [x] 2.1 Catalog audit at 1/4, 3/8 and 7/16; 7/16 keeps the baseline
- [x] 2.2 Run `make limiter-check` and `make limiter-hold-check`
- [ ] 2.3 Run `openspec archive limiter-fine-pattern` after landing
