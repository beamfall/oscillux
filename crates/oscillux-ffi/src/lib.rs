// SPDX-License-Identifier: AGPL-3.0-only
//! C interface to the Oscillux core. `ffi/include/oscillux.h` declares every export.
//!
//! Every export that can panic returns through [`guard`] or [`guard_void`], so a panic never
//! unwinds into C. `oscillux_limiter_process` also does non-panicking null checks and its
//! fail-safe write outside the guard; [`oscillux_abi_version`], [`oscillux_version`] and
//! [`oscillux_status_string`] only return constants.
//!
//! The crate keeps no global mutable state: handles own all state, which is why `oscillux.h`
//! can promise that distinct handles are independent across threads.
#![warn(missing_docs)]

use core::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

pub mod beatgrid;
pub mod dsp;
pub mod limiter;
pub mod overlay;

/// Version of the C interface; bumped on every incompatible change (a changed signature,
/// struct layout or status value, or a removed export). Added exports keep the version but
/// take a new release [`VERSION`]; `docs/api-stability.md` gives the policy.
pub const ABI_VERSION: u32 = 1;

/// Major part of the crate version in the workspace `Cargo.toml`; `OSCILLUX_VERSION_MAJOR`.
pub const VERSION_MAJOR: u32 = version_part(env!("CARGO_PKG_VERSION_MAJOR"), 0xffff);
/// Minor part of the crate version; `OSCILLUX_VERSION_MINOR`.
pub const VERSION_MINOR: u32 = version_part(env!("CARGO_PKG_VERSION_MINOR"), 0xff);
/// Patch part of the crate version; `OSCILLUX_VERSION_PATCH`.
pub const VERSION_PATCH: u32 = version_part(env!("CARGO_PKG_VERSION_PATCH"), 0xff);
/// `VERSION_MAJOR << 16 | VERSION_MINOR << 8 | VERSION_PATCH`; `OSCILLUX_VERSION`.
pub const VERSION: u32 = (VERSION_MAJOR << 16) | (VERSION_MINOR << 8) | VERSION_PATCH;

/// Parses one decimal version part at compile time; a part above `max` fails the build, since
/// it would not fit its field of [`VERSION`].
const fn version_part(digits: &str, max: u32) -> u32 {
    let digits = digits.as_bytes();
    assert!(!digits.is_empty(), "empty version part");
    let mut value = 0u32;
    let mut i = 0;
    while i < digits.len() {
        assert!(digits[i].is_ascii_digit(), "non-decimal version part");
        value = value * 10 + (digits[i] - b'0') as u32;
        assert!(value <= max, "version part does not fit OSCILLUX_VERSION");
        i += 1;
    }
    value
}

/// Status: success.
pub const OSCILLUX_OK: i32 = 0;
/// Status: a required pointer argument was null.
pub const OSCILLUX_ERR_NULL: i32 = -1;
/// Status: an argument or configuration value was out of range.
pub const OSCILLUX_ERR_INVALID_ARGUMENT: i32 = -2;
/// Status: an internal panic was caught at the boundary.
pub const OSCILLUX_ERR_PANIC: i32 = -3;

/// Returns [`ABI_VERSION`].
#[no_mangle]
pub extern "C" fn oscillux_abi_version() -> u32 {
    ABI_VERSION
}

/// Returns [`VERSION`], the release version this library was built as.
#[no_mangle]
pub extern "C" fn oscillux_version() -> u32 {
    VERSION
}

/// Returns a static, NUL-terminated description of `status`; never null. Cannot panic and does
/// not allocate.
#[no_mangle]
pub extern "C" fn oscillux_status_string(status: i32) -> *const c_char {
    let text = match status {
        OSCILLUX_OK => c"ok",
        OSCILLUX_ERR_NULL => c"null pointer argument",
        OSCILLUX_ERR_INVALID_ARGUMENT => c"invalid argument",
        OSCILLUX_ERR_PANIC => c"internal panic; destroy the handle",
        _ => c"unknown status",
    };
    text.as_ptr()
}

/// Runs `body`, turning a panic into [`OSCILLUX_ERR_PANIC`]. State is not rolled back, so
/// `oscillux.h` requires callers to destroy a handle after a call on it returns that status.
pub(crate) fn guard(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(OSCILLUX_ERR_PANIC)
}

/// Runs `body`, swallowing a panic.
pub(crate) fn guard_void(body: impl FnOnce()) {
    let _ = catch_unwind(AssertUnwindSafe(body));
}

mod buffers;
pub mod curves;
pub mod governor;
pub mod mapping;
pub mod packing;
pub mod reaction;
pub mod transition;

// CD+G lyric graphics (OSC-CDG).
pub mod cdg;
