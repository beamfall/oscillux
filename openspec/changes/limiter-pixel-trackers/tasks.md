<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Model and auditor

- [x] 1.1 Per-pixel packed trackers, pixel area counts and the covering window in
  `tools/shader/limiter-model.mjs` and `limiter-geometry.mjs`
- [x] 1.2 Integer-code measures in `tools/shader/limiter-audit.mjs`
- [x] 1.3 Round 7 reproducer tests

## 2. Passes and hosts

- [ ] 2.1 Six GLSL passes with the `uTrack` state texture; generated Metal; READMEs
- [ ] 2.2 WebGL2 and Metal checkers, the reference web host; regenerate vectors

## 3. Verify and close

- [ ] 3.1 Run `make limiter-check`, `make limiter-hold-check` and `make visual-flash-check`
- [ ] 3.2 Run `openspec archive limiter-pixel-trackers` after landing
