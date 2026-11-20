// SPDX-License-Identifier: AGPL-3.0-only
//! C interface for the frame-window governor.
use crate::{guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use oscillux_core::window_governor::{WindowGovernor, WindowGovernorConfig, WindowSample};

/// C configuration. Set the size before calling the default writer or create.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscilluxWindowGovernorConfig {
    /// Size of this struct in the caller's header.
    pub struct_size: u32,
    /// Consecutive windows required to demote.
    pub demote_windows: u32,
    /// Consecutive windows required to promote.
    pub promote_windows: u32,
    /// Demotion threshold as a fraction of the current interval.
    pub demote_budget_fraction: f64,
    /// Promotion threshold as a fraction of the prospective interval.
    pub promote_budget_fraction: f64,
    /// Minimum seconds after a change before promotion.
    pub cooldown_s: f64,
}

const CONFIG_SIZE: u32 = core::mem::size_of::<OscilluxWindowGovernorConfig>() as u32;

impl Default for OscilluxWindowGovernorConfig {
    fn default() -> Self {
        let defaults = WindowGovernorConfig::default();
        Self {
            struct_size: CONFIG_SIZE,
            demote_windows: defaults.demote_windows,
            promote_windows: defaults.promote_windows,
            demote_budget_fraction: defaults.demote_budget_fraction,
            promote_budget_fraction: defaults.promote_budget_fraction,
            cooldown_s: defaults.cooldown_s,
        }
    }
}

/// Telemetry for one window. Flags are 0 or 1.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct OscilluxWindowGovernorSample {
    /// p95 duration in milliseconds, ignored when has_p95 is 0.
    pub p95_ms: f64,
    /// p99 duration in milliseconds, ignored when has_p99 is 0.
    pub p99_ms: f64,
    /// Current target interval in milliseconds.
    pub interval_ms: f64,
    /// Next step's interval in milliseconds, or zero if unavailable.
    pub promotion_budget_ms: f64,
    /// Monotonic seconds in the clock used for create or reset.
    pub now_s: f64,
    /// Whether p95 is present.
    pub has_p95: u32,
    /// Whether p99 is present.
    pub has_p99: u32,
    /// Whether delivery was starved.
    pub starved: u32,
    /// Whether delivery was dropping frames.
    pub dropping: u32,
}

/// The decision and post-record streak counts.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct OscilluxWindowGovernorResult {
    /// One of the OSCILLUX_WINDOW_GOVERNOR_* decisions.
    pub decision: u32,
    /// Whether the window exceeded the current budget (0 or 1).
    pub over_budget: u32,
    /// Consecutive over-budget windows.
    pub over_budget_streak: u32,
    /// Consecutive promotion-eligible windows.
    pub promotion_streak: u32,
    /// Windows held since the latest change.
    pub stable_streak: u32,
}

/// Opaque governor handle with host-owned lifetime.
pub struct OscilluxWindowGovernor {
    inner: WindowGovernor,
}

/// Writes the defaults to a config whose struct_size is already set.
///
/// # Safety
/// The pointer must be null or aligned and valid for a read of struct_size and, when that
/// matches the released size, an exclusive write of the full config.
#[no_mangle]
pub unsafe extern "C" fn oscillux_window_governor_config_default(
    out: *mut OscilluxWindowGovernorConfig,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        // Only struct_size is known to be present until it matches.
        if core::ptr::addr_of!((*out).struct_size).read() != CONFIG_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        out.write(OscilluxWindowGovernorConfig::default());
        OSCILLUX_OK
    })
}

/// Validates the configuration and starts a governor at now_s. Failure nulls the output handle.
///
/// # Safety
/// Each pointer must be null or aligned and valid: config for a read of struct_size and,
/// when that matches the released size, the full config, and out for one disjoint write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_window_governor_create(
    config: *const OscilluxWindowGovernorConfig,
    now_s: f64,
    out: *mut *mut OscilluxWindowGovernor,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        out.write(core::ptr::null_mut());
        if config.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        if core::ptr::addr_of!((*config).struct_size).read() != CONFIG_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let config = &*config;
        let core_config = WindowGovernorConfig {
            demote_windows: config.demote_windows,
            promote_windows: config.promote_windows,
            demote_budget_fraction: config.demote_budget_fraction,
            promote_budget_fraction: config.promote_budget_fraction,
            cooldown_s: config.cooldown_s,
        };
        match WindowGovernor::new(core_config, now_s) {
            Ok(inner) => {
                out.write(Box::into_raw(Box::new(OscilluxWindowGovernor { inner })));
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Frees the handle. Null is ignored.
///
/// # Safety
/// The handle must be null or a live handle from create, exclusively owned by this call.
#[no_mangle]
pub unsafe extern "C" fn oscillux_window_governor_destroy(handle: *mut OscilluxWindowGovernor) {
    guard_void(|| {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    })
}

/// Records one window and writes its result. Refusal leaves the handle and output unchanged.
///
/// # Safety
/// Each pointer must be null or aligned and valid for the declared object's storage. Sample
/// fields must be initialized except for percentiles whose presence flags are zero. The handle
/// must be live and exclusively owned by this call, and the output storage must be disjoint.
#[no_mangle]
pub unsafe extern "C" fn oscillux_window_governor_record(
    handle: *mut OscilluxWindowGovernor,
    sample: *const OscilluxWindowGovernorSample,
    out: *mut OscilluxWindowGovernorResult,
) -> i32 {
    guard(|| {
        if handle.is_null() || sample.is_null() || out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        let has_p95 = (*sample).has_p95;
        let has_p99 = (*sample).has_p99;
        let starved = (*sample).starved;
        let dropping = (*sample).dropping;
        if [has_p95, has_p99, starved, dropping]
            .iter()
            .any(|&flag| flag > 1)
        {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        // Read each percentile only when present, since a C caller may leave it uninitialized.
        let sample = WindowSample {
            p95_ms: (has_p95 == 1).then(|| core::ptr::addr_of!((*sample).p95_ms).read()),
            p99_ms: (has_p99 == 1).then(|| core::ptr::addr_of!((*sample).p99_ms).read()),
            interval_ms: (*sample).interval_ms,
            promotion_budget_ms: (*sample).promotion_budget_ms,
            now_s: (*sample).now_s,
            starved: starved == 1,
            dropping: dropping == 1,
        };
        match (*handle).inner.record(sample) {
            Ok(result) => {
                out.write(OscilluxWindowGovernorResult {
                    decision: result.decision as u32,
                    over_budget: u32::from(result.over_budget),
                    over_budget_streak: result.over_budget_streak,
                    promotion_streak: result.promotion_streak,
                    stable_streak: result.stable_streak,
                });
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Clears streaks and restarts the sample clock and promotion cooldown at now_s.
///
/// # Safety
/// The handle must be null or a live handle from create, exclusively owned by this call.
#[no_mangle]
pub unsafe extern "C" fn oscillux_window_governor_reset(
    handle: *mut OscilluxWindowGovernor,
    now_s: f64,
) -> i32 {
    guard(|| match handle.as_mut() {
        Some(handle) => match handle.inner.reset(now_s) {
            Ok(()) => OSCILLUX_OK,
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        },
        None => OSCILLUX_ERR_NULL,
    })
}
