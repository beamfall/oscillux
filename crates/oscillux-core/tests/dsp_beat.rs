// SPDX-License-Identifier: AGPL-3.0-only
//! Beat tracker conformance (`conformance/dsp/music/beat/`, `conformance/dsp/music/beat-v4/`):
//! every sampled output row matches the stdlib oracle bit for bit and the digest over every
//! frame matches, for the tracker of behaviour versions 1 and 2, that of version 3 and that of
//! version 4; plus validation, reset and no allocation after creation.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use oscillux_core::dsp::{
    Beat, BeatConfig, BeatTracker, DspConfig, DspError, DspFrame, DspSettings, DSP_BEHAVIOR_V4,
    MAX_BANDS,
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

const VECTORS: [(&str, &str); 6] = [
    (
        "beat-default",
        include_str!("../../../conformance/dsp/music/beat/beat-default.vectors"),
    ),
    (
        "beat-config-32k",
        include_str!("../../../conformance/dsp/music/beat/beat-config-32k.vectors"),
    ),
    (
        "beat-v3-default",
        include_str!("../../../conformance/dsp/music/beat/beat-v3-default.vectors"),
    ),
    (
        "beat-v3-config-32k",
        include_str!("../../../conformance/dsp/music/beat/beat-v3-config-32k.vectors"),
    ),
    (
        "beat-v4-default",
        include_str!("../../../conformance/dsp/music/beat-v4/beat-v4-default.vectors"),
    ),
    (
        "beat-v4-config-16k",
        include_str!("../../../conformance/dsp/music/beat-v4/beat-v4-config-16k.vectors"),
    ),
];

struct Expected {
    frame: usize,
    beat: Beat,
}

struct Vector {
    name: &'static str,
    settings: DspSettings,
    beat_config: BeatConfig,
    inputs: Vec<DspFrame>,
    outputs: Vec<Expected>,
    digest: u64,
}

fn parse(name: &'static str, text: &str) -> Vector {
    let mut lines = text.lines();
    // Format 2 adds an onset_high input column, for behaviour version 3.
    let onsets = match lines.next() {
        Some("# dsp-beat-vectors v1") => 2,
        Some("# dsp-beat-vectors v2") => 3,
        other => panic!("{name}: header {other:?}"),
    };
    let mut v = Vector {
        name,
        settings: DspSettings::default(),
        beat_config: BeatConfig::default(),
        inputs: Vec::new(),
        outputs: Vec::new(),
        digest: 0,
    };
    for line in lines.filter(|line| !line.starts_with('#')) {
        let f: Vec<&str> = line.split_whitespace().collect();
        let cfg = &mut v.settings.config;
        match (f[0], f.get(1).copied().unwrap_or("")) {
            ("config", "behavior_version") => v.settings.behavior_version = f[2].parse().unwrap(),
            ("config", "sample_rate_hz") => cfg.sample_rate_hz = f[2].parse().unwrap(),
            ("config", "hop_samples") => cfg.hop_samples = f[2].parse().unwrap(),
            ("config", "fft_window_samples") => cfg.fft_window_samples = f[2].parse().unwrap(),
            ("config", "spectrum_bands") => cfg.spectrum_bands = f[2].parse().unwrap(),
            ("config", "spectrum_min_hz") => cfg.spectrum_min_hz = f[2].parse().unwrap(),
            ("config", "spectrum_max_hz") => cfg.spectrum_max_hz = f[2].parse().unwrap(),
            ("config", "onset_band_groups") => {
                for (group, ends) in cfg.onset_band_groups.iter_mut().zip(f[2].split(',')) {
                    let (a, b) = ends.split_once('-').unwrap();
                    *group = [a.parse().unwrap(), b.parse().unwrap()];
                }
            }
            ("beat_config", "min_bpm") => v.beat_config.min_bpm = f[2].parse().unwrap(),
            ("beat_config", "max_bpm") => v.beat_config.max_bpm = f[2].parse().unwrap(),
            ("beat_config", "beats_per_bar") => v.beat_config.beats_per_bar = f[2].parse().unwrap(),
            ("in", _) => {
                let n: Vec<u32> = f[1..].iter().map(|s| s.parse().unwrap()).collect();
                let q = |i: usize| f64::from(n[i]) / 256.0;
                let mut frame = DspFrame::ZERO;
                frame.sequence = v.inputs.len() as u64;
                frame.flags = n[0];
                let first = 1 + onsets;
                frame.band_count = (n.len() - first) as u32;
                frame.onset.low = q(1);
                frame.onset.mid = q(2);
                if onsets == 3 {
                    frame.onset.high = q(3);
                }
                for b in 0..n.len() - first {
                    frame.spectrum[b] = q(first + b);
                }
                v.inputs.push(frame);
            }
            ("out", _) => {
                let x = |i: usize| f[i].parse::<f64>().unwrap();
                let u = |i: usize| f[i].parse::<u32>().unwrap();
                v.outputs.push(Expected {
                    frame: f[1].parse().unwrap(),
                    beat: Beat {
                        tempo_bpm: x(2),
                        beat_phase: x(3),
                        bar_phase: x(4),
                        confidence: x(5),
                        beat: u(6),
                        downbeat: u(7),
                        beat_in_bar: u(8),
                        reserved: 0,
                    },
                });
            }
            ("digest", _) => v.digest = u64::from_str_radix(f[1], 16).unwrap(),
            _ => panic!("{name}: unknown row {line:?}"),
        }
    }
    assert!(v.inputs.iter().all(|f| f.band_count as usize <= MAX_BANDS));
    v
}

