// SPDX-License-Identifier: AGPL-3.0-only
//! Tempo: the normalised onset envelope, its autocorrelation, the global beat period and a
//! local tempo path through a tempogram.

use alloc::vec;
use alloc::vec::Vec;

/// Subtracts the mean over `±half` frames and scales to unit variance.
pub(crate) fn normalise(flux: &[f64], half: usize) -> Vec<f64> {
    let n = flux.len();
    let mut prefix = vec![0.0; n + 1];
    for i in 0..n {
        prefix[i + 1] = prefix[i] + flux[i];
    }
    let mut out: Vec<f64> = (0..n)
        .map(|i| {
            let lo = i.saturating_sub(half);
            let hi = (i + half + 1).min(n);
            flux[i] - (prefix[hi] - prefix[lo]) / (hi - lo) as f64
        })
        .collect();
    let var = out.iter().map(|v| v * v).sum::<f64>() / n.max(1) as f64;
    let sd = libm::sqrt(var);
    if sd > 0.0 {
        for v in out.iter_mut() {
            *v /= sd;
        }
    }
    out
}

/// Autocorrelation `Σ x[i]·x[i+τ] / Σ x[i]²` for `τ ≤ max_lag`.
pub(crate) fn autocorrelation(x: &[f64], max_lag: usize) -> Vec<f64> {
    let n = x.len();
    let mut r = vec![0.0; max_lag + 1];
    for (tau, r) in r.iter_mut().enumerate() {
        if tau >= n {
            break;
        }
        let mut s = 0.0;
        for i in 0..n - tau {
            s += x[i] * x[i + tau];
        }
        *r = s;
    }
    let r0 = r[0];
    if r0 > 0.0 {
        for v in r.iter_mut() {
            *v /= r0;
        }
    }
    r
}

/// Linear interpolation of `r` at fractional lag `lag`; 0 beyond the end.
pub(crate) fn at(r: &[f64], lag: f64) -> f64 {
    if lag < 0.0 {
        return 0.0;
    }
    let i = libm::floor(lag) as usize;
    if i + 1 >= r.len() {
        return 0.0;
    }
    let f = lag - i as f64;
    r[i] * (1.0 - f) + r[i + 1] * f
}

/// Log-Gaussian tempo prior on `log2(lag / centre)` with `octaves` standard deviation.
fn prior(lag: f64, centre: f64, octaves: f64) -> f64 {
    let z = libm::log2(lag / centre) / octaves;
    libm::exp(-0.5 * z * z)
}

/// Periodicity salience at `lag`: the autocorrelation summed over the first four multiples,
/// so that a period whose multiples also repeat wins over its subdivisions.
fn salience(r: &[f64], lag: f64) -> f64 {
    at(r, lag) + at(r, 2.0 * lag) + at(r, 3.0 * lag) + at(r, 4.0 * lag)
}

/// Lag search step, frames.
const LAG_STEP: f64 = 0.25;

/// The global beat period in frames within `[lo, hi]`: the maximum of the prior-weighted
/// salience of the whole-file autocorrelation `r`, refined by parabolic interpolation.
pub(crate) fn global_period(r: &[f64], lo: f64, hi: f64, centre: f64, octaves: f64) -> f64 {
    let steps = libm::floor((hi - lo) / LAG_STEP) as usize;
    let score = |k: usize| {
        let lag = lo + k as f64 * LAG_STEP;
        salience(r, lag) * prior(lag, centre, octaves)
    };
    let mut best = 0;
    let mut best_score = score(0);
    for k in 1..=steps {
        let s = score(k);
        if s > best_score {
            best = k;
            best_score = s;
        }
    }
    let mut lag = lo + best as f64 * LAG_STEP;
    if best > 0 && best < steps {
        let (a, b, c) = (score(best - 1), best_score, score(best + 1));
        let den = a - 2.0 * b + c;
        if den < 0.0 {
            lag += 0.5 * (a - c) / den * LAG_STEP;
        }
    }
    lag
}

