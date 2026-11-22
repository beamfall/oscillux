// SPDX-License-Identifier: AGPL-3.0-only
//! Reaction sampler: turns analysis hops into the audio values of one display frame at the
//! moment its light reaches the viewer.
//!
//! A host pushes every mapped hop with its beat output and media time
//! ([`ReactionSampler::push`]) and samples once per display frame
//! ([`ReactionSampler::sample`]). `conformance/reaction/README.md` specifies the model and
//! `tools/reaction-vectors.py` is its independent oracle.
//!
//! All times are on the media timeline in milliseconds. A sample at host time `time` targets the
//! media position heard when the frame is seen:
//!
//! ```text
//! target = time + render_ahead + display_latency - output_latency
//! ```
//!
//! A hop pushed at window-end media time `m` describes the audio at `m - analysis_latency`
//! (continuous values and the beat clock) and `m - onset_latency` (transients). Every DSP
//! version is late by its own amount; [`ReactionConfig::for_dsp`] holds the measured table.
//!
//! - Transients ([`ONSET`], [`BASS_IMPACT`], [`FLUX`]) attack at once and are held at full
//!   strength from the first sample at or after `m - onset_latency` through the first sample at
//!   or after `m`, then released exponentially; a sample never misses a hop between samples.
//! - Continuous values and the spectrum are interpolated linearly between the two hops around
//!   the target, or hold the latest hop when the next one has not been pushed.
//! - The beat phase follows a reference clock, from the tracker output of the latest hop or a
//!   host-supplied [`BeatClock`], extrapolated from its tempo to the target. The output phase
//!   only moves forward, and its rate never steps: the rate slews towards the reference tempo
//!   over [`RATE_SLEW_MS`], and the phase error is closed by a correction of at most
//!   [`PHASE_CORRECTION`] of that rate, itself slewed over [`CORRECTION_SLEW_MS`], so a
//!   wavering tracker tempo bends the output's speed rather than racing and stalling it. It
//!   snaps to the reference on the first sample, after [`ReactionSampler::reset`] and when the
//!   target moves back or more than [`RESYNC_MS`] forward.
//! - The beat pulse peaks at the output wrap, the beat's photon time: a Gaussian rise of width
//!   `pulse_rise` before it and an exponential decay of `pulse_decay` after it.
//!
//! [`ReactionSampler::new`] allocates the hop queue; nothing else allocates. Only IEEE
//! arithmetic, floor and `libm::exp` are used, so every target computes the same bits.

use alloc::vec;
use alloc::vec::Vec;

use crate::dsp::{
    Beat, DSP_BEHAVIOR_V1, DSP_BEHAVIOR_V2, DSP_BEHAVIOR_V3, DSP_BEHAVIOR_V4, MAX_BEATS_PER_BAR,
};
use crate::mapping::{
    Mapped, AMPLITUDE, BASS, BASS_IMPACT, CENTROID, FLUX, LEVEL, MID, ONSET, SPECTRUM_BINS, TREBLE,
};

/// A forward move of the target larger than this, in milliseconds, resynchronises the beat
/// phase instead of slewing it (a seek or a stall).
pub const RESYNC_MS: f64 = 500.0;
/// Time, in milliseconds, over which the phase correction aims to close the phase error.
pub const PHASE_SLEW_MS: f64 = 500.0;
/// Time constant, in milliseconds, of the output rate's slew towards the reference tempo.
pub const RATE_SLEW_MS: f64 = 1000.0;
/// Largest fraction by which the phase correction may speed up or slow down the output rate.
pub const PHASE_CORRECTION: f64 = 0.15;
/// Time constant, in milliseconds, of the phase correction's slew towards its target, so the
/// output rate never steps.
pub const CORRECTION_SLEW_MS: f64 = 250.0;
/// Phase error, in beats, below which the output takes the reference phase exactly, so rounding
/// never moves a steady clock's wrap by a frame.
pub const PHASE_SNAP: f64 = 1e-9;
/// Mapped onset a hop must reach, from below on the previous hop, to count as a phase-lock
/// onset.
pub const LOCK_ONSET: f64 = 0.5;
/// Largest distance from the predicted beat, in beats, of an onset the phase lock uses.
pub const LOCK_WINDOW: f64 = 0.15;
/// Sample rate [`ANALYSIS_LATENCY`] was measured at.
pub const REFERENCE_RATE_HZ: f64 = 48_000.0;
/// Most hops a sampler queues.
pub const MAX_CAPACITY: u32 = 1 << 16;
/// [`ReactionConfig::struct_size`] of the only released layout, 96 bytes.
pub const CONFIG_SIZE: u32 = core::mem::size_of::<ReactionConfig>() as u32;
const _: () = assert!(CONFIG_SIZE == 96);

/// Transient slots, peak-held between samples.
const TRANSIENTS: [usize; 3] = [ONSET, BASS_IMPACT, FLUX];
/// Continuous slots, interpolated between hops.
const CONTINUOUS: [usize; 6] = [AMPLITUDE, LEVEL, BASS, MID, TREBLE, CENTROID];

