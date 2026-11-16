// SPDX-License-Identifier: AGPL-3.0-only
//! Whole-sequence flash analysis.

use super::{regular_triplet, AnalysisError, Frame, Policy, WINDOW_MS};

/// Result of scanning a frame sequence.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Analysis {
    /// Most general flashes in any one-second window.
    pub peak_flash_hz: f64,
    /// Largest broadband onset; retained exactly so tightened ceilings cannot hide below rounding.
    pub peak_luminance_delta: f64,
    /// Whether three regularly spaced general flashes fell inside one window.
    pub strobe_detected: bool,
    /// Most red flashes in any one-second window.
    pub peak_red_flashes: u32,
}

impl Analysis {
    /// Whether the analysis violates `policy` on any axis.
    pub fn exceeds(&self, policy: &Policy) -> bool {
        self.peak_flash_hz > policy.max_flash_hz
            || self.peak_luminance_delta > policy.max_luminance_delta
            || (policy.strobe_banned && self.strobe_detected)
            || self.peak_red_flashes > policy.max_red_flashes
    }
}

/// Measures `frames` against `policy`, whose area threshold decides which changes are flashes.
/// Refuses a policy that [`Policy::validate`] refuses. Does not allocate.
pub fn analyze(frames: &[Frame], policy: &Policy) -> Result<Analysis, AnalysisError> {
    policy.validate().map_err(AnalysisError::Policy)?;
    let mut previous_time = None;
    for frame in frames {
        frame
            .validate(previous_time)
            .map_err(AnalysisError::Frame)?;
        previous_time = Some(frame.time_ms);
    }
    let is_flash = |f: &Frame| f.is_flash(policy);
    let is_red_flash = |f: &Frame| f.is_red_flash(policy);
    Ok(Analysis {
        peak_flash_hz: f64::from(peak_window_count(frames, is_flash)),
        peak_luminance_delta: peak_luminance_delta(frames),
        strobe_detected: strobe_in_sequence(frames, is_flash),
        peak_red_flashes: peak_window_count(frames, is_red_flash),
    })
}

fn peak_luminance_delta(frames: &[Frame]) -> f64 {
    frames
        .iter()
        .fold(0.0, |peak: f64, f| peak.max(f.broadband))
}

/// The largest count of matching frames inside a window anchored at a matching frame.
fn peak_window_count(frames: &[Frame], counts: impl Fn(&Frame) -> bool) -> u32 {
    frames
        .iter()
        .enumerate()
        .filter(|(_, f)| counts(f))
        .map(|(i, start)| window_count(&frames[i..], start.time_ms, &counts))
        .max()
        .unwrap_or(0)
}

fn window_count(rest: &[Frame], start_ms: f64, counts: &impl Fn(&Frame) -> bool) -> u32 {
    let in_window = rest
        .iter()
        .filter(|f| counts(f))
        .take_while(|f| f.time_ms - start_ms < WINDOW_MS)
        .count();
    u32::try_from(in_window).unwrap_or(u32::MAX)
}

fn strobe_in_sequence(frames: &[Frame], counts: impl Fn(&Frame) -> bool) -> bool {
    let times = || frames.iter().filter(|f| counts(f)).map(|f| f.time_ms);
    times()
        .zip(times().skip(1))
        .zip(times().skip(2))
        .any(|((a, b), c)| regular_triplet(a, b, c))
}
