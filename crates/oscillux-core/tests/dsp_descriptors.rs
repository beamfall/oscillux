// SPDX-License-Identifier: AGPL-3.0-only
//! Opt-in DSP descriptors (OSC-DSP-DESCRIPTORS) and the FLUX and CENTROID mapping slots
//! (OSC-MAPPER-FEATURES) against conformance/dsp/descriptors/, which the independent
//! standard-library oracle tools/dsp-descriptors-vectors.py writes.

// These vectors hold no booleans, so the reader's boolean accessor goes unused.
#[allow(dead_code)]
mod json;

use json::Value;
use oscillux_core::dsp::{
    decode_wav_mono, k_weighting, Analyzer, BeatConfig, BeatTracker, DspConfig, DspFrame,
    DspSettings, FrameExt, DSP_BEHAVIOR_V1, DSP_BEHAVIOR_V2, DSP_BEHAVIOR_V3, DSP_BEHAVIOR_V4,
    LUFS_FLOOR,
};
use oscillux_core::mapping::{
    Mapper, MappingConfig, CENTROID, CENTROID_DECADES, CENTROID_MIN_HZ, FLUX, ONSET,
};

const K_WEIGHTING: &str = include_str!("../../../conformance/dsp/descriptors/k-weighting.json");
const TECH3341: &str = include_str!("../../../conformance/dsp/descriptors/tech3341.json");
const CENTROID_VECTORS: &str = include_str!("../../../conformance/dsp/descriptors/centroid.json");

/// The fixtures centroid.json reads, embedded so the test also runs on wasm32-wasip1.
const WAVS: [(&str, &[u8]); 9] = [
    (
        "conformance/dsp/chunked-gap-stall.wav",
        include_bytes!("../../../conformance/dsp/chunked-gap-stall.wav"),
    ),
    (
        "conformance/dsp/kicks-120bpm.wav",
        include_bytes!("../../../conformance/dsp/kicks-120bpm.wav"),
    ),
    (
        "conformance/dsp/noise-white.wav",
        include_bytes!("../../../conformance/dsp/noise-white.wav"),
    ),
    (
        "conformance/dsp/silence-44k1-chunked.wav",
        include_bytes!("../../../conformance/dsp/silence-44k1-chunked.wav"),
    ),
    (
        "conformance/dsp/silence.wav",
        include_bytes!("../../../conformance/dsp/silence.wav"),
    ),
    (
        "conformance/dsp/sine-440.wav",
        include_bytes!("../../../conformance/dsp/sine-440.wav"),
    ),
    (
        "conformance/dsp/sines-low-mid-high.wav",
        include_bytes!("../../../conformance/dsp/sines-low-mid-high.wav"),
    ),
    (
        "conformance/dsp/sweep-40-16k.wav",
        include_bytes!("../../../conformance/dsp/sweep-40-16k.wav"),
    ),
    (
        "conformance/dsp/v2/sine-60-full.wav",
        include_bytes!("../../../conformance/dsp/v2/sine-60-full.wav"),
    ),
];

/// One unit of the analyzer's quantised power, 2^-50.
const QUANTUM: f64 = 1.0 / (1u64 << 50) as f64;

fn parse(text: &str) -> Value {
    json::parse(text).expect("vector JSON parses")
}

fn settings(rate: u32, behavior_version: u32) -> DspSettings {
    DspSettings {
        config: DspConfig {
            sample_rate_hz: rate,
            ..DspConfig::default()
        },
        behavior_version,
    }
}

/// Pushes all of `interleaved` as one segment and returns every frame and its extension.
fn run(
    settings: DspSettings,
    interleaved: &[f64],
    channels: usize,
) -> (Vec<DspFrame>, Vec<FrameExt>) {
    let mut analyzer = Analyzer::new(settings).unwrap();
    let capacity = interleaved.len() / channels / settings.config.hop_samples as usize + 1;
    let mut out = vec![DspFrame::ZERO; capacity];
    let mut ext = vec![FrameExt::ZERO; capacity];
    let pushed = analyzer
        .push_ext(interleaved, channels, &mut out, &mut ext)
        .unwrap();
    assert_eq!(pushed.consumed * channels, interleaved.len());
    out.truncate(pushed.produced);
    ext.truncate(pushed.produced);
    (out, ext)
}

