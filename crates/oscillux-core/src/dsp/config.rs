// SPDX-License-Identifier: AGPL-3.0-only
//! Analysis parameters. Every numeric constant of the analysis lives here.

use super::DspError;

/// Largest `spectrum_bands` a frame can carry.
pub const MAX_BANDS: usize = 64;
/// Number of onset band groups (low, mid, high).
pub const ONSET_GROUPS: usize = 3;

const MAX_FFT_WINDOW: u32 = 1 << 16;
const MAX_RMS_WINDOW_SAMPLES: f64 = (1u64 << 24) as f64;

/// DSP behaviour version 1: the original analysis, frozen bit for bit by `conformance/dsp`.
pub const DSP_BEHAVIOR_V1: u32 = 1;
/// DSP behaviour version 2: disjoint triangular band weights with a decimated bass analysis,
/// energy-flux onsets with an absolute floor, and a cheaper hop (`conformance/dsp/v2`).
pub const DSP_BEHAVIOR_V2: u32 = 2;
/// DSP behaviour version 3: the version 2 analysis with the version 3 beat tracker
/// (`conformance/dsp/music/README.md`, "Beat tracker, version 3"). Frames equal version 2 bit for
/// bit; only the beat outputs differ.
pub const DSP_BEHAVIOR_V3: u32 = 3;
/// DSP behaviour version 4: the version 2 analysis with the version 4 beat tracker, a causal
/// beat-pointer model reported at the frame's media time (`conformance/dsp/music/README.md`,
/// "Beat tracker, version 4"). Frames equal version 2 bit for bit; only the beat outputs differ.
pub const DSP_BEHAVIOR_V4: u32 = 4;

// Version 2 algorithm constants (conformance/dsp/README.md, "Behaviour version 2").
/// Onset normaliser lower bound: flux below 1e-3 reads at most 0.1.
pub(crate) const V2_ONSET_FLOOR: f64 = 0.01;
/// Samples per RMS block sum.
pub(crate) const V2_RMS_BLOCK: u64 = 64;
/// Highest decimated bass sample rate, Hz.
pub(crate) const V2_BASS_RATE_HZ: u64 = 6000;
/// Bass window length at the full decimated rate, decimated samples.
pub(crate) const V2_BASS_WINDOW: f64 = 1024.0;
/// Order of the CIC (cascaded boxcar) decimation filter.
pub(crate) const V2_BASS_CIC_ORDER: u32 = 4;
/// A band reads the bass spectrum only below this fraction of the decimated rate...
pub(crate) const V2_BASS_TOP_FRACTION: f64 = 0.1;
/// ...and only when it is narrower than this many main FFT bins (the Hann main lobe).
pub(crate) const V2_BASS_MAX_MAIN_BINS: f64 = 4.0;
/// Largest decimation factor; above `6000 · 256` Hz the bass analysis is off.
pub(crate) const V2_BASS_MAX_DECIMATION: u64 = 256;

/// Analysis parameters. [`DspConfig::default`] is the reference configuration.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DspConfig {
    /// Input sample rate of the mono signal.
    pub sample_rate_hz: u32,
    /// Hann window and FFT length; a power of two.
    pub fft_window_samples: u32,
    /// Samples between frames.
    pub hop_samples: u32,
    /// Number of log-spaced bands between `spectrum_min_hz` and `spectrum_max_hz`.
    pub spectrum_bands: u32,
    /// Lower edge of the bottom band, Hz; positive.
    pub spectrum_min_hz: f64,
    /// Upper edge of the top band; at most the Nyquist frequency `sample_rate_hz / 2`.
    pub spectrum_max_hz: f64,
    /// Band level mapped to 0; 0 dB maps to 1.
    pub db_floor: f64,
    /// Band smoothing time constant while rising.
    pub ballistics_attack_ms: f64,
    /// Band smoothing time constant while falling.
    pub ballistics_release_ms: f64,
    /// RMS window ending at each analysis-window end.
    pub rms_window_ms: f64,
    /// Subtracted from `20·log10(rms)` to give `loudness_db`.
    pub loudness_reference_lufs: f64,
    /// RMS lower bound before taking the logarithm.
    pub rms_floor: f64,
    /// Per-frame decay of the running onset peaks.
    pub onset_peak_decay: f64,
    /// Lower bound of an onset peak used as a divisor.
    pub onset_peak_floor: f64,
    /// Inclusive band index ranges for the low, mid and high onsets.
    pub onset_band_groups: [[u32; 2]; ONSET_GROUPS],
    /// A segment starting more than this many hops after the expected time is flagged as a gap.
    pub gap_tolerance_hops: u32,
}

