// SPDX-License-Identifier: AGPL-3.0-only
//! Golden WAV → feature vectors under `conformance/dsp/` (behaviour version 1, Go reference) and
//! `conformance/dsp/v2/` (behaviour version 2, `tools/dsp-v2-vectors.py`), plus the edge-case
//! fixtures of `conformance/dsp/music/` (44.1 kHz, non-default configuration, stereo anti-phase,
//! replaced non-finite samples) in both versions. Fixtures are embedded at compile time, so the
//! test needs no filesystem access and runs unchanged under a WASI runtime.

use oscillux_core::dsp::{
    analyze_pcm_chunks, analyze_wav, decode_wav_mono, Analyzer, DspConfig, DspFrame, DspSettings,
    PcmChunk, DSP_BEHAVIOR_V1, DSP_BEHAVIOR_V2,
};

/// Published tolerances of the reference frame contract.
const TOL_TIME_MS: f64 = 0.02;
const TOL_SCALAR: f64 = 1e-6;
const TOL_SPECTRUM: f64 = 1e-6;

struct Fixture {
    name: &'static str,
    wav: &'static [u8],
    frames: &'static str,
    /// Expected `digest` of the full-precision output, identical on every target.
    digest: u64,
    /// `DspConfig::sample_rate_hz`; every other field is the default unless `spec` is set.
    sample_rate_hz: u32,
    behavior_version: u32,
    /// An edge-case fixture's `.spec` rows (`conformance/dsp/music/README.md`), or `""`. Its
    /// `channels`, `config`, `chunk` and `replace` rows are repeated in `frames`.
    spec: &'static str,
}

macro_rules! fixture {
    ($name:literal, $digest:literal) => {
        fixture!($name, $digest, 48_000)
    };
    ($name:literal, $digest:literal, $rate:literal) => {
        Fixture {
            name: $name,
            digest: $digest,
            sample_rate_hz: $rate,
            behavior_version: DSP_BEHAVIOR_V1,
            wav: include_bytes!(concat!("../../../conformance/dsp/", $name, ".wav")),
            frames: include_str!(concat!("../../../conformance/dsp/", $name, ".frames")),
            spec: "",
        }
    };
}

/// A version 2 fixture: expected frames under `conformance/dsp/v2/`, input WAV under
/// `conformance/dsp/$dir` (`""` reuses the version 1 input, `"v2/"` is a version 2 signal).
macro_rules! fixture_v2 {
    ($dir:literal, $name:literal, $digest:literal) => {
        fixture_v2!($dir, $name, $digest, 48_000)
    };
    ($dir:literal, $name:literal, $digest:literal, $rate:literal) => {
        Fixture {
            name: $name,
            digest: $digest,
            sample_rate_hz: $rate,
            behavior_version: DSP_BEHAVIOR_V2,
            wav: include_bytes!(concat!("../../../conformance/dsp/", $dir, $name, ".wav")),
            frames: include_str!(concat!("../../../conformance/dsp/v2/", $name, ".frames")),
            spec: "",
        }
    };
}

/// An edge-case fixture under `conformance/dsp/music/`: version 1 frames (Go reference) beside
/// the WAV, version 2 frames (`tools/dsp-v2-vectors.py`) under `v2/`.
macro_rules! edge_fixture {
    (1, $name:literal, $digest:literal) => {
        edge_fixture!(DSP_BEHAVIOR_V1, "", $name, $digest)
    };
    (2, $name:literal, $digest:literal) => {
        edge_fixture!(DSP_BEHAVIOR_V2, "v2/", $name, $digest)
    };
    ($version:expr, $dir:literal, $name:literal, $digest:literal) => {
        Fixture {
            name: $name,
            digest: $digest,
            sample_rate_hz: 48_000,
            behavior_version: $version,
            wav: include_bytes!(concat!("../../../conformance/dsp/music/", $name, ".wav")),
            frames: include_str!(concat!(
                "../../../conformance/dsp/music/",
                $dir,
                $name,
                ".frames"
            )),
            spec: include_str!(concat!("../../../conformance/dsp/music/", $name, ".spec")),
        }
    };
}

