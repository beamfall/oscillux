<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: nebula follows the host's detail reduction (CORE-2220)

## 1. Shader

- [ ] 1.1 `presentationDetail` in `shaders/library.glsl`
- [ ] 1.2 Shell count and alpha weight in `shaders/visuals/nebula.glsl`

## 2. Checks and docs

- [ ] 2.1 `make shader-test`, byte check of the other visuals' outputs
- [ ] 2.2 `docs/shader-toolchain.md` and `CHANGELOG.md`

## 3. Close

- [ ] 3.1 `make gate`
- [ ] 3.2 Archive this change (`openspec archive nebula-host-detail`)
