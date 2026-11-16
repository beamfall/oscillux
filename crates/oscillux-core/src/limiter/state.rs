// SPDX-License-Identifier: AGPL-3.0-only
//! Per-frame limiter state machine.

use super::{
    regular_gaps, round6, Frame, FrameError, Policy, PolicyError, FLASH_THRESHOLD,
    MAX_CREDITED_GAP_MS, WINDOW_MS,
};

/// Admitted flashes one window can hold. A validated policy admits at most three flashes and
/// three red flashes per window, so the windows never outgrow this.
const WINDOW_CAPACITY: usize = 3;

/// Times of the flashes admitted in the current window.
#[derive(Clone, Copy, Debug)]
struct Window {
    times: [f64; WINDOW_CAPACITY],
    /// Whether the gap before each flash spans a discontinuity, so its real length is unknown.
    unknown_gap: [bool; WINDOW_CAPACITY],
    len: usize,
    /// A discontinuity has passed since the latest flash.
    discontinuity: bool,
}

impl Window {
    const EMPTY: Window = Window {
        times: [0.0; WINDOW_CAPACITY],
        unknown_gap: [false; WINDOW_CAPACITY],
        len: 0,
        discontinuity: false,
    };

    /// Drops flashes that fell out of the window ending at `now_ms`, keeping their order.
    fn trim(&mut self, now_ms: f64) {
        let (times, unknown_gap) = (self.times, self.unknown_gap);
        let mut kept = 0;
        for i in 0..self.len {
            if now_ms - times[i] < WINDOW_MS {
                self.times[kept] = times[i];
                self.unknown_gap[kept] = unknown_gap[i];
                kept += 1;
            }
        }
        self.len = kept;
    }

    /// Moves every flash from the timeline ending at `from_ms` to the one ending at `to_ms`,
    /// keeping its age, so a discontinuity credits no elapsed time.
    fn rebase(&mut self, from_ms: f64, to_ms: f64) {
        for t in &mut self.times[..self.len] {
            *t = to_ms - (from_ms - *t);
        }
        self.discontinuity = true;
    }

    fn push(&mut self, now_ms: f64) {
        self.times[self.len] = now_ms;
        self.unknown_gap[self.len] = self.discontinuity;
        self.discontinuity = false;
        self.len += 1;
    }

    /// Whether a flash at `now_ms` would complete a regular strobe with the admitted flashes.
    /// A gap that spans a discontinuity could have had any length, so it counts as regular.
    fn completes_strobe(&self, now_ms: f64) -> bool {
        let mut times = [0.0; WINDOW_CAPACITY + 1];
        let mut unknown = [false; WINDOW_CAPACITY + 1];
        times[..self.len].copy_from_slice(&self.times[..self.len]);
        unknown[..self.len].copy_from_slice(&self.unknown_gap[..self.len]);
        times[self.len] = now_ms;
        unknown[self.len] = self.discontinuity;
        (2..=self.len).any(|i| {
            let (a, b, c) = (times[i - 2], times[i - 1], times[i]);
            c - a < WINDOW_MS && (unknown[i - 1] || unknown[i] || regular_gaps(b - a, c - b))
        })
    }
}

/// Attenuates out-of-bounds frames so the output satisfies its policy.
///
/// Flashes are detected on the input, before the luminance ceiling, so a ceiling tightened
/// below [`FLASH_THRESHOLD`] cannot hide them from the budget. Once the window holds as many
/// flashes as the policy allows, or a flash would complete a banned strobe, the flash is
/// attenuated below [`FLASH_THRESHOLD`]. Red flashes past the red budget have their red
/// transition attenuated the same way. Every onset is then lowered to the luminance ceiling,
/// so tightening the ceiling never raises an output onset or changes which flashes are
/// admitted. [`Limiter::process`] does not allocate.
///
/// Timestamps are trusted only as far as a continuous stream needs. A forward gap above
/// [`MAX_CREDITED_GAP_MS`], and the first frame after [`Limiter::reset`], are
/// discontinuities: they credit no elapsed time, so admitted flashes keep their age and still
/// count against the budget, and the strobe ban treats a gap across one as regular. Each frame
/// credits at most [`MAX_CREDITED_GAP_MS`], so the budget holds in real time only for a host
/// that reports its gaps truthfully.
#[derive(Clone, Debug)]
pub struct Limiter {
    policy: Policy,
    flashes: Window,
    red_flashes: Window,
    previous_time: Option<f64>,
    /// The next frame starts a new timeline: set by reset.
    discontinuity: bool,
}

