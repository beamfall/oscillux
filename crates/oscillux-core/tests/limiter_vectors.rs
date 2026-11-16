// SPDX-License-Identifier: AGPL-3.0-only
//! Runs every case in `conformance/limiter/` against the limiter.

mod json;

use json::Value;
use oscillux_core::limiter::{analyze, Analysis, Frame, FrameError, Limiter, Policy, PolicyError};

const SEQUENCE_FILES: [&str; 3] = [
    "reference-sequences.json",
    "red-flash-and-area-sequences.json",
    "cadence-sequences.json",
];
const VALIDATION_FILES: [&str; 2] = ["reference-validation.json", "tighten-only-validation.json"];
const TIMELINE_FILES: [&str; 1] = ["timeline-sequences.json"];

fn load(name: &str) -> Value {
    let text = match name {
        "reference-sequences.json" => {
            include_str!("../../../conformance/limiter/reference-sequences.json")
        }
        "red-flash-and-area-sequences.json" => {
            include_str!("../../../conformance/limiter/red-flash-and-area-sequences.json")
        }
        "cadence-sequences.json" => {
            include_str!("../../../conformance/limiter/cadence-sequences.json")
        }
        "reference-validation.json" => {
            include_str!("../../../conformance/limiter/reference-validation.json")
        }
        "tighten-only-validation.json" => {
            include_str!("../../../conformance/limiter/tighten-only-validation.json")
        }
        "timeline-sequences.json" => {
            include_str!("../../../conformance/limiter/timeline-sequences.json")
        }
        _ => panic!("unknown fixture"),
    };
    json::parse(text).expect("parse vector file")
}

fn policy(v: &Value) -> Policy {
    Policy {
        max_flash_hz: v.get("maxFlashHz").num(),
        max_luminance_delta: v.get("maxLuminanceDelta").num(),
        max_flash_area: v.get("maxFlashArea").num(),
        max_red_flashes: v.get("maxRedFlashes").num() as u32,
        strobe_banned: v.get("strobeBanned").boolean(),
    }
}

fn frame(v: &Value) -> Frame {
    Frame {
        time_ms: v.get("timeMs").num(),
        broadband: v.get("broadband").num(),
        low: v.get("low").num(),
        mid: v.get("mid").num(),
        high: v.get("high").num(),
        red: v.get("red").num(),
        area: v.get("area").num(),
    }
}

fn frames(v: &Value) -> Vec<Frame> {
    v.arr().iter().map(frame).collect()
}

fn analysis(v: &Value) -> Analysis {
    Analysis {
        peak_flash_hz: v.get("peakFlashHz").num(),
        peak_luminance_delta: v.get("peakLuminanceDelta").num(),
        strobe_detected: v.get("strobeDetected").boolean(),
        peak_red_flashes: v.get("peakRedFlashes").num() as u32,
    }
}

fn error_code(err: PolicyError) -> String {
    match err {
        PolicyError::StrobeNotBanned => "strobe-not-banned".to_string(),
        PolicyError::NonPositive(field) => format!("non-positive:{}", field.name()),
        PolicyError::Looser(field) => format!("looser:{}", field.name()),
    }
}

/// Runs one sequence case; returns a description of the first mismatch.
fn run_sequence(case: &Value) -> Result<(), String> {
    let policy = policy(case.get("policy"));
    let input = frames(case.get("input"));
    let before = analyze(&input, &policy).map_err(|e| e.to_string())?;
    check("analysis", before, analysis(case.get("analysis")))?;
    check(
        "exceeds",
        before.exceeds(&policy),
        case.get("exceeds").boolean(),
    )?;

    let mut limiter = Limiter::new(policy).map_err(|e| e.to_string())?;
    let clamped: Vec<Frame> = input.iter().map(|f| limiter.process(*f).unwrap()).collect();
    check("clamped", &clamped, &frames(case.get("clamped")))?;

    let after = analyze(&clamped, &policy).map_err(|e| e.to_string())?;
    check(
        "clampedAnalysis",
        after,
        analysis(case.get("clampedAnalysis")),
    )?;
    check(
        "clampedExceeds",
        after.exceeds(&policy),
        case.get("clampedExceeds").boolean(),
    )
}

fn frame_error(err: FrameError) -> &'static str {
    match err {
        FrameError::NonFiniteTime => "non-finite-time",
        FrameError::DecreasingTime => "decreasing-time",
        FrameError::InvalidScalar => "invalid-scalar",
    }
}

fn field<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    match v {
        Value::Obj(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
        _ => None,
    }
}

/// Runs one timeline case: frames and resets in order; a refused frame yields the fail-safe
/// frame.
fn run_timeline(case: &Value) -> Result<(), String> {
    let mut limiter = Limiter::new(policy(case.get("policy"))).map_err(|e| e.to_string())?;
    for (i, step) in case.get("steps").arr().iter().enumerate() {
        if field(step, "reset").is_some() {
            limiter.reset();
            continue;
        }
        let input = frame(step.get("input"));
        let (output, error) = match limiter.process(input) {
            Ok(output) => (output, None),
            Err(err) => (Frame::fail_safe(input.time_ms), Some(frame_error(err))),
        };
        let want_error = field(step, "error").map(Value::str);
        check(&format!("step {i} error"), error, want_error)?;
        check(
            &format!("step {i} output"),
            output,
            frame(step.get("output")),
        )?;
    }
    Ok(())
}

fn run_validation(case: &Value) -> Result<(), String> {
    let got = policy(case.get("policy")).validate().map_err(error_code);
    let want = match case.get("valid").boolean() {
        true => Ok(()),
        false => Err(case.get("error").str().to_string()),
    };
    check("validate", got, want)
}

/// Exact comparison: the vectors' tolerance is zero.
fn check<T: PartialEq + std::fmt::Debug>(what: &str, got: T, want: T) -> Result<(), String> {
    if got == want {
        return Ok(());
    }
    Err(format!("{what}: got {got:?}, want {want:?}"))
}

fn run_files(files: &[&str], run: fn(&Value) -> Result<(), String>) -> (usize, Vec<String>) {
    let mut total = 0;
    let mut failures = Vec::new();
    for file in files {
        for case in load(file).get("cases").arr() {
            total += 1;
            if let Err(why) = run(case) {
                failures.push(format!("{file} {}: {why}", case.get("name").str()));
            }
        }
    }
    (total, failures)
}

#[test]
fn every_limiter_vector_passes() {
    let (sequences, mut failures) = run_files(&SEQUENCE_FILES, run_sequence);
    let (validations, validation_failures) = run_files(&VALIDATION_FILES, run_validation);
    failures.extend(validation_failures);
    let (timelines, timeline_failures) = run_files(&TIMELINE_FILES, run_timeline);
    failures.extend(timeline_failures);
    let total = sequences + validations + timelines;
    println!(
        "limiter vectors: {} of {total} passed \
         ({sequences} sequence, {validations} validation, {timelines} timeline)",
        total - failures.len()
    );
    assert!(
        failures.is_empty(),
        "failing vectors:\n{}",
        failures.join("\n")
    );
    assert!(total > 0, "no vectors found");
}
