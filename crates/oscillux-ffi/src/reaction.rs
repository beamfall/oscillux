// SPDX-License-Identifier: AGPL-3.0-only
//! C interface for the reaction sampler; creation allocates, steady-state calls do not.
use crate::mapping::OscilluxMapped;
use crate::{guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use oscillux_core::dsp::Beat as OscilluxDspBeat;
pub use oscillux_core::reaction::BeatClock as OscilluxBeatClock;
pub use oscillux_core::reaction::Reaction as OscilluxReaction;
pub use oscillux_core::reaction::ReactionConfig as OscilluxReactionConfig;
pub use oscillux_core::reaction::MAX_CAPACITY as OSCILLUX_REACTION_MAX_CAPACITY;
use oscillux_core::reaction::{ReactionError, ReactionSampler, CONFIG_SIZE};

/// Opaque reaction sampler handle.
pub struct OscilluxReactionSampler {
    inner: ReactionSampler,
}

fn status(result: Result<(), ReactionError>) -> i32 {
    match result {
        Ok(()) => OSCILLUX_OK,
        Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
    }
}

/// Writes the default configuration with the analysis latencies of DSP `behavior_version` at
/// `sample_rate_hz`. `out->struct_size` must already be a released size; a refused size,
/// version or rate leaves `*out` unchanged.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_reaction_config_default(
    behavior_version: u32,
    sample_rate_hz: u32,
    out: *mut OscilluxReactionConfig,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        // Only `struct_size` is known to be present until it matches; read it alone.
        if core::ptr::addr_of!((*out).struct_size).read() != CONFIG_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        match OscilluxReactionConfig::for_dsp(behavior_version, sample_rate_hz) {
            Some(config) => {
                *out = config;
                OSCILLUX_OK
            }
            None => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Validates configuration and creates a handle; errors null the output handle.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_reaction_create(
    config: *const OscilluxReactionConfig,
    out: *mut *mut OscilluxReactionSampler,
) -> i32 {
    guard(|| {
        let Some(out) = out.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out = core::ptr::null_mut();
        if config.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        if core::ptr::addr_of!((*config).struct_size).read() != CONFIG_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        match ReactionSampler::new(*config) {
            Ok(inner) => {
                *out = Box::into_raw(Box::new(OscilluxReactionSampler { inner }));
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
pub unsafe extern "C" fn oscillux_reaction_destroy(handle: *mut OscilluxReactionSampler) {
    guard_void(|| {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    })
}

/// Forgets every hop, peak, the beat clock and the beat state; keeps the configuration.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_reaction_reset(handle: *mut OscilluxReactionSampler) -> i32 {
    guard(|| match handle.as_mut() {
        Some(handle) => {
            handle.inner.reset();
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}

/// Queues one mapped hop whose analysis window ends at `media_time_ms`, with the tracker output
/// beside it (`beat` may be null). Invalid input or a full queue changes nothing.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_reaction_push(
    handle: *mut OscilluxReactionSampler,
    media_time_ms: f64,
    mapped: *const OscilluxMapped,
    beat: *const OscilluxDspBeat,
) -> i32 {
    guard(|| match (handle.as_mut(), mapped.as_ref()) {
        (Some(handle), Some(mapped)) => {
            status(handle.inner.push(media_time_ms, mapped, beat.as_ref()))
        }
        _ => OSCILLUX_ERR_NULL,
    })
}

/// Drives the beat outputs from a host clock; null returns to the tracker.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_reaction_set_beat_clock(
    handle: *mut OscilluxReactionSampler,
    clock: *const OscilluxBeatClock,
) -> i32 {
    guard(|| match handle.as_mut() {
        Some(handle) => status(handle.inner.set_beat_clock(clock.as_ref())),
        None => OSCILLUX_ERR_NULL,
    })
}

/// Samples the values seen at the photon time of a frame sampled at host media time
/// `time_ms`; a non-finite time leaves state and `*out` unchanged.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_reaction_sample(
    handle: *mut OscilluxReactionSampler,
    time_ms: f64,
    out: *mut OscilluxReaction,
) -> i32 {
    guard(|| match (handle.as_mut(), out.as_mut()) {
        (Some(handle), Some(out)) => match handle.inner.sample(time_ms) {
            Ok(reaction) => {
                *out = reaction;
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        },
        _ => OSCILLUX_ERR_NULL,
    })
}

/// Writes the number of queued hops to `*out`.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_reaction_queued(
    handle: *const OscilluxReactionSampler,
    out: *mut u32,
) -> i32 {
    guard(|| match (handle.as_ref(), out.as_mut()) {
        (Some(handle), Some(out)) => {
            *out = handle.inner.queued() as u32;
            OSCILLUX_OK
        }
        _ => OSCILLUX_ERR_NULL,
    })
}
