// SPDX-License-Identifier: AGPL-3.0-only
//! Beat-to-photon harness for the reaction sampler (OSC-REACT-SYNC).
//!
//! Synthesises 10 ms clicks at 120 to 200 BPM, analyses them at the DSP behaviour version named
//! by `OSCILLUX_REACTION_DSP` (default 3; `make reaction-photon REACTION_DSP=n`, part of
//! `make gate`; the tests are ignored in debug `cargo test`), maps the hops
//! and samples them at simulated display frames, then measures:
//!
//! - onsets: every click raises onset to at least 0.5 in the first frame presented after it, at
//!   30, 60 and 120 Hz;
//! - beat to photon: the beat pulse peak against the true beat time at 60 Hz, for a known beat
//!   clock and for the tracker's output;
//! - smoothness: the beat phase never steps back except at the wrap and moves at 0.5 to 2
//!   times the nominal rate; continuous values stay between the hops around them;
//! - the analysis latency table: [`ANALYSIS_LATENCY`] covers the measured lag.
//!
//! Display times are photon times on the heard-media timeline; the harness converts them to
//! sample times through declared output, display and render-ahead latencies.

use oscillux_core::dsp::*;
use oscillux_core::mapping::*;
use oscillux_core::reaction::*;

/// Sample rates every vector runs at.
const RATES: [u32; 2] = [48_000, 44_100];
const SECONDS: f64 = 20.0;
const BPMS: [f64; 6] = [120.0, 133.0, 150.0, 167.0, 180.0, 200.0];
/// Beats before this time are lock-in, not measured.
const WARMUP_MS: f64 = 8_000.0;
/// Host scenarios every measurement runs: declared latencies and how far past the output write
/// head the host has analysed.
#[derive(Clone, Copy)]
struct Scenario {
    output_ms: f64,
    display_ms: f64,
    render_ahead_ms: f64,
    /// Hops whose window ends at most this far past the write head are pushed; infinite for a
    /// file analysed ahead, 0 for live audio analysed as it is written.
    lookahead_ms: f64,
}

const SCENARIOS: [Scenario; 2] = [
    Scenario {
        output_ms: 0.0,
        display_ms: 0.0,
        render_ahead_ms: 0.0,
        lookahead_ms: f64::INFINITY,
    },
    // Live: the output latency covers render-ahead, display and onset latency, so the hop of a
    // click is analysed before the frame showing it is sampled.
    Scenario {
        output_ms: 40.0,
        display_ms: 9.0,
        render_ahead_ms: 16.7,
        lookahead_ms: 0.0,
    },
];

fn version() -> u32 {
    std::env::var("OSCILLUX_REACTION_DSP")
        .ok()
        .map(|v| {
            v.parse()
                .expect("OSCILLUX_REACTION_DSP is a DSP behaviour version")
        })
        .unwrap_or(DSP_BEHAVIOR_V3)
}

struct Lcg(u32);

impl Lcg {
    fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        (self.0 >> 8) as f64 / 16_777_216.0
    }
}

/// A click vector: mono PCM and the click start times in ms.
struct Clicks {
    rate: u32,
    bpm: f64,
    pcm: Vec<f32>,
    times_ms: Vec<f64>,
}

/// 10 ms clicks, half white noise and half a 60 Hz sine, from a random start at exact tempo.
fn clicks(rate: u32, bpm: f64, seed: u32) -> Clicks {
    let r = rate as f64;
    let n = (SECONDS * r) as usize;
    let mut pcm = vec![0f32; n];
    let mut rng = Lcg(seed);
    let len = (0.010 * r) as usize;
    let mut times_ms = vec![];
    let mut k = 0;
    let first = 250.0 + rng.next() * 60_000.0 / bpm;
    loop {
        let start = libm::ceil((first + k as f64 * 60_000.0 / bpm) * r / 1000.0) as usize;
        if start + len + 960 >= n {
            break;
        }
        times_ms.push(start as f64 * 1000.0 / r);
        for i in 0..len {
            let noise = rng.next() * 2.0 - 1.0;
            let tone = libm::sin(2.0 * core::f64::consts::PI * 60.0 * i as f64 / r);
            pcm[start + i] = (0.5 * noise + 0.5 * tone) as f32;
        }
        k += 1;
    }
    Clicks {
        rate,
        bpm,
        pcm,
        times_ms,
    }
}

