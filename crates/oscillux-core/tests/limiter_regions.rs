// SPDX-License-Identifier: AGPL-3.0-only
//! Runs `conformance/limiter/region-sequences.json` against the region flash analyzer, and
//! checks that admitted output re-measured never exceeds its config.

mod json;

use json::Value;
use oscillux_core::limiter::{
    FlashAnalyzer, FlashConfig, FlashConfigError, FlashReport, RedRule, RegionColor, RegionError,
    RegionSample,
};

fn vectors() -> Value {
    json::parse(include_str!(
        "../../../conformance/limiter/region-sequences.json"
    ))
    .expect("parse vector file")
}

fn opt<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    let Value::Obj(fields) = v else {
        panic!("not an object looking up {key}")
    };
    fields.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// The vector's config, or the error naming its red rule refuses.
fn config(v: &Value) -> Result<FlashConfig, FlashConfigError> {
    Ok(FlashConfig {
        field_width: v.get("fieldWidth").num(),
        field_height: v.get("fieldHeight").num(),
        max_field_area: v.get("maxFieldArea").num(),
        max_flash_hz: v.get("maxFlashHz").num(),
        columns: v.get("columns").num() as u32,
        rows: v.get("rows").num() as u32,
        max_red_flashes: v.get("maxRedFlashes").num() as u32,
        red_rule: RedRule::from_u32(v.get("redRule").num() as u32)?,
    })
}

/// One value for every region, or a row-major array.
fn levels(frame: &Value, key: &str, n: usize) -> Vec<f64> {
    match opt(frame, key) {
        None => vec![0.0; n],
        Some(Value::Arr(items)) => items.iter().map(Value::num).collect(),
        Some(v) => vec![v.num(); n],
    }
}

fn regions(frame: &Value, n: usize) -> Vec<RegionSample> {
    let luminance = levels(frame, "luminance", n);
    let red = levels(frame, "red", n);
    assert_eq!((luminance.len(), red.len()), (n, n));
    luminance
        .into_iter()
        .zip(red)
        .map(|(luminance, red)| RegionSample { luminance, red })
        .collect()
}

/// One `[r, g, b]` for every region, or a row-major array of them; None for a sample frame.
fn colors(frame: &Value, n: usize) -> Option<Vec<RegionColor>> {
    let rgb = opt(frame, "rgb")?.arr();
    let color = |v: &Value| {
        let c: Vec<f64> = v.arr().iter().map(Value::num).collect();
        RegionColor {
            r: c[0],
            g: c[1],
            b: c[2],
        }
    };
    Some(match rgb[0] {
        Value::Arr(_) => rgb.iter().map(color).collect(),
        _ => vec![color(opt(frame, "rgb").unwrap()); n],
    })
}

fn report(v: &Value) -> FlashReport {
    FlashReport {
        time_ms: v.get("t").num(),
        admitted: v.get("admitted").boolean(),
        general_transition: v.get("general").boolean(),
        red_transition: v.get("red").boolean(),
        general_regions: v.get("generalRegions").num() as u32,
        red_regions: v.get("redRegions").num() as u32,
        flashes_in_window: v.get("flashes").num(),
        red_flashes_in_window: v.get("redFlashes").num(),
        exceeds: v.get("exceeds").boolean(),
    }
}

#[test]
fn sequence_vectors_match_exactly() {
    let doc = vectors();
    assert_eq!(doc.get("tolerance").num(), 0.0);
    let cases = doc.get("cases").arr();
    assert_eq!(cases.len(), 27);
    for case in cases {
        let name = case.get("name").str();
        let config = config(case.get("config")).expect(name);
        let n = (config.columns * config.rows) as usize;
        let admit = match case.get("mode").str() {
            "admit" => true,
            "measure" => false,
            other => panic!("{name}: unknown mode {other}"),
        };
        let mut analyzer = FlashAnalyzer::new(config).expect(name);
        let frames = case.get("frames").arr();
        let expected = case.get("expected").arr();
        assert_eq!(frames.len(), expected.len(), "{name}");
        for (i, (frame, want)) in frames.iter().zip(expected).enumerate() {
            if opt(frame, "reset").is_some_and(Value::boolean) {
                analyzer.reset();
            }
            let time = frame.get("t").num();
            let got = match (colors(frame, n), admit) {
                (Some(colors), true) => analyzer.admit_rgb(time, &colors),
                (Some(colors), false) => analyzer.measure_rgb(time, &colors),
                (None, true) => analyzer.admit(time, &regions(frame, n)),
                (None, false) => analyzer.measure(time, &regions(frame, n)),
            };
            assert_eq!(got, Ok(report(want)), "{name} frame {i}");
        }
    }
}

