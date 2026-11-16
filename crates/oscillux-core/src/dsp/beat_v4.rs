// SPDX-License-Identifier: AGPL-3.0-only
//! Version 4 beat tracker: a causal beat-pointer hidden Markov model over integer beat periods,
//! with a bar-position stage for downbeats (`conformance/dsp/music/README.md`, "Beat tracker,
//! version 4"). `tools/dsp-beat-v4-vectors.py` is its independent oracle.
//!
//! The state is a (period, phase) pair: period `q` frames, one per integer from
//! `floor(fr · 60 / max_bpm)` to `ceil(fr · 60 / min_bpm)`, and phase `k` in `0..q`, meaning
//! "the onset envelope peaks at frames `t ≡ k (mod q)`". Per frame `t`:
//!
//! 1. The onset envelope `o = 2·low + mid + high` (each onset clamped to `[0, 1]`) is compared
//!    with three times its two-second running mean: `x = o / (3·mean + 0.001)`.
//! 2. Every state whose beat falls within `floor(0.04·q)` frames of `t` is multiplied by
//!    `1 + (r - 1)·w`, where `r = (0.5 + x) / 1.5` and `w` is a triangle that is 1 on the beat.
//! 3. The states whose beat is now (`k = t mod q`) move on: their mass, times a log-Gaussian
//!    tempo prior around 100 BPM (σ = 0.6 in log period, applied per second rather than per
//!    beat so it presses alike on every tempo), goes 99% to periods within three frames,
//!    weighted `exp(-100·|q'/q - 1|)`, and 1% spread evenly over every period within a factor
//!    of `exp(0.3)`, which lets the tracker re-acquire a new tempo within a beat or two. Mass
//!    leaving a period the octave cue penalises is first multiplied by 0.05.
//! 4. The distribution is normalised and mixed with `10⁻⁶` of the uniform one.
//! 5. The most probable state gives the beat. The envelope lags the window end by 1.5 frames,
//!    so a beat is emitted on the frame nearest the compensated beat instant (up to 2.5 frames
//!    late after a phase jump), at least half a period after the previous one, while an
//!    envelope value of at least 0.1 came within the last four beat periods. Phases are reported
//!    at the frame's media time.
//! 6. The tempo is the probability-weighted mean period of the five periods around the best.
//!
//! The octave cue settles between the best period and its half or double, which the prior and
//! the beat-only observation alone confuse on fast backbeat music and on off-beat hats. While
//! there was activity within the last period, it keeps decaying sums (factor 0.95 per sample)
//! of the four-frame peaks of the low onset and of the mid-plus-high onset at the best state's
//! beats and mid-beats over a two-beat cycle (each sampled once, at least half a period after
//! the last), remapped when the best period halves or doubles and cleared on any other change
//! beyond 1.3 times; once no activity came within the last period it is cleared, penalty
//! included, so a pause or a silent gap between songs leaves the next one to decide afresh (a
//! gapless change keeps it). After eight samples, mid-beats with snare or hat onsets (more than
//! 0.55 of the beats') but little kick (less than 0.4) penalise every period from three quarters
//! of the best on; the same pattern on every other beat penalises every period from 1.5 times
//! the best on.
//!
//! The downbeat stage keeps per bar position a bias-corrected decaying mean (factor 0.95 per
//! bar) of four features of each beat: the low-group level over the beat interval, the low
//! onset around the beat, the spectral change from the previous interval and the bass flux at
//! the interval start (spectrum values are read as given, non-finite or negative as 0).
//! Spectrum features are read `round(bass delay / hop)` frames late, so that they line up with
//! the delayed bass bands of version 2. Each feature is divided by its mean over the bar
//! positions; the position with the largest weighted sum is the downbeat, unless the position
//! chosen last time scores within a factor 1.1 of it. After four beats whose period is outside
//! three quarters to four thirds of the last period inside that range, the means restart.
//!
//! Creation evaluates `exp` and `ln` with the fixed-iteration series of [`exp_series`] and
//! [`ln_series`], so the model is identical on every target; the per-frame path uses only IEEE
//! double addition, subtraction, multiplication, division, absolute value and comparisons, and
//! does not allocate.

use alloc::vec;
use alloc::vec::Vec;

use super::beat::{Beat, BeatConfig, MAX_BEATS_PER_BAR};
use super::config::{DspSettings, MAX_BANDS};
use super::v2::V2;
use super::{DspError, DspFrame, FLAG_GAP, FLAG_STALLED};

