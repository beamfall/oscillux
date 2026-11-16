// SPDX-License-Identifier: AGPL-3.0-only
//! Offline whole-file beat and downbeat grid.
//!
//! [`BeatGrid::analyse`] reads a whole PCM file at once, so unlike the causal trackers in
//! [`crate::dsp`] it can look ahead: it computes an onset envelope over the file, a global tempo
//! and a local tempo path through a tempogram, the beat sequence that best fits both by
//! dynamic programming, and the position of each beat in its bar. Analysis allocates; the
//! result is immutable, and [`BeatGrid::clock`] answers "where in the beat and bar is media
//! time `t`" with a binary search and no allocation, so a renderer can call it every frame.
//!
//! All arithmetic is `f64` with `libm` transcendentals in a fixed order, so a grid is
//! bit-identical on every target, including wasm32.

mod fft;
mod meter;
mod onset;
mod tempo;
mod track;

use alloc::vec::Vec;

/// Lowest accepted sample rate, Hz.
pub const BEATGRID_MIN_SAMPLE_RATE_HZ: u32 = 8_000;
/// Highest accepted sample rate, Hz.
pub const BEATGRID_MAX_SAMPLE_RATE_HZ: u32 = 384_000;
/// Lowest accepted `min_bpm`.
pub const BEATGRID_MIN_BPM: f64 = 20.0;
/// Highest accepted `max_bpm`.
pub const BEATGRID_MAX_BPM: f64 = 400.0;
/// Largest accepted `beats_per_bar` hint.
pub const BEATGRID_MAX_BEATS_PER_BAR: u32 = 16;

/// Beat grid analysis parameters.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BeatGridConfig {
    /// Sample rate of the PCM, Hz, in
    /// [`BEATGRID_MIN_SAMPLE_RATE_HZ`]..=[`BEATGRID_MAX_SAMPLE_RATE_HZ`].
    pub sample_rate_hz: u32,
    /// Interleaved channels in the PCM, at least 1; they are averaged to mono.
    pub channels: u32,
    /// Slowest beat tempo considered, BPM (default 40), at least [`BEATGRID_MIN_BPM`].
    pub min_bpm: f64,
    /// Fastest beat tempo considered, BPM (default 240); greater than `min_bpm` and at most
    /// [`BEATGRID_MAX_BPM`].
    pub max_bpm: f64,
    /// Meter hint: beats per bar in 2..=[`BEATGRID_MAX_BEATS_PER_BAR`], or 0 to choose 3 or 4
    /// from the audio (default 0). Two-beat bars are only produced on request.
    pub beats_per_bar: u32,
    /// Must be 0.
    pub reserved: u32,
}

impl Default for BeatGridConfig {
    fn default() -> Self {
        BeatGridConfig {
            sample_rate_hz: 44_100,
            channels: 2,
            min_bpm: 40.0,
            max_bpm: 240.0,
            beats_per_bar: 0,
            reserved: 0,
        }
    }
}

/// Why a [`BeatGridConfig`] or PCM buffer was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BeatGridError {
    /// The named [`BeatGridConfig`] field is out of range.
    InvalidConfig(&'static str),
    /// The interleaved sample count is not a multiple of `channels`.
    InvalidLength,
}

impl BeatGridConfig {
    /// Checks every field against its documented range; `Err` names the first bad field.
    pub fn validate(&self) -> Result<(), BeatGridError> {
        let field = BeatGridError::InvalidConfig;
        if !(BEATGRID_MIN_SAMPLE_RATE_HZ..=BEATGRID_MAX_SAMPLE_RATE_HZ)
            .contains(&self.sample_rate_hz)
        {
            return Err(field("sample_rate_hz"));
        }
        if self.channels == 0 {
            return Err(field("channels"));
        }
        if !(self.min_bpm >= BEATGRID_MIN_BPM && self.min_bpm < BEATGRID_MAX_BPM) {
            return Err(field("min_bpm"));
        }
        if !(self.max_bpm > self.min_bpm && self.max_bpm <= BEATGRID_MAX_BPM) {
            return Err(field("max_bpm"));
        }
        if self.beats_per_bar == 1 || self.beats_per_bar > BEATGRID_MAX_BEATS_PER_BAR {
            return Err(field("beats_per_bar"));
        }
        if self.reserved != 0 {
            return Err(field("reserved"));
        }
        Ok(())
    }
}

