// SPDX-License-Identifier: AGPL-3.0-only
//! Streaming analyzer: allocation happens in [`Analyzer::new`] only.

use alloc::vec;
use alloc::vec::Vec;

use super::agc::{Agc, AgcConfig, Levels};
use super::beat::{Beat, BeatConfig, BeatTracker};
use super::config::{DspConfig, DspSettings, DSP_BEHAVIOR_V1, MAX_BANDS};
use super::descriptors::DescriptorState;
use super::features::{band_levels, magnitudes, smooth, OnsetState, Tables};
use super::v2::{Recent, Scratch, V2};
use super::{DspError, DspFrame, FrameExt, Onset, FLAG_GAP, FLAG_INPUT_REPLACED, FLAG_STALLED};

/// Largest accepted sample magnitude: that of any finite `f32`. Every output stays finite below it.
pub(crate) const MAX_SAMPLE: f64 = f32::MAX as f64;

/// What one [`Analyzer::push`] call did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PushResult {
    /// Sample frames (one sample per channel) consumed from the input.
    pub consumed: usize,
    /// Analysis frames written to the output buffer.
    pub produced: usize,
}

/// A contiguous run of input. Analysis windows never span two segments.
struct Segment {
    media_start_ms: f64,
    stalled: bool,
    /// Samples received in this segment.
    samples: u64,
    /// Samples still needed before the next frame is due.
    until_frame: usize,
    /// Whether this segment has emitted a frame yet.
    emitted: bool,
    /// Whether a sample since the last frame was replaced with 0.
    replaced: bool,
}

/// Streaming reference analysis over mono (or mixed-down) PCM.
pub struct Analyzer {
    cfg: DspConfig,
    behavior_version: u32,
    tables: Tables,
    /// Version 2 state; `None` runs version 1.
    v2: Option<V2>,
    /// Ring buffer of the most recent `max(window, rms window, bass FIR taps)` samples.
    history: Vec<f64>,
    write: usize,
    segment: Segment,
    re: Vec<f64>,
    im: Vec<f64>,
    mags: Vec<f64>,
    raw_bands: [f64; MAX_BANDS],
    smoothed: [f64; MAX_BANDS],
    onset: OnsetState,
    sequence: u64,
    /// Media time the next segment should start at to be contiguous, once a frame exists.
    expected_next_ms: Option<f64>,
    /// Opt-in outputs, computed for every frame whichever push is used.
    descriptors: DescriptorState,
    /// Default beat tracker; `None` when the configuration's frame rate does not support it.
    beat: Option<BeatTracker>,
    /// Default level normaliser; `None` when the configuration's `db_floor` does not support it.
    agc: Option<Agc>,
    /// Extension outputs of the latest frame.
    ext: FrameExt,
}

impl Analyzer {
    /// Validates `settings` and allocates every buffer the analyzer will use.
    ///
    /// A bare [`DspConfig`] runs behaviour version 1; pass [`DspSettings`] to choose.
    pub fn new(settings: impl Into<DspSettings>) -> Result<Analyzer, DspError> {
        let settings = settings.into();
        settings.validate()?;
        let cfg = settings.config;
        let n = cfg.fft_window_samples as usize;
        let tables = Tables::new(&cfg);
        let v2 = (settings.behavior_version != DSP_BEHAVIOR_V1).then(|| V2::new(&cfg, &tables));
        let fir = v2.as_ref().map_or(0, V2::history_samples);
        let capacity = n.max(cfg.rms_window_samples()).max(fir);
        Ok(Analyzer {
            behavior_version: settings.behavior_version,
            tables,
            v2,
            history: vec![0.0; capacity],
            write: 0,
            segment: Segment::new(&cfg, 0.0, false),
            re: vec![0.0; n],
            im: vec![0.0; n],
            mags: vec![0.0; n / 2 + 1],
            raw_bands: [0.0; MAX_BANDS],
            smoothed: [0.0; MAX_BANDS],
            onset: OnsetState::new(),
            sequence: 0,
            expected_next_ms: None,
            descriptors: DescriptorState::new(&cfg),
            beat: BeatTracker::new(
                &settings,
                BeatConfig::for_version(settings.behavior_version),
            )
            .ok(),
            agc: Agc::new(&settings, AgcConfig::default()).ok(),
            ext: FrameExt::ZERO,
            cfg,
        })
    }