/// Local tempo tracking parameters.
#[derive(Clone, Copy, Debug)]
pub(crate) struct PathParams {
    /// Tempogram window half-length, frames.
    pub half: usize,
    /// Tempogram hop, frames.
    pub hop: usize,
    /// Largest local deviation from the global period, as a ratio (> 1).
    pub span: f64,
    /// Viterbi transition cost per squared octave of tempo change.
    pub change: f64,
    /// Cost per squared octave of distance from the global period.
    pub pull: f64,
}

/// Lag bin spacing of the tempogram, frames.
const BIN_STEP: f64 = 0.5;

/// Per-frame beat period (frames) for envelope `x`: a Viterbi path through a local
/// autocorrelation tempogram restricted to `global / span .. global · span` (and `[lo, hi]`).
/// Every `hop` frames, the Hann-weighted autocorrelation of the `±half` frames around the centre
/// scores each lag bin by half its four-multiple salience less `pull` per squared octave from
/// the global period; moving between bins costs `change` per squared octave.
pub(crate) fn tempo_path(x: &[f64], global: f64, lo: f64, hi: f64, p: &PathParams) -> Vec<f64> {
    let n = x.len();
    let lmin = lo.max(global / p.span);
    let lmax = hi.min(global * p.span);
    let bins = (libm::floor((lmax - lmin) / BIN_STEP) as usize + 1).max(1);
    let lag = |b: usize| lmin + b as f64 * BIN_STEP;
    let max_lag = libm::ceil(4.0 * lmax) as usize + 2;
    let centres = n.div_ceil(p.hop).max(1);
    let weights: Vec<f64> = (0..2 * p.half + 1)
        .map(|j| {
            0.5 - 0.5
                * libm::cos(2.0 * core::f64::consts::PI * (j + 1) as f64 / (2 * p.half + 2) as f64)
        })
        .collect();
    let mut r = vec![0.0; max_lag + 1];
    let mut score = vec![0.0; bins];
    let mut next = vec![0.0; bins];
    let mut back: Vec<u32> = vec![0; centres * bins];
    for c in 0..centres {
        let centre = c * p.hop;
        let start = centre.saturating_sub(p.half);
        let end = (centre + p.half + 1).min(n);
        for (tau, r) in r.iter_mut().enumerate() {
            let mut s = 0.0;
            let mut i = start;
            while i + tau < end {
                s += weights[i + p.half - centre] * x[i] * x[i + tau];
                i += 1;
            }
            *r = s;
        }
        let r0 = r[0];
        if r0 > 0.0 {
            for v in r.iter_mut() {
                *v /= r0;
            }
        }
        for b in 0..bins {
            let l = lag(b);
            let d = libm::log2(l / global);
            let local = 0.5 * salience(&r, l) - p.pull * d * d;
            if c == 0 {
                next[b] = local;
                continue;
            }
            let mut best = f64::MIN;
            let mut arg = 0;
            for (a, &s) in score.iter().enumerate() {
                let d = libm::log2(l / lag(a));
                let v = s - p.change * d * d;
                if v > best {
                    best = v;
                    arg = a;
                }
            }
            next[b] = best + local;
            back[c * bins + b] = arg as u32;
        }
        core::mem::swap(&mut score, &mut next);
    }
    let mut b = 0;
    for k in 1..bins {
        if score[k] > score[b] {
            b = k;
        }
    }
    let mut path = vec![0.0; centres];
    for c in (0..centres).rev() {
        path[c] = lag(b);
        b = back[c * bins + b] as usize;
    }
    (0..n)
        .map(|i| {
            let c = i / p.hop;
            let f = (i - c * p.hop) as f64 / p.hop as f64;
            if c + 1 < centres {
                path[c] * (1.0 - f) + path[c + 1] * f
            } else {
                path[centres - 1]
            }
        })
        .collect()
}