/// Sampler configuration. Every time is in milliseconds.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReactionConfig {
    /// Size of this struct in bytes, [`CONFIG_SIZE`]: the extensible-struct rule of
    /// `ffi/include/oscillux.h`. [`Default`] sets it.
    pub struct_size: u32,
    /// Hops the queue holds, `1 ..= MAX_CAPACITY`.
    pub capacity: u32,
    /// From a sample entering the audio output to its sound leaving the speaker; `>= 0`.
    pub output_latency_ms: f64,
    /// From a frame's presentation to its light reaching the viewer; `>= 0`.
    pub display_latency_ms: f64,
    /// From the sample call's `time` to the frame's presentation; `>= 0`. 0 when the host
    /// passes the target presentation time.
    pub render_ahead_ms: f64,
    /// How much later than the audio it describes a hop's window-end media time is, for the
    /// continuous values and the beat clock; `>= 0`.
    pub analysis_latency_ms: f64,
    /// The same for transients; `>= 0`. At least the largest lag of the first hop to show an
    /// onset, so a transient is never shown after the frame that follows it.
    pub onset_latency_ms: f64,
    /// Release time constant of [`ONSET`]; `> 0`.
    pub onset_release_ms: f64,
    /// Release time constant of [`BASS_IMPACT`]; `> 0`.
    pub bass_impact_release_ms: f64,
    /// Release time constant of [`FLUX`]; `> 0`.
    pub flux_release_ms: f64,
    /// Decay time constant of the beat pulse after the beat; `> 0`.
    pub pulse_decay_ms: f64,
    /// Width of the beat pulse's Gaussian rise before the beat; `> 0`.
    pub pulse_rise_ms: f64,
    /// `[0, 1]`: how far each phase-lock onset moves the tracker phase towards itself. 0 uses
    /// the tracker phase as it is. A host beat clock is never corrected.
    pub phase_lock_gain: f64,
}

/// Measured intrinsic lateness of one DSP behaviour version on 10 ms clicks
/// (`make reaction-photon` prints the measurement).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnalysisLatency {
    /// DSP behaviour version.
    pub behavior_version: u32,
    /// [`ReactionConfig::analysis_latency_ms`].
    pub analysis_ms: f64,
    /// [`ReactionConfig::onset_latency_ms`].
    pub onset_ms: f64,
}

/// Analysis latencies of every DSP version this core runs, at the reference DSP configuration
/// (48 kHz, 2048-sample window, 512-sample hop). The lag is a number of samples, so at another
/// sample rate it scales by `48000 / rate` ([`ReactionConfig::for_dsp`]).
pub const ANALYSIS_LATENCY: [AnalysisLatency; 4] = [
    AnalysisLatency {
        behavior_version: DSP_BEHAVIOR_V1,
        analysis_ms: 10.6,
        onset_ms: 16.0,
    },
    AnalysisLatency {
        behavior_version: DSP_BEHAVIOR_V2,
        analysis_ms: 7.7,
        onset_ms: 13.3,
    },
    AnalysisLatency {
        behavior_version: DSP_BEHAVIOR_V3,
        analysis_ms: 7.7,
        onset_ms: 13.3,
    },
    AnalysisLatency {
        behavior_version: DSP_BEHAVIOR_V4,
        analysis_ms: 7.7,
        onset_ms: 13.3,
    },
];

impl ReactionConfig {
    /// The defaults with the analysis latencies of `behavior_version` from
    /// [`ANALYSIS_LATENCY`] at `sample_rate_hz` (with the default window and hop), or `None` for
    /// a version without a measured entry or a zero rate.
    pub fn for_dsp(behavior_version: u32, sample_rate_hz: u32) -> Option<Self> {
        let row = ANALYSIS_LATENCY
            .iter()
            .find(|row| row.behavior_version == behavior_version)?;
        if sample_rate_hz == 0 {
            return None;
        }
        let scale = REFERENCE_RATE_HZ / sample_rate_hz as f64;
        Some(Self {
            analysis_latency_ms: row.analysis_ms * scale,
            onset_latency_ms: row.onset_ms * scale,
            ..Self::default()
        })
    }

    /// Checks every field's range.
    pub fn validate(&self) -> Result<(), ReactionError> {
        let times = [
            self.output_latency_ms,
            self.display_latency_ms,
            self.render_ahead_ms,
            self.analysis_latency_ms,
            self.onset_latency_ms,
        ];
        let rates = [
            self.onset_release_ms,
            self.bass_impact_release_ms,
            self.flux_release_ms,
            self.pulse_decay_ms,
            self.pulse_rise_ms,
        ];
        let ok = (1..=MAX_CAPACITY).contains(&self.capacity)
            && self.struct_size == CONFIG_SIZE
            && times.iter().all(|v| v.is_finite() && *v >= 0.0)
            && rates.iter().all(|v| v.is_finite() && *v > 0.0)
            && (0.0..=1.0).contains(&self.phase_lock_gain);
        if ok {
            Ok(())
        } else {
            Err(ReactionError::InvalidConfig)
        }
    }
}

impl Default for ReactionConfig {
    /// DSP version 3's latencies, no output or display latency, 256 hops.
    fn default() -> Self {
        Self {
            struct_size: CONFIG_SIZE,
            capacity: 256,
            output_latency_ms: 0.0,
            display_latency_ms: 0.0,
            render_ahead_ms: 0.0,
            analysis_latency_ms: ANALYSIS_LATENCY[2].analysis_ms,
            onset_latency_ms: ANALYSIS_LATENCY[2].onset_ms,
            onset_release_ms: 60.0,
            bass_impact_release_ms: 150.0,
            flux_release_ms: 60.0,
            pulse_decay_ms: 1000.0 / 9.0,
            pulse_rise_ms: 30.0,
            phase_lock_gain: 0.1,
        }
    }
}

