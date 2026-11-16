// SPDX-License-Identifier: AGPL-3.0-only
//! Radix-2 complex FFT that transforms two real frames at once: frame `a` in the real part and
//! frame `b` in the imaginary part, separated afterwards with
//! `A[k] = (Z[k] + conj Z[N-k]) / 2` and `B[k] = (Z[k] - conj Z[N-k]) / 2i`.
//!
//! Twiddles are evaluated directly with `libm`, so every target computes the same bits.

use alloc::vec;
use alloc::vec::Vec;
use core::f64::consts::PI;

pub(crate) struct PairFft {
    n: usize,
    cos: Vec<f64>,
    neg_sin: Vec<f64>,
    re: Vec<f64>,
    im: Vec<f64>,
}

impl PairFft {
    /// `n` is a power of two of at least 4.
    pub(crate) fn new(n: usize) -> PairFft {
        let angle = |k: usize| 2.0 * PI * k as f64 / n as f64;
        PairFft {
            n,
            cos: (0..n / 2).map(|k| libm::cos(angle(k))).collect(),
            neg_sin: (0..n / 2).map(|k| -libm::sin(angle(k))).collect(),
            re: vec![0.0; n],
            im: vec![0.0; n],
        }
    }

    /// Input buffers: fill the real part with frame `a` and the imaginary part with frame `b`.
    pub(crate) fn inputs(&mut self) -> (&mut [f64], &mut [f64]) {
        (&mut self.re, &mut self.im)
    }

    /// Transforms the inputs and writes `|A[k]|` and `|B[k]|` for `k < mag_a.len()` (at most
    /// `N/2 + 1`).
    pub(crate) fn magnitudes(&mut self, mag_a: &mut [f64], mag_b: &mut [f64]) {
        self.run();
        let n = self.n;
        for k in 0..mag_a.len() {
            let j = (n - k) & (n - 1);
            let (zr, zi, cr, ci) = (self.re[k], self.im[k], self.re[j], -self.im[j]);
            let (ar, ai) = ((zr + cr) * 0.5, (zi + ci) * 0.5);
            // (Z - conj Z[N-k]) / 2i: (x + iy) / 2i = (y - ix) / 2
            let (dr, di) = (zr - cr, zi - ci);
            let (br, bi) = (di * 0.5, -dr * 0.5);
            mag_a[k] = libm::sqrt(ar * ar + ai * ai);
            mag_b[k] = libm::sqrt(br * br + bi * bi);
        }
    }

    fn run(&mut self) {
        let n = self.n;
        let bits = n.trailing_zeros();
        for i in 0..n {
            let j = i.reverse_bits() >> (usize::BITS - bits);
            if i < j {
                self.re.swap(i, j);
                self.im.swap(i, j);
            }
        }
        let mut len = 2;
        while len <= n {
            let half = len / 2;
            let stride = n / len;
            for base in (0..n).step_by(len) {
                for k in 0..half {
                    let (wr, wi) = (self.cos[k * stride], self.neg_sin[k * stride]);
                    let (a, b) = (base + k, base + k + half);
                    let xr = self.re[b] * wr - self.im[b] * wi;
                    let xi = self.re[b] * wi + self.im[b] * wr;
                    self.re[b] = self.re[a] - xr;
                    self.im[b] = self.im[a] - xi;
                    self.re[a] += xr;
                    self.im[a] += xi;
                }
            }
            len <<= 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn direct(x: &[f64], k: usize) -> f64 {
        let n = x.len();
        let (mut r, mut i) = (0.0, 0.0);
        for (t, v) in x.iter().enumerate() {
            let a = 2.0 * PI * ((k * t) % n) as f64 / n as f64;
            r += v * libm::cos(a);
            i -= v * libm::sin(a);
        }
        libm::sqrt(r * r + i * i)
    }

    #[test]
    fn pair_matches_direct_dft() {
        let n = 64;
        let a: Vec<f64> = (0..n).map(|i| libm::sin(i as f64 * 0.37) + 0.2).collect();
        let b: Vec<f64> = (0..n).map(|i| libm::cos(i as f64 * 1.9) - 0.1).collect();
        let mut fft = PairFft::new(n);
        let (re, im) = fft.inputs();
        re.copy_from_slice(&a);
        im.copy_from_slice(&b);
        let (mut ma, mut mb) = (vec![0.0; n / 2 + 1], vec![0.0; n / 2 + 1]);
        fft.magnitudes(&mut ma, &mut mb);
        for k in 0..=n / 2 {
            assert!((ma[k] - direct(&a, k)).abs() < 1e-10, "a {k}");
            assert!((mb[k] - direct(&b, k)).abs() < 1e-10, "b {k}");
        }
    }
}