impl Limiter {
    /// Creates a limiter, refusing a policy that [`Policy::validate`] refuses.
    pub fn new(policy: Policy) -> Result<Self, PolicyError> {
        policy.validate()?;
        Ok(Limiter {
            policy,
            flashes: Window::EMPTY,
            red_flashes: Window::EMPTY,
            previous_time: None,
            discontinuity: false,
        })
    }

    /// The policy this limiter enforces.
    pub fn policy(&self) -> &Policy {
        &self.policy
    }

    /// Starts a new timeline, as at a seek or a new stream: the next frame may carry any finite
    /// timestamp. Admitted flashes are kept at their current age, because the viewer's
    /// exposure does not restart with the timeline. Create a new limiter to forget them.
    pub fn reset(&mut self) {
        self.discontinuity = self.previous_time.is_some();
    }

    /// Returns `frame` attenuated to the policy, and advances the state.
    /// Invalid frame values or decreasing timestamps leave the state unchanged; a host should
    /// then render [`Frame::fail_safe`].
    pub fn process(&mut self, frame: Frame) -> Result<Frame, FrameError> {
        let continuous_from = self.previous_time.filter(|_| !self.discontinuity);
        frame.validate(continuous_from)?;
        if let Some(previous) = self.previous_time {
            if self.discontinuity || frame.time_ms - previous > MAX_CREDITED_GAP_MS {
                self.flashes.rebase(previous, frame.time_ms);
                self.red_flashes.rebase(previous, frame.time_ms);
            }
        }
        self.discontinuity = false;
        let mut out = frame;
        if frame.is_flash(&self.policy) && !self.admit_flash(frame.time_ms) {
            out = attenuate_flash(out);
        }
        if frame.is_red_flash(&self.policy) && !self.admit_red_flash(frame.time_ms) {
            out.red = attenuated_level();
        }
        self.previous_time = Some(frame.time_ms);
        Ok(attenuate_luminance(out, self.policy.max_luminance_delta))
    }

    fn admit_flash(&mut self, now_ms: f64) -> bool {
        self.flashes.trim(now_ms);
        let at_rate = (self.flashes.len + 1) as f64 > self.policy.max_flash_hz;
        let strobe = self.policy.strobe_banned && self.flashes.completes_strobe(now_ms);
        if at_rate || strobe {
            return false;
        }
        self.flashes.push(now_ms);
        true
    }

    fn admit_red_flash(&mut self, now_ms: f64) -> bool {
        self.red_flashes.trim(now_ms);
        if self.red_flashes.len >= self.policy.max_red_flashes as usize {
            return false;
        }
        self.red_flashes.push(now_ms);
        true
    }
}

/// The level an attenuated flash is lowered to: half the flash threshold.
fn attenuated_level() -> f64 {
    round6(FLASH_THRESHOLD * 0.5)
}

fn attenuate_luminance(mut frame: Frame, ceiling: f64) -> Frame {
    // Never round a tightened ceiling upward.
    let level = (libm::floor(ceiling * 1_000_000.0) / 1_000_000.0).min(ceiling);
    for onset in [
        &mut frame.broadband,
        &mut frame.low,
        &mut frame.mid,
        &mut frame.high,
    ] {
        if *onset > level {
            *onset = level;
        }
    }
    frame
}

fn attenuate_flash(mut frame: Frame) -> Frame {
    let level = attenuated_level();
    frame.broadband = level;
    for onset in [&mut frame.low, &mut frame.mid, &mut frame.high] {
        if *onset > level {
            *onset = level;
        }
    }
    frame
}
