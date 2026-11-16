// SPDX-License-Identifier: AGPL-3.0-only
//! Whole-buffer conveniences over [`Analyzer`]. These allocate their result; they are not for the
//! per-frame path.

use alloc::vec::Vec;

use super::{decode_wav_mono, Analyzer, DspError, DspFrame, DspSettings};

/// A contiguous run of mono samples starting at `media_start_ms`.
#[derive(Clone, Copy, Debug)]
pub struct PcmChunk<'a> {
    /// Media time of the first sample, in milliseconds.
    pub media_start_ms: f64,
    /// Mono samples, full scale 1.0.
    pub samples: &'a [f64],
    /// The capture stalled before this chunk.
    pub stall: bool,
}

/// Analyzes each chunk as its own segment, carrying smoothing and onset state across chunks.
///
/// A bare `&DspConfig` runs behaviour version 1; pass [`DspSettings`] to choose.
pub fn analyze_pcm_chunks(
    settings: impl Into<DspSettings>,
    chunks: &[PcmChunk<'_>],
) -> Result<Vec<DspFrame>, DspError> {
    let mut analyzer = Analyzer::new(settings)?;
    let mut frames = Vec::new();
    for chunk in chunks {
        analyzer.begin_segment(chunk.media_start_ms, chunk.stall);
        push_all(&mut analyzer, chunk.samples, &mut frames)?;
    }
    Ok(frames)
}

/// Decodes a 16-bit PCM WAV and analyzes it as one chunk starting at 0 ms.
///
/// A bare `&DspConfig` runs behaviour version 1; pass [`DspSettings`] to choose.
pub fn analyze_wav(
    settings: impl Into<DspSettings>,
    wav: &[u8],
) -> Result<Vec<DspFrame>, DspError> {
    let settings = settings.into();
    let samples = decode_wav_mono(wav, settings.config.sample_rate_hz)?;
    let chunk = PcmChunk {
        media_start_ms: 0.0,
        samples: &samples,
        stall: false,
    };
    analyze_pcm_chunks(settings, &[chunk])
}

fn push_all(
    analyzer: &mut Analyzer,
    mut samples: &[f64],
    frames: &mut Vec<DspFrame>,
) -> Result<(), DspError> {
    let mut out = [DspFrame::ZERO; 8];
    while !samples.is_empty() {
        let pushed = analyzer.push(samples, 1, &mut out)?;
        frames.extend_from_slice(&out[..pushed.produced]);
        samples = &samples[pushed.consumed..];
    }
    Ok(())
}
