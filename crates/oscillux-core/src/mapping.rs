// SPDX-License-Identifier: AGPL-3.0-only
//! DSP features to portable numeric inputs, including the stateful loudness envelope.

use crate::dsp::{Descriptors, DspConfig, DspFrame, Levels, MAX_BANDS};

/// Number of [`Mapped::values`].
pub const VALUE_COUNT: usize = 9;
/// Number of [`Mapped::spectrum`] bins.
pub const SPECTRUM_BINS: usize = 64;
/// Number of [`MappingConfig::groups`]: bass, mid, treble.
pub const GROUPS: usize = 3;
/// [`Mapped::values`] index: loudness between `db_floor` and 0 dB.
pub const AMPLITUDE: usize = 0;
/// [`Mapped::values`] index: amplitude with instant attack and exponential release.
pub const LEVEL: usize = 1;
/// [`Mapped::values`] index: mean band energy of `groups[0]`, or with
/// [`LevelSource::Relative`] the mean relative band level.
pub const BASS: usize = 2;
/// [`Mapped::values`] index: mean band energy of `groups[1]`, as [`BASS`].
pub const MID: usize = 3;
/// [`Mapped::values`] index: mean band energy of `groups[2]`, as [`BASS`].
pub const TREBLE: usize = 4;
/// [`Mapped::values`] index: broadband onset.
pub const ONSET: usize = 5;
/// [`Mapped::values`] index: low-band onset.
pub const BASS_IMPACT: usize = 6;
/// [`Mapped::values`] index: spectral flux.
///
/// With descriptors ([`Mapper::map_with`]) it is [`Descriptors::spectral_flux`] clamped to 0..1,
/// distinct from [`ONSET`]. Without them ([`Mapper::map`]) it keeps the reference's deprecated
/// proxy, the broadband onset, so it repeats [`ONSET`].
pub const FLUX: usize = 7;
/// [`Mapped::values`] index: spectral centroid.
///
/// With descriptors ([`Mapper::map_with`]) it is [`Descriptors::centroid_hz`] on a
/// log-frequency scale, `clamp01(log10(hz / 20) / 3)`, so 20 Hz maps to 0, 632.46 Hz to 0.5 and
/// 20 kHz to 1, or 0 when `hz` is at most 20. Without them ([`Mapper::map`]) it keeps the
/// reference's deprecated proxy, the energy-weighted band index as a fraction of the band range.
/// Both are 0 when the summed band energy is at or below [`MappingConfig::centroid_floor`].
pub const CENTROID: usize = 8;
/// Centroid frequency in Hz that [`CENTROID`] maps to 0.
pub const CENTROID_MIN_HZ: f64 = 20.0;
/// Decades above [`CENTROID_MIN_HZ`] that [`CENTROID`] spans, so 20 kHz maps to 1.
pub const CENTROID_DECADES: f64 = 3.0;

