// SPDX-License-Identifier: AGPL-3.0-only
//! Reference audio analysis: PCM in, per-hop RMS, loudness, log-spaced band energies and onsets out.
//!
//! [`Analyzer`] is the streaming form: it allocates once in [`Analyzer::new`] and never again.
//! [`analyze_pcm_chunks`] and [`analyze_wav`] are offline conveniences built on it.
//! [`BeatTracker`] and [`Agc`] are optional stages that consume its frames; every analyzer also
//! runs one of each with its default configuration and reports them in [`FrameExt`].
//!
//! [`DspSettings`] pairs a [`DspConfig`] with a behaviour version. A bare [`DspConfig`] selects
//! [`DSP_BEHAVIOR_V1`], frozen bit for bit; [`DspSettings::default`] selects [`DSP_BEHAVIOR_V2`].
//! [`DSP_BEHAVIOR_V3`] and [`DSP_BEHAVIOR_V4`] keep the version 2 frames and change only the beat
//! tracker.

mod agc;
mod analyzer;
mod beat;
mod beat_v4;
mod config;
mod descriptors;
mod features;
mod fft;
mod offline;
mod v2;
mod wav;

pub use agc::{Agc, AgcConfig, Levels};
pub use analyzer::{Analyzer, PushResult};
pub use beat::{
    Beat, BeatConfig, BeatTracker, BEAT_LATENCY_V1_MS, BEAT_LATENCY_V2_MS, BEAT_LATENCY_V3_MS,
    BEAT_LATENCY_V4_MS, MAX_BEATS_PER_BAR,
};
#[doc(hidden)]
pub use beat_v4::V4Tuning;
pub use config::{
    DspConfig, DspSettings, DSP_BEHAVIOR_V1, DSP_BEHAVIOR_V2, DSP_BEHAVIOR_V3, DSP_BEHAVIOR_V4,
    MAX_BANDS, ONSET_GROUPS,
};
pub use descriptors::{
    channel_weight, k_weighting, Biquad, Descriptors, DESCRIPTOR_MAX_CHANNELS,
    LOUDNESS_MIN_RATE_HZ, LUFS_FLOOR,
};
pub use offline::{analyze_pcm_chunks, analyze_wav, PcmChunk};
pub use wav::decode_wav_mono;

/// Frame flag: this segment started later than one gap tolerance after the previous frame.
pub const FLAG_GAP: u32 = 1;
/// Frame flag: the host marked this segment as following a stalled capture.
pub const FLAG_STALLED: u32 = 2;
/// Frame flag: a sample since the previous frame was non-finite or beyond `f32` range and was
/// replaced with 0.
pub const FLAG_INPUT_REPLACED: u32 = 4;

/// Onset strengths in `[0, 1]`: broadband and the three configured band groups.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Onset {
    /// Onset across every band.
    pub broadband: f64,
    /// Onset of the first band group.
    pub low: f64,
    /// Onset of the second band group.
    pub mid: f64,
    /// Onset of the third band group.
    pub high: f64,
}

/// One analysis frame, emitted every hop once a full window is available.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DspFrame {
    /// Frame index since the analyzer was created.
    pub sequence: u64,
    /// `FLAG_*` bits. `FLAG_GAP` and `FLAG_STALLED` are set only on the first frame of a segment.
    pub flags: u32,
    /// Number of valid entries in `spectrum`.
    pub band_count: u32,
    /// Media time of the analysis-window end, in milliseconds.
    pub media_time_ms: f64,
    /// Root mean square over the RMS window ending at the analysis-window end.
    pub rms: f64,
    /// `20·log10(rms)` relative to the configured loudness reference.
    pub loudness_db: f64,
    /// Onset strengths.
    pub onset: Onset,
    /// Smoothed band energies in `[0, 1]`; entries past `band_count` are zero.
    pub spectrum: [f64; MAX_BANDS],
}

impl DspFrame {
    /// An all-zero frame, for initialising caller-owned output buffers.
    pub const ZERO: DspFrame = DspFrame {
        sequence: 0,
        flags: 0,
        band_count: 0,
        media_time_ms: 0.0,
        rms: 0.0,
        loudness_db: 0.0,
        onset: Onset {
            broadband: 0.0,
            low: 0.0,
            mid: 0.0,
            high: 0.0,
        },
        spectrum: [0.0; MAX_BANDS],
    };

    /// The valid part of `spectrum`.
    pub fn bands(&self) -> &[f64] {
        &self.spectrum[..self.band_count as usize]
    }
}

/// Opt-in outputs written beside each [`DspFrame`] by [`Analyzer::push_ext`]. The analyzer
/// computes them for every frame, so choosing a push variant never changes any output.
/// Later sections are appended; existing ones never move or change meaning.
#[non_exhaustive]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FrameExt {
    /// Loudness, stereo and spectral descriptors.
    pub descriptors: Descriptors,
    /// A [`BeatTracker`] with [`BeatConfig::for_version`] of the analyzer's behaviour version run
    /// on the analyzer's frames; all zero when the analyzer's frame rate puts that tempo range
    /// outside the tracker's period limits.
    pub beat: Beat,
    /// An [`Agc`] with [`AgcConfig::default`] run on the analyzer's frames; all zero when the
    /// analyzer's `db_floor` is too shallow for that configuration.
    pub levels: Levels,
}

impl FrameExt {
    /// All zeros, for initialising caller-owned output buffers.
    pub const ZERO: FrameExt = FrameExt {
        descriptors: Descriptors::ZERO,
        beat: Beat::ZERO,
        levels: Levels::ZERO,
    };
}

/// Why a configuration, a push or a WAV decode was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DspError {
    /// The named `DspConfig`, `BeatConfig` or `AgcConfig` field, or `behavior_version`, is out of
    /// range.
    InvalidConfig(&'static str),
    /// `channels` is zero or does not divide the interleaved sample count.
    InvalidChannels,
    /// The WAV input is malformed or unsupported; the text says how.
    Wav(&'static str),
}
