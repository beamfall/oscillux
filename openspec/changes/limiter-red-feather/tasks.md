<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Model and passes

- [x] 1.1 Red feather guard in `tools/shader/limiter-model.mjs`
- [x] 1.2 The same in `shaders/limiter/output.glsl` (`lut: true`); READMEs
- [x] 1.3 Red-background feather model test; regenerate vectors

## 2. Evidence

- [x] 2.1 Catalog red audit before and after under loud audio
- [x] 2.2 Murmuration worst held frame before and after

## 3. Verify and close

- [x] 3.1 Run `make limiter-check` and `make limiter-hold-check`
- [ ] 3.2 Run `openspec archive limiter-red-feather` after landing
