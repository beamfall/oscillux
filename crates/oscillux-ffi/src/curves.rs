// SPDX-License-Identifier: AGPL-3.0-only
//! C interface for curve; creation allocates, steady-state calls do not.
use crate::{guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use oscillux_core::curves::Curve;
pub use oscillux_core::curves::Curve as OscilluxCurveConfig;
/// Opaque curve handle.
pub struct OscilluxCurve {
    inner: Curve,
}

/// Writes default configuration.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_curve_config_default(out: *mut OscilluxCurveConfig) -> i32 {
    guard(|| match out.as_mut() {
        Some(out) => {
            *out = OscilluxCurveConfig::default();
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
pub unsafe extern "C" fn oscillux_curve_create(
    config: *const OscilluxCurveConfig,
    out: *mut *mut OscilluxCurve,
) -> i32 {
    guard(|| {
        let Some(out) = out.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out = core::ptr::null_mut();
        let Some(config) = config.as_ref() else {
            return OSCILLUX_ERR_NULL;
        };
        match config.validate().map(|()| *config) {
            Ok(inner) => {
                *out = Box::into_raw(Box::new(OscilluxCurve { inner }));
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
pub unsafe extern "C" fn oscillux_curve_destroy(handle: *mut OscilluxCurve) {
    guard_void(|| {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    })
}

pub use oscillux_core::curves::CurveInput as OscilluxCurveInput;

/// Evaluates without allocation; failure leaves output unchanged.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_curve_evaluate(
    handle: *const OscilluxCurve,
    input: *const OscilluxCurveInput,
    out: *mut f64,
) -> i32 {
    guard(|| {
        let (Some(handle), Some(input), Some(out)) =
            (handle.as_ref(), input.as_ref(), out.as_mut())
        else {
            return OSCILLUX_ERR_NULL;
        };
        match handle.inner.evaluate(input) {
            Ok(value) => {
                *out = value;
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}