/// Shortest period, frames.
const MIN_PERIOD_FRAMES: f64 = 8.0;
/// Longest period, frames: bounds the state count (the sum of all periods).
pub(crate) const MAX_PERIOD_FRAMES: f64 = 512.0;
/// Weight of the low onset in the envelope (mid and high weigh 1).
const LOW_WEIGHT: f64 = 2.0;
/// Envelope running-mean time constant, seconds.
const MEAN_TAU_S: f64 = 2.0;
/// The envelope is read relative to this multiple of its running mean...
const MEAN_RATIO: f64 = 3.0;
/// ...plus this floor.
const MEAN_FLOOR: f64 = 1e-3;
/// Likelihood ratio offset: `r = (BETA + x) / (BETA + 1)`.
const BETA: f64 = 0.5;
/// Observation half-width, as a fraction of the period.
const WINDOW: f64 = 0.04;
/// Period transition sharpness.
const LAMBDA: f64 = 100.0;
/// Period transitions reach this many periods either side.
const MAX_STEP: usize = 3;
/// Transition row width.
const STEPS: usize = 2 * MAX_STEP + 1;
/// Share of the uniform distribution mixed in every frame.
const MIX: f64 = 1e-6;
/// Share of a beat's mass that jumps to any period within [`JUMP_RANGE`].
const JUMP: f64 = 0.01;
/// Jump reach, natural-log period.
const JUMP_RANGE: f64 = 0.3;
/// Frames the envelope lags the media time of the window end.
const DELAY_FRAMES: f64 = 1.5;
/// A beat may be emitted up to this many frames after its instant.
const SLACK_FRAMES: f64 = 2.5;
/// Beat periods between emitted beats, at least.
const BEAT_GATE: f64 = 0.5;
/// An envelope value at least this large counts as activity.
const ACTIVE: f64 = 0.1;
/// Beats are emitted until this many periods after the last activity.
const HOLD_BEATS: u64 = 4;
/// Periods either side of the best that the tempo and confidence average over.
const SPAN: usize = 2;
/// Phases either side of the best that the confidence sums.
const PHASE_SPAN: usize = 2;

/// Tempo prior centre, BPM...
const PRIOR_BPM: f64 = 100.0;
/// ...width in natural-log period...
const PRIOR_SIGMA: f64 = 0.6;
/// ...and strength per second.
const PRIOR_GAIN: f64 = 2.0;
/// Octave cue: decay of the half-beat peak sums per sample...
const OCT_DECAY: f64 = 0.95;
/// ...high-band share the off position needs, at least...
const OCT_HIGH: f64 = 0.55;
/// ...low-band share it may have, at most...
const OCT_LOW: f64 = 0.4;
/// ...mass factor per beat of the penalised periods...
const OCT_PENALTY: f64 = 0.05;
/// ...and samples before the cue acts.
const OCT_WARM: f64 = 8.0;

/// Downbeat feature decay per bar.
const BAR_DECAY: f64 = 0.95;
/// Beats at another metrical level before the bar statistics restart.
const BAR_RESET: u32 = 4;
/// Score factor a new downbeat position must beat the held one by.
const BAR_HYST: f64 = 1.1;
/// Initial weight of every downbeat feature mean (keeps empty means at 0).
const BAR_EPSILON: f64 = 1e-9;
/// Downbeat feature weights: interval level, low onset, spectral change, bass flux.
const FEATURE_WEIGHTS: [f64; FEATURES] = [1.0, 0.5, 0.25, 0.5];
const FEATURES: usize = 4;
/// Frames of the low-onset window from the frame before a beat.
const ONSET_SPAN: u32 = 3;
/// Leading low-group bands of the bass flux.
const BASS_FLUX_BANDS: usize = 3;
/// Frames of an interval whose bass flux counts.
const BASS_FLUX_SPAN: f64 = 3.0;
const BPB: usize = MAX_BEATS_PER_BAR as usize;

/// Version 4 constants chosen on development data (annotated recordings that are not
/// distributed with this repository), replaceable for parameter searches (not a stable API).
#[doc(hidden)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct V4Tuning {
    /// Tempo prior centre, BPM...
    pub prior_bpm: f64,
    /// ...width in natural-log period...
    pub prior_sigma: f64,
    /// ...and strength per second, at least 0.
    pub prior_gain: f64,
    /// Octave cue: decay of the half-beat peak sums per sample, 0 to 1...
    pub oct_decay: f64,
    /// ...high-band share the off position needs, at least...
    pub oct_high: f64,
    /// ...low-band share it may have, at most...
    pub oct_low: f64,
    /// ...mass factor per beat of the penalised periods, 0 to 1 (1 turns the cue off)...
    pub oct_pen: f64,
    /// ...and samples before the cue acts.
    pub oct_warm: f64,
    /// Downbeat feature decay per bar, 0 to 1.
    pub bar_decay: f64,
    /// Downbeat feature weights.
    pub weights: [f64; FEATURES],
    /// Beats at another metrical level before the bar statistics restart (0 is never).
    pub bar_reset: u32,
    /// Score factor a new downbeat position must beat the held one by (1 is none).
    pub bar_hyst: f64,
}

impl Default for V4Tuning {
    fn default() -> Self {
        V4Tuning {
            prior_bpm: PRIOR_BPM,
            prior_sigma: PRIOR_SIGMA,
            prior_gain: PRIOR_GAIN,
            oct_decay: OCT_DECAY,
            oct_high: OCT_HIGH,
            oct_low: OCT_LOW,
            oct_pen: OCT_PENALTY,
            oct_warm: OCT_WARM,
            bar_decay: BAR_DECAY,
            weights: FEATURE_WEIGHTS,
            bar_reset: BAR_RESET,
            bar_hyst: BAR_HYST,
        }
    }
}

/// Finite positive inputs pass; anything else reads as 0.
fn clean(v: f64) -> f64 {
    if v.is_finite() && v > 0.0 {
        v
    } else {
        0.0
    }
}

/// Finite inputs clamp to `[0, 1]`; anything else reads as 0.
fn unit(v: f64) -> f64 {
    if v.is_finite() && v > 0.0 {
        if v < 1.0 {
            v
        } else {
            1.0
        }
    } else {
        0.0
    }
}

