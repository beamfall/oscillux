// SPDX-License-Identifier: AGPL-3.0-only
//! Transition scheduler: when a visual switch starts and how far its blend has progressed,
//! as a function of presentation time. The host supplies its beat state as plain numbers and
//! owns which visuals and which transition are shown.
//!
//! A request first pre-rolls the incoming visual for `pre_roll_seconds`, then waits for the
//! next beat or bar boundary (when the beat is confident), then blends for a duration given in
//! beats and clamped to [`MIN_DURATION_SECONDS`, `MAX_DURATION_SECONDS`]. Every step uses only
//! `+ - * /`, `ceil`, comparisons and the easing polynomial, so results are identical on every
//! target and match the stdlib oracle `tools/transition-vectors.py`.

/// `quantise`: start as soon as the pre-roll ends.
pub const QUANTISE_NONE: u32 = 0;
/// `quantise`: start on the first beat at or after the end of the pre-roll.
pub const QUANTISE_BEAT: u32 = 1;
/// `quantise`: start on the first bar at or after the end of the pre-roll.
pub const QUANTISE_BAR: u32 = 2;

/// No request since creation or reset.
pub const STATE_IDLE: u32 = 0;
/// The incoming visual is warming up offscreen; nothing is blended yet.
pub const STATE_PRE_ROLL: u32 = 1;
/// The pre-roll is done; waiting for the quantised start.
pub const STATE_WAITING: u32 = 2;
/// Start reached and end not yet reached; `progress` rises from 0 toward 1.
pub const STATE_BLENDING: u32 = 3;
/// The end is reached; `progress` is exactly 1.
pub const STATE_DONE: u32 = 4;

/// `easing`: progress is linear in time.
pub const EASING_LINEAR: u32 = 0;
/// `easing`: progress is `u * u * (3 - 2u)` of the linear fraction `u`.
pub const EASING_SMOOTHSTEP: u32 = 1;

/// Shortest blend in seconds.
pub const MIN_DURATION_SECONDS: f64 = 0.8;
/// Longest blend in seconds.
pub const MAX_DURATION_SECONDS: f64 = 2.5;
/// Slowest tempo treated as a beat; slower clocks count as no beat.
pub const MIN_TEMPO_BPM: f64 = 30.0;
/// Fastest tempo treated as a beat; faster clocks count as no beat.
pub const MAX_TEMPO_BPM: f64 = 300.0;
/// Tempo used to count auto-advance bars while there is no confident beat.
pub const FALLBACK_TEMPO_BPM: f64 = 120.0;

/// Scheduler settings; `ffi/include/oscillux.h` gives each range.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransitionConfig {
    /// [`EASING_LINEAR`] or [`EASING_SMOOTHSTEP`].
    pub easing: u32,
    /// Beats in a bar, 1 to 16.
    pub beats_per_bar: u32,
    /// Bars between automatic requests; 0 turns auto-advance off. At most 1024.
    pub auto_advance_bars: u32,
    /// Blend length in beats when the beat is confident, above 0 and at most 64.
    pub duration_beats: f64,
    /// Blend length in seconds without a confident beat, within the duration clamp.
    pub fallback_seconds: f64,
    /// Seconds the incoming visual runs before it may become visible, 0 to 10.
    pub pre_roll_seconds: f64,
    /// Confidence at or above which the beat clock is used, 0 to 1.
    pub min_confidence: f64,
}

impl Default for TransitionConfig {
    fn default() -> Self {
        Self {
            easing: EASING_LINEAR,
            beats_per_bar: 4,
            auto_advance_bars: 0,
            duration_beats: 4.0,
            fallback_seconds: 1.6,
            pre_roll_seconds: 0.5,
            min_confidence: 0.5,
        }
    }
}

