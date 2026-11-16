// SPDX-License-Identifier: AGPL-3.0-only
//! Runs `conformance/limiter/overlay-sequences.json` against the flash analyzer's overlay
//! (OSC-OVERLAY), and checks that an analyzer without an overlay is unchanged by one.

mod json;

use json::Value;
use oscillux_core::limiter::{
    FlashAnalyzer, FlashConfig, FlashOverlay, FlashOverlayError, RedRule, RegionSample,
};
use oscillux_core::overlay::{OverlayError, OverlayRegion};

fn vectors() -> Value {
    json::parse(include_str!(
        "../../../conformance/limiter/overlay-sequences.json"
    ))
    .expect("parse vector file")
}

fn opt<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    let Value::Obj(fields) = v else {
        panic!("not an object looking up {key}")
    };
    fields.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

fn config(v: &Value) -> FlashConfig {
    FlashConfig {
        field_width: v.get("fieldWidth").num(),
        field_height: v.get("fieldHeight").num(),
        max_field_area: v.get("maxFieldArea").num(),
        max_flash_hz: v.get("maxFlashHz").num(),
        columns: v.get("columns").num() as u32,
        rows: v.get("rows").num() as u32,
        max_red_flashes: v.get("maxRedFlashes").num() as u32,
        red_rule: RedRule::from_u32(v.get("redRule").num() as u32).unwrap(),
    }
}

fn overlay(v: &Value) -> FlashOverlay {
    FlashOverlay {
        luminance_change: v.get("luminanceChange").num(),
        darker_limit: v.get("darkerLimit").num(),
        max_flash_hz: v.get("maxFlashHz").num(),
        max_area: v.get("maxArea").num(),
    }
}

fn regions(v: &Value) -> Vec<OverlayRegion> {
    v.arr()
        .iter()
        .map(|r| OverlayRegion {
            x: r.get("x").num(),
            y: r.get("y").num(),
            width: r.get("width").num(),
            height: r.get("height").num(),
            corner_radius: r.get("corner_radius").num(),
            feather: r.get("feather").num(),
            strength: r.get("strength").num(),
            mode: r.get("mode").num() as u32,
            reserved: r.get("reserved").num() as u32,
        })
        .collect()
}

fn samples(frame: &Value, n: usize) -> Vec<RegionSample> {
    let sample = |luminance| RegionSample {
        luminance,
        red: 0.0,
    };
    match frame.get("luminance") {
        Value::Arr(items) => items.iter().map(|v| sample(v.num())).collect(),
        v => vec![sample(v.num()); n],
    }
}

#[test]
fn sequences_match_the_vectors() {
    let doc = vectors();
    let mut frames_checked = 0;
    for seq in doc.get("sequences").arr() {
        let name = seq.get("name").str();
        let cfg = config(seq.get("config"));
        let n = (cfg.columns * cfg.rows) as usize;
        let admit = seq.get("mode").str() == "admit";
        let mut analyzer = FlashAnalyzer::new(cfg).unwrap();
        let mut plain = FlashAnalyzer::new(cfg).unwrap();
        for (frame, want) in seq
            .get("frames")
            .arr()
            .iter()
            .zip(seq.get("expected").arr())
        {
            if let Some(set) = opt(frame, "setOverlay") {
                analyzer
                    .set_overlay(&overlay(set.get("overlay")), &regions(set.get("regions")))
                    .unwrap();
            }
            if opt(frame, "clearOverlay").is_some_and(Value::boolean) {
                analyzer.clear_overlay();
            }
            if opt(frame, "reset").is_some_and(Value::boolean) {
                analyzer.reset();
                plain.reset();
            }
            let t = frame.get("t").num();
            let s = samples(frame, n);
            let report = if admit {
                analyzer.admit(t, &s).unwrap()
            } else {
                analyzer.measure(t, &s).unwrap()
            };
            let at = format!("{name} t={t}");
            assert_eq!(report.time_ms, want.get("t").num(), "{at}");
            assert_eq!(report.admitted, want.get("admitted").boolean(), "{at}");
            assert_eq!(
                report.general_transition,
                want.get("general").boolean(),
                "{at}"
            );
            let regions_flagged = want.get("generalRegions").num() as u32;
            assert_eq!(report.general_regions, regions_flagged, "{at}");
            assert_eq!(report.flashes_in_window, want.get("flashes").num(), "{at}");
            assert_eq!(report.exceeds, want.get("exceeds").boolean(), "{at}");
            let o = analyzer.overlay_report();
            let wo = want.get("overlay");
            assert_eq!(o.active, wo.get("active").boolean(), "{at}");
            assert_eq!(o.transition, wo.get("transition").boolean(), "{at}");
            assert_eq!(o.regions, wo.get("regions").num() as u32, "{at}");
            assert_eq!(o.cells, wo.get("cells").num() as u32, "{at}");
            assert_eq!(o.flashes_in_window, wo.get("flashes").num(), "{at}");
            assert_eq!(o.exceeds, wo.get("exceeds").boolean(), "{at}");
            if !admit {
                // Measuring never depends on the overlay.
                let base = plain.measure(t, &s).unwrap();
                assert_eq!(base, report, "{at}: overlay changed the base report");
            }
            frames_checked += 1;
        }
    }
    assert!(frames_checked > 500);
}

#[test]
fn refusals_match_the_vectors() {
    let doc = vectors();
    let cfg = FlashConfig {
        columns: 6,
        rows: 6,
        ..FlashConfig::DEFAULT
    };
    for case in doc.get("refusals").arr() {
        let name = case.get("name").str();
        let mut analyzer = FlashAnalyzer::new(cfg).unwrap();
        let err = analyzer
            .set_overlay(&overlay(case.get("overlay")), &regions(case.get("regions")))
            .unwrap_err();
        let got = match err {
            FlashOverlayError::Regions(e) => format!("{e:?}"),
            e => format!("{e:?}"),
        };
        assert_eq!(got, case.get("refused").str(), "{name}");
        assert!(!analyzer.overlay_report().active, "{name}");
    }
    // A tightened config bounds the overlay too.
    let tight = FlashConfig {
        max_flash_hz: 0.5,
        ..cfg
    };
    let mut analyzer = FlashAnalyzer::new(tight).unwrap();
    assert_eq!(
        analyzer.set_overlay(&FlashOverlay::DEFAULT, &[]),
        Err(FlashOverlayError::MaxFlashHz)
    );
    let mut analyzer = FlashAnalyzer::new(cfg).unwrap();
    let bad = OverlayRegion {
        width: -1.0,
        ..OverlayRegion::default()
    };
    assert_eq!(
        analyzer.set_overlay(&FlashOverlay::DEFAULT, &[bad]),
        Err(FlashOverlayError::Regions(OverlayError::RegionRect))
    );
}