/// Interleaved samples of one tech3341.json case, as the oracle synthesises them.
fn synthesise(case: &Value) -> (Vec<f64>, usize) {
    let rate = case.get("sample_rate_hz").num();
    let frequency = case.get("frequency_hz").num();
    let samples = case.get("samples").num() as usize;
    let mut levels: Vec<(usize, f64)> = case
        .get("levels")
        .arr()
        .iter()
        .map(|pair| (pair.arr()[0].num() as usize, pair.arr()[1].num()))
        .collect();
    if levels.is_empty() {
        levels.push((samples, 0.0));
    }
    let channels = case.get("channels").arr();
    let mut amplitudes = Vec::new();
    for channel in channels {
        let gain = channel.get("gain_db");
        let sign = channel.get("sign").num();
        let mut per_sample = Vec::new();
        for &(length, offset) in &levels {
            let amplitude = match gain {
                Value::Null => 0.0,
                gain => sign * 10f64.powf((gain.num() + offset) / 20.0),
            };
            per_sample.extend(std::iter::repeat_n(amplitude, length));
        }
        amplitudes.push((per_sample, channel.get("dc").num()));
    }
    let mut interleaved = Vec::with_capacity(samples * channels.len());
    for n in 0..samples {
        let phase = (2.0 * std::f64::consts::PI * frequency * n as f64 / rate).sin();
        for (per_sample, dc) in &amplitudes {
            interleaved.push(per_sample[n % per_sample.len()] * phase + dc);
        }
    }
    (interleaved, channels.len())
}

/// `object[key]`, when present.
fn field<'a>(object: &'a Value, key: &str) -> Option<&'a Value> {
    let Value::Obj(fields) = object else {
        panic!("not an object looking up {key}")
    };
    fields.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// Mean K-weighted power behind a LUFS value at or above the floor.
fn power(lufs: f64) -> f64 {
    10f64.powf((lufs + 0.691) / 10.0)
}

#[test]
fn k_weighting_matches_the_oracle_at_every_rate() {
    let doc = parse(K_WEIGHTING);
    let tolerance = doc.get("tolerance").num();
    let mut checked = 0;
    for rate in doc.get("rates").arr() {
        let [shelf, high_pass] = k_weighting(rate.get("sample_rate_hz").num() as u32);
        for (stage, name) in [(shelf, "shelf"), (high_pass, "high_pass")] {
            let want = rate.get(name);
            let got = stage.b.iter().chain(&stage.a);
            let expected = want.get("b").arr().iter().chain(want.get("a").arr());
            for (got, want) in got.zip(expected) {
                assert!(
                    (got - want.num()).abs() <= tolerance,
                    "{name}: {got} vs {}",
                    want.num()
                );
                checked += 1;
            }
        }
    }
    assert_eq!(checked, 10 * 10);
}

#[test]
fn tech3341_cases_match_the_oracle_and_their_nominal_values() {
    let doc = parse(TECH3341);
    let relative = doc.get("power_relative_tolerance").num();
    let ratio = doc.get("ratio_tolerance").num();
    let nominal_lu = doc.get("nominal_lu").num();
    let nominal_ratio = doc.get("nominal_ratio").num();
    let (mut frames, mut worst_db) = (0, 0.0f64);
    for case in doc.get("cases").arr() {
        let name = case.get("name").str();
        let rate = case.get("sample_rate_hz").num() as u32;
        let (interleaved, channels) = synthesise(case);
        let (_, ext) = run(settings(rate, DSP_BEHAVIOR_V2), &interleaved, channels);
        let rows = case.get("frames").arr();
        assert_eq!(ext.len(), rows.len(), "{name} at {rate} Hz: frame count");
        let nominal = case.get("nominal");
        let from = nominal.get("from_frame").num() as usize;
        for (index, (ext, row)) in ext.iter().zip(rows).enumerate() {
            let d = ext.descriptors;
            let row = row.arr();
            let at = format!("{name} at {rate} Hz frame {index}");
            for (got, want) in [
                (d.momentary_lufs, row[0].num()),
                (d.short_term_lufs, row[1].num()),
            ] {
                // Each sample's weighted power is rounded down to a multiple of 2^-50 per channel.
                let bound = relative * power(want) + channels as f64 * QUANTUM;
                assert!(
                    (power(got) - power(want)).abs() <= bound,
                    "{at}: {got} LUFS vs {want}"
                );
                if want > -70.0 {
                    worst_db = worst_db.max((got - want).abs());
                }
            }
            for (got, want) in [(d.width, &row[2]), (d.balance, &row[3])] {
                if let Value::Null = want {
                    continue;
                }
                assert!(
                    (got - want.num()).abs() <= ratio,
                    "{at}: {got} vs {}",
                    want.num()
                );
            }
            if index < from {
                continue;
            }
            let checks = [
                ("momentary_lufs", d.momentary_lufs, nominal_lu),
                ("short_term_lufs", d.short_term_lufs, nominal_lu),
                ("width", d.width, nominal_ratio),
                ("balance", d.balance, nominal_ratio),
            ];
            for (key, got, tolerance) in checks {
                if let Value::Num(want) = nominal.get(key) {
                    assert!(
                        (got - want).abs() <= tolerance,
                        "{at}: {key} {got}, nominal {want}"
                    );
                }
            }
        }
        frames += rows.len();
    }
    assert_eq!(frames, 2476);
    assert!(
        worst_db < 1e-6,
        "loudness differs from the oracle by {worst_db} dB"
    );
    println!(
        "tech3341: {frames} frames, loudness within {worst_db:.3e} dB of the oracle above -70 LUFS"
    );
}

