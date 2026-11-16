// SPDX-License-Identifier: AGPL-3.0-only
//! Behaviour version 2 feature maths (`conformance/dsp/README.md`, "Behaviour version 2").
//!
//! - Spectrum: the main window goes through a real-input FFT. Each band is a triangular
//!   weighting of the bins strictly inside it, normalised to unit sum, so no two bands share a
//!   bin. Bands narrower than four main bins and below a tenth of the decimated rate read a bass
//!   spectrum instead: the input decimated by a power of two to at most 6 kHz through a
//!   fourth-order CIC FIR, then a Hann window of at most 1024 decimated samples (about 171 ms,
//!   about 86 ms group delay), zero padded to a power of two, with the FIR droop divided out.
//! - Onsets: level-domain flux of the energy in each onset range, normalised by a decaying peak
//!   that never drops below an absolute floor.
//! - RMS: squared samples are summed in 64-sample blocks as they arrive, so a frame adds at most
//!   `W/64 + 63` terms instead of `W`.

use alloc::vec;
use alloc::vec::Vec;
use core::f64::consts::PI;

use super::analyzer::latest;
use super::config::{
    DspConfig, ONSET_GROUPS, V2_BASS_CIC_ORDER, V2_BASS_MAX_DECIMATION, V2_BASS_MAX_MAIN_BINS,
    V2_BASS_RATE_HZ, V2_BASS_TOP_FRACTION, V2_BASS_WINDOW, V2_ONSET_FLOOR, V2_RMS_BLOCK,
};
use super::features::{db_level, hann, Tables};
use super::fft::RealFft;
use super::Onset;

/// The analyzer's sample history as a version 2 step sees it.
pub(crate) struct Recent<'a> {
    pub(crate) history: &'a [f64],
    /// Next write index of `history`.
    pub(crate) write: usize,
    /// Samples received in the current segment, including the newest.
    pub(crate) samples: u64,
}

impl Recent<'_> {
    fn latest(&self, count: usize) -> (&[f64], &[f64]) {
        latest(self.history, self.write, count)
    }
}

/// Scratch the analyzer owns and lends to [`V2::analyze`].
pub(crate) struct Scratch<'a> {
    /// `fft_window_samples` values.
    pub(crate) windowed: &'a mut [f64],
    /// `fft_window_samples` values: the packed real FFT input.
    pub(crate) packed: &'a mut [f64],
    /// `fft_window_samples / 2 + 1` main magnitudes.
    pub(crate) mags: &'a mut [f64],
}

/// Version 2 state and tables. Allocates in [`V2::new`] only.
pub(crate) struct V2 {
    fft: RealFft,
    bands: Vec<Band>,
    bass: Option<Bass>,
    onset: EnergyOnset,
    rms: BlockRms,
}

/// One band: unit-sum triangular weights over the bins of one spectrum.
struct Band {
    bass: bool,
    /// `(bin, weight)`, ascending bins.
    weights: Vec<(usize, f64)>,
}

impl V2 {
    pub(crate) fn new(cfg: &DspConfig, tables: &Tables) -> V2 {
        let n = cfg.fft_window_samples as usize;
        let plan = BassPlan::new(cfg);
        let bass_bands = plan.as_ref().map_or(0, |plan| plan.bands);
        let main_hz = |k: usize| k as f64 * cfg.sample_rate_hz as f64 / n as f64;
        let bands = (0..cfg.spectrum_bands as usize)
            .map(|band| {
                let (lo, hi) = band_edges(cfg, band);
                match plan.as_ref().filter(|_| band < bass_bands) {
                    Some(plan) => Band {
                        bass: true,
                        weights: triangle(
                            lo,
                            hi,
                            plan.size / 2 + 1,
                            |k| plan.bin_hz(k),
                            |k| plan.droop_gain(k),
                        ),
                    },
                    None => Band {
                        bass: false,
                        weights: triangle(lo, hi, n / 2 + 1, main_hz, |_| 1.0),
                    },
                }
            })
            .collect::<Vec<_>>();
        let bass = plan.map(|plan| Bass::new(plan, &bands));
        V2 {
            fft: RealFft::new(n),
            onset: EnergyOnset::new(cfg, &tables.window),
            rms: BlockRms::new(cfg.rms_window_samples()),
            bands,
            bass,
        }
    }

