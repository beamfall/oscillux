// SPDX-License-Identifier: AGPL-3.0-only
//! Streaming tempo, beat and downbeat tracking on the analyser's onset envelope.
//!
//! [`BeatTracker`] consumes [`DspFrame`]s in order and returns one [`Beat`] per frame. It
//! allocates in [`BeatTracker::new`] only, and uses only IEEE double addition, subtraction,
//! multiplication, division, floor and comparisons, so every target produces the same bits.
//! `conformance/dsp/music/README.md` ("Beat tracker") specifies it, and
//! `tools/dsp-beat-vectors.py` is the independent oracle for `conformance/dsp/music/beat/`.
//!
//! Per frame:
//!
//! 1. An onset picker on `(low + 2·mid) / 3` decides two frames late whether frame `t - 2` was
//!    an onset (a local maximum well above the local mean).
//! 2. Each onset pairs with up to 24 earlier onsets. Their intervals go into a decaying
//!    histogram, and a four-harmonic comb with a mild 120 BPM prior picks a period between
//!    `min_bpm` and `max_bpm`. A new period must outscore the current one by a fifth and persist
//!    for half a second (one second for the first lock) before it replaces the current one;
//!    changes within 6% are followed at once. A replacement halves the phase histogram.
//! 3. Onsets also go into a 48-bin histogram of beat phase. Each bin's score adds half the bin
//!    half a beat on. The peak near the current anchor is kept unless another is clearly
//!    stronger or the period changed, or a gap or stall came, within the last four beats. The
//!    peak sets the phase of a beat clock that runs at the current period. Each wrap of the
//!    phase moves the bar position on by one beat (back by one when the phase estimate steps back across 0). A forward wrap
//!    emits a beat when the histogram is not empty, half a period has passed since the last
//!    beat and an onset was picked within the last sixteen periods, so beats carry through a
//!    break of up to four 4/4 bars and stop in longer silence.
//! 4. The low-band change around each emitted beat accumulates per bar position; the position
//!    with the largest change becomes the downbeat.
//!
//! A frame flagged [`FLAG_GAP`] or [`FLAG_STALLED`] keeps the tempo but forgets onsets, phase
//! and bar position.
//!
//! Settings at [`DSP_BEHAVIOR_V3`] select version 3, which changes two steps and keeps the rest:
//!
//! - Step 2 correlates the envelope `low + mid + high`, less 1.5 times its one-second running
//!   mean and floored at 0, with its own past every frame, into a histogram that decays over
//!   four seconds. The comb takes the largest of the three lags around each harmonic, and its
//!   prior, `1 / (1 + 1.5·r²)` with `r = (p - p₁₁₀) / (p + p₁₁₀)`, centres on 110 BPM and treats
//!   half and double tempo alike.
//! - Step 3 adds, every frame, the low-band onset of frame `t - 2` plus the picked strength to
//!   the phase histogram, so the phase follows the bass as well as the picked onsets.
//!
//! [`BeatConfig::for_version`] gives version 3 a 60 to 200 BPM range.
//!
//! Settings at [`DSP_BEHAVIOR_V4`] select version 4, a different model: a causal beat-pointer
//! hidden Markov model over every integer beat period, observed through the onset envelope and
//! reported at the frame's media time, with a bar-position stage for downbeats
//! (`conformance/dsp/music/README.md`, "Beat tracker, version 4"; the `beat_v4` module).
//! `tools/dsp-beat-v4-vectors.py` is its oracle for `conformance/dsp/music/beat-v4/`. Its period
//! range ends at 512 frames, and [`BeatConfig::for_version`] gives it 60 to 200 BPM.

use alloc::boxed::Box;
use alloc::vec;
use alloc::vec::Vec;

use super::beat_v4::{V4Tracker, V4Tuning};
use super::config::{DspSettings, DSP_BEHAVIOR_V3, DSP_BEHAVIOR_V4};
use super::{DspError, DspFrame, FLAG_GAP, FLAG_STALLED};

