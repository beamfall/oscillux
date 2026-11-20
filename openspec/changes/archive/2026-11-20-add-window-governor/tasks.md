<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks

- [x] Add the decision logic and C ABI for window samples, with defaults and validation.
- [x] Generate and replay conformance vectors, and add the regeneration check to the gate.
- [x] Update the ABI snapshot and Unreleased changelog.
- [x] Run format, Clippy, Rust tests, ABI, vector, SPDX, and strict OpenSpec checks.
- [x] Run `make gate` on the exact head before merge (909c254, rc=0; released in v0.2.11 at b6fcba3).
- [x] Run `openspec archive add-window-governor` after landing.
