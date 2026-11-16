// SPDX-License-Identifier: AGPL-3.0-only
//! Beat-grid conformance vectors (`conformance/beatgrid/README.md`): synthetic scores rendered
//! here exactly as `tools/beatgrid-vectors.py` renders them, analysed, and compared with the
//! oracle's grids, the scores' annotations and the recorded Rust digests. The fixtures are
//! embedded, so the test runs unchanged on wasm32-wasip1.

use oscillux_core::beatgrid::*;

/// (name, score, oracle grid)
const VECTORS: [(&str, &str, &str); 6] = [
    (
        "clicks-120-44k1",
        include_str!("../../../conformance/beatgrid/clicks-120-44k1.score"),
        include_str!("../../../conformance/beatgrid/clicks-120-44k1.grid"),
    ),
    (
        "waltz-90-48k",
        include_str!("../../../conformance/beatgrid/waltz-90-48k.score"),
        include_str!("../../../conformance/beatgrid/waltz-90-48k.grid"),
    ),
    (
        "ramp-90-150-22k05",
        include_str!("../../../conformance/beatgrid/ramp-90-150-22k05.score"),
        include_str!("../../../conformance/beatgrid/ramp-90-150-22k05.grid"),
    ),
    (
        "step-100-140-22k05",
        include_str!("../../../conformance/beatgrid/step-100-140-22k05.score"),
        include_str!("../../../conformance/beatgrid/step-100-140-22k05.grid"),
    ),
    (
        "fast-200-8k",
        include_str!("../../../conformance/beatgrid/fast-200-8k.score"),
        include_str!("../../../conformance/beatgrid/fast-200-8k.grid"),
    ),
    (
        "groove-110-44k1",
        include_str!("../../../conformance/beatgrid/groove-110-44k1.score"),
        include_str!("../../../conformance/beatgrid/groove-110-44k1.grid"),
    ),
];

const NOISE_TABLE_SIZE: usize = 1 << 16;
const NOISE_SEED: u64 = 20_261_023;

enum Shape {
    Tone {
        f_start: f64,
        f_end: f64,
        glide: f64,
    },
    Noise {
        seed: i64,
        highpass: u32,
    },
}

struct Event {
    start: usize,
    length: usize,
    attack: usize,
    release: usize,
    amp: f64,
    decay: f64,
    shape: Shape,
}

struct Score {
    name: &'static str,
    rate: u32,
    pan: Vec<f64>,
    gain: f64,
    samples: usize,
    hint: u32,
    pcm_fnv1a: u64,
    events: Vec<Event>,
    /// (sample, beat in bar)
    beats: Vec<(usize, u32)>,
}

fn parse(name: &'static str, text: &str) -> Score {
    let mut score = Score {
        name,
        rate: 0,
        pan: Vec::new(),
        gain: 0.0,
        samples: 0,
        hint: 0,
        pcm_fnv1a: 0,
        events: Vec::new(),
        beats: Vec::new(),
    };
    let mut lines = text.lines();
    assert_eq!(lines.next(), Some("# beatgrid-score v1"), "{name}: header");
    for line in lines.filter(|line| !line.starts_with('#')) {
        let f: Vec<&str> = line.split_whitespace().collect();
        let num = |i: usize| f[i].parse::<f64>().expect("number");
        let int = |i: usize| f[i].parse::<usize>().expect("integer");
        match f[0] {
            "name" => assert_eq!(f[1], name),
            "description" => {}
            "rate" => score.rate = f[1].parse().expect("rate"),
            "pan" => score.pan = (1..f.len()).map(num).collect(),
            "gain" => score.gain = num(1),
            "samples" => score.samples = int(1),
            "beats_per_bar_hint" => score.hint = f[1].parse().expect("hint"),
            "pcm_fnv1a" => score.pcm_fnv1a = u64::from_str_radix(f[1], 16).expect("digest"),
            "tone" | "noise" => {
                let shape = if f[0] == "tone" {
                    Shape::Tone {
                        f_start: num(7),
                        f_end: num(8),
                        glide: num(9),
                    }
                } else {
                    Shape::Noise {
                        seed: f[7].parse().expect("seed"),
                        highpass: f[8].parse().expect("highpass"),
                    }
                };
                score.events.push(Event {
                    start: int(1),
                    length: int(2),
                    attack: int(3),
                    release: int(4),
                    amp: num(5),
                    decay: num(6),
                    shape,
                });
            }
            "beat" => score
                .beats
                .push((int(1), f[2].parse().expect("beat in bar"))),
            _ => panic!("{name}: unknown row {line:?}"),
        }
    }
    score
}