    /// The configuration this analyzer runs.
    pub fn config(&self) -> &DspConfig {
        &self.cfg
    }

    /// The behaviour version this analyzer runs.
    pub fn behavior_version(&self) -> u32 {
        self.behavior_version
    }

    /// Starts a new segment whose first sample plays at `media_start_ms`.
    ///
    /// Samples of the previous segment are no longer used for windows or RMS; smoothing and onset
    /// state carry over. The first frame of the new segment carries `FLAG_GAP` when it starts
    /// more than `gap_tolerance_hops` after the previous frame, and `FLAG_STALLED` when
    /// `stalled` is set. A segment that ends before its first frame leaves no trace.
    pub fn begin_segment(&mut self, media_start_ms: f64, stalled: bool) {
        self.segment = Segment::new(&self.cfg, media_start_ms, stalled);
        if let Some(v2) = &mut self.v2 {
            v2.begin_segment();
        }
        self.descriptors.begin_segment();
    }

    /// Consumes interleaved samples, mixing `channels` down by averaging, and writes one frame
    /// per completed hop into `out`. Stops early, before the sample that would complete a frame,
    /// when `out` is full; call again with the unconsumed rest.
    ///
    /// A sample that is NaN, infinite or larger in magnitude than any finite `f32` is replaced
    /// with 0, and the next frame carries `FLAG_INPUT_REPLACED`.
    pub fn push<S: Copy + Into<f64>>(
        &mut self,
        interleaved: &[S],
        channels: usize,
        out: &mut [DspFrame],
    ) -> Result<PushResult, DspError> {
        self.push_ext_with(interleaved, channels, out, |_, _| {})
    }

    /// [`Analyzer::push`] that also writes the extension outputs of `out[i]` to `ext[i]`. Only
    /// the first `min(out.len(), ext.len())` frames are written. Frames are bit-identical to
    /// those of [`Analyzer::push`], which computes the same extension state without returning it.
    pub fn push_ext<S: Copy + Into<f64>>(
        &mut self,
        interleaved: &[S],
        channels: usize,
        out: &mut [DspFrame],
        ext: &mut [FrameExt],
    ) -> Result<PushResult, DspError> {
        let capacity = out.len().min(ext.len());
        self.push_ext_with(
            interleaved,
            channels,
            &mut out[..capacity],
            |i, frame_ext| {
                ext[i] = *frame_ext;
            },
        )
    }

    /// [`Analyzer::push`] that passes the extension outputs of `out[i]` to `sink(i, ext)` as soon
    /// as the frame is written.
    pub fn push_ext_with<S: Copy + Into<f64>, F: FnMut(usize, &FrameExt)>(
        &mut self,
        interleaved: &[S],
        channels: usize,
        out: &mut [DspFrame],
        mut sink: F,
    ) -> Result<PushResult, DspError> {
        let valid = channels > 0 && interleaved.len() % channels == 0;
        if !valid {
            return Err(DspError::InvalidChannels);
        }
        let mut produced = 0;
        for (consumed, frame) in interleaved.chunks_exact(channels).enumerate() {
            if self.segment.until_frame == 1 && produced == out.len() {
                return Ok(PushResult { consumed, produced });
            }
            self.descriptors.accept(frame);
            let (sample, replaced) = mixdown(frame);
            self.segment.replaced |= replaced;
            if self.append(sample, &mut out[produced..]) == 1 {
                sink(produced, &self.ext);
                produced += 1;
            }
        }
        let consumed = interleaved.len() / channels;
        Ok(PushResult { consumed, produced })
    }