/// The host's beat state at one presentation time. Only `time_seconds` must be valid; a
/// clock whose other fields are out of range counts as having no confident beat.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TransitionClock {
    /// Presentation time in seconds on the host's monotonic clock; must be finite.
    pub time_seconds: f64,
    /// Fraction of the current beat elapsed, 0 to 1.
    pub beat_phase: f64,
    /// Fraction of the current bar elapsed, 0 to 1.
    pub bar_phase: f64,
    /// Tempo in beats per minute, [`MIN_TEMPO_BPM`] to [`MAX_TEMPO_BPM`].
    pub tempo_bpm: f64,
    /// Beat confidence, compared against `min_confidence`.
    pub confidence: f64,
}

/// The schedule and its evaluation at one time.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TransitionStatus {
    /// Eased progress: exactly 0 up to the start, exactly 1 from the end on.
    pub progress: f64,
    /// Time of the current request; 0 while idle.
    pub request_seconds: f64,
    /// Blend start; 0 while idle.
    pub start_seconds: f64,
    /// Blend end; 0 while idle.
    pub end_seconds: f64,
    /// One of the `STATE_*` values.
    pub state: u32,
    /// The quantisation actually applied, after any fallback.
    pub quantise: u32,
    /// 1 when this update issued an automatic request, else 0.
    pub auto_requested: u32,
    /// Always 0.
    pub reserved: u32,
}

/// A configuration or input was out of range.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TransitionError;

