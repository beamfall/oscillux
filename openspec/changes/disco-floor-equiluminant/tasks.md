<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: Disco Floor moves colour, not brightness (CORE-3263)

## 1. Visual

- [ ] 1.1 Equiluminant LED floor, kick tint and small far sparks in `disco-floor.glsl`
- [ ] 1.2 Solid dancers in the floor's complement near its luminance, with neon rims at the same luminance
- [ ] 1.3 `trailDecay` 0 for Disco Floor in `shaders/originals/manifest.json`

## 2. Evidence

- [ ] 2.1 `limiter-red-audit.mjs --only disco-floor --audio loud --beats 32` before and after
- [ ] 2.2 `beat-lint`, `make shader-test`, `make shader-verify`
- [ ] 2.3 Renders reviewed, and owner acceptance in the web preview

## 3. Close

- [ ] 3.1 CHANGELOG entry
- [ ] 3.2 Archive this change
