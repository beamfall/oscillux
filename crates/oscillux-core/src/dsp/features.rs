// SPDX-License-Identifier: AGPL-3.0-only
//! Per-frame feature maths: windowing, band levels, ballistics smoothing and spectral-flux onsets.

use alloc::vec::Vec;
use core::f64::consts::PI;

use super::config::{DspConfig, MAX_BANDS, ONSET_GROUPS};
use super::fft::Fft;
use super::Onset;

/// Everything derived from the configuration once, at creation.
pub(crate) struct Tables {
    pub(crate) window: Vec<f64>,
    pub(crate) fft: Fft,
    /// Half-open FFT bin range averaged into each band.
    pub(crate) band_bins: Vec<(usize, usize)>,
    /// Linear amplitude of `db_floor`.
    pub(crate) floor_amp: f64,
    pub(crate) attack: f64,
    pub(crate) release: f64,
}

impl Tables {
    pub(crate) fn new(cfg: &DspConfig) -> Tables {
        let n = cfg.fft_window_samples as usize;
        let hop_sec = cfg.hop_samples as f64 / cfg.sample_rate_hz as f64;
        Tables {
            window: hann(n),
            fft: Fft::new(n),
            band_bins: band_bins(cfg),
            floor_amp: libm::pow(10.0, cfg.db_floor / 20.0),
            attack: libm::exp(-hop_sec / (cfg.ballistics_attack_ms / 1000.0)),
            release: libm::exp(-hop_sec / (cfg.ballistics_release_ms / 1000.0)),
        }
    }
}

/// Symmetric Hann window of length `n`.
pub(crate) fn hann(n: usize) -> Vec<f64> {
    let denom = (n - 1) as f64;
    (0..n)
        .map(|i| 0.5 - 0.5 * libm::cos(2.0 * PI * i as f64 / denom))
        .collect()
}

fn band_bins(cfg: &DspConfig) -> Vec<(usize, usize)> {
    let bands = cfg.spectrum_bands as usize;
    let ratio = libm::pow(
        cfg.spectrum_max_hz / cfg.spectrum_min_hz,
        1.0 / bands as f64,
    );
    (0..bands).map(|band| bin_range(cfg, ratio, band)).collect()
}

fn bin_range(cfg: &DspConfig, ratio: f64, band: usize) -> (usize, usize) {
    let bins = cfg.fft_window_samples as usize / 2 + 1;
    let hz_to_bin = |hz: f64| hz * cfg.fft_window_samples as f64 / cfg.sample_rate_hz as f64;
    let lo = cfg.spectrum_min_hz * libm::pow(ratio, band as f64);
    let hi = cfg.spectrum_min_hz * libm::pow(ratio, (band + 1) as f64);
    let start = libm::ceil(hz_to_bin(lo)) as usize;
    let end = (libm::floor(hz_to_bin(hi)) as usize).max(start);
    let end_exclusive = end.saturating_add(1).min(bins);
    (start.min(end_exclusive), end_exclusive)
}

/// Magnitude spectrum of `re + i·im`, scaled by `2/N`, into `mags` (`N/2 + 1` bins).
pub(crate) fn magnitudes(re: &[f64], im: &[f64], mags: &mut [f64]) {
    let scale = (re.len() / 2) as f64;
    for (k, mag) in mags.iter_mut().enumerate() {
        *mag = libm::sqrt(re[k] * re[k] + im[k] * im[k]) / scale;
    }
}

/// Raw band levels in `[0, 1]`: mean bin magnitude in dB, mapped from `db_floor..0`.
pub(crate) fn band_levels(tables: &Tables, db_floor: f64, mags: &[f64], out: &mut [f64]) {
    for (level, (start, end)) in out.iter_mut().zip(&tables.band_bins) {
        *level = band_level(tables.floor_amp, db_floor, &mags[*start..*end]);
    }
}

fn band_level(floor_amp: f64, db_floor: f64, bins: &[f64]) -> f64 {
    if bins.is_empty() {
        return 0.0;
    }
    let mean = bins.iter().fold(0.0, |sum, m| sum + m) / bins.len() as f64;
    db_level(floor_amp, db_floor, mean)
}

/// Amplitude in dB, mapped from `db_floor..0` to `[0, 1]`.
pub(crate) fn db_level(floor_amp: f64, db_floor: f64, amplitude: f64) -> f64 {
    let db = 20.0 * libm::log10(amplitude.max(floor_amp));
    ((db - db_floor) / -db_floor).clamp(0.0, 1.0)
}