/// One beat of a grid.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GridBeat {
    /// Beat time from the start of the PCM, seconds.
    pub time_s: f64,
    /// Local tempo at this beat from the neighbouring beat intervals, BPM.
    pub tempo_bpm: f64,
    /// Position in the bar, 0 at the downbeat (as in [`crate::dsp::Beat::beat_in_bar`]).
    pub beat_in_bar: u32,
    /// Bar counter: 0 for the first (possibly partial) bar, incremented at every downbeat after
    /// the first beat.
    pub bar_index: u32,
}

/// Summary of a grid.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct BeatGridInfo {
    /// Beats in the grid.
    pub beat_count: usize,
    /// Downbeats in the grid.
    pub bar_count: usize,
    /// Meter used: the hint, or the one chosen from the audio; 0 for an empty grid.
    pub beats_per_bar: u32,
    /// Global tempo, BPM; 0 for an empty grid.
    pub tempo_bpm: f64,
    /// Periodicity of the onset envelope at the global beat period, 0..=1: the normalised
    /// autocorrelation at that lag. Low values mean a weak or absent pulse.
    pub confidence: f64,
    /// Length of the analysed PCM, seconds.
    pub duration_s: f64,
}

/// Musical position at one media time, from [`BeatGrid::clock`].
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct BeatClock {
    /// Progress from the current beat to the next, in `[0, 1)`.
    pub beat_phase: f64,
    /// Progress through the current bar, in `[0, 1)`: `(beat_in_bar + beat_phase) /
    /// beats_per_bar`.
    pub bar_phase: f64,
    /// Local tempo of the current beat, BPM; 0 when the grid has fewer than two beats.
    pub tempo_bpm: f64,
    /// Index of the current beat. Before the first beat and after the last the grid is
    /// extrapolated at the first and last beat interval, so the index is negative before the
    /// first beat and keeps counting after the last; −1 when the grid has fewer than two beats.
    pub beat_index: i64,
    /// Position of the current beat in its bar, 0 at the downbeat.
    pub beat_in_bar: u32,
    /// Always 0; keeps the struct free of tail padding.
    pub reserved: u32,
}

/// Analysis constants chosen on development data (not a stable API).
#[doc(hidden)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Tuning {
    /// Envelope normalisation half-window, seconds.
    pub norm_half_s: f64,
    /// Weight of the low-band envelope in the beat-tracking envelope.
    pub low_weight: f64,
    /// Tempo prior centre, BPM.
    pub prior_bpm: f64,
    /// Tempo prior width, octaves.
    pub prior_octaves: f64,
    /// Tempogram window half-length, seconds.
    pub path_half_s: f64,
    /// Largest local tempo deviation from the global tempo, as a ratio.
    pub path_span: f64,
    /// Tempo path cost per squared octave of change between tempogram frames.
    pub path_change: f64,
    /// Tempo path cost per squared octave from the global tempo.
    pub path_pull: f64,
    /// Beat-interval tightness of the dynamic programme.
    pub tightness: f64,
    /// Weight of the harmonic-change downbeat cue.
    pub down_harmonic: f64,
    /// Weight of the low-band downbeat cue.
    pub down_low: f64,
    /// Cost of an irregular bar position.
    pub down_jump: f64,
    /// Constant added to every beat time, seconds (onset-to-beat latency of the envelope).
    pub offset_s: f64,
}

impl Default for Tuning {
    fn default() -> Self {
        Tuning {
            norm_half_s: 1.0,
            low_weight: 1.0,
            prior_bpm: 140.0,
            prior_octaves: 2.0,
            path_half_s: 4.0,
            path_span: 2.0,
            path_change: 4.0,
            path_pull: 1.0,
            tightness: 100.0,
            down_harmonic: 1.0,
            down_low: 1.0,
            down_jump: 4.0,
            offset_s: 0.009,
        }
    }
}

/// An immutable beat and downbeat grid for one file.
#[derive(Clone, Debug, PartialEq)]
pub struct BeatGrid {
    beats: Vec<GridBeat>,
    info: BeatGridInfo,
}

/// Mixes interleaved `samples` to mono `f64`, with non-finite samples read as silence.
fn mono(samples: &[f32], channels: usize) -> Vec<f64> {
    samples
        .chunks_exact(channels)
        .map(|frame| {
            let mut s = 0.0;
            for &v in frame {
                if v.is_finite() {
                    s += f64::from(v);
                }
            }
            s / channels as f64
        })
        .collect()
}

impl BeatGrid {
    /// Analyses interleaved `samples` (`config.channels` per frame) at `config.sample_rate_hz`.
    /// Non-finite samples are read as silence. Audio without a detectable pulse gives an empty
    /// grid, not an error.
    pub fn analyse(config: &BeatGridConfig, samples: &[f32]) -> Result<BeatGrid, BeatGridError> {
        Self::analyse_tuned(config, samples, &Tuning::default())
    }