impl Default for DspConfig {
    fn default() -> Self {
        DspConfig {
            sample_rate_hz: 48_000,
            fft_window_samples: 2048,
            hop_samples: 512,
            spectrum_bands: 24,
            spectrum_min_hz: 40.0,
            spectrum_max_hz: 16_000.0,
            db_floor: -90.0,
            ballistics_attack_ms: 10.0,
            ballistics_release_ms: 200.0,
            rms_window_ms: 300.0,
            loudness_reference_lufs: -18.0,
            rms_floor: 1e-9,
            onset_peak_decay: 0.995,
            onset_peak_floor: 1e-9,
            onset_band_groups: [[0, 7], [8, 15], [16, 23]],
            gap_tolerance_hops: 1,
        }
    }
}

/// A configuration and the behaviour version that interprets it.
///
/// [`DspSettings::default`] is the reference configuration at [`DSP_BEHAVIOR_V2`]. Converting a
/// bare [`DspConfig`] selects [`DSP_BEHAVIOR_V1`], so existing callers keep version 1 exactly.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DspSettings {
    /// Analysis parameters, shared by every behaviour version.
    pub config: DspConfig,
    /// [`DSP_BEHAVIOR_V1`], [`DSP_BEHAVIOR_V2`], [`DSP_BEHAVIOR_V3`] or [`DSP_BEHAVIOR_V4`].
    pub behavior_version: u32,
}

impl Default for DspSettings {
    fn default() -> Self {
        DspSettings {
            config: DspConfig::default(),
            behavior_version: DSP_BEHAVIOR_V2,
        }
    }
}

impl From<DspConfig> for DspSettings {
    fn from(config: DspConfig) -> Self {
        DspSettings {
            config,
            behavior_version: DSP_BEHAVIOR_V1,
        }
    }
}

impl From<&DspConfig> for DspSettings {
    fn from(config: &DspConfig) -> Self {
        DspSettings::from(*config)
    }
}

impl From<&DspSettings> for DspSettings {
    fn from(settings: &DspSettings) -> Self {
        *settings
    }
}

impl DspSettings {
    /// Checks the configuration, then the behaviour version; names the first field refused.
    pub fn validate(&self) -> Result<(), DspError> {
        self.config.validate()?;
        match self.behavior_version {
            DSP_BEHAVIOR_V1 | DSP_BEHAVIOR_V2 | DSP_BEHAVIOR_V3 | DSP_BEHAVIOR_V4 => Ok(()),
            _ => Err(DspError::InvalidConfig("behavior_version")),
        }
    }
}

impl DspConfig {
    /// Samples in the RMS window (truncated), as the reference computes it.
    pub fn rms_window_samples(&self) -> usize {
        self.rms_window_exact() as usize
    }

    /// Hop duration in milliseconds.
    pub fn hop_ms(&self) -> f64 {
        self.hop_samples as f64 / self.sample_rate_hz as f64 * 1000.0
    }

