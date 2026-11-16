## 1. Model and passes

- [x] 1.1 Lower the red step to 512 in `limiter-model.mjs` and `shaders/limiter/common.glsl`
- [x] 1.2 Add the `stripes` signal and the `red-stripes-10hz` case and test; regenerate vectors
- [x] 1.3 Show the new test fails against the parent commit's model
- [x] 1.4 Move the default palettes of vault, reactor, laser-tunnel and loom off red-dominant palettes in `shaders/manifest.json`

## 2. Evidence

- [x] 2.1 Re-run the catalog red audit on the reference host, with the new and the v0.1.0 palettes
- [x] 2.2 Update the CORE-0125 evidence record

## 3. Verify and close

- [x] 3.1 Run `make limiter-check`
- [x] 3.2 Run `make gate`
- [x] 3.3 Run `openspec archive limiter-red-dilution` after landing, before completing CORE-1616
