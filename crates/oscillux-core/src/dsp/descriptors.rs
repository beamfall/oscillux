// SPDX-License-Identifier: AGPL-3.0-only
//! Opt-in descriptors computed beside every frame: ITU-R BS.1770-4 momentary and short-term
//! loudness, stereo width and balance, spectral centroid in Hz and normalised spectral flux.
//!
//! Loudness, width and balance read the interleaved channels before mixdown, K-weighted per
//! channel: the BS.1770 high-shelf stage, then the RLB high-pass, which also removes DC. Both
//! biquads are derived for the configured sample rate from the analog prototype parameters
//! (the libebur128 formulas); at 48 kHz they reproduce the coefficients published in BS.1770-4.
//! None of this touches the frame path, so behaviour version 1 and 2 frames are unchanged.
//!
//! Each sample's weighted power is quantised down to a multiple of 2^-50 and accumulated in
//! wrapping 128-bit integers. A window sum is the exact difference of two cumulative sums, so
//! long streams do not drift and every target computes the same value. Cumulative sums are
//! recorded at the sample positions where future windows start; with very small hops only every
//! `stride`-th start is recorded (so memory stays bounded) and a window then reaches back to the
//! last recorded start, at most `stride - 1` hops further. At the default 48 kHz configuration,
//! and for any hop of at least 36 samples at 48 kHz, every window is exact.

use alloc::vec;
use alloc::vec::Vec;

use super::analyzer::MAX_SAMPLE;
use super::config::DspConfig;

/// Channels measured for loudness, width and balance; later channels are ignored.
pub const DESCRIPTOR_MAX_CHANNELS: usize = 8;
/// Loudness reported for digital silence and for anything quieter, LUFS.
pub const LUFS_FLOOR: f64 = -120.0;
/// Lowest sample rate at which loudness, width and balance are measured. Below it the K-weighting
/// shelf is not realisable, loudness reads [`LUFS_FLOOR`] and width and balance read 0.
pub const LOUDNESS_MIN_RATE_HZ: u32 = 8000;

/// BS.1770-4 momentary window, seconds.
const MOMENTARY_SECONDS: f64 = 0.4;
/// EBU R 128 short-term window, seconds.
const SHORT_TERM_SECONDS: f64 = 3.0;
/// Fixed-point scale of quantised powers: one unit is 2^-50.
const SCALE: f64 = (1u64 << 50) as f64;
/// Most window starts held per window length.
const MAX_MARKS: u64 = 4096;
/// Filter state magnitudes below this are flushed to 0, so silence never leaves subnormals.
const TINY: f64 = 1e-30;

/// Cumulative sum indices.
const POWER: usize = 0;
const LEFT: usize = 1;
const RIGHT: usize = 2;
const SIDE: usize = 3;

/// Per-frame descriptors, written by [`super::Analyzer::push_ext`].
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Descriptors {
    /// BS.1770-4 momentary loudness over the 400 ms ending at the analysis-window end, LUFS, at
    /// least [`LUFS_FLOOR`]. Clipped to the current segment, like the frame's RMS.
    pub momentary_lufs: f64,
    /// EBU R 128 short-term loudness over the 3 s ending at the analysis-window end, LUFS, at
    /// least [`LUFS_FLOOR`]. Clipped to the current segment.
    pub short_term_lufs: f64,
    /// Side energy fraction `E_S / (E_M + E_S)` of the K-weighted first two channels over the
    /// momentary window, `M = (L + R) / 2`, `S = (L - R) / 2`, in `[0, 1]`: 0 for identical
    /// channels, 0.5 for one silent channel or uncorrelated equal channels, 1 for anti-phase.
    /// 0 for mono input and for silence.
    pub width: f64,
    /// `(E_R - E_L) / (E_R + E_L)` of the K-weighted first two channels over the momentary
    /// window, in `[-1, 1]`: -1 for left only, 1 for right only. 0 for mono input and silence.
    pub balance: f64,
    /// Spectral centroid of the analysis window's magnitude spectrum, `Σ f_k·|X_k| / Σ |X_k|`
    /// over bins `0..=N/2` with `f_k = k·fs/N`, Hz. 0 when the spectrum is zero.
    pub centroid_hz: f64,
    /// Half-wave rectified spectral flux against the previous frame's magnitude spectrum,
    /// normalised by this frame's magnitude sum: `Σ max(0, |X_k| - |P_k|) / Σ |X_k|`, in
    /// `[0, 1]`. 0 for the analyzer's first frame and for a zero spectrum.
    pub spectral_flux: f64,
}

