// SPDX-License-Identifier: AGPL-3.0-only
//! C interface for the transition scheduler; creation allocates, every other call does not.
use crate::{guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
pub use oscillux_core::transition::{
    TransitionClock as OscilluxTransitionClock, TransitionStatus as OscilluxTransitionStatus,
};
use oscillux_core::transition::{TransitionConfig, TransitionScheduler};

/// C configuration for the scheduler. `struct_size` must be [`TRANSITION_CONFIG_SIZE`].
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscilluxTransitionConfig {
    /// Size of this struct as the caller's header declares it.
    pub struct_size: u32,
    /// Mirrors [`TransitionConfig::easing`].
    pub easing: u32,
    /// Mirrors [`TransitionConfig::beats_per_bar`].
    pub beats_per_bar: u32,
    /// Mirrors [`TransitionConfig::auto_advance_bars`].
    pub auto_advance_bars: u32,
    /// Mirrors [`TransitionConfig::duration_beats`].
    pub duration_beats: f64,
    /// Mirrors [`TransitionConfig::fallback_seconds`].
    pub fallback_seconds: f64,
    /// Mirrors [`TransitionConfig::pre_roll_seconds`].
    pub pre_roll_seconds: f64,
    /// Mirrors [`TransitionConfig::min_confidence`].
    pub min_confidence: f64,
}

/// The released size of [`OscilluxTransitionConfig`].
pub const TRANSITION_CONFIG_SIZE: u32 = core::mem::size_of::<OscilluxTransitionConfig>() as u32;

impl Default for OscilluxTransitionConfig {
    fn default() -> Self {
        let c = TransitionConfig::default();
        Self {
            struct_size: TRANSITION_CONFIG_SIZE,
            easing: c.easing,
            beats_per_bar: c.beats_per_bar,
            auto_advance_bars: c.auto_advance_bars,
            duration_beats: c.duration_beats,
            fallback_seconds: c.fallback_seconds,
            pre_roll_seconds: c.pre_roll_seconds,
            min_confidence: c.min_confidence,
        }
    }
}

impl OscilluxTransitionConfig {
    fn core_config(&self) -> TransitionConfig {
        TransitionConfig {
            easing: self.easing,
            beats_per_bar: self.beats_per_bar,
            auto_advance_bars: self.auto_advance_bars,
            duration_beats: self.duration_beats,
            fallback_seconds: self.fallback_seconds,
            pre_roll_seconds: self.pre_roll_seconds,
            min_confidence: self.min_confidence,
        }
    }
}

/// Opaque scheduler handle, allocated only by create and freed by destroy.
pub struct OscilluxTransition {
    inner: TransitionScheduler,
}

/// Writes the default config; `out->struct_size` must already hold the released size.
///
/// # Safety
/// `out` must be null, or aligned and valid for reads and writes of `struct_size` bytes.
#[no_mangle]
pub unsafe extern "C" fn oscillux_transition_config_default(
    out: *mut OscilluxTransitionConfig,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        // Only `struct_size` is known to be present until it matches; read it alone.
        if core::ptr::addr_of!((*out).struct_size).read() != TRANSITION_CONFIG_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        out.write(OscilluxTransitionConfig::default());
        OSCILLUX_OK
    })
}

/// Validates the config and creates an idle scheduler; failure nulls `out`.
///
/// # Safety
/// Both pointers must be null or valid: `config` for reads of its `struct_size` bytes, `out`
/// for one write, with disjoint storage.
#[no_mangle]
pub unsafe extern "C" fn oscillux_transition_create(
    config: *const OscilluxTransitionConfig,
    out: *mut *mut OscilluxTransition,
) -> i32 {
    guard(|| {
        let Some(out) = out.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out = core::ptr::null_mut();
        if config.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        if core::ptr::addr_of!((*config).struct_size).read() != TRANSITION_CONFIG_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        match TransitionScheduler::new((*config).core_config()) {
            Ok(inner) => {
                *out = Box::into_raw(Box::new(OscilluxTransition { inner }));
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Frees a live handle once; null is ignored.
///
/// # Safety
/// `handle` must be null or a live handle from create, exclusively owned by this call.
#[no_mangle]
pub unsafe extern "C" fn oscillux_transition_destroy(handle: *mut OscilluxTransition) {
    guard_void(|| {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    })
}

/// Schedules a switch at `clock->time_seconds`, replacing any current one, and writes the
/// schedule. Refused inputs change nothing and leave `out` unwritten.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects; the handle and `out`
/// must be exclusive and disjoint from the other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_transition_request(
    handle: *mut OscilluxTransition,
    clock: *const OscilluxTransitionClock,
    quantise: u32,
    max_wait_seconds: f64,
    out: *mut OscilluxTransitionStatus,
) -> i32 {
    guard(|| {
        let (Some(handle), Some(clock), Some(out)) =
            (handle.as_mut(), clock.as_ref(), out.as_mut())
        else {
            return OSCILLUX_ERR_NULL;
        };
        match handle.inner.request(clock, quantise, max_wait_seconds) {
            Ok(status) => {
                *out = status;
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Per-frame evaluation at `clock->time_seconds`, issuing an automatic request when
/// auto-advance is due. A non-finite time is refused, changes nothing and leaves `out`
/// unwritten.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects; the handle and `out`
/// must be exclusive and disjoint from the other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_transition_update(
    handle: *mut OscilluxTransition,
    clock: *const OscilluxTransitionClock,
    out: *mut OscilluxTransitionStatus,
) -> i32 {
    guard(|| {
        let (Some(handle), Some(clock), Some(out)) =
            (handle.as_mut(), clock.as_ref(), out.as_mut())
        else {
            return OSCILLUX_ERR_NULL;
        };
        match handle.inner.update(clock) {
            Ok(status) => {
                *out = status;
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Writes the schedule evaluated at `time_seconds` without changing it. Any time is
/// accepted; a NaN time reads as before the start.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects; `out` must be
/// exclusive and disjoint from the handle.
#[no_mangle]
pub unsafe extern "C" fn oscillux_transition_status(
    handle: *const OscilluxTransition,
    time_seconds: f64,
    out: *mut OscilluxTransitionStatus,
) -> i32 {
    guard(|| {
        let (Some(handle), Some(out)) = (handle.as_ref(), out.as_mut()) else {
            return OSCILLUX_ERR_NULL;
        };
        *out = handle.inner.status(time_seconds);
        OSCILLUX_OK
    })
}

/// Returns the scheduler to idle and restarts the auto-advance count.
///
/// # Safety
/// `handle` must be null or an exclusively accessible live handle.
#[no_mangle]
pub unsafe extern "C" fn oscillux_transition_reset(handle: *mut OscilluxTransition) -> i32 {
    guard(|| match handle.as_mut() {
        Some(handle) => {
            handle.inner.reset();
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}
