<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Add a frame-window governor

Ticket: CORE-2758.

## Why

Give hosts a shared decision for each telemetry window so they can use the same budget thresholds,
streaks, and promotion cooldown.

## What changes

- Add a C ABI for classifying frame windows and reporting the resulting decision and streaks.
- Replay deterministic conformance vectors in Rust and check their generator in the merge gate.

## Non-goals

Hosts continue to own ladder steps, frame-rate candidates, device clamps, and recovery policy.
The existing per-frame governor keeps its interface and behavior.

## Failure modes

Malformed configurations are refused at creation. Malformed samples and reset times leave the
governor unchanged. A window with missing telemetry holds and clears the pressure streaks.

## Acceptance evidence

Replay the conformance vectors, test the ABI entry points, regenerate and check the ABI snapshot,
and validate OpenSpec.

## Rollback

Revert the additive API and its tests. Existing governor consumers need no changes.
