// SPDX-License-Identifier: AGPL-3.0-only
//! Opaque, allocation-free per-frame limiter interface.

pub use oscillux_core::limiter::Frame as OscilluxLimiterFrame;
/// One region's mean linear color, the element of the `_rgb` flash functions; an array
/// element, so it carries no `struct_size`.
pub use oscillux_core::limiter::RegionColor as OscilluxFlashColor;
/// One region's relative luminance and saturated-red level; an array element, so it carries no
/// `struct_size`.
pub use oscillux_core::limiter::RegionSample as OscilluxFlashRegion;
use oscillux_core::limiter::{
    FlashAnalyzer, FlashConfig, FlashReport, Limiter, Policy, RedRule, RegionError,
};

use crate::{guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};

/// C policy; the strobe flag must be exactly one. Invalid values are refused.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscilluxLimiterPolicy {
    /// Mirrors [`oscillux_core::limiter::Policy::max_flash_hz`].
    pub max_flash_hz: f64,
    /// Mirrors [`oscillux_core::limiter::Policy::max_luminance_delta`].
    pub max_luminance_delta: f64,
    /// Mirrors [`oscillux_core::limiter::Policy::max_flash_area`].
    pub max_flash_area: f64,
    /// Mirrors [`oscillux_core::limiter::Policy::max_red_flashes`].
    pub max_red_flashes: u32,
    /// 1 for [`oscillux_core::limiter::Policy::strobe_banned`]; any other value is refused.
    pub strobe_banned: u32,
}

impl Default for OscilluxLimiterPolicy {
    fn default() -> Self {
        let policy = Policy::DEFAULT;
        Self {
            max_flash_hz: policy.max_flash_hz,
            max_luminance_delta: policy.max_luminance_delta,
            max_flash_area: policy.max_flash_area,
            max_red_flashes: policy.max_red_flashes,
            strobe_banned: 1,
        }
    }
}

impl OscilluxLimiterPolicy {
    fn core_policy(self) -> Result<Policy, i32> {
        if self.strobe_banned != 1 {
            return Err(OSCILLUX_ERR_INVALID_ARGUMENT);
        }
        let policy = Policy {
            max_flash_hz: self.max_flash_hz,
            max_luminance_delta: self.max_luminance_delta,
            max_flash_area: self.max_flash_area,
            max_red_flashes: self.max_red_flashes,
            strobe_banned: true,
        };
        policy
            .validate()
            .map_err(|_| OSCILLUX_ERR_INVALID_ARGUMENT)?;
        Ok(policy)
    }
}

/// Opaque limiter handle, allocated only by create and freed by destroy.
pub struct OscilluxLimiter {
    limiter: Limiter,
}

