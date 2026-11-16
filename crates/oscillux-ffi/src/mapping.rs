// SPDX-License-Identifier: AGPL-3.0-only
//! C interface for mapping; creation allocates, steady-state calls do not.
use crate::{guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
pub use oscillux_core::mapping::MappingConfig as OscilluxMappingConfig;
use oscillux_core::mapping::{LevelSource, Mapper, LEVELS_ABSOLUTE, LEVELS_RELATIVE};
pub use oscillux_core::mapping::{
    LEVELS_ABSOLUTE as OSCILLUX_MAPPING_LEVELS_ABSOLUTE,
    LEVELS_RELATIVE as OSCILLUX_MAPPING_LEVELS_RELATIVE,
};
/// Opaque mapper handle.
pub struct OscilluxMapper {
    inner: Mapper,
}

/// Writes default configuration.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_mapping_config_default(out: *mut OscilluxMappingConfig) -> i32 {
    guard(|| match out.as_mut() {
        Some(out) => {
            *out = OscilluxMappingConfig::default();
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}

/// Writes the default configuration with hop and loudness reference taken from a valid DSP
/// configuration; an invalid one leaves `*out` unchanged.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_mapping_config_from_dsp(
    dsp: *const DspConfig,
    out: *mut OscilluxMappingConfig,
) -> i32 {
    guard(|| match (dsp.as_ref(), out.as_mut()) {
        (Some(dsp), Some(out)) => match dsp.validate() {
            Ok(()) => {
                *out = OscilluxMappingConfig::for_dsp(dsp);
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        },
        _ => OSCILLUX_ERR_NULL,
    })
}

/// Validates configuration and creates a handle; errors null the output handle.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_mapping_create(
    config: *const OscilluxMappingConfig,
    out: *mut *mut OscilluxMapper,
) -> i32 {
    guard(|| {
        let Some(out) = out.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out = core::ptr::null_mut();
        let Some(config) = config.as_ref() else {
            return OSCILLUX_ERR_NULL;
        };
        match Mapper::new(*config) {
            Ok(inner) => {
                *out = Box::into_raw(Box::new(OscilluxMapper { inner }));
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
pub unsafe extern "C" fn oscillux_mapping_destroy(handle: *mut OscilluxMapper) {
    guard_void(|| {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    })
}

use crate::dsp::{frame_ext_stride, OscilluxDspFrameExt, EXT_LEVELS_END};
use oscillux_core::dsp::{DspConfig, DspFrame};
pub use oscillux_core::mapping::Mapped as OscilluxMapped;

/// Clears previous level so the next valid frame initializes its envelope.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_mapping_reset(handle: *mut OscilluxMapper) -> i32 {
    guard(|| match handle.as_mut() {
        Some(handle) => {
            handle.inner.reset();
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}

/// Selects what the bass, mid and treble values and the spectrum are computed from:
/// `OSCILLUX_MAPPING_LEVELS_ABSOLUTE` (0, the default) or `_RELATIVE` (1). Any other value is
/// refused and leaves the source unchanged; reset keeps it.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_mapping_set_level_source(
    handle: *mut OscilluxMapper,
    source: u32,
) -> i32 {
    guard(|| {
        let Some(handle) = handle.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        let source = match source {
            LEVELS_ABSOLUTE => LevelSource::Absolute,
            LEVELS_RELATIVE => LevelSource::Relative,
            _ => return OSCILLUX_ERR_INVALID_ARGUMENT,
        };
        handle.inner.set_level_source(source);
        OSCILLUX_OK
    })
}

/// Maps a frame. unavailable is 0 or 1; errors leave output and envelope unchanged. Without
/// descriptors the flux and centroid values keep their deprecated proxies (the broadband onset
/// and the band-index centroid); [`oscillux_mapping_process_ext`] maps the descriptors.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_mapping_process(
    handle: *mut OscilluxMapper,
    frame: *const DspFrame,
    unavailable: u32,
    out: *mut OscilluxMapped,
) -> i32 {
    guard(|| {
        if unavailable > 1 {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let (Some(handle), Some(frame), Some(out)) =
            (handle.as_mut(), frame.as_ref(), out.as_mut())
        else {
            return OSCILLUX_ERR_NULL;
        };
        match handle.inner.map(frame, unavailable == 1) {
            Ok(value) => {
                *out = value;
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// [`oscillux_mapping_process`] that also maps the descriptors in `*ext`, the element that
/// `oscillux_dsp_push_ext_f32` or `_f64` wrote beside `*frame`, into the flux and centroid
/// values. A null `ext` maps as `oscillux_mapping_process`. An `ext` whose `struct_size` is not
/// a released size or whose `reserved` is not 0 is refused like an invalid frame. With the
/// relative level source, the bass, mid and treble values and the spectrum come from
/// `ext->levels.relative_bands`; available input whose `ext` is null or ends before the levels
/// section is refused.
///
/// # Safety
/// As [`oscillux_mapping_process`]; `ext` must be null or valid for a read of `struct_size`
/// bytes.
#[no_mangle]
pub unsafe extern "C" fn oscillux_mapping_process_ext(
    handle: *mut OscilluxMapper,
    frame: *const DspFrame,
    ext: *const OscilluxDspFrameExt,
    unavailable: u32,
    out: *mut OscilluxMapped,
) -> i32 {
    guard(|| {
        if unavailable > 1 {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let (Some(handle), Some(frame), Some(out)) =
            (handle.as_mut(), frame.as_ref(), out.as_mut())
        else {
            return OSCILLUX_ERR_NULL;
        };
        let (descriptors, levels) = if ext.is_null() {
            (None, None)
        } else {
            match frame_ext_stride(ext, 1) {
                // Every released size holds the descriptors section.
                Ok(size) => (
                    Some(core::ptr::addr_of!((*ext).descriptors).read()),
                    (size >= EXT_LEVELS_END).then(|| core::ptr::addr_of!((*ext).levels).read()),
                ),
                Err(status) => return status,
            }
        };
        match handle.inner.map_ext(
            frame,
            descriptors.as_ref(),
            levels.as_ref(),
            unavailable == 1,
        ) {
            Ok(value) => {
                *out = value;
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}
