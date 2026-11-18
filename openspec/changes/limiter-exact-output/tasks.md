<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Model and passes

- [x] 1.1 Exact output in `tools/shader/limiter-model.mjs`
- [x] 1.2 The same in `shaders/limiter/state.glsl` and `output.glsl`; READMEs
- [x] 1.3 CORE-2543 rise tests and the exactness test; regenerate vectors

## 2. Verify and close

- [ ] 2.1 Run `make limiter-check`, `make limiter-hold-check` and `make visual-flash-check`
- [ ] 2.2 Run `openspec archive limiter-exact-output` after landing
