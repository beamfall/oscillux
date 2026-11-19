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
