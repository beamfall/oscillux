<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# shader-legs

## ADDED Requirements

### Requirement: Measured photosensitivity data

A manifest visual with the catalog fields SHALL carry `safety`: `maxFlashHz` and `maxRedFlashHz`
in [0, 30], `maxLuminanceDelta` in [0, 1] and `textSafeZone` (`none`, `center` or `upper`). The
loader SHALL reject a block that is missing, has other keys or is out of range, and
`catalog.json` SHALL carry it.

#### Scenario: Missing safety

- **WHEN** a manifest visual has the catalog fields and no `safety`
- **THEN** loading the manifest fails naming that visual's `safety`

### Requirement: Safety data matches measurement

`limiter-red-audit.mjs --release --check-safety` SHALL fail any visual whose measured flashes or
red flashes a second, or field luminance delta, exceed its declared `safety`.

#### Scenario: Reference set within its data

- **WHEN** `make visual-safety-check` runs
- **THEN** each of the 63 release-set visuals measures within its declared `safety`
