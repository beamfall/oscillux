// SPDX-License-Identifier: AGPL-3.0-only
//! 16-bit PCM RIFF/WAVE decoding with channel averaging.

use alloc::vec::Vec;

use super::DspError;

#[derive(Default)]
struct Format {
    channels: u16,
    sample_rate: u32,
    bits: u16,
}

/// Decodes 16-bit PCM WAV bytes to mono samples in `[-1, 1)`: each sample is `raw / 32768`,
/// and channels are averaged. The file's sample rate must equal `sample_rate_hz`.
pub fn decode_wav_mono(data: &[u8], sample_rate_hz: u32) -> Result<Vec<f64>, DspError> {
    let riff = data.len() >= 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WAVE";
    if !riff {
        return Err(DspError::Wav("not a RIFF/WAVE file"));
    }
    let (format, pcm) = read_chunks(data)?;
    check_format(&format, pcm, sample_rate_hz)?;
    let frame_bytes = format.channels as usize * 2;
    Ok(pcm.chunks_exact(frame_bytes).map(mix_frame).collect())
}

fn read_chunks(data: &[u8]) -> Result<(Format, &[u8]), DspError> {
    let mut format = Format::default();
    let mut pcm: &[u8] = &[];
    let mut off = 12;
    while off + 8 <= data.len() {
        let id = &data[off..off + 4];
        let size = u32_at(data, off + 4) as usize;
        let body_start = off + 8;
        let body = body_start
            .checked_add(size)
            .and_then(|end| data.get(body_start..end))
            .ok_or(DspError::Wav("truncated WAV chunk"))?;
        match id {
            b"fmt " => format = parse_fmt(body)?,
            b"data" => pcm = body,
            _ => {}
        }
        off = body_start + size + size % 2;
    }
    Ok((format, pcm))
}

fn parse_fmt(body: &[u8]) -> Result<Format, DspError> {
    if body.len() < 16 {
        return Err(DspError::Wav("short fmt chunk"));
    }
    if u16_at(body, 0) != 1 {
        return Err(DspError::Wav("unsupported WAV format"));
    }
    Ok(Format {
        channels: u16_at(body, 2),
        sample_rate: u32_at(body, 4),
        bits: u16_at(body, 14),
    })
}

fn check_format(format: &Format, pcm: &[u8], sample_rate_hz: u32) -> Result<(), DspError> {
    let present = format.channels != 0 && format.sample_rate != 0 && !pcm.is_empty();
    let checks: [(bool, &'static str); 4] = [
        (present, "missing WAV fmt or data chunk"),
        (format.sample_rate == sample_rate_hz, "sample rate mismatch"),
        (format.bits == 16, "bits per sample must be 16"),
        (
            pcm.len() % (format.channels as usize * 2).max(1) == 0,
            "unaligned PCM data",
        ),
    ];
    match checks.iter().find(|(ok, _)| !ok) {
        Some((_, why)) => Err(DspError::Wav(why)),
        None => Ok(()),
    }
}

fn mix_frame(frame: &[u8]) -> f64 {
    let sum = frame
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]) as f64 / 32768.0)
        .fold(0.0, |sum, s| sum + s);
    sum / (frame.len() / 2) as f64
}

fn u16_at(data: &[u8], off: usize) -> u16 {
    u16::from_le_bytes([data[off], data[off + 1]])
}

fn u32_at(data: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wav(channels: u16, rate: u32, frames: &[i16]) -> Vec<u8> {
        let data_len = (frames.len() * 2) as u32;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&rate.to_le_bytes());
        out.extend_from_slice(&(rate * 2 * channels as u32).to_le_bytes());
        out.extend_from_slice(&(2 * channels).to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_len.to_le_bytes());
        frames
            .iter()
            .for_each(|s| out.extend_from_slice(&s.to_le_bytes()));
        out
    }

    #[test]
    fn averages_stereo() {
        let bytes = wav(2, 48_000, &[16384, -16384, 32767, 1]);
        let samples = decode_wav_mono(&bytes, 48_000).unwrap();
        assert_eq!(
            samples,
            vec![0.0, (32767.0 / 32768.0 + 1.0 / 32768.0) / 2.0]
        );
    }

    #[test]
    fn rejects_wrong_rate_and_truncation() {
        let bytes = wav(1, 44_100, &[0, 1]);
        assert_eq!(
            decode_wav_mono(&bytes, 48_000),
            Err(DspError::Wav("sample rate mismatch"))
        );
        let good = wav(1, 48_000, &[0, 1]);
        assert_eq!(
            decode_wav_mono(&good[..good.len() - 1], 48_000),
            Err(DspError::Wav("truncated WAV chunk"))
        );
        assert_eq!(
            decode_wav_mono(b"RIFX0000WAVE", 48_000),
            Err(DspError::Wav("not a RIFF/WAVE file"))
        );
    }
}
