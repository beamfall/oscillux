// SPDX-License-Identifier: AGPL-3.0-only
//! In-place radix-2 decimation-in-time FFT with precomputed twiddles, and a real-input
//! magnitude spectrum built on a half-length transform.
//!
//! Computes `X[k] = Σ x[n]·e^(-2πi·kn/N)`, the same transform as a direct DFT. Each twiddle is
//! evaluated directly (no recurrence), so the result differs from the direct sum only by
//! summation order, far below the published tolerances.

use alloc::vec::Vec;
use core::f64::consts::PI;

pub(crate) struct Fft {
    /// `cos(2πk/N)` for `k < N/2`.
    cos: Vec<f64>,
    /// `-sin(2πk/N)` for `k < N/2`.
    neg_sin: Vec<f64>,
}

impl Fft {
    /// `n` must be a power of two of at least 2 (checked by config validation).
    pub(crate) fn new(n: usize) -> Fft {
        let angle = |k: usize| 2.0 * PI * k as f64 / n as f64;
        let cos = (0..n / 2).map(|k| libm::cos(angle(k))).collect();
        let neg_sin = (0..n / 2).map(|k| -libm::sin(angle(k))).collect();
        Fft { cos, neg_sin }
    }

    /// Transforms `re + i·im` in place. Both slices have the length given to [`Fft::new`].
    pub(crate) fn run(&self, re: &mut [f64], im: &mut [f64]) {
        bit_reverse(re, im);
        let n = re.len();
        let stage_lengths = core::iter::successors(Some(2usize), |len| Some(len << 1));
        for len in stage_lengths.take_while(|len| *len <= n) {
            self.stage(re, im, len);
        }
    }

    fn stage(&self, re: &mut [f64], im: &mut [f64], len: usize) {
        let stride = re.len() / len;
        for base in (0..re.len()).step_by(len) {
            self.butterflies(re, im, base, len, stride);
        }
    }

    fn butterflies(&self, re: &mut [f64], im: &mut [f64], base: usize, len: usize, stride: usize) {
        let half = len / 2;
        for k in 0..half {
            let wr = self.cos[k * stride];
            let wi = self.neg_sin[k * stride];
            let a = base + k;
            let b = a + half;
            let xr = re[b] * wr - im[b] * wi;
            let xi = re[b] * wi + im[b] * wr;
            re[b] = re[a] - xr;
            im[b] = im[a] - xi;
            re[a] += xr;
            im[a] += xi;
        }
    }
}

/// Magnitude spectrum of a real sequence through a half-length complex FFT.
///
/// The caller packs `x` of length `N` as `z[n] = x[2n] + i·x[2n+1]` (`N/2` values) and this
/// unpacks bin `k` as `X[k] = E[k] + W^k·O[k]`, with `E[k] = (Z[k] + conj Z[N/2-k]) / 2`,
/// `O[k] = (Z[k] - conj Z[N/2-k]) / 2i` and `W = e^(-2πi/N)`; `X[0]` and `X[N/2]` are
/// `Re Z[0] ± Im Z[0]`.
pub(crate) struct RealFft {
    half: Fft,
    /// `cos(2πk/N)` for `k < N/2`.
    cos: Vec<f64>,
    /// `-sin(2πk/N)` for `k < N/2`.
    neg_sin: Vec<f64>,
}

impl RealFft {
    /// `n` must be a power of two of at least 2.
    pub(crate) fn new(n: usize) -> RealFft {
        let angle = |k: usize| 2.0 * PI * k as f64 / n as f64;
        RealFft {
            half: Fft::new(n / 2),
            cos: (0..n / 2).map(|k| libm::cos(angle(k))).collect(),
            neg_sin: (0..n / 2).map(|k| -libm::sin(angle(k))).collect(),
        }
    }

