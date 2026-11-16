// SPDX-License-Identifier: AGPL-3.0-only
//! Numeric quality governor. The host owns ladder meanings, persistence and device policy.

/// Thresholds and timing of a [`Governor`]; `ffi/include/oscillux.h` gives each range.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GovernorConfig {
    /// Target frame duration in milliseconds.
    pub target_ms: f64,
    /// Weight of each sample in the moving average.
    pub ema_alpha: f64,
    /// Durations at or above this many milliseconds are pauses and ignored.
    pub pause_gap_ms: f64,
    /// Samples are capped at `target_ms` times this.
    pub sample_cap_factor: f64,
    /// Per-sample growth factor of the refresh estimate toward `target_ms`.
    pub refresh_drift: f64,
    /// Lower bound of the refresh estimate in milliseconds.
    pub refresh_floor_ms: f64,
    /// An average above `target_ms` times this is slow.
    pub demote_factor: f64,
    /// An average below the refresh estimate times this is fast ...
    pub promote_refresh_factor: f64,
    /// ... as is one below `target_ms` times this.
    pub promote_target_factor: f64,
    /// Consecutive slow samples before a step down.
    pub demote_frames: u32,
    /// Consecutive fast samples before a step up.
    pub promote_frames: u32,
    /// Samples after a step that cannot cause another step.
    pub settle_frames: u32,
    /// Highest quality level.
    pub max_level: u32,
    /// Level after creation.
    pub initial_level: u32,
}
impl Default for GovernorConfig {
    fn default() -> Self {
        Self {
            target_ms: 1000.0 / 60.0,
            ema_alpha: 0.1,
            pause_gap_ms: 250.0,
            sample_cap_factor: 4.0,
            refresh_drift: 1.002,
            refresh_floor_ms: 4.0,
            demote_factor: 1.25,
            promote_refresh_factor: 1.1,
            promote_target_factor: 0.75,
            demote_frames: 45,
            promote_frames: 300,
            settle_frames: 30,
            max_level: 3,
            initial_level: 3,
        }
    }
}
/// The governor's state after a sample.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GovernorStats {
    /// Moving average of frame duration in milliseconds; valid when `has_ema` is 1.
    pub ema_ms: f64,
    /// Estimated display refresh interval in milliseconds.
    pub refresh_ms: f64,
    /// Current quality level, 0 (lowest) to `max_level`.
    pub level: u32,
    /// 0 until the first accepted sample, then 1.
    pub has_ema: u32,
}
/// A configuration was out of range or had no hysteresis.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GovernorError;
/// Steps an integer quality level from frame durations.
#[derive(Clone, Debug)]
pub struct Governor {
    config: GovernorConfig,
    stats: GovernorStats,
    demote: u32,
    promote: u32,
    settle: u32,
}
impl GovernorConfig {
    /// Also requires a nonempty hysteresis band: each promote threshold product with
    /// `target_ms` must be strictly below the demote product. Since the refresh estimate
    /// never exceeds `target_ms`, the live promote threshold then stays below demotion.
    pub fn validate(&self) -> Result<(), GovernorError> {
        let positive = [
            self.target_ms,
            self.ema_alpha,
            self.pause_gap_ms,
            self.sample_cap_factor,
            self.refresh_drift,
            self.refresh_floor_ms,
            self.demote_factor,
            self.promote_refresh_factor,
            self.promote_target_factor,
        ];
        if positive.iter().any(|v| !v.is_finite() || *v <= 0.0)
            || self.ema_alpha > 1.0
            || self.refresh_drift < 1.0
            || self.refresh_floor_ms > self.target_ms
            || self.demote_frames == 0
            || self.promote_frames == 0
            || self.initial_level > self.max_level
            || ![
                self.sample_cap_factor,
                self.demote_factor,
                self.promote_refresh_factor,
                self.promote_target_factor,
            ]
            .iter()
            .all(|v| (self.target_ms * v).is_finite())
            || self.target_ms * self.promote_refresh_factor >= self.target_ms * self.demote_factor
            || self.target_ms * self.promote_target_factor >= self.target_ms * self.demote_factor
        {
            return Err(GovernorError);
        }
        Ok(())
    }
}
impl Governor {
    /// Validates `config` and creates a governor at `initial_level`.
    pub fn new(config: GovernorConfig) -> Result<Self, GovernorError> {
        config.validate()?;
        Ok(Self {
            stats: GovernorStats {
                ema_ms: 0.0,
                refresh_ms: config.target_ms,
                level: config.initial_level,
                has_ema: 0,
            },
            config,
            demote: 0,
            promote: 0,
            settle: 0,
        })
    }
    /// The current state.
    pub fn stats(&self) -> GovernorStats {
        self.stats
    }
    /// Clears the average and counters and sets `level`, clamped to `max_level`.
    pub fn reset(&mut self, level: u32) {
        self.stats = GovernorStats {
            ema_ms: 0.0,
            refresh_ms: self.config.target_ms,
            level: level.min(self.config.max_level),
            has_ema: 0,
        };
        self.demote = 0;
        self.promote = 0;
        self.settle = 0;
    }
    /// Invalid, nonpositive and pause samples are ignored, as in the reference.
    pub fn record(&mut self, frame_ms: f64) -> GovernorStats {
        let c = self.config;
        if !frame_ms.is_finite() || frame_ms <= 0.0 || frame_ms >= c.pause_gap_ms {
            return self.stats;
        }
        let sample = frame_ms.min(c.target_ms * c.sample_cap_factor);
        let drifted = (self.stats.refresh_ms * c.refresh_drift).min(c.target_ms);
        self.stats.refresh_ms = drifted.min(sample).max(c.refresh_floor_ms);
        self.stats.ema_ms = if self.stats.has_ema == 0 {
            sample
        } else {
            self.stats.ema_ms + c.ema_alpha * (sample - self.stats.ema_ms)
        };
        self.stats.has_ema = 1;
        if self.settle > 0 {
            self.settle -= 1;
            return self.stats;
        }
        let down = c.target_ms * c.demote_factor;
        let up = (self.stats.refresh_ms * c.promote_refresh_factor)
            .max(c.target_ms * c.promote_target_factor);
        if self.stats.ema_ms > down {
            self.demote = self.demote.saturating_add(1);
            self.promote = 0;
            if self.demote >= c.demote_frames && self.stats.level > 0 {
                self.stats.level -= 1;
                self.after_step();
            }
        } else if self.stats.ema_ms < up {
            self.promote = self.promote.saturating_add(1);
            self.demote = 0;
            if self.promote >= c.promote_frames && self.stats.level < c.max_level {
                self.stats.level += 1;
                self.after_step();
            }
        } else {
            self.demote = 0;
            self.promote = 0;
        }
        self.stats
    }
    fn after_step(&mut self) {
        self.demote = 0;
        self.promote = 0;
        self.settle = self.config.settle_frames;
    }
}
