<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: continuous beat follower across jitter and tracker resyncs (CORE-3277)

## 1. Follower

- [x] 1.1 Hold follower state on backward target steps up to `HOLD_BACK_MS` (100 ms); keep resync on larger steps back, forward jumps over `RESYNC_MS` (500 ms), and newly set host clocks with earlier target time
- [x] 1.2 In tracker mode, resynchronise to the tracker phase at the whole beat nearest the reached output position, never below `prev.beats`
- [x] 1.3 Add unit test failing on the old follower and passing on the new

## 2. Conformance & Changelog

- [x] 2.1 Mirror follower logic and add jitter/dropout scenario in `tools/reaction-vectors.py` and regenerate `conformance/reaction/vectors.json`
- [x] 2.2 Update Beat section and scenario list in `conformance/reaction/README.md`
- [x] 2.3 Record change under `[Unreleased]` in `CHANGELOG.md`

## 3. Verify & Land

- [x] 3.1 Pass `openspec validate --all --strict`, `make gate`, and Codex read-only review against `origin/main`