impl Descriptors {
    /// All zeros.
    pub const ZERO: Descriptors = Descriptors {
        momentary_lufs: 0.0,
        short_term_lufs: 0.0,
        width: 0.0,
        balance: 0.0,
        centroid_hz: 0.0,
        spectral_flux: 0.0,
    };
}

/// A biquad `b0 + b1 z^-1 + b2 z^-2 over 1 + a1 z^-1 + a2 z^-2`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Biquad {
    /// Numerator `b0, b1, b2`.
    pub b: [f64; 3],
    /// Denominator `a1, a2`; `a0` is 1.
    pub a: [f64; 2],
}

impl Biquad {
    /// Transposed direct form II.
    fn run(&self, x: f64, state: &mut [f64; 2]) -> f64 {
        let y = self.b[0] * x + state[0];
        state[0] = flush(self.b[1] * x - self.a[0] * y + state[1]);
        state[1] = flush(self.b[2] * x - self.a[1] * y);
        y
    }
}

/// BS.1770-4 K-weighting for `sample_rate_hz`: the high-shelf stage, then the RLB high-pass.
/// The rate must be above twice the shelf frequency (about 3364 Hz).
pub fn k_weighting(sample_rate_hz: u32) -> [Biquad; 2] {
    let rate = sample_rate_hz as f64;
    let f0 = 1681.974450955533;
    let gain_db = 3.999843853973347;
    let q = 0.7071752369554196;
    let k = libm::tan(core::f64::consts::PI * f0 / rate);
    let vh = libm::pow(10.0, gain_db / 20.0);
    let vb = libm::pow(vh, 0.4996667741545416);
    let a0 = 1.0 + k / q + k * k;
    let shelf = Biquad {
        b: [
            (vh + vb * k / q + k * k) / a0,
            2.0 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
        ],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
    };
    let f0 = 38.13547087602444;
    let q = 0.5003270373238773;
    let k = libm::tan(core::f64::consts::PI * f0 / rate);
    let a0 = 1.0 + k / q + k * k;
    let high_pass = Biquad {
        b: [1.0, -2.0, 1.0],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
    };
    [shelf, high_pass]
}

/// BS.1770-4 channel weight for channel `index` of a `channels`-channel layout: 5 channels are
/// L R C Ls Rs, 6 channels L R C LFE Ls Rs and 8 channels L R C LFE Ls Rs Lrs Rrs (the ITU-R
/// BS.2051 system I order). Ls and Rs weigh 1.41, the LFE 0 (excluded), and the 7.1 rear
/// surrounds, outside 60-120 degrees azimuth, 1. Every other layout weighs 1. A 7.1 stream in the
/// WAVEFORMATEXTENSIBLE order (back pair before the side pair) weighs its back pair 1.41.
pub fn channel_weight(channels: usize, index: usize) -> f64 {
    match (channels, index) {
        (5, 3 | 4) | (6 | 8, 4 | 5) => 1.41,
        (6 | 8, 3) => 0.0,
        _ => 1.0,
    }
}

/// Cumulative sums recorded at the starts of future windows of one length.
struct Marks<const K: usize> {
    /// Ring of `(segment position, cumulative sums through that position)`.
    ring: Vec<(u64, [u128; K])>,
    head: usize,
    len: usize,
    /// Window length, samples.
    window: u64,
    /// Every `stride`-th window start is recorded.
    stride: u64,
    /// Segment position of the next start to record; 0 before the first is known.
    next: u64,
}