fn noise_table() -> Vec<f64> {
    let mut state = NOISE_SEED;
    (0..NOISE_TABLE_SIZE)
        .map(|_| {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            (state >> 11) as f64 / 9_007_199_254_740_992.0 - 0.5
        })
        .collect()
}

/// The parabolic sine of `tools/beatgrid-vectors.py`, with the same operation order.
fn sine_shape(p: f64) -> f64 {
    let y = if p < 0.5 {
        16.0 * p * (0.5 - p)
    } else {
        let q = p - 0.5;
        -16.0 * q * (0.5 - q)
    };
    0.225 * (y * y.abs() - y) + y
}

/// Adds one event to `buf` exactly as the generator does.
fn add_event(buf: &mut [f64], event: &Event, rate: u32, table: &[f64]) {
    let mask = NOISE_TABLE_SIZE as i64 - 1;
    let t = |index: i64| table[(index & mask) as usize];
    let step = 1.0 / rate as f64;
    let (mut decay, mut glide, mut phase) = (1.0, 1.0, 0.0_f64);
    for i in 0..event.length {
        let a = if i < event.attack {
            i as f64 / event.attack as f64
        } else {
            1.0
        };
        let left = event.length - i;
        let r = if left < event.release {
            left as f64 / event.release as f64
        } else {
            1.0
        };
        let env = ((event.amp * a) * r) * decay;
        decay *= event.decay;
        let shape = match event.shape {
            Shape::Tone {
                f_start,
                f_end,
                glide: g,
            } => {
                let y = sine_shape(phase - phase.floor());
                phase += (f_end + (f_start - f_end) * glide) * step;
                glide *= g;
                y
            }
            Shape::Noise { seed, highpass } => {
                let k = seed + i as i64;
                match highpass {
                    0 => t(k),
                    1 => t(k) - t(k - 1),
                    _ => (t(k) - t(k - 1)) - (t(k - 1) - t(k - 2)),
                }
            }
        };
        buf[event.start + i] += env * shape;
    }
}

fn quantise(value: f64) -> i16 {
    let x = value.clamp(-1.0, 1.0) * 32767.0;
    ((x.abs() + 0.5).floor().copysign(x)) as i16
}

fn fnv1a64(bytes: impl Iterator<Item = u8>) -> u64 {
    bytes.fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// The interleaved samples of a score as `f32` in `[-1, 1)`; checks the 16-bit samples against
/// the digest the generator recorded.
fn render(score: &Score, table: &[f64]) -> Vec<f32> {
    let mut buf = vec![0.0; score.samples];
    for event in &score.events {
        add_event(&mut buf, event, score.rate, table);
    }
    let gains: Vec<f64> = score.pan.iter().map(|p| score.gain * p).collect();
    let pcm: Vec<i16> = buf
        .iter()
        .flat_map(|x| gains.iter().map(move |g| quantise(g * x)))
        .collect();
    assert_eq!(
        fnv1a64(pcm.iter().flat_map(|s| s.to_le_bytes())),
        score.pcm_fnv1a,
        "{}: rendered PCM differs from the generator's",
        score.name
    );
    pcm.iter().map(|&s| f32::from(s) / 32768.0).collect()
}

fn config(score: &Score) -> BeatGridConfig {
    BeatGridConfig {
        sample_rate_hz: score.rate,
        channels: score.pan.len() as u32,
        beats_per_bar: score.hint,
        ..BeatGridConfig::default()
    }
}

struct Rendered {
    score: Score,
    pcm: Vec<f32>,
    grid: BeatGrid,
}

fn rendered() -> &'static [Rendered] {
    static CELL: std::sync::OnceLock<Vec<Rendered>> = std::sync::OnceLock::new();
    CELL.get_or_init(|| {
        let table = noise_table();
        VECTORS
            .iter()
            .map(|&(name, text, _)| {
                let score = parse(name, text);
                let pcm = render(&score, &table);
                let grid = BeatGrid::analyse(&config(&score), &pcm).expect("valid config");
                Rendered { score, pcm, grid }
            })
            .collect()
    })
}

