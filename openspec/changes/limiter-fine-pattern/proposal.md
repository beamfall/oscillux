# Count fine reversing patterns (CORE-2515)

## Why
Sub-block means cancel opposing per-pixel luminance changes. Fine checkers and stripes
can therefore exceed six large-area transitions in one second without requesting a hold.

## What changes
Count per-pixel rising and falling luminance changes against previous output in the rows
pass, request both directions for a reversing sub-block, and charge a paired grant two
tokens with spacing on both sides. Preserve the existing red-dominant feather exclusion.

## Impact
The rows pass adds `uHist` at texture unit 1; hosts must bind previous output before
consuming this change. Grant bit 8 carries the second luma token. No client or release
changes are included here; the orchestrator owns consumer integration and landing.

The implementation isolates the fine-pattern detection and paired-token fixes from existing
Oscillux commits `62eb33a`, `07cb0d2` and `16db5fa`; unrelated feathering changes are excluded.

## Integration order and limits

Land CORE-2492's source corrections before this detector. Against those corrected sources,
the 61-visual loud-audio audit increases mean held fraction by at most 0.0003 (below 0.001).
Dunes moves from five to six output transitions per second; no visual crosses the six limit
because of this detector. On the old flashing sources, the more sensitive detector increases
holds materially, so that baseline does not meet the catalog acceptance criterion.

The existing CORE-1915 output defect remains: Comets, Ink, Kaleidoscope and Spectral City
reach seven output luminance transitions per second. The source audit passes; this change
proves the fine-pattern bound and does not claim to resolve the general output defect.

## Verification evidence

- All 26 model cases pass, including 640x360 fine patterns, mixed single/pair grants,
  the unchanged 1080p/4K equality regression and red-dominant feather exclusions.
- All 17 checked vectors match both WebGL2 (SwiftShader) and native Metal. All seven
  limiter passes pass shader compilation. The `make limiter-check` invocation completes
  its CPU/compiler steps but cannot launch Chromium inside the sandbox; the identical
  GPU command passes separately outside it.
- `make limiter-hold-check` passes: Particles' largest held fraction is 0.02, below 0.05.
- CORE-2541 and CORE-2543's exact reproductions remain within their respective red/luma
  bounds with this patch. Their widened-feather changes are deliberately excluded.