    /// Stores one sample; when it completes a hop, writes a frame to `out[0]` and returns 1.
    fn append(&mut self, sample: f64, out: &mut [DspFrame]) -> usize {
        self.history[self.write] = sample;
        self.write += 1;
        if self.write == self.history.len() {
            self.write = 0;
        }
        self.segment.samples += 1;
        if let Some(v2) = &mut self.v2 {
            let recent = Recent {
                history: &self.history,
                write: self.write,
                samples: self.segment.samples,
            };
            v2.accept(sample, &recent);
        }
        self.segment.until_frame -= 1;
        if self.segment.until_frame > 0 {
            return 0;
        }
        self.segment.until_frame = self.cfg.hop_samples as usize;
        self.emit(&mut out[0]);
        1
    }

    fn emit(&mut self, frame: &mut DspFrame) {
        let bands = self.cfg.spectrum_bands as usize;
        let (onset, rms) = match self.v2.as_mut() {
            Some(v2) => {
                let recent = Recent {
                    history: &self.history,
                    write: self.write,
                    samples: self.segment.samples,
                };
                let scratch = Scratch {
                    windowed: &mut self.re,
                    packed: &mut self.im,
                    mags: &mut self.mags,
                };
                let raw = &mut self.raw_bands[..bands];
                v2.analyze(&self.cfg, &self.tables, &recent, scratch, raw)
            }
            None => self.analyze_v1(bands),
        };
        smooth(
            &self.tables,
            &self.raw_bands[..bands],
            &mut self.smoothed[..bands],
        );
        let media_time_ms = self.segment.media_start_ms
            + self.segment.samples as f64 / self.cfg.sample_rate_hz as f64 * 1000.0;
        *frame = DspFrame {
            sequence: self.sequence,
            flags: self.frame_flags(),
            band_count: bands as u32,
            media_time_ms,
            rms,
            loudness_db: 20.0 * libm::log10(rms.max(self.cfg.rms_floor))
                - self.cfg.loudness_reference_lufs,
            onset,
            spectrum: self.smoothed,
        };
        self.ext.descriptors = self.descriptors.emit(&self.mags);
        self.ext.beat = self.beat.as_mut().map_or(Beat::ZERO, |b| b.update(frame));
        self.ext.levels = self.agc.as_mut().map_or(Levels::ZERO, |a| a.update(frame));
        self.sequence += 1;
        self.segment.emitted = true;
        self.segment.replaced = false;
        // Gap accounting uses the timestamp published by the reference (six decimals).
        let published_time_ms = libm::round(media_time_ms * 1_000_000.0) / 1_000_000.0;
        self.expected_next_ms = Some(published_time_ms + self.cfg.hop_ms());
    }

    /// Version 1 raw bands, onsets and RMS. Smoothing does not read onsets or RMS, so running
    /// it afterwards leaves every value as before.
    fn analyze_v1(&mut self, bands: usize) -> (Onset, f64) {
        self.transform();
        band_levels(
            &self.tables,
            self.cfg.db_floor,
            &self.mags,
            &mut self.raw_bands[..bands],
        );
        let onset = self.onset.update(&self.cfg, &self.raw_bands[..bands]);
        (onset, self.rms())
    }

    /// Windows the latest `fft_window_samples` samples and fills `mags`.
    fn transform(&mut self) {
        let (older, newer) = latest(&self.history, self.write, self.re.len());
        let samples = older.iter().chain(newer);
        for ((re, w), s) in self.re.iter_mut().zip(&self.tables.window).zip(samples) {
            *re = s * w;
        }
        self.im.fill(0.0);
        self.tables.fft.run(&mut self.re, &mut self.im);
        magnitudes(&self.re, &self.im, &mut self.mags);
    }

    /// RMS over the RMS window, clipped to the samples of the current segment.
    fn rms(&self) -> f64 {
        let count = self
            .segment
            .samples
            .min(self.cfg.rms_window_samples() as u64) as usize;
        let (older, newer) = latest(&self.history, self.write, count);
        let sum = older.iter().chain(newer).fold(0.0, |sum, s| sum + s * s);
        libm::sqrt(sum / count as f64)
    }