impl TransitionConfig {
    /// Checks every range given in `ffi/include/oscillux.h`.
    pub fn validate(&self) -> Result<(), TransitionError> {
        let ok = self.easing <= EASING_SMOOTHSTEP
            && (1..=16).contains(&self.beats_per_bar)
            && self.auto_advance_bars <= 1024
            && self.duration_beats > 0.0
            && self.duration_beats <= 64.0
            && self.fallback_seconds >= MIN_DURATION_SECONDS
            && self.fallback_seconds <= MAX_DURATION_SECONDS
            && self.pre_roll_seconds >= 0.0
            && self.pre_roll_seconds <= 10.0
            && self.min_confidence >= 0.0
            && self.min_confidence <= 1.0;
        if ok {
            Ok(())
        } else {
            Err(TransitionError)
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct Schedule {
    request: f64,
    earliest: f64,
    start: f64,
    end: f64,
    quantise: u32,
}

/// Schedules one switch at a time from presentation time and a beat clock.
#[derive(Clone, Debug)]
pub struct TransitionScheduler {
    config: TransitionConfig,
    schedule: Option<Schedule>,
    /// Time auto-advance counts from: the first update, then each blend end.
    anchor: Option<f64>,
}

/// Beat period in seconds when `clock` carries a confident beat.
fn beat_period(config: &TransitionConfig, clock: &TransitionClock) -> Option<f64> {
    let in_unit = |v: f64| (0.0..=1.0).contains(&v);
    let confident = clock.confidence >= config.min_confidence
        && clock.tempo_bpm >= MIN_TEMPO_BPM
        && clock.tempo_bpm <= MAX_TEMPO_BPM
        && in_unit(clock.beat_phase)
        && in_unit(clock.bar_phase);
    confident.then(|| 60.0 / clock.tempo_bpm)
}

/// The first boundary `request + (k - phase) * period` at or after `earliest`, integer `k`.
fn next_boundary(request: f64, earliest: f64, phase: f64, period: f64) -> f64 {
    let k = libm::ceil((earliest - request) / period + phase);
    let at = request + (k - phase) * period;
    if at < earliest {
        earliest
    } else {
        at
    }
}

fn ease(easing: u32, u: f64) -> f64 {
    if easing == EASING_SMOOTHSTEP {
        u * u * (3.0 - 2.0 * u)
    } else {
        u
    }
}

impl TransitionScheduler {
    /// Validates `config` and creates an idle scheduler.
    pub fn new(config: TransitionConfig) -> Result<Self, TransitionError> {
        config.validate()?;
        Ok(Self {
            config,
            schedule: None,
            anchor: None,
        })
    }

    /// The configuration this scheduler was created with.
    pub fn config(&self) -> TransitionConfig {
        self.config
    }

    /// Back to idle; auto-advance counts again from the next update.
    pub fn reset(&mut self) {
        self.schedule = None;
        self.anchor = None;
    }

    /// Schedules a switch requested at `clock.time_seconds`, replacing any current one.
    ///
    /// With a confident beat, `quantise` picks the first beat or bar at or after the end of
    /// the pre-roll; when that is more than `max_wait_seconds` after the pre-roll ends, bar
    /// falls back to beat and beat to none. Without a confident beat the blend starts when the
    /// pre-roll ends and lasts `fallback_seconds`.
    pub fn request(
        &mut self,
        clock: &TransitionClock,
        quantise: u32,
        max_wait_seconds: f64,
    ) -> Result<TransitionStatus, TransitionError> {
        // A NaN or negative wait is refused; +infinity means no limit.
        if !clock.time_seconds.is_finite()
            || quantise > QUANTISE_BAR
            || max_wait_seconds.is_nan()
            || max_wait_seconds < 0.0
        {
            return Err(TransitionError);
        }
        let c = self.config;
        let request = clock.time_seconds;
        let earliest = request + c.pre_roll_seconds;
        let (start, applied, duration) = match beat_period(&c, clock) {
            Some(beat) => {
                let mut start = earliest;
                let mut applied = QUANTISE_NONE;
                if quantise == QUANTISE_BAR {
                    let bar = beat * f64::from(c.beats_per_bar);
                    let at = next_boundary(request, earliest, clock.bar_phase, bar);
                    if at - earliest <= max_wait_seconds {
                        start = at;
                        applied = QUANTISE_BAR;
                    }
                }
                if quantise != QUANTISE_NONE && applied == QUANTISE_NONE {
                    let at = next_boundary(request, earliest, clock.beat_phase, beat);
                    if at - earliest <= max_wait_seconds {
                        start = at;
                        applied = QUANTISE_BEAT;
                    }
                }
                let duration =
                    (c.duration_beats * beat).clamp(MIN_DURATION_SECONDS, MAX_DURATION_SECONDS);
                (start, applied, duration)
            }
            None => (earliest, QUANTISE_NONE, c.fallback_seconds),
        };
        self.schedule = Some(Schedule {
            request,
            earliest,
            start,
            end: start + duration,
            quantise: applied,
        });
        self.anchor = None;
        Ok(self.status_at(request, 0))
    }

    /// Progress at `time_seconds`: exactly 0 up to the start (and while idle), exactly 1 from
    /// the end on, eased in between.
    pub fn progress(&self, time_seconds: f64) -> f64 {
        let Some(s) = self.schedule else {
            return 0.0;
        };
        if time_seconds.is_nan() || time_seconds <= s.start {
            return 0.0;
        }
        if time_seconds >= s.end {
            return 1.0;
        }
        let u = ((time_seconds - s.start) / (s.end - s.start)).clamp(0.0, 1.0);
        ease(self.config.easing, u)
    }

    /// Per-frame evaluation; issues an automatic bar-quantised request when auto-advance is on
    /// and `auto_advance_bars` bars have passed since the first update or the last blend end.
    pub fn update(&mut self, clock: &TransitionClock) -> Result<TransitionStatus, TransitionError> {
        let t = clock.time_seconds;
        if !t.is_finite() {
            return Err(TransitionError);
        }
        let c = self.config;
        if c.auto_advance_bars > 0 {
            let settled = match self.schedule {
                None => true,
                Some(s) => t >= s.end,
            };
            if settled {
                let anchor = match (self.anchor, self.schedule) {
                    (Some(a), _) => a,
                    (None, Some(s)) => s.end,
                    (None, None) => t,
                };
                self.anchor = Some(anchor);
                let beat = beat_period(&c, clock);
                let bar = beat.unwrap_or(60.0 / FALLBACK_TEMPO_BPM) * f64::from(c.beats_per_bar);
                if t - anchor >= f64::from(c.auto_advance_bars) * bar {
                    self.request(clock, QUANTISE_BAR, bar)?;
                    return Ok(self.status_at(t, 1));
                }
            }
        }
        Ok(self.status_at(t, 0))
    }

    /// The schedule evaluated at `time_seconds` without changing anything.
    pub fn status(&self, time_seconds: f64) -> TransitionStatus {
        self.status_at(time_seconds, 0)
    }

    fn status_at(&self, t: f64, auto_requested: u32) -> TransitionStatus {
        let Some(s) = self.schedule else {
            return TransitionStatus {
                auto_requested,
                ..TransitionStatus::default()
            };
        };
        let state = if t >= s.end {
            STATE_DONE
        } else if t >= s.start {
            STATE_BLENDING
        } else if t >= s.earliest {
            STATE_WAITING
        } else {
            STATE_PRE_ROLL
        };
        TransitionStatus {
            progress: self.progress(t),
            request_seconds: s.request,
            start_seconds: s.start,
            end_seconds: s.end,
            state,
            quantise: s.quantise,
            auto_requested,
            reserved: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clock(
        t: f64,
        beat_phase: f64,
        bar_phase: f64,
        tempo: f64,
        confidence: f64,
    ) -> TransitionClock {
        TransitionClock {
            time_seconds: t,
            beat_phase,
            bar_phase,
            tempo_bpm: tempo,
            confidence,
        }
    }

    #[test]
    fn default_config_is_valid_and_bad_ranges_are_refused() {
        assert!(TransitionScheduler::new(TransitionConfig::default()).is_ok());
        let bad = [
            TransitionConfig {
                easing: 2,
                ..Default::default()
            },
            TransitionConfig {
                beats_per_bar: 0,
                ..Default::default()
            },
            TransitionConfig {
                duration_beats: f64::NAN,
                ..Default::default()
            },
            TransitionConfig {
                fallback_seconds: 0.5,
                ..Default::default()
            },
            TransitionConfig {
                pre_roll_seconds: -0.1,
                ..Default::default()
            },
            TransitionConfig {
                min_confidence: 1.5,
                ..Default::default()
            },
            TransitionConfig {
                auto_advance_bars: 2000,
                ..Default::default()
            },
        ];
        for config in bad {
            assert!(TransitionScheduler::new(config).is_err(), "{config:?}");
        }
    }

    #[test]
    fn no_beat_starts_after_pre_roll_with_fallback_duration() {
        let mut s = TransitionScheduler::new(TransitionConfig::default()).unwrap();
        let st = s
            .request(&clock(10.0, 0.0, 0.0, 0.0, 0.0), QUANTISE_BAR, 2.0)
            .unwrap();
        assert_eq!(st.state, STATE_PRE_ROLL);
        assert_eq!(st.quantise, QUANTISE_NONE);
        assert_eq!(st.start_seconds, 10.5);
        assert_eq!(st.end_seconds, 12.1);
        assert_eq!(s.progress(10.5), 0.0);
        assert_eq!(s.progress(12.1), 1.0);
        assert_eq!(s.progress(1e9), 1.0);
        assert!(s.progress(11.0) > 0.0 && s.progress(11.0) < 1.0);
    }

    #[test]
    fn bar_quantise_lands_on_the_next_bar_after_pre_roll() {
        let mut s = TransitionScheduler::new(TransitionConfig::default()).unwrap();
        // 120 BPM: beat 0.5 s, bar 2 s. Bar phase 0.5 at t=10: bars at 11, 13.
        let st = s
            .request(&clock(10.0, 0.0, 0.5, 120.0, 0.9), QUANTISE_BAR, 2.0)
            .unwrap();
        assert_eq!(st.quantise, QUANTISE_BAR);
        assert_eq!(st.start_seconds, 11.0);
        // 4 beats at 0.5 s = 2.0 s.
        assert_eq!(st.end_seconds, 13.0);
        // Bar phase 0.9 at t=10: bar at 10.2 is inside the pre-roll, next at 12.2.
        let st = s
            .request(&clock(10.0, 0.6, 0.9, 120.0, 0.9), QUANTISE_BAR, 2.0)
            .unwrap();
        assert!((st.start_seconds - 12.2).abs() < 1e-12);
        // A tight wait limit falls back to the beat: beats at 10.2, 10.7.
        let st = s
            .request(&clock(10.0, 0.6, 0.9, 120.0, 0.9), QUANTISE_BAR, 0.3)
            .unwrap();
        assert_eq!(st.quantise, QUANTISE_BEAT);
        assert!((st.start_seconds - 10.7).abs() < 1e-12);
        // No wait allowed and not on a boundary: start at the end of the pre-roll.
        let st = s
            .request(&clock(10.0, 0.6, 0.9, 120.0, 0.9), QUANTISE_BAR, 0.0)
            .unwrap();
        assert_eq!(st.quantise, QUANTISE_NONE);
        assert_eq!(st.start_seconds, 10.5);
    }

    #[test]
    fn duration_is_clamped() {
        let mut s = TransitionScheduler::new(TransitionConfig::default()).unwrap();
        let st = s
            .request(&clock(0.0, 0.0, 0.0, 60.0, 1.0), QUANTISE_NONE, 0.0)
            .unwrap();
        assert_eq!(st.end_seconds - st.start_seconds, MAX_DURATION_SECONDS);
        let st = s
            .request(&clock(0.0, 0.0, 0.0, 300.0, 1.0), QUANTISE_NONE, 0.0)
            .unwrap();
        assert_eq!(st.end_seconds - st.start_seconds, MIN_DURATION_SECONDS);
    }

    #[test]
    fn states_follow_time() {
        let mut s = TransitionScheduler::new(TransitionConfig::default()).unwrap();
        assert_eq!(s.status(0.0).state, STATE_IDLE);
        s.request(&clock(0.0, 0.0, 0.5, 120.0, 1.0), QUANTISE_BAR, 2.0)
            .unwrap();
        assert_eq!(s.status(0.2).state, STATE_PRE_ROLL);
        assert_eq!(s.status(0.7).state, STATE_WAITING);
        assert_eq!(s.status(1.0).state, STATE_BLENDING);
        assert_eq!(s.status(1.0).progress, 0.0);
        assert_eq!(s.status(3.0).state, STATE_DONE);
        assert_eq!(s.status(3.0).progress, 1.0);
        s.reset();
        assert_eq!(s.status(1.0).state, STATE_IDLE);
    }

    #[test]
    fn auto_advance_requests_every_n_bars() {
        let config = TransitionConfig {
            auto_advance_bars: 2,
            ..Default::default()
        };
        let mut s = TransitionScheduler::new(config).unwrap();
        // No beat: bars counted at 120 BPM, 2 bars = 4 s from the first update.
        let mut autos = alloc::vec::Vec::new();
        let mut frame = 0u32;
        while frame < 60 * 20 {
            let t = f64::from(frame) / 60.0;
            let st = s.update(&clock(t, 0.0, 0.0, 0.0, 0.0)).unwrap();
            if st.auto_requested == 1 {
                autos.push(frame);
            }
            frame += 1;
        }
        // First at 4 s; blend ends 2.1 s later; the next 4 s after that, and so on.
        assert_eq!(autos, [240, 606, 972]);
    }

    #[test]
    fn invalid_inputs_are_refused() {
        let mut s = TransitionScheduler::new(TransitionConfig::default()).unwrap();
        let good = clock(0.0, 0.0, 0.0, 120.0, 1.0);
        assert!(s.request(&good, 3, 1.0).is_err());
        assert!(s.request(&good, QUANTISE_BAR, f64::NAN).is_err());
        assert!(s.request(&good, QUANTISE_BAR, -1.0).is_err());
        assert!(s
            .request(
                &clock(f64::INFINITY, 0.0, 0.0, 120.0, 1.0),
                QUANTISE_BAR,
                1.0
            )
            .is_err());
        assert!(s.update(&clock(f64::NAN, 0.0, 0.0, 0.0, 0.0)).is_err());
        assert!(s.request(&good, QUANTISE_BAR, f64::INFINITY).is_ok());
    }
}