#[test]
fn color_vectors_match_exactly() {
    let doc = vectors();
    for color in doc.get("colors").arr() {
        let rgb: Vec<f64> = color.get("rgb").arr().iter().map(Value::num).collect();
        let want = RegionSample {
            luminance: color.get("luminance").num(),
            red: color.get("red").num(),
        };
        assert_eq!(
            RegionSample::from_linear_rgb(rgb[0], rgb[1], rgb[2]),
            Ok(want),
            "{rgb:?}"
        );
    }
    for color in doc.get("invalidColors").arr() {
        let rgb: Vec<f64> = color.arr().iter().map(Value::num).collect();
        assert_eq!(
            RegionSample::from_linear_rgb(rgb[0], rgb[1], rgb[2]),
            Err(RegionError::InvalidSample)
        );
    }
    for bad in [f64::NAN, f64::INFINITY] {
        assert!(RegionSample::from_linear_rgb(bad, 0.0, 0.0).is_err());
    }
}

#[test]
fn validation_vectors_match() {
    for case in vectors().get("validation").arr() {
        let want = match case.get("error") {
            Value::Null => Ok(()),
            v => Err(match v.str() {
                "grid" => FlashConfigError::Grid,
                "field" => FlashConfigError::Field,
                "field-area" => FlashConfigError::FieldArea,
                "flash-hz" => FlashConfigError::FlashHz,
                "red-flashes" => FlashConfigError::RedFlashes,
                "red-rule" => FlashConfigError::RedRule,
                other => panic!("unknown error {other}"),
            }),
        };
        let name = case.get("name").str();
        let config = match config(case.get("config")) {
            Ok(config) => config,
            Err(error) => {
                assert_eq!(Err(error), want, "{name}");
                continue;
            }
        };
        assert_eq!(config.validate(), want, "{name}");
        assert_eq!(FlashAnalyzer::new(config).err(), want.err());
    }
    for nan in [
        FlashConfig {
            field_width: f64::NAN,
            ..FlashConfig::DEFAULT
        },
        FlashConfig {
            max_field_area: f64::NAN,
            ..FlashConfig::DEFAULT
        },
        FlashConfig {
            max_flash_hz: f64::NAN,
            ..FlashConfig::DEFAULT
        },
    ] {
        assert!(nan.validate().is_err());
    }
}

fn uniform(n: usize, luminance: f64) -> Vec<RegionSample> {
    vec![
        RegionSample {
            luminance,
            red: 0.0
        };
        n
    ]
}

#[test]
fn invalid_frames_leave_state_unchanged() {
    let config = FlashConfig {
        columns: 2,
        rows: 2,
        ..FlashConfig::DEFAULT
    };
    let mut analyzer = FlashAnalyzer::new(config).unwrap();
    analyzer.measure(0.0, &uniform(4, 0.0)).unwrap();
    let before = format!("{analyzer:?}");
    let bad_sample = [RegionSample {
        luminance: 1.5,
        red: 0.0,
    }; 4];
    assert_eq!(
        analyzer.measure(10.0, &uniform(3, 1.0)),
        Err(RegionError::RegionCount)
    );
    assert_eq!(
        analyzer.admit(10.0, &bad_sample),
        Err(RegionError::InvalidSample)
    );
    assert_eq!(
        analyzer.measure(f64::NAN, &uniform(4, 1.0)),
        Err(RegionError::NonFiniteTime)
    );
    assert_eq!(
        analyzer.measure(-1.0, &uniform(4, 1.0)),
        Err(RegionError::DecreasingTime)
    );
    assert_eq!(format!("{analyzer:?}"), before);
    analyzer.reset();
    let report = analyzer.measure(-1.0, &uniform(4, 1.0)).unwrap();
    assert!(report.general_transition);
}

/// Fixed-seed xorshift, so the property runs are reproducible on every target.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    /// A level on a 1/16 grid, so changes land on and around every threshold.
    fn level(&mut self) -> f64 {
        self.below(17) as f64 / 16.0
    }
}

#[test]
fn admitted_images_remeasured_never_exceed() {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    let (mut refused, mut transitions) = (0, 0);
    for run in 0..200 {
        let config = FlashConfig {
            columns: 1 + rng.below(8) as u32,
            rows: 1 + rng.below(8) as u32,
            field_width: (1 + rng.below(4)) as f64 / 4.0,
            field_height: (1 + rng.below(4)) as f64 / 4.0,
            max_field_area: [0.25, 0.125, 0.0625][rng.below(3) as usize],
            max_flash_hz: [3.0, 2.5, 1.0, 0.5][rng.below(4) as usize],
            max_red_flashes: rng.below(4) as u32,
            red_rule: RedRule::Wcag20,
        };
        let n = (config.columns * config.rows) as usize;
        let mut admit = FlashAnalyzer::new(config).unwrap();
        let mut remeasure = FlashAnalyzer::new(config).unwrap();
        let mut shown = vec![RegionSample::default(); n];
        let mut time = 0.0;
        for frame in 0..400 {
            time += [4.0, 8.25, 16.75, 33.25, 100.0, 300.0][rng.below(6) as usize];
            let reset = rng.below(50) == 0;
            let mut samples = shown.clone();
            for sample in &mut samples {
                if rng.below(3) == 0 {
                    sample.luminance = rng.level();
                    sample.red = if rng.below(2) == 0 { rng.level() } else { 0.0 };
                }
            }
            if reset {
                admit.reset();
                remeasure.reset();
            }
            let got = admit.admit(time, &samples).unwrap();
            if got.admitted {
                shown = samples;
            } else {
                refused += 1;
            }
            transitions += u32::from(got.admitted && got.general_transition);
            let check = remeasure.measure(time, &shown).unwrap();
            assert!(!got.exceeds && !check.exceeds, "run {run} frame {frame}");
            assert_eq!(
                (check.flashes_in_window, check.red_flashes_in_window),
                (got.flashes_in_window, got.red_flashes_in_window),
                "run {run} frame {frame}"
            );
        }
    }
    // The runs must exercise both admission and refusal.
    assert!(
        refused > 1000 && transitions > 1000,
        "{refused} {transitions}"
    );
}