#[test]
fn descriptors_do_not_depend_on_the_behaviour_version() {
    let doc = parse(TECH3341);
    let case = &doc.get("cases").arr()[7];
    assert_eq!(case.get("name").str(), "anti-phase");
    let (interleaved, channels) = synthesise(case);
    let (_, v1) = run(settings(48_000, DSP_BEHAVIOR_V1), &interleaved, channels);
    let (_, v2) = run(settings(48_000, DSP_BEHAVIOR_V2), &interleaved, channels);
    assert_eq!(v1, v2);
    let last = v2.last().unwrap().descriptors;
    assert_eq!((last.width, last.balance), (1.0, 0.0));
}

#[test]
fn centroid_and_flux_match_the_oracle_and_the_librosa_definition() {
    let doc = parse(CENTROID_VECTORS);
    let librosa_tolerance = doc.get("librosa_relative_tolerance").num();
    let definition = doc.get("definition_relative_tolerance").num();
    let flux_tolerance = doc.get("flux_tolerance").num();
    let (mut frames, mut worst_librosa) = (0, 0.0f64);
    for input in doc.get("inputs").arr() {
        let name = input.get("name").str();
        let rate = input.get("sample_rate_hz").num() as u32;
        let samples = match field(input, "sweep") {
            Some(sweep) => {
                let count = sweep.get("samples").num() as usize;
                let (amplitude, f0, f1) = (
                    sweep.get("amplitude").num(),
                    sweep.get("f0").num(),
                    sweep.get("f1").num(),
                );
                let seconds = count as f64 / rate as f64;
                let k = (f1 / f0).ln();
                (0..count)
                    .map(|n| {
                        let t = n as f64 / rate as f64;
                        amplitude
                            * (2.0 * std::f64::consts::PI * f0 * seconds / k
                                * ((t / seconds * k).exp() - 1.0))
                                .sin()
                    })
                    .collect()
            }
            None => {
                let path = input.get("wav").str();
                let (_, wav) = WAVS.iter().find(|(p, _)| *p == path).expect("embedded WAV");
                decode_wav_mono(wav, rate).unwrap()
            }
        };
        for version in [DSP_BEHAVIOR_V1, DSP_BEHAVIOR_V2] {
            let (_, ext) = run(settings(rate, version), &samples, 1);
            let rows = input.get("frames").arr();
            assert_eq!(ext.len(), rows.len(), "{name}: frame count");
            for (index, (ext, row)) in ext.iter().zip(rows).enumerate() {
                let d = ext.descriptors;
                let row = row.arr();
                let (librosa, documented, flux) = (row[0].num(), row[1].num(), row[2].num());
                let at = format!("{name} v{version} frame {index}");
                if documented == 0.0 {
                    assert_eq!(d.centroid_hz, 0.0, "{at}");
                } else {
                    let error = (d.centroid_hz - documented).abs() / documented;
                    assert!(
                        error <= definition,
                        "{at}: centroid {} vs {documented}",
                        d.centroid_hz
                    );
                }
                if librosa == 0.0 {
                    assert_eq!(d.centroid_hz, 0.0, "{at}");
                } else {
                    let error = (d.centroid_hz - librosa).abs() / librosa;
                    assert!(
                        error <= librosa_tolerance,
                        "{at}: centroid {} vs librosa {librosa}",
                        d.centroid_hz
                    );
                    worst_librosa = worst_librosa.max(error);
                }
                assert!(
                    (d.spectral_flux - flux).abs() <= flux_tolerance,
                    "{at}: flux {} vs {flux}",
                    d.spectral_flux
                );
                // Loudness reads the interleaved input; a mono stream has no width or balance.
                assert_eq!((d.width, d.balance), (0.0, 0.0), "{at}");
            }
            frames += rows.len();
        }
    }
    assert_eq!(frames, 2 * 704);
    println!(
        "centroid: {frames} frames, within {:.3}% of the librosa definition",
        worst_librosa * 100.0
    );
}