/// A host-supplied beat clock: the beat position at one media time and the tempo it runs at.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BeatClock {
    /// Media time of this position, ms; finite.
    pub media_time_ms: f64,
    /// Tempo, beats per minute; `> 0`.
    pub tempo_bpm: f64,
    /// Position within the beat, `[0, 1)`.
    pub beat_phase: f64,
    /// Position within the bar, `[0, 1)`.
    pub bar_phase: f64,
    /// Index of the current beat; [`Reaction::beat_count`] counts from it.
    pub beat_index: i64,
    /// Beats per bar, `1 ..= MAX_BEATS_PER_BAR`.
    pub beats_per_bar: u32,
    /// Always 0.
    pub reserved: u32,
}

/// Values of one display frame.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Reaction {
    /// Mapped values and spectrum at the target, as the packer reads them.
    pub mapped: Mapped,
    /// Beat pulse, `[0, 1]`; 1 at the beat's photon time.
    pub beat: f64,
    /// Beat pulse of downbeats only, `[0, 1]`.
    pub downbeat: f64,
    /// Output beat phase, `[0, 1)`; 0 at the beat.
    pub beat_phase: f64,
    /// Output bar phase, `[0, 1)`; 0 at the downbeat.
    pub bar_phase: f64,
    /// Tempo of the reference clock, beats per minute; 0 without one.
    pub tempo_bpm: f64,
    /// Tracker confidence of the latest hop, 1 with a host clock, 0 without a reference.
    pub confidence: f64,
    /// Beats counted at output wraps; a newly set host clock re-anchors it to the clock's beat
    /// index at the next sample.
    pub beat_count: i64,
    /// Index of the current beat within the bar; 0 is the downbeat.
    pub beat_in_bar: u32,
    /// 1 while a reference clock drives the beat outputs, else 0 and they are zero.
    pub locked: u32,
}

impl Reaction {
    /// All zero.
    pub const ZERO: Self = Self {
        mapped: Mapped::ZERO,
        beat: 0.0,
        downbeat: 0.0,
        beat_phase: 0.0,
        bar_phase: 0.0,
        tempo_bpm: 0.0,
        confidence: 0.0,
        beat_count: 0,
        beat_in_bar: 0,
        locked: 0,
    };
}

/// Why a call was refused; the sampler is unchanged.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReactionError {
    /// A configuration field is out of range.
    InvalidConfig,
    /// A pushed value is not finite or out of range, a hop's media time is earlier than the
    /// previous hop's, or a sample time is not finite.
    InvalidInput,
    /// The queue holds `capacity` hops not yet consumed.
    Full,
}

#[derive(Clone, Copy)]
struct Hop {
    media_ms: f64,
    mapped: Mapped,
    beat: Option<Beat>,
}

impl Hop {
    const ZERO: Hop = Hop {
        media_ms: 0.0,
        mapped: Mapped::ZERO,
        beat: None,
    };
}

/// A peak-held transient.
#[derive(Clone, Copy)]
struct Peak {
    value: f64,
    hold_until: f64,
    release_from: Option<f64>,
}

impl Peak {
    const ZERO: Peak = Peak {
        value: 0.0,
        hold_until: f64::NEG_INFINITY,
        release_from: None,
    };

    /// The held value, released from the first sample at or after `hold_until`.
    fn level(&self, t: f64, release: f64) -> f64 {
        match self.release_from {
            Some(from) if t > from => self.value * libm::exp(-(t - from) / release),
            _ => self.value,
        }
    }
}

/// The beat reference: a beat position at an origin and the rate it advances at.
#[derive(Clone, Copy)]
struct Reference {
    origin_ms: f64,
    tempo_bpm: f64,
    /// Beat position at the origin; absolute for a host clock, within `[0, 1)` for the tracker.
    beats: f64,
    /// Position within the bar at the origin, in beats, `[0, beats_per_bar)`.
    bar_beats: f64,
    beats_per_bar: u32,
    confidence: f64,
    /// Whether the pulse fires.
    active: bool,
}

impl Reference {
    fn per_ms(&self) -> f64 {
        self.tempo_bpm / 60_000.0
    }

    fn beats_at(&self, t: f64) -> f64 {
        self.beats + (t - self.origin_ms) * self.per_ms()
    }

    fn bar_at(&self, t: f64) -> f64 {
        self.bar_beats + (t - self.origin_ms) * self.per_ms()
    }
}

#[derive(Clone, Copy)]
struct Follower {
    last_t: f64,
    /// Unwrapped output beat position; its floor counts the wraps.
    beats: f64,
    /// Output rate in beats per millisecond, slewed towards the reference tempo.
    rate: f64,
    /// Fraction added to the rate to close the phase error, slewed towards its target.
    correction: f64,
    /// Bar index of the current beat.
    in_bar: u32,
    /// Whether the latest wrap fired the pulse, and whether it was a downbeat.
    pulsed: bool,
    pulsed_down: bool,
}

