// SPDX-License-Identifier: AGPL-3.0-only
//! The frame-window ABI validates wire inputs before updating state or output.
use oscillux::window_governor::*;
use oscillux::{OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use oscillux_core::window_governor::WindowDecision;
use std::mem::MaybeUninit;
use std::ptr::{self, null, null_mut};

#[test]
fn defaults_and_invalid_configurations() {
    unsafe {
        let mut storage = MaybeUninit::<OscilluxWindowGovernorConfig>::uninit();
        let config_ptr = storage.as_mut_ptr();
        ptr::addr_of_mut!((*config_ptr).struct_size)
            .write(size_of::<OscilluxWindowGovernorConfig>() as u32);
        assert_eq!(
            oscillux_window_governor_config_default(config_ptr),
            OSCILLUX_OK
        );
        let config = storage.assume_init();
        assert_eq!(config.demote_budget_fraction, 0.85);
        assert_eq!(config.promote_budget_fraction, 0.60);
        assert_eq!(config.demote_windows, 30);
        assert_eq!(config.promote_windows, 300);
        assert_eq!(config.cooldown_s, 5.0);
        let mut wrong_size = OscilluxWindowGovernorConfig {
            struct_size: 4,
            ..config
        };
        assert_eq!(
            oscillux_window_governor_config_default(&mut wrong_size),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(wrong_size.struct_size, 4);
        assert_eq!(
            oscillux_window_governor_config_default(null_mut()),
            OSCILLUX_ERR_NULL
        );
        for invalid in [
            wrong_size,
            OscilluxWindowGovernorConfig {
                demote_windows: 0,
                ..config
            },
            OscilluxWindowGovernorConfig {
                promote_windows: 0,
                ..config
            },
            OscilluxWindowGovernorConfig {
                demote_budget_fraction: 1.1,
                ..config
            },
            OscilluxWindowGovernorConfig {
                promote_budget_fraction: f64::NAN,
                ..config
            },
            OscilluxWindowGovernorConfig {
                promote_budget_fraction: 0.85,
                ..config
            },
            OscilluxWindowGovernorConfig {
                cooldown_s: -1.0,
                ..config
            },
            OscilluxWindowGovernorConfig {
                cooldown_s: f64::INFINITY,
                ..config
            },
        ] {
            let mut handle = ptr::dangling_mut();
            assert_eq!(
                oscillux_window_governor_create(&invalid, 0.0, &mut handle),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert!(handle.is_null());
        }
        let mut handle = ptr::dangling_mut();
        assert_eq!(
            oscillux_window_governor_create(&config, f64::NAN, &mut handle),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert!(handle.is_null());
        assert_eq!(
            oscillux_window_governor_create(null(), 0.0, &mut handle),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_window_governor_create(&config, 0.0, null_mut()),
            OSCILLUX_ERR_NULL
        );
        oscillux_window_governor_destroy(null_mut());
    }
}

#[test]
fn refused_samples_preserve_clock_streak_and_output() {
    unsafe {
        let config = OscilluxWindowGovernorConfig {
            demote_windows: 2,
            ..OscilluxWindowGovernorConfig::default()
        };
        let mut handle = null_mut();
        assert_eq!(
            oscillux_window_governor_create(&config, 10.0, &mut handle),
            OSCILLUX_OK
        );
        let sample = OscilluxWindowGovernorSample {
            p95_ms: 3.0,
            p99_ms: 19.0,
            interval_ms: 16.67,
            promotion_budget_ms: 8.33,
            now_s: 11.0,
            has_p95: 1,
            has_p99: 1,
            can_demote: 1,
            ..OscilluxWindowGovernorSample::default()
        };
        let mut out = MaybeUninit::uninit();
        assert_eq!(
            oscillux_window_governor_record(handle, &sample, out.as_mut_ptr()),
            OSCILLUX_OK
        );
        let mut out = out.assume_init();
        assert_eq!(out.decision, WindowDecision::Hold as u32);
        assert_eq!(out.over_budget, 1);
        assert_eq!(out.over_budget_streak, 1);
        let first = out;
        let future = OscilluxWindowGovernorSample {
            now_s: 100.0,
            ..sample
        };
        for invalid in [
            OscilluxWindowGovernorSample {
                now_s: 10.0,
                ..sample
            },
            OscilluxWindowGovernorSample {
                now_s: f64::INFINITY,
                ..sample
            },
            OscilluxWindowGovernorSample {
                p95_ms: f64::NAN,
                ..future
            },
            OscilluxWindowGovernorSample {
                p99_ms: -1.0,
                ..future
            },
            OscilluxWindowGovernorSample {
                interval_ms: 0.0,
                ..future
            },
            OscilluxWindowGovernorSample {
                promotion_budget_ms: -1.0,
                ..future
            },
            OscilluxWindowGovernorSample {
                has_p95: 2,
                ..future
            },
            OscilluxWindowGovernorSample {
                starved: 2,
                ..future
            },
            OscilluxWindowGovernorSample {
                can_demote: 2,
                ..future
            },
        ] {
            assert_eq!(
                oscillux_window_governor_record(handle, &invalid, &mut out),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(out, first);
        }
        assert_eq!(
            oscillux_window_governor_reset(handle, f64::NAN),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            oscillux_window_governor_reset(null_mut(), 0.0),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_window_governor_record(null_mut(), &sample, &mut out),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_window_governor_record(handle, null(), &mut out),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_window_governor_record(handle, &sample, null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(out, first);

        let at_floor = OscilluxWindowGovernorSample {
            can_demote: 0,
            ..sample
        };
        assert_eq!(
            oscillux_window_governor_record(handle, &at_floor, &mut out),
            OSCILLUX_OK
        );
        assert_eq!(
            out,
            OscilluxWindowGovernorResult {
                decision: WindowDecision::Hold as u32,
                over_budget: 1,
                over_budget_streak: 2,
                promotion_streak: 0,
                stable_streak: first.stable_streak,
            }
        );
        assert_eq!(
            oscillux_window_governor_record(handle, &sample, &mut out),
            OSCILLUX_OK
        );
        assert_eq!(
            out,
            OscilluxWindowGovernorResult {
                decision: WindowDecision::Demote as u32,
                over_budget: 1,
                ..OscilluxWindowGovernorResult::default()
            }
        );
        let mut absent = MaybeUninit::new(OscilluxWindowGovernorSample {
            has_p95: 0,
            starved: 1,
            ..sample
        });
        ptr::addr_of_mut!((*absent.as_mut_ptr()).p95_ms)
            .cast::<MaybeUninit<f64>>()
            .write(MaybeUninit::uninit());
        assert_eq!(
            oscillux_window_governor_record(handle, absent.as_ptr(), &mut out),
            OSCILLUX_OK
        );
        assert_eq!(
            out,
            OscilluxWindowGovernorResult {
                decision: WindowDecision::Hold as u32,
                stable_streak: 1,
                ..OscilluxWindowGovernorResult::default()
            }
        );
        oscillux_window_governor_destroy(handle);
    }
}
