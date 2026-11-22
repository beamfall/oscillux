<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Model and passes

- [ ] 1.1 Sub-block windows in `tools/shader/limiter-geometry.mjs` and `limiter-model.mjs`, cell
  fallback when the host passes none
- [ ] 1.2 The same in `shaders/limiter/cells.glsl` and `windows.glsl`; uniform docs and READMEs
- [ ] 1.3 Model tests, a fallback vector, regenerate vectors; WebGL2 and Metal checks pass the
  window

## 2. Verify and close

- [ ] 2.1 Run `make limiter-check`, `make limiter-hold-check` and `make visual-flash-check`
- [ ] 2.2 Audit the 84 originals under loud audio
- [ ] 2.3 Run `openspec archive limiter-block-windows` after landing
