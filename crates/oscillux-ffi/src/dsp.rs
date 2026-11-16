// SPDX-License-Identifier: AGPL-3.0-only
//! C interface to the streaming analyzer. The DSP section of `ffi/include/oscillux.h` declares
//! these functions and mirrors [`DspConfig`] and [`DspFrame`] field for field.
//!
//! The ABI-1 configuration struct carries no `struct_size`, so its functions keep DSP behaviour
//! version 1 exactly. [`OscilluxDspVersionedConfig`] is the additive, size-checked struct that
//! selects a behaviour version; its default is version 2.
//!
//! [`OscilluxDspFrameExt`] carries opt-in outputs beside each frame for
//! [`oscillux_dsp_push_ext_f32`] and [`oscillux_dsp_push_ext_f64`]; its sections are only
//! appended, and `struct_size` says which of them the caller's elements hold.

use core::ffi::{c_char, CStr};
use core::mem::{align_of, offset_of, size_of};

use oscillux_core::dsp::{
    Analyzer, Beat, Descriptors, DspConfig, DspError, DspFrame, DspSettings, FrameExt, Levels,
    BEAT_LATENCY_V1_MS, BEAT_LATENCY_V2_MS, BEAT_LATENCY_V3_MS, BEAT_LATENCY_V4_MS,
    DSP_BEHAVIOR_V1, DSP_BEHAVIOR_V2, DSP_BEHAVIOR_V3, DSP_BEHAVIOR_V4,
};

use crate::{guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};

/// Opaque analyzer handle.
pub struct OscilluxDsp {
    analyzer: Analyzer,
}

/// What one [`oscillux_dsp_push_f32`] call did.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct OscilluxDspPushResult {
    /// Sample frames consumed from the input.
    pub consumed: usize,
    /// Analysis frames written to the output buffer.
    pub produced: usize,
}

/// Views `len` elements at `ptr`; a zero length accepts any pointer, including null.
///
/// # Safety
/// When `len > 0`, `ptr` must be valid for `len` reads.
unsafe fn slice_or_empty<'a, T>(ptr: *const T, len: usize) -> Option<&'a [T]> {
    match (len, ptr.is_null()) {
        (0, _) => Some(&[]),
        (_, true) => None,
        _ => Some(core::slice::from_raw_parts(ptr, len)),
    }
}

/// Mutable form of [`slice_or_empty`].
///
/// # Safety
/// When `len > 0`, `ptr` must be valid for `len` writes and not aliased.
unsafe fn slice_or_empty_mut<'a, T>(ptr: *mut T, len: usize) -> Option<&'a mut [T]> {
    match (len, ptr.is_null()) {
        (0, _) => Some(&mut []),
        (_, true) => None,
        _ => Some(core::slice::from_raw_parts_mut(ptr, len)),
    }
}

/// Writes the reference configuration to `*out`.
///
/// # Safety
/// `out` must be null or valid for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_config_default(out: *mut DspConfig) -> i32 {
    guard(|| match out.as_mut() {
        Some(out) => {
            *out = DspConfig::default();
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}

/// Every `OscilluxDspConfig` member name, as `oscillux_dsp_config_validate` reports it.
const CONFIG_FIELDS: [&CStr; 16] = [
    c"sample_rate_hz",
    c"fft_window_samples",
    c"hop_samples",
    c"spectrum_bands",
    c"spectrum_min_hz",
    c"spectrum_max_hz",
    c"db_floor",
    c"ballistics_attack_ms",
    c"ballistics_release_ms",
    c"rms_window_ms",
    c"loudness_reference_lufs",
    c"rms_floor",
    c"onset_peak_decay",
    c"onset_peak_floor",
    c"onset_band_groups",
    c"gap_tolerance_hops",
];

/// Reported when an error names no member listed in [`CONFIG_FIELDS`].
const WHOLE_CONFIG: &CStr = c"config";

/// The static C name of the member `error` blames, or [`WHOLE_CONFIG`]. Error variants or
/// field names added to the core later fall back rather than fail.
fn blamed_field(error: DspError) -> &'static CStr {
    match error {
        DspError::InvalidConfig(name) => CONFIG_FIELDS
            .iter()
            .find(|field| field.to_bytes() == name.as_bytes())
            .copied()
            .unwrap_or(WHOLE_CONFIG),
        _ => WHOLE_CONFIG,
    }
}

/// Checks `*config` as [`oscillux_dsp_create`] does, without allocating. When `out_field` is
/// not null it receives the static name of the first offending member on
/// [`OSCILLUX_ERR_INVALID_ARGUMENT`], and null otherwise.
///
/// # Safety
/// `config` must be null or valid for one read; `out_field` must be null or valid for one
/// write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_config_validate(
    config: *const DspConfig,
    out_field: *mut *const c_char,
) -> i32 {
    guard(|| {
        let (status, field) = match config.as_ref().map(DspConfig::validate) {
            None => (OSCILLUX_ERR_NULL, None),
            Some(Ok(())) => (OSCILLUX_OK, None),
            Some(Err(error)) => (OSCILLUX_ERR_INVALID_ARGUMENT, Some(blamed_field(error))),
        };
        if let Some(out_field) = out_field.as_mut() {
            *out_field = field.map_or(core::ptr::null(), CStr::as_ptr);
        }
        status
    })
}