/// `e^y`: halve `y` below 0.5 in magnitude, sum the Taylor series to degree 20 by Horner's
/// rule, square back. Creation only.
pub(crate) fn exp_series(y: f64) -> f64 {
    let (mut y, mut halvings) = (y, 0);
    while y.abs() >= 0.5 {
        y *= 0.5;
        halvings += 1;
    }
    let mut s = 1.0;
    for n in (1..=20).rev() {
        s = 1.0 + y * s / n as f64;
    }
    for _ in 0..halvings {
        s *= s;
    }
    s
}

/// `ln x` for finite `x > 0`: scale by 2 into `(√½, √2]`, then `2·atanh((m-1)/(m+1))` to
/// degree 25. Creation only.
pub(crate) fn ln_series(x: f64) -> f64 {
    let (mut m, mut e) = (x, 0i32);
    while m >= 2.0 {
        m *= 0.5;
        e += 1;
    }
    while m < 1.0 {
        m *= 2.0;
        e -= 1;
    }
    if m > core::f64::consts::SQRT_2 {
        m *= 0.5;
        e += 1;
    }
    let s = (m - 1.0) / (m + 1.0);
    let s2 = s * s;
    let mut sum = 0.0;
    for n in (0..=12).rev() {
        sum = 1.0 / (2 * n + 1) as f64 + s2 * sum;
    }
    2.0 * s * sum + e as f64 * core::f64::consts::LN_2
}

/// Bar-position statistics for downbeats; see the module documentation.
#[derive(Clone, Debug)]
struct Downbeat {
    bpb: usize,
    decay: f64,
    weights: [f64; FEATURES],
    /// Frames the spectrum features are read late.
    lag: u64,
    low_first: usize,
    low_count: usize,
    bass_bands: usize,
    bands: usize,
    /// Bar position of the next beat.
    slot: usize,
    /// Bar position of the next lagged beat, and whether one has closed an interval yet.
    closed: usize,
    closed_any: bool,
    sum: [[f64; FEATURES]; BPB],
    weight: [[f64; FEATURES]; BPB],
    level: f64,
    frames: f64,
    spec: [f64; MAX_BANDS],
    prev_spec: [f64; MAX_BANDS],
    have_prev: bool,
    bass: f64,
    last_flux: f64,
    prev_bands: [f64; BASS_FLUX_BANDS],
    onset: f64,
    onset_frames: u32,
    prev_onset: f64,
    have_onset: bool,
    /// Beat flags of the last `lag + 1` frames.
    beats: Vec<bool>,
    t: u64,
    reset_after: u32,
    hyst: f64,
    /// Period of the metrical level the statistics belong to, and beats since at another.
    ref_q: usize,
    off_level: u32,
    /// Bar position chosen as the downbeat at the last beat.
    chosen: usize,
}

impl Downbeat {
    fn new(
        tuning: &V4Tuning,
        bpb: usize,
        lag: u64,
        low_first: usize,
        low_count: usize,
        bands: usize,
    ) -> Downbeat {
        Downbeat {
            bpb,
            decay: tuning.bar_decay,
            weights: tuning.weights,
            lag,
            low_first,
            low_count,
            bass_bands: low_count.min(BASS_FLUX_BANDS),
            bands,
            slot: 0,
            closed: 0,
            closed_any: false,
            sum: [[0.0; FEATURES]; BPB],
            weight: [[BAR_EPSILON; FEATURES]; BPB],
            level: 0.0,
            frames: 0.0,
            spec: [0.0; MAX_BANDS],
            prev_spec: [0.0; MAX_BANDS],
            have_prev: false,
            bass: 0.0,
            last_flux: 0.0,
            prev_bands: [0.0; BASS_FLUX_BANDS],
            onset: 0.0,
            onset_frames: ONSET_SPAN,
            prev_onset: 0.0,
            have_onset: false,
            beats: vec![false; lag as usize + 1],
            t: 0,
            reset_after: tuning.bar_reset,
            hyst: tuning.bar_hyst,
            ref_q: 0,
            off_level: 0,
            chosen: 0,
        }
    }

    fn reset(&mut self) {
        self.slot = 0;
        self.closed = 0;
        self.closed_any = false;
        self.sum = [[0.0; FEATURES]; BPB];
        self.weight = [[BAR_EPSILON; FEATURES]; BPB];
        self.level = 0.0;
        self.frames = 0.0;
        self.spec = [0.0; MAX_BANDS];
        self.prev_spec = [0.0; MAX_BANDS];
        self.have_prev = false;
        self.bass = 0.0;
        self.last_flux = 0.0;
        self.prev_bands = [0.0; BASS_FLUX_BANDS];
        self.onset = 0.0;
        self.onset_frames = ONSET_SPAN;
        self.prev_onset = 0.0;
        self.have_onset = false;
        self.beats.fill(false);
        self.t = 0;
        self.ref_q = 0;
        self.off_level = 0;
        self.chosen = 0;
    }

    fn add(&mut self, slot: usize, feature: usize, value: f64) {
        self.sum[slot][feature] = self.sum[slot][feature] * self.decay + value;
        self.weight[slot][feature] = self.weight[slot][feature] * self.decay + 1.0;
    }

