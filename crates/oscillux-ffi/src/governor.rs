// SPDX-License-Identifier: AGPL-3.0-only
//! C interface for governor; creation allocates, steady-state calls do not.
use crate::{guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use oscillux_core::governor::Governor;
pub use oscillux_core::governor::GovernorConfig as OscilluxGovernorConfig;
/// Opaque governor handle.
pub struct OscilluxGovernor {
    inner: Governor,
}

/// Writes default configuration.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_governor_config_default(out: *mut OscilluxGovernorConfig) -> i32 {
    guard(|| match out.as_mut() {
        Some(out) => {
            *out = OscilluxGovernorConfig::default();
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}

/// Validates configuration and creates a handle; errors null the output handle.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_governor_create(
    config: *const OscilluxGovernorConfig,
    out: *mut *mut OscilluxGovernor,
) -> i32 {
    guard(|| {
        let Some(out) = out.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out = core::ptr::null_mut();
        let Some(config) = config.as_ref() else {
            return OSCILLUX_ERR_NULL;
        };
        match Governor::new(*config) {
            Ok(inner) => {
                *out = Box::into_raw(Box::new(OscilluxGovernor { inner }));
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Frees a live handle once; null is ignored.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_governor_destroy(handle: *mut OscilluxGovernor) {
    guard_void(|| {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    })
}

pub use oscillux_core::governor::GovernorStats as OscilluxGovernorStats;

/// Records a duration. Invalid/nonpositive/pause samples are ignored without state changes.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_governor_record(
    handle: *mut OscilluxGovernor,
    frame_ms: f64,
    out: *mut OscilluxGovernorStats,
) -> i32 {
    guard(|| {
        let (Some(handle), Some(out)) = (handle.as_mut(), out.as_mut()) else {
            return OSCILLUX_ERR_NULL;
        };
        *out = handle.inner.record(frame_ms);
        OSCILLUX_OK
    })
}

/// Resets history; requested level is clamped to the configured maximum.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_governor_reset(handle: *mut OscilluxGovernor, level: u32) -> i32 {
    guard(|| match handle.as_mut() {
        Some(handle) => {
            handle.inner.reset(level);
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}
