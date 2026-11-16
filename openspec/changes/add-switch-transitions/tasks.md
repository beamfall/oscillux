<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks

- [x] Write `shaders/switch/switch.glsl` and its host-pass contract `shaders/switch/README.md`.
- [x] Write the model `tools/switch-transition-vectors.py` and `conformance/switch-transition/`.
- [x] Write `tools/shader/switch.mjs` and `tools/shader/switch-transition-check.mjs` (WebGL2,
      Metal, contact strip, 1080p timing) and compile the pass in `tools/shader/verify.mjs`.
- [x] Add `make switch-transition-check` to `make gate`.
- [x] Record the planted-red proof, contact strip and timings in the CORE-0141 evidence record.
- [ ] `make gate` on the exact head.
- [ ] `openspec archive add-switch-transitions` after landing.
