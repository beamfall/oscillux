<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Preset vectors

The preset schema is in `docs/shader-toolchain.md` (Presets) and `tools/shader/preset.mjs`.
`make shader-test` runs `tools/shader/test-preset.mjs`, which checks both files here.

`vectors.json` resolves 40 cases against a two-visual fixture catalog: `glow` (a palette
index, two controls, one quantised in sixths) and `free` (free-mode palette, one control with
a 0.2 to 0.8 range). There are 4 accept, 4 clamp, 26 refuse and 6 migrate cases. Each case gives
`input` (a JSON value) or `text` (JSON text). An accepted case must match exactly the uniforms
`presetUniforms` returns, the mapping `presetMapping` returns, the clamped paths in order and
`migratedFrom`. A refused case must match the refusal's path and code. The file was generated
once from the rules in the schema and is maintained by hand. A change to a rule changes a case
in the same commit.

`adversarial.json` holds 17 presets that `test-preset.mjs` resolves for every visual of
`shaders/manifest.json`, `shaders/originals/manifest.json` and `examples/shader/manifest.json`.
`$visual` stands for the visual id, and `$params` for a value given to every control of that
visual. The 4 accepted cases push every field to the largest and most negative finite doubles,
to subnormals, and to the version-0 extremes. The result must hold exactly the tunable uniforms,
each inside its range. The 13 refused cases try to set `presentation0`, `presentation1`,
`safeRect` or the audio uniforms, to pass a `uniforms` object or a mapping field the schema lacks,
to pollute a prototype through `__proto__` or `constructor`, to use non-finite numbers, a boolean
trail, a huge version or a fractional palette index. `make overlay-check
OVERLAY_ARGS='--preset NAME'` renders an accepted case through the present pass.