    fn frame_flags(&self) -> u32 {
        let replaced_bit = if self.segment.replaced {
            FLAG_INPUT_REPLACED
        } else {
            0
        };
        if self.segment.emitted {
            return replaced_bit;
        }
        let tolerance = self.cfg.gap_tolerance_hops as f64 * self.cfg.hop_ms();
        let gap = self
            .expected_next_ms
            .is_some_and(|expected| self.segment.media_start_ms - expected > tolerance);
        let gap_bit = if gap { FLAG_GAP } else { 0 };
        let stall_bit = if self.segment.stalled {
            FLAG_STALLED
        } else {
            0
        };
        gap_bit | stall_bit | replaced_bit
    }
}

impl Segment {
    fn new(cfg: &DspConfig, media_start_ms: f64, stalled: bool) -> Segment {
        Segment {
            media_start_ms,
            stalled,
            samples: 0,
            until_frame: cfg.fft_window_samples as usize,
            emitted: false,
            replaced: false,
        }
    }
}

/// The latest `count` samples of `ring`, whose next write index is `write`, oldest first, as
/// the ring's two contiguous runs. `count` is at most the ring length.
pub(crate) fn latest(ring: &[f64], write: usize, count: usize) -> (&[f64], &[f64]) {
    let (newer, older) = ring.split_at(write);
    let from_older = count.saturating_sub(newer.len());
    let from_newer = count - from_older;
    (
        &older[older.len() - from_older..],
        &newer[newer.len() - from_newer..],
    )
}

/// Average of one interleaved sample frame, summed in channel order, with samples outside
/// `±MAX_SAMPLE` (including NaN) counted as 0; the flag reports whether any were.
fn mixdown<S: Copy + Into<f64>>(frame: &[S]) -> (f64, bool) {
    let mut replaced = false;
    let sum = frame.iter().fold(0.0, |sum, s| {
        let s: f64 = (*s).into();
        if s.abs() <= MAX_SAMPLE {
            sum + s
        } else {
            replaced = true;
            sum
        }
    });
    (sum / frame.len() as f64, replaced)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rms_retains_full_history_beyond_the_32_bit_sample_boundary() {
        let mut analyzer = Analyzer::new(DspConfig::default()).unwrap();
        analyzer.history.fill(0.5);
        for samples in [1u64 << 32, (1u64 << 32) + 512] {
            analyzer.segment.samples = samples;
            assert_eq!(analyzer.rms(), 0.5);
        }
    }

    #[test]
    fn replaced_sample_flag_joins_segment_flags_and_dies_with_an_unemitted_segment() {
        let cfg = DspConfig::default();
        let mut analyzer = Analyzer::new(cfg).unwrap();
        let mut samples = vec![0.1; cfg.fft_window_samples as usize];
        samples[7] = f64::NAN;
        let mut out = [DspFrame::ZERO];
        analyzer.push(&samples[..100], 1, &mut out).unwrap();
        analyzer.begin_segment(0.0, true);
        analyzer.push(&samples, 1, &mut out).unwrap();
        assert_eq!(out[0].flags, FLAG_STALLED | FLAG_INPUT_REPLACED);
        samples[7] = 0.1;
        analyzer
            .push(&samples[..cfg.hop_samples as usize], 1, &mut out)
            .unwrap();
        assert_eq!(out[0].flags, 0);
        analyzer.push(&[f64::INFINITY], 1, &mut out).unwrap();
        analyzer.begin_segment(64.0, false);
        analyzer.push(&samples, 1, &mut out).unwrap();
        assert_eq!(out[0].flags, 0);
    }

    #[test]
    fn gap_threshold_uses_reference_published_timestamp() {
        let cfg = DspConfig::default();
        for (start, flags) in [(64.0000001, 0), (64.0000005, FLAG_GAP)] {
            let mut analyzer = Analyzer::new(cfg).unwrap();
            let samples = vec![0.0; cfg.fft_window_samples as usize];
            let mut out = [DspFrame::ZERO];
            analyzer.push(&samples, 1, &mut out).unwrap();
            analyzer.begin_segment(start, false);
            analyzer.push(&samples, 1, &mut out).unwrap();
            assert_eq!(out[0].flags, flags);
        }
    }
}