    /// Consumes a frame, with the best period `q`; on a beat returns its position in the bar
    /// (0 is the downbeat).
    fn update(&mut self, frame: &DspFrame, low: f64, beat: bool, q: usize) -> Option<usize> {
        let bpb = self.bpb;
        // A run of beats at a period outside [3/4, 4/3] of the reference one: another metrical
        // level, whose bar positions the old statistics do not describe.
        if beat && self.reset_after > 0 {
            if self.ref_q == 0 || (4 * q >= 3 * self.ref_q && 3 * q <= 4 * self.ref_q) {
                self.ref_q = q;
                self.off_level = 0;
            } else {
                self.off_level += 1;
                if self.off_level >= self.reset_after {
                    self.sum = [[0.0; FEATURES]; BPB];
                    self.weight = [[BAR_EPSILON; FEATURES]; BPB];
                    self.ref_q = q;
                    self.off_level = 0;
                }
            }
        }
        let mut flux = 0.0;
        for j in 0..self.bass_bands {
            let v = clean(frame.spectrum[self.low_first + j]);
            let rise = v - self.prev_bands[j];
            flux += if rise > 0.0 { rise } else { 0.0 };
            self.prev_bands[j] = v;
        }
        // The low onset from the frame before a beat to two frames after it.
        if beat {
            if self.have_onset {
                let slot = (self.slot + bpb - 1) % bpb;
                self.add(slot, 1, self.onset);
            }
            self.onset = self.prev_onset;
            self.onset_frames = 0;
            self.have_onset = true;
        }
        if self.onset_frames < ONSET_SPAN {
            if low > self.onset {
                self.onset = low;
            }
            self.onset_frames += 1;
        }
        self.prev_onset = low;
        // Spectrum intervals between lagged beats.
        let ring = self.beats.len() as u64;
        self.beats[(self.t % ring) as usize] = beat;
        if self.t >= self.lag && self.beats[((self.t - self.lag) % ring) as usize] {
            if self.frames > 0.0 && self.closed_any {
                let prev = (self.closed + bpb - 1) % bpb;
                let mut change = 0.0;
                for b in 0..self.bands {
                    let mean = self.spec[b] / self.frames;
                    if self.have_prev {
                        change += (mean - self.prev_spec[b]).abs();
                    }
                    self.prev_spec[b] = mean;
                }
                let level = self.level / self.frames;
                self.add(prev, 0, level);
                self.add(prev, 2, change);
                self.add(prev, 3, self.bass);
                self.have_prev = true;
            }
            self.closed = (self.closed + 1) % bpb;
            self.closed_any = true;
            self.level = 0.0;
            self.frames = 0.0;
            self.spec = [0.0; MAX_BANDS];
            self.bass = self.last_flux;
        }
        if self.frames < BASS_FLUX_SPAN && flux > self.bass {
            self.bass = flux;
        }
        self.last_flux = flux;
        let mut position = None;
        if beat {
            let mut means = [0.0; FEATURES];
            for (k, mean) in means.iter_mut().enumerate() {
                let mut total = 0.0;
                for i in 0..bpb {
                    total += self.sum[i][k] / self.weight[i][k];
                }
                *mean = total / bpb as f64;
            }
            let (mut best, mut best_score, mut held) = (0, f64::MIN, 0.0);
            for i in 0..bpb {
                let mut score = 0.0;
                for (k, mean) in means.iter().enumerate() {
                    score += self.weights[k] * (self.sum[i][k] / self.weight[i][k])
                        / (mean + BAR_EPSILON);
                }
                if score > best_score {
                    best_score = score;
                    best = i;
                }
                if i == self.chosen {
                    held = score;
                }
            }
            // The held position stays unless another scores `hyst` times as high.
            if self.hyst > 1.0 && held * self.hyst >= best_score {
                best = self.chosen;
            }
            self.chosen = best;
            position = Some((self.slot + bpb - best) % bpb);
            self.slot = (self.slot + 1) % bpb;
        }
        for b in 0..self.low_count {
            self.level += clean(frame.spectrum[self.low_first + b]);
        }
        for b in 0..self.bands {
            self.spec[b] += clean(frame.spectrum[b]);
        }
        self.frames += 1.0;
        self.t += 1;
        position
    }
}

