<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: Disco Floor moves colour, not brightness (CORE-3263)

## 1. Visual

- [x] 1.1 Equiluminant LED floor that steps its palette on the beat and fades between patterns, and kick tint, in `disco-floor.glsl`
- [x] 1.2 Solid dancers in the floor's complement near its luminance, with neon rims at the same luminance
- [x] 1.3 Coloured spots and sequins under the flash step, sequins in the dress frame, strong reds eased toward grey
- [x] 1.4 `trailDecay` 0 for Disco Floor in `shaders/originals/manifest.json`

## 2. Evidence

- [x] 2.1 `limiter-red-audit.mjs --only disco-floor --audio loud --beats 32` before and after
- [x] 2.2 `beat-lint`, `make shader-test`, `make shader-verify`
- [x] 2.3 Renders reviewed, and owner acceptance in the web preview (2026-11-22)

- [x] 2.4 Displayed-frame glint check: spots alone and sequins alone each add under 0.1

## 3. Close

- [x] 3.1 CHANGELOG entry
- [ ] 3.2 Archive this change
