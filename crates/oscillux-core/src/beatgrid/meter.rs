// SPDX-License-Identifier: AGPL-3.0-only
//! Bar positions: a per-beat downbeat cue (harmonic change between beat-synchronous pitch-class
//! profiles plus low-band onset strength) decoded by a Viterbi pass over positions in the bar.

use alloc::vec;
use alloc::vec::Vec;

/// Downbeat decoding parameters.
#[derive(Clone, Copy, Debug)]
pub(crate) struct MeterParams {
    /// Weight of the harmonic-change cue.
    pub harmonic: f64,
    /// Weight of the low-band onset cue.
    pub low: f64,
}

/// Standardises `v` to zero mean and unit variance (unchanged when constant).
fn standardise(v: &mut [f64]) {
    let n = v.len().max(1) as f64;
    let mean = v.iter().sum::<f64>() / n;
    let var = v.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / n;
    let sd = libm::sqrt(var);
    for x in v.iter_mut() {
        *x = if sd > 0.0 { (*x - mean) / sd } else { 0.0 };
    }
}

/// Per-beat downbeat cue for beat frames `beats` (ascending).
pub(crate) fn cue(beats: &[usize], chroma: &[[f64; 12]], low: &[f64], p: &MeterParams) -> Vec<f64> {
    let n = beats.len();
    let frames = chroma.len();
    // beat-synchronous pitch-class profiles, unit length
    let profiles: Vec<[f64; 12]> = (0..n)
        .map(|i| {
            let start = beats[i].min(frames);
            let end = if i + 1 < n { beats[i + 1] } else { frames }
                .min(frames)
                .max(start);
            let mut m = [0.0; 12];
            for c in &chroma[start..end] {
                for k in 0..12 {
                    m[k] += c[k];
                }
            }
            let norm = libm::sqrt(m.iter().map(|v| v * v).sum::<f64>());
            if norm > 0.0 {
                for v in m.iter_mut() {
                    *v /= norm;
                }
            }
            m
        })
        .collect();
    let mut harmonic: Vec<f64> = (0..n)
        .map(|i| {
            if i == 0 {
                return 0.0;
            }
            let dot: f64 = (0..12).map(|k| profiles[i - 1][k] * profiles[i][k]).sum();
            1.0 - dot
        })
        .collect();
    let mut bass: Vec<f64> = beats
        .iter()
        .map(|&b| {
            let lo = b.saturating_sub(2);
            let hi = (b + 3).min(low.len());
            low[lo.min(hi)..hi].iter().copied().fold(0.0, f64::max)
        })
        .collect();
    standardise(&mut harmonic);
    standardise(&mut bass);
    harmonic
        .iter()
        .zip(&bass)
        .map(|(h, l)| p.harmonic * h + p.low * l)
        .collect()
}

/// Bar positions (0 = downbeat) for `cue` under meter `m`, and the decoded path's contrast:
/// the mean cue at downbeats minus the mean elsewhere.
pub(crate) fn decode(cue: &[f64], m: usize, jump: f64) -> (Vec<u32>, f64) {
    let n = cue.len();
    if n == 0 || m == 0 {
        return (Vec::new(), 0.0);
    }
    let mut score = vec![0.0; m];
    let mut next = vec![0.0; m];
    let mut back = vec![0u8; n * m];
    for (i, &c) in cue.iter().enumerate() {
        for pos in 0..m {
            let emit = if pos == 0 { c } else { 0.0 };
            if i == 0 {
                next[pos] = emit;
                continue;
            }
            let follow = (pos + m - 1) % m;
            let mut best = score[follow];
            let mut arg = follow;
            for (q, &s) in score.iter().enumerate() {
                if q != follow && s - jump > best {
                    best = s - jump;
                    arg = q;
                }
            }
            next[pos] = best + emit;
            back[i * m + pos] = arg as u8;
        }
        core::mem::swap(&mut score, &mut next);
    }
    let mut pos = 0;
    for q in 1..m {
        if score[q] > score[pos] {
            pos = q;
        }
    }
    let mut out = vec![0u32; n];
    for i in (0..n).rev() {
        out[i] = pos as u32;
        pos = back[i * m + pos] as usize;
    }
    let (mut down, mut nd, mut other, mut no) = (0.0, 0usize, 0.0, 0usize);
    for (c, &p) in cue.iter().zip(&out) {
        if p == 0 {
            down += c;
            nd += 1;
        } else {
            other += c;
            no += 1;
        }
    }
    let contrast = down / nd.max(1) as f64 - other / no.max(1) as f64;
    (out, contrast)
}