impl<const K: usize> Marks<K> {
    fn new(window: u64, hop: u64) -> Marks<K> {
        let per_window = |stride: u64| window.div_ceil(stride * hop) + 3;
        let stride = window.div_ceil(hop * (MAX_MARKS - 3)).max(1);
        Marks {
            ring: vec![(0, [0; K]); per_window(stride) as usize],
            head: 0,
            len: 0,
            window,
            stride,
            next: 0,
        }
    }

    /// Forgets every start and finds the first one of a segment whose frames end at
    /// `first_end + k·hop`: the earliest recorded start after the segment's first sample.
    fn begin_segment(&mut self, first_end: u64, hop: u64) {
        self.head = 0;
        self.len = 0;
        let step = self.stride * hop;
        let steps = if first_end > self.window {
            0
        } else {
            (self.window - first_end) / step + 1
        };
        self.next = first_end + steps * step - self.window;
    }

    /// Records `sums` when `position` is the next window start.
    fn accept(&mut self, position: u64, sums: &[u128; 4], hop: u64) {
        if position != self.next {
            return;
        }
        self.next += self.stride * hop;
        if self.len == self.ring.len() {
            debug_assert!(false, "descriptor window ring overflow");
            return;
        }
        let mut values = [0; K];
        values.copy_from_slice(&sums[..K]);
        let slot = (self.head + self.len) % self.ring.len();
        self.ring[slot] = (position, values);
        self.len += 1;
    }

    /// Sums and sample count of the window ending at segment position `end`, the end of the
    /// segment's frame `index`, given the cumulative `sums` through `end`.
    fn window(&mut self, end: u64, index: u64, hop: u64, sums: &[u128; 4]) -> ([u128; K], u64) {
        let mut through = [0; K];
        through.copy_from_slice(&sums[..K]);
        let count = self.window + index % self.stride * hop;
        if count >= end {
            return (through, end);
        }
        let start = end - count;
        while self.len > 0 && self.ring[self.head].0 < start {
            self.head = (self.head + 1) % self.ring.len();
            self.len -= 1;
        }
        if self.len == 0 || self.ring[self.head].0 != start {
            debug_assert!(false, "descriptor window start not recorded");
            return (through, end);
        }
        let before = &self.ring[self.head].1;
        for (value, before) in through.iter_mut().zip(before) {
            *value = value.wrapping_sub(*before);
        }
        (through, count)
    }
}

/// Streaming descriptor state, owned by the analyzer. Allocates in [`DescriptorState::new`] only.
pub(crate) struct DescriptorState {
    /// K-weighting stages; `None` below [`LOUDNESS_MIN_RATE_HZ`].
    filters: Option<[Biquad; 2]>,
    /// Per channel, per stage filter state.
    states: [[[f64; 2]; 2]; DESCRIPTOR_MAX_CHANNELS],
    /// Wrapping cumulative quantised sums since the segment start: weighted power, left, right
    /// and side energy.
    sums: [u128; 4],
    /// Samples in this segment.
    samples: u64,
    /// Frames emitted in this segment.
    frames: u64,
    first_end: u64,
    hop: u64,
    momentary: Marks<4>,
    short_term: Marks<1>,
    bin_hz: f64,
    /// The previous frame's magnitude spectrum, kept across segments like the onset state.
    previous: Vec<f64>,
    has_previous: bool,
}

impl DescriptorState {
    pub(crate) fn new(cfg: &DspConfig) -> DescriptorState {
        let rate = cfg.sample_rate_hz as f64;
        let hop = cfg.hop_samples as u64;
        let first_end = cfg.fft_window_samples as u64;
        let window = |seconds: f64| (libm::round(seconds * rate) as u64).max(1);
        let mut state = DescriptorState {
            filters: (cfg.sample_rate_hz >= LOUDNESS_MIN_RATE_HZ)
                .then(|| k_weighting(cfg.sample_rate_hz)),
            states: [[[0.0; 2]; 2]; DESCRIPTOR_MAX_CHANNELS],
            sums: [0; 4],
            samples: 0,
            frames: 0,
            first_end,
            hop,
            momentary: Marks::new(window(MOMENTARY_SECONDS), hop),
            short_term: Marks::new(window(SHORT_TERM_SECONDS), hop),
            bin_hz: rate / cfg.fft_window_samples as f64,
            previous: vec![0.0; cfg.fft_window_samples as usize / 2 + 1],
            has_previous: false,
        };
        state.begin_segment();
        state
    }