    /// Checks every field; names the first one out of range.
    pub fn validate(&self) -> Result<(), DspError> {
        let rms_window = self.rms_window_exact();
        let checks: [(bool, &'static str); 15] = [
            (self.sample_rate_hz > 0, "sample_rate_hz"),
            (self.fft_window_valid(), "fft_window_samples"),
            (self.hop_samples > 0, "hop_samples"),
            (self.bands_valid(), "spectrum_bands"),
            (positive(self.spectrum_min_hz), "spectrum_min_hz"),
            (self.max_hz_valid(), "spectrum_max_hz"),
            (negative(self.db_floor), "db_floor"),
            (positive(self.ballistics_attack_ms), "ballistics_attack_ms"),
            (
                positive(self.ballistics_release_ms),
                "ballistics_release_ms",
            ),
            (rms_window >= 1.0, "rms_window_ms"),
            (rms_window <= MAX_RMS_WINDOW_SAMPLES, "rms_window_ms"),
            (
                self.loudness_reference_lufs.is_finite(),
                "loudness_reference_lufs",
            ),
            (positive(self.rms_floor), "rms_floor"),
            (self.decay_valid(), "onset_peak_decay"),
            (positive(self.onset_peak_floor), "onset_peak_floor"),
        ];
        let failed = checks.iter().find(|(ok, _)| !ok);
        let groups_ok = self.groups_valid();
        match (failed, groups_ok) {
            (Some((_, field)), _) => Err(DspError::InvalidConfig(field)),
            (None, false) => Err(DspError::InvalidConfig("onset_band_groups")),
            (None, true) => Ok(()),
        }
    }

    fn rms_window_exact(&self) -> f64 {
        let samples = self.sample_rate_hz as f64 * self.rms_window_ms / 1000.0;
        if samples.is_finite() {
            libm::trunc(samples)
        } else {
            0.0
        }
    }

    fn fft_window_valid(&self) -> bool {
        let n = self.fft_window_samples;
        n.is_power_of_two() && (2..=MAX_FFT_WINDOW).contains(&n)
    }

    fn bands_valid(&self) -> bool {
        (1..=MAX_BANDS as u32).contains(&self.spectrum_bands)
    }

    /// Bands above Nyquist would read no FFT bins and stay at 0, so they are rejected rather than
    /// clamped: clamping would silently move every log-spaced band edge, and with it the meaning
    /// of each band index and onset group. The Nyquist bin itself is a valid band edge.
    fn max_hz_valid(&self) -> bool {
        let nyquist = self.sample_rate_hz as f64 / 2.0;
        self.spectrum_max_hz.is_finite()
            && self.spectrum_max_hz > self.spectrum_min_hz
            && self.spectrum_max_hz <= nyquist
    }

    fn decay_valid(&self) -> bool {
        (0.0..=1.0).contains(&self.onset_peak_decay)
    }

    fn groups_valid(&self) -> bool {
        let bands = self.spectrum_bands;
        self.onset_band_groups
            .iter()
            .all(|[start, end]| start <= end && *end < bands)
    }
}

fn positive(v: f64) -> bool {
    v.is_finite() && v > 0.0
}

fn negative(v: f64) -> bool {
    v.is_finite() && v < 0.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_valid_and_matches_reference_window() {
        let cfg = DspConfig::default();
        assert_eq!(cfg.validate(), Ok(()));
        assert_eq!(cfg.rms_window_samples(), 14_400);
    }

    #[test]
    fn rejects_top_band_above_nyquist() {
        let low_rate = DspConfig {
            sample_rate_hz: 22_050,
            ..DspConfig::default()
        };
        assert_eq!(
            low_rate.validate(),
            Err(DspError::InvalidConfig("spectrum_max_hz"))
        );
        let at_nyquist = DspConfig {
            spectrum_max_hz: 11_025.0,
            ..low_rate
        };
        assert_eq!(at_nyquist.validate(), Ok(()));
        let just_above = DspConfig {
            spectrum_max_hz: f64::from_bits(11_025f64.to_bits() + 1),
            ..low_rate
        };
        assert_eq!(
            just_above.validate(),
            Err(DspError::InvalidConfig("spectrum_max_hz"))
        );
    }

    #[test]
    fn defaults_are_valid_at_44_1_khz() {
        let cfg = DspConfig {
            sample_rate_hz: 44_100,
            ..DspConfig::default()
        };
        assert_eq!(cfg.validate(), Ok(()));
        assert_eq!(cfg.rms_window_samples(), 13_230);
    }

    #[test]
    fn rejects_non_power_of_two_window() {
        let cfg = DspConfig {
            fft_window_samples: 2000,
            ..DspConfig::default()
        };
        assert_eq!(
            cfg.validate(),
            Err(DspError::InvalidConfig("fft_window_samples"))
        );
    }

    #[test]
    fn bare_config_selects_version_1_and_settings_default_to_version_2() {
        let settings = DspSettings::from(DspConfig::default());
        assert_eq!(settings.behavior_version, DSP_BEHAVIOR_V1);
        assert_eq!(DspSettings::default().behavior_version, DSP_BEHAVIOR_V2);
        assert_eq!(DspSettings::default().config, DspConfig::default());
        for version in [0, 5, u32::MAX] {
            let settings = DspSettings {
                behavior_version: version,
                ..DspSettings::default()
            };
            assert_eq!(
                settings.validate(),
                Err(DspError::InvalidConfig("behavior_version"))
            );
        }
        let both_bad = DspSettings {
            config: DspConfig {
                hop_samples: 0,
                ..DspConfig::default()
            },
            behavior_version: 0,
        };
        assert_eq!(
            both_bad.validate(),
            Err(DspError::InvalidConfig("hop_samples"))
        );
    }

    #[test]
    fn rejects_group_past_last_band() {
        let cfg = DspConfig {
            onset_band_groups: [[0, 7], [8, 15], [16, 24]],
            ..DspConfig::default()
        };
        assert_eq!(
            cfg.validate(),
            Err(DspError::InvalidConfig("onset_band_groups"))
        );
    }
}
