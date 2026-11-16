// SPDX-License-Identifier: AGPL-3.0-only
//! Replays `conformance/reaction/vectors.json`, written by the independent model
//! `tools/reaction-vectors.py` from `conformance/reaction/README.md`, against the sampler.

mod json;

use json::Value;
use oscillux_core::dsp::Beat;
use oscillux_core::mapping::{Mapped, SPECTRUM_BINS};
use oscillux_core::reaction::*;

const VECTORS: &str = include_str!("../../../conformance/reaction/vectors.json");

fn doc() -> Value {
    json::parse(VECTORS).expect("parse conformance/reaction/vectors.json")
}

fn opt<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    let Value::Obj(fields) = v else {
        panic!("not an object looking up {key}")
    };
    fields
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v)
        .filter(|v| !matches!(v, Value::Null))
}

/// A number, or one of the README's strings for a non-finite value.
fn num(v: &Value) -> f64 {
    match v {
        Value::Str(s) => match s.as_str() {
            "NaN" => f64::NAN,
            "Infinity" => f64::INFINITY,
            "-Infinity" => f64::NEG_INFINITY,
            other => panic!("unknown number string {other}"),
        },
        _ => v.num(),
    }
}

fn int(v: &Value) -> i64 {
    let n = v.num();
    assert_eq!(n, n.trunc(), "not an integer: {n}");
    n as i64
}

fn config(v: &Value) -> ReactionConfig {
    let f = |k: &str| num(v.get(k));
    ReactionConfig {
        struct_size: int(v.get("struct_size")) as u32,
        capacity: int(v.get("capacity")) as u32,
        output_latency_ms: f("output_latency_ms"),
        display_latency_ms: f("display_latency_ms"),
        render_ahead_ms: f("render_ahead_ms"),
        analysis_latency_ms: f("analysis_latency_ms"),
        onset_latency_ms: f("onset_latency_ms"),
        onset_release_ms: f("onset_release_ms"),
        bass_impact_release_ms: f("bass_impact_release_ms"),
        flux_release_ms: f("flux_release_ms"),
        pulse_decay_ms: f("pulse_decay_ms"),
        pulse_rise_ms: f("pulse_rise_ms"),
        phase_lock_gain: f("phase_lock_gain"),
    }
}

fn result(r: Result<(), ReactionError>) -> &'static str {
    match r {
        Ok(()) => "ok",
        Err(ReactionError::Full) => "full",
        Err(ReactionError::InvalidInput) => "invalid",
        Err(ReactionError::InvalidConfig) => "invalid-config",
    }
}

fn close(what: &str, got: f64, want: f64, tolerance: f64) {
    assert!(
        (got - want).abs() <= tolerance,
        "{what}: got {got:?}, want {want:?}"
    );
}

#[test]
fn for_dsp_rows() {
    let doc = doc();
    for row in doc.get("for_dsp").arr() {
        let version = int(row.get("behavior_version")) as u32;
        let rate = int(row.get("sample_rate_hz")) as u32;
        let got = ReactionConfig::for_dsp(version, rate);
        match opt(row, "latency") {
            None => assert!(got.is_none(), "v{version} {rate} Hz"),
            Some(l) => {
                let got = got.unwrap_or_else(|| panic!("v{version} {rate} Hz"));
                // Exact: both sides multiply the table by 48000 / rate.
                assert_eq!(got.analysis_latency_ms, num(l.get("analysis_latency_ms")));
                assert_eq!(got.onset_latency_ms, num(l.get("onset_latency_ms")));
                assert_eq!(
                    got,
                    ReactionConfig {
                        analysis_latency_ms: got.analysis_latency_ms,
                        onset_latency_ms: got.onset_latency_ms,
                        ..ReactionConfig::default()
                    }
                );
            }
        }
    }
}

#[test]
fn config_validity() {
    let doc = doc();
    for case in doc.get("configs").arr() {
        let name = case.get("name").str();
        let c = config(case.get("config"));
        let valid = case.get("valid").boolean();
        assert_eq!(c.validate().is_ok(), valid, "{name}");
        assert_eq!(ReactionSampler::new(c).is_ok(), valid, "{name}");
        if name == "default" {
            assert_eq!(c, ReactionConfig::default());
        }
    }
}