/// F-measure of `detected` against `reference` (seconds) with greedy in-order matching, and
/// the signed errors (detected − reference) of the matched pairs.
fn matches(detected: &[f64], reference: &[f64], tolerance: f64) -> (f64, Vec<f64>) {
    let (mut i, mut j, mut errors) = (0, 0, Vec::new());
    while i < detected.len() && j < reference.len() {
        let d = detected[i] - reference[j];
        if d.abs() <= tolerance {
            errors.push(d);
            i += 1;
            j += 1;
        } else if d < 0.0 {
            i += 1;
        } else {
            j += 1;
        }
    }
    if errors.is_empty() {
        return (0.0, errors);
    }
    let p = errors.len() as f64 / detected.len() as f64;
    let r = errors.len() as f64 / reference.len() as f64;
    (2.0 * p * r / (p + r), errors)
}

fn mean_sd(v: &[f64]) -> (f64, f64) {
    let n = v.len() as f64;
    let mean = v.iter().sum::<f64>() / n;
    let var = v.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / n;
    (mean, var.sqrt())
}

/// Beat and downbeat F-measure at ±70 ms against the score's annotations, and the signed
/// beat-time errors, ms.
fn against_truth(r: &Rendered) -> (f64, f64, Vec<f64>) {
    let rate = f64::from(r.score.rate);
    let truth: Vec<f64> = r.score.beats.iter().map(|b| b.0 as f64 / rate).collect();
    let truth_down: Vec<f64> = r
        .score
        .beats
        .iter()
        .filter(|b| b.1 == 0)
        .map(|b| b.0 as f64 / rate)
        .collect();
    let beats: Vec<f64> = r.grid.beats().iter().map(|b| b.time_s).collect();
    let down: Vec<f64> = r
        .grid
        .beats()
        .iter()
        .filter(|b| b.beat_in_bar == 0)
        .map(|b| b.time_s)
        .collect();
    let (f, errors) = matches(&beats, &truth, 0.07);
    let (fd, _) = matches(&down, &truth_down, 0.07);
    (f, fd, errors.iter().map(|e| e * 1000.0).collect())
}

/// A `.grid` file written by the oracle.
struct OracleGrid {
    beat_count: usize,
    bar_count: usize,
    beats_per_bar: u32,
    tempo_bpm: f64,
    confidence: f64,
    duration_s: f64,
    beats: Vec<GridBeat>,
    /// (media time, expected clock)
    clocks: Vec<(f64, BeatClock)>,
}

