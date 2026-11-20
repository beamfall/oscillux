// SPDX-License-Identifier: AGPL-3.0-only
//! Frame-window decisions and streaks must match the reference vectors exactly.
#[allow(dead_code)]
mod json;

use json::Value;
use oscillux_core::window_governor::{
    WindowDecision, WindowGovernor, WindowGovernorConfig, WindowResult, WindowSample,
};

fn config(value: &Value) -> WindowGovernorConfig {
    if matches!(value, Value::Null) {
        return WindowGovernorConfig::default();
    }
    WindowGovernorConfig {
        demote_budget_fraction: value.get("demote_budget_fraction").num(),
        promote_budget_fraction: value.get("promote_budget_fraction").num(),
        demote_windows: value.get("demote_windows").num() as u32,
        promote_windows: value.get("promote_windows").num() as u32,
        cooldown_s: value.get("cooldown_s").num(),
    }
}

fn percentile(value: &Value) -> Option<f64> {
    (!matches!(value, Value::Null)).then(|| value.num())
}

#[test]
fn window_governor_replays_reference_vectors() {
    let doc = json::parse(include_str!(
        "../../../conformance/window-governor/reference.json"
    ))
    .unwrap();
    assert_eq!(
        doc.get("format").str(),
        "oscillux-window-governor-vectors/1"
    );
    for case in doc.get("cases").arr() {
        let name = case.get("name").str();
        let mut governor =
            WindowGovernor::new(config(case.get("config")), case.get("start_s").num()).unwrap();
        for (index, step) in case.get("steps").arr().iter().enumerate() {
            let Value::Obj(fields) = step else {
                panic!("{name} step {index}: expected an object");
            };
            if let Some((_, time)) = fields.iter().find(|(key, _)| key == "reset_s") {
                governor.reset(time.num()).unwrap();
                continue;
            }
            let sample = step.get("sample").arr();
            let result = governor
                .record(WindowSample {
                    p95_ms: percentile(&sample[0]),
                    p99_ms: percentile(&sample[1]),
                    interval_ms: sample[2].num(),
                    promotion_budget_ms: sample[3].num(),
                    starved: sample[4].boolean(),
                    dropping: sample[5].boolean(),
                    now_s: sample[6].num(),
                    can_demote: sample[7].boolean(),
                })
                .unwrap_or_else(|_| panic!("{name} step {index}: sample refused"));
            let want = step.get("want").arr();
            assert_eq!(
                result,
                WindowResult {
                    decision: match want[0].str() {
                        "hold" => WindowDecision::Hold,
                        "demote" => WindowDecision::Demote,
                        "promote" => WindowDecision::Promote,
                        other => panic!("{name} step {index}: unknown decision {other}"),
                    },
                    over_budget: want[1].boolean(),
                    over_budget_streak: want[2].num() as u32,
                    promotion_streak: want[3].num() as u32,
                    stable_streak: want[4].num() as u32,
                },
                "{name} step {index}"
            );
        }
    }
}