    /// Samples of history version 2 needs: the bass FIR reads its taps from it.
    pub(crate) fn history_samples(&self) -> usize {
        self.bass.as_ref().map_or(0, |bass| bass.taps.len())
    }

    /// Bass group delay in input samples, if the bass analysis is on for this configuration.
    pub(crate) fn bass_delay_samples(cfg: &DspConfig) -> Option<f64> {
        BassPlan::new(cfg).map(|plan| plan.delay_samples(cfg))
    }

    pub(crate) fn begin_segment(&mut self) {
        self.rms.acc = 0.0;
    }

    /// Per-sample step, after the analyzer stored the sample and counted it.
    pub(crate) fn accept(&mut self, sample: f64, recent: &Recent<'_>) {
        self.rms.accept(sample, recent.samples);
        if let Some(bass) = &mut self.bass {
            if recent.samples & bass.mask == 0 {
                bass.decimate(recent);
            }
        }
    }

    /// Fills `raw_bands` and returns the onsets and the RMS of the frame ending now.
    pub(crate) fn analyze(
        &mut self,
        cfg: &DspConfig,
        tables: &Tables,
        recent: &Recent<'_>,
        scratch: Scratch<'_>,
        raw_bands: &mut [f64],
    ) -> (Onset, f64) {
        let (older, newer) = recent.latest(scratch.windowed.len());
        let samples = older.iter().chain(newer);
        for ((x, s), w) in scratch.windowed.iter_mut().zip(samples).zip(&tables.window) {
            *x = s * w;
        }
        let half = scratch.windowed.len() / 2;
        let (zr, zi) = scratch.packed.split_at_mut(half);
        deinterleave(scratch.windowed, zr, zi);
        self.fft.magnitudes(zr, zi, half as f64, scratch.mags);
        if let Some(bass) = &mut self.bass {
            bass.spectrum(recent.samples);
        }
        let bass_mags = self.bass.as_ref().map_or(&[][..], |bass| &bass.mags);
        for (level, band) in raw_bands.iter_mut().zip(&self.bands) {
            let spectrum = if band.bass { bass_mags } else { &*scratch.mags };
            let amplitude = band
                .weights
                .iter()
                .fold(0.0, |sum, &(k, w)| sum + w * spectrum[k]);
            *level = db_level(tables.floor_amp, cfg.db_floor, amplitude);
        }
        let onset = self.onset.update(cfg, tables.floor_amp, scratch.mags);
        (onset, self.rms.rms(recent))
    }
}

/// `[lo, hi)` of `band`: `spectrum_min_hz · ratio^band`, as version 1 computes it.
fn band_edges(cfg: &DspConfig, band: usize) -> (f64, f64) {
    let edge = |b: usize| cfg.spectrum_min_hz * libm::pow(band_ratio(cfg), b as f64);
    (edge(band), edge(band + 1))
}

fn band_ratio(cfg: &DspConfig) -> f64 {
    libm::pow(
        cfg.spectrum_max_hz / cfg.spectrum_min_hz,
        1.0 / cfg.spectrum_bands as f64,
    )
}

/// Unit-sum triangular weights over the bins strictly inside `(lo, hi)`, apex at the geometric
/// centre, each then multiplied by `gain(bin)`. A band with no bin inside reads the magnitude
/// linearly interpolated at its centre.
fn triangle(
    lo: f64,
    hi: f64,
    bins: usize,
    hz: impl Fn(usize) -> f64,
    gain: impl Fn(usize) -> f64,
) -> Vec<(usize, f64)> {
    let centre = libm::sqrt(lo * hi);
    let inside = (0..bins).filter_map(|k| {
        let f = hz(k);
        let rising = (f - lo) / (centre - lo);
        let falling = (hi - f) / (hi - centre);
        let weight = if f <= centre { rising } else { falling };
        (lo < f && f < hi).then_some((k, weight))
    });
    let mut weights: Vec<(usize, f64)> = inside.collect();
    if weights.is_empty() {
        let position = centre / hz(1);
        let k0 = (libm::floor(position) as usize).min(bins - 2);
        let frac = (position - k0 as f64).clamp(0.0, 1.0);
        weights = vec![(k0, 1.0 - frac), (k0 + 1, frac)];
    }
    let total = weights.iter().fold(0.0, |sum, (_, w)| sum + w);
    let normalise = |&(k, w): &(usize, f64)| (k, w / total * gain(k));
    weights.iter().map(normalise).collect()
}

