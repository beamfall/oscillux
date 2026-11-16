<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: nebula follows the host's detail reduction (CORE-2220)

## 1. Shader

- [x] 1.1 Shell count and alpha weight in `shaders/visuals/nebula.glsl`

## 2. Checks and docs

- [x] 2.1 `make shader-test`, byte check that only nebula's outputs change; repin the android-gles source digest
- [x] 2.2 `docs/shader-toolchain.md` and `CHANGELOG.md`

## 3. Close

- [x] 3.1 `make gate`
- [x] 3.2 Archive this change (`openspec archive nebula-host-detail`)