/// How [`Mapper`] turns DSP frames into normalized values.
///
/// `hop_seconds` and `loudness_reference` describe the analyzer that produces the frames; build
/// them with [`MappingConfig::for_dsp`] so they match its `DspConfig`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MappingConfig {
    /// The analyzer's `loudness_reference_lufs`, dB; added back to [`DspFrame::loudness_db`] to
    /// recover dBFS.
    pub loudness_reference: f64,
    /// Loudness in dB mapped to amplitude 0; negative.
    pub db_floor: f64,
    /// The analyzer's hop duration, `hop_samples / sample_rate_hz`, seconds.
    pub hop_seconds: f64,
    /// Level decay time constant in seconds.
    pub release_seconds: f64,
    /// Summed band energy at or below which the centroid is 0.
    pub centroid_floor: f64,
    /// Inclusive band index ranges for bass, mid and treble.
    pub groups: [[u32; 2]; GROUPS],
}
impl Default for MappingConfig {
    /// [`MappingConfig::for_dsp`] of [`DspConfig::default`].
    fn default() -> Self {
        Self::for_dsp(&DspConfig::default())
    }
}
impl MappingConfig {
    /// Default mapping whose hop duration and loudness reference are taken from `dsp`, so the
    /// level release time and the dBFS recovery hold at any sample rate or hop.
    pub fn for_dsp(dsp: &DspConfig) -> Self {
        Self {
            loudness_reference: dsp.loudness_reference_lufs,
            db_floor: -60.0,
            hop_seconds: dsp.hop_samples as f64 / dsp.sample_rate_hz as f64,
            release_seconds: 0.2,
            centroid_floor: 1e-6,
            groups: [[0, 7], [8, 15], [16, 23]],
        }
    }
}
/// Normalized values for one frame.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Mapped {
    /// Indexed by [`AMPLITUDE`] through [`CENTROID`].
    pub values: [f64; VALUE_COUNT],
    /// Band energies resampled linearly to [`SPECTRUM_BINS`] bins.
    pub spectrum: [f32; SPECTRUM_BINS],
}
impl Mapped {
    /// All zeros, the output for unavailable input.
    pub const ZERO: Self = Self {
        values: [0.0; VALUE_COUNT],
        spectrum: [0.0; SPECTRUM_BINS],
    };
}
/// C value of [`LevelSource::Absolute`].
pub const LEVELS_ABSOLUTE: u32 = 0;
/// C value of [`LevelSource::Relative`].
pub const LEVELS_RELATIVE: u32 = 1;
/// What [`BASS`], [`MID`], [`TREBLE`] and [`Mapped::spectrum`] are computed from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LevelSource {
    /// The frame's absolute band energies; the default, bit-identical to earlier releases.
    #[default]
    Absolute,
    /// [`Levels::relative_bands`], each band's level relative to its recent range, so mastered
    /// music keeps its contrast. [`AMPLITUDE`], [`LEVEL`], [`ONSET`], [`BASS_IMPACT`], [`FLUX`]
    /// and [`CENTROID`] still read the absolute frame and descriptors.
    Relative,
}
/// A configuration or frame was out of range.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MappingError;
/// Stateful mapper; the level envelope carries between frames.
#[derive(Clone, Debug)]
pub struct Mapper {
    config: MappingConfig,
    alpha: f64,
    previous: Option<f64>,
    source: LevelSource,
}
impl Mapper {
    /// Validates `config` and creates a mapper.
    pub fn new(config: MappingConfig) -> Result<Self, MappingError> {
        if ![
            config.loudness_reference,
            config.db_floor,
            config.hop_seconds,
            config.release_seconds,
            config.centroid_floor,
        ]
        .iter()
        .all(|v| v.is_finite())
            || config.db_floor >= 0.0
            || config.hop_seconds <= 0.0
            || config.release_seconds <= 0.0
            || config.centroid_floor < 0.0
            || config
                .groups
                .iter()
                .any(|[a, b]| a > b || *b as usize >= MAX_BANDS)
        {
            return Err(MappingError);
        }
        Ok(Self {
            alpha: 1.0 - libm::exp(-config.hop_seconds / config.release_seconds),
            config,
            previous: None,
            source: LevelSource::Absolute,
        })
    }
    /// Forgets the previous level; the level source is kept.
    pub fn reset(&mut self) {
        self.previous = None;
    }
    /// Selects the level source; [`LevelSource::Absolute`] until called.
    pub fn set_level_source(&mut self, source: LevelSource) {
        self.source = source;
    }
    /// The selected level source.
    pub fn level_source(&self) -> LevelSource {
        self.source
    }
    /// [`Mapper::map_with`] without descriptors: [`FLUX`] and [`CENTROID`] keep the reference's
    /// deprecated proxies, bit-identical to earlier releases.
    pub fn map(&mut self, frame: &DspFrame, unavailable: bool) -> Result<Mapped, MappingError> {
        self.map_with(frame, None, unavailable)
    }
    /// Maps `frame` and, when given, the [`Descriptors`] that `Analyzer::push_ext` wrote beside
    /// it, which feed [`FLUX`] and [`CENTROID`]; `None` keeps the deprecated proxies.
    ///
    /// Unavailable input maps to zero and retains a zero previous level, as in the reference.
    /// Finite validation failures, including a non-finite descriptor, leave the envelope
    /// unchanged. With [`LevelSource::Relative`] it refuses available input, which needs
    /// [`Mapper::map_ext`].
    pub fn map_with(
        &mut self,
        frame: &DspFrame,
        descriptors: Option<&Descriptors>,
        unavailable: bool,
    ) -> Result<Mapped, MappingError> {
        self.map_ext(frame, descriptors, None, unavailable)
    }
    /// [`Mapper::map_with`] that also takes the [`Levels`] that `Analyzer::push_ext` wrote
    /// beside `frame`. [`LevelSource::Absolute`] ignores them. [`LevelSource::Relative`] maps
    /// [`BASS`], [`MID`], [`TREBLE`] and the spectrum from [`Levels::relative_bands`] as the
    /// absolute path maps the band energies, and refuses available input whose levels are
    /// missing, whose `band_count` differs from the frame's or whose valid relative bands are
    /// not finite.
    pub fn map_ext(
        &mut self,
        frame: &DspFrame,
        descriptors: Option<&Descriptors>,
        levels: Option<&Levels>,
        unavailable: bool,
    ) -> Result<Mapped, MappingError> {
        if unavailable {
            self.previous = Some(0.0);
            return Ok(Mapped::ZERO);
        }
        if frame.band_count as usize > MAX_BANDS
            || ![
                frame.rms,
                frame.loudness_db,
                frame.onset.broadband,
                frame.onset.low,
                frame.onset.mid,
                frame.onset.high,
            ]
            .iter()
            .all(|v| v.is_finite())
        {
            return Err(MappingError);
        }
        let bands = &frame.spectrum[..frame.band_count as usize];
        if bands.iter().any(|v| !v.is_finite()) {
            return Err(MappingError);
        }
        let shaped = match self.source {
            LevelSource::Absolute => bands,
            LevelSource::Relative => match levels {
                Some(l) if l.band_count == frame.band_count => {
                    let relative = &l.relative_bands[..bands.len()];
                    if relative.iter().any(|v| !v.is_finite()) {
                        return Err(MappingError);
                    }
                    relative
                }
                _ => return Err(MappingError),
            },
        };
        if let Some(d) = descriptors {
            if ![
                d.momentary_lufs,
                d.short_term_lufs,
                d.width,
                d.balance,
                d.centroid_hz,
                d.spectral_flux,
            ]
            .iter()
            .all(|v| v.is_finite())
            {
                return Err(MappingError);
            }
        }
        let amplitude = if frame.rms > 0.0 {
            clamp01(
                (frame.loudness_db + self.config.loudness_reference - self.config.db_floor)
                    / -self.config.db_floor,
            )
        } else {
            0.0
        };
        let previous = self.previous.unwrap_or(amplitude);
        let level = if amplitude > previous {
            amplitude
        } else {
            previous + self.alpha * (amplitude - previous)
        };
        let mut out = Mapped::ZERO;
        out.values[AMPLITUDE] = amplitude;
        out.values[LEVEL] = clamp01(level);
        out.values[BASS] = group(shaped, self.config.groups[0]);
        out.values[MID] = group(shaped, self.config.groups[1]);
        out.values[TREBLE] = group(shaped, self.config.groups[2]);
        out.values[ONSET] = clamp01(frame.onset.broadband);
        out.values[BASS_IMPACT] = clamp01(frame.onset.low);
        match descriptors {
            Some(d) => {
                out.values[FLUX] = clamp01(d.spectral_flux);
                out.values[CENTROID] = centroid(bands, d.centroid_hz, self.config.centroid_floor);
            }
            None => {
                out.values[FLUX] = clamp01(frame.onset.broadband);
                out.values[CENTROID] = band_centroid(bands, self.config.centroid_floor);
            }
        }
        for (i, value) in out.spectrum.iter_mut().enumerate() {
            *value = match shaped.len() {
                0 => 0.0,
                1 => clamp01(shaped[0]) as f32,
                n => {
                    let position = i as f64 / (SPECTRUM_BINS - 1) as f64 * (n - 1) as f64;
                    let low = libm::floor(position) as usize;
                    let high = (low + 1).min(n - 1);
                    let t = position - low as f64;
                    clamp01(shaped[low] * (1.0 - t) + shaped[high] * t) as f32
                }
            };
        }
        if out.values.iter().any(|v| !v.is_finite()) || out.spectrum.iter().any(|v| !v.is_finite())
        {
            return Err(MappingError);
        }
        self.previous = Some(out.values[LEVEL]);
        Ok(out)
    }
}
fn group(bands: &[f64], [from, to]: [u32; 2]) -> f64 {
    let values = bands
        .iter()
        .skip(from as usize)
        .take((to - from + 1) as usize);
    let (sum, count) = values.fold((0.0, 0u32), |(s, n), v| (s + v, n + 1));
    if count == 0 {
        0.0
    } else {
        clamp01(sum / count as f64)
    }
}
/// The reference's deprecated centroid proxy, kept for [`Mapper::map`].
fn band_centroid(bands: &[f64], floor: f64) -> f64 {
    let (weighted, total) = bands
        .iter()
        .enumerate()
        .fold((0.0, 0.0), |(w, t), (i, v)| (w + i as f64 * v, t + v));
    if total <= floor || bands.len() < 2 {
        0.0
    } else {
        clamp01(weighted / total / (bands.len() - 1) as f64)
    }
}
fn centroid(bands: &[f64], hz: f64, floor: f64) -> f64 {
    let total = bands.iter().fold(0.0, |t, v| t + v);
    if total <= floor || hz <= CENTROID_MIN_HZ {
        0.0
    } else {
        clamp01(libm::log10(hz / CENTROID_MIN_HZ) / CENTROID_DECADES)
    }
}