/// Samples mapped hops at display frames' photon times.
#[derive(Clone)]
pub struct ReactionSampler {
    config: ReactionConfig,
    queue: Vec<Hop>,
    head: usize,
    len: usize,
    /// Queue hops already consumed for transients, from `head`.
    transient_done: usize,
    /// Latest hop consumed for continuous values, and whether there is one.
    current: Hop,
    has_current: bool,
    last_pushed_ms: f64,
    peaks: [Peak; 3],
    /// Phase-lock state: onset of the previous continuous hop and the learned phase offset.
    previous_onset: f64,
    lock_offset: f64,
    tracker: Option<Reference>,
    clock: Option<BeatClock>,
    follower: Option<Follower>,
    /// The next sample snaps the follower to the reference.
    resync: bool,
    /// The next sample moves the follower's beat count to a newly set beat clock's.
    reanchor: bool,
}

fn frac(x: f64) -> f64 {
    x - libm::floor(x)
}

/// `x` wrapped to `[-0.5, 0.5)`.
fn wrap(x: f64) -> f64 {
    x - libm::floor(x + 0.5)
}

fn finite_mapped(m: &Mapped) -> bool {
    m.values.iter().all(|v| v.is_finite()) && m.spectrum.iter().all(|v| v.is_finite())
}

fn valid_beat(b: &Beat) -> bool {
    [b.tempo_bpm, b.beat_phase, b.bar_phase, b.confidence]
        .iter()
        .all(|v| v.is_finite())
        && b.tempo_bpm >= 0.0
        && (0.0..1.0).contains(&b.beat_phase)
        && (0.0..1.0).contains(&b.bar_phase)
        && b.beat_in_bar < MAX_BEATS_PER_BAR
}

/// Beats per bar implied by a tracker output, or `fallback`.
fn beats_per_bar(b: &Beat, fallback: u32) -> u32 {
    if b.bar_phase > 0.0 {
        let n = libm::floor((b.beat_in_bar as f64 + b.beat_phase) / b.bar_phase + 0.5);
        if n >= 1.0 && n <= MAX_BEATS_PER_BAR as f64 && (b.beat_in_bar as f64) < n {
            return n as u32;
        }
    }
    fallback.max(b.beat_in_bar + 1)
}

impl ReactionSampler {
    /// Validates `config` and allocates the hop queue.
    pub fn new(config: ReactionConfig) -> Result<Self, ReactionError> {
        config.validate()?;
        Ok(Self {
            queue: vec![Hop::ZERO; config.capacity as usize],
            config,
            head: 0,
            len: 0,
            transient_done: 0,
            current: Hop::ZERO,
            has_current: false,
            last_pushed_ms: f64::NEG_INFINITY,
            peaks: [Peak::ZERO; 3],
            previous_onset: 0.0,
            lock_offset: 0.0,
            tracker: None,
            clock: None,
            follower: None,
            resync: true,
            reanchor: false,
        })
    }

    /// The configuration this sampler runs.
    pub fn config(&self) -> &ReactionConfig {
        &self.config
    }

    /// Hops queued and not yet consumed by both value kinds.
    pub fn queued(&self) -> usize {
        self.len
    }

    /// Forgets every hop, peak, the beat clock and the beat state; keeps the configuration.
    pub fn reset(&mut self) {
        self.head = 0;
        self.len = 0;
        self.transient_done = 0;
        self.current = Hop::ZERO;
        self.has_current = false;
        self.last_pushed_ms = f64::NEG_INFINITY;
        self.peaks = [Peak::ZERO; 3];
        self.previous_onset = 0.0;
        self.lock_offset = 0.0;
        self.tracker = None;
        self.clock = None;
        self.follower = None;
        self.resync = true;
        self.reanchor = false;
    }

    /// Queues one mapped hop whose analysis window ends at `media_time_ms`, with the tracker
    /// output beside it, if any. Media times must not decrease.
    pub fn push(
        &mut self,
        media_time_ms: f64,
        mapped: &Mapped,
        beat: Option<&Beat>,
    ) -> Result<(), ReactionError> {
        if !media_time_ms.is_finite()
            || media_time_ms < self.last_pushed_ms
            || !finite_mapped(mapped)
            || beat.is_some_and(|b| !valid_beat(b))
        {
            return Err(ReactionError::InvalidInput);
        }
        if self.len == self.queue.len() {
            return Err(ReactionError::Full);
        }
        let at = (self.head + self.len) % self.queue.len();
        self.queue[at] = Hop {
            media_ms: media_time_ms,
            mapped: *mapped,
            beat: beat.copied(),
        };
        self.len += 1;
        self.last_pushed_ms = media_time_ms;
        Ok(())
    }

    /// Drives the beat outputs from `clock` instead of the tracker; `None` returns to the
    /// tracker. The next sample takes a new clock's tempo and beat count; its phase is followed
    /// by slewing, as a tracker update is.
    pub fn set_beat_clock(&mut self, clock: Option<&BeatClock>) -> Result<(), ReactionError> {
        if let Some(c) = clock {
            let ok = [c.media_time_ms, c.tempo_bpm, c.beat_phase, c.bar_phase]
                .iter()
                .all(|v| v.is_finite())
                && c.tempo_bpm > 0.0
                && (0.0..1.0).contains(&c.beat_phase)
                && (0.0..1.0).contains(&c.bar_phase)
                && (1..=MAX_BEATS_PER_BAR).contains(&c.beats_per_bar)
                && c.reserved == 0;
            if !ok {
                return Err(ReactionError::InvalidInput);
            }
        }
        self.clock = clock.copied();
        self.reanchor = clock.is_some();
        Ok(())
    }

