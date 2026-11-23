<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: Neon Run, Space Flight and Ocean Glide hold their light steady (CORE-3273..3275)

## 1. Visuals

- [x] 1.1 Neon Run: lights recoloured at a fixed luminance; window grid, billboards and traffic
      filtered over the pixel footprint and the frame's travel (`neon-run.glsl`)
- [x] 1.2 Space Flight: streaks and stars at least a pixel wide at equal energy, treble as
      tint, rings filtered over the pixel footprint (`space-flight.glsl`)
- [x] 1.3 Ocean Glide: water luminance held to the calm mirror, pinpoint glints on top
      (`ocean-glide.glsl`)

## 2. Evidence

- [x] 2.1 `limiter-red-audit.mjs --only V --audio loud --beats 32` before and after, each visual
- [x] 2.2 `beat-lint --only V`; render mean luma before and after
- [ ] 2.3 Owner acceptance in the web preview

## 3. Close

- [x] 3.1 CHANGELOG entry
- [ ] 3.2 Archive this change
