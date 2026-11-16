// SPDX-License-Identifier: AGPL-3.0-only
//! C boundary robustness: null pointers, zero and huge lengths, non-finite values and the
//! destroy lifecycle never reach `OSCILLUX_ERR_PANIC`, and refused calls leave state alone.
//!
//! Misaligned pointers, dangling handles and double destroy are caller contract violations
//! (undefined in C as well) and are deliberately not exercised.
use oscillux::dsp::*;
use oscillux::limiter::*;
use oscillux::{
    curves::*, governor::*, mapping::*, packing::*, reaction::*, OSCILLUX_ERR_INVALID_ARGUMENT,
    OSCILLUX_ERR_NULL, OSCILLUX_OK,
};
use oscillux_core::dsp::{DspConfig, DspFrame, FLAG_GAP};
use std::ptr::{null, null_mut};

const NON_FINITE: [f64; 3] = [f64::NAN, f64::INFINITY, f64::NEG_INFINITY];

fn dsp() -> *mut OscilluxDsp {
    let mut dsp = null_mut();
    assert_eq!(
        unsafe { oscillux_dsp_create(&DspConfig::default(), &mut dsp) },
        OSCILLUX_OK
    );
    dsp
}

/// Pushes `samples` (mono F32) and returns the produced frames.
fn push(dsp: *mut OscilluxDsp, samples: &[f32]) -> Vec<DspFrame> {
    let mut out = vec![DspFrame::ZERO; samples.len() / 64 + 1];
    let mut result = OscilluxDspPushResult::default();
    let status = unsafe {
        oscillux_dsp_push_f32(
            dsp,
            samples.as_ptr(),
            samples.len(),
            1,
            out.as_mut_ptr(),
            out.len(),
            &mut result,
        )
    };
    assert_eq!(status, OSCILLUX_OK);
    assert_eq!(result.consumed, samples.len());
    out.truncate(result.produced);
    out
}