fn deinterleave(x: &[f64], re: &mut [f64], im: &mut [f64]) {
    for (pair, (r, i)) in x.chunks_exact(2).zip(re.iter_mut().zip(im.iter_mut())) {
        *r = pair[0];
        *i = pair[1];
    }
}

/// Shape of the bass analysis for one configuration.
struct BassPlan {
    sample_rate_hz: f64,
    /// Decimation factor `D`, a power of two.
    factor: u64,
    /// Hann window length `L`, decimated samples.
    window: usize,
    /// FFT length: `L` rounded up to a power of two.
    size: usize,
    /// Leading bands that read the bass spectrum.
    bands: usize,
}

impl BassPlan {
    /// The bass analysis applies when its window spans more input than the main window and at
    /// least the lowest band qualifies; qualifying bands are always a prefix.
    fn new(cfg: &DspConfig) -> Option<BassPlan> {
        let fs = cfg.sample_rate_hz as u64;
        let factor = (0..=V2_BASS_MAX_DECIMATION.trailing_zeros())
            .map(|shift| 1u64 << shift)
            .find(|d| fs <= V2_BASS_RATE_HZ * d)?;
        let rate = fs as f64 / factor as f64;
        let window = libm::floor(rate * V2_BASS_WINDOW / V2_BASS_RATE_HZ as f64).min(V2_BASS_WINDOW)
            as usize;
        let spans_more = window as u64 * factor > cfg.fft_window_samples as u64;
        let qualifies = |band: &usize| {
            let (lo, hi) = band_edges(cfg, *band);
            let main_bins = (hi - lo) * cfg.fft_window_samples as f64 / cfg.sample_rate_hz as f64;
            main_bins < V2_BASS_MAX_MAIN_BINS && hi <= V2_BASS_TOP_FRACTION * rate
        };
        let bands = (0..cfg.spectrum_bands as usize)
            .take_while(qualifies)
            .count();
        (spans_more && bands > 0).then_some(BassPlan {
            sample_rate_hz: cfg.sample_rate_hz as f64,
            factor,
            window,
            size: window.next_power_of_two(),
            bands,
        })
    }

    fn bin_hz(&self, k: usize) -> f64 {
        k as f64 * self.sample_rate_hz / (self.factor as usize * self.size) as f64
    }

    /// `1 / H(f)` with `H(f) = (sin(D·x) / (D·sin x))^4`, `x = π f / fs`: the CIC droop.
    fn droop_gain(&self, k: usize) -> f64 {
        if k == 0 {
            return 1.0;
        }
        let x = PI * self.bin_hz(k) / self.sample_rate_hz;
        let d = self.factor as f64;
        let ratio = libm::sin(d * x) / (d * libm::sin(x));
        let squared = ratio * ratio;
        1.0 / (squared * squared)
    }

    /// FIR taps: a length-`D` boxcar convolved with itself to order 4, divided by `D^4`.
    /// Symmetric, so the same order serves oldest-first input.
    fn taps(&self) -> Vec<f64> {
        let d = self.factor as usize;
        let mut taps = vec![1.0];
        for _ in 0..V2_BASS_CIC_ORDER {
            let mut next = vec![0.0; taps.len() + d - 1];
            for (i, t) in taps.iter().enumerate() {
                for out in &mut next[i..i + d] {
                    *out += t;
                }
            }
            taps = next;
        }
        let scale = libm::pow(d as f64, V2_BASS_CIC_ORDER as f64);
        taps.iter().map(|t| t / scale).collect()
    }

    /// Window centre plus FIR delay, plus `D - 1` when frames can fall between decimated samples.
    fn delay_samples(&self, cfg: &DspConfig) -> f64 {
        let d = self.factor;
        let aligned = cfg.fft_window_samples as u64 % d == 0 && cfg.hop_samples as u64 % d == 0;
        let fir = (V2_BASS_CIC_ORDER as u64 * (d - 1)) as f64 / 2.0;
        let window = (self.window - 1) as f64 * d as f64 / 2.0;
        let misalignment = if aligned { 0.0 } else { (d - 1) as f64 };
        window + fir + misalignment
    }
}

