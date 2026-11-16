// SPDX-License-Identifier: AGPL-3.0-only
//! C interface to the overlay contract (OSC-OVERLAY): regions where host UI sits over the
//! visuals, packed into the std140 `OverlayUniforms` block the present pass reads. Every call
//! is pure, allocation-free and lock-free.

/// One overlay region; an array element, so it carries no `struct_size`.
pub use oscillux_core::overlay::OverlayRegion as OscilluxOverlayRegion;
use oscillux_core::overlay::{
    pack, OverlayConfig, MAX_OVERLAY_REGIONS, MODE_BLUR, MODE_DAMP_FLASH, MODE_DAMP_MOTION,
    MODE_DARK_TEXT, MODE_DESATURATE, MODE_LIGHT_TEXT, OVERLAY_UNIFORMS_SIZE,
};

use crate::limiter::{released, OscilluxFlashConfig};
use crate::{guard, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};

/// `OSCILLUX_OVERLAY_MAX_REGIONS`.
pub const OSCILLUX_OVERLAY_MAX_REGIONS: u32 = MAX_OVERLAY_REGIONS as u32;
/// `OSCILLUX_OVERLAY_UNIFORMS_SIZE`.
pub const OSCILLUX_OVERLAY_UNIFORMS_SIZE: u32 = OVERLAY_UNIFORMS_SIZE as u32;
/// `OSCILLUX_OVERLAY_MODE_LIGHT_TEXT`.
pub const OSCILLUX_OVERLAY_MODE_LIGHT_TEXT: u32 = MODE_LIGHT_TEXT;
/// `OSCILLUX_OVERLAY_MODE_DARK_TEXT`.
pub const OSCILLUX_OVERLAY_MODE_DARK_TEXT: u32 = MODE_DARK_TEXT;
/// `OSCILLUX_OVERLAY_MODE_DESATURATE`.
pub const OSCILLUX_OVERLAY_MODE_DESATURATE: u32 = MODE_DESATURATE;
/// `OSCILLUX_OVERLAY_MODE_BLUR`.
pub const OSCILLUX_OVERLAY_MODE_BLUR: u32 = MODE_BLUR;
/// `OSCILLUX_OVERLAY_MODE_DAMP_MOTION`.
pub const OSCILLUX_OVERLAY_MODE_DAMP_MOTION: u32 = MODE_DAMP_MOTION;
/// `OSCILLUX_OVERLAY_MODE_DAMP_FLASH`.
pub const OSCILLUX_OVERLAY_MODE_DAMP_FLASH: u32 = MODE_DAMP_FLASH;

/// C mirror of [`OverlayConfig`]; flags are 0 or 1 and other values are refused.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscilluxOverlayConfig {
    /// Size of this struct as the caller's header declares it; must be
    /// [`OVERLAY_CONFIG_SIZE`].
    pub struct_size: u32,
    /// Mirrors [`OverlayConfig::reduced_motion`].
    pub reduced_motion: u32,
    /// Mirrors [`OverlayConfig::premultiplied_alpha`].
    pub premultiplied_alpha: u32,
    /// Mirrors [`OverlayConfig::output_levels`].
    pub output_levels: u32,
    /// Mirrors [`OverlayConfig::viewport_width`].
    pub viewport_width: f64,
    /// Mirrors [`OverlayConfig::viewport_height`].
    pub viewport_height: f64,
    /// Mirrors [`OverlayConfig::contrast_ratio`].
    pub contrast_ratio: f64,
    /// Mirrors [`OverlayConfig::intensity`].
    pub intensity: f64,
    /// Mirrors [`OverlayConfig::frame_interval_ms`].
    pub frame_interval_ms: f64,
    /// Mirrors [`OverlayConfig::alpha`].
    pub alpha: f64,
}

/// The released size of [`OscilluxOverlayConfig`].
pub const OVERLAY_CONFIG_SIZE: u32 = core::mem::size_of::<OscilluxOverlayConfig>() as u32;

impl Default for OscilluxOverlayConfig {
    fn default() -> Self {
        let c = OverlayConfig::DEFAULT;
        Self {
            struct_size: OVERLAY_CONFIG_SIZE,
            reduced_motion: c.reduced_motion.into(),
            premultiplied_alpha: c.premultiplied_alpha.into(),
            output_levels: c.output_levels,
            viewport_width: c.viewport_width,
            viewport_height: c.viewport_height,
            contrast_ratio: c.contrast_ratio,
            intensity: c.intensity,
            frame_interval_ms: c.frame_interval_ms,
            alpha: c.alpha,
        }
    }
}

fn flag(v: u32) -> Result<bool, i32> {
    match v {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(OSCILLUX_ERR_INVALID_ARGUMENT),
    }
}