const FIXTURES: [Fixture; 8] = [
    fixture!("sine-440", 0x74c8_68cd_5273_acf1),
    fixture!("sines-low-mid-high", 0xdcf7_05f6_eea5_9063),
    fixture!("noise-white", 0x5a73_e7b3_4177_0481),
    fixture!("kicks-120bpm", 0xa715_46da_9bc3_4982),
    fixture!("silence", 0x07b6_62d4_d723_c2f2),
    fixture!("sweep-40-16k", 0xc748_664d_459d_22e0),
    fixture!("chunked-gap-stall", 0xd7f4_b8cc_937e_e90d),
    // Analytic expectations, not Go output; see conformance/dsp/README.md.
    fixture!("silence-44k1-chunked", 0x1d08_652f_f1a4_e6d9, 44_100),
];

/// Behaviour version 2. Expected frames come from the independent model in
/// `tools/dsp-v2-vectors.py`; the digests are of Rust output (docs/portable-math.md).
const V2_FIXTURES: [Fixture; 10] = [
    fixture_v2!("", "sine-440", 0x0def_95f9_52eb_e422),
    fixture_v2!("", "sines-low-mid-high", 0x23c2_1dbd_c56e_ceb2),
    fixture_v2!("", "noise-white", 0x2ecf_414e_b8d8_8a99),
    fixture_v2!("", "kicks-120bpm", 0x74b3_def0_fc89_c3cc),
    fixture_v2!("", "silence", 0x07b6_62d4_d723_c2f2),
    fixture_v2!("", "sweep-40-16k", 0xce05_81de_1b4b_5212),
    fixture_v2!("", "chunked-gap-stall", 0x3703_c2d3_dd1f_ca96),
    fixture_v2!("", "silence-44k1-chunked", 0x1d08_652f_f1a4_e6d9, 44_100),
    fixture_v2!("v2/", "kicks-120bpm-long", 0xc048_62bf_9dcd_f474),
    fixture_v2!("v2/", "sine-60-full", 0xe98a_49f1_2ba5_3c27),
];

/// OSC-DSP-MUSIC-VECTORS edge cases. The digests are of Rust output.
const EDGE_FIXTURES: [Fixture; 8] = [
    edge_fixture!(1, "kicks-44k1", 0x9b52_551a_db63_4604),
    edge_fixture!(1, "kicks-config-32k", 0x6ee6_ebe6_d05c_74a2),
    edge_fixture!(1, "stereo-antiphase", 0x5215_1ede_e53f_6ded),
    edge_fixture!(1, "nan-replaced", 0x1f79_25ac_b2c2_9d1a),
    edge_fixture!(2, "kicks-44k1", 0xab34_dceb_82b2_0f47),
    edge_fixture!(2, "kicks-config-32k", 0xce78_6fb9_1be6_a92b),
    edge_fixture!(2, "stereo-antiphase", 0x3229_8356_f619_4fa0),
    edge_fixture!(2, "nan-replaced", 0x5152_561a_7f59_9519),
];

/// One golden frame: seq, flags, then the numeric features in file order.
struct Golden {
    sequence: u64,
    flags: u32,
    values: Vec<f64>,
}

struct ChunkSpec {
    media_start_ms: f64,
    begin: usize,
    end: usize,
    stall: bool,
}

/// Features compared, with their tolerance and their column range in a golden row (`usize::MAX`:
/// to the end of the row, which has one spectrum column per band).
const FEATURES: [(&str, f64, usize, usize); 8] = [
    ("media_time_ms", TOL_TIME_MS, 0, 1),
    ("rms", TOL_SCALAR, 1, 2),
    ("loudness_db", TOL_SCALAR, 2, 3),
    ("onset.broadband", TOL_SCALAR, 3, 4),
    ("onset.low", TOL_SCALAR, 4, 5),
    ("onset.mid", TOL_SCALAR, 5, 6),
    ("onset.high", TOL_SCALAR, 6, 7),
    ("spectrum", TOL_SPECTRUM, 7, usize::MAX),
];

fn parse_golden(line: &str) -> Golden {
    let mut fields = line.split_whitespace().skip(1);
    let mut next = || fields.next().expect("short frame line");
    let sequence = next().parse().unwrap();
    let flags = next().parse().unwrap();
    let values = fields.map(|v| v.parse().unwrap()).collect();
    Golden {
        sequence,
        flags,
        values,
    }
}

fn parse_chunk(line: &str) -> ChunkSpec {
    let f: Vec<&str> = line.split_whitespace().skip(1).collect();
    ChunkSpec {
        media_start_ms: f[0].parse().unwrap(),
        begin: f[1].parse().unwrap(),
        end: f[2].parse().unwrap(),
        stall: f[3] == "1",
    }
}