/// The version 4 tracker behind [`super::BeatTracker`].
#[derive(Clone, Debug)]
pub(crate) struct V4Tracker {
    fr: f64,
    bpb: usize,
    /// Period of each tempo state, frames, ascending.
    periods: Vec<usize>,
    /// First phase state of each period in `mass`.
    offsets: Vec<usize>,
    /// Observation half-width of each period, frames.
    widths: Vec<usize>,
    /// Transition weights from each period to its [`STEPS`] neighbours (from `i - MAX_STEP`).
    trans: Vec<f64>,
    /// Tempo prior factor per beat of each period.
    gain: Vec<f64>,
    /// Jump targets of each period: first and last period index and their count.
    jump_first: Vec<usize>,
    jump_last: Vec<usize>,
    jump_count: Vec<f64>,
    states: usize,
    mean_rate: f64,
    oct: V4Tuning,
    /// Low and mid-plus-high onsets of the last four frames.
    ring_l: [f64; 4],
    ring_h: [f64; 4],
    /// Decaying sums of the low and mid-plus-high peaks at the four half-beat positions of a
    /// two-beat cycle: 0 and 2 are beats, 1 and 3 mid-beats.
    acc_l: [f64; 4],
    acc_h: [f64; 4],
    /// Samples taken since the sums were last cleared.
    samples: f64,
    /// Beats sampled; its parity picks the cycle position.
    beats_seen: u64,
    /// Best period at the last sample.
    oct_q: usize,
    /// Frame of the last beat sample.
    last_on: u64,
    /// Frame of the last mid-beat sample.
    last_off: u64,
    /// After a halving: the last beat frame and the period before it, to place the next beat
    /// in the cycle.
    anchor: Option<(u64, usize)>,
    /// Periods from this index on are penalised at their beat.
    cut: usize,
    mass: Vec<f64>,
    moving: Vec<f64>,
    prefix: Vec<f64>,
    period_mass: Vec<f64>,
    t: u64,
    mean: f64,
    /// Frames since the envelope last reached [`ACTIVE`].
    since: u64,
    last_beat: Option<u64>,
    locked: bool,
    in_bar: usize,
    phase: f64,
    down: Downbeat,
}

impl V4Tracker {
    /// Checks the period range against version 4's bounds after [`super::BeatTracker::new`]
    /// checked the rest.
    pub(crate) fn new(
        settings: &DspSettings,
        beat: BeatConfig,
        tuning: &V4Tuning,
    ) -> Result<V4Tracker, DspError> {
        let cfg = &settings.config;
        let fr = cfg.sample_rate_hz as f64 / cfg.hop_samples as f64;
        let lo = libm::floor(fr * 60.0 / beat.max_bpm);
        if lo < MIN_PERIOD_FRAMES {
            return Err(DspError::InvalidConfig("max_bpm"));
        }
        let hi = libm::ceil(fr * 60.0 / beat.min_bpm);
        if hi > MAX_PERIOD_FRAMES {
            return Err(DspError::InvalidConfig("min_bpm"));
        }
        let t = tuning;
        let finite = [
            t.prior_gain,
            t.oct_decay,
            t.oct_high,
            t.oct_low,
            t.oct_pen,
            t.oct_warm,
            t.bar_decay,
            t.bar_hyst,
        ]
        .iter()
        .chain(t.weights.iter())
        .all(|v| v.is_finite());
        // A negative prior gain grows mass away from the prior; a decay above 1 grows the sums
        // without bound, and a negative one (or penalty) makes them, or the mass, negative.
        let unit = |v: f64| (0.0..=1.0).contains(&v);
        if !(finite
            && t.prior_bpm.is_finite()
            && t.prior_bpm > 0.0
            && t.prior_sigma.is_finite()
            && t.prior_sigma > 0.0
            && t.prior_gain >= 0.0
            && unit(t.oct_decay)
            && unit(t.oct_pen)
            && unit(t.bar_decay))
        {
            return Err(DspError::InvalidConfig("v4_tuning"));
        }
        let periods: Vec<usize> = (lo as usize..=hi as usize).collect();
        let count = periods.len();
        let mut offsets = Vec::with_capacity(count);
        let mut states = 0;
        for &q in &periods {
            offsets.push(states);
            states += q;
        }
        let widths = periods
            .iter()
            .map(|&q| libm::floor(WINDOW * q as f64) as usize)
            .collect();
        let mut trans = vec![0.0; count * STEPS];
        for j in 0..count {
            let first = j.saturating_sub(MAX_STEP);
            let last = (j + MAX_STEP).min(count - 1);
            let mut total = 0.0;
            for i in first..=last {
                let w = exp_series(-LAMBDA * (periods[i] as f64 / periods[j] as f64 - 1.0).abs());
                trans[j * STEPS + i - first] = w;
                total += w;
            }
            for i in first..=last {
                trans[j * STEPS + i - first] /= total;
            }
        }
        let pref = fr * 60.0 / tuning.prior_bpm;
        let mut gain = Vec::with_capacity(count);
        for &q in &periods {
            // The series loop on an infinite or zero argument: an extreme prior centre or width
            // is rejected rather than hanging creation.
            let ratio = q as f64 / pref;
            if !(ratio.is_finite() && ratio > 0.0) {
                return Err(DspError::InvalidConfig("v4_tuning"));
            }
            let z = ln_series(ratio) / tuning.prior_sigma;
            let y = -0.5 * z * z * tuning.prior_gain * q as f64 / fr;
            if !y.is_finite() {
                return Err(DspError::InvalidConfig("v4_tuning"));
            }
            gain.push(exp_series(y));
        }
        let within = |i: usize, j: usize| {
            ln_series(periods[i] as f64 / periods[j] as f64).abs() <= JUMP_RANGE
        };
        let mut jump_first = Vec::with_capacity(count);
        let mut jump_last = Vec::with_capacity(count);
        let mut jump_count = Vec::with_capacity(count);
        for i in 0..count {
            let first = (0..count).find(|&j| within(i, j)).unwrap_or(i);
            let last = (0..count).rev().find(|&j| within(i, j)).unwrap_or(i);
            jump_first.push(first);
            jump_last.push(last);
            jump_count.push((last - first + 1) as f64);
        }
        let [low_first, low_last] = cfg.onset_band_groups[0];
        let lag = V2::bass_delay_samples(cfg).map_or(0, |delay| {
            libm::floor(delay / cfg.hop_samples as f64 + 0.5) as u64
        });
        let bpb = beat.beats_per_bar as usize;
        let mut tracker = V4Tracker {
            fr,
            bpb,
            mass: vec![0.0; states],
            moving: vec![0.0; count],
            prefix: vec![0.0; count + 1],
            period_mass: vec![0.0; count],
            periods,
            offsets,
            widths,
            trans,
            gain,
            jump_first,
            jump_last,
            jump_count,
            states,
            mean_rate: 1.0 / (MEAN_TAU_S * fr),
            oct: *tuning,
            ring_l: [0.0; 4],
            ring_h: [0.0; 4],
            acc_l: [0.0; 4],
            acc_h: [0.0; 4],
            samples: 0.0,
            beats_seen: 0,
            oct_q: 0,
            last_on: 0,
            last_off: 0,
            anchor: None,
            cut: usize::MAX,
            t: 0,
            mean: 0.0,
            since: u64::MAX,
            last_beat: None,
            locked: false,
            in_bar: 0,
            phase: 0.0,
            down: Downbeat::new(
                tuning,
                bpb,
                lag,
                low_first as usize,
                (low_last - low_first + 1) as usize,
                cfg.spectrum_bands as usize,
            ),
        };
        tracker.reset();
        Ok(tracker)
    }

