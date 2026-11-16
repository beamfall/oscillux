// SPDX-License-Identifier: AGPL-3.0-only
//! Checked lengths before constructing borrowed C buffers.
use crate::{OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL};
fn length<T>(len: usize) -> Result<(), i32> {
    match len.checked_mul(core::mem::size_of::<T>()) {
        Some(bytes) if bytes <= isize::MAX as usize => Ok(()),
        _ => Err(OSCILLUX_ERR_INVALID_ARGUMENT),
    }
}
pub(crate) unsafe fn input<'a, T>(ptr: *const T, len: usize) -> Result<&'a [T], i32> {
    length::<T>(len)?;
    if len == 0 {
        Ok(&[])
    } else if ptr.is_null() {
        Err(OSCILLUX_ERR_NULL)
    } else {
        Ok(core::slice::from_raw_parts(ptr, len))
    }
}
pub(crate) unsafe fn output<'a, T>(ptr: *mut T, len: usize) -> Result<&'a mut [T], i32> {
    length::<T>(len)?;
    if len == 0 {
        Ok(&mut [])
    } else if ptr.is_null() {
        Err(OSCILLUX_ERR_NULL)
    } else {
        Ok(core::slice::from_raw_parts_mut(ptr, len))
    }
}