fn vectors() -> Vec<Clicks> {
    RATES
        .iter()
        .flat_map(|&rate| {
            BPMS.iter()
                .enumerate()
                .map(move |(i, &bpm)| clicks(rate, bpm, 0x5eed_0000 + i as u32))
        })
        .collect()
}

/// Analysed and mapped hops: window-end media time, mapped values, tracker output.
type Hops = Vec<(f64, Mapped, Beat)>;

fn analyse(c: &Clicks, version: u32) -> Hops {
    let pcm = &c.pcm;
    let dsp = DspConfig {
        sample_rate_hz: c.rate,
        ..DspConfig::default()
    };
    let settings = DspSettings {
        config: dsp,
        behavior_version: version,
    };
    let mut analyzer = Analyzer::new(settings).unwrap();
    let mut mapper = Mapper::new(MappingConfig::for_dsp(&dsp)).unwrap();
    let mut out = vec![DspFrame::ZERO; pcm.len() / 512 + 2];
    let mut ext = vec![FrameExt::ZERO; out.len()];
    let produced = analyzer
        .push_ext(pcm, 1, &mut out, &mut ext)
        .unwrap()
        .produced;
    (0..produced)
        .map(|k| {
            let e = &ext[k];
            let m = mapper
                .map_ext(&out[k], Some(&e.descriptors), Some(&e.levels), false)
                .unwrap();
            (out[k].media_time_ms, m, e.beat)
        })
        .collect()
}

fn config(version: u32, rate: u32, s: Scenario) -> ReactionConfig {
    ReactionConfig {
        capacity: 4096,
        output_latency_ms: s.output_ms,
        display_latency_ms: s.display_ms,
        render_ahead_ms: s.render_ahead_ms,
        ..ReactionConfig::for_dsp(version, rate).expect("a measured DSP version")
    }
}

/// One rendered frame: photon time and the sampled values.
struct Frame {
    photon_ms: f64,
    r: Reaction,
}

/// Samples `hops` at frames `period_ms` apart from `phase_ms` (photon times), as host `s` runs
/// them. The sample call's time is the output write head: the media position entering the
/// output, heard `output_ms` later.
fn render(
    hops: &Hops,
    s: Scenario,
    cfg: ReactionConfig,
    period_ms: f64,
    phase_ms: f64,
    clock: Option<BeatClock>,
) -> Vec<Frame> {
    let mut sampler = ReactionSampler::new(cfg).unwrap();
    sampler.set_beat_clock(clock.as_ref()).unwrap();
    let ahead = cfg.render_ahead_ms + cfg.display_latency_ms - cfg.output_latency_ms;
    let mut next = 0;
    let mut frames = vec![];
    let mut k = 0;
    loop {
        let photon = phase_ms + k as f64 * period_ms;
        if photon > SECONDS * 1000.0 - 50.0 {
            break;
        }
        let time = photon - ahead;
        while next < hops.len() && hops[next].0 <= time + s.lookahead_ms {
            sampler
                .push(hops[next].0, &hops[next].1, Some(&hops[next].2))
                .unwrap();
            next += 1;
        }
        frames.push(Frame {
            photon_ms: photon,
            r: sampler.sample(time).unwrap(),
        });
        k += 1;
    }
    frames
}

struct Stats {
    n: usize,
    mean: f64,
    mean_abs: f64,
    sd: f64,
    min: f64,
    max: f64,
}

fn stats(v: &[f64]) -> Stats {
    let n = v.len().max(1) as f64;
    let mean = v.iter().sum::<f64>() / n;
    let sd = (v.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / n).sqrt();
    Stats {
        n: v.len(),
        mean,
        mean_abs: v.iter().map(|x| x.abs()).sum::<f64>() / n,
        sd,
        min: v.iter().cloned().fold(f64::INFINITY, f64::min),
        max: v.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
    }
}

fn show(s: &Stats) -> String {
    format!(
        "n={} mean={:+.3} mean|.|={:.3} sd={:.3} min={:+.3} max={:+.3}",
        s.n, s.mean, s.mean_abs, s.sd, s.min, s.max
    )
}