impl OscilluxOverlayConfig {
    fn core_config(&self) -> Result<OverlayConfig, i32> {
        if self.struct_size != OVERLAY_CONFIG_SIZE {
            return Err(OSCILLUX_ERR_INVALID_ARGUMENT);
        }
        let config = OverlayConfig {
            viewport_width: self.viewport_width,
            viewport_height: self.viewport_height,
            contrast_ratio: self.contrast_ratio,
            intensity: self.intensity,
            frame_interval_ms: self.frame_interval_ms,
            alpha: self.alpha,
            output_levels: self.output_levels,
            reduced_motion: flag(self.reduced_motion)?,
            premultiplied_alpha: flag(self.premultiplied_alpha)?,
        };
        config
            .validate()
            .map_err(|_| OSCILLUX_ERR_INVALID_ARGUMENT)?;
        Ok(config)
    }
}

/// Reads a caller's config: `struct_size` alone first, then the whole struct once it matches.
///
/// # Safety
/// `config` must be non-null and valid for reads of its `struct_size` bytes.
unsafe fn read_config(config: *const OscilluxOverlayConfig) -> Result<OverlayConfig, i32> {
    let size = core::ptr::addr_of!((*config).struct_size).read();
    if size != OVERLAY_CONFIG_SIZE {
        return Err(OSCILLUX_ERR_INVALID_ARGUMENT);
    }
    config.read().core_config()
}

/// The caller's region array, refusing more than the maximum.
///
/// # Safety
/// `regions` must be null with `count` 0, or valid for reads of `count` regions.
pub(crate) unsafe fn regions<'a>(
    regions: *const OscilluxOverlayRegion,
    count: usize,
) -> Result<&'a [OscilluxOverlayRegion], i32> {
    if count > MAX_OVERLAY_REGIONS {
        return Err(OSCILLUX_ERR_INVALID_ARGUMENT);
    }
    if count == 0 {
        return Ok(&[]);
    }
    if regions.is_null() {
        return Err(OSCILLUX_ERR_NULL);
    }
    Ok(core::slice::from_raw_parts(regions, count))
}

/// Writes the default config through `out->struct_size` bytes, which must already hold
/// [`OVERLAY_CONFIG_SIZE`].
///
/// # Safety
/// `out` must be null, or aligned and valid for reads and writes of `struct_size` bytes.
#[no_mangle]
pub unsafe extern "C" fn oscillux_overlay_config_default(out: *mut OscilluxOverlayConfig) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        let size = core::ptr::addr_of!((*out).struct_size).read();
        if size != OVERLAY_CONFIG_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        out.write(OscilluxOverlayConfig::default());
        OSCILLUX_OK
    })
}

/// Packs the `OverlayUniforms` block into the first [`OSCILLUX_OVERLAY_UNIFORMS_SIZE`] bytes of
/// `out`; bytes beyond are not touched. Refuses invalid input or a short buffer with
/// `out` unchanged.
///
/// # Safety
/// `config` must be null or valid for reads of its `struct_size` bytes; `regions` null with
/// `count` 0 or valid for `count` reads; `out` valid for `capacity` writes and disjoint from
/// the inputs.
#[no_mangle]
pub unsafe extern "C" fn oscillux_overlay_pack(
    config: *const OscilluxOverlayConfig,
    regions_ptr: *const OscilluxOverlayRegion,
    count: usize,
    out: *mut u8,
    capacity: usize,
) -> i32 {
    guard(|| {
        if config.is_null() || out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        let config = match read_config(config) {
            Ok(c) => c,
            Err(status) => return status,
        };
        let list = match regions(regions_ptr, count) {
            Ok(r) => r,
            Err(status) => return status,
        };
        if capacity < OVERLAY_UNIFORMS_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let mut block = [0u8; OVERLAY_UNIFORMS_SIZE];
        if pack(&config, list, &mut block).is_err() {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        core::ptr::copy_nonoverlapping(block.as_ptr(), out, OVERLAY_UNIFORMS_SIZE);
        OSCILLUX_OK
    })
}

/// Writes the presentation intensity visuals read: the config's intensity, halved under
/// reduced motion.
///
/// # Safety
/// `config` must be null or valid for reads of its `struct_size` bytes; `out` null or valid for
/// one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_overlay_presentation_intensity(
    config: *const OscilluxOverlayConfig,
    out: *mut f64,
) -> i32 {
    guard(|| {
        if config.is_null() || out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        match read_config(config) {
            Ok(c) => {
                out.write(c.presentation_intensity());
                OSCILLUX_OK
            }
            Err(status) => status,
        }
    })
}

