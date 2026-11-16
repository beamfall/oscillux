<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Present pass conformance

`present-v1.glsl` is `shaders/present/present.glsl` at `532a4f4`, the v1 present pass before
CORE-0108. `tools/shader/present-v2-check.mjs` renders it beside the working-tree pass to measure
the v1 to v2 hue error and banding change. It is a frozen copy so the check runs in shallow clones
and source archives that lack that commit. Do not edit it; regenerate it only with
`git show 532a4f4:shaders/present/present.glsl > conformance/present/present-v1.glsl`.