fn lines_with<'a>(text: &'a str, tag: &'a str) -> impl Iterator<Item = &'a str> + 'a {
    text.lines()
        .filter(move |l| l.split_whitespace().next() == Some(tag))
}

fn row(frame: &DspFrame) -> Vec<f64> {
    let head = [
        frame.media_time_ms,
        frame.rms,
        frame.loudness_db,
        frame.onset.broadband,
        frame.onset.low,
        frame.onset.mid,
        frame.onset.high,
    ];
    head.iter().chain(frame.bands()).copied().collect()
}

fn settings(fixture: &Fixture) -> DspSettings {
    let mut config = DspConfig {
        sample_rate_hz: fixture.sample_rate_hz,
        ..DspConfig::default()
    };
    for line in lines_with(fixture.frames, "config") {
        let f: Vec<&str> = line.split_whitespace().skip(1).collect();
        set_config(&mut config, f[0], f[1]);
    }
    DspSettings {
        config,
        behavior_version: fixture.behavior_version,
    }
}

fn set_config(c: &mut DspConfig, key: &str, value: &str) {
    let int = || value.parse::<u32>().unwrap();
    let float = || value.parse::<f64>().unwrap();
    match key {
        "sample_rate_hz" => c.sample_rate_hz = int(),
        "fft_window_samples" => c.fft_window_samples = int(),
        "hop_samples" => c.hop_samples = int(),
        "spectrum_bands" => c.spectrum_bands = int(),
        "spectrum_min_hz" => c.spectrum_min_hz = float(),
        "spectrum_max_hz" => c.spectrum_max_hz = float(),
        "db_floor" => c.db_floor = float(),
        "ballistics_attack_ms" => c.ballistics_attack_ms = float(),
        "ballistics_release_ms" => c.ballistics_release_ms = float(),
        "rms_window_ms" => c.rms_window_ms = float(),
        "loudness_reference_lufs" => c.loudness_reference_lufs = float(),
        "gap_tolerance_hops" => c.gap_tolerance_hops = int(),
        "onset_band_groups" => {
            for (group, range) in c.onset_band_groups.iter_mut().zip(value.split(',')) {
                let (lo, hi) = range.split_once('-').unwrap();
                *group = [lo.parse().unwrap(), hi.parse().unwrap()];
            }
        }
        _ => panic!("unknown config key {key}"),
    }
}

/// Interleaved 16-bit PCM of a WAV as sample / 32768, and its channel count.
fn decode_wav_interleaved(wav: &[u8]) -> (Vec<f64>, usize) {
    let u16_at = |at: usize| u16::from_le_bytes([wav[at], wav[at + 1]]);
    let u32_at = |at: usize| u32::from_le_bytes(wav[at..at + 4].try_into().unwrap());
    let (mut at, mut channels, mut samples) = (12, 0, Vec::new());
    while at + 8 <= wav.len() {
        let size = u32_at(at + 4) as usize;
        let body = &wav[at + 8..at + 8 + size];
        match &wav[at..at + 4] {
            b"fmt " => {
                assert_eq!((u16_at(at + 8), u16_at(at + 22)), (1, 16), "16-bit PCM");
                channels = usize::from(u16_at(at + 10));
            }
            b"data" => {
                let pairs = body.chunks_exact(2);
                let pcm = pairs.map(|b| f64::from(i16::from_le_bytes([b[0], b[1]])) / 32768.0);
                samples = pcm.collect();
            }
            _ => {}
        }
        at += 8 + size + size % 2;
    }
    (samples, channels)
}

/// The rows that define an edge-case fixture's input and configuration.
fn definition_rows(text: &str) -> Vec<&str> {
    let tags = ["channels", "config", "chunk", "replace"];
    let defines = |l: &&str| tags.contains(&l.split_whitespace().next().unwrap_or(""));
    text.lines().filter(defines).collect()
}