/// Writes the reference policy defaults.
///
/// # Safety
/// `out` must be null or valid for one policy write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_limiter_policy_default(out: *mut OscilluxLimiterPolicy) -> i32 {
    guard(|| match out.as_mut() {
        Some(out) => {
            *out = OscilluxLimiterPolicy::default();
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}

/// Creates a limiter. Invalid policy values are refused; failure nulls `out_limiter`.
///
/// # Safety
/// Both pointers must be null or valid for one element, with disjoint storage.
#[no_mangle]
pub unsafe extern "C" fn oscillux_limiter_create(
    policy: *const OscilluxLimiterPolicy,
    out_limiter: *mut *mut OscilluxLimiter,
) -> i32 {
    guard(|| {
        let Some(out) = out_limiter.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out = core::ptr::null_mut();
        let Some(policy) = policy.as_ref() else {
            return OSCILLUX_ERR_NULL;
        };
        let Ok(policy) = policy.core_policy() else {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        };
        match Limiter::new(policy) {
            Ok(limiter) => {
                *out = Box::into_raw(Box::new(OscilluxLimiter { limiter }));
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Frees the handle; null is ignored.
///
/// # Safety
/// `limiter` must be null or a live handle from create, exclusively owned by this call.
#[no_mangle]
pub unsafe extern "C" fn oscillux_limiter_destroy(limiter: *mut OscilluxLimiter) {
    guard_void(|| {
        if !limiter.is_null() {
            drop(Box::from_raw(limiter));
        }
    })
}

/// Starts a new timeline: the next frame may carry any finite timestamp. Admitted flashes
/// keep their age and the policy is retained.
///
/// # Safety
/// `limiter` must be null or an exclusively accessible live handle.
#[no_mangle]
pub unsafe extern "C" fn oscillux_limiter_reset(limiter: *mut OscilluxLimiter) -> i32 {
    guard(|| match limiter.as_mut() {
        Some(limiter) => {
            limiter.limiter.reset();
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}

/// Processes one frame into caller storage. Input and output may be the same frame.
/// Invalid scalars or decreasing/non-finite timestamps leave state unchanged. On any error
/// with a non-null `out`, writes the fail-safe frame (every scalar zero, `time_ms` from the
/// input, or NaN without one) for the host to render. Does not allocate, lock or perform I/O.
///
/// # Safety
/// The handle must be exclusively accessible. Frame pointers must be null or valid for one
/// element and disjoint from the handle. `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn oscillux_limiter_process(
    limiter: *mut OscilluxLimiter,
    frame: *const OscilluxLimiterFrame,
    out: *mut OscilluxLimiterFrame,
) -> i32 {
    if out.is_null() {
        return OSCILLUX_ERR_NULL;
    }
    let time_ms = frame.as_ref().map_or(f64::NAN, |f| f.time_ms);
    let status = guard(|| {
        if limiter.is_null() || frame.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        match (*limiter).limiter.process(frame.read()) {
            Ok(result) => {
                out.write(result);
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    });
    if status != OSCILLUX_OK {
        out.write(OscilluxLimiterFrame::fail_safe(time_ms));
    }
    status
}

// ---- Region flash analyzer -----------------------------------------------------------------

/// C configuration for the region flash analyzer. `struct_size` must be a released size:
/// [`FLASH_CONFIG_SIZE`] or [`FLASH_CONFIG_SIZE_V1`], which ends before `red_rule` and so
/// selects the WCAG 2.0 red rule.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscilluxFlashConfig {
    /// Size of this struct as the caller's header declares it.
    pub struct_size: u32,
    /// Mirrors [`FlashConfig::columns`].
    pub columns: u32,
    /// Mirrors [`FlashConfig::rows`].
    pub rows: u32,
    /// Mirrors [`FlashConfig::max_red_flashes`].
    pub max_red_flashes: u32,
    /// Mirrors [`FlashConfig::field_width`].
    pub field_width: f64,
    /// Mirrors [`FlashConfig::field_height`].
    pub field_height: f64,
    /// Mirrors [`FlashConfig::max_field_area`].
    pub max_field_area: f64,
    /// Mirrors [`FlashConfig::max_flash_hz`].
    pub max_flash_hz: f64,
    /// [`RedRule`] as a number: 0 WCAG 2.0, 1 ISO 9241-391. Other values are refused.
    pub red_rule: u32,
    /// Must be 0; keeps the next appended member at a distinct size.
    pub reserved: u32,
}

/// `red_rule` value for [`RedRule::Wcag20`], the default.
pub const OSCILLUX_FLASH_RED_RULE_WCAG20: u32 = RedRule::Wcag20 as u32;

/// `red_rule` value for [`RedRule::Iso9241_391`].
pub const OSCILLUX_FLASH_RED_RULE_ISO_9241_391: u32 = RedRule::Iso9241_391 as u32;

/// The current released size of [`OscilluxFlashConfig`].
pub const FLASH_CONFIG_SIZE: u32 = core::mem::size_of::<OscilluxFlashConfig>() as u32;

/// The first released size of [`OscilluxFlashConfig`], through `max_flash_hz`.
pub const FLASH_CONFIG_SIZE_V1: u32 = core::mem::offset_of!(OscilluxFlashConfig, red_rule) as u32;

/// Whether `size` is a released [`OscilluxFlashConfig`] size.
pub(crate) fn released(size: u32) -> bool {
    size == FLASH_CONFIG_SIZE || size == FLASH_CONFIG_SIZE_V1
}

impl Default for OscilluxFlashConfig {
    fn default() -> Self {
        let config = FlashConfig::DEFAULT;
        Self {
            struct_size: FLASH_CONFIG_SIZE,
            columns: config.columns,
            rows: config.rows,
            max_red_flashes: config.max_red_flashes,
            field_width: config.field_width,
            field_height: config.field_height,
            max_field_area: config.max_field_area,
            max_flash_hz: config.max_flash_hz,
            red_rule: config.red_rule as u32,
            reserved: 0,
        }
    }
}

impl OscilluxFlashConfig {
    pub(crate) fn core_config(self) -> Result<FlashConfig, i32> {
        if !released(self.struct_size) || self.reserved != 0 {
            return Err(OSCILLUX_ERR_INVALID_ARGUMENT);
        }
        let red_rule =
            RedRule::from_u32(self.red_rule).map_err(|_| OSCILLUX_ERR_INVALID_ARGUMENT)?;
        let config = FlashConfig {
            field_width: self.field_width,
            field_height: self.field_height,
            max_field_area: self.max_field_area,
            max_flash_hz: self.max_flash_hz,
            columns: self.columns,
            rows: self.rows,
            max_red_flashes: self.max_red_flashes,
            red_rule,
        };
        config
            .validate()
            .map_err(|_| OSCILLUX_ERR_INVALID_ARGUMENT)?;
        Ok(config)
    }
}

/// C mirror of [`FlashReport`]; flags are 0 or 1.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct OscilluxFlashReport {
    /// Mirrors [`FlashReport::time_ms`].
    pub time_ms: f64,
    /// Mirrors [`FlashReport::flashes_in_window`].
    pub flashes_in_window: f64,
    /// Mirrors [`FlashReport::red_flashes_in_window`].
    pub red_flashes_in_window: f64,
    /// Mirrors [`FlashReport::admitted`].
    pub admitted: u32,
    /// Mirrors [`FlashReport::general_transition`].
    pub general_transition: u32,
    /// Mirrors [`FlashReport::red_transition`].
    pub red_transition: u32,
    /// Mirrors [`FlashReport::general_regions`].
    pub general_regions: u32,
    /// Mirrors [`FlashReport::red_regions`].
    pub red_regions: u32,
    /// Mirrors [`FlashReport::exceeds`].
    pub exceeds: u32,
}

impl OscilluxFlashReport {
    /// The report written on any error: nothing admitted or measured, at the input's time.
    pub const fn fail_safe(time_ms: f64) -> Self {
        Self {
            time_ms,
            flashes_in_window: 0.0,
            red_flashes_in_window: 0.0,
            admitted: 0,
            general_transition: 0,
            red_transition: 0,
            general_regions: 0,
            red_regions: 0,
            exceeds: 0,
        }
    }
}

impl From<FlashReport> for OscilluxFlashReport {
    fn from(r: FlashReport) -> Self {
        Self {
            time_ms: r.time_ms,
            flashes_in_window: r.flashes_in_window,
            red_flashes_in_window: r.red_flashes_in_window,
            admitted: r.admitted.into(),
            general_transition: r.general_transition.into(),
            red_transition: r.red_transition.into(),
            general_regions: r.general_regions,
            red_regions: r.red_regions,
            exceeds: r.exceeds.into(),
        }
    }
}

/// Opaque region flash analyzer handle, allocated only by create and freed by destroy.
pub struct OscilluxFlashAnalyzer {
    analyzer: FlashAnalyzer,
}

/// Writes the default config through `out->struct_size` bytes, which must already hold a
/// released size; bytes beyond it are not touched.
///
/// # Safety
/// `out` must be null, or aligned and valid for reads and writes of `struct_size` bytes.
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_config_default(out: *mut OscilluxFlashConfig) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        // Only `struct_size` is known to be present until it matches; read it alone.
        let size = core::ptr::addr_of!((*out).struct_size).read();
        if !released(size) {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let config = OscilluxFlashConfig {
            struct_size: size,
            ..OscilluxFlashConfig::default()
        };
        core::ptr::copy_nonoverlapping(
            (&config as *const OscilluxFlashConfig).cast::<u8>(),
            out.cast::<u8>(),
            size as usize,
        );
        OSCILLUX_OK
    })
}

/// Creates an analyzer. Invalid config values are refused; failure nulls `out_analyzer`.
///
/// # Safety
/// Both pointers must be null or valid: `config` for reads of its `struct_size` bytes,
/// `out_analyzer` for one write, with disjoint storage.
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_analyzer_create(
    config: *const OscilluxFlashConfig,
    out_analyzer: *mut *mut OscilluxFlashAnalyzer,
) -> i32 {
    guard(|| {
        let Some(out) = out_analyzer.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out = core::ptr::null_mut();
        if config.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        // Only `struct_size` is known to be present until it matches; read it alone, then
        // read that many bytes over the defaults.
        let size = core::ptr::addr_of!((*config).struct_size).read();
        if !released(size) {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let mut read = OscilluxFlashConfig::default();
        core::ptr::copy_nonoverlapping(
            config.cast::<u8>(),
            (&mut read as *mut OscilluxFlashConfig).cast::<u8>(),
            size as usize,
        );
        let Ok(config) = read.core_config() else {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        };
        match FlashAnalyzer::new(config) {
            Ok(analyzer) => {
                *out = Box::into_raw(Box::new(OscilluxFlashAnalyzer { analyzer }));
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Frees the handle; null is ignored.
///
/// # Safety
/// `analyzer` must be null or a live handle from create, exclusively owned by this call.
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_analyzer_destroy(analyzer: *mut OscilluxFlashAnalyzer) {
    guard_void(|| {
        if !analyzer.is_null() {
            drop(Box::from_raw(analyzer));
        }
    })
}

/// Starts a new timeline: the next frame may carry any finite timestamp. Transitions keep
/// their age and each region keeps its last image.
///
/// # Safety
/// `analyzer` must be null or an exclusively accessible live handle.
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_analyzer_reset(
    analyzer: *mut OscilluxFlashAnalyzer,
) -> i32 {
    guard(|| match analyzer.as_mut() {
        Some(analyzer) => {
            analyzer.analyzer.reset();
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}

/// One frame's region array, from either input path.
#[derive(Clone, Copy)]
enum Regions {
    Samples(*const OscilluxFlashRegion),
    Colors(*const OscilluxFlashColor),
}

impl Regions {
    fn is_null(self) -> bool {
        match self {
            Regions::Samples(p) => p.is_null(),
            Regions::Colors(p) => p.is_null(),
        }
    }

    /// # Safety
    /// The pointer must be valid for `count` reads.
    unsafe fn run(
        self,
        analyzer: &mut FlashAnalyzer,
        time_ms: f64,
        count: usize,
        admit: bool,
    ) -> Result<FlashReport, RegionError> {
        match (self, admit) {
            (Regions::Samples(p), false) => {
                analyzer.measure(time_ms, core::slice::from_raw_parts(p, count))
            }
            (Regions::Samples(p), true) => {
                analyzer.admit(time_ms, core::slice::from_raw_parts(p, count))
            }
            (Regions::Colors(p), false) => {
                analyzer.measure_rgb(time_ms, core::slice::from_raw_parts(p, count))
            }
            (Regions::Colors(p), true) => {
                analyzer.admit_rgb(time_ms, core::slice::from_raw_parts(p, count))
            }
        }
    }
}

/// Shared body of measure and admit on either path: validates pointers, runs the frame and
/// writes the report, or the fail-safe report on any error with a non-null `out`.
unsafe fn flash_frame(
    analyzer: *mut OscilluxFlashAnalyzer,
    time_ms: f64,
    regions: Regions,
    region_count: usize,
    out: *mut OscilluxFlashReport,
    admit: bool,
) -> i32 {
    if out.is_null() {
        return OSCILLUX_ERR_NULL;
    }
    let status = guard(|| {
        let Some(analyzer) = analyzer.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        if regions.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        // Check the count before forming the slice: a garbage count must not reach it.
        let config = analyzer.analyzer.config();
        if region_count != config.columns as usize * config.rows as usize {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        match regions.run(&mut analyzer.analyzer, time_ms, region_count, admit) {
            Ok(report) => {
                out.write(report.into());
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    });
    if status != OSCILLUX_OK {
        out.write(OscilluxFlashReport::fail_safe(time_ms));
    }
    status
}

/// Measures one frame of `region_count` row-major regions and always commits it. Invalid
/// input leaves state unchanged; on any error with a non-null `out`, writes the fail-safe
/// report. Refused under the ISO 9241-391 red rule, which needs colors. Does not allocate,
/// lock or perform I/O.
///
/// # Safety
/// The handle must be exclusively accessible. `regions` must be null or valid for
/// `region_count` reads; `out` must be null or writable, disjoint from both.
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_analyzer_measure(
    analyzer: *mut OscilluxFlashAnalyzer,
    time_ms: f64,
    regions: *const OscilluxFlashRegion,
    region_count: usize,
    out: *mut OscilluxFlashReport,
) -> i32 {
    flash_frame(
        analyzer,
        time_ms,
        Regions::Samples(regions),
        region_count,
        out,
        false,
    )
}

/// Measures one frame and commits it only within the config; `out->admitted` is 0 when the
/// host must keep presenting its last admitted image. Otherwise as measure.
///
/// # Safety
/// As [`oscillux_flash_analyzer_measure`].
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_analyzer_admit(
    analyzer: *mut OscilluxFlashAnalyzer,
    time_ms: f64,
    regions: *const OscilluxFlashRegion,
    region_count: usize,
    out: *mut OscilluxFlashReport,
) -> i32 {
    flash_frame(
        analyzer,
        time_ms,
        Regions::Samples(regions),
        region_count,
        out,
        true,
    )
}

/// Measures one frame of `region_count` row-major mean linear colors, under either red rule;
/// otherwise as measure. Does not allocate, lock or perform I/O.
///
/// # Safety
/// As [`oscillux_flash_analyzer_measure`], with `colors` valid for `region_count` reads.
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_analyzer_measure_rgb(
    analyzer: *mut OscilluxFlashAnalyzer,
    time_ms: f64,
    colors: *const OscilluxFlashColor,
    region_count: usize,
    out: *mut OscilluxFlashReport,
) -> i32 {
    flash_frame(
        analyzer,
        time_ms,
        Regions::Colors(colors),
        region_count,
        out,
        false,
    )
}

/// Admits one frame of mean linear colors, under either red rule; otherwise as admit.
///
/// # Safety
/// As [`oscillux_flash_analyzer_measure_rgb`].
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_analyzer_admit_rgb(
    analyzer: *mut OscilluxFlashAnalyzer,
    time_ms: f64,
    colors: *const OscilluxFlashColor,
    region_count: usize,
    out: *mut OscilluxFlashReport,
) -> i32 {
    flash_frame(
        analyzer,
        time_ms,
        Regions::Colors(colors),
        region_count,
        out,
        true,
    )
}

/// Writes the region measurement of a mean linear color, each channel in `[0, 1]`. Invalid
/// channels return `OSCILLUX_ERR_INVALID_ARGUMENT` and leave `out` unchanged.
///
/// # Safety
/// `out` must be null or valid for one region write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_region_from_linear_rgb(
    r: f64,
    g: f64,
    b: f64,
    out: *mut OscilluxFlashRegion,
) -> i32 {
    guard(|| {
        let Some(out) = out.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        match OscilluxFlashRegion::from_linear_rgb(r, g, b) {
            Ok(region) => {
                *out = region;
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

// Overlay regions as a stricter flash area (OSC-OVERLAY).

use crate::overlay::OscilluxOverlayRegion;
use oscillux_core::limiter::{FlashOverlay, FlashOverlayReport};

/// C mirror of [`FlashOverlay`]: stricter flash rules for the grid cells overlay regions
/// cover.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscilluxFlashOverlay {
    /// Size of this struct as the caller's header declares it; must be
    /// [`FLASH_OVERLAY_SIZE`].
    pub struct_size: u32,
    /// Must be 0.
    pub reserved: u32,
    /// Mirrors [`FlashOverlay::luminance_change`].
    pub luminance_change: f64,
    /// Mirrors [`FlashOverlay::darker_limit`].
    pub darker_limit: f64,
    /// Mirrors [`FlashOverlay::max_flash_hz`].
    pub max_flash_hz: f64,
    /// Mirrors [`FlashOverlay::max_area`].
    pub max_area: f64,
}

/// The released size of [`OscilluxFlashOverlay`].
pub const FLASH_OVERLAY_SIZE: u32 = core::mem::size_of::<OscilluxFlashOverlay>() as u32;

impl Default for OscilluxFlashOverlay {
    fn default() -> Self {
        let o = FlashOverlay::DEFAULT;
        Self {
            struct_size: FLASH_OVERLAY_SIZE,
            reserved: 0,
            luminance_change: o.luminance_change,
            darker_limit: o.darker_limit,
            max_flash_hz: o.max_flash_hz,
            max_area: o.max_area,
        }
    }
}

/// C mirror of [`FlashOverlayReport`]; flags are 0 or 1.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscilluxFlashOverlayReport {
    /// Size of this struct as the caller's header declares it; must be
    /// [`FLASH_OVERLAY_REPORT_SIZE`].
    pub struct_size: u32,
    /// Mirrors [`FlashOverlayReport::active`].
    pub active: u32,
    /// Mirrors [`FlashOverlayReport::transition`].
    pub transition: u32,
    /// Mirrors [`FlashOverlayReport::regions`].
    pub regions: u32,
    /// Mirrors [`FlashOverlayReport::cells`].
    pub cells: u32,
    /// Mirrors [`FlashOverlayReport::exceeds`].
    pub exceeds: u32,
    /// Mirrors [`FlashOverlayReport::flashes_in_window`].
    pub flashes_in_window: f64,
}

/// The released size of [`OscilluxFlashOverlayReport`].
pub const FLASH_OVERLAY_REPORT_SIZE: u32 =
    core::mem::size_of::<OscilluxFlashOverlayReport>() as u32;

impl From<FlashOverlayReport> for OscilluxFlashOverlayReport {
    fn from(r: FlashOverlayReport) -> Self {
        Self {
            struct_size: FLASH_OVERLAY_REPORT_SIZE,
            active: r.active.into(),
            transition: r.transition.into(),
            regions: r.regions,
            cells: r.cells,
            exceeds: r.exceeds.into(),
            flashes_in_window: r.flashes_in_window,
        }
    }
}

/// Writes the default flash overlay; `out->struct_size` must already hold
/// [`FLASH_OVERLAY_SIZE`].
///
/// # Safety
/// `out` must be null, or aligned and valid for reads and writes of `struct_size` bytes.
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_overlay_default(out: *mut OscilluxFlashOverlay) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        let size = core::ptr::addr_of!((*out).struct_size).read();
        if size != FLASH_OVERLAY_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        out.write(OscilluxFlashOverlay::default());
        OSCILLUX_OK
    })
}

/// Holds the grid cells `regions` cover to `*overlay` from the next frame; a null `overlay`
/// clears the overlay (`regions` is then ignored). Opt-in: without an overlay the analyzer
/// measures exactly as before, and measuring never depends on it; admitting also refuses a
/// frame that would put the overlay window over its rate. Refuses values looser than the
/// analyzer config, or invalid regions, leaving the previous overlay in place. Not for the
/// per-frame path: call it when the host UI layout changes.
///
/// # Safety
/// `analyzer` must be null or an exclusively accessible live handle; `overlay` null or valid
/// for reads of its `struct_size` bytes; `regions` null with `count` 0 or valid for `count`
/// reads.
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_analyzer_set_overlay(
    analyzer: *mut OscilluxFlashAnalyzer,
    overlay: *const OscilluxFlashOverlay,
    regions: *const OscilluxOverlayRegion,
    count: usize,
) -> i32 {
    guard(|| {
        let Some(analyzer) = analyzer.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        if overlay.is_null() {
            analyzer.analyzer.clear_overlay();
            return OSCILLUX_OK;
        }
        let size = core::ptr::addr_of!((*overlay).struct_size).read();
        if size != FLASH_OVERLAY_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let o = overlay.read();
        if o.reserved != 0 {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let list = match crate::overlay::regions(regions, count) {
            Ok(list) => list,
            Err(status) => return status,
        };
        let rules = FlashOverlay {
            luminance_change: o.luminance_change,
            darker_limit: o.darker_limit,
            max_flash_hz: o.max_flash_hz,
            max_area: o.max_area,
        };
        match analyzer.analyzer.set_overlay(&rules, list) {
            Ok(()) => OSCILLUX_OK,
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Writes the overlay outcome of the frame last measured or admitted; `out->struct_size` must
/// already hold [`FLASH_OVERLAY_REPORT_SIZE`].
///
/// # Safety
/// `analyzer` must be null or a live handle; `out` null or aligned and valid for reads and
/// writes of `struct_size` bytes.
#[no_mangle]
pub unsafe extern "C" fn oscillux_flash_analyzer_overlay_report(
    analyzer: *const OscilluxFlashAnalyzer,
    out: *mut OscilluxFlashOverlayReport,
) -> i32 {
    guard(|| {
        let Some(analyzer) = analyzer.as_ref() else {
            return OSCILLUX_ERR_NULL;
        };
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        let size = core::ptr::addr_of!((*out).struct_size).read();
        if size != FLASH_OVERLAY_REPORT_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        out.write(analyzer.analyzer.overlay_report().into());
        OSCILLUX_OK
    })
}
