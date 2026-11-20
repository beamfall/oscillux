<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Model and passes

- [x] 1.1 Dimmed hold in `tools/shader/limiter-model.mjs`
- [x] 1.2 The same in `shaders/limiter/common.glsl` and `output.glsl`, bit for bit
- [x] 1.3 Model tests (a held pixel follows the input; nothing fires outside the grant);
      re-record the vectors
- [x] 1.4 READMEs, the audit's header and the changelog
- [x] 1.5 A denied rise mixes from the previous output (model, passes, tests, vectors, docs)
- [x] 1.6 The limit of a denied rise over a lit pixel (model, passes, tests, vectors, docs)
- [x] 1.7 Mix searches that assume no order along the mix (model, passes, tests, vectors, docs)

## 2. Verify and close

- [x] 2.1 Run `make limiter-check`, `make limiter-hold-check` and the catalogue audit; record
      the per-frame cost
- [x] 2.2 Contact sheets of catalogue visuals under loud audio, v0.2.9 beside the change
- [x] 2.3 Repeat 2.1 and 2.2 for 1.5 and 1.6
- [x] 2.5 Repeat 2.1 and 2.2 for 1.7
- [x] 2.4 Run `openspec archive limiter-dim-hold` after landing
