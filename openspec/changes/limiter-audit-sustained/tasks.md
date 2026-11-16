<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tasks: pixel auditor counts sustained flashing (CORE-1623)

## 1. Confirm

- [x] 1.1 Run the region `FlashAnalyzer` oracle on the audited frames of the ten listed visuals
- [x] 1.2 Sweep all 61 visuals with the fixed auditor and the oracle; the limiter defect it found
  is CORE-1915

## 2. Auditor

- [x] 2.1 Count every fresh large-area change in `tools/shader/limiter-audit.mjs`
- [x] 2.2 Failing-first 15 Hz and 30 Hz cases in `tools/shader/test-limiter.mjs`

## 3. Evidence

- [x] 3.1 Before and after numbers in the CORE-1623 evidence record

## 4. Close

- [ ] 4.1 `make gate` on the stacked head
- [ ] 4.2 Archive this change (`openspec archive limiter-audit-sustained`)