/// An edge-case fixture through `Analyzer::push`: interleaved channels, the replace rows'
/// values (NaN, ±infinity, beyond `f32`) injected in channel 0 where the WAV holds 0.
fn analyze_edge(fixture: &Fixture, settings: DspSettings) -> Vec<DspFrame> {
    let rows = definition_rows(fixture.frames);
    assert_eq!(
        rows,
        definition_rows(fixture.spec),
        "{}: rows",
        fixture.name
    );
    let (mut pcm, channels) = decode_wav_interleaved(fixture.wav);
    let declared = lines_with(fixture.frames, "channels").next().unwrap();
    assert_eq!(declared, format!("channels {channels}"), "{}", fixture.name);
    for line in lines_with(fixture.frames, "replace") {
        let f: Vec<&str> = line.split_whitespace().skip(1).collect();
        let index: usize = f[0].parse().unwrap();
        assert_eq!(
            pcm[index * channels],
            0.0,
            "{}: replaced sample",
            fixture.name
        );
        pcm[index * channels] = f[1].parse().unwrap();
    }
    let frame_count = pcm.len() / channels;
    let mut specs: Vec<ChunkSpec> = lines_with(fixture.frames, "chunk")
        .map(parse_chunk)
        .collect();
    if specs.is_empty() {
        specs.push(ChunkSpec {
            media_start_ms: 0.0,
            begin: 0,
            end: frame_count,
            stall: false,
        });
    }
    let mut analyzer = Analyzer::new(settings).unwrap();
    let hop = settings.config.hop_samples as usize;
    let mut frames = vec![DspFrame::ZERO; frame_count / hop + specs.len()];
    let mut produced = 0;
    for spec in &specs {
        analyzer.begin_segment(spec.media_start_ms, spec.stall);
        let samples = &pcm[spec.begin * channels..spec.end * channels];
        let pushed = analyzer
            .push(samples, channels, &mut frames[produced..])
            .unwrap();
        assert_eq!(pushed.consumed, spec.end - spec.begin, "{}", fixture.name);
        produced += pushed.produced;
    }
    frames.truncate(produced);
    frames
}

fn analyze(fixture: &Fixture) -> Vec<DspFrame> {
    let settings = settings(fixture);
    if !fixture.spec.is_empty() {
        return analyze_edge(fixture, settings);
    }
    let specs: Vec<ChunkSpec> = lines_with(fixture.frames, "chunk")
        .map(parse_chunk)
        .collect();
    if specs.is_empty() {
        return analyze_wav(settings, fixture.wav).unwrap();
    }
    let samples = decode_wav_mono(fixture.wav, fixture.sample_rate_hz).unwrap();
    let chunks: Vec<PcmChunk> = specs
        .iter()
        .map(|s| PcmChunk {
            media_start_ms: s.media_start_ms,
            samples: &samples[s.begin..s.end],
            stall: s.stall,
        })
        .collect();
    analyze_pcm_chunks(settings, &chunks).unwrap()
}

type Errors = [f64; FEATURES.len()];

/// Largest absolute error per feature for one fixture: of the full-precision output, and of the
/// output rounded to 6 decimals the way the reference publishes it.
fn fixture_errors(fixture: &Fixture) -> (Errors, Errors) {
    let golden: Vec<Golden> = lines_with(fixture.frames, "frame")
        .map(parse_golden)
        .collect();
    let frames = analyze(fixture);
    assert_eq!(frames.len(), golden.len(), "{}: frame count", fixture.name);
    println!(
        "v{} {:<20} output digest {:016x}",
        fixture.behavior_version,
        fixture.name,
        digest(&frames)
    );
    // Invariant 3: the bits, not only the tolerance, must agree across targets.
    assert_eq!(
        digest(&frames),
        fixture.digest,
        "{}: output digest differs from the recorded value; see docs/portable-math.md",
        fixture.name
    );
    let mut worst = [0.0; FEATURES.len()];
    let mut worst_rounded = [0.0; FEATURES.len()];
    for (frame, want) in frames.iter().zip(&golden) {
        assert_eq!(frame.sequence, want.sequence, "{}: sequence", fixture.name);
        assert_eq!(frame.flags, want.flags, "{}: flags", fixture.name);
        let got = row(frame);
        let rounded: Vec<f64> = got.iter().map(|v| round6(*v)).collect();
        accumulate(&mut worst, &got, &want.values);
        accumulate(&mut worst_rounded, &rounded, &want.values);
    }
    (worst, worst_rounded)
}

/// FNV-1a over the bit patterns of every output value, to compare targets bit for bit.
fn digest(frames: &[DspFrame]) -> u64 {
    let bits = frames.iter().flat_map(row).map(f64::to_bits);
    bits.fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ b).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

fn round6(v: f64) -> f64 {
    (v * 1_000_000.0).round() / 1_000_000.0
}

