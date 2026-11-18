<!-- SPDX-License-Identifier: AGPL-3.0-only -->
## 1. Audit and visuals

- [x] 1.1 `limiter-red-audit.mjs --max-luma` and `make visual-flash-check`
- [x] 1.2 Calm the offending visuals to at most 6 luma transitions a second and no red

## 2. Verify and close

- [x] 2.1 `make visual-flash-check`, beat lint and `make shader-test`
- [ ] 2.2 Run `openspec archive visual-source-flash` after landing