    /// The media time a sample at host time `time_ms` targets.
    pub fn target(&self, time_ms: f64) -> f64 {
        let c = &self.config;
        time_ms + c.render_ahead_ms + c.display_latency_ms - c.output_latency_ms
    }

    /// Samples the values seen at the photon time of a frame sampled at host media time
    /// `time_ms`, consuming every hop due by then.
    pub fn sample(&mut self, time_ms: f64) -> Result<Reaction, ReactionError> {
        if !time_ms.is_finite() {
            return Err(ReactionError::InvalidInput);
        }
        let t = self.target(time_ms);
        self.consume_transients(t);
        self.consume_continuous(t);
        let mut out = Reaction::ZERO;
        self.sample_values(t, &mut out.mapped);
        self.sample_beat(t, &mut out);
        Ok(out)
    }

    fn hop(&self, i: usize) -> &Hop {
        &self.queue[(self.head + i) % self.queue.len()]
    }

    fn releases(&self) -> [f64; 3] {
        let c = &self.config;
        [
            c.onset_release_ms,
            c.bass_impact_release_ms,
            c.flux_release_ms,
        ]
    }

    fn consume_transients(&mut self, t: f64) {
        let lead = self.config.onset_latency_ms;
        while self.transient_done < self.len {
            let hop = *self.hop(self.transient_done);
            if hop.media_ms - lead > t {
                break;
            }
            self.consume_one_transient(&hop, t);
            self.transient_done += 1;
        }
    }

    fn consume_continuous(&mut self, t: f64) {
        let lag = self.config.analysis_latency_ms;
        while self.len > 0 {
            let hop = *self.hop(0);
            if hop.media_ms - lag > t {
                break;
            }
            if self.transient_done == 0 {
                // Transients are always consumed first unless onset_latency < analysis_latency;
                // keep the queue order by consuming them now.
                self.consume_one_transient(&hop, t);
            } else {
                self.transient_done -= 1;
            }
            self.head = (self.head + 1) % self.queue.len();
            self.len -= 1;
            self.accept(&hop);
        }
    }

    fn consume_one_transient(&mut self, hop: &Hop, t: f64) {
        let releases = self.releases();
        for (k, &slot) in TRANSIENTS.iter().enumerate() {
            let v = hop.mapped.values[slot];
            if v >= self.peaks[k].level(t, releases[k]) {
                self.peaks[k] = Peak {
                    value: v,
                    hold_until: hop.media_ms,
                    release_from: None,
                };
            }
        }
    }

    /// Takes a hop as the current one: updates the tracker reference and the phase lock.
    fn accept(&mut self, hop: &Hop) {
        let event = hop.media_ms - self.config.analysis_latency_ms;
        if let Some(b) = hop.beat {
            if b.tempo_bpm > 0.0 {
                let fallback = self.tracker.map_or(4, |r| r.beats_per_bar);
                let bpb = beats_per_bar(&b, fallback);
                if let Some(old) = self.tracker {
                    if libm::fabs(b.tempo_bpm - old.tempo_bpm) > 0.06 * old.tempo_bpm {
                        self.lock_offset = 0.0;
                    }
                }
                self.tracker = Some(Reference {
                    origin_ms: event,
                    tempo_bpm: b.tempo_bpm,
                    beats: b.beat_phase,
                    bar_beats: b.beat_in_bar as f64 + b.beat_phase,
                    beats_per_bar: bpb,
                    confidence: b.confidence,
                    active: b.confidence > 0.0,
                });
            } else {
                self.tracker = None;
                self.lock_offset = 0.0;
            }
        }
        let onset = hop.mapped.values[ONSET];
        if let Some(r) = self.tracker {
            let gain = self.config.phase_lock_gain;
            if gain > 0.0 && r.active && onset >= LOCK_ONSET && self.previous_onset < LOCK_ONSET {
                let err = wrap(r.beats_at(event) + self.lock_offset);
                if libm::fabs(err) < LOCK_WINDOW {
                    self.lock_offset = wrap(self.lock_offset - gain * err);
                }
            }
        }
        self.previous_onset = onset;
        self.current = *hop;
        self.has_current = true;
    }

