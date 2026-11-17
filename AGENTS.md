# Oscillux contributor and agent guide

Oscillux is a portable, audio-reactive visual core: audio analysis, flash limiting, uniform
packing, transitions and governor math behind a C interface.

## Invariants

1. Host-agnostic. No entitlements or UI policy in this repository. Hosts pass policy in as data.
   Descriptive visual metadata is allowed: each visual's name, blurb, tier, input, overlay and calm
   flags, parameter labels and the default `catalogOrder` live in `shaders/manifest.json` and ship
   as the legs' `catalog.json`. Hosts own selection, gating and defaults on top of it. The
   `android-gles` leg keeps its consumer package `com.beamfall.kit.visuals` as a contract name.
   (Owner decision 2026-11-16, CORE-2208, when beamfall-visual-shaders was retired.)
2. Conformance vectors under `conformance/` are the specification. Outputs match them within the
   stated tolerance on every supported target, including wasm32.
3. Deterministic numerics. No platform-specific floating-point paths that change results across
   targets.
4. Real-time safe on the per-frame path: no allocation, locking or I/O.
5. Oscillux is licensed under the GNU AGPL v3 only. Every source file carries
   `SPDX-License-Identifier: AGPL-3.0-only` (`LICENSING.md`).
6. Outside contributions need the contributor agreement before merge
   (`CONTRIBUTING.md`).

## Documentation

Keep docs in `README.md`, `CONTRIBUTING.md`, `LICENSING.md`, `docs/`, `openspec/` and this file.
When this repository is checked out inside the Beamfall multi-repo workspace, also follow that
workspace's `DOCUMENTATION-GOVERNANCE.md` before adding, moving or archiving a doc.

## Gate

`make gate` is the merge gate. Run it on the exact head before merging. While iterating, run the
focused target instead (`make fmt clippy test`, `make spdx`, `make shader-test`, one
`cargo test --test <name>`).

## Spec-driven changes (OpenSpec)

New or changed behaviour needs an OpenSpec change in `openspec/changes/<id>/` committed before the
code: `proposal.md` (naming its tracking issue when there is one), the spec delta and `tasks.md`.
A fix that restores an existing requirement cites it instead. `tasks.md` is a checklist. Existing
`docs/` stay canonical; do not backfill specs. Run `openspec validate --all --strict` before review
and `openspec archive <id>` after landing. Agent commands are generated per checkout with
`openspec update`.
