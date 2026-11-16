// SPDX-License-Identifier: AGPL-3.0-only
use oscillux::{
    curves::*, governor::*, mapping::*, packing::*, OSCILLUX_ERR_INVALID_ARGUMENT,
    OSCILLUX_ERR_NULL, OSCILLUX_OK,
};
use oscillux_core::dsp::{DspConfig, DspFrame};
use oscillux_core::mapping::{AMPLITUDE, BASS, BASS_IMPACT, CENTROID, FLUX, LEVEL, ONSET};
use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
    ptr::{null, null_mut},
};
struct Allocator;
thread_local! {static ARMED:Cell<bool>=const{Cell::new(false)};static ALLOCS:Cell<usize>=const{Cell::new(0)};}
unsafe impl GlobalAlloc for Allocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if ARMED.with(Cell::get) {
            ALLOCS.with(|n| n.set(n.get() + 1));
        }
        System.alloc(layout)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }
}
#[global_allocator]
static ALLOCATOR: Allocator = Allocator;
struct Handles {
    curve: *mut OscilluxCurve,
    governor: *mut OscilluxGovernor,
    mapper: *mut OscilluxMapper,
    packer: *mut OscilluxPacker,
}
impl Drop for Handles {
    fn drop(&mut self) {
        unsafe {
            oscillux_curve_destroy(self.curve);
            oscillux_governor_destroy(self.governor);
            oscillux_mapping_destroy(self.mapper);
            oscillux_packer_destroy(self.packer);
        }
    }
}
impl Handles {
    fn new() -> Self {
        let mut h = Self {
            curve: null_mut(),
            governor: null_mut(),
            mapper: null_mut(),
            packer: null_mut(),
        };
        let mut curve = OscilluxCurveConfig::default();
        let mut governor = OscilluxGovernorConfig::default();
        let mut mapper = OscilluxMappingConfig::default();
        unsafe {
            assert_eq!(oscillux_curve_config_default(&mut curve), OSCILLUX_OK);
            curve.value = 0.25;
            assert_eq!(oscillux_governor_config_default(&mut governor), OSCILLUX_OK);
            assert_eq!(oscillux_mapping_config_default(&mut mapper), OSCILLUX_OK);
            assert_eq!(oscillux_curve_create(&curve, &mut h.curve), OSCILLUX_OK);
            assert_eq!(
                oscillux_governor_create(&governor, &mut h.governor),
                OSCILLUX_OK
            );
            assert_eq!(oscillux_mapping_create(&mapper, &mut h.mapper), OSCILLUX_OK);
            let fields = [
                OscilluxUniformField {
                    source: 0,
                    source_offset: 0,
                    components: 9,
                    offset: 0,
                    stride: 4,
                },
                OscilluxUniformField {
                    source: 2,
                    source_offset: 0,
                    components: 1,
                    offset: 36,
                    stride: 4,
                },
            ];
            assert_eq!(
                oscillux_packer_create(fields.as_ptr(), fields.len(), 40, &mut h.packer),
                OSCILLUX_OK
            );
        }
        h
    }
}
#[test]
fn end_to_end_c_calls_and_resets_allocate_nothing() {
    let h = Handles::new();
    let mut mapped = OscilluxMapped::ZERO;
    let mut bytes = [0; 40];
    let mut curve = 0.0;
    let mut stats = OscilluxGovernorStats {
        ema_ms: 0.0,
        refresh_ms: 0.0,
        level: 0,
        has_ema: 0,
    };
    let mut frame = DspFrame::ZERO;
    frame.rms = 0.1;
    frame.loudness_db = -2.0;
    frame.band_count = 24;
    ARMED.with(|v| v.set(true));
    for i in 0..2000 {
        unsafe {
            assert_eq!(
                oscillux_curve_evaluate(h.curve, &OscilluxCurveInput::default(), &mut curve),
                OSCILLUX_OK
            );
            assert_eq!(
                oscillux_governor_record(h.governor, 16.7, &mut stats),
                OSCILLUX_OK
            );
            assert_eq!(
                oscillux_mapping_process(h.mapper, &frame, 0, &mut mapped),
                OSCILLUX_OK
            );
            assert_eq!(
                oscillux_packer_pack(
                    h.packer,
                    &mapped,
                    &curve,
                    1,
                    bytes.as_mut_ptr(),
                    bytes.len()
                ),
                OSCILLUX_OK
            );
            if i % 19 == 0 {
                assert_eq!(oscillux_governor_reset(h.governor, 2), OSCILLUX_OK);
                assert_eq!(oscillux_mapping_reset(h.mapper), OSCILLUX_OK);
            }
        }
    }
    ARMED.with(|v| v.set(false));
    assert_eq!(ALLOCS.with(Cell::get), 0);
    assert_eq!(&bytes[36..40], &0.25f32.to_le_bytes());
}
#[test]
fn c_failures_preserve_output_and_state() {
    let h = Handles::new();
    let mut out = 123.0;
    unsafe {
        assert_eq!(
            oscillux_curve_evaluate(
                h.curve,
                &OscilluxCurveInput {
                    has_previous: 2,
                    ..Default::default()
                },
                &mut out
            ),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(out, 123.0);
        assert_eq!(
            oscillux_curve_evaluate(h.curve, null(), &mut out),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_governor_record(h.governor, 33.4, null_mut()),
            OSCILLUX_ERR_NULL
        );
        let mut stats = OscilluxGovernorStats {
            ema_ms: 0.0,
            refresh_ms: 0.0,
            level: 0,
            has_ema: 0,
        };
        assert_eq!(
            oscillux_governor_record(h.governor, 16.7, &mut stats),
            OSCILLUX_OK
        );
        assert_eq!(stats.level, 3);
        assert_eq!(stats.ema_ms, 16.7);
        let mut mapped = OscilluxMapped::ZERO;
        let mut frame = DspFrame::ZERO;
        frame.rms = f64::NAN;
        assert_eq!(
            oscillux_mapping_process(h.mapper, &frame, 0, &mut mapped),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(mapped, OscilluxMapped::ZERO);
        assert_eq!(
            oscillux_mapping_process(h.mapper, &DspFrame::ZERO, 2, &mut mapped),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        let mut bytes = [99; 40];
        let host = [f64::NAN];
        assert_eq!(
            oscillux_packer_pack(h.packer, &mapped, host.as_ptr(), 1, bytes.as_mut_ptr(), 40),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(bytes, [99; 40]);
        assert_eq!(
            oscillux_packer_pack(
                h.packer,
                &mapped,
                null(),
                usize::MAX,
                bytes.as_mut_ptr(),
                40
            ),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(bytes, [99; 40]);
        assert_eq!(
            oscillux_packer_pack(h.packer, &mapped, null(), 0, bytes.as_mut_ptr(), usize::MAX),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(bytes, [99; 40]);
        assert_eq!(
            oscillux_packer_pack(h.packer, &mapped, &0.5, 1, bytes.as_mut_ptr(), 39),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(bytes, [99; 40]);
    }
}
#[test]
fn invalid_create_nulls_handles_and_null_lifecycle_is_safe() {
    unsafe {
        let mut curve = null_mut();
        let bad = OscilluxCurveConfig {
            kind: 99,
            ..Default::default()
        };
        assert_eq!(
            oscillux_curve_create(&bad, &mut curve),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert!(curve.is_null());
        let mut governor = null_mut();
        let bad = OscilluxGovernorConfig {
            ema_alpha: f64::NAN,
            ..Default::default()
        };
        assert_eq!(
            oscillux_governor_create(&bad, &mut governor),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert!(governor.is_null());
        let bad = OscilluxGovernorConfig {
            promote_target_factor: 2.0,
            ..Default::default()
        };
        assert_eq!(
            oscillux_governor_create(&bad, &mut governor),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert!(governor.is_null());
        let mut mapper = null_mut();
        let bad = OscilluxMappingConfig {
            release_seconds: 0.0,
            ..Default::default()
        };
        assert_eq!(
            oscillux_mapping_create(&bad, &mut mapper),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert!(mapper.is_null());
        let mut packer = null_mut();
        assert_eq!(
            oscillux_packer_create(null(), usize::MAX, 16, &mut packer),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert!(packer.is_null());
        assert_eq!(oscillux_curve_config_default(null_mut()), OSCILLUX_ERR_NULL);
        assert_eq!(
            oscillux_governor_config_default(null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_mapping_config_default(null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(oscillux_governor_reset(null_mut(), 0), OSCILLUX_ERR_NULL);
        assert_eq!(oscillux_mapping_reset(null_mut()), OSCILLUX_ERR_NULL);
        oscillux_curve_destroy(null_mut());
        oscillux_governor_destroy(null_mut());
        oscillux_mapping_destroy(null_mut());
        oscillux_packer_destroy(null_mut());
    }
}
#[test]
fn mapping_config_from_dsp_derives_hop_and_loudness_reference() {
    let dsp = DspConfig {
        sample_rate_hz: 44_100,
        ..DspConfig::default()
    };
    let mut out = OscilluxMappingConfig::default();
    unsafe {
        assert_eq!(
            oscillux_mapping_config_from_dsp(&dsp, &mut out),
            OSCILLUX_OK
        );
        assert_eq!(out, OscilluxMappingConfig::for_dsp(&dsp));
        assert_eq!(out.hop_seconds, 512.0 / 44_100.0);
        assert_eq!(out.loudness_reference, -18.0);
        let mut default = OscilluxMappingConfig::for_dsp(&dsp);
        let reference = DspConfig::default();
        assert_eq!(
            oscillux_mapping_config_from_dsp(&reference, &mut default),
            OSCILLUX_OK
        );
        assert_eq!(default, OscilluxMappingConfig::default());
        let above_nyquist = DspConfig {
            sample_rate_hz: 22_050,
            ..DspConfig::default()
        };
        let before = out;
        assert_eq!(
            oscillux_mapping_config_from_dsp(&above_nyquist, &mut out),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(out, before);
        assert_eq!(
            oscillux_mapping_config_from_dsp(null(), &mut out),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_mapping_config_from_dsp(&dsp, null_mut()),
            OSCILLUX_ERR_NULL
        );
    }
}

#[test]
fn mapping_process_ext_reads_descriptors_and_refuses_a_bad_ext_without_moving_state() {
    let plain = Handles::new();
    let ext_mapper = Handles::new();
    let mut frame = DspFrame::ZERO;
    frame.rms = 0.25;
    frame.onset.broadband = 0.5;
    frame.band_count = 24;
    frame.spectrum[3] = 0.5;
    let mut ext = oscillux::dsp::OscilluxDspFrameExt::default();
    ext.descriptors.spectral_flux = 0.375;
    ext.descriptors.centroid_hz = 2000.0;
    let (mut want, mut got) = (OscilluxMapped::ZERO, OscilluxMapped::ZERO);
    unsafe {
        // A null ext maps exactly as the plain call.
        assert_eq!(
            oscillux_mapping_process(plain.mapper, &frame, 0, &mut want),
            OSCILLUX_OK
        );
        assert_eq!(
            oscillux_mapping_process_ext(ext_mapper.mapper, &frame, null(), 0, &mut got),
            OSCILLUX_OK
        );
        assert_eq!(got, want);
        // Without descriptors the deprecated proxies stay: the onset, and band 3 of 24.
        assert_eq!(got.values[FLUX], 0.5);
        assert_eq!(got.values[CENTROID], 3.0 / 23.0);

        // Refusals leave the output and the envelope untouched.
        let before = got;
        for bad in [
            oscillux::dsp::OscilluxDspFrameExt {
                struct_size: 48,
                ..ext
            },
            oscillux::dsp::OscilluxDspFrameExt { reserved: 1, ..ext },
        ] {
            assert_eq!(
                oscillux_mapping_process_ext(ext_mapper.mapper, &frame, &bad, 0, &mut got),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(got, before);
        }
        let mut non_finite = ext;
        non_finite.descriptors.centroid_hz = f64::INFINITY;
        assert_eq!(
            oscillux_mapping_process_ext(ext_mapper.mapper, &frame, &non_finite, 0, &mut got),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(got, before);
        assert_eq!(
            oscillux_mapping_process_ext(ext_mapper.mapper, &frame, &ext, 2, &mut got),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            oscillux_mapping_process_ext(ext_mapper.mapper, null(), &ext, 0, &mut got),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(got, before);

        // With descriptors only FLUX and CENTROID differ from the plain mapper.
        assert_eq!(
            oscillux_mapping_process(plain.mapper, &frame, 0, &mut want),
            OSCILLUX_OK
        );
        assert_eq!(
            oscillux_mapping_process_ext(ext_mapper.mapper, &frame, &ext, 0, &mut got),
            OSCILLUX_OK
        );
        assert_eq!(got.values[FLUX], 0.375);
        // log10(2000 / 20) / 3 decades.
        assert!((got.values[CENTROID] - 2.0 / 3.0).abs() < 1e-15);
        for slot in (0..got.values.len()).filter(|&s| s != FLUX && s != CENTROID) {
            assert_eq!(got.values[slot], want.values[slot], "slot {slot}");
        }
        assert_eq!(got.spectrum, want.spectrum);
    }
}

#[test]
fn mapping_relative_level_source_reads_ext_levels_and_refuses_frames_without_them() {
    let absolute = Handles::new();
    let relative = Handles::new();
    let mut frame = DspFrame::ZERO;
    frame.rms = 0.25;
    frame.band_count = 24;
    frame.spectrum[..24].fill(0.125);
    let mut ext = oscillux::dsp::OscilluxDspFrameExt::default();
    ext.levels.band_count = 24;
    ext.levels.relative_bands[..8].fill(0.75);
    ext.levels.relative_bands[8..24].fill(0.25);
    let (mut want, mut got) = (OscilluxMapped::ZERO, OscilluxMapped::ZERO);
    unsafe {
        for bad in [2, u32::MAX] {
            assert_eq!(
                oscillux_mapping_set_level_source(relative.mapper, bad),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
        }
        assert_eq!(
            oscillux_mapping_set_level_source(null_mut(), OSCILLUX_MAPPING_LEVELS_RELATIVE),
            OSCILLUX_ERR_NULL
        );
        // The refused values left the default: the levels are ignored.
        assert_eq!(
            oscillux_mapping_process_ext(absolute.mapper, &frame, &ext, 0, &mut want),
            OSCILLUX_OK
        );
        assert_eq!(
            oscillux_mapping_process_ext(relative.mapper, &frame, &ext, 0, &mut got),
            OSCILLUX_OK
        );
        assert_eq!(got, want);
        assert_eq!(want.values[BASS..ONSET], [0.125; 3]);
        assert_eq!(oscillux_mapping_reset(relative.mapper), OSCILLUX_OK);

        assert_eq!(
            oscillux_mapping_set_level_source(relative.mapper, OSCILLUX_MAPPING_LEVELS_RELATIVE),
            OSCILLUX_OK
        );
        // Without the levels section the relative source refuses and moves nothing.
        let before = got;
        let descriptors_only = oscillux::dsp::OscilluxDspFrameExt {
            struct_size: 56,
            ..ext
        };
        let through_beat = oscillux::dsp::OscilluxDspFrameExt {
            struct_size: 104,
            ..ext
        };
        for bad in [
            null(),
            &descriptors_only as *const _,
            &through_beat as *const _,
        ] {
            assert_eq!(
                oscillux_mapping_process_ext(relative.mapper, &frame, bad, 0, &mut got),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(got, before);
        }
        assert_eq!(
            oscillux_mapping_process(relative.mapper, &frame, 0, &mut got),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(got, before);
        assert_eq!(
            oscillux_mapping_process(relative.mapper, &frame, 1, &mut got),
            OSCILLUX_OK
        );
        assert_eq!(got, OscilluxMapped::ZERO);
        assert_eq!(oscillux_mapping_reset(relative.mapper), OSCILLUX_OK);

        assert_eq!(
            oscillux_mapping_process_ext(relative.mapper, &frame, &ext, 0, &mut got),
            OSCILLUX_OK
        );
        assert_eq!(got.values[BASS..ONSET], [0.75, 0.25, 0.25]);
        assert_eq!(got.spectrum[0], 0.75);
        assert_eq!(got.spectrum[63], 0.25);
        for slot in [AMPLITUDE, LEVEL, ONSET, BASS_IMPACT, FLUX, CENTROID] {
            assert_eq!(got.values[slot], want.values[slot], "slot {slot}");
        }
    }
}