    /// Restarts loudness, width and balance; the spectral flux reference carries over.
    pub(crate) fn begin_segment(&mut self) {
        self.states = [[[0.0; 2]; 2]; DESCRIPTOR_MAX_CHANNELS];
        self.sums = [0; 4];
        self.samples = 0;
        self.frames = 0;
        self.momentary.begin_segment(self.first_end, self.hop);
        self.short_term.begin_segment(self.first_end, self.hop);
    }

    /// Takes one interleaved sample frame, before mixdown. Samples outside `±MAX_SAMPLE`
    /// (including NaN) count as 0, as in the mixdown.
    pub(crate) fn accept<S: Copy + Into<f64>>(&mut self, frame: &[S]) {
        self.samples += 1;
        let Some(filters) = &self.filters else {
            return;
        };
        let channels = frame.len();
        let mut weighted = [0.0; 2];
        for (index, (sample, state)) in frame.iter().zip(&mut self.states).enumerate() {
            let x: f64 = (*sample).into();
            let x = if x.abs() <= MAX_SAMPLE { x } else { 0.0 };
            let y = filters[1].run(filters[0].run(x, &mut state[0]), &mut state[1]);
            let energy = quantise(y * y);
            let weight = channel_weight(channels, index);
            let power = if weight == 1.0 {
                energy
            } else {
                quantise(weight * (y * y))
            };
            self.sums[POWER] = self.sums[POWER].wrapping_add(power);
            // Mono input leaves the left, right and side sums alone, so width and balance read 0.
            if index < 2 && channels >= 2 {
                weighted[index] = y;
                self.sums[LEFT + index] = self.sums[LEFT + index].wrapping_add(energy);
            }
        }
        if channels >= 2 {
            let side = (weighted[0] - weighted[1]) * 0.5;
            self.sums[SIDE] = self.sums[SIDE].wrapping_add(quantise(side * side));
        }
        self.momentary.accept(self.samples, &self.sums, self.hop);
        self.short_term.accept(self.samples, &self.sums, self.hop);
    }

    /// The descriptors of the frame ending at the latest sample, from its magnitude spectrum.
    pub(crate) fn emit(&mut self, mags: &[f64]) -> Descriptors {
        let (end, index, hop) = (self.samples, self.frames, self.hop);
        debug_assert_eq!(end, self.first_end + index * hop);
        self.frames += 1;
        // Below the minimum rate `accept` records no window starts, and every sum stays 0.
        let measured = self.filters.is_some();
        let (momentary, momentary_count) = if measured {
            self.momentary.window(end, index, hop, &self.sums)
        } else {
            ([0; 4], 0)
        };
        let (short_term, short_term_count) = if measured {
            self.short_term.window(end, index, hop, &self.sums)
        } else {
            ([0; 1], 0)
        };
        let (centroid_hz, spectral_flux) = self.spectral(mags);
        Descriptors {
            momentary_lufs: lufs(momentary[POWER], momentary_count),
            short_term_lufs: lufs(short_term[POWER], short_term_count),
            width: if measured { width(&momentary) } else { 0.0 },
            balance: if measured { balance(&momentary) } else { 0.0 },
            centroid_hz,
            spectral_flux,
        }
    }

