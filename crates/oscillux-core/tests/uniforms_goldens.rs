// SPDX-License-Identifier: AGPL-3.0-only
//! Runs the vendored AudioFrame v1 goldens in `conformance/uniforms/inputs/` through the Rust
//! mapper at dt = 1/60 s and checks `conformance/uniforms/*.uniforms.golden.json`, which the
//! independent model `tools/uniforms-vectors.py` wrote (docs/visual-uniforms.md).

mod json;

use json::Value;
use oscillux_core::dsp::{DspFrame, FLAG_GAP, FLAG_STALLED};
use oscillux_core::mapping::{Mapper, MappingConfig, SPECTRUM_BINS, VALUE_COUNT};

const UNIFORMS: [&str; VALUE_COUNT] = [
    "amplitude",
    "level",
    "bass",
    "mid",
    "treble",
    "onset",
    "bassImpact",
    "flux",
    "spectralCentroid",
];

fn frame_flags(frame: &Value) -> (u32, bool) {
    let Value::Obj(fields) = frame else {
        panic!("frame is not an object")
    };
    let Some((_, flags)) = fields.iter().find(|(k, _)| k == "flags") else {
        return (0, false);
    };
    let mut bits = 0;
    let mut unavailable = false;
    for flag in flags.arr() {
        match flag.str() {
            "analysis-gap" => bits |= FLAG_GAP,
            "analysis-stalled" => bits |= FLAG_STALLED,
            "live-analysis-unavailable" => unavailable = true,
            _ => {}
        }
    }
    (bits, unavailable)
}

fn check(input: &str, golden: &str) {
    let input = json::parse(input).expect("parse input");
    let golden = json::parse(golden).expect("parse golden");
    let mapping = golden.get("mapping");
    let config = MappingConfig {
        hop_seconds: mapping.get("dt_seconds").num(),
        ..MappingConfig::default()
    };
    assert_eq!(config.hop_seconds, 1.0 / 60.0);
    assert_eq!(config.db_floor, mapping.get("db_floor").num());
    assert_eq!(
        config.loudness_reference,
        mapping.get("loudness_reference").num()
    );
    assert_eq!(config.release_seconds, mapping.get("release_seconds").num());
    let tolerance = golden.get("tolerance").get("scalar").num();
    let mut mapper = Mapper::new(config).unwrap();
    let frames = input.get("frames").arr();
    let expected = golden.get("frames").arr();
    assert_eq!(frames.len(), expected.len());
    for (frame, want) in frames.iter().zip(expected) {
        let sequence = frame.get("sequence").num();
        assert_eq!(sequence, want.get("sequence").num());
        let (bits, unavailable) = frame_flags(frame);
        let reset = bits & (FLAG_GAP | FLAG_STALLED) != 0;
        assert_eq!(reset, want.get("reset").boolean(), "frame {sequence}");
        assert_eq!(unavailable, want.get("unavailable").boolean());
        if reset {
            mapper.reset();
        }
        let bands = frame.get("spectrum").arr();
        let mut dsp = DspFrame::ZERO;
        dsp.flags = bits;
        dsp.band_count = bands.len() as u32;
        dsp.rms = frame.get("rms").num();
        dsp.loudness_db = frame.get("loudnessDb").num();
        let onset = frame.get("onset");
        dsp.onset.broadband = onset.get("broadband").num();
        dsp.onset.low = onset.get("low").num();
        dsp.onset.mid = onset.get("mid").num();
        dsp.onset.high = onset.get("high").num();
        for (slot, band) in dsp.spectrum.iter_mut().zip(bands) {
            *slot = band.num();
        }
        let mapped = mapper.map(&dsp, unavailable).unwrap();
        for (slot, name) in UNIFORMS.iter().enumerate() {
            let expect = want.get("uniforms").get(name).num();
            let got = mapped.values[slot];
            assert!(
                (got - expect).abs() <= tolerance,
                "frame {sequence} {name}: rust {got}, golden {expect}"
            );
        }
        let spectrum = want.get("spectrum").arr();
        assert_eq!(spectrum.len(), SPECTRUM_BINS);
        for (bin, (got, expect)) in mapped.spectrum.iter().zip(spectrum).enumerate() {
            assert_eq!(
                got.to_bits(),
                (expect.num() as f32).to_bits(),
                "frame {sequence} bin {bin}"
            );
        }
    }
}

#[test]
fn sine_440() {
    check(
        include_str!("../../../conformance/uniforms/inputs/sine-440.frames.golden.json"),
        include_str!("../../../conformance/uniforms/sine-440.uniforms.golden.json"),
    );
}

#[test]
fn gap_stall_latency() {
    check(
        include_str!("../../../conformance/uniforms/inputs/gap-stall-latency.frames.golden.json"),
        include_str!("../../../conformance/uniforms/gap-stall-latency.uniforms.golden.json"),
    );
}