/// Attack/release smoothing of `raw` into `smoothed`, which holds the previous output.
pub(crate) fn smooth(tables: &Tables, raw: &[f64], smoothed: &mut [f64]) {
    for (prev, r) in smoothed.iter_mut().zip(raw) {
        let coeff = if *r > *prev {
            tables.attack
        } else {
            tables.release
        };
        *prev = r + coeff * (*prev - r);
    }
}

/// Running state of the spectral-flux onset detector.
pub(crate) struct OnsetState {
    prev_bands: [f64; MAX_BANDS],
    initialized: bool,
    peak: f64,
    group_peaks: [f64; ONSET_GROUPS],
}

impl OnsetState {
    pub(crate) const fn new() -> OnsetState {
        OnsetState {
            prev_bands: [0.0; MAX_BANDS],
            initialized: false,
            peak: 0.0,
            group_peaks: [0.0; ONSET_GROUPS],
        }
    }

    /// Half-wave rectified flux of the raw bands, normalised by decaying running peaks.
    pub(crate) fn update(&mut self, cfg: &DspConfig, bands: &[f64]) -> Onset {
        if !self.initialized {
            self.initialized = true;
            self.prev_bands[..bands.len()].copy_from_slice(bands);
            self.peak = 1.0;
            return Onset::default();
        }
        let (flux_sum, group_flux) = self.flux(cfg, bands);
        let flux = flux_sum / bands.len() as f64;
        self.peak = flux.max(self.peak * cfg.onset_peak_decay);
        let groups = self.group_values(cfg, group_flux);
        Onset {
            broadband: flux / self.peak.max(cfg.onset_peak_floor),
            low: groups[0],
            mid: groups[1],
            high: groups[2],
        }
    }

    /// Sums positive band deltas overall and per group, and stores `bands` as the previous frame.
    fn flux(&mut self, cfg: &DspConfig, bands: &[f64]) -> (f64, [f64; ONSET_GROUPS]) {
        let mut flux = 0.0;
        let mut group_flux = [0.0; ONSET_GROUPS];
        for (i, band) in bands.iter().enumerate() {
            let delta = (band - self.prev_bands[i]).max(0.0);
            flux += delta;
            add_to_groups(cfg, i, delta, &mut group_flux);
            self.prev_bands[i] = *band;
        }
        (flux, group_flux)
    }

    fn group_values(&mut self, cfg: &DspConfig, group_flux: [f64; ONSET_GROUPS]) -> [f64; 3] {
        let mut values = [0.0; ONSET_GROUPS];
        for (gi, [start, end]) in cfg.onset_band_groups.iter().enumerate() {
            let width = (end - start + 1) as f64;
            let flux = group_flux[gi] / width;
            self.group_peaks[gi] = flux.max(self.group_peaks[gi] * cfg.onset_peak_decay);
            values[gi] = flux / self.group_peaks[gi].max(cfg.onset_peak_floor);
        }
        values
    }
}

fn add_to_groups(cfg: &DspConfig, band: usize, delta: f64, group_flux: &mut [f64; ONSET_GROUPS]) {
    let band = band as u32;
    let groups = group_flux.iter_mut().zip(&cfg.onset_band_groups);
    let containing = groups.filter(|(_, [start, end])| (*start..=*end).contains(&band));
    for (sum, _) in containing {
        *sum += delta;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_or_underflowed_peak_does_not_reinitialize_onsets() {
        for decay in [0.0, 1e-100] {
            let cfg = DspConfig {
                onset_peak_decay: decay,
                ..DspConfig::default()
            };
            let mut state = OnsetState::new();
            let mut bands = [0.0; 24];
            for _ in 0..10 {
                state.update(&cfg, &bands);
            }
            assert_eq!(state.peak, 0.0);
            bands[0] = 1.0;
            let attack = state.update(&cfg, &bands);
            assert_eq!(attack.broadband, 1.0);
            assert_eq!(attack.low, 1.0);
        }
    }

    #[test]
    fn finite_extreme_frequencies_stay_within_fft_bins() {
        let cfg = DspConfig {
            spectrum_min_hz: 1e100,
            spectrum_max_hz: 1e200,
            ..DspConfig::default()
        };
        // Validation rejects this as above Nyquist; the bin mapping still stays in range.
        assert!(cfg.validate().is_err());
        let bins = cfg.fft_window_samples as usize / 2 + 1;
        assert!(band_bins(&cfg)
            .iter()
            .all(|&(start, end)| start == bins && end == bins));
    }
}