    #[doc(hidden)]
    pub fn analyse_tuned(
        config: &BeatGridConfig,
        samples: &[f32],
        tuning: &Tuning,
    ) -> Result<BeatGrid, BeatGridError> {
        config.validate()?;
        let channels = config.channels as usize;
        if samples.len() % channels != 0 {
            return Err(BeatGridError::InvalidLength);
        }
        let features = onset::features(&mono(samples, channels), config.sample_rate_hz);
        Ok(Self::from_features(
            &features,
            config,
            tuning,
            samples.len() / channels,
        ))
    }

    fn from_features(
        f: &onset::Features,
        config: &BeatGridConfig,
        t: &Tuning,
        frames_in: usize,
    ) -> BeatGrid {
        let duration_s = frames_in as f64 / f.rate;
        let empty = BeatGrid {
            beats: Vec::new(),
            info: BeatGridInfo {
                duration_s,
                ..BeatGridInfo::default()
            },
        };
        let fps = f.fps();
        let lo = 60.0 * fps / config.max_bpm;
        let hi = 60.0 * fps / config.min_bpm;
        // at least four slowest beat periods of audio
        if (f.frames() as f64) < 4.0 * hi || lo < 2.0 {
            return empty;
        }
        let half = libm::round(t.norm_half_s * fps) as usize;
        let broad = tempo::normalise(&f.flux, half);
        let low = tempo::normalise(&f.low, half);
        let r = tempo::autocorrelation(&broad, libm::ceil(4.0 * hi) as usize + 2);
        if r[0] == 0.0 {
            return empty;
        }
        let global = tempo::global_period(&r, lo, hi, 60.0 * fps / t.prior_bpm, t.prior_octaves);
        let path = tempo::tempo_path(
            &broad,
            global,
            lo,
            hi,
            &tempo::PathParams {
                half: libm::round(t.path_half_s * fps) as usize,
                hop: (libm::round(fps / 2.0) as usize).max(1),
                span: t.path_span,
                change: t.path_change,
                pull: t.path_pull,
            },
        );
        let env: Vec<f64> = broad
            .iter()
            .zip(&low)
            .map(|(b, l)| b + t.low_weight * l)
            .collect();
        let frames = track::track(&env, &path, t.tightness);
        if frames.len() < 2 {
            return empty;
        }
        let times: Vec<f64> = frames
            .iter()
            .map(|&b| track::refine(&env, b, 2) / fps + t.offset_s)
            .collect();
        let cue = meter::cue(
            &frames,
            &f.chroma,
            &low,
            &meter::MeterParams {
                harmonic: t.down_harmonic,
                low: t.down_low,
            },
        );
        let (meter, positions) = if config.beats_per_bar >= 2 {
            let m = config.beats_per_bar as usize;
            (m, meter::decode(&cue, m, t.down_jump).0)
        } else {
            let mut best = (0, Vec::new(), f64::MIN);
            // duple bars of two beats read as half of a 4-beat bar; meter 2 needs a hint
            for m in [4usize, 3] {
                let (p, c) = meter::decode(&cue, m, t.down_jump);
                if c > best.2 {
                    best = (m, p, c);
                }
            }
            (best.0, best.1)
        };
        let n = times.len();
        let mut beats = Vec::with_capacity(n);
        let mut bar = 0u32;
        let mut bars = 0usize;
        for i in 0..n {
            if positions[i] == 0 {
                bars += 1;
                if i > 0 {
                    bar += 1;
                }
            }
            let span = if i == 0 {
                times[1] - times[0]
            } else if i + 1 == n {
                times[i] - times[i - 1]
            } else {
                0.5 * (times[i + 1] - times[i - 1])
            };
            beats.push(GridBeat {
                time_s: times[i],
                tempo_bpm: if span > 0.0 { 60.0 / span } else { 0.0 },
                beat_in_bar: positions[i],
                bar_index: bar,
            });
        }
        let confidence = tempo::at(&r, global).clamp(0.0, 1.0);
        BeatGrid {
            beats,
            info: BeatGridInfo {
                beat_count: n,
                bar_count: bars,
                beats_per_bar: meter as u32,
                tempo_bpm: 60.0 * fps / global,
                confidence,
                duration_s,
            },
        }
    }

    /// The beats, in time order.
    pub fn beats(&self) -> &[GridBeat] {
        &self.beats
    }

    /// The grid summary.
    pub fn info(&self) -> BeatGridInfo {
        self.info
    }

