<!-- SPDX-License-Identifier: AGPL-3.0-only -->

## ADDED Requirements

### Requirement: Host-directed frame-window decisions

Oscillux SHALL expose a separate C ABI to configure, create, record, reset, and destroy a
frame-window governor. It SHALL validate an extensible configuration and provide a default
writer. Record SHALL be allocation-, lock-, and I/O-free. Hosts SHALL own which steps to apply.

#### Scenario: A host records one telemetry window

- **WHEN** a host supplies optional p95 and p99 durations, the current interval, a prospective promotion budget (zero when unavailable), delivery flags, and a monotonic timestamp
- **THEN** the governor returns HOLD, DEMOTE, or PROMOTE, the window's over-budget classification, and the post-record counts of consecutive over-budget windows, consecutive promotion-eligible windows, and windows held since a change

#### Scenario: Sustained budget pressure

- **WHEN** both percentiles are present and p95 exceeds 0.85 times the current interval, p99 exceeds the current interval, or either delivery flag is set
- **THEN** the default governor classifies the window as over budget and clears the promotion streak
- **AND** it returns DEMOTE on the 30th consecutive such window

#### Scenario: Sustained headroom against the next step

- **WHEN** a window is within budget, a prospective budget exists, and p95 is strictly below 0.60 times that budget
- **THEN** the default governor returns PROMOTE once 300 consecutive windows qualify and at least five seconds have elapsed since creation, reset, or the most recent step
- **AND** p99 is compared with the current interval even when the prospective budget is smaller

#### Scenario: Timing data is missing or a condition breaks

- **WHEN** either percentile is absent
- **THEN** the governor returns HOLD, marks the sample within budget, clears both pressure streaks, and counts the window toward stability
- **AND** each pressure streak otherwise clears when its condition breaks, and every HOLD counts toward stability

#### Scenario: A step or reset starts a new measurement period

- **WHEN** the governor returns DEMOTE or PROMOTE, or the host resets it
- **THEN** all streak counts clear and the timestamp becomes the new reference for the promotion cooldown

#### Scenario: A host supplies different thresholds

- **WHEN** a host creates a governor with a valid configuration
- **THEN** it uses the supplied demotion and promotion fractions, consecutive-window counts, and promotion cooldown
