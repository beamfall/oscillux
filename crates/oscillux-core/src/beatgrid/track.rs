// SPDX-License-Identifier: AGPL-3.0-only
//! Dynamic-programming beat tracking over the whole envelope with a time-varying period
//! (Ellis 2007, with the period taken from the tempo path at each frame).

use alloc::vec;
use alloc::vec::Vec;

/// Beat frames that maximise the summed envelope at the beats minus `tightness·ln²(Δ/τ)` per
/// interval `Δ`, with `τ = period[t]` frames at the later beat.
pub(crate) fn track(env: &[f64], period: &[f64], tightness: f64) -> Vec<usize> {
    let n = env.len();
    if n == 0 {
        return Vec::new();
    }
    let mut score = vec![0.0; n];
    let mut back = vec![usize::MAX; n];
    for t in 0..n {
        let tau = period[t];
        let lo = t as f64 - 2.0 * tau;
        let hi = t as f64 - 0.5 * tau;
        let mut best = 0.0;
        let mut arg = usize::MAX;
        if hi >= 0.0 {
            let lo = if lo < 0.0 { 0 } else { libm::ceil(lo) as usize };
            let hi = libm::floor(hi) as usize;
            for (p, &prev) in score.iter().enumerate().take(hi + 1).skip(lo) {
                let d = libm::log((t - p) as f64 / tau);
                let s = prev - tightness * d * d;
                if s > best {
                    best = s;
                    arg = p;
                }
            }
        }
        score[t] = env[t] + best;
        back[t] = arg;
    }
    // end: the best cumulative score
    let mut end = 0;
    for t in 1..n {
        if score[t] > score[end] {
            end = t;
        }
    }
    let mut beats = Vec::new();
    let mut t = end;
    loop {
        beats.push(t);
        if back[t] == usize::MAX {
            break;
        }
        t = back[t];
    }
    beats.reverse();
    beats
}

/// Sub-frame position of the envelope peak nearest beat frame `b`: the maximum within `±reach`
/// frames, refined by parabolic interpolation.
pub(crate) fn refine(env: &[f64], b: usize, reach: usize) -> f64 {
    let n = env.len();
    let lo = b.saturating_sub(reach);
    let hi = (b + reach).min(n - 1);
    let mut m = b.min(n - 1);
    for i in lo..=hi {
        if env[i] > env[m] {
            m = i;
        }
    }
    if m == 0 || m + 1 >= n {
        return m as f64;
    }
    let (a, c, d) = (env[m - 1], env[m], env[m + 1]);
    let den = a - 2.0 * c + d;
    // only at a local maximum: a window maximum at the edge of a rising slope has its vertex
    // far outside the window
    if a <= c && d <= c && den < 0.0 {
        m as f64 + 0.5 * (a - d) / den
    } else {
        m as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A window maximum at the edge of a rising, concave slope stays on its frame: the
    /// parabola's vertex lies outside the window (OSC-BEAT-GRID-TRACK-BIAS).
    #[test]
    fn refine_keeps_an_edge_maximum_on_its_frame() {
        let env = [0.0, 10.0, 18.0, 24.0, 28.0, 30.0, 31.0, 31.5];
        assert_eq!(refine(&env, 3, 2), 5.0);
        assert_eq!(refine(&env, 3, 100), 7.0);
    }

    /// An interior peak is still interpolated toward its higher neighbour.
    #[test]
    fn refine_interpolates_an_interior_peak() {
        let env = [0.0, 1.0, 3.0, 4.0, 2.0, 0.0, 0.0];
        assert!((refine(&env, 3, 2) - (3.0 - 1.0 / 6.0)).abs() < 1e-12);
        assert!((refine(&env, 5, 2) - (3.0 - 1.0 / 6.0)).abs() < 1e-12);
    }
}