#[test]
fn null_arguments_are_refused_on_every_export() {
    unsafe {
        let mut frame = DspFrame::ZERO;
        let mut result = OscilluxDspPushResult::default();
        assert_eq!(oscillux_dsp_config_default(null_mut()), OSCILLUX_ERR_NULL);
        assert_eq!(oscillux_dsp_create(null(), null_mut()), OSCILLUX_ERR_NULL);
        let mut handle = std::ptr::dangling_mut::<OscilluxDsp>();
        assert_eq!(oscillux_dsp_create(null(), &mut handle), OSCILLUX_ERR_NULL);
        assert!(handle.is_null(), "a failed create must null the handle");
        assert_eq!(
            oscillux_dsp_versioned_config_default(null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_dsp_versioned_config_validate(null(), null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_dsp_create_versioned(null(), null_mut()),
            OSCILLUX_ERR_NULL
        );
        let mut handle = std::ptr::dangling_mut::<OscilluxDsp>();
        assert_eq!(
            oscillux_dsp_create_versioned(null(), &mut handle),
            OSCILLUX_ERR_NULL
        );
        assert!(
            handle.is_null(),
            "a failed versioned create must null the handle"
        );
        assert_eq!(
            oscillux_dsp_begin_segment(null_mut(), 0.0, 0),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_dsp_push_f32(null_mut(), null(), 0, 1, null_mut(), 0, &mut result),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_dsp_push_f64(null_mut(), null(), 0, 1, null_mut(), 0, &mut result),
            OSCILLUX_ERR_NULL
        );
        let dsp = dsp();
        // Nonzero lengths with null buffers, and a null result.
        assert_eq!(
            oscillux_dsp_push_f32(dsp, null(), 4, 1, &mut frame, 1, &mut result),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_dsp_push_f64(dsp, [0.0; 4].as_ptr(), 4, 1, null_mut(), 1, &mut result),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_dsp_push_f32(dsp, null(), 0, 1, null_mut(), 0, null_mut()),
            OSCILLUX_ERR_NULL
        );
        oscillux_dsp_destroy(dsp);

        let mut out = OscilluxLimiterFrame::default();
        assert_eq!(
            oscillux_limiter_policy_default(null_mut()),
            OSCILLUX_ERR_NULL
        );
        let mut limiter = std::ptr::dangling_mut::<OscilluxLimiter>();
        assert_eq!(
            oscillux_limiter_create(null(), &mut limiter),
            OSCILLUX_ERR_NULL
        );
        assert!(limiter.is_null());
        assert_eq!(
            oscillux_limiter_create(&OscilluxLimiterPolicy::default(), null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(oscillux_limiter_reset(null_mut()), OSCILLUX_ERR_NULL);
        assert_eq!(
            oscillux_limiter_process(null_mut(), &out, &mut out),
            OSCILLUX_ERR_NULL
        );

        let mut value = 0.0;
        let mut stats = OscilluxGovernorStats {
            ema_ms: 0.0,
            refresh_ms: 0.0,
            level: 0,
            has_ema: 0,
        };
        let mut mapped = OscilluxMapped::ZERO;
        assert_eq!(oscillux_curve_create(null(), null_mut()), OSCILLUX_ERR_NULL);
        assert_eq!(
            oscillux_curve_evaluate(null(), &OscilluxCurveInput::default(), &mut value),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_governor_create(null(), null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_governor_record(null_mut(), 16.0, &mut stats),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_mapping_create(null(), null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_mapping_process(null_mut(), &frame, 0, &mut mapped),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_packer_create(null(), 0, 4, null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_packer_pack(null(), &mapped, null(), 0, null_mut(), 0),
            OSCILLUX_ERR_NULL
        );
    }
}

#[test]
fn zero_and_huge_lengths_are_handled_without_touching_memory() {
    unsafe {
        let dsp = dsp();
        let mut result = OscilluxDspPushResult {
            consumed: 7,
            produced: 7,
        };
        // Zero lengths accept null buffers and report no progress.
        assert_eq!(
            oscillux_dsp_push_f32(dsp, null(), 0, 2, null_mut(), 0, &mut result),
            OSCILLUX_OK
        );
        assert_eq!(result, OscilluxDspPushResult::default());
        // Zero channels is refused, even with no samples.
        assert_eq!(
            oscillux_dsp_push_f32(dsp, null(), 0, 0, null_mut(), 0, &mut result),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        // Lengths whose byte size overflows or exceeds isize::MAX are refused before any slice
        // is formed; the (dangling but non-null) pointers are never read.
        let dangling32 = core::ptr::NonNull::<f32>::dangling().as_ptr();
        let dangling64 = core::ptr::NonNull::<f64>::dangling().as_ptr();
        let frames = core::ptr::NonNull::<DspFrame>::dangling().as_ptr();
        for (count, channels) in [
            (usize::MAX, 2),
            (usize::MAX / 2, 2),
            (isize::MAX as usize / 4 + 1, 1),
            (usize::MAX, u32::MAX),
        ] {
            assert_eq!(
                oscillux_dsp_push_f32(dsp, dangling32, count, channels, frames, 1, &mut result),
                OSCILLUX_ERR_INVALID_ARGUMENT,
                "f32 {count} x {channels}"
            );
            assert_eq!(
                oscillux_dsp_push_f64(dsp, dangling64, count, channels, frames, 1, &mut result),
                OSCILLUX_ERR_INVALID_ARGUMENT,
                "f64 {count} x {channels}"
            );
        }
        for capacity in [
            usize::MAX,
            isize::MAX as usize / core::mem::size_of::<DspFrame>() + 1,
        ] {
            assert_eq!(
                oscillux_dsp_push_f32(dsp, dangling32, 1, 1, frames, capacity, &mut result),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
        }
        // A full window with no output room stops just before the completing sample.
        let window = DspConfig::default().fft_window_samples as usize;
        let samples = vec![0.25f32; window];
        assert_eq!(
            oscillux_dsp_push_f32(dsp, samples.as_ptr(), window, 1, null_mut(), 0, &mut result),
            OSCILLUX_OK
        );
        assert_eq!(result.consumed, window - 1);
        assert_eq!(result.produced, 0);
        oscillux_dsp_destroy(dsp);

        // Packer: field counts and byte lengths past the limits.
        let mut packer = null_mut();
        let field = OscilluxUniformField {
            source: 0,
            source_offset: 0,
            components: 1,
            offset: 0,
            stride: 4,
        };
        let many = vec![field; 257];
        assert_eq!(
            oscillux_packer_create(many.as_ptr(), many.len(), 4, &mut packer),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        for block in [0, 3, usize::MAX] {
            assert_eq!(
                oscillux_packer_create(&field, 1, block, &mut packer),
                OSCILLUX_ERR_INVALID_ARGUMENT,
                "block {block}"
            );
            assert!(packer.is_null());
        }
        assert_eq!(
            oscillux_packer_create(&field, 1, 4, &mut packer),
            OSCILLUX_OK
        );
        let mapped = OscilluxMapped::ZERO;
        let bytes = core::ptr::NonNull::<u8>::dangling().as_ptr();
        let host = core::ptr::NonNull::<f64>::dangling().as_ptr();
        assert_eq!(
            oscillux_packer_pack(packer, &mapped, host, usize::MAX, bytes, 4),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            oscillux_packer_pack(packer, &mapped, null(), 0, bytes, usize::MAX),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        let mut short = [0xAAu8; 3];
        assert_eq!(
            oscillux_packer_pack(packer, &mapped, null(), 0, short.as_mut_ptr(), short.len()),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(short, [0xAA; 3], "a refused pack must not write");
        oscillux_packer_destroy(packer);
    }
}

#[test]
fn non_finite_inputs_never_panic_and_refusals_keep_state() {
    unsafe {
        // DSP: non-finite PCM is outside the qualified domain but must not panic, and the
        // analyzer stays usable.
        let dsp = dsp();
        let window = DspConfig::default().fft_window_samples as usize;
        for bad in NON_FINITE {
            let mut samples = vec![0.1f32; window * 2];
            samples[window / 2] = bad as f32;
            assert!(!push(dsp, &samples).is_empty());
            let samples64 = vec![bad; 1024];
            let mut out = vec![DspFrame::ZERO; 4];
            let mut result = OscilluxDspPushResult::default();
            assert_eq!(
                oscillux_dsp_push_f64(
                    dsp,
                    samples64.as_ptr(),
                    samples64.len(),
                    1,
                    out.as_mut_ptr(),
                    out.len(),
                    &mut result
                ),
                OSCILLUX_OK
            );
        }
        assert_eq!(oscillux_dsp_begin_segment(dsp, 0.0, 0), OSCILLUX_OK);
        assert!(!push(dsp, &vec![0.1f32; window * 2]).is_empty());
        oscillux_dsp_destroy(dsp);

        // Limiter: non-finite policy and frame values are refused; output and history stay.
        for bad in NON_FINITE {
            let mut limiter = null_mut();
            let policy = OscilluxLimiterPolicy {
                max_flash_hz: bad,
                ..Default::default()
            };
            assert_eq!(
                oscillux_limiter_create(&policy, &mut limiter),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert!(limiter.is_null());
        }
        let mut limiter = null_mut();
        assert_eq!(
            oscillux_limiter_create(&OscilluxLimiterPolicy::default(), &mut limiter),
            OSCILLUX_OK
        );
        let good = OscilluxLimiterFrame {
            time_ms: 100.0,
            broadband: 0.5,
            ..Default::default()
        };
        let mut out = OscilluxLimiterFrame::default();
        assert_eq!(
            oscillux_limiter_process(limiter, &good, &mut out),
            OSCILLUX_OK
        );
        let sentinel = OscilluxLimiterFrame {
            time_ms: -1.0,
            ..Default::default()
        };
        for bad in NON_FINITE {
            for field in 0..7 {
                let mut frame = good;
                let slot = [
                    &mut frame.time_ms,
                    &mut frame.broadband,
                    &mut frame.low,
                    &mut frame.mid,
                    &mut frame.high,
                    &mut frame.red,
                    &mut frame.area,
                ];
                *slot.into_iter().nth(field).unwrap() = bad;
                out = sentinel;
                assert_eq!(
                    oscillux_limiter_process(limiter, &frame, &mut out),
                    OSCILLUX_ERR_INVALID_ARGUMENT
                );
                assert_eq!(out.time_ms.to_bits(), frame.time_ms.to_bits());
                assert_eq!(
                    OscilluxLimiterFrame {
                        time_ms: 0.0,
                        ..out
                    },
                    OscilluxLimiterFrame::fail_safe(0.0),
                    "a refused frame writes the fail-safe frame"
                );
            }
        }
        // History unchanged: the same timestamp is still accepted (non-decreasing).
        assert_eq!(
            oscillux_limiter_process(limiter, &good, &mut out),
            OSCILLUX_OK
        );
        oscillux_limiter_destroy(limiter);

        // Curve, governor, mapping and packer.
        let mut curve = null_mut();
        let config = OscilluxCurveConfig {
            value: 0.5,
            ..Default::default()
        };
        assert_eq!(oscillux_curve_create(&config, &mut curve), OSCILLUX_OK);
        for bad in NON_FINITE {
            let mut value = 7.0;
            let input = OscilluxCurveInput {
                previous_value: bad,
                has_previous: 1,
                ..Default::default()
            };
            assert_eq!(
                oscillux_curve_evaluate(curve, &input, &mut value),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(value, 7.0);
            let mut rejected = null_mut();
            let bad_config = OscilluxCurveConfig {
                value: bad,
                ..config
            };
            assert_eq!(
                oscillux_curve_create(&bad_config, &mut rejected),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert!(rejected.is_null());
        }
        oscillux_curve_destroy(curve);

        let mut governor = null_mut();
        assert_eq!(
            oscillux_governor_create(&OscilluxGovernorConfig::default(), &mut governor),
            OSCILLUX_OK
        );
        let mut before = OscilluxGovernorStats {
            ema_ms: 0.0,
            refresh_ms: 0.0,
            level: 0,
            has_ema: 0,
        };
        assert_eq!(
            oscillux_governor_record(governor, 16.0, &mut before),
            OSCILLUX_OK
        );
        for bad in NON_FINITE {
            let mut after = before;
            assert_eq!(
                oscillux_governor_record(governor, bad, &mut after),
                OSCILLUX_OK
            );
            assert_eq!(after, before, "a non-finite sample must be ignored");
        }
        oscillux_governor_destroy(governor);

        let mut mapper = null_mut();
        assert_eq!(
            oscillux_mapping_create(&OscilluxMappingConfig::default(), &mut mapper),
            OSCILLUX_OK
        );
        let mut packer = null_mut();
        let field = OscilluxUniformField {
            source: 2,
            source_offset: 0,
            components: 1,
            offset: 0,
            stride: 4,
        };
        assert_eq!(
            oscillux_packer_create(&field, 1, 4, &mut packer),
            OSCILLUX_OK
        );
        for bad in NON_FINITE {
            let mut frame = DspFrame::ZERO;
            frame.band_count = 24;
            frame.spectrum[3] = bad;
            let mut mapped = OscilluxMapped::ZERO;
            mapped.values[0] = 9.0;
            assert_eq!(
                oscillux_mapping_process(mapper, &frame, 0, &mut mapped),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(mapped.values[0], 9.0, "a refused map must not write");
            let mut bytes = [0xAAu8; 4];
            assert_eq!(
                oscillux_packer_pack(packer, &mapped, &bad, 1, bytes.as_mut_ptr(), 4),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(bytes, [0xAA; 4], "a refused pack must not write");
        }
        // A finite value beyond f32 range is refused rather than packed as infinity.
        let mut bytes = [0xAAu8; 4];
        assert_eq!(
            oscillux_packer_pack(
                packer,
                &OscilluxMapped::ZERO,
                &f64::MAX,
                1,
                bytes.as_mut_ptr(),
                4
            ),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        oscillux_mapping_destroy(mapper);
        oscillux_packer_destroy(packer);
    }
}

#[test]
fn non_finite_segment_start_is_refused_and_keeps_gap_detection() {
    unsafe {
        let dsp = dsp();
        let window = DspConfig::default().fft_window_samples as usize;
        let samples = vec![0.1f32; window];
        assert!(!push(dsp, &samples).is_empty());
        for bad in NON_FINITE {
            assert_eq!(
                oscillux_dsp_begin_segment(dsp, bad, 0),
                OSCILLUX_ERR_INVALID_ARGUMENT,
                "segment start {bad}"
            );
        }
        // The refused calls did not replace the segment or poison the expected next time, so
        // a real ten-second gap is still flagged on the next segment's first frame.
        assert_eq!(oscillux_dsp_begin_segment(dsp, 10_000.0, 0), OSCILLUX_OK);
        let frames = push(dsp, &samples);
        assert_eq!(frames[0].flags & FLAG_GAP, FLAG_GAP);
        assert!(frames.iter().all(|f| f.media_time_ms.is_finite()));
        oscillux_dsp_destroy(dsp);
    }
}

#[test]
fn destroy_accepts_null_repeatedly_and_handles_survive_refusals() {
    unsafe {
        for _ in 0..3 {
            oscillux_dsp_destroy(null_mut());
            oscillux_limiter_destroy(null_mut());
            oscillux_curve_destroy(null_mut());
            oscillux_governor_destroy(null_mut());
            oscillux_mapping_destroy(null_mut());
            oscillux_reaction_destroy(null_mut());
            oscillux_packer_destroy(null_mut());
        }
        // Destroy after a run of refused calls, and destroy late after a reset.
        let dsp = dsp();
        let mut result = OscilluxDspPushResult::default();
        for _ in 0..100 {
            assert_eq!(
                oscillux_dsp_push_f32(dsp, null(), 1, 1, null_mut(), 0, &mut result),
                OSCILLUX_ERR_NULL
            );
        }
        assert_eq!(oscillux_dsp_begin_segment(dsp, 5.0, 1), OSCILLUX_OK);
        oscillux_dsp_destroy(dsp);
        let mut limiter = null_mut();
        assert_eq!(
            oscillux_limiter_create(&OscilluxLimiterPolicy::default(), &mut limiter),
            OSCILLUX_OK
        );
        assert_eq!(oscillux_limiter_reset(limiter), OSCILLUX_OK);
        oscillux_limiter_destroy(limiter);
    }
}

#[test]
fn reaction_refuses_null_bad_config_and_bad_input_without_changing_state() {
    unsafe {
        let mut config = OscilluxReactionConfig::default();
        let mut reaction = OscilluxReaction::ZERO;
        let mut queued = 0;
        let mut sampler = null_mut();
        let mapped = OscilluxMapped::ZERO;
        assert_eq!(
            oscillux_reaction_config_default(OSCILLUX_DSP_BEHAVIOR_V3, 48_000, null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_reaction_create(null(), &mut sampler),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_reaction_create(&config, null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(oscillux_reaction_reset(null_mut()), OSCILLUX_ERR_NULL);
        assert_eq!(
            oscillux_reaction_push(null_mut(), 0.0, &mapped, null()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_reaction_set_beat_clock(null_mut(), null()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_reaction_sample(null_mut(), 0.0, &mut reaction),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_reaction_queued(null(), &mut queued),
            OSCILLUX_ERR_NULL
        );

        // Unknown version, zero rate and an unreleased struct_size leave *out alone.
        config.capacity = 7;
        for (version, rate) in [(0, 48_000), (99, 48_000), (OSCILLUX_DSP_BEHAVIOR_V3, 0)] {
            assert_eq!(
                oscillux_reaction_config_default(version, rate, &mut config),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(config.capacity, 7);
        }
        config.struct_size = 8;
        assert_eq!(
            oscillux_reaction_config_default(OSCILLUX_DSP_BEHAVIOR_V3, 48_000, &mut config),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!((config.struct_size, config.capacity), (8, 7));
        sampler = std::ptr::dangling_mut();
        assert_eq!(
            oscillux_reaction_create(&config, &mut sampler),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert!(sampler.is_null(), "a refused create must null the handle");
        config = OscilluxReactionConfig::default();
        config.capacity = OSCILLUX_REACTION_MAX_CAPACITY + 1;
        assert_eq!(
            oscillux_reaction_create(&config, &mut sampler),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );

        config.capacity = 2;
        assert_eq!(oscillux_reaction_create(&config, &mut sampler), OSCILLUX_OK);
        for bad in NON_FINITE {
            let mut value = OscilluxMapped::ZERO;
            value.values[3] = bad;
            assert_eq!(
                oscillux_reaction_push(sampler, 0.0, &value, null()),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(
                oscillux_reaction_push(sampler, bad, &mapped, null()),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            reaction.beat = 9.0;
            assert_eq!(
                oscillux_reaction_sample(sampler, bad, &mut reaction),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(reaction.beat, 9.0, "a refused sample must not write");
        }
        let mut beat = OscilluxDspFrameExt::default().beat;
        beat.beat_phase = 1.0;
        assert_eq!(
            oscillux_reaction_push(sampler, 0.0, &mapped, &beat),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(oscillux_reaction_queued(sampler, &mut queued), OSCILLUX_OK);
        assert_eq!(queued, 0, "refused pushes must not queue");
        // Times must not decrease, and a full queue is refused.
        assert_eq!(
            oscillux_reaction_push(sampler, 10.0, &mapped, null()),
            OSCILLUX_OK
        );
        assert_eq!(
            oscillux_reaction_push(sampler, 5.0, &mapped, null()),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            oscillux_reaction_push(sampler, 10.0, &mapped, null()),
            OSCILLUX_OK
        );
        assert_eq!(
            oscillux_reaction_push(sampler, 20.0, &mapped, null()),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(oscillux_reaction_queued(sampler, &mut queued), OSCILLUX_OK);
        assert_eq!(queued, 2);
        let clock = OscilluxBeatClock {
            media_time_ms: 0.0,
            tempo_bpm: 0.0,
            beat_phase: 0.0,
            bar_phase: 0.0,
            beat_index: 0,
            beats_per_bar: 4,
            reserved: 0,
        };
        for bad in [
            clock,
            OscilluxBeatClock {
                tempo_bpm: 120.0,
                beats_per_bar: 0,
                ..clock
            },
            OscilluxBeatClock {
                tempo_bpm: 120.0,
                reserved: 1,
                ..clock
            },
            OscilluxBeatClock {
                tempo_bpm: 120.0,
                media_time_ms: f64::NAN,
                ..clock
            },
        ] {
            assert_eq!(
                oscillux_reaction_set_beat_clock(sampler, &bad),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
        }
        assert_eq!(
            oscillux_reaction_sample(sampler, 100.0, &mut reaction),
            OSCILLUX_OK
        );
        assert_eq!(
            reaction.locked, 0,
            "a refused clock must not drive the beat"
        );
        assert_eq!(oscillux_reaction_reset(sampler), OSCILLUX_OK);
        assert_eq!(oscillux_reaction_queued(sampler, &mut queued), OSCILLUX_OK);
        assert_eq!(queued, 0);
        assert_eq!(
            oscillux_reaction_push(sampler, 0.0, &mapped, null()),
            OSCILLUX_OK
        );
        oscillux_reaction_destroy(sampler);
    }
}
