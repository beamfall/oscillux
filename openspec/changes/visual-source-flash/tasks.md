<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Audit and visuals

- [x] 1.1 `limiter-red-audit.mjs --max-luma` and `make visual-flash-check`
- [ ] 1.2 Calm the offending visuals to at most 6 luma transitions a second and no red (done
  against the v0.2.8 sub-block auditor; measured per pixel in v0.2.9, 29 of 61 are still over 6
  luma/s and none makes red; the limiter holds them)

## 2. Verify and close

- [ ] 2.1 `make visual-flash-check`, beat lint and `make shader-test`
- [ ] 2.2 Run `openspec archive visual-source-flash` after landing