    fn spectral(&mut self, mags: &[f64]) -> (f64, f64) {
        let mut total = 0.0;
        let mut moment = 0.0;
        let mut rise = 0.0;
        for (k, (mag, previous)) in mags.iter().zip(&mut self.previous).enumerate() {
            total += *mag;
            moment += k as f64 * *mag;
            if *mag > *previous {
                rise += *mag - *previous;
            }
            *previous = *mag;
        }
        let had_previous = core::mem::replace(&mut self.has_previous, true);
        if total <= 0.0 || !total.is_finite() {
            return (0.0, 0.0);
        }
        let centroid = moment / total * self.bin_hz;
        let flux = if had_previous {
            (rise / total).clamp(0.0, 1.0)
        } else {
            0.0
        };
        (centroid, flux)
    }
}

fn flush(value: f64) -> f64 {
    if value.abs() < TINY {
        0.0
    } else {
        value
    }
}

/// `value` in units of 2^-50, rounded down, saturating at 2^64 - 1 units (about 16384).
fn quantise(value: f64) -> u128 {
    (value * SCALE) as u64 as u128
}

/// BS.1770 loudness of a quantised power sum over `count` samples.
fn lufs(sum: u128, count: u64) -> f64 {
    if sum == 0 || count == 0 {
        return LUFS_FLOOR;
    }
    let mean = sum as f64 / SCALE / count as f64;
    (-0.691 + 10.0 * libm::log10(mean)).max(LUFS_FLOOR)
}

fn width(sums: &[u128; 4]) -> f64 {
    let half = (sums[LEFT] as f64 + sums[RIGHT] as f64) * 0.5;
    if half > 0.0 {
        (sums[SIDE] as f64 / half).clamp(0.0, 1.0)
    } else {
        0.0
    }
}

fn balance(sums: &[u128; 4]) -> f64 {
    let (left, right) = (sums[LEFT] as f64, sums[RIGHT] as f64);
    if left + right > 0.0 {
        ((right - left) / (right + left)).clamp(-1.0, 1.0)
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn k_weighting_reproduces_the_bs1770_48_khz_table() {
        let [shelf, high_pass] = k_weighting(48_000);
        let published_shelf = [
            1.53512485958697,
            -2.69169618940638,
            1.19839281085285,
            -1.69065929318241,
            0.73248077421585,
        ];
        let derived = [shelf.b[0], shelf.b[1], shelf.b[2], shelf.a[0], shelf.a[1]];
        for (d, p) in derived.iter().zip(published_shelf) {
            assert!((d - p).abs() < 1e-12, "{d} vs {p}");
        }
        assert_eq!(high_pass.b, [1.0, -2.0, 1.0]);
        assert!((high_pass.a[0] + 1.99004745483398).abs() < 1e-12);
        assert!((high_pass.a[1] - 0.99007225036621).abs() < 1e-12);
    }

    #[test]
    fn channel_weights_exclude_the_lfe_of_5_1_and_7_1() {
        let weights = |channels: usize| (0..channels).map(move |i| channel_weight(channels, i));
        assert!(weights(5).eq([1.0, 1.0, 1.0, 1.41, 1.41]));
        assert!(weights(6).eq([1.0, 1.0, 1.0, 0.0, 1.41, 1.41]));
        assert!(weights(8).eq([1.0, 1.0, 1.0, 0.0, 1.41, 1.41, 1.0, 1.0]));
        for channels in [1, 2, 3, 4, 7] {
            assert!(weights(channels).all(|w| w == 1.0), "{channels} channels");
        }
    }

    #[test]
    fn marks_stay_bounded_and_windows_widen_by_whole_hops() {
        let marks = Marks::<1>::new(3 * 4_294_967_295, 1);
        assert!(marks.ring.len() as u64 <= MAX_MARKS);
        let exact = Marks::<1>::new(144_000, 36);
        assert_eq!(exact.stride, 1);
        assert!(Marks::<1>::new(144_000, 35).stride > 1);
    }

    #[test]
    fn quantisation_saturates_instead_of_wrapping() {
        assert_eq!(quantise(1e300), u64::MAX as u128);
        assert_eq!(quantise(0.0), 0);
        assert_eq!(quantise(1.0), 1 << 50);
    }
}