const PICK_RING: usize = 16;
const PICK_DELAY: u64 = 2;
const PICK_MAX_BEFORE: u64 = 3;
const PICK_MEAN_BEFORE: u64 = 10;
const PICK_FILLED: u64 = PICK_MEAN_BEFORE + PICK_DELAY + 1;
const PICK_DELTA: f64 = 0.1;
const PICK_RATIO: f64 = 3.0;
const PICK_MIN_GAP: u64 = 3;
const ONSET_RING: usize = 24;
const KERNEL: usize = 2;
const HARMONICS: usize = 4;
const IOI_TAU_S: f64 = 2.0;
const PRIOR_WEIGHT: f64 = 1.0;
const FOLLOW: f64 = 0.06;
const SWITCH_S: f64 = 0.5;
const JUMP_MARGIN: f64 = 1.2;
const PHASE_BINS: usize = 48;
const PHASE_BEATS: f64 = 8.0;
const HALF_WEIGHT: f64 = 0.5;
const PHASE_TRACK: usize = 4;
const PHASE_SWITCH: f64 = 1.3;
const FREE_BEATS: f64 = 4.0;
const JUMP_KEEP: f64 = 0.5;
const BEAT_GATE: f64 = 0.5;
const CUE_SPAN: u64 = 3;
const SPEC_RING: usize = 8;
const ACCENT_RATE: f64 = 0.3;
const ACCENT_SWITCH: f64 = 1.1;
const FLUSH: f64 = 1e-12;
const MIN_PERIOD_FRAMES: f64 = 8.0;
const MAX_PERIOD_FRAMES: f64 = 1024.0;

// Version 3.
const V3_MIN_BPM: f64 = 60.0;
const V3_MAX_BPM: f64 = 200.0;
const V3_PRIOR_BPM: f64 = 110.0;
const V3_PRIOR_WEIGHT: f64 = 1.5;
const V3_ACF_TAU_S: f64 = 4.0;
const V3_MEAN_SCALE: f64 = 1.5;
const V3_MEAN_TAU_S: f64 = 1.0;

/// The largest accepted [`BeatConfig::beats_per_bar`].
pub const MAX_BEATS_PER_BAR: u32 = 16;

/// Beat analysis latency of behaviour version 1, ms: the mean time from an onset to the media
/// time of the frame that reports its beat, measured on click and kick trains from 60 to 200 BPM
/// at 44.1 and 48 kHz (`conformance/dsp/music/README.md`, "Beat timing"). A host that times a
/// reaction to the beat subtracts it.
pub const BEAT_LATENCY_V1_MS: u32 = 16;
/// Beat analysis latency of behaviour version 2, ms; see [`BEAT_LATENCY_V1_MS`].
pub const BEAT_LATENCY_V2_MS: u32 = 14;
/// Beat analysis latency of behaviour version 3, ms; see [`BEAT_LATENCY_V1_MS`].
pub const BEAT_LATENCY_V3_MS: u32 = 16;
/// Beat analysis latency of behaviour version 4, ms; see [`BEAT_LATENCY_V1_MS`]. Version 4
/// compensates its own envelope delay, so what remains is the onset rise within a frame.
pub const BEAT_LATENCY_V4_MS: u32 = 3;

/// Tempo range and metre for a [`BeatTracker`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BeatConfig {
    /// Slowest reported tempo, beats per minute.
    pub min_bpm: f64,
    /// Fastest reported tempo, beats per minute. Before version 3, keep the range within one
    /// octave (`max_bpm <= 2 · min_bpm`): a wider range lets the tracker settle on half or double
    /// the tempo.
    pub max_bpm: f64,
    /// Beats per bar, `1..=MAX_BEATS_PER_BAR`.
    pub beats_per_bar: u32,
}

impl Default for BeatConfig {
    /// 80 to 160 BPM in 4/4.
    fn default() -> Self {
        Self {
            min_bpm: 80.0,
            max_bpm: 160.0,
            beats_per_bar: 4,
        }
    }
}

impl BeatConfig {
    /// The configuration an analyzer at `behavior_version` runs: 60 to 200 BPM in 4/4 at
    /// [`DSP_BEHAVIOR_V3`] and [`DSP_BEHAVIOR_V4`], else [`BeatConfig::default`].
    pub fn for_version(behavior_version: u32) -> Self {
        if behavior_version == DSP_BEHAVIOR_V3 || behavior_version == DSP_BEHAVIOR_V4 {
            Self {
                min_bpm: V3_MIN_BPM,
                max_bpm: V3_MAX_BPM,
                ..Self::default()
            }
        } else {
            Self::default()
        }
    }
}

