<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Model and passes

- [x] 1.1 Smooth hold field in `tools/shader/limiter-model.mjs`
- [x] 1.2 The same in `shaders/limiter/state.glsl` and `output.glsl`; READMEs
- [x] 1.3 Boundary-step model test; regenerate vectors
- [x] 1.4 Calm Aurora so the limiter rarely holds on it

## 2. Evidence

- [x] 2.1 Catalog audit before and after
- [x] 2.2 Aurora probe before and after

## 3. Verify and close

- [ ] 3.1 Run `make limiter-check`
- [ ] 3.2 Run `make gate`
- [ ] 3.3 Run `openspec archive limiter-smooth-hold` after landing