    /// Returns the tracker to its state after [`V4Tracker::new`].
    pub(crate) fn reset(&mut self) {
        let uniform = 1.0 / self.states as f64;
        self.mass.fill(uniform);
        for (i, &q) in self.periods.iter().enumerate() {
            self.period_mass[i] = q as f64 * uniform;
        }
        self.t = 0;
        self.mean = 0.0;
        self.locked = false;
        self.soft_reset();
    }

    /// After a gap or stall: keeps each period's mass, spreads it over its phases, and forgets
    /// onsets, beats and bar statistics.
    fn soft_reset(&mut self) {
        for (i, &q) in self.periods.iter().enumerate() {
            let base = self.offsets[i];
            let v = self.period_mass[i] / q as f64;
            self.mass[base..base + q].fill(v);
        }
        self.since = u64::MAX;
        self.last_beat = None;
        self.in_bar = 0;
        self.phase = 0.0;
        self.down.reset();
        self.ring_l = [0.0; 4];
        self.ring_h = [0.0; 4];
        self.forget_octave(0);
    }

    /// Clears the octave cue's sums, starting again at period `q`.
    fn forget_octave(&mut self, q: usize) {
        self.acc_l = [0.0; 4];
        self.acc_h = [0.0; 4];
        self.samples = 0.0;
        self.beats_seen = 0;
        self.last_on = 0;
        self.last_off = 0;
        self.oct_q = q;
        self.anchor = None;
        self.cut = usize::MAX;
    }

    /// The octave cue: samples the onset peaks at the best state's beat and mid-beat (`elapsed`
    /// frames after its beat at frame `t`, best period index `bi`) and sets the periods that
    /// [`V4Tracker::advance`] penalises; see the module documentation.
    fn octave(&mut self, t: u64, bi: usize, elapsed: usize) {
        let q = self.periods[bi];
        let old = self.oct_q;
        if 5 * q >= 2 * old && 5 * q <= 3 * old {
            // Halved: the old beats and mid-beats are the new beats.
            for v in [&mut self.acc_l, &mut self.acc_h] {
                *v = [0.5 * (v[0] + v[2]), 0.0, 0.5 * (v[1] + v[3]), 0.0];
            }
            self.anchor = Some((self.last_on, old));
        } else if 10 * q >= 17 * old && 10 * q <= 23 * old {
            // Doubled: the old strong beats (by the low band, not the best state's phase, which
            // may sit on the snare) are the new beats, the others the mid-beats.
            let (on, off) = if self.acc_l[0] >= self.acc_l[2] {
                (0, 2)
            } else {
                (2, 0)
            };
            for v in [&mut self.acc_l, &mut self.acc_h] {
                *v = [v[on], v[off], v[on], v[off]];
            }
            self.anchor = None;
        } else if 10 * q > 13 * old || 13 * q < 10 * old {
            self.forget_octave(q);
        }
        self.oct_q = q;
        let half = q / 2;
        // A phase or period shift of the best state can bring `elapsed` back to the same value
        // on a later frame: each beat and each mid-beat is sampled once, at least half a period
        // after the last one.
        let idx = if elapsed == 2 && 2 * (t - self.last_on) > q as u64 {
            match self.anchor.take() {
                Some((ta, qa)) => {
                    let r = ((t - ta) % qa as u64) as usize;
                    self.beats_seen = u64::from(4 * r > qa && 4 * r < 3 * qa);
                }
                None => self.beats_seen += 1,
            }
            self.last_on = t;
            2 * (self.beats_seen % 2) as usize
        } else if elapsed == half + 2 && 2 * (t - self.last_off) > q as u64 {
            self.last_off = t;
            2 * (self.beats_seen % 2) as usize + 1
        } else {
            return;
        };
        let (mut l, mut h) = (0.0, 0.0);
        for j in 0..4 {
            if self.ring_l[j] > l {
                l = self.ring_l[j];
            }
            if self.ring_h[j] > h {
                h = self.ring_h[j];
            }
        }
        let d = self.oct.oct_decay;
        for j in 0..4 {
            self.acc_l[j] *= d;
            self.acc_h[j] *= d;
        }
        self.acc_l[idx] += l;
        self.acc_h[idx] += h;
        self.samples += 1.0;
        if self.samples < self.oct.oct_warm {
            return;
        }
        let (l, h) = (&self.acc_l, &self.acc_h);
        let (high, low) = (self.oct.oct_high, self.oct.oct_low);
        // Mid-beats of q that carry high-band onsets but few low-band ones: q is the half tempo.
        // The strict comparisons need real evidence: with no high-band onset at all (bass only)
        // or no low-band onset on the beats neither pattern holds.
        let backbeat = h[1] + h[3] > high * (h[0] + h[2]) && l[1] + l[3] < low * (l[0] + l[2]);
        // Every other beat of q such a backbeat: q is the tempo and 2q the half tempo.
        let (on, off) = if l[0] >= l[2] { (0, 2) } else { (2, 0) };
        let alternate = h[off] > high * h[on] && l[off] < low * l[on];
        let target = if backbeat && q / 2 >= self.periods[0] {
            3 * q / 4
        } else if alternate {
            3 * q / 2
        } else {
            self.cut = usize::MAX;
            return;
        };
        self.cut = self.periods.partition_point(|&p| p < target);
    }