    fn sample_values(&mut self, t: f64, out: &mut Mapped) {
        if self.has_current {
            let a = &self.current;
            let lag = self.config.analysis_latency_ms;
            let next = (self.len > 0).then(|| *self.hop(0));
            match next {
                Some(b) if b.media_ms > a.media_ms => {
                    let w = (t - (a.media_ms - lag)) / (b.media_ms - a.media_ms);
                    let w = w.clamp(0.0, 1.0);
                    for &slot in &CONTINUOUS {
                        let (x, y) = (a.mapped.values[slot], b.mapped.values[slot]);
                        out.values[slot] = x + (y - x) * w;
                    }
                    for i in 0..SPECTRUM_BINS {
                        let (x, y) = (a.mapped.spectrum[i] as f64, b.mapped.spectrum[i] as f64);
                        out.spectrum[i] = (x + (y - x) * w) as f32;
                    }
                }
                _ => {
                    for &slot in &CONTINUOUS {
                        out.values[slot] = a.mapped.values[slot];
                    }
                    out.spectrum = a.mapped.spectrum;
                }
            }
        }
        let releases = self.releases();
        for (k, &slot) in TRANSIENTS.iter().enumerate() {
            let peak = &mut self.peaks[k];
            if peak.release_from.is_none() && t >= peak.hold_until {
                peak.release_from = Some(t);
            }
            out.values[slot] = peak.level(t, releases[k]);
        }
    }

    fn reference(&self) -> Option<Reference> {
        if let Some(c) = &self.clock {
            let bpb = c.beats_per_bar;
            return Some(Reference {
                origin_ms: c.media_time_ms,
                tempo_bpm: c.tempo_bpm,
                beats: c.beat_index as f64 + c.beat_phase,
                bar_beats: c.bar_phase * bpb as f64,
                beats_per_bar: bpb,
                confidence: 1.0,
                active: true,
            });
        }
        self.tracker.map(|mut r| {
            r.beats += self.lock_offset;
            r.bar_beats += self.lock_offset;
            r
        })
    }

