// SPDX-License-Identifier: AGPL-3.0-only
//! Adaptive level normaliser conformance (`conformance/dsp/music/agc/`): every sampled output
//! row matches the stdlib oracle bit for bit and the digest over every frame matches; plus
//! validation, reset, input cleaning and no allocation after creation.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use oscillux_core::dsp::{
    Agc, AgcConfig, DspConfig, DspError, DspFrame, DspSettings, Levels, ONSET_GROUPS,
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

const VECTORS: [(&str, &str); 2] = [
    (
        "agc-default",
        include_str!("../../../conformance/dsp/music/agc/agc-default.vectors"),
    ),
    (
        "agc-config-32k",
        include_str!("../../../conformance/dsp/music/agc/agc-config-32k.vectors"),
    ),
];

struct Vector {
    name: &'static str,
    settings: DspSettings,
    agc: AgcConfig,
    inputs: Vec<DspFrame>,
    outputs: Vec<(usize, Vec<f64>)>,
    digest: u64,
}

fn parse(name: &'static str, text: &str) -> Vector {
    let mut lines = text.lines();
    assert_eq!(lines.next(), Some("# dsp-agc-vectors v1"), "{name}: header");
    let mut v = Vector {
        name,
        settings: DspSettings::default(),
        agc: AgcConfig::default(),
        inputs: Vec::new(),
        outputs: Vec::new(),
        digest: 0,
    };
    for line in lines.filter(|line| !line.starts_with('#')) {
        let f: Vec<&str> = line.split_whitespace().collect();
        let cfg = &mut v.settings.config;
        match (f[0], f.get(1).copied().unwrap_or("")) {
            ("config", "sample_rate_hz") => cfg.sample_rate_hz = f[2].parse().unwrap(),
            ("config", "hop_samples") => cfg.hop_samples = f[2].parse().unwrap(),
            ("config", "fft_window_samples") => cfg.fft_window_samples = f[2].parse().unwrap(),
            ("config", "spectrum_bands") => cfg.spectrum_bands = f[2].parse().unwrap(),
            ("config", "spectrum_min_hz") => cfg.spectrum_min_hz = f[2].parse().unwrap(),
            ("config", "spectrum_max_hz") => cfg.spectrum_max_hz = f[2].parse().unwrap(),
            ("config", "db_floor") => cfg.db_floor = f[2].parse().unwrap(),
            ("config", "onset_band_groups") => {
                for (group, ends) in cfg.onset_band_groups.iter_mut().zip(f[2].split(',')) {
                    let (a, b) = ends.split_once('-').unwrap();
                    *group = [a.parse().unwrap(), b.parse().unwrap()];
                }
            }
            ("agc_config", "time_constant_s") => v.agc.time_constant_s = f[2].parse().unwrap(),
            ("agc_config", "min_range_db") => v.agc.min_range_db = f[2].parse().unwrap(),
            ("agc_config", "gate_db") => v.agc.gate_db = f[2].parse().unwrap(),
            ("agc_config", "reference_time_constant_s") => {
                v.agc.reference_time_constant_s = f[2].parse().unwrap()
            }
            ("in", _) => {
                let mut frame = DspFrame::ZERO;
                frame.sequence = v.inputs.len() as u64;
                frame.band_count = (f.len() - 1) as u32;
                for (slot, s) in frame.spectrum.iter_mut().zip(&f[1..]) {
                    *slot = f64::from(s.parse::<u32>().unwrap()) / 256.0;
                }
                v.inputs.push(frame);
            }
            ("out", _) => v.outputs.push((
                f[1].parse().unwrap(),
                f[2..].iter().map(|s| s.parse().unwrap()).collect(),
            )),
            ("digest", _) => v.digest = u64::from_str_radix(f[1], 16).unwrap(),
            _ => panic!("{name}: unknown row {line:?}"),
        }
    }
    v
}

fn vectors() -> Vec<Vector> {
    VECTORS
        .iter()
        .map(|&(name, text)| parse(name, text))
        .collect()
}

/// The values the oracle writes per frame: relative groups, absolute groups, relative bands.
fn values(l: &Levels) -> impl Iterator<Item = f64> + '_ {
    l.relative_groups
        .iter()
        .chain(&l.absolute_groups)
        .chain(&l.relative_bands[..l.band_count as usize])
        .copied()
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

