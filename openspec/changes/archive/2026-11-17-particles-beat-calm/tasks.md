<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: Particles stops tiling under the frame limiter (CORE-2409)

## 1. Shader

- [x] 1.1 Beat, onset and burst multipliers in `shaders/visuals/particles.glsl`
- [x] 1.2 Smooth streak falloff, no beat-driven trail rotation, fixed 35% ember tint (CORE-2392 hunks)

## 2. Checks and docs

- [x] 2.1 `--audio loud` and `--max-held` in `tools/shader/limiter-red-audit.mjs`; `make limiter-hold-check` in `make gate`, red on the old shader
- [x] 2.2 `make shader-test`; repin the android-gles source digest
- [x] 2.3 `CHANGELOG.md`

## 3. Close

- [x] 3.1 `make gate`
- [x] 3.2 Archive this change (`openspec archive particles-beat-calm`)