fn fnv1a(hash: u64, bytes: &[u8]) -> u64 {
    bytes.iter().fold(hash, |h, &b| {
        (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// The oracle's digest step: FNV-1a over a frame's four little-endian f64 and three u32.
fn digest_step(mut h: u64, b: &Beat) -> u64 {
    for x in [b.tempo_bpm, b.beat_phase, b.bar_phase, b.confidence] {
        h = fnv1a(h, &x.to_le_bytes());
    }
    for n in [b.beat, b.downbeat, b.beat_in_bar] {
        h = fnv1a(h, &n.to_le_bytes());
    }
    h
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

fn digest(outputs: &[Beat]) -> u64 {
    outputs.iter().fold(FNV_OFFSET, digest_step)
}

fn run(v: &Vector, tracker: &mut BeatTracker) -> Vec<Beat> {
    v.inputs.iter().map(|frame| tracker.update(frame)).collect()
}

fn vectors() -> Vec<Vector> {
    VECTORS
        .iter()
        .map(|&(name, text)| parse(name, text))
        .collect()
}

fn same(a: &Beat, b: &Beat) -> bool {
    let bits = |x: &Beat| [x.tempo_bpm, x.beat_phase, x.bar_phase, x.confidence].map(f64::to_bits);
    bits(a) == bits(b)
        && (a.beat, a.downbeat, a.beat_in_bar, a.reserved)
            == (b.beat, b.downbeat, b.beat_in_bar, b.reserved)
}

#[test]
fn beat_vectors_match_bit_for_bit() {
    for v in vectors() {
        let mut tracker = BeatTracker::new(&v.settings, v.beat_config).expect("tracker");
        let got = run(&v, &mut tracker);
        for e in &v.outputs {
            assert!(
                same(&got[e.frame], &e.beat),
                "{} frame {}: got {:?}, expected {:?}",
                v.name,
                e.frame,
                got[e.frame],
                e.beat
            );
        }
        let beats = got.iter().filter(|b| b.beat == 1).count();
        let sampled = v.outputs.iter().filter(|e| e.beat.beat == 1).count();
        assert_eq!(beats, sampled, "{}: every beat frame is sampled", v.name);
        assert_eq!(digest(&got), v.digest, "{}: digest", v.name);
        println!(
            "{}: {} frames, {beats} beats, digest {:016x}",
            v.name,
            got.len(),
            v.digest
        );
    }
}

#[test]
fn reset_repeats_the_stream_and_update_does_not_allocate() {
    for v in vectors() {
        let mut tracker = BeatTracker::new(&v.settings, v.beat_config).expect("tracker");
        COUNT.with(|c| c.set(0));
        ARMED.with(|a| a.set(true));
        let mut digests = [FNV_OFFSET; 2];
        for d in &mut digests {
            for frame in &v.inputs {
                *d = digest_step(*d, &tracker.update(frame));
            }
            tracker.reset();
        }
        ARMED.with(|a| a.set(false));
        assert_eq!(
            COUNT.with(Cell::get),
            0,
            "{}: update or reset allocated",
            v.name
        );
        assert_eq!(
            digests, [v.digest; 2],
            "{}: digest before and after reset",
            v.name
        );
    }
}

#[test]
fn outputs_stay_in_range() {
    for v in vectors() {
        let mut tracker = BeatTracker::new(&v.settings, v.beat_config).expect("tracker");
        let bpb = v.beat_config.beats_per_bar;
        for b in run(&v, &mut tracker) {
            assert!((0.0..1.0).contains(&b.beat_phase), "{}: {b:?}", v.name);
            assert!((0.0..1.0).contains(&b.bar_phase), "{}: {b:?}", v.name);
            assert!((0.0..=1.0).contains(&b.confidence), "{}: {b:?}", v.name);
            assert!(b.beat_in_bar < bpb && b.downbeat <= b.beat && b.reserved == 0);
            if b.tempo_bpm != 0.0 {
                assert!(b.tempo_bpm >= v.beat_config.min_bpm * 0.94);
                assert!(b.tempo_bpm <= v.beat_config.max_bpm * 1.06);
            }
        }
    }
}

#[test]
fn non_finite_inputs_read_as_zero() {
    // beat-default, beat-v3-default and beat-v4-default.
    for v in vectors().into_iter().step_by(2) {
        let mut clean = BeatTracker::new(&v.settings, v.beat_config).unwrap();
        let mut dirty = clean.clone();
        for frame in &v.inputs {
            let mut bad = *frame;
            if frame.onset.low == 0.0 {
                bad.onset.low = f64::NAN;
            }
            if frame.onset.mid == 0.0 {
                bad.onset.mid = -1.0;
            }
            if frame.onset.high == 0.0 {
                bad.onset.high = f64::NEG_INFINITY;
            }
            if frame.spectrum[0] == 0.0 {
                bad.spectrum[0] = f64::INFINITY;
            }
            assert!(
                same(&clean.update(frame), &dirty.update(&bad)),
                "{}",
                v.name
            );
        }
    }
}

#[test]
fn invalid_configurations_are_refused() {
    let settings = DspSettings::default();
    let with = |f: fn(&mut BeatConfig)| {
        let mut c = BeatConfig::default();
        f(&mut c);
        BeatTracker::new(&settings, c).err()
    };
    let invalid = |field| Some(DspError::InvalidConfig(field));
    assert_eq!(with(|c| c.min_bpm = 0.0), invalid("min_bpm"));
    assert_eq!(with(|c| c.min_bpm = f64::NAN), invalid("min_bpm"));
    assert_eq!(with(|c| c.max_bpm = 80.0), invalid("max_bpm"));
    assert_eq!(with(|c| c.max_bpm = f64::INFINITY), invalid("max_bpm"));
    // 93.75 frames/s: a period below 8 frames (above ~703 BPM) or above 1024 frames.
    assert_eq!(with(|c| c.max_bpm = 750.0), invalid("max_bpm"));
    assert_eq!(with(|c| c.min_bpm = 5.0), invalid("min_bpm"));
    assert_eq!(with(|c| c.beats_per_bar = 0), invalid("beats_per_bar"));
    assert_eq!(with(|c| c.beats_per_bar = 17), invalid("beats_per_bar"));
    assert_eq!(with(|c| c.beats_per_bar = 16), None);
    let bad = DspSettings {
        config: DspConfig {
            hop_samples: 0,
            ..DspConfig::default()
        },
        ..DspSettings::default()
    };
    assert!(BeatTracker::new(&bad, BeatConfig::default()).is_err());
}

#[test]
fn version_4_bounds_the_longest_period() {
    let settings = DspSettings {
        behavior_version: DSP_BEHAVIOR_V4,
        ..DspSettings::default()
    };
    let with = |min_bpm| {
        let beat = BeatConfig {
            min_bpm,
            ..BeatConfig::default()
        };
        BeatTracker::new(&settings, beat).err()
    };
    // 93.75 frames/s: 11 BPM is a 512-frame period, 10 BPM a 563-frame one (version 3 takes
    // periods up to 1024 frames).
    assert_eq!(with(11.0), None);
    assert_eq!(with(10.0), Some(DspError::InvalidConfig("min_bpm")));
    assert_eq!(with(5.0), Some(DspError::InvalidConfig("min_bpm")));
}

/// 120 BPM onset pulses at 93.75 frames/s within the `on` ranges, with an off-beat hat; no
/// onsets elsewhere. The spectrum holds steady throughout, so the downbeat never moves.
fn pulses(frames: usize, on: &[(usize, usize)]) -> Vec<DspFrame> {
    let period = 93.75 * 60.0 / 120.0;
    (0..frames)
        .map(|n| {
            let mut frame = DspFrame::ZERO;
            frame.spectrum[..24].fill(0.5);
            if on.iter().any(|&(a, b)| a <= n && n < b) {
                let phase = n as f64 / period;
                let beat = (phase - phase.floor()) * period < 1.0;
                let half = ((phase + 0.5) - (phase + 0.5).floor()) * period < 1.0;
                frame.onset.low = if beat { 0.9 } else { 0.02 };
                frame.onset.mid = if half { 0.4 } else { 0.02 };
            }
            frame
        })
        .collect()
}

#[test]
fn no_beats_without_recent_onsets_and_bar_phase_keeps_running() {
    let fr = 93.75;
    let period = fr * 60.0 / 120.0;
    let (loud, quiet) = ((15.0 * fr) as usize, (180.0 * fr) as usize);
    let total = loud + quiet + (10.0 * fr) as usize;
    let frames = pulses(total, &[(0, loud), (loud + quiet, total)]);
    let mut tracker = BeatTracker::new(&DspSettings::default(), BeatConfig::default()).unwrap();
    let out: Vec<Beat> = frames.iter().map(|f| tracker.update(f)).collect();

    let locked = &out[loud - 1];
    assert!((locked.tempo_bpm - 120.0).abs() < 2.0, "{locked:?}");
    // Two frames of onset-picker delay, sixteen periods of recency, one frame of rounding.
    let last_allowed = loud + (16.0 * period) as usize + 3;
    let late: Vec<usize> = (last_allowed..loud + quiet)
        .filter(|&t| out[t].beat == 1)
        .collect();
    assert!(late.is_empty(), "beats in silence at frames {late:?}");
    let bpb = 4.0;
    // From a few frames into the silence, past the onset picker's delay, the phase histogram
    // only decays, so the phases advance by about one frame each (its peak moves slightly as
    // bins flush to 0). A wrap that did not move the bar position would step back a beat.
    for t in loud + 4..loud + quiet {
        let (a, b) = (&out[t - 1], &out[t]);
        assert!(b.confidence == 0.0 || t < last_allowed, "{t}: {b:?}");
        // The tempo is held; it moves by hundredths of a BPM as histogram bins flush to 0.
        assert!((b.tempo_bpm - locked.tempo_bpm).abs() < 0.5, "{t}: {b:?}");
        let step = b.bar_phase - a.bar_phase;
        let step = step - step.floor();
        let frame = b.tempo_bpm / (60.0 * fr * bpb);
        assert!(
            step > 0.5 * frame && step < 1.5 * frame,
            "{t}: bar phase step {step}, one frame is {frame}"
        );
    }
    let resumed = out[loud + quiet..].iter().filter(|b| b.beat == 1).count();
    assert!(resumed >= 12, "{resumed} beats after the silence");
}