    /// Consumes the next analysis frame.
    pub(crate) fn update(&mut self, frame: &DspFrame) -> Beat {
        if frame.flags & (FLAG_GAP | FLAG_STALLED) != 0 {
            self.soft_reset();
        }
        let t = self.t;
        let low = unit(frame.onset.low);
        let o = LOW_WEIGHT * low + unit(frame.onset.mid) + unit(frame.onset.high);
        self.since = if o >= ACTIVE {
            0
        } else {
            self.since.saturating_add(1)
        };
        self.mean += (o - self.mean) * self.mean_rate;
        let x = o / (MEAN_RATIO * self.mean + MEAN_FLOOR);
        let r = (BETA + x) / (BETA + 1.0);
        self.ring_l[(t % 4) as usize] = low;
        self.ring_h[(t % 4) as usize] = unit(frame.onset.mid) + unit(frame.onset.high);
        self.observe(t, r);
        self.advance(t);
        self.normalise();
        let (bi, bk) = self.best();

        let q = self.periods[bi];
        let tq = (t % q as u64) as usize;
        let elapsed = (tq + q - bk) % q;
        let qf = q as f64;
        let mut pf = elapsed as f64 + DELAY_FRAMES;
        if pf >= qf {
            pf -= qf;
        }
        let d = if pf > qf / 2.0 { pf - qf } else { pf };
        if self.oct.oct_pen < 1.0 {
            if self.since <= q as u64 {
                self.octave(t, bi, elapsed);
            } else {
                // No onset within a period: a pause or the end of a song, whose evidence must
                // not decide the next one.
                self.forget_octave(0);
            }
        }
        let active = self.since <= HOLD_BEATS * q as u64;
        let gated = self
            .last_beat
            .is_some_and(|last| ((t - last) as f64) < BEAT_GATE * qf);
        let beat = active && d > -0.5 && d <= SLACK_FRAMES && !gated;
        if beat {
            self.last_beat = Some(t);
            self.locked = true;
        }
        let position = self.down.update(frame, low, beat, q);

        let first = bi.saturating_sub(SPAN);
        let last = (bi + SPAN).min(self.periods.len() - 1);
        let (mut num, mut den) = (0.0, 0.0);
        for i in first..=last {
            num += self.period_mass[i] * self.periods[i] as f64;
            den += self.period_mass[i];
        }
        let tempo = 60.0 * self.fr / (num / den);
        self.t += 1;
        if !self.locked {
            return Beat::ZERO;
        }

        let beat_phase = if beat && d <= 0.0 { 0.0 } else { pf / qf };
        match position {
            Some(p) => self.in_bar = p,
            // Without a beat, a phase wrap still moves the bar on, so it keeps running.
            None if beat_phase < self.phase - 0.5 => self.in_bar = (self.in_bar + 1) % self.bpb,
            None => {}
        }
        self.phase = beat_phase;
        let mut near = 0.0;
        for i in first..=last {
            let qi = self.periods[i];
            let base = self.offsets[i];
            let centre = ((t % qi as u64) as usize + qi - elapsed % qi) % qi;
            for delta in 0..=2 * PHASE_SPAN {
                near += self.mass[base + (centre + qi + delta - PHASE_SPAN) % qi];
            }
        }
        let since = self.since as f64;
        let fade = if since <= qf {
            1.0
        } else if since >= HOLD_BEATS as f64 * qf {
            0.0
        } else {
            (HOLD_BEATS as f64 * qf - since) / ((HOLD_BEATS - 1) as f64 * qf)
        };
        let confidence = (if near < 1.0 { near } else { 1.0 }) * fade;
        let downbeat = beat && self.in_bar == 0;
        Beat {
            tempo_bpm: tempo,
            beat_phase,
            bar_phase: (self.in_bar as f64 + beat_phase) / self.bpb as f64,
            confidence,
            beat: u32::from(beat),
            downbeat: u32::from(downbeat),
            beat_in_bar: self.in_bar as u32,
            reserved: 0,
        }
    }