#[test]
fn scenarios() {
    let doc = doc();
    let tolerance = doc.get("tolerance").num();
    let mut samples = 0;
    for scenario in doc.get("scenarios").arr() {
        let name = scenario.get("name").str();
        let mut s = ReactionSampler::new(config(scenario.get("config"))).unwrap();
        for (n, step) in scenario.get("steps").arr().iter().enumerate() {
            let at = format!("{name} step {n}");
            match step.get("op").str() {
                "push" => {
                    let mut m = Mapped::ZERO;
                    for (slot, v) in step.get("values").arr().iter().enumerate() {
                        m.values[slot] = num(v);
                    }
                    if let Some(bins) = opt(step, "spectrum") {
                        for (i, v) in bins.arr().iter().enumerate() {
                            m.spectrum[i] = num(v) as f32;
                        }
                    }
                    let beat = opt(step, "beat").map(|b| Beat {
                        tempo_bpm: num(b.get("tempo_bpm")),
                        beat_phase: num(b.get("beat_phase")),
                        bar_phase: num(b.get("bar_phase")),
                        confidence: num(b.get("confidence")),
                        beat_in_bar: int(b.get("beat_in_bar")) as u32,
                        ..Beat::ZERO
                    });
                    let got = result(s.push(num(step.get("t")), &m, beat.as_ref()));
                    assert_eq!(got, step.get("expect").str(), "{at}");
                }
                "clock" => {
                    let clock = opt(step, "clock").map(|c| BeatClock {
                        media_time_ms: num(c.get("media_time_ms")),
                        tempo_bpm: num(c.get("tempo_bpm")),
                        beat_phase: num(c.get("beat_phase")),
                        bar_phase: num(c.get("bar_phase")),
                        beat_index: int(c.get("beat_index")),
                        beats_per_bar: int(c.get("beats_per_bar")) as u32,
                        reserved: int(c.get("reserved")) as u32,
                    });
                    let got = result(s.set_beat_clock(clock.as_ref()));
                    assert_eq!(got, step.get("expect").str(), "{at}");
                }
                "reset" => s.reset(),
                "sample" => {
                    let got = s.sample(num(step.get("t")));
                    let expect = step.get("expect");
                    if let Value::Str(e) = expect {
                        assert_eq!(e, "invalid", "{at}");
                        assert_eq!(got, Err(ReactionError::InvalidInput), "{at}");
                        continue;
                    }
                    let r = got.unwrap_or_else(|e| panic!("{at}: {e:?}"));
                    samples += 1;
                    for (slot, v) in expect.get("values").arr().iter().enumerate() {
                        close(
                            &format!("{at} value {slot}"),
                            r.mapped.values[slot],
                            num(v),
                            tolerance,
                        );
                    }
                    match opt(expect, "spectrum") {
                        Some(bins) => {
                            for (i, v) in bins.arr().iter().enumerate() {
                                let want = num(v) as f32;
                                assert_eq!(r.mapped.spectrum[i], want, "{at} bin {i}");
                            }
                        }
                        // Scenarios without spectra push zero bins.
                        None => assert_eq!(r.mapped.spectrum, [0.0; SPECTRUM_BINS], "{at}"),
                    }
                    for (key, got) in [
                        ("beat", r.beat),
                        ("downbeat", r.downbeat),
                        ("beat_phase", r.beat_phase),
                        ("bar_phase", r.bar_phase),
                        ("tempo_bpm", r.tempo_bpm),
                        ("confidence", r.confidence),
                    ] {
                        close(&format!("{at} {key}"), got, num(expect.get(key)), tolerance);
                    }
                    assert_eq!(
                        r.beat_count,
                        int(expect.get("beat_count")),
                        "{at} beat_count"
                    );
                    assert_eq!(
                        r.beat_in_bar as i64,
                        int(expect.get("beat_in_bar")),
                        "{at} beat_in_bar"
                    );
                    assert_eq!(r.locked as i64, int(expect.get("locked")), "{at} locked");
                    assert_eq!(s.queued() as i64, int(expect.get("queued")), "{at} queued");
                }
                other => panic!("{at}: unknown op {other}"),
            }
        }
    }
    assert!(samples > 700, "{samples} samples");
}