fn accumulate(worst: &mut Errors, got: &[f64], want: &[f64]) {
    assert_eq!(got.len(), want.len(), "feature column count");
    for (w, (_, _, from, to)) in worst.iter_mut().zip(FEATURES) {
        let to = to.min(got.len());
        let errs = got[from..to].iter().zip(&want[from..to]);
        *w = errs
            .map(|(g, e)| {
                assert!(
                    g.is_finite() && e.is_finite(),
                    "non-finite feature or expected value"
                );
                let error = (g - e).abs();
                assert!(error.is_finite(), "non-finite feature error");
                error
            })
            .fold(*w, f64::max);
    }
}

fn max_each(a: Errors, b: Errors) -> Errors {
    core::array::from_fn(|i| a[i].max(b[i]))
}

#[test]
fn fixtures_match_reference_within_published_tolerance() {
    check_within_tolerance(&FIXTURES);
}

#[test]
fn v2_fixtures_match_the_oracle_within_published_tolerance() {
    check_within_tolerance(&V2_FIXTURES);
}

#[test]
fn edge_fixtures_match_reference_within_published_tolerance() {
    check_within_tolerance(&EDGE_FIXTURES[..4]);
}

#[test]
fn v2_edge_fixtures_match_the_oracle_within_published_tolerance() {
    check_within_tolerance(&EDGE_FIXTURES[4..]);
}

/// The anti-phase 1 kHz component cancels in the mixdown: the band that holds 1 kHz stays far
/// below its neighbours' level in the in-phase content.
#[test]
fn stereo_antiphase_component_cancels_in_the_mixdown() {
    for fixture in EDGE_FIXTURES
        .iter()
        .filter(|f| f.name == "stereo-antiphase")
    {
        let cfg = settings(fixture).config;
        let ratio = (cfg.spectrum_max_hz / cfg.spectrum_min_hz).powf(1.0 / 24.0);
        let band = (0..24)
            .find(|b| cfg.spectrum_min_hz * ratio.powi(b + 1) > 1000.0)
            .unwrap() as usize;
        let frames = analyze(fixture);
        let loudest = frames.iter().map(|f| f.spectrum[band]).fold(0.0, f64::max);
        println!(
            "v{} stereo-antiphase: band {band} (1 kHz) peak {loudest:.4}",
            fixture.behavior_version
        );
        // A 0.3-amplitude tone alone reaches about 0.9 here (-10 dB on a -90 dB floor).
        assert!(loudest < 0.75, "band {band}: {loudest}");
    }
}

fn check_within_tolerance(fixtures: &[Fixture]) {
    let mut worst = [0.0; FEATURES.len()];
    let mut worst_rounded = [0.0; FEATURES.len()];
    for fixture in fixtures {
        let (errs, rounded) = fixture_errors(fixture);
        worst = max_each(worst, errs);
        worst_rounded = max_each(worst_rounded, rounded);
    }
    println!("feature           tolerance  largest_error  largest_error_rounded_6dp");
    for (i, (name, tol, _, _)) in FEATURES.iter().enumerate() {
        println!(
            "{name:<17} {tol:<10.0e} {:<14.3e} {:.3e}",
            worst[i], worst_rounded[i]
        );
    }
    let over: Vec<&str> = FEATURES
        .iter()
        .zip(worst)
        .filter(|((_, tol, _, _), err)| err > tol)
        .map(|((name, ..), _)| *name)
        .collect();
    assert!(over.is_empty(), "features over tolerance: {over:?}");
}

#[test]
#[should_panic(expected = "non-finite feature")]
fn non_finite_output_cannot_pass_the_golden_comparison() {
    let mut got = [0.0; 31];
    got[7] = f64::NAN;
    accumulate(&mut [0.0; FEATURES.len()], &got, &[0.0; 31]);
}

#[test]
#[should_panic(expected = "non-finite feature")]
fn non_finite_expected_value_cannot_pass_the_golden_comparison() {
    let mut want = [0.0; 31];
    want[1] = f64::INFINITY;
    accumulate(&mut [0.0; FEATURES.len()], &[0.0; 31], &want);
}

fn v2_fixture(name: &str) -> &'static Fixture {
    V2_FIXTURES.iter().find(|f| f.name == name).unwrap()
}

