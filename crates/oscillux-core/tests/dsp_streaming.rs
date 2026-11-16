// SPDX-License-Identifier: AGPL-3.0-only
//! Streaming behaviour: slicing, output back-pressure, mixdown, and no allocation after creation.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use oscillux_core::dsp::{
    analyze_wav, decode_wav_mono, Analyzer, DspConfig, DspFrame, DspSettings,
};

/// Counts allocations made by the current thread while armed.
struct CountingAlloc;

thread_local! {
    static ARMED: Cell<bool> = const { Cell::new(false) };
    static COUNT: Cell<usize> = const { Cell::new(0) };
}

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if ARMED.with(Cell::get) {
            COUNT.with(|c| c.set(c.get() + 1));
        }
        System.alloc(layout)
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }
}

#[global_allocator]
static GLOBAL: CountingAlloc = CountingAlloc;

const WAV: &[u8] = include_bytes!("../../../conformance/dsp/kicks-120bpm.wav");

/// Behaviour version 1 (a bare config) and version 2 (the default settings).
fn both_versions() -> [DspSettings; 2] {
    [DspConfig::default().into(), DspSettings::default()]
}

/// Pushes `samples` in slices of cycling sizes into an output buffer of `capacity` frames.
fn stream(
    analyzer: &mut Analyzer,
    samples: &[f32],
    channels: usize,
    capacity: usize,
) -> Vec<DspFrame> {
    let sizes = [1usize, 7, 128, 513, 2048, 4999];
    let mut out = vec![DspFrame::ZERO; capacity];
    let mut frames = Vec::new();
    let mut rest = samples;
    for size in sizes.iter().cycle() {
        if rest.is_empty() {
            break;
        }
        let take = (size * channels).min(rest.len());
        let (slice, tail) = rest.split_at(take);
        frames.extend(drain(analyzer, slice, channels, &mut out));
        rest = tail;
    }
    frames
}

fn drain(
    analyzer: &mut Analyzer,
    mut slice: &[f32],
    channels: usize,
    out: &mut [DspFrame],
) -> Vec<DspFrame> {
    let mut frames = Vec::new();
    while !slice.is_empty() {
        let pushed = analyzer.push(slice, channels, out).unwrap();
        frames.extend_from_slice(&out[..pushed.produced]);
        slice = &slice[pushed.consumed * channels..];
    }
    frames
}

#[test]
fn sliced_stereo_f32_stream_equals_offline_analysis() {
    for settings in both_versions() {
        let offline = analyze_wav(settings, WAV).unwrap();
        let mono = decode_wav_mono(WAV, settings.config.sample_rate_hz).unwrap();
        let stereo: Vec<f32> = mono.iter().flat_map(|s| [*s as f32, *s as f32]).collect();
        for capacity in [1, 3] {
            let mut analyzer = Analyzer::new(settings).unwrap();
            let streamed = stream(&mut analyzer, &stereo, 2, capacity);
            let version = settings.behavior_version;
            assert_eq!(streamed, offline, "v{version} capacity {capacity}");
        }
    }
}

#[test]
fn full_output_buffer_stops_before_the_completing_sample() {
    let cfg = DspConfig::default();
    let mut analyzer = Analyzer::new(cfg).unwrap();
    let samples = vec![0.0f64; cfg.fft_window_samples as usize + 10];
    let pushed = analyzer.push(&samples, 1, &mut []).unwrap();
    assert_eq!(pushed.consumed, cfg.fft_window_samples as usize - 1);
    assert_eq!(pushed.produced, 0);
}

#[test]
fn push_and_segments_do_not_allocate() {
    for settings in both_versions() {
        let samples = decode_wav_mono(WAV, settings.config.sample_rate_hz).unwrap();
        let mut analyzer = Analyzer::new(settings).unwrap();
        let mut out = [DspFrame::ZERO; 4];
        COUNT.with(|c| c.set(0));
        ARMED.with(|a| a.set(true));
        for (i, chunk) in samples.chunks(700).enumerate() {
            if i % 50 == 49 {
                analyzer.begin_segment(i as f64 * 20.0, true);
            }
            let mut rest = chunk;
            while !rest.is_empty() {
                let pushed = analyzer.push(rest, 1, &mut out).unwrap();
                rest = &rest[pushed.consumed..];
            }
        }
        ARMED.with(|a| a.set(false));
        assert_eq!(COUNT.with(Cell::get), 0, "v{}", settings.behavior_version);
    }
}
