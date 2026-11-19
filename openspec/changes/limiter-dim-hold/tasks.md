<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Model and passes

- [ ] 1.1 Dimmed hold in `tools/shader/limiter-model.mjs`
- [ ] 1.2 The same in `shaders/limiter/common.glsl` and `output.glsl`, bit for bit
- [ ] 1.3 Model tests (a held pixel follows the input; nothing fires outside the grant);
      re-record the vectors
- [ ] 1.4 READMEs, the audit's header and the changelog

## 2. Verify and close

- [ ] 2.1 Run `make limiter-check`, `make limiter-hold-check` and the catalogue audit; record
      the per-frame cost
- [ ] 2.2 Contact sheets of catalogue visuals under loud audio, v0.2.9 beside the change
- [ ] 2.3 Run `openspec archive limiter-dim-hold` after landing