/// Decimated bass history and its spectrum.
struct Bass {
    /// `D - 1`: a decimated sample is due when the segment sample count has these bits clear.
    mask: u64,
    factor: u64,
    taps: Vec<f64>,
    window: Vec<f64>,
    /// Decimated sample `j` of the segment lives at `ring[j % L]`.
    ring: Vec<f64>,
    fft: RealFft,
    /// FFT input: windowed decimated samples, oldest first, zero padded after the newest.
    padded: Vec<f64>,
    packed: Vec<f64>,
    /// Magnitudes of the bins the bass bands read.
    mags: Vec<f64>,
}

impl Bass {
    fn new(plan: BassPlan, bands: &[Band]) -> Bass {
        let used = bands.iter().filter(|band| band.bass);
        let bins = used.flat_map(|band| band.weights.iter().map(|(k, _)| k + 1));
        Bass {
            mask: plan.factor - 1,
            factor: plan.factor,
            taps: plan.taps(),
            window: hann(plan.window),
            ring: vec![0.0; plan.window],
            fft: RealFft::new(plan.size),
            padded: vec![0.0; plan.size],
            packed: vec![0.0; plan.size],
            mags: vec![0.0; bins.max().unwrap_or(0)],
        }
    }

    /// Filters the newest input samples of the segment into the next decimated sample.
    fn decimate(&mut self, recent: &Recent<'_>) {
        let count = (self.taps.len() as u64).min(recent.samples) as usize;
        let (older, newer) = recent.latest(count);
        let taps = &self.taps[self.taps.len() - count..];
        let samples = older.iter().chain(newer);
        let value = samples.zip(taps).fold(0.0, |sum, (x, h)| sum + x * h);
        let index = recent.samples / self.factor - 1;
        let slot = (index % self.ring.len() as u64) as usize;
        self.ring[slot] = value;
    }

    /// Windows the latest `L` decimated samples of the segment (zeros before its start).
    fn spectrum(&mut self, samples: u64) {
        let len = self.window.len();
        let decimated = samples / self.factor;
        let available = decimated.min(len as u64) as usize;
        let write = (decimated % len as u64) as usize;
        let (older, newer) = latest(&self.ring, write, available);
        let start = len - available;
        self.padded[..start].fill(0.0);
        let values = older.iter().chain(newer).zip(&self.window[start..]);
        for (x, (d, w)) in self.padded[start..len].iter_mut().zip(values) {
            *x = d * w;
        }
        let half = self.padded.len() / 2;
        let (zr, zi) = self.packed.split_at_mut(half);
        deinterleave(&self.padded, zr, zi);
        self.fft
            .magnitudes(zr, zi, len as f64 / 2.0, &mut self.mags);
    }
}

/// Level-domain flux of the energy in the broadband and band-group ranges.
struct EnergyOnset {
    /// Half-open main-spectrum bin range per detector: broadband, then each band group.
    ranges: [(usize, usize); ONSET_GROUPS + 1],
    /// `N / Σw²`: turns summed squared magnitudes into the squared amplitude of a sine.
    scale: f64,
    prev: [f64; ONSET_GROUPS + 1],
    peaks: [f64; ONSET_GROUPS + 1],
    initialized: bool,
}

impl EnergyOnset {
    fn new(cfg: &DspConfig, window: &[f64]) -> EnergyOnset {
        let n = cfg.fft_window_samples as usize;
        let hz = |k: usize| k as f64 * cfg.sample_rate_hz as f64 / n as f64;
        let below = |limit: f64| (0..=n / 2).filter(|k| hz(*k) < limit).count();
        let range = |lo: f64, hi: f64| (below(lo), below(hi));
        let mut ranges = [range(cfg.spectrum_min_hz, cfg.spectrum_max_hz); ONSET_GROUPS + 1];
        for (slot, [start, end]) in ranges[1..].iter_mut().zip(&cfg.onset_band_groups) {
            let (lo, _) = band_edges(cfg, *start as usize);
            let (_, hi) = band_edges(cfg, *end as usize);
            *slot = range(lo, hi);
        }
        let window_energy = window.iter().fold(0.0, |sum, w| sum + w * w);
        EnergyOnset {
            ranges,
            scale: n as f64 / window_energy,
            prev: [0.0; ONSET_GROUPS + 1],
            peaks: [0.0; ONSET_GROUPS + 1],
            initialized: false,
        }
    }