#[test]
#[ignore = "release-profile harness; make reaction-photon runs it"]
fn every_click_raises_onset_in_the_first_frame_after_it() {
    let v = version();
    let mut lost = 0;
    let mut checked = 0;
    let mut lowest = f64::INFINITY;
    for c in vectors() {
        let hops = analyse(&c, v);
        for rate in [30.0, 60.0, 120.0] {
            let period = 1000.0 / rate;
            let mut rng = Lcg(c.bpm as u32 * 7 + rate as u32);
            for sc in SCENARIOS {
                for _ in 0..4 {
                    let phase = rng.next() * period;
                    let frames = render(&hops, sc, config(v, c.rate, sc), period, phase, None);
                    for &t in &c.times_ms {
                        let f = frames.iter().find(|f| f.photon_ms >= t).unwrap();
                        let onset = f.r.mapped.values[ONSET];
                        lowest = lowest.min(onset);
                        checked += 1;
                        if onset < 0.5 {
                            lost += 1;
                            // the analysis's own peak for this click: below 0.5, the DSP
                            // version (not the sampler) is what keeps the onset low
                            let analysed = hops
                                .iter()
                                .filter(|h| h.0 >= t && h.0 <= t + 200.0)
                                .map(|h| h.1.values[ONSET])
                                .fold(0.0, f64::max);
                            println!(
                                "lost: v{v} {} BPM {rate} Hz click {t:.2} ms frame {:.2} ms onset {onset:.3} analysed peak {analysed:.3}",
                                c.bpm, f.photon_ms
                            );
                        }
                    }
                }
            }
        }
    }
    println!(
        "criterion 1 (DSP v{v}): {checked} click-frames at 30/60/120 Hz, {lost} below 0.5, lowest onset {lowest:.4}"
    );
    assert_eq!(lost, 0);
}

/// Pulse peaks: the photon time of each frame whose pulse is a local maximum above 0.5, and the
/// sub-frame time at which the output beat position crosses each integer.
fn peaks(frames: &[Frame]) -> (Vec<f64>, Vec<f64>) {
    let mut maxima = vec![];
    let mut crossings = vec![];
    for i in 1..frames.len() - 1 {
        let (a, b, c) = (frames[i - 1].r.beat, frames[i].r.beat, frames[i + 1].r.beat);
        if b > 0.5 && b > a && b >= c {
            maxima.push(frames[i].photon_ms);
        }
        let (p, q) = (&frames[i - 1], &frames[i]);
        if p.r.locked == 1 && q.r.locked == 1 && q.r.beat_phase < p.r.beat_phase && q.r.beat > 0.5 {
            let before = p.r.beat_phase;
            let after = 1.0 + q.r.beat_phase;
            let w = (1.0 - before) / (after - before);
            crossings.push(p.photon_ms + w * (q.photon_ms - p.photon_ms));
        }
    }
    (maxima, crossings)
}

/// Offset of each peak after the warm-up to the nearest true beat.
fn offsets(peaks: &[f64], beats: &[f64]) -> Vec<f64> {
    peaks
        .iter()
        .filter(|&&p| p >= WARMUP_MS)
        .map(|&p| {
            let i = beats.partition_point(|&b| b <= p);
            let mut d = f64::INFINITY;
            for &b in &beats[i.saturating_sub(1)..(i + 1).min(beats.len())] {
                if (p - b).abs() < d.abs() {
                    d = p - b;
                }
            }
            d
        })
        .collect()
}

/// True beats after the warm-up with no peak within a quarter beat.
fn missed(peaks: &[f64], beats: &[f64], beat_ms: f64) -> usize {
    beats
        .iter()
        .filter(|&&b| b >= WARMUP_MS && b <= peaks.last().copied().unwrap_or(0.0))
        .filter(|&&b| !peaks.iter().any(|p| (p - b).abs() < beat_ms / 4.0))
        .count()
}

#[derive(Default)]
struct PhotonResult {
    /// Peak frame to true beat, ms.
    frame: Vec<f64>,
    /// Sub-frame pulse-peak time to true beat, ms.
    crossing: Vec<f64>,
    missed: usize,
}

