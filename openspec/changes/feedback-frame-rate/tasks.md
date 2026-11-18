<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Wrappers and Ink

- [x] 1.1 `feedbackTrail`: zoom and rotation per second, out-of-frame history fades
- [x] 1.2 Ink: advection, bleed and injection per second, out-of-frame history fades
- [x] 1.3 `precision highp sampler2D` in the GLSL ES 3.00 visual, present and bloom wrappers

## 2. Verify and close

- [x] 2.1 Run `make shader-test` and regenerate the legs
- [ ] 2.2 Run `openspec archive feedback-frame-rate` after landing