    /// The musical position at `media_time_s` seconds from the start of the PCM. It does not
    /// allocate. A grid with fewer than two beats, or a non-finite time, gives the default
    /// clock with `beat_index` −1.
    pub fn clock(&self, media_time_s: f64) -> BeatClock {
        let b = &self.beats;
        let n = b.len();
        let meter = self.info.beats_per_bar.max(1);
        if n < 2 || !media_time_s.is_finite() {
            return BeatClock {
                beat_index: -1,
                ..BeatClock::default()
            };
        }
        let t = media_time_s;
        let wrap = |pos: i64| pos.rem_euclid(i64::from(meter)) as u32;
        // (beat index, its time, interval to the next beat, bar position, tempo)
        let (index, start, interval, in_bar, tempo) = if t < b[0].time_s {
            let iv = b[1].time_s - b[0].time_s;
            let k = libm::floor((t - b[0].time_s) / iv);
            let pos = wrap(i64::from(b[0].beat_in_bar) + k as i64);
            (k as i64, b[0].time_s + k * iv, iv, pos, b[0].tempo_bpm)
        } else if t >= b[n - 1].time_s {
            let iv = b[n - 1].time_s - b[n - 2].time_s;
            let k = libm::floor((t - b[n - 1].time_s) / iv);
            // `k as i64` saturates for absurd times, so the sums must too.
            let pos = wrap(i64::from(b[n - 1].beat_in_bar).saturating_add(k as i64));
            let tempo = b[n - 1].tempo_bpm;
            (
                ((n - 1) as i64).saturating_add(k as i64),
                b[n - 1].time_s + k * iv,
                iv,
                pos,
                tempo,
            )
        } else {
            // b[lo].time_s <= t < b[hi].time_s
            let (mut lo, mut hi) = (0, n - 1);
            while hi - lo > 1 {
                let mid = lo + (hi - lo) / 2;
                if b[mid].time_s <= t {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
            let iv = b[lo + 1].time_s - b[lo].time_s;
            (
                lo as i64,
                b[lo].time_s,
                iv,
                b[lo].beat_in_bar,
                b[lo].tempo_bpm,
            )
        };
        let below_one = 1.0 - f64::EPSILON / 2.0;
        let phase = if interval > 0.0 {
            ((t - start) / interval).clamp(0.0, below_one)
        } else {
            0.0
        };
        BeatClock {
            beat_phase: phase,
            bar_phase: ((f64::from(in_bar % meter) + phase) / f64::from(meter)).min(below_one),
            tempo_bpm: tempo,
            beat_index: index,
            beat_in_bar: in_bar,
            reserved: 0,
        }
    }
}

/// Development access to the stages (not a stable API).
#[doc(hidden)]
pub mod dev {
    use super::*;

    /// Onset features of a whole file.
    pub struct Onsets {
        f: onset::Features,
        frames_in: usize,
    }

    impl Onsets {
        /// Frames per second.
        pub fn fps(&self) -> f64 {
            self.f.fps()
        }
        /// Broadband flux.
        pub fn flux(&self) -> &[f64] {
            &self.f.flux
        }
        /// Low-band flux.
        pub fn low(&self) -> &[f64] {
            &self.f.low
        }
        /// Pitch-class profiles.
        pub fn chroma(&self) -> &[[f64; 12]] {
            &self.f.chroma
        }
    }

    /// Mixes interleaved `samples` to mono and computes the onset features.
    pub fn onsets(samples: &[f32], channels: usize, rate: u32) -> Onsets {
        Onsets {
            f: onset::features(&mono(samples, channels), rate),
            frames_in: samples.len() / channels,
        }
    }

    /// The grid from precomputed features.
    pub fn grid(on: &Onsets, config: &BeatGridConfig, tuning: &Tuning) -> BeatGrid {
        BeatGrid::from_features(&on.f, config, tuning, on.frames_in)
    }

    /// Normalised envelope.
    pub fn normalise(flux: &[f64], half: usize) -> Vec<f64> {
        tempo::normalise(flux, half)
    }

    /// Autocorrelation.
    pub fn autocorrelation(x: &[f64], max_lag: usize) -> Vec<f64> {
        tempo::autocorrelation(x, max_lag)
    }

    /// DP tracker.
    pub fn track(env: &[f64], period: &[f64], tightness: f64) -> Vec<usize> {
        track::track(env, period, tightness)
    }

    /// Sub-frame envelope peak within `±reach` frames of frame `b`.
    pub fn refine(env: &[f64], b: usize, reach: usize) -> f64 {
        track::refine(env, b, reach)
    }
}