impl PhotonResult {
    fn extend(&mut self, o: PhotonResult) {
        self.frame.extend(o.frame);
        self.crossing.extend(o.crossing);
        self.missed += o.missed;
    }
}

/// Runs every vector at 60 Hz with four random frame phases per scenario, returning results per
/// vector with the tracker's final tempo.
fn photon(clock: bool, v: u32) -> Vec<(Clicks, f64, PhotonResult)> {
    let period = 1000.0 / 60.0;
    let mut out = vec![];
    for c in vectors() {
        let hops = analyse(&c, v);
        let beat_ms = 60_000.0 / c.bpm;
        let mut rng = Lcg(c.bpm as u32 * 13 + clock as u32 + c.rate);
        let true_clock = BeatClock {
            media_time_ms: c.times_ms[0],
            tempo_bpm: c.bpm,
            beat_phase: 0.0,
            bar_phase: 0.0,
            beat_index: 0,
            beats_per_bar: 4,
            reserved: 0,
        };
        let mut per = PhotonResult::default();
        for sc in SCENARIOS {
            for _ in 0..4 {
                let phase = rng.next() * period;
                let cfg = config(v, c.rate, sc);
                let frames = render(&hops, sc, cfg, period, phase, clock.then_some(true_clock));
                let (maxima, crossings) = peaks(&frames);
                per.extend(PhotonResult {
                    frame: offsets(&maxima, &c.times_ms),
                    crossing: offsets(&crossings, &c.times_ms),
                    missed: missed(&crossings, &c.times_ms, beat_ms),
                });
            }
        }
        let tempo = hops.last().unwrap().2.tempo_bpm;
        println!(
            "  {} Hz {} BPM (tracker {tempo:.2}): frame {} | pulse peak {} | missed {}",
            c.rate,
            c.bpm,
            show(&stats(&per.frame)),
            show(&stats(&per.crossing)),
            per.missed
        );
        out.push((c, tempo, per));
    }
    out
}

/// Checks criterion 2 over `r`: every peak frame within one 60 Hz frame of its beat, mean
/// |offset| of the peak frames at most 8 ms and the sub-frame pulse-peak time's standard deviation
/// (jitter, pooled over every vector, so per-tempo bias counts too) at most 4 ms. Returns
/// whether it holds.
fn check_photon(label: &str, r: &PhotonResult) -> bool {
    let f = stats(&r.frame);
    let x = stats(&r.crossing);
    let frame = 1000.0 / 60.0;
    let within = r.frame.iter().all(|d| d.abs() <= frame);
    let ok = within && f.mean_abs <= 8.0 && x.sd <= 4.0 && r.missed == 0;
    println!(
        "criterion 2 ({label}): peak frame {} ; pulse peak {} ; missed beats {}",
        show(&f),
        show(&x),
        r.missed
    );
    println!(
        "criterion 2 ({label}): all within +/-1 frame {within}, mean |offset| {:.3} ms (<= 8), jitter {:.3} ms (<= 4) -> {}",
        f.mean_abs,
        x.sd,
        if ok { "MET" } else { "NOT MET" }
    );
    ok
}

#[test]
#[ignore = "release-profile harness; make reaction-photon runs it"]
fn beat_pulse_peaks_at_the_true_beat_with_a_known_clock() {
    let mut all = PhotonResult::default();
    for (_, _, r) in photon(true, version()) {
        all.extend(r);
    }
    assert!(check_photon("known beat clock", &all));
}

/// The tracker's own tempo errors are outside the sampler: a vector whose tracker settles off
/// the true tempo (an octave error) is reported, not asserted; the sampler criterion is checked
/// over the vectors the tracker follows.
#[test]
#[ignore = "release-profile harness; make reaction-photon runs it"]
fn beat_pulse_peaks_at_the_true_beat_from_the_tracker() {
    let v = version();
    let (mut followed, mut octave) = (PhotonResult::default(), PhotonResult::default());
    let mut errors = vec![];
    for (c, tempo, r) in photon(false, v) {
        if (tempo - c.bpm).abs() <= 0.06 * c.bpm {
            followed.extend(r);
        } else {
            errors.push(format!("{} Hz {} BPM -> {tempo:.2}", c.rate, c.bpm));
            octave.extend(r);
        }
    }
    println!("tracker tempo errors (DSP v{v}): {errors:?}");
    if !errors.is_empty() {
        check_photon(&format!("DSP v{v} tracker, tempo-error vectors"), &octave);
    }
    assert!(check_photon(
        &format!("DSP v{v} tracker, followed vectors"),
        &followed
    ));
}