fn parse_grid(name: &str, score: &Score, text: &str) -> OracleGrid {
    let mut g = OracleGrid {
        beat_count: usize::MAX,
        bar_count: usize::MAX,
        beats_per_bar: u32::MAX,
        tempo_bpm: f64::NAN,
        confidence: f64::NAN,
        duration_s: f64::NAN,
        beats: Vec::new(),
        clocks: Vec::new(),
    };
    let float = |v: &str| {
        v.parse::<f64>()
            .unwrap_or_else(|_| panic!("{name}: bad number {v}"))
    };
    let int = |v: &str| {
        v.parse::<u64>()
            .unwrap_or_else(|_| panic!("{name}: bad integer {v}"))
    };
    for line in text.lines().filter(|l| !l.starts_with('#')) {
        let f: Vec<&str> = line.split(' ').collect();
        match (f[0], f.len()) {
            ("name", 2) => assert_eq!(f[1], name),
            ("config", 7) => {
                assert_eq!(
                    f[1..],
                    [
                        "rate",
                        &score.rate.to_string(),
                        "channels",
                        &score.pan.len().to_string(),
                        "beats_per_bar",
                        &score.hint.to_string()
                    ]
                );
            }
            ("info", 7) => {
                assert_eq!(
                    [f[1], f[3], f[5]],
                    ["beat_count", "bar_count", "beats_per_bar"]
                );
                g.beat_count = int(f[2]) as usize;
                g.bar_count = int(f[4]) as usize;
                g.beats_per_bar = int(f[6]) as u32;
            }
            ("tempo_bpm", 2) => g.tempo_bpm = float(f[1]),
            ("confidence", 2) => g.confidence = float(f[1]),
            ("duration_s", 2) => g.duration_s = float(f[1]),
            ("beat", 5) => g.beats.push(GridBeat {
                time_s: float(f[1]),
                tempo_bpm: float(f[2]),
                beat_in_bar: int(f[3]) as u32,
                bar_index: int(f[4]) as u32,
            }),
            ("clock", 7) => g.clocks.push((
                float(f[1]),
                BeatClock {
                    beat_phase: float(f[2]),
                    bar_phase: float(f[3]),
                    tempo_bpm: float(f[4]),
                    beat_index: f[5].parse().unwrap(),
                    beat_in_bar: int(f[6]) as u32,
                    reserved: 0,
                },
            )),
            _ => panic!("{name}: unexpected line {line}"),
        }
    }
    assert_eq!(g.beats.len(), g.beat_count, "{name}: beat lines");
    assert!(g.duration_s.is_finite() && g.confidence.is_finite() && !g.clocks.is_empty());
    g
}

/// README "Tolerances".
const TIME_TOL: f64 = 1e-6;
const REL_TOL: f64 = 1e-6;
const UNIT_TOL: f64 = 1e-6;

fn close_rel(a: f64, b: f64) -> bool {
    (a - b).abs() <= REL_TOL * b.abs().max(1.0)
}

/// OSC-BEAT-GRID: the Rust grids and clocks agree with the independent oracle's within the
/// published tolerances, with every integer field exact.
#[test]
fn grids_match_oracle() {
    for (r, &(name, _, text)) in rendered().iter().zip(&VECTORS) {
        let want = parse_grid(name, &r.score, text);
        let info = r.grid.info();
        assert_eq!(
            (info.beat_count, info.bar_count, info.beats_per_bar),
            (want.beat_count, want.bar_count, want.beats_per_bar),
            "{name}: counts"
        );
        assert!(
            close_rel(info.tempo_bpm, want.tempo_bpm),
            "{name}: tempo {}",
            info.tempo_bpm
        );
        assert!(
            (info.confidence - want.confidence).abs() <= UNIT_TOL,
            "{name}: confidence"
        );
        assert!(
            (info.duration_s - want.duration_s).abs() <= TIME_TOL,
            "{name}: duration"
        );
        let mut worst = (0.0f64, 0.0f64, 0.0f64);
        for (i, (got, exp)) in r.grid.beats().iter().zip(&want.beats).enumerate() {
            assert_eq!(
                (got.beat_in_bar, got.bar_index),
                (exp.beat_in_bar, exp.bar_index),
                "{name}: beat {i} position"
            );
            assert!(
                (got.time_s - exp.time_s).abs() <= TIME_TOL,
                "{name}: beat {i} time"
            );
            assert!(
                close_rel(got.tempo_bpm, exp.tempo_bpm),
                "{name}: beat {i} tempo"
            );
            worst.0 = worst.0.max((got.time_s - exp.time_s).abs());
        }
        for &(t, exp) in &want.clocks {
            let got = r.grid.clock(t);
            assert_eq!(
                (got.beat_index, got.beat_in_bar, got.reserved),
                (exp.beat_index, exp.beat_in_bar, 0),
                "{name}: clock at {t}"
            );
            assert!(
                (got.beat_phase - exp.beat_phase).abs() <= UNIT_TOL,
                "{name}: phase at {t}"
            );
            assert!(
                (got.bar_phase - exp.bar_phase).abs() <= UNIT_TOL,
                "{name}: bar at {t}"
            );
            assert!(
                close_rel(got.tempo_bpm, exp.tempo_bpm),
                "{name}: clock tempo at {t}"
            );
            worst.1 = worst.1.max((got.beat_phase - exp.beat_phase).abs());
            worst.2 = worst.2.max((got.bar_phase - exp.bar_phase).abs());
        }
        println!(
            "{name:20} oracle max |dt| {:.1e} s, |d phase| {:.1e}, |d bar phase| {:.1e}",
            worst.0, worst.1, worst.2
        );
    }
}

