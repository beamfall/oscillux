<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: Fractal Flight moves colour, not brightness (CORE-3272)

## 1. Visual

- [x] 1.1 Panes, flare and lace wave at a fixed luminance in `fractal-flight.glsl`
- [x] 1.2 Shafts faded near the camera, steady tinted haze at a fixed luminance
- [x] 1.3 Hue on the bars only; pace on the 32-beat flight profile under twice cruise

## 2. Evidence

- [x] 2.1 `limiter-red-audit.mjs --only fractal-flight --audio loud --beats 32` before and after
- [x] 2.2 `beat-lint --only fractal-flight`; render mean luma before and after
- [ ] 2.3 Owner acceptance in the web preview

## 3. Close

- [x] 3.1 CHANGELOG entry
- [ ] 3.2 Archive this change