    fn sample_beat(&mut self, t: f64, out: &mut Reaction) {
        let Some(r) = self.reference() else {
            self.resync = true;
            return;
        };
        let absolute = self.clock.is_some();
        let bpb = r.beats_per_bar;
        let bar_index = |bar_beats: f64, phase: f64| -> u32 {
            let n = libm::floor(bar_beats - phase + 0.5);
            let n = n - libm::floor(n / bpb as f64) * bpb as f64;
            (n as u32).min(bpb - 1)
        };
        let resync = match &self.follower {
            None => true,
            Some(f) => self.resync || t < f.last_t || t - f.last_t > RESYNC_MS,
        };
        self.resync = false;
        let reanchor = core::mem::take(&mut self.reanchor);
        let mut f = if resync {
            let target = r.beats_at(t);
            let beats = if absolute {
                target
            } else {
                let count = self.follower.map_or(0.0, |f| libm::floor(f.beats));
                count + frac(target)
            };
            Follower {
                last_t: t,
                beats,
                rate: r.per_ms(),
                correction: 0.0,
                in_bar: bar_index(r.bar_at(t), frac(beats)),
                pulsed: false,
                pulsed_down: false,
            }
        } else {
            let Some(mut f) = self.follower else {
                return;
            };
            let dt = t - f.last_t;
            let reference = r.beats_at(t);
            if reanchor && absolute {
                // A host clock is authoritative: take its tempo and beat count at once. The
                // phase still slews.
                f.rate = r.per_ms();
                f.beats += libm::floor(reference - (f.beats + dt * f.rate) + 0.5);
            }
            f.rate += (r.per_ms() - f.rate) * (1.0 - libm::exp(-dt / RATE_SLEW_MS));
            let err = wrap(reference - (f.beats + dt * f.rate));
            let target = if f.rate > 0.0 {
                err / (PHASE_SLEW_MS * f.rate)
            } else {
                0.0
            };
            // Explicit bounds rather than `f64::clamp`, whose bound-check panic
            // links float formatting into the wasm build.
            #[allow(clippy::manual_clamp)]
            let target = if target < -PHASE_CORRECTION {
                -PHASE_CORRECTION
            } else if target > PHASE_CORRECTION {
                PHASE_CORRECTION
            } else {
                target
            };
            f.correction += (target - f.correction) * (1.0 - libm::exp(-dt / CORRECTION_SLEW_MS));
            let next = f.beats + dt * f.rate * (1.0 + f.correction);
            let snapped = reference + libm::floor(next - reference + 0.5);
            let next = if libm::fabs(next - snapped) < PHASE_SNAP && snapped >= f.beats {
                snapped
            } else {
                next
            };
            let before = libm::floor(f.beats);
            f.beats = next;
            if libm::floor(f.beats) > before {
                f.in_bar = bar_index(r.bar_at(t), frac(f.beats));
                f.pulsed = r.active;
                f.pulsed_down = r.active && f.in_bar == 0;
            }
            f.last_t = t;
            f
        };
        if f.in_bar >= bpb {
            f.in_bar %= bpb;
        }
        self.follower = Some(f);

        let phase = frac(f.beats);
        let per_ms = f.rate * (1.0 + f.correction);
        let after = phase / per_ms;
        let before = (1.0 - phase) / per_ms;
        let decay = libm::exp(-after / self.config.pulse_decay_ms);
        let x = before / self.config.pulse_rise_ms;
        let rise = libm::exp(-(x * x));
        let next_down = (f.in_bar + 1) % bpb == 0;
        let fired = if f.pulsed { decay } else { 0.0 };
        let fired_down = if f.pulsed_down { decay } else { 0.0 };
        let coming = if r.active { rise } else { 0.0 };
        let coming_down = if r.active && next_down { rise } else { 0.0 };
        out.beat = fired.max(coming);
        out.downbeat = fired_down.max(coming_down);
        out.beat_phase = phase;
        out.bar_phase = (f.in_bar as f64 + phase) / bpb as f64;
        out.tempo_bpm = r.tempo_bpm;
        out.confidence = r.confidence;
        out.beat_count = libm::floor(f.beats) as i64;
        out.beat_in_bar = f.in_bar;
        out.locked = 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mapped(slot: usize, v: f64) -> Mapped {
        let mut m = Mapped::ZERO;
        m.values[slot] = v;
        m
    }

    fn sampler(config: ReactionConfig) -> ReactionSampler {
        ReactionSampler::new(config).unwrap()
    }

    fn plain() -> ReactionConfig {
        ReactionConfig {
            analysis_latency_ms: 0.0,
            onset_latency_ms: 0.0,
            ..ReactionConfig::default()
        }
    }

    fn clock(bpm: f64) -> BeatClock {
        BeatClock {
            media_time_ms: 0.0,
            tempo_bpm: bpm,
            beat_phase: 0.0,
            bar_phase: 0.0,
            beat_index: 0,
            beats_per_bar: 4,
            reserved: 0,
        }
    }

    #[test]
    fn config_table_and_validation() {
        assert_eq!(ReactionConfig::default().validate(), Ok(()));
        let v1 = ReactionConfig::for_dsp(DSP_BEHAVIOR_V1, 48_000).unwrap();
        assert_eq!(v1.analysis_latency_ms, ANALYSIS_LATENCY[0].analysis_ms);
        let at_24k = ReactionConfig::for_dsp(DSP_BEHAVIOR_V3, 24_000).unwrap();
        assert_eq!(at_24k.onset_latency_ms, 2.0 * ANALYSIS_LATENCY[2].onset_ms);
        assert_eq!(ReactionConfig::for_dsp(99, 48_000), None);
        assert_eq!(ReactionConfig::for_dsp(DSP_BEHAVIOR_V3, 0), None);
        let bad = [
            ReactionConfig {
                capacity: 0,
                ..plain()
            },
            ReactionConfig {
                capacity: MAX_CAPACITY + 1,
                ..plain()
            },
            ReactionConfig {
                struct_size: CONFIG_SIZE - 8,
                ..plain()
            },
            ReactionConfig {
                output_latency_ms: -1.0,
                ..plain()
            },
            ReactionConfig {
                render_ahead_ms: f64::NAN,
                ..plain()
            },
            ReactionConfig {
                onset_release_ms: 0.0,
                ..plain()
            },
            ReactionConfig {
                pulse_rise_ms: f64::INFINITY,
                ..plain()
            },
            ReactionConfig {
                phase_lock_gain: 1.5,
                ..plain()
            },
        ];
        for c in bad {
            assert_eq!(
                ReactionSampler::new(c).err(),
                Some(ReactionError::InvalidConfig)
            );
        }
    }

    #[test]
    fn push_refuses_bad_input_and_a_full_queue() {
        let mut s = sampler(ReactionConfig {
            capacity: 2,
            ..plain()
        });
        assert_eq!(
            s.push(f64::NAN, &Mapped::ZERO, None),
            Err(ReactionError::InvalidInput)
        );
        assert_eq!(
            s.push(0.0, &mapped(LEVEL, f64::NAN), None),
            Err(ReactionError::InvalidInput)
        );
        let beat = Beat {
            beat_phase: 1.0,
            ..Beat::ZERO
        };
        assert_eq!(
            s.push(0.0, &Mapped::ZERO, Some(&beat)),
            Err(ReactionError::InvalidInput)
        );
        s.push(10.0, &Mapped::ZERO, None).unwrap();
        assert_eq!(
            s.push(9.0, &Mapped::ZERO, None),
            Err(ReactionError::InvalidInput)
        );
        s.push(20.0, &Mapped::ZERO, None).unwrap();
        assert_eq!(s.push(30.0, &Mapped::ZERO, None), Err(ReactionError::Full));
        assert_eq!(s.queued(), 2);
        assert_eq!(s.sample(f64::NAN), Err(ReactionError::InvalidInput));
        s.sample(25.0).unwrap();
        assert_eq!(s.queued(), 0);
        s.push(30.0, &Mapped::ZERO, None).unwrap();
        let mut c = clock(120.0);
        c.beats_per_bar = 0;
        assert_eq!(s.set_beat_clock(Some(&c)), Err(ReactionError::InvalidInput));
    }

    #[test]
    fn a_transient_between_frames_is_held_for_the_next_frame() {
        let mut s = sampler(plain());
        assert_eq!(s.sample(0.0).unwrap().mapped.values[ONSET], 0.0);
        // A one-hop spike well between two 30 Hz frames, followed by silence.
        s.push(10.0, &mapped(ONSET, 0.9), None).unwrap();
        s.push(20.0, &Mapped::ZERO, None).unwrap();
        s.push(30.0, &Mapped::ZERO, None).unwrap();
        let r = s.sample(33.3).unwrap();
        assert_eq!(r.mapped.values[ONSET], 0.9);
        // Released from that frame on.
        let later = s.sample(66.6).unwrap().mapped.values[ONSET];
        let want = 0.9 * libm::exp(-(66.6 - 33.3) / plain().onset_release_ms);
        assert!((later - want).abs() < 1e-12);
        // A larger hop replaces the held peak; a smaller one does not.
        s.push(70.0, &mapped(ONSET, 0.3), None).unwrap();
        assert!(s.sample(70.0).unwrap().mapped.values[ONSET] >= 0.3);
    }

    #[test]
    fn continuous_values_interpolate_between_hops() {
        let mut s = sampler(ReactionConfig {
            analysis_latency_ms: 5.0,
            ..plain()
        });
        s.push(10.0, &mapped(LEVEL, 0.2), None).unwrap();
        s.push(20.0, &mapped(LEVEL, 0.6), None).unwrap();
        // Hop 10 describes media 5, hop 20 media 15: at 10 the value is half way.
        let r = s.sample(10.0).unwrap();
        assert!((r.mapped.values[LEVEL] - 0.4).abs() < 1e-12);
        // Holds the latest hop without a next one.
        assert_eq!(s.sample(40.0).unwrap().mapped.values[LEVEL], 0.6);
    }

    #[test]
    fn clock_phase_moves_forward_and_peaks_at_the_beat() {
        let mut s = sampler(plain());
        s.set_beat_clock(Some(&clock(120.0))).unwrap();
        let mut previous = s.sample(0.0).unwrap();
        assert_eq!(
            (previous.beat_phase, previous.beat_count, previous.locked),
            (0.0, 0, 1)
        );
        let mut wraps = 0;
        for k in 1..=600 {
            let r = s.sample(k as f64 * 1000.0 / 60.0).unwrap();
            if r.beat_phase < previous.beat_phase {
                wraps += 1;
                assert_eq!(r.beat_count, previous.beat_count + 1);
            } else {
                assert!(r.beat_phase > previous.beat_phase);
            }
            previous = r;
        }
        // 10 s at 120 BPM.
        assert_eq!((wraps, previous.beat_count), (20, 20));
        assert!((previous.beat - 1.0).abs() < 1e-9 && previous.beat_phase.abs() < 1e-9);
        assert!(
            (previous.downbeat - 1.0).abs() < 1e-9,
            "beat 20 is a downbeat"
        );
    }

    #[test]
    fn a_replaced_clock_reanchors_the_count_and_it_then_only_counts_up() {
        let mut s = sampler(plain());
        s.set_beat_clock(Some(&clock(120.0))).unwrap();
        let frame = 1000.0 / 60.0;
        let mut previous = s.sample(0.0).unwrap();
        for k in 1..=120 {
            previous = s.sample(k as f64 * frame).unwrap();
        }
        assert_eq!(previous.beat_count, 4);
        // Same origin at half the tempo: the clock is at beat 2.
        s.set_beat_clock(Some(&clock(60.0))).unwrap();
        previous = s.sample(121.0 * frame).unwrap();
        assert_eq!(previous.beat_count, 2);
        for k in 122..=600 {
            let r = s.sample(k as f64 * frame).unwrap();
            assert!(r.beat_count == previous.beat_count || r.beat_count == previous.beat_count + 1);
            assert!(r.beat_phase > previous.beat_phase || r.beat_count == previous.beat_count + 1);
            previous = r;
        }
        assert_eq!(previous.beat_count, 10);
    }

    #[test]
    fn a_seek_resynchronises_and_reset_forgets() {
        let mut s = sampler(plain());
        s.set_beat_clock(Some(&clock(60.0))).unwrap();
        s.sample(0.0).unwrap();
        s.sample(10.0).unwrap();
        let r = s.sample(5_250.0).unwrap();
        assert_eq!(r.beat_count, 5);
        assert!((r.beat_phase - 0.25).abs() < 1e-12);
        let back = s.sample(1_500.0).unwrap();
        assert_eq!(back.beat_count, 1);
        assert!((back.beat_phase - 0.5).abs() < 1e-12);
        s.push(1_600.0, &mapped(ONSET, 1.0), None).unwrap();
        s.reset();
        assert_eq!(s.queued(), 0);
        assert_eq!(s.sample(2_000.0).unwrap(), Reaction::ZERO);
    }

    #[test]
    fn the_tracker_drives_the_beat_without_a_clock() {
        let mut s = sampler(ReactionConfig {
            phase_lock_gain: 0.0,
            ..plain()
        });
        let beat = |phase: f64| Beat {
            tempo_bpm: 120.0,
            beat_phase: phase,
            bar_phase: phase / 4.0,
            confidence: 0.8,
            ..Beat::ZERO
        };
        let mut previous: Option<Reaction> = None;
        for k in 0..200 {
            let media = k as f64 * 10.0;
            s.push(media, &Mapped::ZERO, Some(&beat((media / 500.0) % 1.0)))
                .unwrap();
            let r = s.sample(media).unwrap();
            assert_eq!((r.locked, r.tempo_bpm, r.confidence), (1, 120.0, 0.8));
            if let Some(p) = previous {
                assert!(r.beat_phase > p.beat_phase || r.beat_count == p.beat_count + 1);
            }
            previous = Some(r);
        }
        assert_eq!(previous.unwrap().beat_count, 3);
        // Tempo 0 drops the reference.
        s.push(2_000.0, &Mapped::ZERO, Some(&Beat::ZERO)).unwrap();
        assert_eq!(s.sample(2_000.0).unwrap().locked, 0);
    }
}