/// The meter each score is written in: one more than its largest annotated bar position.
fn annotated_meter(score: &Score) -> u32 {
    score.beats.iter().map(|b| b.1).max().unwrap() + 1
}

/// OSC-BEAT-GRID acceptance on the synthetic vectors: beat F ≥ 0.85 at ±70 ms on every vector
/// (the ramp and step among them), the annotated meter, downbeat F ≥ 0.70, and on the click
/// track a beat-time bias within 5 ms with a spread within 10 ms.
#[test]
fn grids_match_annotations() {
    for r in rendered() {
        let name = r.score.name;
        let (f, fd, errors) = against_truth(r);
        let (mean, sd) = mean_sd(&errors);
        let info = r.grid.info();
        println!(
            "{name:20} beats {:3}/{:3} F {f:.3} downbeat F {fd:.3} offset {mean:+.2} ms sd \
             {sd:.2} ms tempo {:.2} meter {} confidence {:.2}",
            info.beat_count,
            r.score.beats.len(),
            info.tempo_bpm,
            info.beats_per_bar,
            info.confidence
        );
        assert!(f >= 0.85, "{name}: beat F {f:.3}");
        assert!(fd >= 0.70, "{name}: downbeat F {fd:.3}");
        assert_eq!(
            info.beats_per_bar,
            annotated_meter(&r.score),
            "{name}: meter"
        );
        if name.starts_with("clicks") {
            assert!(
                mean.abs() <= 5.0 && sd <= 10.0,
                "{name}: offset {mean:.2} sd {sd:.2} ms"
            );
        }
    }
}

/// FNV-1a over the grid and its clock at the oracle's sample times, as `u64` words: summary
/// fields, then per beat its time, tempo, bar position and bar, then per clock sample its five
/// fields.
fn grid_digest(r: &Rendered, clocks: &[(f64, BeatClock)]) -> u64 {
    let info = r.grid.info();
    let mut words = vec![
        info.beat_count as u64,
        info.bar_count as u64,
        u64::from(info.beats_per_bar),
        info.tempo_bpm.to_bits(),
        info.confidence.to_bits(),
        info.duration_s.to_bits(),
    ];
    for b in r.grid.beats() {
        words.extend([
            b.time_s.to_bits(),
            b.tempo_bpm.to_bits(),
            u64::from(b.beat_in_bar),
            u64::from(b.bar_index),
        ]);
    }
    for &(t, _) in clocks {
        let c = r.grid.clock(t);
        words.extend([
            c.beat_phase.to_bits(),
            c.bar_phase.to_bits(),
            c.tempo_bpm.to_bits(),
            c.beat_index as u64,
            u64::from(c.beat_in_bar),
        ]);
    }
    fnv1a64(words.iter().flat_map(|w| w.to_le_bytes()))
}