    /// Step 2: weighs every state whose beat falls near frame `t` by the likelihood ratio `r`.
    fn observe(&mut self, t: u64, r: f64) {
        for (i, &q) in self.periods.iter().enumerate() {
            let w = self.widths[i];
            let base = self.offsets[i];
            let tq = (t % q as u64) as usize;
            for step in 0..=2 * w {
                // phi = step - w; the state whose beat is phi frames before t.
                let k = (tq + q + w - step) % q;
                let phi = w.abs_diff(step);
                let tri = 1.0 - phi as f64 / (w as f64 + 1.0);
                self.mass[base + k] *= 1.0 + (r - 1.0) * tri;
            }
        }
    }

    /// Step 3: moves the mass of the states at their beat to the same phase of nearby periods.
    fn advance(&mut self, t: u64) {
        let count = self.periods.len();
        for i in 0..count {
            let q = self.periods[i];
            let at = self.offsets[i] + (t % q as u64) as usize;
            self.moving[i] = self.mass[at] * self.gain[i];
            // The octave cue's penalty.
            if i >= self.cut {
                self.moving[i] *= self.oct.oct_pen;
            }
            self.mass[at] = 0.0;
        }
        for j in 0..count {
            let xj = self.moving[j];
            let first = j.saturating_sub(MAX_STEP);
            let last = (j + MAX_STEP).min(count - 1);
            for i in first..=last {
                let q = self.periods[i];
                let at = self.offsets[i] + (t % q as u64) as usize;
                self.mass[at] += xj * self.trans[j * STEPS + i - first] * (1.0 - JUMP);
            }
        }
        for j in 0..count {
            self.prefix[j + 1] = self.prefix[j] + self.moving[j] / self.jump_count[j];
        }
        for i in 0..count {
            let q = self.periods[i];
            let at = self.offsets[i] + (t % q as u64) as usize;
            self.mass[at] +=
                JUMP * (self.prefix[self.jump_last[i] + 1] - self.prefix[self.jump_first[i]]);
        }
    }

    /// Step 4.
    fn normalise(&mut self) {
        let mut total = 0.0;
        for &v in &self.mass {
            total += v;
        }
        let scale = (1.0 - MIX) / total;
        let floor = MIX / self.states as f64;
        for v in &mut self.mass {
            *v = *v * scale + floor;
        }
    }

    /// The most probable state (the first on ties) as (period index, phase); records each
    /// period's mass.
    fn best(&mut self) -> (usize, usize) {
        let (mut best, mut bi, mut bk) = (-1.0, 0, 0);
        for (i, &q) in self.periods.iter().enumerate() {
            let base = self.offsets[i];
            let mut total = 0.0;
            for k in 0..q {
                let v = self.mass[base + k];
                total += v;
                if v > best {
                    best = v;
                    bi = i;
                    bk = k;
                }
            }
            self.period_mass[i] = total;
        }
        (bi, bk)
    }
}

#[cfg(test)]
mod tests {
    use super::super::config::{DspConfig, DSP_BEHAVIOR_V4};
    use super::*;

    /// OSC-BEAT-V4-OCTAVE review: a best state whose phase slips back a frame brings `elapsed`
    /// to its beat or mid-beat again on the next frame; the octave cue samples each once, so
    /// the two-beat cycle keeps its parity and no peak counts twice.
    #[test]
    fn octave_cue_samples_each_beat_and_mid_beat_once() {
        let settings = DspSettings {
            config: DspConfig::default(),
            behavior_version: DSP_BEHAVIOR_V4,
        };
        let beat = BeatConfig::for_version(DSP_BEHAVIOR_V4);
        let mut v4 = V4Tracker::new(&settings, beat, &V4Tuning::default()).expect("tracker");
        let bi = 10;
        let q = v4.periods[bi];
        let (half, t) = (q / 2, 1000);
        v4.ring_l = [1.0; 4];
        v4.ring_h = [0.5; 4];
        for (dt, elapsed) in [
            (0, 2),
            (1, 2),
            (half, half + 2),
            (half + 1, half + 2),
            (q, 2),
        ] {
            v4.octave(t + dt as u64, bi, elapsed);
        }
        assert_eq!((v4.samples, v4.beats_seen), (3.0, 2));
        let d = OCT_DECAY;
        assert_eq!(v4.acc_l, [1.0, 0.0, d * d, d]);
        assert_eq!(v4.acc_h, [0.5, 0.0, 0.5 * d * d, 0.5 * d]);
    }

    #[test]
    fn series_match_the_libm_functions_closely() {
        for &y in &[-37.5, -3.0, -0.4, 0.0, 0.25, 1.0, 5.5] {
            let (a, b) = (exp_series(y), libm::exp(y));
            assert!((a - b).abs() <= 1e-13 * b, "exp {y}: {a} vs {b}");
        }
        for &x in &[0.11, 0.5, 0.75, 1.0, 1.5, 2.0, 9.0, 512.0 / 28.0] {
            let (a, b) = (ln_series(x), libm::log(x));
            assert!(
                (a - b).abs() <= 1e-15 + 1e-15 * b.abs(),
                "ln {x}: {a} vs {b}"
            );
        }
    }
}