    fn update(&mut self, cfg: &DspConfig, floor_amp: f64, mags: &[f64]) -> Onset {
        let mut out = [0.0; ONSET_GROUPS + 1];
        for (i, (start, end)) in self.ranges.iter().enumerate() {
            let energy = mags[*start..*end].iter().fold(0.0, |sum, m| sum + m * m);
            let level = db_level(floor_amp, cfg.db_floor, libm::sqrt(energy * self.scale));
            if self.initialized {
                let flux = (level - self.prev[i]).max(0.0);
                self.peaks[i] = flux.max(self.peaks[i] * cfg.onset_peak_decay);
                let norm = self.peaks[i].max(cfg.onset_peak_floor).max(V2_ONSET_FLOOR);
                out[i] = flux / norm;
            }
            self.prev[i] = level;
        }
        self.initialized = true;
        Onset {
            broadband: out[0],
            low: out[1],
            mid: out[2],
            high: out[3],
        }
    }
}

/// RMS from block sums of squared samples.
struct BlockRms {
    /// RMS window `W`, samples.
    window: usize,
    /// Completed block `b` of the segment lives at `blocks[b % len]`; `len = W/64 + 1`.
    blocks: Vec<f64>,
    /// Sum of squares of the current, incomplete block.
    acc: f64,
}

impl BlockRms {
    fn new(window: usize) -> BlockRms {
        BlockRms {
            window,
            blocks: vec![0.0; window / V2_RMS_BLOCK as usize + 1],
            acc: 0.0,
        }
    }

    fn accept(&mut self, sample: f64, samples: u64) {
        self.acc += sample * sample;
        if samples % V2_RMS_BLOCK == 0 {
            let block = samples / V2_RMS_BLOCK - 1;
            let slot = (block % self.blocks.len() as u64) as usize;
            self.blocks[slot] = self.acc;
            self.acc = 0.0;
        }
    }