/// The tracker's output for one frame. Every field is 0 until the first tempo lock.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Beat {
    /// Current tempo, beats per minute.
    pub tempo_bpm: f64,
    /// Position within the current beat, `[0, 1)`; 0 is the beat.
    pub beat_phase: f64,
    /// Position within the current bar, `[0, 1)`; 0 is the downbeat.
    pub bar_phase: f64,
    /// `[0, 1]`: the product of tempo clarity, phase clarity and onset recency. It falls from
    /// two to sixteen beats after the last onset and is 0 from then on, while the phases keep
    /// running at the held tempo.
    pub confidence: f64,
    /// 1 on the frame a beat is emitted, else 0. No beat is emitted from sixteen beats after the
    /// last onset until the next onset.
    pub beat: u32,
    /// 1 when this frame's beat is the first of a bar, else 0.
    pub downbeat: u32,
    /// Index of the current beat within the bar, `0..beats_per_bar`; 0 is the downbeat.
    pub beat_in_bar: u32,
    /// Always 0.
    pub reserved: u32,
}

impl Beat {
    /// All zero, for initialising caller-owned output buffers.
    pub const ZERO: Beat = Beat {
        tempo_bpm: 0.0,
        beat_phase: 0.0,
        bar_phase: 0.0,
        confidence: 0.0,
        beat: 0,
        downbeat: 0,
        beat_in_bar: 0,
        reserved: 0,
    };
}

/// A streaming beat tracker; see the module documentation.
#[derive(Clone, Debug)]
pub struct BeatTracker {
    fr: f64,
    lo: usize,
    hi: usize,
    bpb: u32,
    low_first: usize,
    low_count: usize,
    ioi_decay: f64,
    switch: u32,
    pref: f64,
    hist: Vec<f64>,
    x: [f64; PICK_RING],
    /// Version 3; the fields below are used only by it.
    v3: bool,
    /// Low-band onsets of recent frames.
    low: [f64; PICK_RING],
    /// Recent correlation envelope values; empty before version 3.
    z: Vec<f64>,
    zmean: f64,
    zrate: f64,
    spec: Vec<f64>,
    t: u64,
    period: f64,
    pending: f64,
    count: u32,
    clock: f64,
    last_beat: Option<u64>,
    filled: u64,
    last_onset: Option<u64>,
    ring: [Option<(u64, f64)>; ONSET_RING],
    rpos: usize,
    ph: [f64; PHASE_BINS],
    prev_psi: Option<f64>,
    /// Beat phase of the latest histogram peak, as a fraction of a beat.
    anchor: f64,
    /// Frames left before the anchor's hysteresis applies again after the phases were cleared.
    free: f64,
    cue: Option<(u64, usize)>,
    accent: [f64; MAX_BEATS_PER_BAR as usize],
    down: usize,
    /// Bar position, `0..bpb`, of the latest phase wrap.
    slot: usize,
    /// The version 4 tracker, which replaces everything above when present.
    v4: Option<Box<V4Tracker>>,
}