fn fnv1a(hash: u64, bytes: &[u8]) -> u64 {
    bytes.iter().fold(hash, |h, &b| {
        (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// The oracle's digest step: FNV-1a over the little-endian band count and values.
fn digest_step(mut h: u64, l: &Levels) -> u64 {
    h = fnv1a(h, &l.band_count.to_le_bytes());
    for x in values(l) {
        h = fnv1a(h, &x.to_le_bytes());
    }
    h
}

#[test]
fn agc_vectors_match_bit_for_bit() {
    for v in vectors() {
        let mut agc = Agc::new(&v.settings, v.agc).expect("agc");
        let got: Vec<Levels> = v.inputs.iter().map(|f| agc.update(f)).collect();
        for (frame, expected) in &v.outputs {
            let have: Vec<u64> = values(&got[*frame]).map(f64::to_bits).collect();
            let want: Vec<u64> = expected.iter().map(|x| x.to_bits()).collect();
            assert_eq!(have, want, "{} frame {frame}", v.name);
        }
        for l in &got {
            assert_eq!(l.band_count, v.settings.config.spectrum_bands);
            assert_eq!(l.reserved, 0);
            assert!(l.relative_bands[l.band_count as usize..]
                .iter()
                .all(|&x| x.to_bits() == 0));
            assert!(values(l).all(|x| (0.0..=1.0).contains(&x) && x.to_bits() >> 63 == 0));
        }
        assert_eq!(
            got.iter().fold(FNV_OFFSET, digest_step),
            v.digest,
            "{}: digest",
            v.name
        );
        println!("{}: {} frames, digest {:016x}", v.name, got.len(), v.digest);
    }
}

#[test]
fn reset_repeats_the_stream_and_update_does_not_allocate() {
    for v in vectors() {
        let mut agc = Agc::new(&v.settings, v.agc).expect("agc");
        COUNT.with(|c| c.set(0));
        ARMED.with(|a| a.set(true));
        let mut digests = [FNV_OFFSET; 2];
        for d in &mut digests {
            for frame in &v.inputs {
                *d = digest_step(*d, &agc.update(frame));
            }
            agc.reset();
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
fn inputs_are_cleaned_and_flags_ignored() {
    let v = vectors().remove(0);
    let mut clean = Agc::new(&v.settings, v.agc).unwrap();
    let mut dirty = clean.clone();
    for frame in &v.inputs {
        let mut bad = *frame;
        bad.flags = 3;
        for x in &mut bad.spectrum[..frame.band_count as usize] {
            if *x == 0.0 {
                *x = [f64::NAN, -0.0, -2.0, f64::INFINITY][frame.sequence as usize % 4];
            } else if *x == 1.0 {
                *x = 7.5;
            }
        }
        assert_eq!(clean.update(frame), dirty.update(&bad));
    }
}

#[test]
fn a_steady_level_reads_one_half() {
    let mut agc = Agc::new(&DspSettings::default(), AgcConfig::default()).unwrap();
    let mut frame = DspFrame::ZERO;
    frame.band_count = 24;
    frame.spectrum[..24].fill(0.4);
    // The window is widened to the 12 dB minimum around the level, so it reads 0.5 up to
    // rounding, from the first frame on and for as long as it holds.
    let half = |x: &f64| (x - 0.5).abs() < 1e-12;
    for _ in 0..1000 {
        let out = agc.update(&frame);
        assert!(out.relative_bands[..24].iter().all(half), "{out:?}");
        assert!(out.relative_groups.iter().all(half), "{out:?}");
        assert!(out.absolute_groups.iter().all(|&x| (x - 0.4).abs() < 1e-12));
    }
    // A step up then reads 1 and relaxes toward the middle of the widened window.
    frame.spectrum[..24].fill(0.6);
    assert_eq!(agc.update(&frame).relative_groups, [1.0; ONSET_GROUPS]);
    let mut last = 1.0;
    for _ in 0..2000 {
        let now = agc.update(&frame).relative_groups[0];
        assert!(now <= last);
        last = now;
    }
    assert!(last < 0.75, "{last}");
}

/// Band levels for `frames` frames of hiss around `mean_db` with `±jitter_db` of uniform
/// jitter per band and frame, from a fixed seed.
fn hiss(frames: usize, mean_db: f64, jitter_db: f64) -> Vec<DspFrame> {
    let mut state: u64 = 0x2026_1020;
    (0..frames)
        .map(|_| {
            let mut frame = DspFrame::ZERO;
            frame.band_count = 24;
            for x in &mut frame.spectrum[..24] {
                state = state
                    .wrapping_mul(6_364_136_223_846_793_005)
                    .wrapping_add(1_442_695_040_888_963_407);
                let u = (state >> 11) as f64 / (1u64 << 53) as f64;
                *x = (mean_db + (2.0 * u - 1.0) * jitter_db + 90.0) / 90.0;
            }
            frame
        })
        .collect()
}

/// Frames whose 24 band levels alternate between `a_db` and `b_db` every 8 frames.
fn alternating(frames: usize, a_db: f64, b_db: f64) -> Vec<DspFrame> {
    (0..frames)
        .map(|i| {
            let mut frame = DspFrame::ZERO;
            frame.band_count = 24;
            let db = if i / 8 % 2 == 0 { a_db } else { b_db };
            frame.spectrum[..24].fill((db + 90.0) / 90.0);
            frame
        })
        .collect()
}

const FRAME_RATE: f64 = 48_000.0 / 512.0;

/// Review finding: after loud material, sustained quiet hiss (bands around -84 dB, +-3 dB; with
/// the default analyser about -53 dBFS white noise) must read near 0, not mid-scale.
#[test]
fn quiet_hiss_after_loud_material_reads_near_zero() {
    let fr = FRAME_RATE;
    let loud = alternating((10.0 * fr) as usize, -22.5, -45.0);
    let settle = (15.0 * fr) as usize;
    let run = |agc: AgcConfig, quiet: &[DspFrame]| {
        let mut agc = Agc::new(&DspSettings::default(), agc).unwrap();
        for frame in &loud {
            agc.update(frame);
        }
        let (mut peak, mut total, mut count) = (0.0f64, 0.0, 0.0);
        for (i, frame) in quiet.iter().enumerate() {
            let out = agc.update(frame);
            if i >= settle {
                for &x in out.relative_groups.iter().chain(&out.relative_bands[..24]) {
                    peak = peak.max(x);
                }
                total += out.relative_groups.iter().sum::<f64>();
                count += ONSET_GROUPS as f64;
            }
        }
        // The gate follows the running maximum, which jumps up at once, so the next loud frame
        // reads full scale.
        let back = agc.update(&loud[0]);
        (peak, total / count, back)
    };
    let quiet = hiss((120.0 * fr) as usize, -84.0, 3.0);
    let (peak, mean, back) = run(AgcConfig::default(), &quiet);
    println!("gated: peak {peak:.4}, mean group {mean:.4}");
    assert!(peak < 0.02, "hiss reads {peak} after 15 s");
    assert_eq!(back.relative_groups, [1.0; ONSET_GROUPS]);
    // With the gate opened past the whole range (gate_db = -db_floor + min_range_db), the same
    // hiss is stretched toward mid-scale, as the review found.
    let open = AgcConfig {
        gate_db: 102.0,
        ..AgcConfig::default()
    };
    let (peak, mean, _) = run(open, &quiet);
    println!("gate open: peak {peak:.4}, mean group {mean:.4}");
    assert!(
        mean > 0.2 && peak > 0.4,
        "hiss reads mean {mean}, peak {peak}"
    );
}

/// Review finding: the gate is relative to each level's own reference, so a quiet master reads
/// like a loud one. The same programme (loud material, a passage 20 dB quieter, then 60 s of
/// hiss 50 dB below the loud material) at 0 and -20 dB gives the same relative levels up to
/// rounding, while every level stays at least `min_range_db` above the floor; the quieter
/// passage reaches full scale and the hiss is gated at both gains.
#[test]
fn a_quiet_master_reads_like_a_loud_one() {
    let fr = FRAME_RATE;
    let programme = |gain_db: f64| {
        let mut frames = alternating((10.0 * fr) as usize, -4.5 + gain_db, -27.0 + gain_db);
        frames.extend(alternating(
            (20.0 * fr) as usize,
            -24.5 + gain_db,
            -47.0 + gain_db,
        ));
        frames.extend(hiss((60.0 * fr) as usize, -55.0 + gain_db, 3.0));
        frames
    };
    let (loud, quiet) = (programme(0.0), programme(-20.0));
    let mut a = Agc::new(&DspSettings::default(), AgcConfig::default()).unwrap();
    let mut b = a.clone();
    let passage = (10.0 * fr) as usize..(30.0 * fr) as usize;
    let hiss_from = (45.0 * fr) as usize;
    let (mut passage_peak, mut hiss_peak, mut worst) = (0.0f64, 0.0f64, 0.0f64);
    for (i, (x, y)) in loud.iter().zip(&quiet).enumerate() {
        let (x, y) = (a.update(x), b.update(y));
        for (&p, &q) in x.relative_groups.iter().zip(&y.relative_groups) {
            worst = worst.max((p - q).abs());
        }
        for (&p, &q) in x.relative_bands.iter().zip(&y.relative_bands) {
            worst = worst.max((p - q).abs());
        }
        for (&p, &q) in x.absolute_groups.iter().zip(&y.absolute_groups) {
            assert!((p - q - 20.0 / 90.0).abs() < 1e-12, "frame {i}: {p} {q}");
        }
        if passage.contains(&i) {
            passage_peak = passage_peak.max(x.relative_groups[0]);
        }
        if i >= hiss_from {
            for &v in x.relative_groups.iter().chain(&x.relative_bands[..24]) {
                hiss_peak = hiss_peak.max(v);
            }
        }
    }
    println!("0 vs -20 dB: largest difference {worst:e}; passage peak {passage_peak}, hiss peak {hiss_peak}");
    assert!(worst < 1e-9, "relative levels differ by {worst}");
    assert_eq!(passage_peak, 1.0);
    assert!(hiss_peak < 0.02, "hiss reads {hiss_peak}");
}

#[test]
fn invalid_configurations_are_refused() {
    let settings = DspSettings::default();
    let with = |time_constant_s, min_range_db, gate_db, reference_time_constant_s| {
        Agc::new(
            &settings,
            AgcConfig {
                time_constant_s,
                min_range_db,
                gate_db,
                reference_time_constant_s,
            },
        )
        .err()
    };
    let invalid = |field| Some(DspError::InvalidConfig(field));
    assert_eq!(with(0.0, 12.0, 36.0, 600.0), invalid("time_constant_s"));
    assert_eq!(
        with(f64::INFINITY, 12.0, 36.0, 600.0),
        invalid("time_constant_s")
    );
    assert_eq!(with(4.0, 0.0, 36.0, 600.0), invalid("min_range_db"));
    assert_eq!(with(4.0, f64::NAN, 36.0, 600.0), invalid("min_range_db"));
    assert_eq!(with(4.0, 90.5, 36.0, 600.0), invalid("min_range_db"));
    assert_eq!(with(4.0, 90.0, 90.0, 600.0), None);
    assert_eq!(with(4.0, 12.0, 11.5, 600.0), invalid("gate_db"));
    assert_eq!(with(4.0, 12.0, f64::NAN, 600.0), invalid("gate_db"));
    assert_eq!(with(4.0, 12.0, f64::INFINITY, 600.0), invalid("gate_db"));
    assert_eq!(with(4.0, 12.0, 12.0, 600.0), None);
    assert_eq!(with(4.0, 12.0, 1000.0, 600.0), None);
    assert_eq!(
        with(4.0, 12.0, 36.0, 0.0),
        invalid("reference_time_constant_s")
    );
    assert_eq!(
        with(4.0, 12.0, 36.0, -1.0),
        invalid("reference_time_constant_s")
    );
    assert_eq!(
        with(4.0, 12.0, 36.0, f64::NAN),
        invalid("reference_time_constant_s")
    );
    assert_eq!(
        with(4.0, 12.0, 36.0, f64::INFINITY),
        invalid("reference_time_constant_s")
    );
    assert_eq!(with(4.0, 12.0, 36.0, 0.01), None);
    let bad = DspSettings {
        config: DspConfig {
            hop_samples: 0,
            ..DspConfig::default()
        },
        ..DspSettings::default()
    };
    assert!(Agc::new(&bad, AgcConfig::default()).is_err());
}
