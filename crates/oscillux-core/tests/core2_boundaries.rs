// SPDX-License-Identifier: AGPL-3.0-only
use oscillux_core::{curves::*, dsp::DspFrame, governor::*, mapping::*, packing::*};

#[test]
fn malformed_layouts_and_overflow_are_rejected() {
    let valid = Field {
        source: 2,
        source_offset: 0,
        components: 2,
        offset: 0,
        stride: 4,
    };
    for field in [
        Field { source: 3, ..valid },
        Field {
            source_offset: u32::MAX,
            ..valid
        },
        Field {
            components: 0,
            ..valid
        },
        Field {
            components: 65,
            ..valid
        },
        Field { offset: 1, ..valid },
        Field { stride: 2, ..valid },
        Field {
            offset: u32::MAX - 3,
            ..valid
        },
        Field {
            source: 0,
            source_offset: 8,
            ..valid
        },
        Field {
            source: 1,
            source_offset: 63,
            ..valid
        },
    ] {
        assert!(Packer::new(&[field], 32).is_err());
    }
    assert!(Packer::new(&[valid, valid], 32).is_err());
    for size in [0, 3, 4, usize::MAX] {
        assert!(Packer::new(&[valid], size).is_err());
    }
    assert!(Packer::new(&[valid; 257], 32).is_err());
}

#[test]
fn invalid_pack_never_partially_writes_and_padding_is_deterministic() {
    let field = Field {
        source: 2,
        source_offset: 0,
        components: 2,
        offset: 0,
        stride: 8,
    };
    let packer = Packer::new(&[field], 16).unwrap();
    for host in [
        &[1.0][..],
        &[1.0, f64::NAN],
        &[1.0, f64::INFINITY],
        &[1.0, f64::MAX],
    ] {
        let mut out = [99; 20];
        assert!(packer.pack(&[0.0; 9], &[0.0; 64], host, &mut out).is_err());
        assert_eq!(out, [99; 20]);
    }
    let mut short = [99; 15];
    assert!(packer
        .pack(&[0.0; 9], &[0.0; 64], &[1.0, 2.0], &mut short)
        .is_err());
    assert_eq!(short, [99; 15]);
    let mut out = [99; 20];
    packer
        .pack(&[0.0; 9], &[0.0; 64], &[1.0, -0.0], &mut out)
        .unwrap();
    assert_eq!(&out[0..4], &1.0f32.to_le_bytes());
    assert_eq!(&out[8..12], &(-0.0f32).to_le_bytes());
    assert_eq!(&out[4..8], &[0; 4]);
    assert_eq!(&out[12..16], &[0; 4]);
    assert_eq!(&out[16..], &[99; 4]);
}

#[test]
fn curves_reject_invalid_configuration_inputs_and_nonfinite_arithmetic() {
    for curve in [
        Curve {
            kind: 4,
            ..Curve::default()
        },
        Curve {
            unit: 3,
            ..Curve::default()
        },
        Curve {
            flags: 0,
            ..Curve::default()
        },
        Curve {
            flags: 64,
            ..Curve::default()
        },
        Curve {
            value: f64::NAN,
            ..Curve::default()
        },
        Curve {
            kind: 1,
            duration: 0.0,
            ..Curve::default()
        },
        Curve {
            kind: 2,
            attack: -1.0,
            release: 1.0,
            unit: 1,
            ..Curve::default()
        },
        Curve {
            kind: 3,
            period: 0.0,
            ..Curve::default()
        },
    ] {
        assert!(curve.validate().is_err());
    }
    let c = Curve::default();
    for input in [
        CurveInput {
            elapsed_seconds: f64::NAN,
            ..Default::default()
        },
        CurveInput {
            has_previous: 2,
            ..Default::default()
        },
    ] {
        assert!(c.evaluate(&input).is_err());
    }
    assert!(Curve {
        value: f64::MAX,
        ..Curve::default()
    }
    .evaluate(&CurveInput::default())
    .is_err());
    let lfo = Curve {
        kind: 3,
        unit: 1,
        flags: MIN | MAX,
        min: 0.0,
        max: 1.0,
        period: f64::MIN_POSITIVE,
        ..Curve::default()
    };
    assert!(lfo
        .evaluate(&CurveInput {
            elapsed_seconds: f64::MAX,
            ..Default::default()
        })
        .is_err());
}

#[test]
fn governor_ignores_invalid_samples_and_clamps_reset() {
    let mut governor = Governor::new(GovernorConfig::default()).unwrap();
    let before = governor.record(16.7);
    for frame in [0.0, -1.0, f64::NAN, f64::INFINITY, 250.0, 1000.0] {
        assert_eq!(governor.record(frame), before);
    }
    governor.reset(u32::MAX);
    assert_eq!(governor.stats().level, 3);
    assert_eq!(governor.stats().has_ema, 0);
    for c in [
        GovernorConfig {
            ema_alpha: 2.0,
            ..Default::default()
        },
        GovernorConfig {
            target_ms: f64::MAX,
            ..Default::default()
        },
        GovernorConfig {
            target_ms: f64::NAN,
            ..Default::default()
        },
        GovernorConfig {
            demote_frames: 0,
            ..Default::default()
        },
        GovernorConfig {
            initial_level: 4,
            ..Default::default()
        },
    ] {
        assert!(Governor::new(c).is_err());
    }
}

#[test]
fn mapping_rejects_invalid_inputs_without_mutating_envelope() {
    let mut mapper = Mapper::new(MappingConfig::default()).unwrap();
    let mut hot = DspFrame::ZERO;
    hot.rms = 1.0;
    hot.loudness_db = 18.0;
    hot.band_count = 24;
    mapper.map(&hot, false).unwrap();
    for invalid in [
        DspFrame {
            band_count: 65,
            ..hot
        },
        DspFrame {
            rms: f64::NAN,
            ..hot
        },
        DspFrame {
            loudness_db: f64::INFINITY,
            ..hot
        },
    ] {
        let mut actual = mapper.clone();
        assert!(actual.map(&invalid, false).is_err());
        let cold = DspFrame::ZERO;
        assert_eq!(actual.map(&cold, false), mapper.clone().map(&cold, false));
    }
    let mut invalid = hot;
    invalid.spectrum[1] = f64::NAN;
    assert!(mapper.map(&invalid, false).is_err());
    mapper.reset();
    assert_eq!(mapper.map(&DspFrame::ZERO, false).unwrap(), Mapped::ZERO);
    assert!(Mapper::new(MappingConfig {
        groups: [[0, 64], [8, 15], [16, 23]],
        ..Default::default()
    })
    .is_err());
}

#[test]
fn finite_mapping_overflow_uses_reference_zero_fallback() {
    let mut mapper = Mapper::new(MappingConfig::default()).unwrap();
    let mut frame = DspFrame::ZERO;
    frame.band_count = 24;
    frame.spectrum.fill(f64::MAX);
    let mapped = mapper.map(&frame, false).unwrap();
    assert_eq!(mapped.values[2], 0.0);
    assert_eq!(mapped.values[8], 0.0);
}
