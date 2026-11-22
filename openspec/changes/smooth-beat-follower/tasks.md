<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: beat follower bends its rate (CORE-3215)

## 1. Follower

- [x] 1.1 Slewed output rate and bounded, slewed phase correction in
  `crates/oscillux-core/src/reaction.rs`
- [x] 1.2 Sub-nanobeat residual snap, so a steady clock's wraps stay exact, never backwards
- [x] 1.3 `beat_count` counts wraps; a newly set host clock re-anchors tempo and count

## 2. Conformance

- [x] 2.1 Mirror the follower in `tools/reaction-vectors.py` and regenerate
  `conformance/reaction/vectors.json`
- [x] 2.2 Update the Beat section of `conformance/reaction/README.md`
- [x] 2.3 `make reaction-photon` (criteria 1 to 3 met; tempo-error vectors reported)

## 3. Close

- [ ] 3.1 `make gate` on the landing head
- [ ] 3.2 Release, and repin core's web player
- [ ] 3.3 Archive this change (`openspec archive smooth-beat-follower`)