fn clamp01(value: f64) -> f64 {
    if value.is_finite() {
        value.clamp(0.0, 1.0)
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_unchanged_reference_mapping() {
        let literal = MappingConfig {
            loudness_reference: -18.0,
            db_floor: -60.0,
            hop_seconds: 512.0 / 48_000.0,
            release_seconds: 0.2,
            centroid_floor: 1e-6,
            groups: [[0, 7], [8, 15], [16, 23]],
        };
        let default = MappingConfig::default();
        assert_eq!(default, literal);
        assert_eq!(default.hop_seconds.to_bits(), literal.hop_seconds.to_bits());
    }

    #[test]
    fn derives_hop_and_loudness_reference_from_dsp() {
        let dsp = DspConfig {
            sample_rate_hz: 44_100,
            hop_samples: 441,
            loudness_reference_lufs: -23.0,
            ..DspConfig::default()
        };
        let cfg = MappingConfig::for_dsp(&dsp);
        assert_eq!(cfg.hop_seconds, 0.01);
        assert_eq!(cfg.loudness_reference, -23.0);
        let rest = MappingConfig {
            hop_seconds: cfg.hop_seconds,
            loudness_reference: cfg.loudness_reference,
            ..MappingConfig::default()
        };
        assert_eq!(cfg, rest);
    }

    #[test]
    fn release_follows_the_dsp_hop_at_44_1_khz() {
        let dsp = DspConfig {
            sample_rate_hz: 44_100,
            ..DspConfig::default()
        };
        let mut mapper = Mapper::new(MappingConfig::for_dsp(&dsp)).unwrap();
        let mut frame = DspFrame::ZERO;
        frame.rms = 1.0;
        frame.loudness_db = 18.0; // 0 dBFS after adding back the -18 reference.
        assert_eq!(mapper.map(&frame, false).unwrap().values[1], 1.0);
        frame.rms = 0.0;
        let level = mapper.map(&frame, false).unwrap().values[1];
        // One 512-sample hop at 44.1 kHz of a 0.2 s release: exp(-512 / 44100 / 0.2).
        assert!((level - 0.943_602_873_103_416_2).abs() < 1e-12, "{level}");
    }

    fn loud_frame() -> DspFrame {
        let mut frame = DspFrame::ZERO;
        frame.rms = 0.5;
        frame.loudness_db = 10.0;
        frame.band_count = 24;
        frame.spectrum[..24].fill(0.25);
        frame.onset.broadband = 0.7;
        frame
    }

    #[test]
    fn flux_and_centroid_come_from_descriptors_when_given() {
        let mut mapper = Mapper::new(MappingConfig::default()).unwrap();
        let frame = loud_frame();
        let legacy = mapper.map(&frame, false).unwrap();
        assert_eq!(legacy.values[ONSET], 0.7);
        // Without descriptors the deprecated proxies stay: onset, and the band-index centroid
        // of 24 equal bands, 11.5 / 23.
        assert_eq!(legacy.values[FLUX], 0.7);
        assert_eq!(legacy.values[CENTROID], 0.5);
        assert_eq!(mapper.map_with(&frame, None, false).unwrap(), legacy);
        let mut d = Descriptors {
            spectral_flux: 0.3,
            centroid_hz: 632.455_532_033_675_9,
            ..Descriptors::ZERO
        };
        let mapped = mapper.map_with(&frame, Some(&d), false).unwrap();
        assert_eq!(mapped.values[ONSET], 0.7);
        assert_eq!(mapped.values[FLUX], 0.3);
        assert!((mapped.values[CENTROID] - 0.5).abs() < 1e-12);
        assert_eq!(mapped.values[..FLUX], legacy.values[..FLUX]);
        for (hz, expected) in [
            (0.0, 0.0),
            (19.9, 0.0),
            (20.0, 0.0),
            (200.0, 1.0 / 3.0),
            (2e4, 1.0),
            (3e4, 1.0),
        ] {
            d.centroid_hz = hz;
            let value = mapper.map_with(&frame, Some(&d), false).unwrap().values[CENTROID];
            assert!((value - expected).abs() < 1e-12, "{hz}: {value}");
        }
        d.spectral_flux = 1.5;
        assert_eq!(
            mapper.map_with(&frame, Some(&d), false).unwrap().values[FLUX],
            1.0
        );
        let mut quiet = frame;
        quiet.spectrum[..24].fill(0.0);
        d.centroid_hz = 1000.0;
        assert_eq!(
            mapper.map_with(&quiet, Some(&d), false).unwrap().values[CENTROID],
            0.0
        );
    }

    #[test]
    fn relative_levels_replace_band_groups_and_spectrum_only_when_selected() {
        let mut absolute = Mapper::new(MappingConfig::default()).unwrap();
        let mut relative = Mapper::new(MappingConfig::default()).unwrap();
        assert_eq!(relative.level_source(), LevelSource::Absolute);
        relative.set_level_source(LevelSource::Relative);
        let frame = loud_frame();
        let mut levels = Levels {
            band_count: 24,
            ..Levels::ZERO
        };
        levels.relative_bands[..8].fill(1.0);
        levels.relative_bands[8..16].fill(0.5);
        // Above 1 clamps, as the absolute band energies do.
        levels.relative_bands[16..24].fill(1.5);
        let d = Descriptors {
            spectral_flux: 0.3,
            centroid_hz: 1000.0,
            ..Descriptors::ZERO
        };
        let base = absolute.map_with(&frame, Some(&d), false).unwrap();
        // Absolute ignores the levels: bit-identical to map_with.
        assert_eq!(
            absolute.map_ext(&frame, Some(&d), Some(&levels), false),
            Ok(base)
        );
        let mapped = relative
            .map_ext(&frame, Some(&d), Some(&levels), false)
            .unwrap();
        assert_eq!(mapped.values[BASS..ONSET], [1.0, 0.5, 1.0]);
        for slot in [AMPLITUDE, LEVEL, ONSET, BASS_IMPACT, FLUX, CENTROID] {
            assert_eq!(mapped.values[slot], base.values[slot], "{slot}");
        }
        assert_eq!(mapped.spectrum[0], 1.0);
        assert_eq!(mapped.spectrum[SPECTRUM_BINS - 1], 1.0);
        assert_eq!(mapped.spectrum[30], 0.5);
        // Relative refuses missing, mismatched or non-finite levels and keeps the envelope.
        let mut short = levels;
        short.band_count = 23;
        let mut bad = levels;
        bad.relative_bands[3] = f64::NAN;
        for wrong in [None, Some(&short), Some(&bad)] {
            assert_eq!(
                relative.map_ext(&frame, Some(&d), wrong, false),
                Err(MappingError)
            );
        }
        assert_eq!(relative.map(&frame, false), Err(MappingError));
        // A NaN past band_count is not read.
        let mut past = levels;
        past.relative_bands[30] = f64::NAN;
        assert_eq!(
            relative.map_ext(&frame, Some(&d), Some(&past), false),
            Ok(mapped)
        );
        assert_eq!(relative.map_ext(&frame, None, None, true), Ok(Mapped::ZERO));
        relative.reset();
        assert_eq!(relative.level_source(), LevelSource::Relative);
    }

    #[test]
    fn non_finite_descriptors_are_refused_without_touching_the_envelope() {
        let mut mapper = Mapper::new(MappingConfig::default()).unwrap();
        let frame = loud_frame();
        let first = mapper.map(&frame, false).unwrap();
        for field in 0..6 {
            let mut d = Descriptors::ZERO;
            let value = [
                &mut d.momentary_lufs,
                &mut d.short_term_lufs,
                &mut d.width,
                &mut d.balance,
                &mut d.centroid_hz,
                &mut d.spectral_flux,
            ];
            *value.into_iter().nth(field).unwrap() = f64::NAN;
            assert_eq!(mapper.map_with(&frame, Some(&d), false), Err(MappingError));
        }
        assert_eq!(mapper.map(&frame, false).unwrap(), first);
        let unavailable = Descriptors {
            centroid_hz: f64::NAN,
            ..Descriptors::ZERO
        };
        assert_eq!(
            mapper.map_with(&frame, Some(&unavailable), true),
            Ok(Mapped::ZERO)
        );
    }
}