/// Smallest kick onset and largest other onset (broadband) after 0.5 s, and the kick count. A
/// kick's onset is the largest within one analysis window after it starts.
fn kick_onsets(frames: &[DspFrame], cfg: &DspConfig) -> (f64, f64, usize) {
    let window_ms = cfg.fft_window_samples as f64 / cfg.sample_rate_hz as f64 * 1000.0;
    let last = frames.last().unwrap().media_time_ms;
    let kicks: Vec<f64> = (1..)
        .map(|k| 500.0 * k as f64)
        .take_while(|kick| kick + window_ms <= last)
        .collect();
    let after = |kick: f64, t: f64| kick < t && t <= kick + window_ms;
    let peak_after = |kick: f64| {
        let after_kick = frames.iter().filter(|f| after(kick, f.media_time_ms));
        after_kick.map(|f| f.onset.broadband).fold(0.0, f64::max)
    };
    let weakest = kicks.iter().map(|k| peak_after(*k)).fold(1.0, f64::min);
    let between = frames
        .iter()
        .filter(|f| f.media_time_ms > 500.0 && !kicks.iter().any(|k| after(*k, f.media_time_ms)))
        .map(|f| f.onset.broadband)
        .fold(0.0, f64::max);
    (weakest, between, kicks.len())
}

/// OSC-DSP-ONSET-NORM: after 0.5 s every kick yields a broadband onset of at least 0.8 and
/// every frame between kicks stays at or below 0.2.
#[test]
fn v2_every_kick_stands_out_and_between_kick_frames_stay_low() {
    let v1 = FIXTURES.iter().find(|f| f.name == "kicks-120bpm").unwrap();
    let (kick, between, _) = kick_onsets(&analyze(v1), &settings(v1).config);
    println!("v1 kicks-120bpm: weakest kick {kick:.4}, between-kick max {between:.4}");
    for name in ["kicks-120bpm", "kicks-120bpm-long"] {
        let fixture = v2_fixture(name);
        let (kick, between, count) = kick_onsets(&analyze(fixture), &settings(fixture).config);
        println!("v2 {name}: {count} kicks, weakest {kick:.4}, between-kick max {between:.4}");
        assert!(count >= 3, "{name}: {count} kicks");
        assert!(kick >= 0.8, "{name}: weakest kick onset {kick}");
        assert!(between <= 0.2, "{name}: between-kick onset {between}");
    }
}

/// Bands above 0.5 and the highest band of the last frame.
fn lit_bands(frame: &DspFrame) -> (Vec<usize>, usize) {
    let bands = frame.bands();
    let lit = (0..bands.len()).filter(|b| bands[*b] > 0.5).collect();
    let top = (0..bands.len())
        .max_by(|a, b| bands[*a].total_cmp(&bands[*b]))
        .unwrap();
    (lit, top)
}

/// OSC-DSP-LOW-BANDS criterion 2 as revised by owner decision D3: a full-scale 60 Hz tone puts
/// at most three bands above 0.5, and the highest is the band containing 60 Hz.
#[test]
fn v2_full_scale_60_hz_tone_lights_at_most_three_bands_peaking_at_its_own() {
    let cfg = DspConfig::default();
    let ratio = (cfg.spectrum_max_hz / cfg.spectrum_min_hz).powf(1.0 / cfg.spectrum_bands as f64);
    let own = (0..cfg.spectrum_bands as usize)
        .find(|b| cfg.spectrum_min_hz * ratio.powi(*b as i32 + 1) > 60.0)
        .unwrap();
    let rate = cfg.sample_rate_hz as f64;
    let tone: Vec<f64> = (0..cfg.sample_rate_hz)
        .map(|i| (2.0 * std::f64::consts::PI * 60.0 * i as f64 / rate).sin())
        .collect();
    let chunk = [PcmChunk {
        media_start_ms: 0.0,
        samples: &tone,
        stall: false,
    }];
    let v1 = analyze_pcm_chunks(cfg, &chunk).unwrap();
    println!(
        "v1 60 Hz tone: (bands above 0.5, highest) {:?}",
        lit_bands(v1.last().unwrap())
    );
    let fixture = analyze(v2_fixture("sine-60-full"));
    let v2 = analyze_pcm_chunks(DspSettings::default(), &chunk).unwrap();
    for (signal, frames) in [("sine-60-full fixture", fixture), ("f64 tone, 1 s", v2)] {
        let (lit, top) = lit_bands(frames.last().unwrap());
        println!("v2 {signal}: bands above 0.5 {lit:?}, highest {top}, own band {own}");
        assert!(lit.len() <= 3, "{signal}: {lit:?}");
        assert_eq!(top, own, "{signal}");
    }
}
