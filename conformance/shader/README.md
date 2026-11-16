<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Shader wrapper goldens

`examples/` holds the exact output of `tools/shader/emit.mjs` for
`examples/shader/manifest.json`: GLSL ES 3.00 (`*.web.frag`, `vertex.web.vert`),
Vulkan GLSL 450 (`*.vulkan.frag`) and the GLSL 450 fed to SPIR-V for Metal
(`*.msl.frag`). `make shader-test` requires byte equality and the same file set.

Generated Metal is not a golden here: it depends on the installed SPIRV-Cross
build, and the gate does not require the pinned one. The `.vulkan.frag` and
`.msl.frag` goldens compiled with glslangValidator 16.6.0, and both visuals
rendered in WebGL2 and Metal (`make shader-render`), when they were recorded.

Regenerate with `node tools/shader/test-wrap.mjs --update` only for a deliberate
wrapper or example change, and review the diff.

`<id>.hlsl` (SM 5.0, for each `hlsl` visual) is the `emit.mjs --hlsl` output of the pinned
toolchain: glslangValidator 16.6.0 and SPIRV-Cross with build timestamp 2026-07-06T12:43:32.
The gate cannot produce it, so `make shader-test` does not compare its bytes. It checks that
there is one per `hlsl` visual, runs `checkHlslABI` on each one, and runs it on edited copies
of `image-ripple.hlsl`, which tests the register, entry and cbuffer packing checks without
SPIRV-Cross. `make shader-verify` on the pinned toolchain requires the emitted HLSL to equal
these files byte for byte and compiles them with FXC or DXC. `test-wrap.mjs --update` keeps
them; regenerate them with
`node tools/shader/emit.mjs examples/shader/manifest.json --hlsl --out conformance/shader/examples`
on the pinned toolchain and review the diff.
