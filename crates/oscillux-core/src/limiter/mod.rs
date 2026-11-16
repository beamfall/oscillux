// SPDX-License-Identifier: AGPL-3.0-only
//! Photosensitivity limiter.
//!
//! A [`Policy`] declares the flash ceilings a host accepts. [`Policy::DEFAULT`] holds the hard
//! maxima; a host may tighten any value but never loosen one, and a looser policy is refused
//! with a [`PolicyError`] rather than clamped.
//!
//! [`Limiter`] is the per-frame state machine: it attenuates out-of-bounds frames instead of
//! dropping them. [`analyze`] measures a whole sequence against a policy.
//!
//! [`FlashAnalyzer`] measures flashes from per-region relative luminance and saturated red
//! instead of proxies, with the WCAG 2.3.1 pair rules and a 10-degree field area window.

mod analyze;
mod overlay;
mod policy;
mod regions;
mod state;

pub use analyze::{analyze, Analysis};
pub use overlay::{FlashOverlay, FlashOverlayError, FlashOverlayReport};
pub use policy::{Policy, PolicyError, PolicyField};
pub use regions::{
    FlashAnalyzer, FlashConfig, FlashConfigError, FlashReport, RedRule, RegionColor, RegionError,
    RegionSample, DARKER_LIMIT, LUMINANCE_CHANGE, MAX_GRID, RED_CHANGE, RED_CHROMATICITY_CHANGE,
    RED_SATURATION,
};
pub use state::Limiter;

/// Magnitude at or above which an onset or a red transition counts as a flash.
pub const FLASH_THRESHOLD: f64 = 0.80;

/// Length of the sliding window that flashes are counted over, in milliseconds.
pub const WINDOW_MS: f64 = 1000.0;

/// Largest forward timestamp gap the limiter credits as elapsed time, in milliseconds. A
/// larger gap is a discontinuity and credits none, so a far-future timestamp cannot empty the
/// window; emptying a full window takes at least four frames. Smaller inflated gaps are
/// credited in full.
pub const MAX_CREDITED_GAP_MS: f64 = WINDOW_MS / 4.0;

/// One frame of host-supplied proxies; this does not measure rendered pixels.
///
/// Onset magnitudes drive luminance and are normalized to `0..=1`. `red` is the magnitude of the
/// frame's transition to or from a saturated red. `area` is the fraction of the screen the
/// frame's change covers.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Frame {
    /// Presentation time in milliseconds. Frames must arrive in non-decreasing time order
    /// until [`Limiter::reset`] starts a new timeline.
    pub time_ms: f64,
    /// Broadband onset: the luminance-driving signal.
    pub broadband: f64,
    /// Low-band onset.
    pub low: f64,
    /// Mid-band onset.
    pub mid: f64,
    /// High-band onset.
    pub high: f64,
    /// Saturated-red transition magnitude.
    pub red: f64,
    /// Fraction of the screen area the change covers.
    pub area: f64,
}

/// Invalid frame input; rejected before the limiter changes state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameError {
    /// `time_ms` was not finite.
    NonFiniteTime,
    /// `time_ms` was earlier than the previous frame's.
    DecreasingTime,
    /// A scalar was not finite or outside `[0, 1]`.
    InvalidScalar,
}

impl core::fmt::Display for FrameError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "invalid limiter frame: {self:?}")
    }
}
impl core::error::Error for FrameError {}

/// A sequence could not be analyzed because its policy or frames are invalid.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnalysisError {
    /// The policy was refused.
    Policy(PolicyError),
    /// A frame was refused.
    Frame(FrameError),
}

impl core::fmt::Display for AnalysisError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Policy(error) => error.fmt(f),
            Self::Frame(error) => error.fmt(f),
        }
    }
}
impl core::error::Error for AnalysisError {}

impl Frame {
    /// The frame a host renders when the limiter refuses its input: no onset, no red
    /// transition and no area, at the input's time.
    pub const fn fail_safe(time_ms: f64) -> Frame {
        Frame {
            time_ms,
            broadband: 0.0,
            low: 0.0,
            mid: 0.0,
            high: 0.0,
            red: 0.0,
            area: 0.0,
        }
    }

    pub(crate) fn validate(&self, previous_time: Option<f64>) -> Result<(), FrameError> {
        if !self.time_ms.is_finite() {
            return Err(FrameError::NonFiniteTime);
        }
        if previous_time.is_some_and(|time| self.time_ms < time) {
            return Err(FrameError::DecreasingTime);
        }
        if [
            self.broadband,
            self.low,
            self.mid,
            self.high,
            self.red,
            self.area,
        ]
        .iter()
        .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
        {
            return Err(FrameError::InvalidScalar);
        }
        Ok(())
    }

    /// A general flash: a threshold onset over more than the policy's flash area.
    fn is_flash(&self, policy: &Policy) -> bool {
        self.broadband >= FLASH_THRESHOLD && self.area > policy.max_flash_area
    }

    /// A red flash: a threshold red transition over more than the policy's flash area.
    fn is_red_flash(&self, policy: &Policy) -> bool {
        self.red >= FLASH_THRESHOLD && self.area > policy.max_flash_area
    }
}

/// Rounds to six decimal places, half away from zero.
fn round6(v: f64) -> f64 {
    libm::round(v * 1_000_000.0) / 1_000_000.0
}

/// Three flashes inside one window with near-uniform spacing.
fn regular_triplet(a: f64, b: f64, c: f64) -> bool {
    c - a < WINDOW_MS && regular_gaps(b - a, c - b)
}

fn regular_gaps(gap1: f64, gap2: f64) -> bool {
    if gap1 <= 0.0 || gap2 <= 0.0 {
        return false;
    }
    (gap1 - gap2).abs() <= 0.25 * gap1.max(gap2)
}