    /// Sums the oldest `rest % 64` samples directly, then whole blocks oldest first, then the
    /// current block. With fewer samples than the current block holds, sums them directly.
    fn rms(&self, recent: &Recent<'_>) -> f64 {
        let count = recent.samples.min(self.window as u64) as usize;
        let fill = (recent.samples % V2_RMS_BLOCK) as usize;
        let (older, newer) = recent.latest(count);
        let squares = older.iter().chain(newer).map(|s| s * s);
        let sum = if count <= fill {
            squares.fold(0.0, |sum, sq| sum + sq)
        } else {
            let rest = count - fill;
            let block = V2_RMS_BLOCK as usize;
            let head = squares.take(rest % block).fold(0.0, |sum, sq| sum + sq);
            let completed = recent.samples / V2_RMS_BLOCK;
            let write = (completed % self.blocks.len() as u64) as usize;
            let (older, newer) = latest(&self.blocks, write, rest / block);
            let blocks = older.iter().chain(newer).fold(head, |sum, b| sum + b);
            blocks + self.acc
        };
        libm::sqrt(sum / count as f64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v2(cfg: &DspConfig) -> V2 {
        V2::new(cfg, &Tables::new(cfg))
    }

    fn at_rate(sample_rate_hz: u32) -> DspConfig {
        DspConfig {
            sample_rate_hz,
            spectrum_max_hz: 16000.0f64.min(sample_rate_hz as f64 / 2.0),
            ..DspConfig::default()
        }
    }

    #[test]
    fn no_two_bands_share_a_bin_at_the_default_config() {
        for rate in [44100, 48000] {
            let cfg = at_rate(rate);
            let analysis = v2(&cfg);
            assert_eq!(analysis.bass.as_ref().map(|b| b.factor), Some(8));
            let bass_bands = analysis.bands.iter().filter(|b| b.bass).count();
            assert_eq!(bass_bands, 9, "{rate} Hz");
            for (i, band) in analysis.bands.iter().enumerate() {
                let (lo, hi) = band_edges(&cfg, i);
                assert!(!band.weights.is_empty());
                let plan = BassPlan::new(&cfg).unwrap();
                let main_hz = |k: usize| k as f64 * rate as f64 / 2048.0;
                for &(k, w) in &band.weights {
                    let f = if band.bass {
                        plan.bin_hz(k)
                    } else {
                        main_hz(k)
                    };
                    assert!(lo < f && f < hi, "band {i} bin {k} at {f} Hz outside");
                    assert!(w > 0.0);
                }
                for other in &analysis.bands[i + 1..] {
                    let shared = band.bass == other.bass
                        && band
                            .weights
                            .iter()
                            .any(|(k, _)| other.weights.iter().any(|(j, _)| j == k));
                    assert!(!shared, "band {i} shares a bin");
                }
            }
        }
    }

    #[test]
    fn bass_group_delay_stays_within_90_ms() {
        for rate in [
            8000, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 192000,
        ] {
            let cfg = at_rate(rate);
            // At 16 kHz and below the main window already resolves the low bands.
            let Some(delay) = V2::bass_delay_samples(&cfg) else {
                assert!(rate <= 16000, "{rate} Hz has no bass analysis");
                continue;
            };
            let ms = delay / rate as f64 * 1000.0;
            assert!(ms <= 90.0, "{rate} Hz: {ms} ms");
        }
        let delay = V2::bass_delay_samples(&DspConfig::default()).unwrap();
        assert_eq!(delay, 4106.0);
        let odd_hop = DspConfig {
            hop_samples: 500,
            ..DspConfig::default()
        };
        assert_eq!(V2::bass_delay_samples(&odd_hop), Some(4113.0));
    }

    #[test]
    fn bass_analysis_is_off_where_it_cannot_help() {
        let long_window = DspConfig {
            fft_window_samples: 16384,
            ..DspConfig::default()
        };
        assert!(BassPlan::new(&long_window).is_none());
        let high_bands = DspConfig {
            spectrum_min_hz: 1000.0,
            ..DspConfig::default()
        };
        assert!(BassPlan::new(&high_bands).is_none());
        let extreme_rate = DspConfig {
            sample_rate_hz: 6000 * 512,
            rms_window_ms: 1.0,
            ..DspConfig::default()
        };
        assert!(BassPlan::new(&extreme_rate).is_none());
        let tiny_rate = DspConfig {
            sample_rate_hz: 100,
            fft_window_samples: 64,
            hop_samples: 16,
            spectrum_min_hz: 1.0,
            spectrum_max_hz: 50.0,
            ..DspConfig::default()
        };
        assert!(tiny_rate.validate().is_ok());
        let tiny = v2(&tiny_rate);
        assert!(tiny.bands.iter().all(|band| !band.weights.is_empty()));
    }

    #[test]
    fn cic_taps_sum_to_one_and_are_symmetric() {
        let plan = BassPlan::new(&DspConfig::default()).unwrap();
        let taps = plan.taps();
        assert_eq!(taps.len(), 29);
        assert_eq!(taps.iter().sum::<f64>(), 1.0);
        assert!(taps.iter().eq(taps.iter().rev()));
    }

    #[test]
    fn group_onsets_do_not_saturate_on_flux_below_1e_3() {
        let cfg = DspConfig::default();
        let tables = Tables::new(&cfg);
        let mut onset = EnergyOnset::new(&cfg, &tables.window);
        let mut mags = vec![1e-3; 1025];
        assert_eq!(
            onset.update(&cfg, tables.floor_amp, &mags),
            Onset::default()
        );
        for _ in 0..200 {
            onset.update(&cfg, tables.floor_amp, &mags);
        }
        // +0.0804 dB is a level step of 8.9e-4 in every range: below 1e-3, so at most 0.1.
        for m in &mut mags {
            *m *= 1.0093;
        }
        let out = onset.update(&cfg, tables.floor_amp, &mags);
        for value in [out.broadband, out.low, out.mid, out.high] {
            assert!(value > 0.08 && value < 0.1, "{out:?}");
        }
    }

    #[test]
    fn block_rms_matches_direct_sum() {
        for (window, total) in [(14400, 20000u64), (100, 700), (10, 300), (64, 640), (1, 9)] {
            let mut rms = BlockRms::new(window);
            let mut history = vec![0.0; window.max(1)];
            let mut write = 0;
            for samples in 1..=total {
                let sample = libm::sin(samples as f64 * 0.37) * 0.8;
                history[write] = sample;
                write = (write + 1) % history.len();
                rms.accept(sample, samples);
                let recent = Recent {
                    history: &history,
                    write,
                    samples,
                };
                let count = samples.min(window as u64) as usize;
                let (older, newer) = latest(&history, write, count);
                let direct = older.iter().chain(newer).map(|s| s * s).sum::<f64>();
                let want = libm::sqrt(direct / count as f64);
                assert!(
                    (rms.rms(&recent) - want).abs() < 1e-12,
                    "{window} {samples}"
                );
            }
        }
    }
}