/// Rust grid digests, recorded on aarch64-apple-darwin and checked unchanged on wasm32-wasip1
/// (`make test-wasi`): the grids are bit-identical across targets. The README lists them.
const DIGESTS: [(&str, u64); 6] = [
    ("clicks-120-44k1", 0x303c1730b6d8b96c),
    ("waltz-90-48k", 0x86f0c53a88e61daf),
    ("ramp-90-150-22k05", 0xc03cbc911a291846),
    ("step-100-140-22k05", 0x9af0cbc9a335dd0f),
    ("fast-200-8k", 0x3a9b45d69c7d5b86),
    ("groove-110-44k1", 0x3cea8b96a3078458),
];

#[test]
fn grids_are_bit_identical() {
    let mut problems = Vec::new();
    for ((r, &(name, _, text)), &(want_name, want)) in rendered().iter().zip(&VECTORS).zip(&DIGESTS)
    {
        assert_eq!(name, want_name);
        let got = grid_digest(r, &parse_grid(name, &r.score, text).clocks);
        if got != want {
            problems.push(format!("(\"{name}\", 0x{got:016x})"));
        }
    }
    assert!(
        problems.is_empty(),
        "grid digests differ: {}",
        problems.join(", ")
    );
}

/// Analysis of the same PCM twice gives the same grid, and the clock is consistent with it:
/// phases in [0, 1), the beat index steps by one per beat, and the bar phase follows the beat.
#[test]
fn clock_follows_the_grid() {
    let r = &rendered()[1];
    assert_eq!(
        BeatGrid::analyse(&config(&r.score), &r.pcm).unwrap(),
        r.grid
    );
    let beats = r.grid.beats();
    let meter = f64::from(r.grid.info().beats_per_bar);
    for (i, w) in beats.windows(2).enumerate() {
        for frac in [0.0, 0.25, 0.5, 0.999] {
            let t = w[0].time_s + frac * (w[1].time_s - w[0].time_s);
            let c = r.grid.clock(t);
            assert_eq!((c.beat_index, c.beat_in_bar), (i as i64, w[0].beat_in_bar));
            assert!((c.beat_phase - frac).abs() < 1e-9 && c.beat_phase < 1.0);
            let bar = (f64::from(w[0].beat_in_bar) + c.beat_phase) / meter;
            assert!((c.bar_phase - bar).abs() < 1e-12 && c.bar_phase < 1.0);
            assert_eq!(c.tempo_bpm, w[0].tempo_bpm);
        }
    }
    // extrapolation at the first and last interval
    let iv = beats[1].time_s - beats[0].time_s;
    let c = r.grid.clock(beats[0].time_s - 2.5 * iv);
    assert_eq!(c.beat_index, -3);
    assert!((c.beat_phase - 0.5).abs() < 1e-9);
    let n = beats.len();
    let iv = beats[n - 1].time_s - beats[n - 2].time_s;
    let c = r.grid.clock(beats[n - 1].time_s + 1.25 * iv);
    assert_eq!(c.beat_index, n as i64);
    assert_eq!(c.beat_in_bar, (beats[n - 1].beat_in_bar + 1) % meter as u32);
    assert!((c.beat_phase - 0.25).abs() < 1e-9);
    // absurd finite times saturate instead of overflowing the beat index
    assert!(r.grid.clock(f64::MAX).beat_index >= n as i64);
    assert!(r.grid.clock(-f64::MAX).beat_index < 0);
    for t in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert_eq!(
            r.grid.clock(t),
            BeatClock {
                beat_index: -1,
                ..BeatClock::default()
            }
        );
    }
}

