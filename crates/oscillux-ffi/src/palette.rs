// SPDX-License-Identifier: AGPL-3.0-only
//! C interface for the vivid colour mode's palette tour; no call allocates.
use crate::{guard, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use oscillux_core::palette;

/// `OSCILLUX_PALETTE_TOUR_COUNT`.
pub const OSCILLUX_PALETTE_TOUR_COUNT: u32 = palette::TOUR_COUNT;
/// `OSCILLUX_PALETTE_TOUR_SECONDS`.
pub const OSCILLUX_PALETTE_TOUR_SECONDS: u32 = palette::TOUR_SECONDS;

/// Writes the `palette` uniform of the tour at `time_seconds` to `out[0..4]`. Refuses a
/// non-finite argument with `out` unchanged.
///
/// # Safety
/// `out` must be null or valid and aligned for writes of four `f64`.
#[no_mangle]
pub unsafe extern "C" fn oscillux_palette_tour(
    time_seconds: f64,
    offset: f64,
    out: *mut f64,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        if !time_seconds.is_finite() || !offset.is_finite() {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        out.cast::<[f64; 4]>()
            .write(palette::tour(time_seconds, offset));
        OSCILLUX_OK
    })
}

/// Writes the vivid mode's present-pass saturation and vibrance to `out[0]` and `out[1]`.
///
/// # Safety
/// `out` must be null or valid and aligned for writes of two `f64`.
#[no_mangle]
pub unsafe extern "C" fn oscillux_palette_vivid_present(out: *mut f64) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        out.cast::<[f64; 2]>()
            .write([palette::VIVID_SATURATION, palette::VIVID_VIBRANCE]);
        OSCILLUX_OK
    })
}