fn grey(n: usize, level: f64) -> Vec<RegionColor> {
    vec![
        RegionColor {
            r: level,
            g: level,
            b: level
        };
        n
    ]
}

#[test]
fn iso_rule_needs_colors_and_refuses_samples_unchanged() {
    let config = FlashConfig {
        columns: 2,
        rows: 2,
        red_rule: RedRule::Iso9241_391,
        ..FlashConfig::DEFAULT
    };
    let mut analyzer = FlashAnalyzer::new(config).unwrap();
    assert_eq!(
        analyzer.measure(0.0, &uniform(4, 0.0)),
        Err(RegionError::ColorRequired)
    );
    analyzer.measure_rgb(0.0, &grey(4, 0.0)).unwrap();
    let before = format!("{analyzer:?}");
    assert_eq!(
        analyzer.admit(10.0, &uniform(4, 1.0)),
        Err(RegionError::ColorRequired)
    );
    assert_eq!(
        analyzer.measure_rgb(10.0, &grey(4, 1.5)),
        Err(RegionError::InvalidSample)
    );
    assert_eq!(
        analyzer.measure_rgb(10.0, &grey(3, 1.0)),
        Err(RegionError::RegionCount)
    );
    assert_eq!(format!("{analyzer:?}"), before);
    assert_eq!(RedRule::from_u32(2), Err(FlashConfigError::RedRule));
    assert_eq!(RedRule::from_u32(1), Ok(RedRule::Iso9241_391));
    assert_eq!(FlashConfig::default().red_rule, RedRule::Wcag20);
}

/// A random linear color on a 1/16 grid, often a saturated red.
fn color(rng: &mut Rng) -> RegionColor {
    let r = rng.level();
    let (g, b) = if rng.below(2) == 0 {
        (0.0, rng.below(3) as f64 / 16.0)
    } else {
        (rng.level(), rng.level())
    };
    RegionColor { r, g, b }
}

#[test]
fn rgb_path_matches_samples_under_wcag20_and_iso_admits_never_exceed() {
    let mut rng = Rng(0x2545_f491_4f6c_dd1d);
    let (mut refused, mut red) = (0, 0);
    for run in 0..100 {
        let base = FlashConfig {
            columns: 1 + rng.below(6) as u32,
            rows: 1 + rng.below(6) as u32,
            max_red_flashes: rng.below(4) as u32,
            ..FlashConfig::DEFAULT
        };
        let iso = FlashConfig {
            red_rule: RedRule::Iso9241_391,
            ..base
        };
        let n = (base.columns * base.rows) as usize;
        let (mut by_rgb, mut by_sample) = (
            FlashAnalyzer::new(base).unwrap(),
            FlashAnalyzer::new(base).unwrap(),
        );
        let (mut admit, mut remeasure) = (
            FlashAnalyzer::new(iso).unwrap(),
            FlashAnalyzer::new(iso).unwrap(),
        );
        let mut colors = vec![RegionColor::default(); n];
        let mut shown = colors.clone();
        let mut time = 0.0;
        for frame in 0..200 {
            time += [16.75, 33.25, 100.0][rng.below(3) as usize];
            for c in &mut colors {
                if rng.below(2) == 0 {
                    *c = color(&mut rng);
                }
            }
            let samples: Vec<RegionSample> = colors
                .iter()
                .map(|c| RegionSample::from_linear_rgb(c.r, c.g, c.b).unwrap())
                .collect();
            assert_eq!(
                by_rgb.admit_rgb(time, &colors),
                by_sample.admit(time, &samples),
                "run {run} frame {frame}"
            );
            let got = admit.admit_rgb(time, &colors).unwrap();
            if got.admitted {
                shown.clone_from(&colors);
            } else {
                refused += 1;
            }
            red += u32::from(got.admitted && got.red_transition);
            let check = remeasure.measure_rgb(time, &shown).unwrap();
            assert!(!got.exceeds && !check.exceeds, "run {run} frame {frame}");
            assert_eq!(
                check.red_flashes_in_window, got.red_flashes_in_window,
                "run {run} frame {frame}"
            );
        }
    }
    assert!(refused > 500 && red > 500, "{refused} {red}");
}