#[test]
#[ignore = "release-profile harness; make reaction-photon runs it"]
fn continuous_values_are_smooth_between_hops() {
    let v = version();
    let mut worst_rate: (f64, f64) = (f64::INFINITY, 0.0);
    let mut backward = 0;
    let mut outside = 0;
    let mut frames_checked = 0;
    for c in vectors() {
        let hops = analyse(&c, v);
        for rate in [30.0, 60.0, 120.0] {
            let period = 1000.0 / rate;
            for sc in SCENARIOS {
                let cfg = config(v, c.rate, sc);
                let frames = render(&hops, sc, cfg, period, 0.37 * period, None);
                for w in frames.windows(2) {
                    let (p, q) = (&w[0].r, &w[1].r);
                    // The harness never seeks, so only the first locked frame resynchronises.
                    if p.locked == 0 || q.locked == 0 {
                        continue;
                    }
                    frames_checked += 1;
                    let mut step = q.beat_phase - p.beat_phase;
                    if step < 0.0 {
                        step += 1.0;
                        if q.beat_count != p.beat_count + 1 {
                            backward += 1;
                        }
                    }
                    let nominal = period * q.tempo_bpm / 60_000.0;
                    let ratio = step / nominal;
                    worst_rate = (worst_rate.0.min(ratio), worst_rate.1.max(ratio));
                }
                // Continuous values lie between the two hops around the target.
                let lag = cfg.analysis_latency_ms;
                for f in &frames {
                    let t = f.photon_ms;
                    let i = hops.partition_point(|h| h.0 - lag <= t);
                    if i == 0 || i >= hops.len() {
                        continue;
                    }
                    for slot in [BASS, LEVEL, AMPLITUDE] {
                        let (a, b) = (hops[i - 1].1.values[slot], hops[i].1.values[slot]);
                        let x = f.r.mapped.values[slot];
                        if x < a.min(b) - 1e-12 || x > a.max(b) + 1e-12 {
                            outside += 1;
                        }
                    }
                }
            }
        }
    }
    println!(
        "criterion 3 (DSP v{v}): {frames_checked} frame steps, beat phase step / nominal in [{:.3}, {:.3}], backward steps {backward}, continuous values outside their hops {outside}",
        worst_rate.0, worst_rate.1
    );
    assert!(
        backward == 0 && outside == 0 && worst_rate.0 >= 0.5 - 1e-9 && worst_rate.1 <= 2.0 + 1e-9
    );
}

#[test]
#[ignore = "release-profile harness; make reaction-photon runs it"]
fn analysis_latency_table_covers_the_measured_lag() {
    for row in ANALYSIS_LATENCY {
        let mut first = vec![];
        let mut peak = vec![];
        for c in vectors() {
            let hops = analyse(&c, row.behavior_version);
            for &t in &c.times_ms {
                let window: Vec<_> = hops.iter().filter(|h| h.0 >= t && h.0 < t + 60.0).collect();
                if let Some(h) = window.iter().find(|h| h.1.values[ONSET] >= 0.5) {
                    first.push((h.0 - t) * c.rate as f64 / REFERENCE_RATE_HZ);
                }
                let best = window
                    .iter()
                    .max_by(|a, b| a.1.values[ONSET].partial_cmp(&b.1.values[ONSET]).unwrap())
                    .unwrap();
                peak.push((best.0 - t) * c.rate as f64 / REFERENCE_RATE_HZ);
            }
        }
        let (f, p) = (stats(&first), stats(&peak));
        println!(
            "v{}: first hop >= 0.5 lag {} ; peak hop lag {} ; table analysis {} onset {}",
            row.behavior_version,
            show(&f),
            show(&p),
            row.analysis_ms,
            row.onset_ms
        );
        assert!(row.onset_ms >= f.max, "onset latency below the largest lag");
        assert!(
            (row.analysis_ms - p.mean).abs() <= 0.5,
            "analysis latency off the mean peak lag"
        );
    }
}
