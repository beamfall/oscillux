## 1. Reference model

- [x] 1.1 Port the web host's cell limiter to `tools/shader/limiter-model.mjs` with a pixel auditor
- [x] 1.2 Split the red budget (refill 0); prove luminance vectors byte-identical (CORE-0125)
- [x] 1.3 Replace the cell model with the 10° window, box-reduced sub-block model (CORE-0121)
- [x] 1.4 Write `conformance/limiter/frame/` vectors and the model tests

## 2. GPU pass

- [x] 2.1 Write the GLSL passes under `shaders/limiter/` and the interface README
- [x] 2.2 Generate GLSL ES 3.00 and Metal with ABI checks (`tools/shader/limiter.mjs`)
- [x] 2.3 Check the WebGL2 pass against the vectors; run the Metal pass and time it at 1080p

## 3. Evidence

- [x] 3.1 Record the parent-commit failures of the CORE-0121 cases
- [x] 3.2 Run the red audit over the visual catalog
- [x] 3.3 Write both evidence pages

## 4. Verify and close

- [x] 4.1 Run `make limiter-check`, `make shader-test`, `cargo fmt --check`, clippy and core tests
- [ ] 4.2 Run `make gate`
- [ ] 4.3 Run `openspec archive gpu-frame-limiter` after landing, before completing CORE-0125 and CORE-0121
