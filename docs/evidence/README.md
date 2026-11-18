<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Release manifests

Byte copies of each release's `oscillux-vX.Y.Z.manifest.json`, kept here so consumers can verify
a pin against the manifest at a known path: `OSC-RELEASE-vX.Y.Z/manifest.json`. Each manifest names
the release's source commit (`build.sourceRevision`) and the sha256 of every packaged artifact.

From v0.2.1 each release directory also holds `<leg>.index.json`, a byte copy of the `index.json`
inside each shader leg zip (`msl`, `glsl300`, `android-gles`). It names the release, the source
commit and the sha256 of every file in the leg, so a consumer can prove a vendored or generated
leg file against this repository's history without downloading the zip.

| Release | Licence | Source commit |
|---|---|---|
| v0.2.8 | AGPL-3.0-only | `2602d6e` |
| v0.2.7 | AGPL-3.0-only | `dfae7c1` |
| v0.2.6 | AGPL-3.0-only | `3f5f2c3` |
| v0.2.5 | AGPL-3.0-only | `59cd60a` |
| v0.2.4 | AGPL-3.0-only | `9446469` |
| v0.2.3 | AGPL-3.0-only | `d4de78d` |
| v0.2.2 | AGPL-3.0-only | `7682232` |
| v0.2.1 | AGPL-3.0-only | `6f21c91` |
| v0.2.0 | AGPL-3.0-only | `ea319a1`, this repository's first public commit |
| v0.1.1 | PolyForm-Noncommercial-1.0.0 | `a38042f`, pre-public history (not in this repository) |
| v0.1.0 | PolyForm-Noncommercial-1.0.0 | `d4a4f72`, pre-public history (not in this repository) |

The v0.1.x manifests stay until no known consumer pins those releases.
