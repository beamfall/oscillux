// SPDX-License-Identifier: AGPL-3.0-only
//! Whole-file onset features: a centred short-time spectrum on a semitone filterbank, its
//! log-compressed spectral flux (broadband and low band) and a per-frame pitch-class profile.

use alloc::vec;
use alloc::vec::Vec;
use core::f64::consts::PI;

use super::fft::PairFft;

/// Lowest filterbank frequency, Hz (A0).
const BAND_MIN_HZ: f64 = 27.5;
/// Highest filterbank frequency, Hz (or the Nyquist frequency when lower).
const BAND_MAX_HZ: f64 = 16_000.0;
/// Log compression `ln(1 + GAMMA·m)` of a band's summed magnitude.
const GAMMA: f64 = 100.0;
/// Bands below this frequency form the low-band flux.
const LOW_MAX_HZ: f64 = 150.0;
/// Pitch-class profile range, Hz.
const CHROMA_MIN_HZ: f64 = 60.0;
const CHROMA_MAX_HZ: f64 = 4_000.0;

/// Onset features, one entry per frame. Frame `i` is centred on sample `i·hop`.
pub(crate) struct Features {
    pub hop: usize,
    pub rate: f64,
    /// Broadband log spectral flux.
    pub flux: Vec<f64>,
    /// Low-band log spectral flux.
    pub low: Vec<f64>,
    /// Log band energies folded onto 12 pitch classes.
    pub chroma: Vec<[f64; 12]>,
}

impl Features {
    pub fn frames(&self) -> usize {
        self.flux.len()
    }

    /// Frames per second.
    pub fn fps(&self) -> f64 {
        self.rate / self.hop as f64
    }
}

/// Analysis window: the smallest power of two of at least 40 ms.
pub(crate) fn window_len(rate: u32) -> usize {
    let min = (f64::from(rate) * 0.04) as usize;
    min.max(4).next_power_of_two()
}

/// Hop: 10 ms, rounded to whole samples.
pub(crate) fn hop_len(rate: u32) -> usize {
    ((f64::from(rate) / 100.0 + 0.5) as usize).max(1)
}

/// Computes the features of `mono` sampled at `rate` Hz.
pub(crate) fn features(mono: &[f64], rate: u32) -> Features {
    let n = window_len(rate);
    let hop = hop_len(rate);
    let frames = mono.len() / hop + 1;
    let fr = f64::from(rate);
    let window: Vec<f64> = (0..n)
        .map(|j| 0.5 - 0.5 * libm::cos(2.0 * PI * j as f64 / n as f64))
        .collect();
    let scale = 4.0 / n as f64;
    // bin k -> band, or usize::MAX outside the filterbank
    let top = BAND_MAX_HZ.min(fr / 2.0);
    let band_of = |f: f64| (12.0 * libm::log2(f / BAND_MIN_HZ) + 0.5) as usize;
    let bins = n / 2 + 1;
    let bands = band_of(top) + 1;
    let map: Vec<usize> = (0..bins)
        .map(|k| {
            let f = k as f64 * fr / n as f64;
            if f < BAND_MIN_HZ || f > top {
                usize::MAX
            } else {
                band_of(f)
            }
        })
        .collect();
    let used: Vec<bool> = (0..bands).map(|b| map.contains(&b)).collect();
    let low_bands = band_of(LOW_MAX_HZ).min(bands);
    let chroma_lo = band_of(CHROMA_MIN_HZ);
    let chroma_hi = band_of(CHROMA_MAX_HZ).min(bands - 1);

    let mut fft = PairFft::new(n);
    let (mut mag_a, mut mag_b) = (vec![0.0; bins], vec![0.0; bins]);
    let mut prev: Vec<f64> = vec![0.0; bands];
    let mut cur: Vec<f64> = vec![0.0; bands];
    let mut out = Features {
        hop,
        rate: fr,
        flux: Vec::with_capacity(frames),
        low: Vec::with_capacity(frames),
        chroma: Vec::with_capacity(frames),
    };
    let fill = |dst: &mut [f64], frame: usize| {
        let start = (frame * hop) as isize - (n / 2) as isize;
        for (j, d) in dst.iter_mut().enumerate() {
            let s = start + j as isize;
            *d = if s >= 0 && (s as usize) < mono.len() {
                mono[s as usize] * window[j]
            } else {
                0.0
            };
        }
    };
    let mut i = 0;
    while i < frames {
        {
            let (re, im) = fft.inputs();
            fill(re, i);
            if i + 1 < frames {
                fill(im, i + 1);
            } else {
                im.fill(0.0);
            }
        }
        fft.magnitudes(&mut mag_a, &mut mag_b);
        for mags in [&mag_a, &mag_b] {
            if out.flux.len() == frames {
                break;
            }
            cur.fill(0.0);
            for (k, &b) in map.iter().enumerate() {
                if b != usize::MAX {
                    cur[b] += mags[k] * scale;
                }
            }
            for c in cur.iter_mut() {
                *c = libm::log(1.0 + GAMMA * *c);
            }
            let first = out.flux.is_empty();
            let (mut flux, mut low) = (0.0, 0.0);
            for b in 0..bands {
                if !used[b] {
                    continue;
                }
                // reference: the previous frame, max-filtered over the neighbouring bands
                let mut r = prev[b];
                if b > 0 && used[b - 1] {
                    r = r.max(prev[b - 1]);
                }
                if b + 1 < bands && used[b + 1] {
                    r = r.max(prev[b + 1]);
                }
                let d = if first { 0.0 } else { (cur[b] - r).max(0.0) };
                flux += d;
                if b < low_bands {
                    low += d;
                }
            }
            let mut chroma = [0.0; 12];
            for b in chroma_lo..=chroma_hi {
                if used[b] {
                    chroma[b % 12] += cur[b];
                }
            }
            out.flux.push(flux);
            out.low.push(low);
            out.chroma.push(chroma);
            core::mem::swap(&mut prev, &mut cur);
        }
        i += 2;
    }
    out
}