/// Validates `*config` and creates an analyzer, writing its handle to `*out_dsp`. This is the
/// only call that allocates. On failure `*out_dsp` is set to null.
///
/// # Safety
/// `config` must be null or valid for one read; `out_dsp` must be null or valid for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_create(
    config: *const DspConfig,
    out_dsp: *mut *mut OscilluxDsp,
) -> i32 {
    guard(|| {
        let Some(out_dsp) = out_dsp.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out_dsp = core::ptr::null_mut();
        let Some(config) = config.as_ref() else {
            return OSCILLUX_ERR_NULL;
        };
        match Analyzer::new(*config) {
            Ok(analyzer) => {
                *out_dsp = Box::into_raw(Box::new(OscilluxDsp { analyzer }));
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// `OSCILLUX_DSP_BEHAVIOR_V1`: the original analysis, frozen bit for bit.
pub const OSCILLUX_DSP_BEHAVIOR_V1: u32 = DSP_BEHAVIOR_V1;
/// `OSCILLUX_DSP_BEHAVIOR_V2`: the default of [`oscillux_dsp_versioned_config_default`].
pub const OSCILLUX_DSP_BEHAVIOR_V2: u32 = DSP_BEHAVIOR_V2;
/// `OSCILLUX_DSP_BEHAVIOR_V3`: version 2 frames with the version 3 beat tracker.
pub const OSCILLUX_DSP_BEHAVIOR_V3: u32 = DSP_BEHAVIOR_V3;
/// `OSCILLUX_DSP_BEHAVIOR_V4`: version 2 frames with the version 4 beat tracker.
pub const OSCILLUX_DSP_BEHAVIOR_V4: u32 = DSP_BEHAVIOR_V4;
/// `OSCILLUX_DSP_BEAT_LATENCY_V1_MS`: beat analysis latency of version 1, ms.
pub const OSCILLUX_DSP_BEAT_LATENCY_V1_MS: u32 = BEAT_LATENCY_V1_MS;
/// `OSCILLUX_DSP_BEAT_LATENCY_V2_MS`: beat analysis latency of version 2, ms.
pub const OSCILLUX_DSP_BEAT_LATENCY_V2_MS: u32 = BEAT_LATENCY_V2_MS;
/// `OSCILLUX_DSP_BEAT_LATENCY_V3_MS`: beat analysis latency of version 3, ms.
pub const OSCILLUX_DSP_BEAT_LATENCY_V3_MS: u32 = BEAT_LATENCY_V3_MS;
/// `OSCILLUX_DSP_BEAT_LATENCY_V4_MS`: beat analysis latency of version 4, ms.
pub const OSCILLUX_DSP_BEAT_LATENCY_V4_MS: u32 = BEAT_LATENCY_V4_MS;

/// A DSP configuration and the behaviour version that interprets it. `struct_size` must be
/// `sizeof(OscilluxDspVersionedConfig)` before any call, including the default call; members
/// are only appended after `reserved`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscilluxDspVersionedConfig {
    /// Released size of this struct, set by the caller.
    pub struct_size: u32,
    /// Analysis parameters, as for [`oscillux_dsp_create`].
    pub config: DspConfig,
    /// [`OSCILLUX_DSP_BEHAVIOR_V1`], [`OSCILLUX_DSP_BEHAVIOR_V2`], [`OSCILLUX_DSP_BEHAVIOR_V3`]
    /// or [`OSCILLUX_DSP_BEHAVIOR_V4`]; default version 2.
    pub behavior_version: u32,
    /// Must be 0. It fills what would be tail padding, so the next appended member changes the
    /// size and an older library refuses it.
    pub reserved: u32,
}

const DSP_VERSIONED_CONFIG_SIZE: u32 = core::mem::size_of::<OscilluxDspVersionedConfig>() as u32;

impl Default for OscilluxDspVersionedConfig {
    fn default() -> Self {
        let settings = DspSettings::default();
        OscilluxDspVersionedConfig {
            struct_size: DSP_VERSIONED_CONFIG_SIZE,
            config: settings.config,
            behavior_version: settings.behavior_version,
            reserved: 0,
        }
    }
}

impl OscilluxDspVersionedConfig {
    fn settings(&self) -> DspSettings {
        DspSettings {
            config: self.config,
            behavior_version: self.behavior_version,
        }
    }
}

/// Reads `*config` when it is not null and its `struct_size` is the released size; `Err` holds
/// the status to return otherwise. `reserved` is not checked here.
///
/// # Safety
/// `config` must be null or valid for a read of `struct_size` and, when that matches, of the
/// whole struct.
unsafe fn read_versioned(
    config: *const OscilluxDspVersionedConfig,
) -> Result<OscilluxDspVersionedConfig, i32> {
    if config.is_null() {
        return Err(OSCILLUX_ERR_NULL);
    }
    // Only `struct_size` is known to be present until it matches; read it alone.
    if core::ptr::addr_of!((*config).struct_size).read() != DSP_VERSIONED_CONFIG_SIZE {
        return Err(OSCILLUX_ERR_INVALID_ARGUMENT);
    }
    Ok(config.read())
}

/// Writes the reference configuration at behaviour version 2. `out->struct_size` must already
/// hold the released size.
///
/// # Safety
/// `out` must be null or valid for a read of `struct_size` and, when that matches, one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_versioned_config_default(
    out: *mut OscilluxDspVersionedConfig,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        // Only `struct_size` is known to be present until it matches; read it alone.
        if core::ptr::addr_of!((*out).struct_size).read() != DSP_VERSIONED_CONFIG_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        out.write(OscilluxDspVersionedConfig::default());
        OSCILLUX_OK
    })
}

/// Checks `*config` as [`oscillux_dsp_create_versioned`] does, without allocating. `out_field`,
/// when not null, receives `"struct_size"`, the first offending `config` member name,
/// `"behavior_version"`, `"reserved"` or `"config"` on [`OSCILLUX_ERR_INVALID_ARGUMENT`], and
/// null otherwise.
///
/// # Safety
/// As for [`oscillux_dsp_versioned_config_default`] for `config`, read only; `out_field` must
/// be null or valid for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_versioned_config_validate(
    config: *const OscilluxDspVersionedConfig,
    out_field: *mut *const c_char,
) -> i32 {
    guard(|| {
        let (status, field) = match read_versioned(config) {
            Err(OSCILLUX_ERR_INVALID_ARGUMENT) => {
                (OSCILLUX_ERR_INVALID_ARGUMENT, Some(c"struct_size"))
            }
            Err(status) => (status, None),
            Ok(versioned) => match versioned.settings().validate() {
                Ok(()) if versioned.reserved != 0 => {
                    (OSCILLUX_ERR_INVALID_ARGUMENT, Some(c"reserved"))
                }
                Ok(()) => (OSCILLUX_OK, None),
                Err(DspError::InvalidConfig("behavior_version")) => {
                    (OSCILLUX_ERR_INVALID_ARGUMENT, Some(c"behavior_version"))
                }
                Err(error) => (OSCILLUX_ERR_INVALID_ARGUMENT, Some(blamed_field(error))),
            },
        };
        if let Some(out_field) = out_field.as_mut() {
            *out_field = field.map_or(core::ptr::null(), CStr::as_ptr);
        }
        status
    })
}

