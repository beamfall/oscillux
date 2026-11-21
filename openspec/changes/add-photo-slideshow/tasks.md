<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks

- [x] Write `shaders/slideshow/slideshow.glsl` and its host-pass contract.
- [x] Write the model `tools/slideshow-vectors.py` and `conformance/slideshow/`.
- [x] Write `tools/shader/slideshow.mjs` and `tools/shader/slideshow-check.mjs` (WebGL2, Metal,
      audio identity, flash sequence, contact frames) and compile the pass in `verify.mjs`.
- [x] Ship the pass in the `glsl300` and `msl` legs.
- [x] Add `make slideshow-check` to `make gate`.
- [ ] `make gate` on the exact head.
- [ ] `openspec archive add-photo-slideshow` after landing.
