// SPDX-License-Identifier: AGPL-3.0-only
//! The transition scheduler against `conformance/transition/reference.json`, written by the
//! standard-library model `tools/transition-vectors.py`; every value must match exactly.
#[allow(dead_code)]
mod json;
use json::Value;
use oscillux_core::transition::*;

fn num(v: &Value) -> f64 {
    match v {
        Value::Str(s) => match s.as_str() {
            "NaN" => f64::NAN,
            "Infinity" => f64::INFINITY,
            "-Infinity" => f64::NEG_INFINITY,
            other => panic!("number {other}"),
        },
        v => v.num(),
    }
}

fn field<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    match v {
        Value::Obj(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
        _ => None,
    }
}

fn config(v: &Value) -> TransitionConfig {
    TransitionConfig {
        easing: num(v.get("easing")) as u32,
        beats_per_bar: num(v.get("beats_per_bar")) as u32,
        auto_advance_bars: num(v.get("auto_advance_bars")) as u32,
        duration_beats: num(v.get("duration_beats")),
        fallback_seconds: num(v.get("fallback_seconds")),
        pre_roll_seconds: num(v.get("pre_roll_seconds")),
        min_confidence: num(v.get("min_confidence")),
    }
}

fn clock(v: &Value) -> TransitionClock {
    let f: Vec<f64> = v.arr().iter().map(num).collect();
    TransitionClock {
        time_seconds: f[0],
        beat_phase: f[1],
        bar_phase: f[2],
        tempo_bpm: f[3],
        confidence: f[4],
    }
}

fn check(name: &str, step: usize, got: Result<TransitionStatus, TransitionError>, want: &Value) {
    match (got, want) {
        (Err(_), Value::Str(s)) if s == "refused" => {}
        (Ok(st), Value::Arr(w)) => {
            let w: Vec<f64> = w.iter().map(num).collect();
            let g = [
                st.progress,
                st.request_seconds,
                st.start_seconds,
                st.end_seconds,
                f64::from(st.state),
                f64::from(st.quantise),
                f64::from(st.auto_requested),
            ];
            for (i, (g, w)) in g.iter().zip(&w).enumerate() {
                assert!(
                    g.to_bits() == w.to_bits(),
                    "{name} step {step} field {i}: got {g:?}, want {w:?}"
                );
            }
            assert_eq!(st.reserved, 0);
        }
        (got, want) => panic!("{name} step {step}: got {got:?}, want {want:?}"),
    }
}

#[test]
fn scheduler_matches_the_oracle_exactly() {
    let doc = json::parse(include_str!(
        "../../../conformance/transition/reference.json"
    ))
    .unwrap();
    assert_eq!(doc.get("tolerance").num(), 0.0);
    let mut steps_checked = 0;
    let cases = doc.get("cases").arr();
    for case in cases {
        let name = case.get("name").str();
        let made = TransitionScheduler::new(config(case.get("config")));
        if field(case, "create").is_some() {
            assert!(made.is_err(), "{name} must be refused");
            continue;
        }
        let mut s = made.unwrap_or_else(|_| panic!("{name} must be valid"));
        for (i, step) in case.get("steps").arr().iter().enumerate() {
            let want = field(step, "want").unwrap_or(&Value::Null);
            match step.get("op").str() {
                "request" => {
                    let got = s.request(
                        &clock(step.get("clock")),
                        num(step.get("quantise")) as u32,
                        num(step.get("max_wait")),
                    );
                    check(name, i, got, want);
                }
                "update" => check(name, i, s.update(&clock(step.get("clock"))), want),
                "status" => check(name, i, Ok(s.status(num(step.get("time")))), want),
                "reset" => s.reset(),
                op => panic!("{name}: op {op}"),
            }
            steps_checked += 1;
        }
    }
    assert!(cases.len() >= 27 && steps_checked > 1500, "{steps_checked}");
}

/// A host loop at `hz` from `t0`: request on the first frame, then one update per frame.
/// Returns the schedule, the time of the first blended frame, the time of the first DONE frame
/// and every blended p in order (DONE frame included).
fn host_loop(
    hz: f64,
    t0: f64,
    clock_at: &dyn Fn(f64) -> TransitionClock,
) -> (TransitionStatus, f64, f64, Vec<f64>) {
    let mut s = TransitionScheduler::new(TransitionConfig::default()).unwrap();
    let schedule = s.request(&clock_at(t0), QUANTISE_BAR, 2.0).unwrap();
    let mut first = None;
    let mut blended = Vec::new();
    for n in 1.. {
        let t = t0 + f64::from(n) / hz;
        let st = s.update(&clock_at(t)).unwrap();
        if st.state == STATE_BLENDING || st.state == STATE_DONE {
            first.get_or_insert(t);
            blended.push(st.progress);
        }
        if st.state == STATE_DONE {
            return (schedule, first.unwrap(), t, blended);
        }
    }
    unreachable!()
}

#[test]
fn switch_wall_time_is_independent_of_frame_rate() {
    let no_beat = |t: f64| TransitionClock {
        time_seconds: t,
        ..TransitionClock::default()
    };
    let beat = |t: f64| {
        let beats = t * 2.0;
        TransitionClock {
            time_seconds: t,
            beat_phase: beats - beats.floor(),
            bar_phase: beats / 4.0 - (beats / 4.0).floor(),
            tempo_bpm: 120.0,
            confidence: 0.9,
        }
    };
    for clock_at in [&no_beat as &dyn Fn(f64) -> TransitionClock, &beat] {
        for hz in [30.0, 60.0, 120.0] {
            let (st, first, done, blended) = host_loop(hz, 7.3, clock_at);
            let frame = 1.0 / hz;
            // The blend is seen from the frame at its start and ends on the frame at its end,
            // so the wall time equals the scheduled duration within one frame.
            assert!(first >= st.start_seconds && first - st.start_seconds < frame + 1e-9);
            assert!(done >= st.end_seconds && done - st.end_seconds < frame + 1e-9);
            let wall = done - first;
            assert!(
                (wall - (st.end_seconds - st.start_seconds)).abs() <= frame + 1e-9,
                "{hz}"
            );
            // The last blended frame shows p = 1 exactly, and nothing before it does.
            assert_eq!(*blended.last().unwrap(), 1.0);
            assert!(blended[..blended.len() - 1].iter().all(|p| *p < 1.0));
            assert!(blended.windows(2).all(|w| w[0] <= w[1]));
        }
    }
}