/// Tightens `*inout`, a flash config of any released size, for the overlay config's reduced-motion
/// preference: at most 1 general and 1 red flash a second over at most 0.1 of a field. Never
/// loosens a value; without reduced motion `*inout` is unchanged. Refuses an invalid flash
/// config with `*inout` unchanged.
///
/// # Safety
/// `config` must be null or valid for reads of its `struct_size` bytes; `inout` null or valid
/// for reads and writes of its `struct_size` bytes, a released [`OscilluxFlashConfig`] size.
#[no_mangle]
pub unsafe extern "C" fn oscillux_overlay_flash_config(
    config: *const OscilluxOverlayConfig,
    inout: *mut OscilluxFlashConfig,
) -> i32 {
    guard(|| {
        if config.is_null() || inout.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        let config = match read_config(config) {
            Ok(c) => c,
            Err(status) => return status,
        };
        // Only `struct_size` is known to be present until it is a released size; read it
        // alone, then that many bytes over the defaults, and write back the same bytes.
        let size = core::ptr::addr_of!((*inout).struct_size).read();
        if !released(size) {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let mut current = OscilluxFlashConfig::default();
        core::ptr::copy_nonoverlapping(
            inout.cast::<u8>(),
            (&mut current as *mut OscilluxFlashConfig).cast::<u8>(),
            size as usize,
        );
        let Ok(base) = current.core_config() else {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        };
        let tight = config.flash_config(base);
        let written = OscilluxFlashConfig {
            max_field_area: tight.max_field_area,
            max_flash_hz: tight.max_flash_hz,
            max_red_flashes: tight.max_red_flashes,
            ..current
        };
        core::ptr::copy_nonoverlapping(
            (&written as *const OscilluxFlashConfig).cast::<u8>(),
            inout.cast::<u8>(),
            size as usize,
        );
        OSCILLUX_OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pack_through_c_matches_core_and_refuses_bad_sizes() {
        let mut config = OscilluxOverlayConfig {
            struct_size: OVERLAY_CONFIG_SIZE,
            ..OscilluxOverlayConfig::default()
        };
        assert_eq!(unsafe { oscillux_overlay_config_default(&mut config) }, 0);
        let region = OscilluxOverlayRegion {
            x: 0.1,
            y: 0.8,
            width: 0.8,
            height: 0.15,
            strength: 1.0,
            mode: MODE_LIGHT_TEXT,
            ..OscilluxOverlayRegion::default()
        };
        let mut out = [7u8; 330];
        let status = unsafe { oscillux_overlay_pack(&config, &region, 1, out.as_mut_ptr(), 330) };
        assert_eq!(status, OSCILLUX_OK);
        let mut want = [0u8; OVERLAY_UNIFORMS_SIZE];
        pack(&OverlayConfig::DEFAULT, &[region], &mut want).unwrap();
        assert_eq!(&out[..320], &want[..]);
        assert!(out[320..].iter().all(|&b| b == 7));
        let short = unsafe { oscillux_overlay_pack(&config, &region, 1, out.as_mut_ptr(), 319) };
        assert_eq!(short, OSCILLUX_ERR_INVALID_ARGUMENT);
        let null =
            unsafe { oscillux_overlay_pack(&config, core::ptr::null(), 1, out.as_mut_ptr(), 330) };
        assert_eq!(null, OSCILLUX_ERR_NULL);
        let bad = OscilluxOverlayConfig {
            reduced_motion: 2,
            ..config
        };
        let flagged = unsafe { oscillux_overlay_pack(&bad, &region, 1, out.as_mut_ptr(), 330) };
        assert_eq!(flagged, OSCILLUX_ERR_INVALID_ARGUMENT);
        let sized = OscilluxOverlayConfig {
            struct_size: 8,
            ..config
        };
        assert_eq!(
            unsafe { oscillux_overlay_config_default(&mut sized.clone()) },
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
    }

    #[test]
    fn reduced_motion_tightens_flash_config_and_intensity() {
        let config = OscilluxOverlayConfig {
            reduced_motion: 1,
            intensity: 0.8,
            ..OscilluxOverlayConfig::default()
        };
        let mut flash = OscilluxFlashConfig::default();
        assert_eq!(
            unsafe { oscillux_overlay_flash_config(&config, &mut flash) },
            0
        );
        assert_eq!(flash.max_flash_hz, 1.0);
        assert_eq!(flash.max_red_flashes, 1);
        assert_eq!(flash.max_field_area, 0.1);
        let mut intensity = 0.0;
        assert_eq!(
            unsafe { oscillux_overlay_presentation_intensity(&config, &mut intensity) },
            0
        );
        assert_eq!(intensity, 0.4);
    }
}