/// `x - floor(x)`, with a result that rounds up to 1 returned as 0.
fn frac(x: f64) -> f64 {
    let f = x - libm::floor(x);
    if f >= 1.0 {
        0.0
    } else {
        f
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

/// Multiplies every value by `factor`, flushing results below [`FLUSH`] to 0.
fn decay(values: &mut [f64], factor: f64) {
    for v in values {
        let d = *v * factor;
        *v = if d < FLUSH { 0.0 } else { d };
    }
}

impl BeatTracker {
    /// A tracker for frames produced with `settings`. Uses the first onset band group as the
    /// low bands for downbeat cues.
    pub fn new(settings: &DspSettings, beat: BeatConfig) -> Result<Self, DspError> {
        Self::with_v4_tuning(settings, beat, &V4Tuning::default())
    }

    /// [`BeatTracker::new`] with the version 4 constants replaced (not a stable API).
    #[doc(hidden)]
    pub fn with_v4_tuning(
        settings: &DspSettings,
        beat: BeatConfig,
        tuning: &V4Tuning,
    ) -> Result<Self, DspError> {
        settings.validate()?;
        let cfg = &settings.config;
        if !(beat.min_bpm.is_finite() && beat.min_bpm > 0.0) {
            return Err(DspError::InvalidConfig("min_bpm"));
        }
        if !(beat.max_bpm.is_finite() && beat.max_bpm > beat.min_bpm) {
            return Err(DspError::InvalidConfig("max_bpm"));
        }
        if !(1..=MAX_BEATS_PER_BAR).contains(&beat.beats_per_bar) {
            return Err(DspError::InvalidConfig("beats_per_bar"));
        }
        let fr = cfg.sample_rate_hz as f64 / cfg.hop_samples as f64;
        let lo = libm::floor(fr * 60.0 / beat.max_bpm);
        if lo < MIN_PERIOD_FRAMES {
            return Err(DspError::InvalidConfig("max_bpm"));
        }
        let hi = libm::ceil(fr * 60.0 / beat.min_bpm);
        if hi > MAX_PERIOD_FRAMES {
            return Err(DspError::InvalidConfig("min_bpm"));
        }
        let (lo, hi) = (lo as usize, hi as usize);
        let [first, last] = cfg.onset_band_groups[0];
        let low_count = (last - first + 1) as usize;
        let v3 = settings.behavior_version == DSP_BEHAVIOR_V3;
        Ok(Self {
            fr,
            lo,
            hi,
            bpb: beat.beats_per_bar,
            low_first: first as usize,
            low_count,
            ioi_decay: 1.0 - 1.0 / (if v3 { V3_ACF_TAU_S } else { IOI_TAU_S } * fr),
            switch: libm::floor(SWITCH_S * fr + 0.5) as u32,
            pref: if v3 {
                fr * 60.0 / V3_PRIOR_BPM
            } else {
                fr * 0.5
            },
            hist: vec![0.0; HARMONICS * hi + 2 * KERNEL + 1],
            x: [0.0; PICK_RING],
            v3,
            low: [0.0; PICK_RING],
            z: if v3 {
                vec![0.0; HARMONICS * hi + KERNEL + 1]
            } else {
                Vec::new()
            },
            zmean: 0.0,
            zrate: 1.0 / (V3_MEAN_TAU_S * fr),
            spec: vec![0.0; SPEC_RING * low_count],
            t: 0,
            period: 0.0,
            pending: 0.0,
            count: 0,
            clock: 0.0,
            last_beat: None,
            filled: 0,
            last_onset: None,
            ring: [None; ONSET_RING],
            rpos: 0,
            ph: [0.0; PHASE_BINS],
            prev_psi: None,
            anchor: 0.0,
            free: 0.0,
            cue: None,
            accent: [0.0; MAX_BEATS_PER_BAR as usize],
            down: 0,
            slot: beat.beats_per_bar as usize - 1,
            v4: if settings.behavior_version == DSP_BEHAVIOR_V4 {
                Some(Box::new(V4Tracker::new(settings, beat, tuning)?))
            } else {
                None
            },
        })
    }

    /// Returns the tracker to its state after [`BeatTracker::new`].
    pub fn reset(&mut self) {
        self.hist.fill(0.0);
        self.x = [0.0; PICK_RING];
        self.low = [0.0; PICK_RING];
        self.spec.fill(0.0);
        self.t = 0;
        self.period = 0.0;
        self.pending = 0.0;
        self.count = 0;
        self.clock = 0.0;
        self.last_beat = None;
        self.soft_reset();
        if let Some(v4) = self.v4.as_mut() {
            v4.reset();
        }
    }

    /// After a gap or stall: forgets onsets, phase and bar position; keeps the tempo.
    fn soft_reset(&mut self) {
        self.filled = 0;
        self.last_onset = None;
        self.ring = [None; ONSET_RING];
        self.rpos = 0;
        self.z.fill(0.0);
        self.zmean = 0.0;
        self.ph = [0.0; PHASE_BINS];
        self.prev_psi = None;
        self.anchor = 0.0;
        self.free = FREE_BEATS * self.period;
        self.cue = None;
        self.accent = [0.0; MAX_BEATS_PER_BAR as usize];
        self.down = 0;
        self.slot = self.bpb as usize - 1;
    }

    /// Strength of an onset at frame `t - 2`, or 0.
    fn pick(&mut self, t: u64) -> f64 {
        if self.filled < PICK_FILLED {
            return 0.0;
        }
        let at = |n: u64| self.x[n as usize % PICK_RING];
        let k = t - PICK_DELAY;
        let v = at(k);
        for n in k - PICK_MAX_BEFORE..=k + PICK_DELAY {
            if n != k && at(n) > v {
                return 0.0;
            }
        }
        let mut total = 0.0;
        for n in k - PICK_MEAN_BEFORE..=k + PICK_DELAY {
            total += at(n);
        }
        let mean = total / (PICK_MEAN_BEFORE + PICK_DELAY + 1) as f64;
        if v < mean + PICK_DELTA || v < PICK_RATIO * mean {
            return 0.0;
        }
        if self.last_onset.is_some_and(|last| k - last < PICK_MIN_GAP) {
            return 0.0;
        }
        self.last_onset = Some(k);
        v - mean
    }

    /// Adds the intervals from onset `(k, s)` to every remembered onset, then remembers it.
    fn deposit(&mut self, k: u64, s: f64) {
        let top = (HARMONICS * self.hi + KERNEL) as u64;
        let bottom = (self.lo - KERNEL) as u64;
        let norm = ((KERNEL + 1) * (KERNEL + 1)) as f64;
        for &(kj, sj) in self.ring.iter().flatten() {
            let lag = k - kj;
            if lag < bottom || lag > top {
                continue;
            }
            let w = s * sj / norm;
            for (i, h) in self.hist[lag as usize - KERNEL..=lag as usize + KERNEL]
                .iter_mut()
                .enumerate()
            {
                *h += w * (KERNEL + 1 - i.abs_diff(KERNEL)) as f64;
            }
        }
        self.ring[self.rpos] = Some((k, s));
        self.rpos = (self.rpos + 1) % ONSET_RING;
    }

    /// Version 3: correlates this frame's envelope value with the remembered ones.
    fn correlate(&mut self, t: u64, frame: &DspFrame) {
        let raw = clean(frame.onset.low) + clean(frame.onset.mid) + clean(frame.onset.high);
        self.zmean += self.zrate * (raw - self.zmean);
        let d = raw - V3_MEAN_SCALE * self.zmean;
        let v = if d > 0.0 { d } else { 0.0 };
        let n = self.z.len();
        let i = (t % n as u64) as usize;
        self.z[i] = v;
        if v > 0.0 {
            for lag in self.lo - KERNEL..=HARMONICS * self.hi + KERNEL {
                self.hist[lag] += v * self.z[(i + n - lag) % n];
            }
        }
    }

    fn comb_score(&self, p: usize) -> f64 {
        let mut total = 0.0;
        if self.v3 {
            for n in 1..=HARMONICS {
                let h = &self.hist;
                let c = n * p;
                let mut m = h[c - 1];
                if h[c] > m {
                    m = h[c];
                }
                if h[c + 1] > m {
                    m = h[c + 1];
                }
                total += m;
            }
            let r = (p as f64 - self.pref) / (p as f64 + self.pref);
            return total / (1.0 + V3_PRIOR_WEIGHT * r * r);
        }
        for n in 1..=HARMONICS {
            total += self.hist[n * p];
        }
        let r = (p as f64 - self.pref) / self.pref;
        total / (1.0 + PRIOR_WEIGHT * r * r)
    }

    /// (Candidate period in frames, or 0; tempo contrast; the candidate's score.)
    fn comb(&self) -> (f64, f64, f64) {
        let (mut best, mut bp, mut total) = (-1.0, 0, 0.0);
        for p in self.lo..=self.hi {
            let score = self.comb_score(p);
            total += score;
            if score > best {
                best = score;
                bp = p;
            }
        }
        if best <= 0.0 {
            return (0.0, 0.0, 0.0);
        }
        let contrast = (best - total / (self.hi - self.lo + 1) as f64) / best;
        if self.lo < bp && bp < self.hi {
            let (y0, y2) = (self.comb_score(bp - 1), self.comb_score(bp + 1));
            let den = y0 - 2.0 * best + y2;
            if den < 0.0 {
                return (bp as f64 + 0.5 * (y0 - y2) / den, contrast, best);
            }
        }
        (bp as f64, contrast, best)
    }

    fn follow(&mut self, cand: f64) {
        if cand <= 0.0 {
            self.pending = 0.0;
            self.count = 0;
            return;
        }
        if self.period > 0.0 && libm::fabs(cand - self.period) <= FOLLOW * self.period {
            self.period = cand;
            self.count = 0;
            return;
        }
        if self.count > 0 && libm::fabs(cand - self.pending) <= FOLLOW * self.pending {
            self.count += 1;
        } else {
            self.count = 1;
        }
        self.pending = cand;
        let need = if self.period > 0.0 {
            self.switch
        } else {
            2 * self.switch
        };
        if self.count >= need {
            self.period = cand;
            self.count = 0;
            // Phases measured at the old period no longer line up with the clock.
            decay(&mut self.ph, JUMP_KEEP);
            self.free = FREE_BEATS * cand;
        }
    }

    fn smoothed(&self, i: usize) -> f64 {
        let ph = &self.ph;
        ph[(i + PHASE_BINS - 1) % PHASE_BINS] + 2.0 * ph[i % PHASE_BINS] + ph[(i + 1) % PHASE_BINS]
    }

    /// Phase score of bin `i`: its smoothed weight plus [`HALF_WEIGHT`] of the bin half a beat on.
    fn phase_score(&self, i: usize) -> f64 {
        self.smoothed(i) + HALF_WEIGHT * self.smoothed(i + PHASE_BINS / 2)
    }

    /// Consumes the next analysis frame.
    pub fn update(&mut self, frame: &DspFrame) -> Beat {
        if let Some(v4) = self.v4.as_mut() {
            return v4.update(frame);
        }
        if frame.flags & (FLAG_GAP | FLAG_STALLED) != 0 {
            self.soft_reset();
        }
        let t = self.t;
        let low = clean(frame.onset.low);
        self.x[t as usize % PICK_RING] = (low + 2.0 * clean(frame.onset.mid)) / 3.0;
        self.low[t as usize % PICK_RING] = low;
        let row = (t as usize % SPEC_RING) * self.low_count;
        for q in 0..self.low_count {
            self.spec[row + q] = clean(frame.spectrum[self.low_first + q]);
        }
        self.filled += 1;
        let s = self.pick(t);

        decay(&mut self.hist, self.ioi_decay);
        if self.v3 {
            self.correlate(t, frame);
        } else if s > 0.0 {
            self.deposit(t - PICK_DELAY, s);
        }
        let (mut cand, tempo_contrast, score) = self.comb();
        // A jump away from the current period counts only while the candidate clearly wins.
        if self.period > 0.0
            && cand > 0.0
            && libm::fabs(cand - self.period) > FOLLOW * self.period
            && score < JUMP_MARGIN * self.comb_score(libm::floor(self.period + 0.5) as usize)
        {
            cand = self.period;
        }
        self.follow(cand);

        let p = self.period;
        if p <= 0.0 {
            self.t += 1;
            return Beat::default();
        }

        self.clock = frac(self.clock + 1.0 / p);
        if self.free > 0.0 {
            self.free -= 1.0;
        }
        decay(&mut self.ph, 1.0 - 1.0 / (PHASE_BEATS * p));
        let s = if !self.v3 {
            s
        } else if self.filled > PICK_DELAY {
            s + self.low[(t - PICK_DELAY) as usize % PICK_RING]
        } else {
            0.0
        };
        if s > 0.0 {
            let pos = frac(self.clock - PICK_DELAY as f64 / p) * PHASE_BINS as f64;
            let i0 = libm::floor(pos);
            let w = pos - i0;
            let i0 = i0 as usize;
            self.ph[i0 % PHASE_BINS] += s * (1.0 - w);
            self.ph[(i0 + 1) % PHASE_BINS] += s * w;
        }

        let (mut best, mut bi, mut total) = (-1.0, 0, 0.0);
        for i in 0..PHASE_BINS {
            let v = self.phase_score(i);
            total += v;
            if v > best {
                best = v;
                bi = i;
            }
        }
        // The anchor follows its own peak and jumps to a distant one only when that is clearly
        // stronger.
        let near = libm::floor(self.anchor * PHASE_BINS as f64 + 0.5) as usize;
        let (mut local, mut li) = (-1.0, 0);
        for i in near + PHASE_BINS - PHASE_TRACK..=near + PHASE_BINS + PHASE_TRACK {
            let v = self.phase_score(i % PHASE_BINS);
            if v > local {
                local = v;
                li = i % PHASE_BINS;
            }
        }
        let (peak, pi) = if self.free <= 0.0 && PHASE_SWITCH * local >= best {
            (local, li)
        } else {
            (best, bi)
        };
        let (y0, y2) = (
            self.phase_score(pi + PHASE_BINS - 1),
            self.phase_score(pi + 1),
        );
        let den = y0 - 2.0 * peak + y2;
        let offset = if den < 0.0 {
            0.5 * (y0 - y2) / den
        } else {
            0.0
        };
        // An empty histogram (long silence) keeps the last peak, so the phases run on smoothly.
        if best > 0.0 {
            self.anchor = frac((pi as f64 + offset) / PHASE_BINS as f64);
        }
        let psi = frac(self.clock - self.anchor);
        let phase_contrast = if best > 0.0 {
            (best - total / PHASE_BINS as f64) / best
        } else {
            0.0
        };

        let fresh = match self.last_onset {
            None => 0.0,
            Some(last) => {
                let since = (t - last) as f64;
                if since <= 2.0 * p {
                    1.0
                } else if since >= 16.0 * p {
                    0.0
                } else {
                    (16.0 * p - since) / (14.0 * p)
                }
            }
        };

        let bpb = self.bpb as usize;
        let (mut beat, mut downbeat) = (0, 0);
        if let Some(prev) = self.prev_psi {
            if psi < prev && prev - psi > 0.5 {
                self.slot = (self.slot + 1) % bpb;
                let gated = self
                    .last_beat
                    .is_none_or(|last| (t - last) as f64 >= BEAT_GATE * p);
                if best > 0.0 && gated && fresh > 0.0 {
                    beat = 1;
                    self.last_beat = Some(t);
                    downbeat = u32::from(self.slot == self.down);
                    self.cue = Some((t + CUE_SPAN, self.slot));
                }
            } else if psi > prev && psi - prev > 0.5 {
                self.slot = (self.slot + bpb - 1) % bpb;
            }
        }
        self.prev_psi = Some(psi);

        if let Some((end, slot)) = self.cue {
            if end <= t {
                self.cue = None;
                if self.filled > 2 * CUE_SPAN {
                    let n = self.low_count;
                    let now = (t as usize % SPEC_RING) * n;
                    let then = ((t - 2 * CUE_SPAN) as usize % SPEC_RING) * n;
                    let mut change = 0.0;
                    for q in 0..n {
                        change += libm::fabs(self.spec[now + q] - self.spec[then + q]);
                    }
                    self.accent[slot] += ACCENT_RATE * (change - self.accent[slot]);
                    let mut strongest = 0;
                    for q in 1..bpb {
                        if self.accent[q] > self.accent[strongest] {
                            strongest = q;
                        }
                    }
                    if self.accent[strongest] > ACCENT_SWITCH * self.accent[self.down] {
                        self.down = strongest;
                    }
                }
            }
        }

        let in_bar = (self.slot + bpb - self.down) % bpb;
        self.t += 1;
        Beat {
            tempo_bpm: 60.0 * self.fr / p,
            beat_phase: psi,
            bar_phase: (in_bar as f64 + psi) / bpb as f64,
            confidence: tempo_contrast * phase_contrast * fresh,
            beat,
            downbeat,
            beat_in_bar: in_bar as u32,
            reserved: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_histogram_clears_a_pending_tempo() {
        let mut tracker = BeatTracker::new(&DspSettings::default(), BeatConfig::default()).unwrap();
        tracker.follow(40.0);
        assert_eq!((tracker.pending, tracker.count), (40.0, 1));
        tracker.follow(0.0);
        assert_eq!((tracker.pending, tracker.count), (0.0, 0));
        tracker.follow(40.0);
        assert_eq!(
            tracker.count, 1,
            "a pending candidate starts over after an empty histogram"
        );
    }
}
