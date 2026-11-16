// SPDX-License-Identifier: AGPL-3.0-only
use oscillux_core::{
    curves::{Curve, CurveInput, FROM, TO},
    governor::{Governor, GovernorConfig},
    packing::{Field, Packer},
};

#[test]
fn curve_governor_and_byte_block_early_proof() {
    let curve = Curve {
        kind: 1,
        unit: 1,
        flags: FROM | TO,
        from: 2.0,
        to: 4.0,
        duration: 2.0,
        ..Curve::default()
    };
    let value = curve
        .evaluate(&CurveInput {
            elapsed_seconds: 0.5,
            ..CurveInput::default()
        })
        .unwrap();
    assert_eq!(value, 2.5);
    let mut governor = Governor::new(GovernorConfig {
        demote_frames: 2,
        ..GovernorConfig::default()
    })
    .unwrap();
    assert_eq!(governor.record(33.4).level, 3);
    assert_eq!(governor.record(33.4).level, 2);
    let packer = Packer::new(
        &[Field {
            source: 2,
            source_offset: 0,
            components: 2,
            offset: 4,
            stride: 8,
        }],
        16,
    )
    .unwrap();
    let mut bytes = [255u8; 16];
    packer
        .pack(
            &[0.0; 9],
            &[0.0; 64],
            &[value, governor.stats().level as f64],
            &mut bytes,
        )
        .unwrap();
    assert_eq!(bytes, [0, 0, 0, 0, 0, 0, 32, 64, 0, 0, 0, 0, 0, 0, 0, 64]);
}