/// Validates `*config` and creates an analyzer that runs its behaviour version, writing the
/// handle to `*out_dsp`; every other `oscillux_dsp_*` call accepts it. Allocates like
/// [`oscillux_dsp_create`]. On failure `*out_dsp` is set to null.
///
/// # Safety
/// As for [`oscillux_dsp_versioned_config_validate`] for `config`; `out_dsp` must be null or
/// valid for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_create_versioned(
    config: *const OscilluxDspVersionedConfig,
    out_dsp: *mut *mut OscilluxDsp,
) -> i32 {
    guard(|| {
        let Some(out_dsp) = out_dsp.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out_dsp = core::ptr::null_mut();
        let versioned = match read_versioned(config) {
            Ok(versioned) => versioned,
            Err(status) => return status,
        };
        if versioned.reserved != 0 {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        match Analyzer::new(versioned.settings()) {
            Ok(analyzer) => {
                *out_dsp = Box::into_raw(Box::new(OscilluxDsp { analyzer }));
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Frees an analyzer. Null is ignored.
///
/// # Safety
/// `dsp` must be null or a handle from [`oscillux_dsp_create`] or
/// [`oscillux_dsp_create_versioned`] not yet destroyed.
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_destroy(dsp: *mut OscilluxDsp) {
    guard_void(|| {
        if !dsp.is_null() {
            drop(Box::from_raw(dsp));
        }
    })
}

/// Starts a new input segment whose first sample plays at `media_start_ms`; `stalled` is
/// non-zero when capture stalled before it. A non-finite `media_start_ms` is refused and leaves
/// the current segment unchanged.
///
/// # Safety
/// `dsp` must be null or a live handle.
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_begin_segment(
    dsp: *mut OscilluxDsp,
    media_start_ms: f64,
    stalled: u32,
) -> i32 {
    guard(|| match dsp.as_mut() {
        Some(_) if !media_start_ms.is_finite() => OSCILLUX_ERR_INVALID_ARGUMENT,
        Some(dsp) => {
            dsp.analyzer.begin_segment(media_start_ms, stalled != 0);
            OSCILLUX_OK
        }
        None => OSCILLUX_ERR_NULL,
    })
}

/// Consumes up to `sample_frames` interleaved frames of `channels` samples each and writes at
/// most `out_capacity` analysis frames to `out`. Stops before the sample that would complete a
/// frame once `out` is full; `*result` reports how far it got. Does not allocate, lock or
/// perform I/O. NaN and infinite samples are replaced with 0 and flagged on the next frame.
///
/// # Safety
/// `dsp` must be a live handle; `samples` must be valid for `sample_frames * channels` reads
/// and `out` for `out_capacity` writes (either may be null when its length is zero);
/// `result` must be valid for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_push_f32(
    dsp: *mut OscilluxDsp,
    samples: *const f32,
    sample_frames: usize,
    channels: u32,
    out: *mut DspFrame,
    out_capacity: usize,
    result: *mut OscilluxDspPushResult,
) -> i32 {
    guard(|| {
        let Some(sample_count) = sample_frames.checked_mul(channels as usize) else {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        };
        if sample_count > isize::MAX as usize / core::mem::size_of::<f32>()
            || out_capacity > isize::MAX as usize / core::mem::size_of::<DspFrame>()
        {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let dsp = dsp.as_mut();
        let input = slice_or_empty(samples, sample_count);
        let output = slice_or_empty_mut(out, out_capacity);
        let result = result.as_mut();
        let (Some(dsp), Some(input), Some(output), Some(result)) = (dsp, input, output, result)
        else {
            return OSCILLUX_ERR_NULL;
        };
        match dsp.analyzer.push(input, channels as usize, output) {
            Ok(pushed) => {
                *result = OscilluxDspPushResult {
                    consumed: pushed.consumed,
                    produced: pushed.produced,
                };
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Consumes up to `sample_frames` interleaved frames of `channels` samples each and writes at
/// most `out_capacity` analysis frames to `out`. Stops before the sample that would complete a
/// frame once `out` is full; `*result` reports how far it got. Does not allocate, lock or
/// perform I/O.
///
/// # Safety
/// `dsp` must be a live handle; `samples` must be valid for `sample_frames * channels` reads
/// and `out` for `out_capacity` writes (either may be null when its length is zero);
/// `result` must be valid for one write. Buffers must be aligned for their element types,
/// live for the call and nonoverlapping; the handle, output and result require exclusive access.
/// No input/output buffer is retained or freed. Only read `result` and produced outputs after
/// `OSCILLUX_OK`; on error their contents are not a successful result. After `OSCILLUX_ERR_PANIC`,
/// discard/recreate the analyzer because partial state changes are not rolled back.
/// Supported PCM is finite normalized input, including bounded gain-scaled values in [-2, 2].
/// NaN, infinite samples and magnitudes above `f32::MAX` are replaced with 0 and flagged on the
/// next frame.
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_push_f64(
    dsp: *mut OscilluxDsp,
    samples: *const f64,
    sample_frames: usize,
    channels: u32,
    out: *mut DspFrame,
    out_capacity: usize,
    result: *mut OscilluxDspPushResult,
) -> i32 {
    guard(|| {
        let Some(sample_count) = sample_frames.checked_mul(channels as usize) else {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        };
        if sample_count > isize::MAX as usize / core::mem::size_of::<f64>()
            || out_capacity > isize::MAX as usize / core::mem::size_of::<DspFrame>()
        {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let dsp = dsp.as_mut();
        let input = slice_or_empty(samples, sample_count);
        let output = slice_or_empty_mut(out, out_capacity);
        let result = result.as_mut();
        let (Some(dsp), Some(input), Some(output), Some(result)) = (dsp, input, output, result)
        else {
            return OSCILLUX_ERR_NULL;
        };
        match dsp.analyzer.push(input, channels as usize, output) {
            Ok(pushed) => {
                *result = OscilluxDspPushResult {
                    consumed: pushed.consumed,
                    produced: pushed.produced,
                };
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Opt-in outputs for one analysis frame, written by [`oscillux_dsp_push_ext_f32`] and
/// [`oscillux_dsp_push_ext_f64`] to the element matching each frame. Sections are only appended
/// after `descriptors`, never moved, retyped or given a new meaning.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscilluxDspFrameExt {
    /// One of [`FRAME_EXT_SIZES`], set by the caller in every element; it is also the element
    /// stride of the caller's array.
    pub struct_size: u32,
    /// Must be 0.
    pub reserved: u32,
    /// Loudness, stereo image and spectral shape of the frame.
    pub descriptors: Descriptors,
    /// The analyzer's default beat tracker output for the frame.
    pub beat: Beat,
    /// The analyzer's default adaptive levels for the frame.
    pub levels: Levels,
}

/// End of the `descriptors` section, the size in the first header that declared the struct.
const EXT_DESCRIPTORS_END: usize =
    offset_of!(OscilluxDspFrameExt, descriptors) + size_of::<Descriptors>();
/// End of the `beat` section.
const EXT_BEAT_END: usize = offset_of!(OscilluxDspFrameExt, beat) + size_of::<Beat>();
/// End of the `levels` section.
pub(crate) const EXT_LEVELS_END: usize =
    offset_of!(OscilluxDspFrameExt, levels) + size_of::<Levels>();

/// Every accepted `struct_size` of [`OscilluxDspFrameExt`], ascending: the end of each section.
/// No header declared 104, the end of `beat`; it is accepted so that a caller can take the beat
/// without the levels. An appended section adds its end, which must be a multiple of the
/// struct's alignment so that every element of an array of that size stays aligned.
const FRAME_EXT_SIZES: [usize; 3] = [EXT_DESCRIPTORS_END, EXT_BEAT_END, EXT_LEVELS_END];

const _: () = {
    assert!(FRAME_EXT_SIZES[FRAME_EXT_SIZES.len() - 1] == size_of::<OscilluxDspFrameExt>());
    // Section ends never change; the header documents these values.
    assert!(EXT_DESCRIPTORS_END == 56 && EXT_BEAT_END == 104 && EXT_LEVELS_END == 672);
    let mut i = 0;
    while i < FRAME_EXT_SIZES.len() {
        assert!(FRAME_EXT_SIZES[i] % align_of::<OscilluxDspFrameExt>() == 0);
        i += 1;
    }
};

impl Default for OscilluxDspFrameExt {
    fn default() -> Self {
        OscilluxDspFrameExt {
            struct_size: size_of::<OscilluxDspFrameExt>() as u32,
            reserved: 0,
            descriptors: Descriptors::ZERO,
            beat: Beat::ZERO,
            levels: Levels::ZERO,
        }
    }
}

/// Checks `capacity` caller elements of `ext` and returns their stride, the shared
/// `struct_size`; `Err` holds the status to return. Reads only, so a refusal changes nothing.
///
/// # Safety
/// When `capacity > 0` and `ext` is not null, `ext` must be valid for reads of `capacity`
/// elements of the size its first `struct_size` names.
pub(crate) unsafe fn frame_ext_stride(
    ext: *const OscilluxDspFrameExt,
    capacity: usize,
) -> Result<usize, i32> {
    if capacity == 0 {
        return Ok(0);
    }
    if ext.is_null() {
        return Err(OSCILLUX_ERR_NULL);
    }
    if !ext.is_aligned() {
        return Err(OSCILLUX_ERR_INVALID_ARGUMENT);
    }
    // Only the header is known to be present until struct_size is checked; read it alone.
    let size = core::ptr::addr_of!((*ext).struct_size).read() as usize;
    if !FRAME_EXT_SIZES.contains(&size) || capacity > isize::MAX as usize / size {
        return Err(OSCILLUX_ERR_INVALID_ARGUMENT);
    }
    let base = ext.cast::<u8>();
    for index in 0..capacity {
        let element = base.add(index * size).cast::<OscilluxDspFrameExt>();
        if core::ptr::addr_of!((*element).struct_size).read() as usize != size
            || core::ptr::addr_of!((*element).reserved).read() != 0
        {
            return Err(OSCILLUX_ERR_INVALID_ARGUMENT);
        }
    }
    Ok(size)
}

/// Writes the sections of `value` that end within `stride` to element `index` of `base`;
/// `struct_size`, `reserved` and later sections are left as the caller set them.
///
/// # Safety
/// `base` must have passed [`frame_ext_stride`] with `stride` for more than `index` elements.
pub(crate) unsafe fn write_frame_ext(base: *mut u8, stride: usize, index: usize, value: &FrameExt) {
    let element = base.add(index * stride);
    if EXT_DESCRIPTORS_END <= stride {
        element
            .add(offset_of!(OscilluxDspFrameExt, descriptors))
            .cast::<Descriptors>()
            .write(value.descriptors);
    }
    if EXT_BEAT_END <= stride {
        element
            .add(offset_of!(OscilluxDspFrameExt, beat))
            .cast::<Beat>()
            .write(value.beat);
    }
    if EXT_LEVELS_END <= stride {
        element
            .add(offset_of!(OscilluxDspFrameExt, levels))
            .cast::<Levels>()
            .write(value.levels);
    }
}

/// Shared body of the ext push functions.
///
/// # Safety
/// As [`oscillux_dsp_push_ext_f32`].
#[allow(clippy::too_many_arguments)]
unsafe fn push_ext<S: Copy + Into<f64>>(
    dsp: *mut OscilluxDsp,
    samples: *const S,
    sample_frames: usize,
    channels: u32,
    out: *mut DspFrame,
    ext: *mut OscilluxDspFrameExt,
    out_capacity: usize,
    result: *mut OscilluxDspPushResult,
) -> i32 {
    guard(|| {
        let Some(sample_count) = sample_frames.checked_mul(channels as usize) else {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        };
        if sample_count > isize::MAX as usize / size_of::<S>()
            || out_capacity > isize::MAX as usize / size_of::<DspFrame>()
        {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let dsp = dsp.as_mut();
        let input = slice_or_empty(samples, sample_count);
        let output = slice_or_empty_mut(out, out_capacity);
        let result = result.as_mut();
        let (Some(dsp), Some(input), Some(output), Some(result)) = (dsp, input, output, result)
        else {
            return OSCILLUX_ERR_NULL;
        };
        let stride = match frame_ext_stride(ext, out_capacity) {
            Ok(stride) => stride,
            Err(status) => return status,
        };
        let base = ext.cast::<u8>();
        let sink = |index: usize, value: &FrameExt| write_frame_ext(base, stride, index, value);
        match dsp
            .analyzer
            .push_ext_with(input, channels as usize, output, sink)
        {
            Ok(pushed) => {
                *result = OscilluxDspPushResult {
                    consumed: pushed.consumed,
                    produced: pushed.produced,
                };
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// [`oscillux_dsp_push_f32`] that also writes `ext[i]` beside `out[i]` for every produced frame.
/// The frames equal those of `oscillux_dsp_push_f32` bit for bit, and the analyzer state is the
/// same whichever push is used. Before any input is consumed, `ext` is refused with
/// `OSCILLUX_ERR_NULL` when null with a nonzero `out_capacity`, and with
/// `OSCILLUX_ERR_INVALID_ARGUMENT` when misaligned, when the first element's `struct_size` is
/// not a section end, or when any of the `out_capacity` elements has a different
/// `struct_size` or a nonzero `reserved`.
///
/// # Safety
/// As [`oscillux_dsp_push_f32`]; `ext` must also be valid for reads and writes of
/// `out_capacity` elements of `ext->struct_size` bytes each (null when `out_capacity` is 0),
/// aligned, exclusive and disjoint from the other buffers.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_push_ext_f32(
    dsp: *mut OscilluxDsp,
    samples: *const f32,
    sample_frames: usize,
    channels: u32,
    out: *mut DspFrame,
    ext: *mut OscilluxDspFrameExt,
    out_capacity: usize,
    result: *mut OscilluxDspPushResult,
) -> i32 {
    push_ext(
        dsp,
        samples,
        sample_frames,
        channels,
        out,
        ext,
        out_capacity,
        result,
    )
}

/// [`oscillux_dsp_push_f64`] with the `ext` output of [`oscillux_dsp_push_ext_f32`].
///
/// # Safety
/// As [`oscillux_dsp_push_ext_f32`] with float64 samples.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub unsafe extern "C" fn oscillux_dsp_push_ext_f64(
    dsp: *mut OscilluxDsp,
    samples: *const f64,
    sample_frames: usize,
    channels: u32,
    out: *mut DspFrame,
    ext: *mut OscilluxDspFrameExt,
    out_capacity: usize,
    result: *mut OscilluxDspPushResult,
) -> i32 {
    push_ext(
        dsp,
        samples,
        sample_frames,
        channels,
        out,
        ext,
        out_capacity,
        result,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::ptr::{null, null_mut};
    use oscillux_core::dsp::FLAG_INPUT_REPLACED;

    #[test]
    fn stream_through_the_c_interface_equals_the_core() {
        let mut cfg = DspConfig {
            hop_samples: 0,
            ..DspConfig::default()
        };
        assert_eq!(
            unsafe { oscillux_dsp_config_default(&mut cfg) },
            OSCILLUX_OK
        );
        assert_eq!(cfg, DspConfig::default());
        let mut dsp = null_mut();
        assert_eq!(unsafe { oscillux_dsp_create(&cfg, &mut dsp) }, OSCILLUX_OK);
        let samples: Vec<f32> = (0..6000).map(|i| ((i % 97) as f32 - 48.0) / 64.0).collect();
        let mut out = [DspFrame::ZERO; 16];
        let mut result = OscilluxDspPushResult::default();
        let rc = unsafe {
            oscillux_dsp_push_f32(
                dsp,
                samples.as_ptr(),
                samples.len(),
                1,
                out.as_mut_ptr(),
                out.len(),
                &mut result,
            )
        };
        unsafe { oscillux_dsp_destroy(dsp) };
        let mut analyzer = Analyzer::new(DspConfig::default()).unwrap();
        let mut want = [DspFrame::ZERO; 16];
        let pushed = analyzer.push(&samples, 1, &mut want).unwrap();
        assert_eq!(rc, OSCILLUX_OK);
        assert_eq!(
            (result.consumed, result.produced),
            (pushed.consumed, pushed.produced)
        );
        assert_eq!(out, want);
    }

    type PushFn<T> = unsafe extern "C" fn(
        *mut OscilluxDsp,
        *const T,
        usize,
        u32,
        *mut DspFrame,
        usize,
        *mut OscilluxDspPushResult,
    ) -> i32;

    /// Pushes stereo `samples` through `push` on a fresh default analyzer.
    fn push_stereo<T>(push: PushFn<T>, samples: &[T]) -> Vec<DspFrame> {
        let mut dsp = null_mut();
        assert_eq!(
            unsafe { oscillux_dsp_create(&DspConfig::default(), &mut dsp) },
            OSCILLUX_OK
        );
        let mut out = vec![DspFrame::ZERO; 16];
        let mut result = OscilluxDspPushResult::default();
        let rc = unsafe {
            push(
                dsp,
                samples.as_ptr(),
                samples.len() / 2,
                2,
                out.as_mut_ptr(),
                out.len(),
                &mut result,
            )
        };
        unsafe { oscillux_dsp_destroy(dsp) };
        assert_eq!((rc, result.consumed), (OSCILLUX_OK, samples.len() / 2));
        out.truncate(result.produced);
        for frame in &out {
            let scalars = [frame.media_time_ms, frame.rms, frame.loudness_db];
            let onsets = [frame.onset.broadband, frame.onset.low, frame.onset.mid];
            let values = scalars.iter().chain(&onsets).chain(&frame.spectrum);
            assert!(values.chain([&frame.onset.high]).all(|v| v.is_finite()));
        }
        out
    }

    /// `got` equals `want` except that exactly frame `flagged` also carries the replaced flag.
    fn assert_one_frame_flagged(got: &[DspFrame], want: &[DspFrame], flagged: usize) {
        assert_eq!(got.len(), want.len());
        for (i, (got, want)) in got.iter().zip(want).enumerate() {
            let extra = if i == flagged { FLAG_INPUT_REPLACED } else { 0 };
            assert_eq!(got.flags, want.flags | extra, "frame {i}");
            assert_eq!(
                DspFrame {
                    flags: want.flags,
                    ..*got
                },
                *want,
                "frame {i}"
            );
        }
    }

    #[test]
    fn invalid_samples_are_replaced_with_zero_and_flag_one_frame_on_both_entry_points() {
        let clean: Vec<f64> = (0..8192)
            .map(|i| 0.25 * ((i % 97) as f64 - 48.0) / 48.0)
            .collect();
        // Right channel of sample frame 2500, which falls in the hop of frame 1 (2048..2560).
        let (bad_at, flagged) = (5001, 1);
        let mut zeroed = clean.clone();
        zeroed[bad_at] = 0.0;
        let want = push_stereo(oscillux_dsp_push_f64, &zeroed);
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 1e300, -f64::MAX] {
            let mut input = clean.clone();
            input[bad_at] = bad;
            let got = push_stereo(oscillux_dsp_push_f64, &input);
            assert_one_frame_flagged(&got, &want, flagged);
        }
        let clean: Vec<f32> = clean.iter().map(|s| *s as f32).collect();
        let zeroed: Vec<f32> = zeroed.iter().map(|s| *s as f32).collect();
        let want = push_stereo(oscillux_dsp_push_f32, &zeroed);
        for bad in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            let mut input = clean.clone();
            input[bad_at] = bad;
            let got = push_stereo(oscillux_dsp_push_f32, &input);
            assert_one_frame_flagged(&got, &want, flagged);
        }
        // The largest finite f32 is in range on both entry points: kept, unflagged and finite.
        let mut huge = clean.clone();
        huge[bad_at] = -f32::MAX;
        let huge_f64: Vec<f64> = huge.iter().map(|s| f64::from(*s)).collect();
        let f32_frames = push_stereo(oscillux_dsp_push_f32, &huge);
        assert_eq!(f32_frames, push_stereo(oscillux_dsp_push_f64, &huge_f64));
        assert!(f32_frames.iter().all(|frame| frame.flags == 0));
        assert!(f32_frames[flagged].rms > 1e36);
    }

    #[test]
    fn oversized_buffers_are_rejected_before_pointer_access() {
        for (samples, frames) in [(usize::MAX / 4, 0), (0, usize::MAX / 8)] {
            assert_eq!(
                unsafe {
                    oscillux_dsp_push_f32(
                        null_mut(),
                        null(),
                        samples,
                        1,
                        null_mut(),
                        frames,
                        null_mut(),
                    )
                },
                OSCILLUX_ERR_INVALID_ARGUMENT,
            );
        }
    }

    #[test]
    fn null_and_invalid_arguments_are_refused() {
        let mut dsp = null_mut();
        let bad = DspConfig {
            fft_window_samples: 1000,
            ..DspConfig::default()
        };
        let mut result = OscilluxDspPushResult::default();
        let checks = [
            (
                unsafe { oscillux_dsp_config_default(null_mut()) },
                OSCILLUX_ERR_NULL,
            ),
            (
                unsafe { oscillux_dsp_create(null(), &mut dsp) },
                OSCILLUX_ERR_NULL,
            ),
            (
                unsafe { oscillux_dsp_create(&bad, &mut dsp) },
                OSCILLUX_ERR_INVALID_ARGUMENT,
            ),
            (
                unsafe { oscillux_dsp_begin_segment(null_mut(), 0.0, 0) },
                OSCILLUX_ERR_NULL,
            ),
            (
                unsafe {
                    oscillux_dsp_push_f32(null_mut(), null(), 0, 1, null_mut(), 0, &mut result)
                },
                OSCILLUX_ERR_NULL,
            ),
        ];
        for (i, (got, want)) in checks.into_iter().enumerate() {
            assert_eq!(got, want, "check {i}");
        }
        assert!(dsp.is_null());
        unsafe { oscillux_dsp_destroy(null_mut()) };
    }
    fn assert_f64_push(
        dsp: *mut OscilluxDsp,
        reference: &mut Analyzer,
        samples: &[f64],
        channels: usize,
        capacity: usize,
    ) -> usize {
        let mut output = vec![DspFrame::ZERO; capacity];
        let mut expected = vec![DspFrame::ZERO; capacity];
        let mut result = OscilluxDspPushResult::default();
        let pushed = reference.push(samples, channels, &mut expected).unwrap();
        assert_eq!(
            unsafe {
                oscillux_dsp_push_f64(
                    dsp,
                    samples.as_ptr(),
                    samples.len() / channels,
                    channels as u32,
                    output.as_mut_ptr(),
                    capacity,
                    &mut result,
                )
            },
            OSCILLUX_OK
        );
        assert_eq!(
            (result.consumed, result.produced),
            (pushed.consumed, pushed.produced)
        );
        assert_eq!(output, expected);
        for frame in &output[..result.produced] {
            assert!(frame.rms.is_finite() && frame.loudness_db.is_finite());
            assert!(frame.spectrum.iter().all(|value| value.is_finite()));
        }
        result.consumed
    }

    #[test]
    fn f64_stereo_chunking_backpressure_and_segments_equal_direct_core() {
        let cfg = DspConfig::default();
        let mut dsp = null_mut();
        assert_eq!(unsafe { oscillux_dsp_create(&cfg, &mut dsp) }, OSCILLUX_OK);
        let mut reference = Analyzer::new(cfg).unwrap();
        // Includes quiet precision-sensitive PCM, silence, attack/release and values near ±2.
        let samples: Vec<f64> = (0..16000)
            .map(|i| {
                let amplitude = match i / 4000 {
                    0 => 1e-7,
                    1 => 0.0,
                    2 => 1.9952623149688795,
                    _ => 0.03,
                };
                amplitude * ((i % 97) as f64 - 48.0) / 48.0
            })
            .collect();
        let mut consumed = assert_f64_push(dsp, &mut reference, &samples, 2, 0);
        assert!(consumed > 0 && consumed < samples.len() / 2);
        while consumed < samples.len() / 2 {
            let end = (consumed + 173).min(samples.len() / 2);
            let n = assert_f64_push(dsp, &mut reference, &samples[consumed * 2..end * 2], 2, 1);
            assert!(n > 0);
            consumed += n;
        }
        for (start, stalled) in [(1000.0, true), (1400.0, false)] {
            reference.begin_segment(start, stalled);
            assert_eq!(
                unsafe { oscillux_dsp_begin_segment(dsp, start, u32::from(stalled)) },
                OSCILLUX_OK
            );
            let n = assert_f64_push(dsp, &mut reference, &samples[..6000], 2, 8);
            assert_eq!(n, 3000);
        }
        unsafe { oscillux_dsp_destroy(dsp) };
    }

    #[test]
    fn mixed_f32_f64_calls_keep_one_stream_state() {
        let cfg = DspConfig::default();
        let mut dsp = null_mut();
        assert_eq!(unsafe { oscillux_dsp_create(&cfg, &mut dsp) }, OSCILLUX_OK);
        let mut reference = Analyzer::new(cfg).unwrap();
        let f32_samples: Vec<f32> = (0..2600).map(|i| ((i % 41) as f32 - 20.0) / 32.0).collect();
        let f64_samples: Vec<f64> = (0..2600)
            .map(|i| ((i % 53) as f64 - 26.0) / 64.0 + 1e-10)
            .collect();
        for _ in 0..2 {
            let mut output = [DspFrame::ZERO; 8];
            let mut expected = output;
            let mut result = OscilluxDspPushResult::default();
            let want = reference.push(&f32_samples, 1, &mut expected).unwrap();
            assert_eq!(
                unsafe {
                    oscillux_dsp_push_f32(
                        dsp,
                        f32_samples.as_ptr(),
                        f32_samples.len(),
                        1,
                        output.as_mut_ptr(),
                        output.len(),
                        &mut result,
                    )
                },
                OSCILLUX_OK
            );
            assert_eq!(
                (result.consumed, result.produced),
                (want.consumed, want.produced)
            );
            assert_eq!(output, expected);
            assert_eq!(
                assert_f64_push(dsp, &mut reference, &f64_samples, 1, 8),
                f64_samples.len()
            );
        }
        unsafe { oscillux_dsp_destroy(dsp) };
    }

    #[test]
    fn f64_invalid_calls_preserve_result_and_stream_state() {
        let cfg = DspConfig::default();
        let mut dsp = null_mut();
        assert_eq!(unsafe { oscillux_dsp_create(&cfg, &mut dsp) }, OSCILLUX_OK);
        let mut reference = Analyzer::new(cfg).unwrap();
        let mut result = OscilluxDspPushResult {
            consumed: 123,
            produced: 456,
        };
        assert_eq!(
            unsafe { oscillux_dsp_push_f64(dsp, null(), 0, 0, null_mut(), 0, &mut result) },
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!((result.consumed, result.produced), (123, 456));
        for (handle, input_len, channels, capacity, null_result) in [
            (dsp, 1, 1, 0, false),
            (dsp, 0, 1, 1, false),
            (dsp, 0, 1, 0, true),
            (null_mut(), 0, 1, 0, false),
        ] {
            let result_ptr = if null_result { null_mut() } else { &mut result };
            assert_eq!(
                unsafe {
                    oscillux_dsp_push_f64(
                        handle,
                        null(),
                        input_len,
                        channels,
                        null_mut(),
                        capacity,
                        result_ptr,
                    )
                },
                OSCILLUX_ERR_NULL
            );
            assert_eq!((result.consumed, result.produced), (123, 456));
        }
        for (frames, channels, capacity) in [
            (usize::MAX, 2, 0),
            (isize::MAX as usize / core::mem::size_of::<f64>() + 1, 1, 0),
            (
                0,
                1,
                isize::MAX as usize / core::mem::size_of::<DspFrame>() + 1,
            ),
        ] {
            assert_eq!(
                unsafe {
                    oscillux_dsp_push_f64(
                        dsp,
                        null(),
                        frames,
                        channels,
                        null_mut(),
                        capacity,
                        &mut result,
                    )
                },
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!((result.consumed, result.produced), (123, 456));
        }
        assert_eq!(
            unsafe { oscillux_dsp_push_f64(dsp, null(), 0, 1, null_mut(), 0, &mut result) },
            OSCILLUX_OK
        );
        assert_eq!((result.consumed, result.produced), (0, 0));
        let samples = vec![0.123456789012345; 6000];
        assert_eq!(
            assert_f64_push(dsp, &mut reference, &samples, 1, 16),
            samples.len()
        );
        unsafe { oscillux_dsp_destroy(dsp) };
    }

    /// Runs `oscillux_dsp_config_validate` and returns its status and reported field name.
    fn validate(config: &DspConfig) -> (i32, Option<String>) {
        let mut field: *const c_char = c"sentinel".as_ptr();
        let status = unsafe { oscillux_dsp_config_validate(config, &mut field) };
        let name = (!field.is_null()).then(|| {
            unsafe { CStr::from_ptr(field) }
                .to_str()
                .unwrap()
                .to_owned()
        });
        (status, name)
    }

    #[test]
    fn validate_names_each_offending_field_and_agrees_with_create() {
        let base = DspConfig::default();
        assert_eq!(validate(&base), (OSCILLUX_OK, None));
        let cases: [(&str, DspConfig); 15] = [
            (
                "sample_rate_hz",
                DspConfig {
                    sample_rate_hz: 0,
                    ..base
                },
            ),
            (
                "fft_window_samples",
                DspConfig {
                    fft_window_samples: 1000,
                    ..base
                },
            ),
            (
                "hop_samples",
                DspConfig {
                    hop_samples: 0,
                    ..base
                },
            ),
            (
                "spectrum_bands",
                DspConfig {
                    spectrum_bands: 65,
                    ..base
                },
            ),
            (
                "spectrum_min_hz",
                DspConfig {
                    spectrum_min_hz: 0.0,
                    ..base
                },
            ),
            (
                "spectrum_max_hz",
                DspConfig {
                    spectrum_max_hz: base.spectrum_min_hz,
                    ..base
                },
            ),
            (
                "db_floor",
                DspConfig {
                    db_floor: 0.0,
                    ..base
                },
            ),
            (
                "ballistics_attack_ms",
                DspConfig {
                    ballistics_attack_ms: 0.0,
                    ..base
                },
            ),
            (
                "ballistics_release_ms",
                DspConfig {
                    ballistics_release_ms: -1.0,
                    ..base
                },
            ),
            (
                "rms_window_ms",
                DspConfig {
                    rms_window_ms: 0.0,
                    ..base
                },
            ),
            (
                "loudness_reference_lufs",
                DspConfig {
                    loudness_reference_lufs: f64::NAN,
                    ..base
                },
            ),
            (
                "rms_floor",
                DspConfig {
                    rms_floor: 0.0,
                    ..base
                },
            ),
            (
                "onset_peak_decay",
                DspConfig {
                    onset_peak_decay: 1.5,
                    ..base
                },
            ),
            (
                "onset_peak_floor",
                DspConfig {
                    onset_peak_floor: 0.0,
                    ..base
                },
            ),
            (
                "onset_band_groups",
                DspConfig {
                    onset_band_groups: [[0, 99], [0, 1], [2, 3]],
                    ..base
                },
            ),
        ];
        for (want, config) in cases {
            assert_eq!(
                validate(&config),
                (OSCILLUX_ERR_INVALID_ARGUMENT, Some(want.to_owned())),
                "{want}"
            );
            let mut dsp = null_mut();
            assert_eq!(
                unsafe { oscillux_dsp_create(&config, &mut dsp) },
                OSCILLUX_ERR_INVALID_ARGUMENT,
                "{want}"
            );
            assert!(dsp.is_null());
        }
    }

    #[test]
    fn validate_handles_null_arguments() {
        let mut field: *const c_char = c"sentinel".as_ptr();
        assert_eq!(
            unsafe { oscillux_dsp_config_validate(null(), &mut field) },
            OSCILLUX_ERR_NULL
        );
        assert!(field.is_null());
        let bad = DspConfig {
            hop_samples: 0,
            ..DspConfig::default()
        };
        assert_eq!(
            unsafe { oscillux_dsp_config_validate(&bad, null_mut()) },
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            unsafe { oscillux_dsp_config_validate(&DspConfig::default(), null_mut()) },
            OSCILLUX_OK
        );
    }

    #[test]
    fn unknown_errors_fall_back_to_the_whole_config() {
        assert_eq!(
            blamed_field(DspError::InvalidConfig("added_later")),
            WHOLE_CONFIG
        );
        assert_eq!(blamed_field(DspError::InvalidChannels), WHOLE_CONFIG);
        assert_eq!(blamed_field(DspError::Wav("header")), WHOLE_CONFIG);
    }

    /// Runs `oscillux_dsp_versioned_config_validate` and returns its status and field name.
    fn validate_versioned(config: &OscilluxDspVersionedConfig) -> (i32, Option<String>) {
        let mut field: *const c_char = c"sentinel".as_ptr();
        let status = unsafe { oscillux_dsp_versioned_config_validate(config, &mut field) };
        let name = (!field.is_null()).then(|| {
            unsafe { CStr::from_ptr(field) }
                .to_str()
                .unwrap()
                .to_owned()
        });
        (status, name)
    }

    /// The mono signal the versioned-create tests push.
    fn test_signal() -> Vec<f32> {
        (0..9000).map(|i| ((i % 89) as f32 - 44.0) / 64.0).collect()
    }

    /// Frames from the analyzer `create` makes for [`test_signal`], or `create`'s status.
    fn frames_from(
        create: impl FnOnce(*mut *mut OscilluxDsp) -> i32,
    ) -> Result<Vec<DspFrame>, i32> {
        let mut dsp = null_mut();
        let status = create(&mut dsp);
        if status != OSCILLUX_OK {
            assert!(dsp.is_null());
            return Err(status);
        }
        let samples = test_signal();
        let mut out = [DspFrame::ZERO; 32];
        let mut result = OscilluxDspPushResult::default();
        let rc = unsafe {
            oscillux_dsp_push_f32(
                dsp,
                samples.as_ptr(),
                samples.len(),
                1,
                out.as_mut_ptr(),
                out.len(),
                &mut result,
            )
        };
        unsafe { oscillux_dsp_destroy(dsp) };
        assert_eq!(rc, OSCILLUX_OK);
        Ok(out[..result.produced].to_vec())
    }

    /// Frames the core analyzer produces for [`test_signal`] under `settings`.
    fn core_frames(settings: DspSettings) -> Vec<DspFrame> {
        let mut analyzer = Analyzer::new(settings).unwrap();
        let mut frames = [DspFrame::ZERO; 32];
        let pushed = analyzer.push(&test_signal(), 1, &mut frames).unwrap();
        assert!(pushed.produced > 0);
        frames[..pushed.produced].to_vec()
    }

    #[test]
    fn versioned_default_is_version_2_and_requires_the_released_size() {
        let mut out = OscilluxDspVersionedConfig {
            struct_size: DSP_VERSIONED_CONFIG_SIZE,
            config: DspConfig {
                hop_samples: 0,
                ..DspConfig::default()
            },
            behavior_version: 0,
            reserved: 7,
        };
        assert_eq!(DSP_VERSIONED_CONFIG_SIZE, 144);
        assert_eq!(
            core::mem::offset_of!(OscilluxDspVersionedConfig, reserved),
            140,
            "reserved fills the tail, so the next member changes the size"
        );
        assert_eq!(
            unsafe { oscillux_dsp_versioned_config_default(&mut out) },
            OSCILLUX_OK
        );
        assert_eq!(out.behavior_version, OSCILLUX_DSP_BEHAVIOR_V2);
        assert_eq!(out.reserved, 0);
        assert_eq!(out.config, DspConfig::default());
        assert_eq!(validate_versioned(&out), (OSCILLUX_OK, None));
        for size in [0, 136, 128, 145, u32::MAX] {
            let mut wrong = OscilluxDspVersionedConfig {
                struct_size: size,
                ..OscilluxDspVersionedConfig::default()
            };
            let before = wrong;
            assert_eq!(
                unsafe { oscillux_dsp_versioned_config_default(&mut wrong) },
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(wrong, before, "a refused default writes nothing");
            assert_eq!(
                validate_versioned(&wrong),
                (OSCILLUX_ERR_INVALID_ARGUMENT, Some("struct_size".into()))
            );
            let created = frames_from(|dsp| unsafe { oscillux_dsp_create_versioned(&wrong, dsp) });
            assert_eq!(created, Err(OSCILLUX_ERR_INVALID_ARGUMENT));
        }
        assert_eq!(
            unsafe { oscillux_dsp_versioned_config_default(null_mut()) },
            OSCILLUX_ERR_NULL
        );
    }

    #[test]
    fn versioned_validate_names_struct_size_members_and_behavior_version() {
        let bad_hop = OscilluxDspVersionedConfig {
            config: DspConfig {
                hop_samples: 0,
                ..DspConfig::default()
            },
            ..OscilluxDspVersionedConfig::default()
        };
        assert_eq!(
            validate_versioned(&bad_hop),
            (OSCILLUX_ERR_INVALID_ARGUMENT, Some("hop_samples".into()))
        );
        for version in [0, 5, u32::MAX] {
            let bad_version = OscilluxDspVersionedConfig {
                behavior_version: version,
                ..OscilluxDspVersionedConfig::default()
            };
            assert_eq!(
                validate_versioned(&bad_version),
                (
                    OSCILLUX_ERR_INVALID_ARGUMENT,
                    Some("behavior_version".into())
                )
            );
            let created =
                frames_from(|dsp| unsafe { oscillux_dsp_create_versioned(&bad_version, dsp) });
            assert_eq!(created, Err(OSCILLUX_ERR_INVALID_ARGUMENT));
        }
        let mut field: *const c_char = c"sentinel".as_ptr();
        assert_eq!(
            unsafe { oscillux_dsp_versioned_config_validate(null(), &mut field) },
            OSCILLUX_ERR_NULL
        );
        assert!(field.is_null());
        assert_eq!(
            unsafe { oscillux_dsp_versioned_config_validate(&bad_hop, null_mut()) },
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        let mut dsp = null_mut::<OscilluxDsp>();
        assert_eq!(
            unsafe { oscillux_dsp_create_versioned(null(), &mut dsp) },
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            unsafe {
                oscillux_dsp_create_versioned(&OscilluxDspVersionedConfig::default(), null_mut())
            },
            OSCILLUX_ERR_NULL
        );
    }

    #[test]
    fn versioned_config_refuses_a_nonzero_reserved() {
        for reserved in [1, 0x8000_0000, u32::MAX] {
            let config = OscilluxDspVersionedConfig {
                reserved,
                ..OscilluxDspVersionedConfig::default()
            };
            assert_eq!(
                validate_versioned(&config),
                (OSCILLUX_ERR_INVALID_ARGUMENT, Some("reserved".into()))
            );
            let created = frames_from(|dsp| unsafe { oscillux_dsp_create_versioned(&config, dsp) });
            assert_eq!(created, Err(OSCILLUX_ERR_INVALID_ARGUMENT));
            // A wrong struct_size or an invalid member is still named first.
            let bad_version = OscilluxDspVersionedConfig {
                behavior_version: 5,
                ..config
            };
            assert_eq!(
                validate_versioned(&bad_version).1.as_deref(),
                Some("behavior_version")
            );
            let bad_size = OscilluxDspVersionedConfig {
                struct_size: 140,
                ..config
            };
            assert_eq!(
                validate_versioned(&bad_size).1.as_deref(),
                Some("struct_size")
            );
        }
    }

    #[test]
    fn versioned_create_runs_the_selected_version_and_abi_1_create_stays_version_1() {
        let v2 = OscilluxDspVersionedConfig::default();
        let v1 = OscilluxDspVersionedConfig {
            behavior_version: OSCILLUX_DSP_BEHAVIOR_V1,
            ..v2
        };
        let got_v2 = frames_from(|dsp| unsafe { oscillux_dsp_create_versioned(&v2, dsp) });
        let got_v1 = frames_from(|dsp| unsafe { oscillux_dsp_create_versioned(&v1, dsp) });
        let abi_1 = frames_from(|dsp| unsafe { oscillux_dsp_create(&DspConfig::default(), dsp) });
        assert_eq!(got_v2.unwrap(), core_frames(DspSettings::default()));
        assert_eq!(
            got_v1.clone().unwrap(),
            core_frames(DspConfig::default().into())
        );
        assert_eq!(abi_1, got_v1);
        assert_ne!(
            abi_1,
            frames_from(|dsp| unsafe { oscillux_dsp_create_versioned(&v2, dsp) })
        );
    }

    #[test]
    fn reported_names_are_the_header_member_names() {
        let header = include_str!("../../../ffi/include/oscillux.h");
        let body = header
            .split("typedef struct OscilluxDspConfig {")
            .nth(1)
            .and_then(|rest| rest.split("} OscilluxDspConfig;").next())
            .expect("OscilluxDspConfig in header");
        let members: Vec<&str> = body
            .lines()
            // Code precedes any comment; comment continuation lines start with '*'.
            .map(|line| line.split('/').next().unwrap().trim())
            .filter(|code| code.ends_with(';') && !code.starts_with('*'))
            .map(|code| {
                let declarator = code
                    .trim_end_matches(';')
                    .split_whitespace()
                    .last()
                    .unwrap();
                declarator.split('[').next().unwrap()
            })
            .collect();
        let reported: Vec<&str> = CONFIG_FIELDS.iter().map(|f| f.to_str().unwrap()).collect();
        assert_eq!(reported, members);
    }

    fn stereo_test_signal(frames: usize) -> Vec<f64> {
        (0..frames * 2)
            .map(|i| {
                let t = (i / 2) as f64 / 48_000.0;
                let tone = (2.0 * core::f64::consts::PI * 997.0 * t).sin();
                if i % 2 == 0 {
                    0.5 * tone
                } else {
                    -0.25 * tone + 0.01
                }
            })
            .collect()
    }

    fn new_dsp(behavior_version: u32) -> *mut OscilluxDsp {
        let config = OscilluxDspVersionedConfig {
            behavior_version,
            ..OscilluxDspVersionedConfig::default()
        };
        let mut dsp = null_mut();
        assert_eq!(
            unsafe { oscillux_dsp_create_versioned(&config, &mut dsp) },
            OSCILLUX_OK
        );
        dsp
    }

    #[test]
    fn push_ext_frames_equal_push_and_ext_equals_the_core_on_every_version() {
        let samples = stereo_test_signal(30_000);
        let narrow: Vec<f32> = samples.iter().map(|&v| v as f32).collect();
        for version in [
            DSP_BEHAVIOR_V1,
            DSP_BEHAVIOR_V2,
            DSP_BEHAVIOR_V3,
            DSP_BEHAVIOR_V4,
        ] {
            let (plain, ext_dsp) = (new_dsp(version), new_dsp(version));
            let mut core = Analyzer::new(DspSettings {
                behavior_version: version,
                ..DspSettings::default()
            })
            .unwrap();
            let mut consumed = 0;
            let mut frames = 0;
            let mut chunk = 0;
            while consumed < samples.len() / 2 {
                let end = (consumed + 700 + 37 * chunk).min(samples.len() / 2);
                let wide = chunk % 2 == 0;
                let capacity = 1 + chunk % 3;
                let mut want = vec![DspFrame::ZERO; capacity];
                let mut want_ext = vec![FrameExt::ZERO; capacity];
                let mut got = vec![DspFrame::ZERO; capacity];
                let mut got_plain = vec![DspFrame::ZERO; capacity];
                let mut ext = vec![OscilluxDspFrameExt::default(); capacity];
                let (mut r, mut r_plain) = (
                    OscilluxDspPushResult::default(),
                    OscilluxDspPushResult::default(),
                );
                let (rc, rc_plain, pushed) = unsafe {
                    if wide {
                        let input = &samples[consumed * 2..end * 2];
                        (
                            oscillux_dsp_push_ext_f64(
                                ext_dsp,
                                input.as_ptr(),
                                end - consumed,
                                2,
                                got.as_mut_ptr(),
                                ext.as_mut_ptr(),
                                capacity,
                                &mut r,
                            ),
                            oscillux_dsp_push_f64(
                                plain,
                                input.as_ptr(),
                                end - consumed,
                                2,
                                got_plain.as_mut_ptr(),
                                capacity,
                                &mut r_plain,
                            ),
                            core.push_ext(input, 2, &mut want, &mut want_ext).unwrap(),
                        )
                    } else {
                        let input = &narrow[consumed * 2..end * 2];
                        (
                            oscillux_dsp_push_ext_f32(
                                ext_dsp,
                                input.as_ptr(),
                                end - consumed,
                                2,
                                got.as_mut_ptr(),
                                ext.as_mut_ptr(),
                                capacity,
                                &mut r,
                            ),
                            oscillux_dsp_push_f32(
                                plain,
                                input.as_ptr(),
                                end - consumed,
                                2,
                                got_plain.as_mut_ptr(),
                                capacity,
                                &mut r_plain,
                            ),
                            core.push_ext(input, 2, &mut want, &mut want_ext).unwrap(),
                        )
                    }
                };
                assert_eq!((rc, rc_plain), (OSCILLUX_OK, OSCILLUX_OK));
                assert_eq!(r, r_plain);
                assert_eq!((r.consumed, r.produced), (pushed.consumed, pushed.produced));
                for i in 0..r.produced {
                    assert_eq!(got[i].sequence, got_plain[i].sequence);
                    assert_eq!(format!("{:?}", got[i]), format!("{:?}", got_plain[i]));
                    assert_eq!(got[i], want[i]);
                    assert_eq!(
                        ext[i].struct_size as usize,
                        size_of::<OscilluxDspFrameExt>()
                    );
                    assert_eq!(ext[i].reserved, 0);
                    assert_eq!(ext[i].descriptors, want_ext[i].descriptors);
                    assert_eq!(ext[i].beat, want_ext[i].beat);
                    assert_eq!(ext[i].levels, want_ext[i].levels);
                }
                for e in &ext[r.produced..] {
                    assert_eq!(*e, OscilluxDspFrameExt::default());
                }
                frames += r.produced;
                consumed += r.consumed;
                chunk += 1;
            }
            assert!(frames > 50, "{frames}");
            unsafe {
                oscillux_dsp_destroy(plain);
                oscillux_dsp_destroy(ext_dsp);
            }
        }
    }

    #[test]
    fn bad_ext_arrays_are_refused_before_any_input_is_consumed() {
        let samples = stereo_test_signal(6000);
        let dsp = new_dsp(DSP_BEHAVIOR_V2);
        let mut out = [DspFrame::ZERO; 4];
        let mut storage = [OscilluxDspFrameExt::default(); 9];
        let size = size_of::<OscilluxDspFrameExt>() as u32;
        let push = |ext: *mut OscilluxDspFrameExt, out: &mut [DspFrame; 4], capacity: usize| {
            let mut result = OscilluxDspPushResult {
                consumed: 7,
                produced: 9,
            };
            let rc = unsafe {
                oscillux_dsp_push_ext_f64(
                    dsp,
                    samples.as_ptr(),
                    6000,
                    2,
                    out.as_mut_ptr(),
                    ext,
                    capacity,
                    &mut result,
                )
            };
            (rc, result)
        };
        // (name, element, struct_size, reserved) written into an otherwise valid array.
        let cases = [
            ("zero size", 0, 0, 0),
            ("header only", 0, 8, 0),
            ("descriptors without header", 0, 48, 0),
            ("between sections", 0, 64, 0),
            ("beat without header", 0, 96, 0),
            ("mixed section-end sizes", 1, 56, 0),
            ("one byte short", 0, size - 1, 0),
            ("one byte long", 0, size + 1, 0),
            ("next multiple", 0, size + 8, 0),
            ("reserved first", 0, size, 1),
            ("reserved last", 3, size, 0x8000_0000),
            ("later size differs", 2, 0, 0),
        ];
        for (name, index, struct_size, reserved) in cases {
            let mut ext = storage;
            ext[index].struct_size = struct_size;
            ext[index].reserved = reserved;
            let (rc, result) = push(ext.as_mut_ptr(), &mut out, 4);
            assert_eq!(rc, OSCILLUX_ERR_INVALID_ARGUMENT, "{name}");
            assert_eq!((result.consumed, result.produced), (7, 9), "{name}");
        }
        let misaligned = unsafe { storage.as_mut_ptr().cast::<u8>().add(4).cast() };
        assert_eq!(
            push(misaligned, &mut out, 4).0,
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(push(null_mut(), &mut out, 4).0, OSCILLUX_ERR_NULL);
        assert_eq!(
            push(storage.as_mut_ptr(), &mut out, usize::MAX / 4).0,
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        // Null ext with no output is accepted; the stream then continues as if the refused
        // calls never happened.
        let (rc, first) = push(null_mut(), &mut out, 0);
        assert_eq!((rc, first.produced), (OSCILLUX_OK, 0));
        let (rc, result) = unsafe {
            let mut result = OscilluxDspPushResult::default();
            let rest = &samples[first.consumed * 2..];
            let rc = oscillux_dsp_push_ext_f64(
                dsp,
                rest.as_ptr(),
                rest.len() / 2,
                2,
                out.as_mut_ptr(),
                storage.as_mut_ptr(),
                4,
                &mut result,
            );
            (rc, result)
        };
        assert_eq!(rc, OSCILLUX_OK);
        let mut core = Analyzer::new(DspSettings::default()).unwrap();
        let mut want = [DspFrame::ZERO; 4];
        let mut want_ext = [FrameExt::ZERO; 4];
        let pushed = core
            .push_ext(
                &samples[..(first.consumed + result.consumed) * 2],
                2,
                &mut want,
                &mut want_ext,
            )
            .unwrap();
        assert_eq!(pushed.produced, result.produced);
        assert_eq!(out[..result.produced], want[..result.produced]);
        for i in 0..result.produced {
            assert_eq!(storage[i].descriptors, want_ext[i].descriptors);
            assert_eq!(storage[i].beat, want_ext[i].beat);
            assert_eq!(storage[i].levels, want_ext[i].levels);
        }
        unsafe { oscillux_dsp_destroy(dsp) };
    }

    #[test]
    fn ext_writes_follow_struct_size_and_touch_only_the_target_sections() {
        // For every section end, struct_size alone sets the stride, and a write fills only
        // the sections that end within it, in its own element, leaving struct_size, reserved,
        // later sections and every other element's bytes alone.
        let mut value = FrameExt::ZERO;
        value.descriptors.width = 0.25;
        value.beat.tempo_bpm = 120.0;
        value.beat.reserved = 7;
        value.levels.band_count = 32;
        value.levels.relative_bands[63] = 0.5;
        assert_eq!(FRAME_EXT_SIZES, [56, 104, 672]);
        for size in FRAME_EXT_SIZES {
            let image = OscilluxDspFrameExt {
                struct_size: size as u32,
                reserved: 0,
                descriptors: value.descriptors,
                beat: value.beat,
                levels: value.levels,
            };
            let mut bytes = vec![0xA5u8; size * 3 + 8];
            let base = bytes
                .as_mut_ptr()
                .wrapping_add(bytes.as_ptr().align_offset(8));
            unsafe {
                // The struct has no padding, so its bytes are the expected element.
                let image = core::slice::from_raw_parts(
                    (&image as *const OscilluxDspFrameExt).cast::<u8>(),
                    size_of::<OscilluxDspFrameExt>(),
                );
                for i in 0..3 {
                    let element = base.add(i * size).cast::<OscilluxDspFrameExt>();
                    core::ptr::addr_of_mut!((*element).struct_size).write(size as u32);
                    core::ptr::addr_of_mut!((*element).reserved).write(0);
                }
                assert_eq!(frame_ext_stride(base.cast(), 3), Ok(size));
                write_frame_ext(base, size, 1, &value);
                let got = core::slice::from_raw_parts(base, size * 3);
                assert_eq!(&got[size..size * 2], &image[..size], "size {size}");
                for i in [0, 2] {
                    assert_eq!(&got[i * size..i * size + 8], &image[..8], "size {size}");
                    assert!(got[i * size + 8..(i + 1) * size].iter().all(|&b| b == 0xA5));
                }
            }
        }
    }
}
