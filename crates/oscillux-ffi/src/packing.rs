// SPDX-License-Identifier: AGPL-3.0-only
//! Caller-defined uniform block layouts; values are narrowed to little-endian float32.
use crate::mapping::OscilluxMapped;
use crate::{
    buffers, guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK,
};
pub use oscillux_core::packing::Field as OscilluxUniformField;
use oscillux_core::packing::Packer;
/// Opaque packer handle.
pub struct OscilluxPacker {
    inner: Packer,
}

/// Validates bounded field geometry and rejects overlap before creating the layout.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_packer_create(
    fields: *const OscilluxUniformField,
    field_count: usize,
    block_size: usize,
    out: *mut *mut OscilluxPacker,
) -> i32 {
    guard(|| {
        let Some(out) = out.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out = core::ptr::null_mut();
        if field_count > 256 {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let fields = match buffers::input(fields, field_count) {
            Ok(fields) => fields,
            Err(code) => return code,
        };
        match Packer::new(fields, block_size) {
            Ok(inner) => {
                *out = Box::into_raw(Box::new(OscilluxPacker { inner }));
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
pub unsafe extern "C" fn oscillux_packer_destroy(handle: *mut OscilluxPacker) {
    guard_void(|| {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    })
}

/// Writes the block with zero padding. Errors leave all output bytes unchanged; buffers may not overlap.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_packer_pack(
    handle: *const OscilluxPacker,
    mapped: *const OscilluxMapped,
    host: *const f64,
    host_count: usize,
    out: *mut u8,
    out_capacity: usize,
) -> i32 {
    guard(|| {
        let (Some(handle), Some(mapped)) = (handle.as_ref(), mapped.as_ref()) else {
            return OSCILLUX_ERR_NULL;
        };
        let host = match buffers::input(host, host_count) {
            Ok(v) => v,
            Err(code) => return code,
        };
        let out = match buffers::output(out, out_capacity) {
            Ok(v) => v,
            Err(code) => return code,
        };
        match handle
            .inner
            .pack(&mapped.values, &mapped.spectrum, host, out)
        {
            Ok(()) => OSCILLUX_OK,
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}
