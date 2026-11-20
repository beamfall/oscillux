// SPDX-License-Identifier: AGPL-3.0-only
//! Frame-window decisions. The host supplies timing and delivery health and applies the steps.

/// Thresholds and timing for a [WindowGovernor].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowGovernorConfig {
    /// Over-budget p95 threshold as a fraction of the current target interval.
    pub demote_budget_fraction: f64,
    /// Promotion p95 threshold as a fraction of the prospective interval.
    pub promote_budget_fraction: f64,
    /// Consecutive over-budget windows needed to demote.
    pub demote_windows: u32,
    /// Consecutive promotion-eligible windows needed to promote.
    pub promote_windows: u32,
    /// Minimum seconds between the most recent change and promotion.
    pub cooldown_s: f64,
}

impl Default for WindowGovernorConfig {
    fn default() -> Self {
        Self {
            demote_budget_fraction: 0.85,
            promote_budget_fraction: 0.60,
            demote_windows: 30,
            promote_windows: 300,
            cooldown_s: 5.0,
        }
    }
}

/// One telemetry window.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowSample {
    /// Optional 95th-percentile frame duration in milliseconds.
    pub p95_ms: Option<f64>,
    /// Optional 99th-percentile frame duration in milliseconds.
    pub p99_ms: Option<f64>,
    /// Current target frame interval in milliseconds.
    pub interval_ms: f64,
    /// Next step's frame interval in milliseconds, or zero when no step is available.
    pub promotion_budget_ms: f64,
    /// The delivery path was starved.
    pub starved: bool,
    /// The delivery path was dropping frames.
    pub dropping: bool,
    /// Sample time in monotonic seconds.
    pub now_s: f64,
    /// Whether the host has no lower step available.
    pub at_floor: bool,
}

/// The step a host should apply.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowDecision {
    /// Keep the current step.
    Hold = 0,
    /// Step down.
    Demote = 1,
    /// Step up.
    Promote = 2,
}

/// Classification and streaks after recording a window.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WindowResult {
    /// The requested step.
    pub decision: WindowDecision,
    /// Whether this window exceeded the current budget.
    pub over_budget: bool,
    /// Consecutive over-budget windows.
    pub over_budget_streak: u32,
    /// Consecutive promotion-eligible windows.
    pub promotion_streak: u32,
    /// Stable windows since the latest change. Sustained pressure at the floor pauses this count.
    pub stable_streak: u32,
}

/// The configuration, timestamp, or window was invalid.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WindowGovernorError;

/// Allocation-free frame-window state.
#[derive(Debug)]
pub struct WindowGovernor {
    config: WindowGovernorConfig,
    last_change_s: f64,
    last_sample_s: f64,
    over_budget_streak: u32,
    promotion_streak: u32,
    stable_streak: u32,
}

fn finite_nonnegative(value: f64) -> bool {
    value.is_finite() && value >= 0.0
}

impl WindowGovernor {
    /// Starts a governor with zero streaks and the promotion cooldown starting at `now_s`.
    pub fn new(config: WindowGovernorConfig, now_s: f64) -> Result<Self, WindowGovernorError> {
        if !(0.0 < config.promote_budget_fraction
            && config.promote_budget_fraction < config.demote_budget_fraction
            && config.demote_budget_fraction <= 1.0)
            || !finite_nonnegative(config.cooldown_s)
            || config.demote_windows == 0
            || config.promote_windows == 0
            || !finite_nonnegative(now_s)
        {
            return Err(WindowGovernorError);
        }
        Ok(Self {
            config,
            last_change_s: now_s,
            last_sample_s: now_s,
            over_budget_streak: 0,
            promotion_streak: 0,
            stable_streak: 0,
        })
    }

    /// Records one window. Invalid input leaves all state unchanged.
    pub fn record(&mut self, sample: WindowSample) -> Result<WindowResult, WindowGovernorError> {
        if !finite_nonnegative(sample.now_s)
            || sample.now_s < self.last_sample_s
            || !sample.interval_ms.is_finite()
            || sample.interval_ms <= 0.0
            || !finite_nonnegative(sample.promotion_budget_ms)
            || sample.p95_ms.is_some_and(|ms| !finite_nonnegative(ms))
            || sample.p99_ms.is_some_and(|ms| !finite_nonnegative(ms))
        {
            return Err(WindowGovernorError);
        }
        self.last_sample_s = sample.now_s;

        let (over_budget, promotion_eligible) = match (sample.p95_ms, sample.p99_ms) {
            (Some(p95), Some(p99)) => {
                let over_budget = p95 > self.config.demote_budget_fraction * sample.interval_ms
                    || p99 > sample.interval_ms
                    || sample.starved
                    || sample.dropping;
                (
                    over_budget,
                    !over_budget
                        && p95 < self.config.promote_budget_fraction * sample.promotion_budget_ms,
                )
            }
            _ => (false, false),
        };
        self.over_budget_streak = if over_budget {
            self.over_budget_streak.saturating_add(1)
        } else {
            0
        };
        self.promotion_streak = if promotion_eligible {
            self.promotion_streak.saturating_add(1)
        } else {
            0
        };
        let demotion_threshold_reached = self.over_budget_streak >= self.config.demote_windows;
        let decision = if demotion_threshold_reached && !sample.at_floor {
            WindowDecision::Demote
        } else if self.promotion_streak >= self.config.promote_windows
            && sample.now_s - self.last_change_s >= self.config.cooldown_s
        {
            WindowDecision::Promote
        } else {
            WindowDecision::Hold
        };

        match decision {
            WindowDecision::Hold if !demotion_threshold_reached => {
                self.stable_streak = self.stable_streak.saturating_add(1);
            }
            WindowDecision::Hold => {}
            WindowDecision::Demote | WindowDecision::Promote => self.note_change(sample.now_s),
        }
        Ok(WindowResult {
            decision,
            over_budget,
            over_budget_streak: self.over_budget_streak,
            promotion_streak: self.promotion_streak,
            stable_streak: self.stable_streak,
        })
    }

    /// Clears all streaks and starts the cooldown and sample clock at `now_s`.
    pub fn reset(&mut self, now_s: f64) -> Result<(), WindowGovernorError> {
        if !finite_nonnegative(now_s) {
            return Err(WindowGovernorError);
        }
        self.last_sample_s = now_s;
        self.note_change(now_s);
        Ok(())
    }

    fn note_change(&mut self, now_s: f64) {
        self.last_change_s = now_s;
        self.over_budget_streak = 0;
        self.promotion_streak = 0;
        self.stable_streak = 0;
    }
}