/// Configurations outside the documented ranges are refused, naming the field; silence and
/// short PCM give an empty grid with the PCM duration, whose clock reports no beat.
#[test]
fn contract_edges() {
    let ok = BeatGridConfig::default();
    assert_eq!(ok.validate(), Ok(()));
    let bad = [
        (
            BeatGridConfig {
                sample_rate_hz: 7_999,
                ..ok
            },
            "sample_rate_hz",
        ),
        (
            BeatGridConfig {
                sample_rate_hz: 384_001,
                ..ok
            },
            "sample_rate_hz",
        ),
        (BeatGridConfig { channels: 0, ..ok }, "channels"),
        (
            BeatGridConfig {
                min_bpm: 19.0,
                ..ok
            },
            "min_bpm",
        ),
        (
            BeatGridConfig {
                min_bpm: f64::NAN,
                ..ok
            },
            "min_bpm",
        ),
        (
            BeatGridConfig {
                max_bpm: 40.0,
                ..ok
            },
            "max_bpm",
        ),
        (
            BeatGridConfig {
                max_bpm: 401.0,
                ..ok
            },
            "max_bpm",
        ),
        (
            BeatGridConfig {
                beats_per_bar: 1,
                ..ok
            },
            "beats_per_bar",
        ),
        (
            BeatGridConfig {
                beats_per_bar: 17,
                ..ok
            },
            "beats_per_bar",
        ),
        (BeatGridConfig { reserved: 1, ..ok }, "reserved"),
    ];
    for (config, field) in bad {
        assert_eq!(
            BeatGrid::analyse(&config, &[0.0; 4]),
            Err(BeatGridError::InvalidConfig(field))
        );
    }
    assert_eq!(
        BeatGrid::analyse(&ok, &[0.0; 3]),
        Err(BeatGridError::InvalidLength)
    );
    let mono = BeatGridConfig { channels: 1, ..ok };
    for samples in [
        vec![],
        vec![0.0f32; 44_100 * 10],
        vec![f32::NAN; 44_100 * 10],
        vec![0.5; 4410],
    ] {
        let grid = BeatGrid::analyse(&mono, &samples).unwrap();
        let info = grid.info();
        assert!(grid.beats().is_empty());
        assert_eq!(
            (info.beat_count, info.bar_count, info.beats_per_bar),
            (0, 0, 0)
        );
        assert_eq!((info.tempo_bpm, info.confidence), (0.0, 0.0));
        assert_eq!(info.duration_s, samples.len() as f64 / 44_100.0);
        assert_eq!(
            grid.clock(1.0),
            BeatClock {
                beat_index: -1,
                ..BeatClock::default()
            }
        );
    }
}

/// OSC-BEAT-GRID: a 4-minute 44.1 kHz stereo file analyses in under 2 s on one thread. Timing
/// depends on the machine and build, so it is ignored by default; run it in release with
/// `cargo test --release -p oscillux-core --test beatgrid_vectors -- --ignored`.
#[test]
#[ignore = "timing; run in release with --ignored"]
fn four_minutes_analyse_in_two_seconds() {
    let r = rendered()
        .iter()
        .find(|r| r.score.name == "groove-110-44k1")
        .unwrap();
    let mono: Vec<f32> = r.pcm.clone();
    let mut stereo = Vec::with_capacity(44_100 * 240 * 2);
    while stereo.len() < 44_100 * 240 * 2 {
        for &s in &mono {
            stereo.extend([s, s]);
        }
    }
    stereo.truncate(44_100 * 240 * 2);
    let config = BeatGridConfig::default();
    let started = std::time::Instant::now();
    let grid = BeatGrid::analyse(&config, &stereo).unwrap();
    let elapsed = started.elapsed().as_secs_f64();
    println!(
        "240 s at 44.1 kHz stereo: {} beats in {elapsed:.3} s",
        grid.info().beat_count
    );
    assert!(grid.info().beat_count > 200);
    assert!(elapsed < 2.0, "analysis took {elapsed:.3} s");
}