    /// Transforms the packed `zr + i·zi` (length `N/2`) in place, then writes `|X[k]| / divisor`
    /// for `k < mags.len()` (at most `N/2 + 1` bins).
    pub(crate) fn magnitudes(
        &self,
        zr: &mut [f64],
        zi: &mut [f64],
        divisor: f64,
        mags: &mut [f64],
    ) {
        if zr.len() > 1 {
            self.half.run(zr, zi);
        }
        for (k, mag) in mags.iter_mut().enumerate() {
            let (xr, xi) = self.bin(zr, zi, k);
            *mag = libm::sqrt(xr * xr + xi * xi) / divisor;
        }
    }

    fn bin(&self, zr: &[f64], zi: &[f64], k: usize) -> (f64, f64) {
        let h = zr.len();
        if k == 0 || k == h {
            let sign = if k == 0 { 1.0 } else { -1.0 };
            return (zr[0] + sign * zi[0], 0.0);
        }
        let j = h - k;
        let (er, ei) = ((zr[k] + zr[j]) * 0.5, (zi[k] - zi[j]) * 0.5);
        let (or, oi) = ((zi[k] + zi[j]) * 0.5, (zr[j] - zr[k]) * 0.5);
        let (wr, wi) = (self.cos[k], self.neg_sin[k]);
        (er + (wr * or - wi * oi), ei + (wr * oi + wi * or))
    }
}

fn bit_reverse(re: &mut [f64], im: &mut [f64]) {
    let bits = re.len().trailing_zeros();
    for i in 0..re.len() {
        let j = i.reverse_bits() >> (usize::BITS - bits);
        swap_if_before(re, im, i, j);
    }
}

fn swap_if_before(re: &mut [f64], im: &mut [f64], i: usize, j: usize) {
    if i < j {
        re.swap(i, j);
        im.swap(i, j);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn direct_dft(x: &[f64]) -> (Vec<f64>, Vec<f64>) {
        let n = x.len();
        let bin = |k: usize| {
            let terms = x.iter().enumerate().map(|(t, v)| {
                let angle = 2.0 * PI * (k * t) as f64 / n as f64;
                (v * libm::cos(angle), -v * libm::sin(angle))
            });
            terms.fold((0.0, 0.0), |(r, i), (tr, ti)| (r + tr, i + ti))
        };
        (0..n).map(bin).unzip()
    }

    #[test]
    fn real_fft_matches_direct_dft_magnitudes() {
        for n in [2usize, 4, 8, 256, 1024] {
            let x: Vec<f64> = (0..n)
                .map(|i| libm::sin(i as f64 * 0.61) - 0.4 * libm::cos(i as f64 * 2.3) + 0.1)
                .collect();
            let (want_re, want_im) = direct_dft(&x);
            let (mut zr, mut zi): (Vec<f64>, Vec<f64>) =
                x.chunks_exact(2).map(|pair| (pair[0], pair[1])).unzip();
            let mut mags = vec![0.0; n / 2 + 1];
            RealFft::new(n).magnitudes(&mut zr, &mut zi, 1.0, &mut mags);
            let err = mags
                .iter()
                .enumerate()
                .map(|(k, m)| (m - libm::hypot(want_re[k], want_im[k])).abs())
                .fold(0.0, f64::max);
            assert!(err < 1e-10, "n={n} max error {err}");
        }
    }

    #[test]
    fn matches_direct_dft() {
        let n = 256;
        let x: Vec<f64> = (0..n)
            .map(|i| libm::sin(i as f64 * 0.37) + 0.25 * libm::cos(i as f64 * 1.9))
            .collect();
        let (want_re, want_im) = direct_dft(&x);
        let mut re = x.clone();
        let mut im = vec![0.0; n];
        Fft::new(n).run(&mut re, &mut im);
        let err = re
            .iter()
            .zip(&want_re)
            .chain(im.iter().zip(&want_im))
            .map(|(a, b)| (a - b).abs())
            .fold(0.0, f64::max);
        assert!(err < 1e-10, "max error {err}");
    }
}