#[test]
fn versions_3_and_4_change_only_the_beat_tracker() {
    let samples = decode_wav_mono(WAVS[1].1, 48_000).unwrap();
    let (v2, v2_ext) = run(settings(48_000, DSP_BEHAVIOR_V2), &samples, 1);
    for version in [DSP_BEHAVIOR_V3, DSP_BEHAVIOR_V4] {
        let v3_settings = settings(48_000, version);
        let (v3, v3_ext) = run(v3_settings, &samples, 1);
        assert_eq!(format!("{v2:?}"), format!("{v3:?}"));
        let mut tracker = BeatTracker::new(&v3_settings, BeatConfig::for_version(version)).unwrap();
        for ((frame, a), b) in v3.iter().zip(&v2_ext).zip(&v3_ext) {
            assert_eq!(
                format!("{:?}", (a.descriptors, a.levels)),
                format!("{:?}", (b.descriptors, b.levels))
            );
            assert_eq!(
                format!("{:?}", tracker.update(frame)),
                format!("{:?}", b.beat)
            );
        }
    }
}

#[test]
fn push_ext_frames_equal_push_frames() {
    let samples = decode_wav_mono(WAVS[1].1, 48_000).unwrap();
    for version in [
        DSP_BEHAVIOR_V1,
        DSP_BEHAVIOR_V2,
        DSP_BEHAVIOR_V3,
        DSP_BEHAVIOR_V4,
    ] {
        let settings = settings(48_000, version);
        let (with_ext, _) = run(settings, &samples, 1);
        let mut analyzer = Analyzer::new(settings).unwrap();
        let mut out = vec![DspFrame::ZERO; with_ext.len() + 1];
        let pushed = analyzer.push(&samples, 1, &mut out).unwrap();
        assert_eq!(pushed.produced, with_ext.len());
        for (a, b) in out.iter().zip(&with_ext) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"), "v{version}");
        }
    }
}

#[test]
fn flux_and_centroid_slots_read_the_descriptors_not_the_onset() {
    let samples = decode_wav_mono(WAVS[1].1, 48_000).unwrap();
    let settings = DspSettings::default();
    let (frames, ext) = run(settings, &samples, 1);
    let mut mapper = Mapper::new(MappingConfig::for_dsp(&settings.config)).unwrap();
    let mut legacy = Mapper::new(MappingConfig::for_dsp(&settings.config)).unwrap();
    let mut differing = 0;
    for (frame, ext) in frames.iter().zip(&ext) {
        let d = &ext.descriptors;
        let mapped = mapper.map_with(frame, Some(d), false).unwrap();
        // Without descriptors slot 7 keeps the onset proxy; slots 0-6 do not depend on them.
        let plain = legacy.map(frame, false).unwrap();
        assert_eq!(plain.values[FLUX], plain.values[ONSET]);
        assert_eq!(plain.values[..FLUX], mapped.values[..FLUX]);
        assert_eq!(mapped.values[FLUX], d.spectral_flux.clamp(0.0, 1.0));
        let energy: f64 = frame.spectrum[..frame.band_count as usize].iter().sum();
        let centroid = if energy <= 1e-6 || d.centroid_hz <= CENTROID_MIN_HZ {
            0.0
        } else {
            ((d.centroid_hz / CENTROID_MIN_HZ).log10() / CENTROID_DECADES).clamp(0.0, 1.0)
        };
        assert!((mapped.values[CENTROID] - centroid).abs() <= 1e-12);
        if (mapped.values[FLUX] - mapped.values[ONSET]).abs() > 1e-6 {
            differing += 1;
        }
    }
    // With descriptors slot 7 is a distinct signal on most frames.
    assert!(
        differing * 2 > frames.len(),
        "{differing} of {} frames differ",
        frames.len()
    );
}

#[test]
fn loudness_is_not_measured_below_8_khz() {
    let mut config = DspConfig {
        sample_rate_hz: 4000,
        fft_window_samples: 256,
        hop_samples: 64,
        spectrum_min_hz: 40.0,
        spectrum_max_hz: 1800.0,
        ..DspConfig::default()
    };
    config.rms_window_ms = 100.0;
    let tone: Vec<f64> = (0..8000)
        .flat_map(|n| {
            let x = 0.5 * (2.0 * std::f64::consts::PI * 500.0 * n as f64 / 4000.0).sin();
            [x, 0.25 * x]
        })
        .collect();
    let (_, ext) = run(
        DspSettings {
            config,
            behavior_version: DSP_BEHAVIOR_V2,
        },
        &tone,
        2,
    );
    assert!(!ext.is_empty());
    for ext in &ext {
        let d = ext.descriptors;
        assert_eq!(
            (d.momentary_lufs, d.short_term_lufs),
            (LUFS_FLOOR, LUFS_FLOOR)
        );
        assert_eq!((d.width, d.balance), (0.0, 0.0));
        assert!(
            d.centroid_hz > 400.0 && d.centroid_hz < 600.0,
            "{}",
            d.centroid_hz
        );
    }
}
