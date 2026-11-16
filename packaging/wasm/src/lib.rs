// SPDX-License-Identifier: AGPL-3.0-only
//! wasm-bindgen adapter over the C interface in `ffi/include/oscillux.h`.
//!
//! Every header export is either called here or listed with a reason in `docs/packaging.md`;
//! `tests/coverage.rs` fails when one is neither. Handles own caller-visible buffers that are
//! allocated once at construction, so frame calls (`push`, `pushF64`, `pushExt`, `pushExtF64`,
//! `process`, `processExt`, `measure`, `admit`, `measureRgb`, `admitRgb`, `evaluate`, `record`,
//! `pack`, and the transition `request`, `update`, `status`) do not allocate. Neither do the CD+G
//! frame calls (`advanceToTime`, `advanceToPack`, `state`, `screen`, `windowRgba`).
//! Configuration objects are plain value classes whose constructors write the C defaults.
use core::ffi::{c_char, CStr};
use core::ptr::null_mut;

use oscillux::cdg::{
    oscillux_cdg_advance_to_pack, oscillux_cdg_advance_to_time, oscillux_cdg_create,
    oscillux_cdg_destroy, oscillux_cdg_index_counts, oscillux_cdg_screen, oscillux_cdg_state,
    oscillux_cdg_window_rgba, OscilluxCdg, OscilluxCdgState,
};
use oscillux::curves::{
    oscillux_curve_config_default, oscillux_curve_create, oscillux_curve_destroy,
    oscillux_curve_evaluate, OscilluxCurve, OscilluxCurveConfig, OscilluxCurveInput,
};
use oscillux::dsp::{
    oscillux_dsp_begin_segment, oscillux_dsp_create_versioned, oscillux_dsp_destroy,
    oscillux_dsp_push_ext_f32, oscillux_dsp_push_ext_f64, oscillux_dsp_push_f32,
    oscillux_dsp_push_f64, oscillux_dsp_versioned_config_default,
    oscillux_dsp_versioned_config_validate, OscilluxDsp, OscilluxDspFrameExt,
    OscilluxDspPushResult, OscilluxDspVersionedConfig,
};
use oscillux::governor::{
    oscillux_governor_config_default, oscillux_governor_create, oscillux_governor_destroy,
    oscillux_governor_record, oscillux_governor_reset, OscilluxGovernor, OscilluxGovernorConfig,
    OscilluxGovernorStats,
};
use oscillux::limiter::{
    oscillux_flash_analyzer_admit, oscillux_flash_analyzer_admit_rgb,
    oscillux_flash_analyzer_create, oscillux_flash_analyzer_destroy,
    oscillux_flash_analyzer_measure, oscillux_flash_analyzer_measure_rgb,
    oscillux_flash_analyzer_reset, oscillux_flash_config_default,
    oscillux_flash_region_from_linear_rgb, oscillux_limiter_create, oscillux_limiter_destroy,
    oscillux_limiter_policy_default, oscillux_limiter_process, oscillux_limiter_reset,
    OscilluxFlashAnalyzer, OscilluxFlashColor, OscilluxFlashConfig, OscilluxFlashRegion,
    OscilluxFlashReport, OscilluxLimiter, OscilluxLimiterFrame, OscilluxLimiterPolicy,
};
use oscillux::limiter::{
    oscillux_flash_analyzer_overlay_report, oscillux_flash_analyzer_set_overlay,
    oscillux_flash_overlay_default, OscilluxFlashOverlay, OscilluxFlashOverlayReport,
    FLASH_OVERLAY_REPORT_SIZE,
};
use oscillux::mapping::{
    oscillux_mapping_config_default, oscillux_mapping_config_from_dsp, oscillux_mapping_create,
    oscillux_mapping_destroy, oscillux_mapping_process, oscillux_mapping_process_ext,
    oscillux_mapping_reset, oscillux_mapping_set_level_source, OscilluxMapped, OscilluxMapper,
    OscilluxMappingConfig,
};
use oscillux::overlay::{
    oscillux_overlay_config_default, oscillux_overlay_flash_config, oscillux_overlay_pack,
    oscillux_overlay_presentation_intensity, OscilluxOverlayConfig, OscilluxOverlayRegion,
    OSCILLUX_OVERLAY_MAX_REGIONS, OSCILLUX_OVERLAY_UNIFORMS_SIZE,
};
use oscillux::packing::{
    oscillux_packer_create, oscillux_packer_destroy, oscillux_packer_pack, OscilluxPacker,
    OscilluxUniformField,
};
use oscillux::{OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_OK};
use oscillux_core::dsp::{DspConfig as CDspConfig, DspFrame};
use wasm_bindgen::prelude::*;

const INVALID: i32 = OSCILLUX_ERR_INVALID_ARGUMENT;

/// Returns `OSCILLUX_ABI_VERSION` of the linked core.
#[wasm_bindgen(js_name = abiVersion)]
pub fn abi_version() -> u32 {
    oscillux::oscillux_abi_version()
}

/// Release version of the linked core, packed as `major << 16 | minor << 8 | patch`.
#[wasm_bindgen]
pub fn version() -> u32 {
    oscillux::oscillux_version()
}

/// Short English description of a status code (0 ok, -1 null, -2 invalid argument, -3 panic).
#[wasm_bindgen(js_name = statusString)]
pub fn status_string(status: i32) -> String {
    // SAFETY: the C contract returns a static, NUL-terminated, never-null string.
    let text = unsafe { CStr::from_ptr(oscillux::oscillux_status_string(status)) };
    text.to_string_lossy().into_owned()
}

/// The wasm memory every `*Ptr()` offset refers to. Obtain views after constructing adapters
/// and recreate them after any memory growth.
#[wasm_bindgen(js_name = wasmMemory, unchecked_return_type = "WebAssembly.Memory")]
pub fn wasm_memory() -> JsValue {
    wasm_bindgen::memory()
}

/// Turns a refused create into an `Error` naming the status.
fn refused(what: &str, status: i32) -> JsError {
    JsError::new(&format!("{what}: {}", status_string(status)))
}

/// Getter/setter pairs exposing the wrapped C struct's fields under camelCase names.
macro_rules! fields {
    ($class:ident { $($(#[$doc:meta])* $field:ident, $set:ident, $js:ident: $ty:ty;)* }) => {
        #[wasm_bindgen]
        impl $class {
            $(
                $(#[$doc])*
                #[wasm_bindgen(getter = $js)]
                pub fn $field(&self) -> $ty {
                    self.0.$field
                }
                #[wasm_bindgen(setter = $js)]
                pub fn $set(&mut self, value: $ty) {
                    self.0.$field = value;
                }
            )*
        }
    };
}

/// Inclusive band range `[start, end]` from a group table, or an error for a bad index.
fn group(groups: &[[u32; 2]], index: u32) -> Result<Vec<u32>, JsError> {
    groups
        .get(index as usize)
        .map(|g| g.to_vec())
        .ok_or_else(|| JsError::new("group index"))
}

fn set_group(groups: &mut [[u32; 2]], index: u32, start: u32, end: u32) -> Result<(), JsError> {
    let slot = groups
        .get_mut(index as usize)
        .ok_or_else(|| JsError::new("group index"))?;
    *slot = [start, end];
    Ok(())
}

// ==== DSP ====================================================================================

/// `OscilluxDspFrame.flags` bits.
#[wasm_bindgen]
pub enum DspFlag {
    Gap = 1,
    Stalled = 2,
    InputReplaced = 4,
}

/// Analysis parameters (`OscilluxDspConfig`) and DSP behaviour version, passed to C as an
/// `OscilluxDspVersionedConfig`; the constructor writes the reference values and version 2.
/// Its `reserved` member is not exposed and is always passed as 0.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct DspConfig(CDspConfig, u32);

impl DspConfig {
    fn versioned(&self) -> OscilluxDspVersionedConfig {
        OscilluxDspVersionedConfig {
            config: self.0,
            behavior_version: self.1,
            ..OscilluxDspVersionedConfig::default()
        }
    }
}

#[wasm_bindgen]
impl DspConfig {
    #[wasm_bindgen(constructor)]
    pub fn new() -> DspConfig {
        let mut config = OscilluxDspVersionedConfig::default();
        // SAFETY: `config` is a valid, exclusive destination carrying the released struct_size.
        unsafe { oscillux_dsp_versioned_config_default(&mut config) };
        DspConfig(config.config, config.behavior_version)
    }
    /// The first member `new Dsp` would refuse, spelled as in oscillux.h (for example
    /// "fft_window_samples" or "behavior_version"), or undefined when the configuration is
    /// valid.
    pub fn validate(&self) -> Option<String> {
        let mut field: *const c_char = core::ptr::null();
        // SAFETY: both pointers are valid; a non-null field is static and NUL-terminated.
        let status =
            unsafe { oscillux_dsp_versioned_config_validate(&self.versioned(), &mut field) };
        if status == OSCILLUX_OK {
            return None;
        }
        if field.is_null() {
            return Some("config".into());
        }
        // SAFETY: see above.
        Some(
            unsafe { CStr::from_ptr(field) }
                .to_string_lossy()
                .into_owned(),
        )
    }
    /// Onset band group `group` (0 low, 1 mid, 2 high) as `[start, end]`, inclusive.
    #[wasm_bindgen(js_name = onsetBandGroup)]
    pub fn onset_band_group(
        &self,
        #[wasm_bindgen(js_name = groupIndex)] group_index: u32,
    ) -> Result<Vec<u32>, JsError> {
        group(&self.0.onset_band_groups, group_index)
    }
    #[wasm_bindgen(js_name = setOnsetBandGroup)]
    pub fn set_onset_band_group(
        &mut self,
        group: u32,
        start: u32,
        end: u32,
    ) -> Result<(), JsError> {
        set_group(&mut self.0.onset_band_groups, group, start, end)
    }
    /// DSP behaviour version: 1 (`OSCILLUX_DSP_BEHAVIOR_V1`, the ABI-1 analysis), 2 (the
    /// default; real-input FFT, low-band bass analysis and normalised onsets), 3 (version 2
    /// frames with the autocorrelation beat tracker) or 4 (version 2 frames with the
    /// beat-pointer beat tracker).
    #[wasm_bindgen(getter = behaviorVersion)]
    pub fn behavior_version(&self) -> u32 {
        self.1
    }
    #[wasm_bindgen(setter = behaviorVersion)]
    pub fn set_behavior_version(&mut self, value: u32) {
        self.1 = value;
    }
}

impl Default for DspConfig {
    fn default() -> Self {
        Self::new()
    }
}

fields!(DspConfig {
    /// Input sample rate, Hz.
    sample_rate_hz, set_sample_rate_hz, sampleRateHz: u32;
    /// Window and FFT length, samples; a power of two.
    fft_window_samples, set_fft_window_samples, fftWindowSamples: u32;
    /// Samples between frames.
    hop_samples, set_hop_samples, hopSamples: u32;
    /// Log-spaced bands, 1 ..= 64.
    spectrum_bands, set_spectrum_bands, spectrumBands: u32;
    /// Lower edge of the first band, Hz.
    spectrum_min_hz, set_spectrum_min_hz, spectrumMinHz: f64;
    /// Upper band edge, Hz; at most half the sample rate.
    spectrum_max_hz, set_spectrum_max_hz, spectrumMaxHz: f64;
    /// Band level mapped to 0, dB; negative.
    db_floor, set_db_floor, dbFloor: f64;
    /// Band smoothing time constant while rising, ms.
    ballistics_attack_ms, set_ballistics_attack_ms, ballisticsAttackMs: f64;
    /// Band smoothing time constant while falling, ms.
    ballistics_release_ms, set_ballistics_release_ms, ballisticsReleaseMs: f64;
    /// RMS window, ms.
    rms_window_ms, set_rms_window_ms, rmsWindowMs: f64;
    /// Subtracted from the RMS level for loudnessDb, dB.
    loudness_reference_lufs, set_loudness_reference_lufs, loudnessReferenceLufs: f64;
    /// Linear RMS lower bound before the logarithm.
    rms_floor, set_rms_floor, rmsFloor: f64;
    /// Per-frame decay factor of running onset peaks, 0 ..= 1.
    onset_peak_decay, set_onset_peak_decay, onsetPeakDecay: f64;
    /// Lower bound of an onset peak used as a divisor.
    onset_peak_floor, set_onset_peak_floor, onsetPeakFloor: f64;
    /// Segment lateness tolerated before the Gap flag, hops.
    gap_tolerance_hops, set_gap_tolerance_hops, gapToleranceHops: u32;
});

/// Streaming analyzer (`OscilluxDsp`) with preallocated PCM input and frame output buffers:
/// a Float32 input for `push` and, when constructed with an `f64Capacity`, a Float64 input for
/// `pushF64`.
/// Frames use the `OscilluxDspFrame` layout of the included oscillux.h, `frameBytes()` apart;
/// read `sequence` with `DataView.getBigUint64(offset, true)`. `pushExt` and `pushExtF64` also
/// write one `OscilluxDspFrameExt` per frame at `extPtr()`, `extBytes()` apart. The first of
/// them allocates that buffer (`frameCapacity` elements of 672 bytes), so refresh typed-array
/// views after it; a `Dsp` that only uses `push` or `pushF64` never allocates it. Its
/// descriptors are little-endian Float64 at byte 8 (momentaryLufs), 16 (shortTermLufs), 24
/// (width), 32 (balance), 40 (centroidHz) and 48 (spectralFlux). The beat follows as Float64
/// at 56 (tempoBpm), 64 (beatPhase), 72 (barPhase) and 80 (confidence) and Uint32 at 88
/// (beat), 92 (downbeat), 96 (beatInBar) and 100 (reserved). The levels follow: Uint32 at
/// 104 (bandCount) and 108 (reserved), then Float64 relative groups (low, mid, high) at 112,
/// 120 and 128, absolute groups at 136, 144 and 152, and 64 relative bands from 160.
#[wasm_bindgen]
pub struct Dsp {
    handle: *mut OscilluxDsp,
    input: Box<[f32]>,
    input_f64: Box<[f64]>,
    output: Box<[DspFrame]>,
    /// Empty until the first `pushExt` or `pushExtF64`, then `output.len()` elements.
    ext: Box<[OscilluxDspFrameExt]>,
    consumed: u32,
    produced: u32,
    ext_produced: bool,
}

#[wasm_bindgen]
impl Dsp {
    /// Validates `config` and allocates room for `sampleCapacity` interleaved Float32 PCM
    /// samples, `frameCapacity` output frames and `f64Capacity` (default 0) interleaved Float64
    /// samples. Throws naming the refused member.
    #[wasm_bindgen(constructor)]
    pub fn new(
        config: &DspConfig,
        #[wasm_bindgen(js_name = sampleCapacity)] sample_capacity: u32,
        #[wasm_bindgen(js_name = frameCapacity)] frame_capacity: u32,
        #[wasm_bindgen(js_name = f64Capacity)] f64_capacity: Option<u32>,
    ) -> Result<Dsp, JsError> {
        let f64_capacity = f64_capacity.unwrap_or(0);
        if sample_capacity > 16_777_216 || frame_capacity > 65536 || f64_capacity > 16_777_216 {
            return Err(JsError::new("buffer capacity"));
        }
        let mut handle = null_mut();
        // SAFETY: config and handle are valid for the call.
        let status = unsafe { oscillux_dsp_create_versioned(&config.versioned(), &mut handle) };
        if status != OSCILLUX_OK {
            let field = config.validate().unwrap_or_else(|| "config".into());
            return Err(JsError::new(&format!("DSP configuration: {field}")));
        }
        Ok(Self {
            handle,
            input: vec![0.0; sample_capacity as usize].into_boxed_slice(),
            input_f64: vec![0.0; f64_capacity as usize].into_boxed_slice(),
            output: vec![DspFrame::ZERO; frame_capacity as usize].into_boxed_slice(),
            ext: Box::default(),
            consumed: 0,
            produced: 0,
            ext_produced: false,
        })
    }
    /// Byte offset of the Float32 PCM input buffer in `wasmMemory().buffer`.
    #[wasm_bindgen(js_name = inputPtr)]
    pub fn input_ptr(&self) -> u32 {
        self.input.as_ptr() as u32
    }
    /// Byte offset of the Float64 PCM input buffer (`f64Capacity` samples) in
    /// `wasmMemory().buffer`.
    #[wasm_bindgen(js_name = inputF64Ptr)]
    pub fn input_f64_ptr(&self) -> u32 {
        self.input_f64.as_ptr() as u32
    }
    /// Byte offset of the frame output buffer in `wasmMemory().buffer`.
    #[wasm_bindgen(js_name = outputPtr)]
    pub fn output_ptr(&self) -> u32 {
        self.output.as_ptr() as u32
    }
    /// Size of one output frame, bytes.
    #[wasm_bindgen(js_name = frameBytes)]
    pub fn frame_bytes(&self) -> u32 {
        core::mem::size_of::<DspFrame>() as u32
    }
    /// Byte offset of the `OscilluxDspFrameExt` output buffer (`frameCapacity` elements) in
    /// `wasmMemory().buffer`; `pushExt` and `pushExtF64` write its first `produced()` elements.
    /// 0 until the first `pushExt` or `pushExtF64` allocates the buffer; fixed after that.
    #[wasm_bindgen(js_name = extPtr)]
    pub fn ext_ptr(&self) -> u32 {
        if self.ext.is_empty() {
            0
        } else {
            self.ext.as_ptr() as u32
        }
    }
    /// Size of one `OscilluxDspFrameExt`, bytes: its `struct_size`.
    #[wasm_bindgen(js_name = extBytes)]
    pub fn ext_bytes(&self) -> u32 {
        core::mem::size_of::<OscilluxDspFrameExt>() as u32
    }
    /// Sample frames (not scalars) consumed by the last `push` or `pushF64`.
    pub fn consumed(&self) -> u32 {
        self.consumed
    }
    /// Frames written to the output buffer by the last `push` or `pushF64`.
    pub fn produced(&self) -> u32 {
        self.produced
    }
    /// Starts a segment whose first sample plays at `timeMs`; returns a status.
    #[wasm_bindgen(js_name = beginSegment)]
    pub fn begin_segment(
        &mut self,
        #[wasm_bindgen(js_name = timeMs)] time_ms: f64,
        stalled: bool,
    ) -> i32 {
        // SAFETY: the handle is live until drop.
        unsafe { oscillux_dsp_begin_segment(self.handle, time_ms, u32::from(stalled)) }
    }
    /// Analyzes the first `sampleCount` interleaved scalars of the Float32 input buffer; returns
    /// a status. Read `produced()` frames from `outputPtr()`.
    pub fn push(
        &mut self,
        #[wasm_bindgen(js_name = sampleCount)] sample_count: u32,
        channels: u32,
    ) -> i32 {
        let input = self.input.as_ptr();
        let capacity = self.input.len();
        // SAFETY: the input is owned, `capacity` scalars long and disjoint from the output.
        self.push_with(
            sample_count,
            channels,
            capacity,
            |dsp, frames, out, cap, result| unsafe {
                oscillux_dsp_push_f32(dsp, input, frames, channels, out, cap, result)
            },
        )
    }
    /// Analyzes the first `sampleCount` interleaved scalars of the Float64 input buffer, exactly
    /// as `oscillux_dsp_push_f64`; returns a status. Read `produced()` frames from `outputPtr()`.
    #[wasm_bindgen(js_name = pushF64)]
    pub fn push_f64(
        &mut self,
        #[wasm_bindgen(js_name = sampleCount)] sample_count: u32,
        channels: u32,
    ) -> i32 {
        let input = self.input_f64.as_ptr();
        let capacity = self.input_f64.len();
        // SAFETY: the input is owned, `capacity` scalars long and disjoint from the output.
        self.push_with(
            sample_count,
            channels,
            capacity,
            |dsp, frames, out, cap, result| unsafe {
                oscillux_dsp_push_f64(dsp, input, frames, channels, out, cap, result)
            },
        )
    }
    /// As `push`, and also writes each frame's descriptors, beat and levels to the ext buffer
    /// at `extPtr()` (`oscillux_dsp_push_ext_f32`). Frames equal those `push` would write.
    #[wasm_bindgen(js_name = pushExt)]
    pub fn push_ext(
        &mut self,
        #[wasm_bindgen(js_name = sampleCount)] sample_count: u32,
        channels: u32,
    ) -> i32 {
        let input = self.input.as_ptr();
        let capacity = self.input.len();
        let ext = self.ext_buffer();
        // SAFETY: input, output and ext are owned, disjoint and as long as stated.
        let status = self.push_with(
            sample_count,
            channels,
            capacity,
            |dsp, frames, out, cap, result| unsafe {
                oscillux_dsp_push_ext_f32(dsp, input, frames, channels, out, ext, cap, result)
            },
        );
        self.ext_produced = status == OSCILLUX_OK;
        status
    }
    /// As `pushF64`, and also writes each frame's descriptors, beat and levels to the ext
    /// buffer (`oscillux_dsp_push_ext_f64`).
    #[wasm_bindgen(js_name = pushExtF64)]
    pub fn push_ext_f64(
        &mut self,
        #[wasm_bindgen(js_name = sampleCount)] sample_count: u32,
        channels: u32,
    ) -> i32 {
        let input = self.input_f64.as_ptr();
        let capacity = self.input_f64.len();
        let ext = self.ext_buffer();
        // SAFETY: as for pushExt.
        let status = self.push_with(
            sample_count,
            channels,
            capacity,
            |dsp, frames, out, cap, result| unsafe {
                oscillux_dsp_push_ext_f64(dsp, input, frames, channels, out, ext, cap, result)
            },
        );
        self.ext_produced = status == OSCILLUX_OK;
        status
    }
}

impl Dsp {
    /// The ext buffer, allocated once on the first `pushExt` or `pushExtF64` with one element
    /// per output frame, so that a `Dsp` that never asks for ext output does not hold it.
    fn ext_buffer(&mut self) -> *mut OscilluxDspFrameExt {
        if self.ext.len() != self.output.len() {
            self.ext = vec![OscilluxDspFrameExt::default(); self.output.len()].into_boxed_slice();
        }
        self.ext.as_mut_ptr()
    }

    fn push_with(
        &mut self,
        sample_count: u32,
        channels: u32,
        capacity: usize,
        push: impl FnOnce(
            *mut OscilluxDsp,
            usize,
            *mut DspFrame,
            usize,
            &mut OscilluxDspPushResult,
        ) -> i32,
    ) -> i32 {
        self.consumed = 0;
        self.produced = 0;
        self.ext_produced = false;
        let count = sample_count as usize;
        if channels == 0 || count > capacity || !count.is_multiple_of(channels as usize) {
            return INVALID;
        }
        let mut result = OscilluxDspPushResult::default();
        let status = push(
            self.handle,
            count / channels as usize,
            self.output.as_mut_ptr(),
            self.output.len(),
            &mut result,
        );
        if status == OSCILLUX_OK {
            self.consumed = result.consumed as u32;
            self.produced = result.produced as u32;
        }
        status
    }
}

impl Drop for Dsp {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_dsp_destroy(self.handle) }
    }
}

// ==== Limiter ================================================================================

/// Flash-limiter policy (`OscilluxLimiterPolicy`); the constructor writes the default, the
/// loosest policy accepted. Ceilings may only be tightened.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct LimiterPolicy(OscilluxLimiterPolicy);

#[wasm_bindgen]
impl LimiterPolicy {
    #[wasm_bindgen(constructor)]
    pub fn new() -> LimiterPolicy {
        let mut policy = OscilluxLimiterPolicy::default();
        // SAFETY: `policy` is a valid, exclusive destination.
        unsafe { oscillux_limiter_policy_default(&mut policy) };
        LimiterPolicy(policy)
    }
}

impl Default for LimiterPolicy {
    fn default() -> Self {
        Self::new()
    }
}

fields!(LimiterPolicy {
    /// General flashes per one-second window; at most 3.
    max_flash_hz, set_max_flash_hz, maxFlashHz: f64;
    /// Ceiling on any onset magnitude, normalized; at most 0.8.
    max_luminance_delta, set_max_luminance_delta, maxLuminanceDelta: f64;
    /// Screen fraction at or below which a change is no flash; at most 0.25.
    max_flash_area, set_max_flash_area, maxFlashArea: f64;
    /// Red flashes per one-second window; 0 ..= 3.
    max_red_flashes, set_max_red_flashes, maxRedFlashes: u32;
    /// Must equal 1.
    strobe_banned, set_strobe_banned, strobeBanned: u32;
});

/// Flash limiter (`OscilluxLimiter`) with two preallocated seven-double frames in the order
/// time, broadband, low, mid, high, red, area.
#[wasm_bindgen]
pub struct Limiter {
    handle: *mut OscilluxLimiter,
    input: Box<OscilluxLimiterFrame>,
    output: Box<OscilluxLimiterFrame>,
}

#[wasm_bindgen]
impl Limiter {
    #[wasm_bindgen(constructor)]
    pub fn new(policy: &LimiterPolicy) -> Result<Limiter, JsError> {
        let mut handle = null_mut();
        // SAFETY: policy and handle are valid for the call.
        let status = unsafe { oscillux_limiter_create(&policy.0, &mut handle) };
        if status != OSCILLUX_OK {
            return Err(refused("limiter policy", status));
        }
        Ok(Self {
            handle,
            input: Box::default(),
            output: Box::default(),
        })
    }
    #[wasm_bindgen(js_name = inputPtr)]
    pub fn input_ptr(&self) -> u32 {
        &*self.input as *const OscilluxLimiterFrame as u32
    }
    #[wasm_bindgen(js_name = outputPtr)]
    pub fn output_ptr(&self) -> u32 {
        &*self.output as *const OscilluxLimiterFrame as u32
    }
    /// Starts a new timeline; returns a status.
    pub fn reset(&mut self) -> i32 {
        // SAFETY: the handle is live until drop.
        unsafe { oscillux_limiter_reset(self.handle) }
    }
    /// Limits the input frame into the output frame; returns a status. A refused frame writes
    /// the fail-safe frame, which the host renders.
    pub fn process(&mut self) -> i32 {
        // SAFETY: the frames are owned and distinct.
        unsafe { oscillux_limiter_process(self.handle, &*self.input, &mut *self.output) }
    }
}

impl Drop for Limiter {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_limiter_destroy(self.handle) }
    }
}

/// `FlashConfig.redRule`: which red-flash rule the analyzer applies.
#[wasm_bindgen]
pub enum FlashRedRule {
    /// WCAG 2.0: (R - G - B) * 320 changes by more than 20; the default.
    Wcag20 = 0,
    /// ISO 9241-391: a transition to or from saturated red (R / (R + G + B) >= 0.8) with a
    /// CIE 1976 u'v' change above 0.2. Needs colors: use `measureRgb` / `admitRgb`.
    Iso9241_391 = 1,
}

/// Region flash analyzer configuration (`OscilluxFlashConfig`); the constructor writes the
/// defaults, the loosest configuration `new FlashAnalyzer` accepts.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct FlashConfig(OscilluxFlashConfig);

#[wasm_bindgen]
impl FlashConfig {
    #[wasm_bindgen(constructor)]
    pub fn new() -> FlashConfig {
        // `struct_size` already selects the released layout, as the C call requires.
        let mut config = OscilluxFlashConfig::default();
        // SAFETY: `config` is a valid, exclusive destination.
        unsafe { oscillux_flash_config_default(&mut config) };
        FlashConfig(config)
    }
}

impl Default for FlashConfig {
    fn default() -> Self {
        Self::new()
    }
}

fields!(FlashConfig {
    /// Regions across the viewport; 1 ..= 16.
    columns, set_columns, columns: u32;
    /// Regions down the viewport; 1 ..= 16.
    rows, set_rows, rows: u32;
    /// Red flashes per one-second window; 0 ..= 3.
    max_red_flashes, set_max_red_flashes, maxRedFlashes: u32;
    /// Field-window width as a viewport fraction; > 0, at most 1.
    field_width, set_field_width, fieldWidth: f64;
    /// Field-window height as a viewport fraction; > 0, at most 1.
    field_height, set_field_height, fieldHeight: f64;
    /// Field-window fraction at or below which a change is no flash; > 0, at most 0.25.
    max_field_area, set_max_field_area, maxFieldArea: f64;
    /// General flashes per one-second window; > 0, at most 3.
    max_flash_hz, set_max_flash_hz, maxFlashHz: f64;
    /// A `FlashRedRule`; any other value is refused by `new FlashAnalyzer`.
    red_rule, set_red_rule, redRule: u32;
});

/// Region flash analyzer (`OscilluxFlashAnalyzer`) with preallocated row-major region and color
/// arrays (`columns * rows` pairs of doubles: luminance, red; and triples: linear r, g, b) and
/// one report. `measure` / `admit` read the regions, `measureRgb` / `admitRgb` the colors; each
/// writes the report and none allocates.
#[wasm_bindgen]
pub struct FlashAnalyzer {
    handle: *mut OscilluxFlashAnalyzer,
    regions: Box<[OscilluxFlashRegion]>,
    colors: Box<[OscilluxFlashColor]>,
    report: Box<OscilluxFlashReport>,
}

#[wasm_bindgen]
impl FlashAnalyzer {
    /// Throws when `config` is refused.
    #[wasm_bindgen(constructor)]
    pub fn new(config: &FlashConfig) -> Result<FlashAnalyzer, JsError> {
        let mut handle = null_mut();
        // SAFETY: config and handle are valid for the call.
        let status = unsafe { oscillux_flash_analyzer_create(&config.0, &mut handle) };
        if status != OSCILLUX_OK {
            return Err(refused("flash config", status));
        }
        let count = (config.0.columns * config.0.rows) as usize;
        Ok(Self {
            handle,
            regions: vec![OscilluxFlashRegion::default(); count].into_boxed_slice(),
            colors: vec![OscilluxFlashColor::default(); count].into_boxed_slice(),
            report: Box::default(),
        })
    }
    /// Byte offset of the region array: Float64 pairs (luminance, red), row-major.
    #[wasm_bindgen(js_name = regionsPtr)]
    pub fn regions_ptr(&self) -> u32 {
        self.regions.as_ptr() as u32
    }
    /// Byte offset of the color array: Float64 triples (r, g, b), linear light, row-major.
    #[wasm_bindgen(js_name = colorsPtr)]
    pub fn colors_ptr(&self) -> u32 {
        self.colors.as_ptr() as u32
    }
    /// Regions in the array, `columns * rows`.
    #[wasm_bindgen(js_name = regionCount)]
    pub fn region_count(&self) -> u32 {
        self.regions.len() as u32
    }
    /// Byte offset of the `OscilluxFlashReport` the last measure or admit wrote.
    #[wasm_bindgen(js_name = reportPtr)]
    pub fn report_ptr(&self) -> u32 {
        &*self.report as *const OscilluxFlashReport as u32
    }
    /// Writes region `index` from a mean linear-light sRGB color, each channel in [0, 1];
    /// returns a status and leaves the region unchanged on refusal.
    #[wasm_bindgen(js_name = setRegionFromLinearRgb)]
    pub fn set_region_from_linear_rgb(&mut self, index: u32, r: f64, g: f64, b: f64) -> i32 {
        match self.regions.get_mut(index as usize) {
            // SAFETY: `region` is a valid, exclusive destination.
            Some(region) => unsafe { oscillux_flash_region_from_linear_rgb(r, g, b, region) },
            None => INVALID,
        }
    }
    /// Starts a new timeline (a seek or new stream); returns a status.
    pub fn reset(&mut self) -> i32 {
        // SAFETY: the handle is live until drop.
        unsafe { oscillux_flash_analyzer_reset(self.handle) }
    }
    /// Measures and commits the regions as the frame at `timeMs`; returns a status. On an
    /// error the report is zero except `timeMs`.
    pub fn measure(&mut self, #[wasm_bindgen(js_name = timeMs)] time_ms: f64) -> i32 {
        // SAFETY: the regions and report are owned; the count is the configured grid.
        unsafe {
            oscillux_flash_analyzer_measure(
                self.handle,
                time_ms,
                self.regions.as_ptr(),
                self.regions.len(),
                &mut *self.report,
            )
        }
    }
    /// As `measure`, but commits the frame only if it keeps the window within the config.
    /// When `admitted` is false the host keeps presenting its last admitted image.
    pub fn admit(&mut self, #[wasm_bindgen(js_name = timeMs)] time_ms: f64) -> i32 {
        // SAFETY: see `measure`.
        unsafe {
            oscillux_flash_analyzer_admit(
                self.handle,
                time_ms,
                self.regions.as_ptr(),
                self.regions.len(),
                &mut *self.report,
            )
        }
    }
    /// As `measure`, from the color array; the only path `FlashRedRule.Iso9241_391` accepts.
    #[wasm_bindgen(js_name = measureRgb)]
    pub fn measure_rgb(&mut self, #[wasm_bindgen(js_name = timeMs)] time_ms: f64) -> i32 {
        // SAFETY: the colors and report are owned; the count is the configured grid.
        unsafe {
            oscillux_flash_analyzer_measure_rgb(
                self.handle,
                time_ms,
                self.colors.as_ptr(),
                self.colors.len(),
                &mut *self.report,
            )
        }
    }
    /// As `admit`, from the color array.
    #[wasm_bindgen(js_name = admitRgb)]
    pub fn admit_rgb(&mut self, #[wasm_bindgen(js_name = timeMs)] time_ms: f64) -> i32 {
        // SAFETY: see `measureRgb`.
        unsafe {
            oscillux_flash_analyzer_admit_rgb(
                self.handle,
                time_ms,
                self.colors.as_ptr(),
                self.colors.len(),
                &mut *self.report,
            )
        }
    }
    /// The last report's frame time, ms.
    #[wasm_bindgen(getter = timeMs)]
    pub fn time_ms(&self) -> f64 {
        self.report.time_ms
    }
    /// General flashes (transitions / 2) in the last 1000 ms.
    #[wasm_bindgen(getter = flashesInWindow)]
    pub fn flashes_in_window(&self) -> f64 {
        self.report.flashes_in_window
    }
    /// Red flashes (transitions / 2) in the last 1000 ms.
    #[wasm_bindgen(getter = redFlashesInWindow)]
    pub fn red_flashes_in_window(&self) -> f64 {
        self.report.red_flashes_in_window
    }
    /// The frame was committed; false means show the last admitted one.
    #[wasm_bindgen(getter)]
    pub fn admitted(&self) -> bool {
        self.report.admitted != 0
    }
    /// The frame completes a general transition.
    #[wasm_bindgen(getter = generalTransition)]
    pub fn general_transition(&self) -> bool {
        self.report.general_transition != 0
    }
    /// The frame completes a red transition.
    #[wasm_bindgen(getter = redTransition)]
    pub fn red_transition(&self) -> bool {
        self.report.red_transition != 0
    }
    /// Regions completing a general change this frame.
    #[wasm_bindgen(getter = generalRegions)]
    pub fn general_regions(&self) -> u32 {
        self.report.general_regions
    }
    /// Regions completing a red change this frame.
    #[wasm_bindgen(getter = redRegions)]
    pub fn red_regions(&self) -> u32 {
        self.report.red_regions
    }
    /// The window holds more flashes than the config allows.
    #[wasm_bindgen(getter)]
    pub fn exceeds(&self) -> bool {
        self.report.exceeds != 0
    }
}

impl Drop for FlashAnalyzer {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_flash_analyzer_destroy(self.handle) }
    }
}

// ==== Curves =================================================================================

/// `CurveConfig.kind`.
#[wasm_bindgen]
pub enum CurveKind {
    Constant = 0,
    Easing = 1,
    Envelope = 2,
    Lfo = 3,
}

/// `CurveConfig.unit`: the clock for duration, attack, release, releaseAt and period.
#[wasm_bindgen]
pub enum CurveUnit {
    Unspecified = 0,
    Seconds = 1,
    Beats = 2,
}

/// `CurveConfig.easing` for the Easing kind.
#[wasm_bindgen]
pub enum CurveEasing {
    Linear = 0,
    In = 1,
    Out = 2,
    InOut = 3,
}

/// `CurveConfig.shape` for the Lfo kind.
#[wasm_bindgen]
pub enum CurveShape {
    Sine = 0,
    Triangle = 1,
    Square = 2,
}

/// `CurveConfig.flags` bits; combine with `|`.
#[wasm_bindgen]
pub enum CurveFlag {
    Value = 1,
    From = 2,
    To = 4,
    Min = 8,
    Max = 16,
    Wrap = 32,
}

/// A typed curve (`OscilluxCurveConfig`); the constructor writes a constant 0.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct CurveConfig(OscilluxCurveConfig);

#[wasm_bindgen]
impl CurveConfig {
    #[wasm_bindgen(constructor)]
    pub fn new() -> CurveConfig {
        let mut config = OscilluxCurveConfig::default();
        // SAFETY: `config` is a valid, exclusive destination.
        unsafe { oscillux_curve_config_default(&mut config) };
        CurveConfig(config)
    }
}

impl Default for CurveConfig {
    fn default() -> Self {
        Self::new()
    }
}

fields!(CurveConfig {
    /// A `CurveKind`.
    kind, set_kind, kind: u32;
    /// A `CurveUnit`.
    unit, set_unit, unit: u32;
    /// A `CurveEasing`.
    easing, set_easing, easing: u32;
    /// A `CurveShape`.
    shape, set_shape, shape: u32;
    /// `CurveFlag` bits marking which optional values are present.
    flags, set_flags, flags: u32;
    /// Constant output; envelope peak.
    value, set_value, value: f64;
    /// Easing start value.
    from, set_from, from: f64;
    /// Easing end value.
    to, set_to, to: f64;
    /// Easing length, curve units.
    duration, set_duration, duration: f64;
    /// Envelope rise, curve units.
    attack, set_attack, attack: f64;
    /// Envelope fall, curve units.
    release, set_release, release: f64;
    /// Envelope release start, curve units; 0 = never.
    release_at, set_release_at, releaseAt: f64;
    /// LFO cycle length, curve units.
    period, set_period, period: f64;
    /// LFO phase offset, cycles.
    phase, set_phase, phase: f64;
    /// Lower bound (Min flag); LFO low value.
    min, set_min, min: f64;
    /// Upper bound (Max flag); LFO high value.
    max, set_max, max: f64;
    /// Exponential smoothing time constant, s; 0 disables.
    smoothing_seconds, set_smoothing_seconds, smoothingSeconds: f64;
});

/// The clock and history for one evaluation (`OscilluxCurveInput`); starts at zero.
#[wasm_bindgen]
#[derive(Clone, Copy, Default)]
pub struct CurveInput(OscilluxCurveInput);

#[wasm_bindgen]
impl CurveInput {
    #[wasm_bindgen(constructor)]
    pub fn new() -> CurveInput {
        CurveInput::default()
    }
    /// Whether `previousValue` is read.
    #[wasm_bindgen(getter = hasPrevious)]
    pub fn has_previous(&self) -> bool {
        self.0.has_previous != 0
    }
    #[wasm_bindgen(setter = hasPrevious)]
    pub fn set_has_previous(&mut self, value: bool) {
        self.0.has_previous = u32::from(value);
    }
}

fields!(CurveInput {
    /// Time since the curve started, s.
    elapsed_seconds, set_elapsed_seconds, elapsedSeconds: f64;
    /// Time since the curve started, beats.
    elapsed_beats, set_elapsed_beats, elapsedBeats: f64;
    /// Added to the LFO phase when the unit is beats, cycles.
    beat_phase, set_beat_phase, beatPhase: f64;
    /// Time since the previous evaluation, s; smoothing needs > 0.
    delta_seconds, set_delta_seconds, deltaSeconds: f64;
    /// The previous output, read when hasPrevious is true.
    previous_value, set_previous_value, previousValue: f64;
});

/// A validated curve (`OscilluxCurve`).
#[wasm_bindgen]
pub struct Curve {
    handle: *mut OscilluxCurve,
}

#[wasm_bindgen]
impl Curve {
    #[wasm_bindgen(constructor)]
    pub fn new(config: &CurveConfig) -> Result<Curve, JsError> {
        let mut handle = null_mut();
        // SAFETY: config and handle are valid for the call.
        let status = unsafe { oscillux_curve_create(&config.0, &mut handle) };
        if status != OSCILLUX_OK {
            return Err(refused("curve configuration", status));
        }
        Ok(Self { handle })
    }
    /// The value at `input`, or undefined when refused.
    pub fn evaluate(&self, input: &CurveInput) -> Option<f64> {
        let mut value = 0.0;
        // SAFETY: the handle is live; input and value are valid and distinct.
        let status = unsafe { oscillux_curve_evaluate(self.handle, &input.0, &mut value) };
        (status == OSCILLUX_OK).then_some(value)
    }
}

impl Drop for Curve {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_curve_destroy(self.handle) }
    }
}

// ==== Governor ===============================================================================

/// Frame-time governor parameters (`OscilluxGovernorConfig`); the constructor writes the
/// reference values.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct GovernorConfig(OscilluxGovernorConfig);

#[wasm_bindgen]
impl GovernorConfig {
    #[wasm_bindgen(constructor)]
    pub fn new() -> GovernorConfig {
        let mut config = OscilluxGovernorConfig::default();
        // SAFETY: `config` is a valid, exclusive destination.
        unsafe { oscillux_governor_config_default(&mut config) };
        GovernorConfig(config)
    }
}

impl Default for GovernorConfig {
    fn default() -> Self {
        Self::new()
    }
}

fields!(GovernorConfig {
    /// Target frame duration, ms.
    target_ms, set_target_ms, targetMs: f64;
    /// Weight of each sample in the moving average; (0, 1].
    ema_alpha, set_ema_alpha, emaAlpha: f64;
    /// Durations at or above this are pauses and ignored, ms.
    pause_gap_ms, set_pause_gap_ms, pauseGapMs: f64;
    /// Samples are capped at targetMs times this.
    sample_cap_factor, set_sample_cap_factor, sampleCapFactor: f64;
    /// Per-sample growth factor of refreshMs toward the target; >= 1.
    refresh_drift, set_refresh_drift, refreshDrift: f64;
    /// Lower bound of refreshMs, ms.
    refresh_floor_ms, set_refresh_floor_ms, refreshFloorMs: f64;
    /// An average above targetMs times this is slow.
    demote_factor, set_demote_factor, demoteFactor: f64;
    /// An average below refreshMs times this is fast ...
    promote_refresh_factor, set_promote_refresh_factor, promoteRefreshFactor: f64;
    /// ... or below targetMs times this.
    promote_target_factor, set_promote_target_factor, promoteTargetFactor: f64;
    /// Consecutive slow samples before a step down.
    demote_frames, set_demote_frames, demoteFrames: u32;
    /// Consecutive fast samples before a step up.
    promote_frames, set_promote_frames, promoteFrames: u32;
    /// Samples after a step that cannot cause another step.
    settle_frames, set_settle_frames, settleFrames: u32;
    /// Highest quality level.
    max_level, set_max_level, maxLevel: u32;
    /// Level after construction; <= maxLevel.
    initial_level, set_initial_level, initialLevel: u32;
});

/// Frame-time governor (`OscilluxGovernor`). `level`, `emaMs` and `refreshMs` read the stats
/// of the last `record` or `reset`.
#[wasm_bindgen]
pub struct Governor {
    handle: *mut OscilluxGovernor,
    stats: OscilluxGovernorStats,
}

#[wasm_bindgen]
impl Governor {
    #[wasm_bindgen(constructor)]
    pub fn new(config: &GovernorConfig) -> Result<Governor, JsError> {
        let mut handle = null_mut();
        // SAFETY: config and handle are valid for the call.
        let status = unsafe { oscillux_governor_create(&config.0, &mut handle) };
        if status != OSCILLUX_OK {
            return Err(refused("governor configuration", status));
        }
        let mut governor = Self {
            handle,
            stats: OscilluxGovernorStats {
                ema_ms: 0.0,
                refresh_ms: 0.0,
                level: 0,
                has_ema: 0,
            },
        };
        governor.refresh_stats();
        Ok(governor)
    }
    /// A non-finite duration is ignored with OK and reports the unchanged stats.
    fn refresh_stats(&mut self) {
        // SAFETY: the handle is live; stats is a valid destination.
        unsafe { oscillux_governor_record(self.handle, f64::NAN, &mut self.stats) };
    }
    /// Records one frame duration, ms; returns a status. Pauses and invalid durations are
    /// ignored.
    pub fn record(&mut self, #[wasm_bindgen(js_name = frameMs)] frame_ms: f64) -> i32 {
        // SAFETY: the handle is live; stats is a valid destination.
        unsafe { oscillux_governor_record(self.handle, frame_ms, &mut self.stats) }
    }
    /// Clears the average and counters and sets the level, clamped to maxLevel.
    pub fn reset(&mut self, level: u32) -> i32 {
        // SAFETY: the handle is live until drop.
        let status = unsafe { oscillux_governor_reset(self.handle, level) };
        self.refresh_stats();
        status
    }
    /// Current quality level, 0 = lowest.
    #[wasm_bindgen(getter)]
    pub fn level(&self) -> u32 {
        self.stats.level
    }
    /// Moving average of frame duration, ms; undefined before the first accepted sample.
    #[wasm_bindgen(getter = emaMs)]
    pub fn ema_ms(&self) -> Option<f64> {
        (self.stats.has_ema != 0).then_some(self.stats.ema_ms)
    }
    /// Estimated display refresh interval, ms.
    #[wasm_bindgen(getter = refreshMs)]
    pub fn refresh_ms(&self) -> f64 {
        self.stats.refresh_ms
    }
}

impl Drop for Governor {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_governor_destroy(self.handle) }
    }
}

// ==== Mapping ================================================================================

/// `Mapper.setLevelSource` values (`OSCILLUX_MAPPING_LEVELS_*`).
#[wasm_bindgen]
pub enum LevelSource {
    /// The band energies; the default.
    Absolute = 0,
    /// The ext frame's relative band levels.
    Relative = 1,
}

/// Indices into the mapped values (`OSCILLUX_MAPPED_*`); every value is normalized.
#[wasm_bindgen]
pub enum MappedValue {
    Amplitude = 0,
    Level = 1,
    Bass = 2,
    Mid = 3,
    Treble = 4,
    Onset = 5,
    BassImpact = 6,
    /// Spectral flux with descriptors (`processExt`); otherwise the broadband onset, a
    /// deprecated proxy.
    Flux = 7,
    /// Log-frequency centroid with descriptors (`processExt`); otherwise the band-index
    /// fraction, a deprecated proxy.
    Centroid = 8,
}

/// DSP-frame-to-value mapping (`OscilluxMappingConfig`); the constructor writes the values
/// matching the default `DspConfig`, `fromDsp` those matching any valid one.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct MappingConfig(OscilluxMappingConfig);

#[wasm_bindgen]
impl MappingConfig {
    #[wasm_bindgen(constructor)]
    pub fn new() -> MappingConfig {
        let mut config = OscilluxMappingConfig::default();
        // SAFETY: `config` is a valid, exclusive destination.
        unsafe { oscillux_mapping_config_default(&mut config) };
        MappingConfig(config)
    }
    /// The default mapping with hop and loudness reference taken from `dsp`; throws when `dsp`
    /// is invalid.
    #[wasm_bindgen(js_name = fromDsp)]
    pub fn from_dsp(dsp: &DspConfig) -> Result<MappingConfig, JsError> {
        let mut config = OscilluxMappingConfig::default();
        // SAFETY: both pointers are valid and distinct.
        let status = unsafe { oscillux_mapping_config_from_dsp(&dsp.0, &mut config) };
        if status != OSCILLUX_OK {
            return Err(refused("DSP configuration", status));
        }
        Ok(MappingConfig(config))
    }
    /// Band group `group` (0 bass, 1 mid, 2 treble) as `[start, end]`, inclusive.
    pub fn group(
        &self,
        #[wasm_bindgen(js_name = groupIndex)] group_index: u32,
    ) -> Result<Vec<u32>, JsError> {
        group(&self.0.groups, group_index)
    }
    #[wasm_bindgen(js_name = setGroup)]
    pub fn set_group(&mut self, group: u32, start: u32, end: u32) -> Result<(), JsError> {
        set_group(&mut self.0.groups, group, start, end)
    }
}

impl Default for MappingConfig {
    fn default() -> Self {
        Self::new()
    }
}

fields!(MappingConfig {
    /// Added back to a frame's loudnessDb, dB.
    loudness_reference, set_loudness_reference, loudnessReference: f64;
    /// Loudness mapped to amplitude 0, dB; negative.
    db_floor, set_db_floor, dbFloor: f64;
    /// Analyzer hop duration, s.
    hop_seconds, set_hop_seconds, hopSeconds: f64;
    /// Level decay time constant, s.
    release_seconds, set_release_seconds, releaseSeconds: f64;
    /// Summed band energy at or below which the centroid is 0.
    centroid_floor, set_centroid_floor, centroidFloor: f64;
});

/// Frame mapper (`OscilluxMapper`) with a preallocated `OscilluxMapped` output (nine float64
/// values, then 64 float32 spectrum bins at byte 72) and a one-frame input buffer for frames
/// that do not come from a `Dsp`.
#[wasm_bindgen]
pub struct Mapper {
    handle: *mut OscilluxMapper,
    frame: Box<DspFrame>,
    ext: Box<OscilluxDspFrameExt>,
    output: Box<OscilluxMapped>,
}

#[wasm_bindgen]
impl Mapper {
    #[wasm_bindgen(constructor)]
    pub fn new(config: &MappingConfig) -> Result<Mapper, JsError> {
        let mut handle = null_mut();
        // SAFETY: config and handle are valid for the call.
        let status = unsafe { oscillux_mapping_create(&config.0, &mut handle) };
        if status != OSCILLUX_OK {
            return Err(refused("mapping configuration", status));
        }
        Ok(Self {
            handle,
            frame: Box::new(DspFrame::ZERO),
            ext: Box::new(OscilluxDspFrameExt::default()),
            output: Box::new(OscilluxMapped::ZERO),
        })
    }
    /// Byte offset of the one-frame `OscilluxDspFrame` input used by `processFrame`.
    #[wasm_bindgen(js_name = frameInputPtr)]
    pub fn frame_input_ptr(&self) -> u32 {
        &*self.frame as *const DspFrame as u32
    }
    /// Byte offset of the one `OscilluxDspFrameExt` input used by `processFrameExt`; its
    /// `struct_size` is preset, so write only the descriptors and, for the relative level
    /// source, the levels (layout as on `Dsp`).
    #[wasm_bindgen(js_name = extInputPtr)]
    pub fn ext_input_ptr(&self) -> u32 {
        &*self.ext as *const OscilluxDspFrameExt as u32
    }
    /// Byte offset of the `OscilluxMapped` output.
    #[wasm_bindgen(js_name = outputPtr)]
    pub fn output_ptr(&self) -> u32 {
        &*self.output as *const OscilluxMapped as u32
    }
    /// Mapped value `index` (a `MappedValue`) from the last successful call, or undefined for
    /// an index out of range.
    pub fn value(&self, index: u32) -> Option<f64> {
        self.output.values.get(index as usize).copied()
    }
    /// Spectrum bin `index` (0 ..= 63) from the last successful call, or undefined.
    pub fn spectrum(&self, index: u32) -> Option<f32> {
        self.output.spectrum.get(index as usize).copied()
    }
    /// Selects what BASS, MID, TREBLE and the spectrum read (a `LevelSource`): `Absolute`, the
    /// default, the band energies; `Relative` the ext frame's relative band levels. The
    /// relative source refuses `process` and `processFrame`, and `processExt` or
    /// `processFrameExt` whose levels band count is not the frame's (0 when the analyzer
    /// refused the AGC configuration) or whose relative bands are not finite. Returns a
    /// status; an unknown source is refused and leaves the source unchanged. `reset` keeps it.
    #[wasm_bindgen(js_name = setLevelSource)]
    pub fn set_level_source(&mut self, source: u32) -> i32 {
        // SAFETY: the handle is live until drop.
        unsafe { oscillux_mapping_set_level_source(self.handle, source) }
    }
    /// Forgets the previous level; returns a status.
    pub fn reset(&mut self) -> i32 {
        // SAFETY: the handle is live until drop.
        unsafe { oscillux_mapping_reset(self.handle) }
    }
    /// Maps frame `index` of `dsp`'s last `push` (index < produced()); returns a status.
    /// `unavailable` writes all zeros.
    pub fn process(&mut self, dsp: &Dsp, index: u32, unavailable: bool) -> i32 {
        if index >= dsp.produced {
            return INVALID;
        }
        let frame = &dsp.output[index as usize];
        // SAFETY: the handle is live; frame and output are distinct owned storage.
        unsafe {
            oscillux_mapping_process(
                self.handle,
                frame,
                u32::from(unavailable),
                &mut *self.output,
            )
        }
    }
    /// Maps the frame written at `frameInputPtr()`; returns a status.
    #[wasm_bindgen(js_name = processFrame)]
    pub fn process_frame(&mut self, unavailable: bool) -> i32 {
        // SAFETY: as for process.
        unsafe {
            oscillux_mapping_process(
                self.handle,
                &*self.frame,
                u32::from(unavailable),
                &mut *self.output,
            )
        }
    }
    /// As `process`, with frame `index`'s descriptors from `dsp`'s last `pushExt` or
    /// `pushExtF64` feeding FLUX and CENTROID (`oscillux_mapping_process_ext`), and its levels
    /// feeding the relative level source; invalid after any other push.
    #[wasm_bindgen(js_name = processExt)]
    pub fn process_ext(&mut self, dsp: &Dsp, index: u32, unavailable: bool) -> i32 {
        if index >= dsp.produced || !dsp.ext_produced {
            return INVALID;
        }
        let frame = &dsp.output[index as usize];
        let ext = &dsp.ext[index as usize];
        // SAFETY: the handle is live; frame, ext and output are distinct owned storage.
        unsafe {
            oscillux_mapping_process_ext(
                self.handle,
                frame,
                ext,
                u32::from(unavailable),
                &mut *self.output,
            )
        }
    }
    /// Maps the frame at `frameInputPtr()` with the descriptors and levels at `extInputPtr()`;
    /// returns a status.
    #[wasm_bindgen(js_name = processFrameExt)]
    pub fn process_frame_ext(&mut self, unavailable: bool) -> i32 {
        // SAFETY: as for processExt.
        unsafe {
            oscillux_mapping_process_ext(
                self.handle,
                &*self.frame,
                &*self.ext,
                u32::from(unavailable),
                &mut *self.output,
            )
        }
    }
}

impl Drop for Mapper {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_mapping_destroy(self.handle) }
    }
}

// ==== Packing ================================================================================

/// `UniformField.source`.
#[wasm_bindgen]
pub enum FieldSource {
    /// Mapped values, indexed by `MappedValue`.
    Mapped = 0,
    /// The 64 mapped spectrum bins.
    Spectrum = 1,
    /// The packer's host values.
    Host = 2,
}

#[wasm_bindgen(typescript_custom_section)]
const UNIFORM_FIELD: &'static str = r#"
/** Copies `components` consecutive source values, as float32, into the block (OscilluxUniformField). */
export interface UniformField {
  /** A FieldSource. */
  source: FieldSource;
  /** Index of the first source element (elements, not bytes). */
  sourceOffset: number;
  /** 1 ..= 64. */
  components: number;
  /** Byte offset of the first component; multiple of 4. */
  offset: number;
  /** Bytes between components; multiple of 4, >= 4. */
  stride: number;
}
"#;

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(typescript_type = "readonly UniformField[]")]
    pub type UniformFieldList;
    #[wasm_bindgen(method, getter)]
    fn length(this: &UniformFieldList) -> u32;
    #[wasm_bindgen(method, indexing_getter)]
    fn get(this: &UniformFieldList, index: u32) -> UniformFieldSpec;

    #[wasm_bindgen(typescript_type = "UniformField")]
    pub type UniformFieldSpec;
    #[wasm_bindgen(method, getter)]
    fn source(this: &UniformFieldSpec) -> u32;
    #[wasm_bindgen(method, getter = sourceOffset)]
    fn source_offset(this: &UniformFieldSpec) -> u32;
    #[wasm_bindgen(method, getter)]
    fn components(this: &UniformFieldSpec) -> u32;
    #[wasm_bindgen(method, getter)]
    fn offset(this: &UniformFieldSpec) -> u32;
    #[wasm_bindgen(method, getter)]
    fn stride(this: &UniformFieldSpec) -> u32;
}

/// Explicit uniform block packer (`OscilluxPacker`) with preallocated float64 host values and
/// a `blockSize`-byte little-endian float32 output block.
#[wasm_bindgen]
pub struct Packer {
    handle: *mut OscilluxPacker,
    host: Box<[f64]>,
    output: Box<[u8]>,
}

#[wasm_bindgen]
impl Packer {
    /// Validates the layout (at most 256 fields) for a `blockSize`-byte block and allocates
    /// room for `hostCapacity` host values.
    #[wasm_bindgen(constructor)]
    pub fn new(
        fields: &UniformFieldList,
        #[wasm_bindgen(js_name = blockSize)] block_size: u32,
        #[wasm_bindgen(js_name = hostCapacity)] host_capacity: u32,
    ) -> Result<Packer, JsError> {
        let count = fields.length();
        if count > 256 || block_size > 16_777_216 || host_capacity > 65536 {
            return Err(JsError::new("packer capacity"));
        }
        let layout: Vec<OscilluxUniformField> = (0..count)
            .map(|i| {
                let f = fields.get(i);
                OscilluxUniformField {
                    source: f.source(),
                    source_offset: f.source_offset(),
                    components: f.components(),
                    offset: f.offset(),
                    stride: f.stride(),
                }
            })
            .collect();
        let mut handle = null_mut();
        // SAFETY: layout holds `count` fields; handle is valid for the call.
        let status = unsafe {
            oscillux_packer_create(
                layout.as_ptr(),
                layout.len(),
                block_size as usize,
                &mut handle,
            )
        };
        if status != OSCILLUX_OK {
            return Err(refused("uniform layout", status));
        }
        Ok(Self {
            handle,
            host: vec![0.0; host_capacity as usize].into_boxed_slice(),
            output: vec![0; block_size as usize].into_boxed_slice(),
        })
    }
    /// Byte offset of the float64 host values.
    #[wasm_bindgen(js_name = hostPtr)]
    pub fn host_ptr(&self) -> u32 {
        self.host.as_ptr() as u32
    }
    /// Byte offset of the packed block.
    #[wasm_bindgen(js_name = outputPtr)]
    pub fn output_ptr(&self) -> u32 {
        self.output.as_ptr() as u32
    }
    /// Size of the packed block, bytes.
    #[wasm_bindgen(js_name = blockSize)]
    pub fn block_size(&self) -> u32 {
        self.output.len() as u32
    }
    /// Packs `mapper`'s last output and the first `hostCount` host values; returns a status.
    /// A refusal leaves the block unchanged.
    pub fn pack(
        &mut self,
        mapper: &Mapper,
        #[wasm_bindgen(js_name = hostCount)] host_count: u32,
    ) -> i32 {
        if host_count as usize > self.host.len() {
            return INVALID;
        }
        // SAFETY: the handle is live (created in `new`, destroyed only in `drop`). `output` is
        // exclusively borrowed through `&mut self`, so `as_mut_ptr()` is valid for the
        // `output.len()` bytes passed as the capacity. `host` is a separate boxed slice and
        // `host_count <= host.len()` was checked above; `mapper.output` is a third allocation, so
        // no argument aliases the writable block.
        unsafe {
            oscillux_packer_pack(
                self.handle,
                &*mapper.output,
                self.host.as_ptr(),
                host_count as usize,
                self.output.as_mut_ptr(),
                self.output.len(),
            )
        }
    }
}

impl Drop for Packer {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_packer_destroy(self.handle) }
    }
}

// ==== Transition =============================================================================

use oscillux::transition::{
    oscillux_transition_config_default, oscillux_transition_create, oscillux_transition_destroy,
    oscillux_transition_request, oscillux_transition_reset, oscillux_transition_status,
    oscillux_transition_update, OscilluxTransition, OscilluxTransitionClock,
    OscilluxTransitionConfig, OscilluxTransitionStatus,
};

/// Transition scheduler parameters (`OscilluxTransitionConfig`); the constructor writes the
/// reference values.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct TransitionConfig(OscilluxTransitionConfig);

#[wasm_bindgen]
impl TransitionConfig {
    #[wasm_bindgen(constructor)]
    pub fn new() -> TransitionConfig {
        let mut config = OscilluxTransitionConfig::default();
        // SAFETY: `config` is a valid, exclusive destination with its struct_size set.
        unsafe { oscillux_transition_config_default(&mut config) };
        TransitionConfig(config)
    }
}

impl Default for TransitionConfig {
    fn default() -> Self {
        Self::new()
    }
}

fields!(TransitionConfig {
    /// Progress easing: 0 linear, 1 smoothstep.
    easing, set_easing, easing: u32;
    /// Beats per bar, 1 to 16.
    beats_per_bar, set_beats_per_bar, beatsPerBar: u32;
    /// Bars between automatic switches; 0 disables auto-advance.
    auto_advance_bars, set_auto_advance_bars, autoAdvanceBars: u32;
    /// Blend length in beats on a confident clock, clamped to 0.8 to 2.5 s.
    duration_beats, set_duration_beats, durationBeats: f64;
    /// Blend length without a confident beat, s; 0.8 to 2.5.
    fallback_seconds, set_fallback_seconds, fallbackSeconds: f64;
    /// Time the incoming visual runs offscreen before it may start, s.
    pre_roll_seconds, set_pre_roll_seconds, preRollSeconds: f64;
    /// Lowest clock confidence that counts as a beat.
    min_confidence, set_min_confidence, minConfidence: f64;
});

/// Transition scheduler (`OscilluxTransition`). `request` and `update` take the clock as
/// numbers; the getters read the status of the last successful call.
#[wasm_bindgen]
pub struct Transition {
    handle: *mut OscilluxTransition,
    status: OscilluxTransitionStatus,
}

fn transition_clock(
    time_seconds: f64,
    beat_phase: f64,
    bar_phase: f64,
    tempo_bpm: f64,
    confidence: f64,
) -> OscilluxTransitionClock {
    OscilluxTransitionClock {
        time_seconds,
        beat_phase,
        bar_phase,
        tempo_bpm,
        confidence,
    }
}

#[wasm_bindgen]
impl Transition {
    #[wasm_bindgen(constructor)]
    pub fn new(config: &TransitionConfig) -> Result<Transition, JsError> {
        let mut handle = null_mut();
        // SAFETY: config and handle are valid for the call.
        let status = unsafe { oscillux_transition_create(&config.0, &mut handle) };
        if status != OSCILLUX_OK {
            return Err(refused("transition configuration", status));
        }
        Ok(Self {
            handle,
            status: OscilluxTransitionStatus::default(),
        })
    }
    /// Schedules a switch requested at `timeSeconds`; quantise 0 none, 1 beat, 2 bar, waiting
    /// at most `maxWaitSeconds` past the pre-roll. Returns a status; a refusal changes nothing.
    #[allow(clippy::too_many_arguments)]
    pub fn request(
        &mut self,
        #[wasm_bindgen(js_name = timeSeconds)] time_seconds: f64,
        #[wasm_bindgen(js_name = beatPhase)] beat_phase: f64,
        #[wasm_bindgen(js_name = barPhase)] bar_phase: f64,
        #[wasm_bindgen(js_name = tempoBpm)] tempo_bpm: f64,
        confidence: f64,
        quantise: u32,
        #[wasm_bindgen(js_name = maxWaitSeconds)] max_wait_seconds: f64,
    ) -> i32 {
        let clock = transition_clock(time_seconds, beat_phase, bar_phase, tempo_bpm, confidence);
        // SAFETY: the handle is live; clock and status are distinct owned storage.
        unsafe {
            oscillux_transition_request(
                self.handle,
                &clock,
                quantise,
                max_wait_seconds,
                &mut self.status,
            )
        }
    }
    /// Per-frame evaluation at `timeSeconds`, issuing an automatic request when one is due.
    pub fn update(
        &mut self,
        #[wasm_bindgen(js_name = timeSeconds)] time_seconds: f64,
        #[wasm_bindgen(js_name = beatPhase)] beat_phase: f64,
        #[wasm_bindgen(js_name = barPhase)] bar_phase: f64,
        #[wasm_bindgen(js_name = tempoBpm)] tempo_bpm: f64,
        confidence: f64,
    ) -> i32 {
        let clock = transition_clock(time_seconds, beat_phase, bar_phase, tempo_bpm, confidence);
        // SAFETY: the handle is live; clock and status are distinct owned storage.
        unsafe { oscillux_transition_update(self.handle, &clock, &mut self.status) }
    }
    /// Evaluates the schedule at `timeSeconds` without changing it.
    pub fn status(&mut self, #[wasm_bindgen(js_name = timeSeconds)] time_seconds: f64) -> i32 {
        // SAFETY: the handle is live; status is a valid destination.
        unsafe { oscillux_transition_status(self.handle, time_seconds, &mut self.status) }
    }
    /// Returns to idle and restarts the auto-advance count.
    pub fn reset(&mut self) -> i32 {
        self.status = OscilluxTransitionStatus::default();
        // SAFETY: the handle is live until drop.
        unsafe { oscillux_transition_reset(self.handle) }
    }
    /// Blend progress in [0, 1]; exactly 1 from the end of the blend.
    #[wasm_bindgen(getter)]
    pub fn progress(&self) -> f64 {
        self.status.progress
    }
    /// `OSCILLUX_TRANSITION_STATE_*`: 0 idle, 1 pre-roll, 2 waiting, 3 blending, 4 done.
    #[wasm_bindgen(getter)]
    pub fn state(&self) -> u32 {
        self.status.state
    }
    /// Time of the request, s.
    #[wasm_bindgen(getter = requestSeconds)]
    pub fn request_seconds(&self) -> f64 {
        self.status.request_seconds
    }
    /// Time the blend starts, s.
    #[wasm_bindgen(getter = startSeconds)]
    pub fn start_seconds(&self) -> f64 {
        self.status.start_seconds
    }
    /// Time the blend ends, s.
    #[wasm_bindgen(getter = endSeconds)]
    pub fn end_seconds(&self) -> f64 {
        self.status.end_seconds
    }
    /// Quantisation applied to the start: 0 none, 1 beat, 2 bar.
    #[wasm_bindgen(getter)]
    pub fn quantise(&self) -> u32 {
        self.status.quantise
    }
    /// True when the last update issued an automatic request.
    #[wasm_bindgen(getter = autoRequested)]
    pub fn auto_requested(&self) -> bool {
        self.status.auto_requested != 0
    }
}

impl Drop for Transition {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_transition_destroy(self.handle) }
    }
}

// ==== Reaction ===============================================================================

use oscillux::reaction::{
    oscillux_reaction_config_default, oscillux_reaction_create, oscillux_reaction_destroy,
    oscillux_reaction_push, oscillux_reaction_queued, oscillux_reaction_reset,
    oscillux_reaction_sample, oscillux_reaction_set_beat_clock, OscilluxBeatClock,
    OscilluxReaction, OscilluxReactionConfig, OscilluxReactionSampler,
};

/// Reaction sampler configuration (`OscilluxReactionConfig`); every time is in ms. The
/// constructor writes the defaults with the analysis latencies of DSP `behaviorVersion` at
/// `sampleRateHz` and throws for a version without measured latencies or a zero rate.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct ReactionConfig(OscilluxReactionConfig);

#[wasm_bindgen]
impl ReactionConfig {
    #[wasm_bindgen(constructor)]
    pub fn new(
        #[wasm_bindgen(js_name = behaviorVersion)] behavior_version: u32,
        #[wasm_bindgen(js_name = sampleRateHz)] sample_rate_hz: u32,
    ) -> Result<ReactionConfig, JsError> {
        let mut config = OscilluxReactionConfig::default();
        // SAFETY: `config` is a valid, exclusive destination with its struct_size set.
        let status = unsafe {
            oscillux_reaction_config_default(behavior_version, sample_rate_hz, &mut config)
        };
        if status != OSCILLUX_OK {
            return Err(refused("reaction configuration", status));
        }
        Ok(ReactionConfig(config))
    }
}

fields!(ReactionConfig {
    /// Hops queued, 1 ..= 65536.
    capacity, set_capacity, capacity: u32;
    /// Audio written at the host time to audio heard.
    output_latency_ms, set_output_latency_ms, outputLatencyMs: f64;
    /// Frame presented to light emitted.
    display_latency_ms, set_display_latency_ms, displayLatencyMs: f64;
    /// Sample time to frame presentation.
    render_ahead_ms, set_render_ahead_ms, renderAheadMs: f64;
    /// Hop time to the audio its continuous values describe.
    analysis_latency_ms, set_analysis_latency_ms, analysisLatencyMs: f64;
    /// Hop time to the audio its transients describe.
    onset_latency_ms, set_onset_latency_ms, onsetLatencyMs: f64;
    /// Release time constant of the onset.
    onset_release_ms, set_onset_release_ms, onsetReleaseMs: f64;
    /// Release time constant of the bass impact.
    bass_impact_release_ms, set_bass_impact_release_ms, bassImpactReleaseMs: f64;
    /// Release time constant of the flux.
    flux_release_ms, set_flux_release_ms, fluxReleaseMs: f64;
    /// Beat pulse decay time constant after the beat.
    pulse_decay_ms, set_pulse_decay_ms, pulseDecayMs: f64;
    /// Beat pulse Gaussian rise width before the beat.
    pulse_rise_ms, set_pulse_rise_ms, pulseRiseMs: f64;
    /// Share of an onset's phase error taken, 0 ..= 1.
    phase_lock_gain, set_phase_lock_gain, phaseLockGain: f64;
});

/// A host beat clock (`OscilluxBeatClock`): the beat position at one media time and its tempo.
/// The constructor writes 120 BPM in 4/4 at beat 0, media time 0.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct BeatClock(OscilluxBeatClock);

#[wasm_bindgen]
impl BeatClock {
    #[wasm_bindgen(constructor)]
    pub fn new() -> BeatClock {
        BeatClock(OscilluxBeatClock {
            media_time_ms: 0.0,
            tempo_bpm: 120.0,
            beat_phase: 0.0,
            bar_phase: 0.0,
            beat_index: 0,
            beats_per_bar: 4,
            reserved: 0,
        })
    }
    /// Index of the current beat (an integer; fractions are truncated).
    #[wasm_bindgen(getter = beatIndex)]
    pub fn beat_index(&self) -> f64 {
        self.0.beat_index as f64
    }
    #[wasm_bindgen(setter = beatIndex)]
    pub fn set_beat_index(&mut self, value: f64) {
        self.0.beat_index = value as i64;
    }
}

impl Default for BeatClock {
    fn default() -> Self {
        Self::new()
    }
}

fields!(BeatClock {
    /// Media time of this position, ms.
    media_time_ms, set_media_time_ms, mediaTimeMs: f64;
    /// Tempo, > 0.
    tempo_bpm, set_tempo_bpm, tempoBpm: f64;
    /// [0, 1); 0 is the beat.
    beat_phase, set_beat_phase, beatPhase: f64;
    /// [0, 1); 0 is the downbeat.
    bar_phase, set_bar_phase, barPhase: f64;
    /// 1 ..= 16.
    beats_per_bar, set_beats_per_bar, beatsPerBar: u32;
});

/// Reaction sampler (`OscilluxReactionSampler`) with a preallocated `OscilluxReaction` output:
/// the `OscilluxMapped` layout of `Mapper.outputPtr` (bytes 0 .. 328), then little-endian
/// Float64 at 328 (beat), 336 (downbeat), 344 (beatPhase), 352 (barPhase), 360 (tempoBpm), 368
/// (confidence), Int64 at 376 (beatCount) and Uint32 at 384 (beatInBar) and 388 (locked).
/// `push`, `pushWithBeat`, `sample` and the accessors do not allocate.
#[wasm_bindgen]
pub struct ReactionSampler {
    handle: *mut OscilluxReactionSampler,
    output: Box<OscilluxReaction>,
}

#[wasm_bindgen]
impl ReactionSampler {
    #[wasm_bindgen(constructor)]
    pub fn new(config: &ReactionConfig) -> Result<ReactionSampler, JsError> {
        let mut handle = null_mut();
        // SAFETY: config and handle are valid for the call.
        let status = unsafe { oscillux_reaction_create(&config.0, &mut handle) };
        if status != OSCILLUX_OK {
            return Err(refused("reaction configuration", status));
        }
        Ok(Self {
            handle,
            output: Box::new(OscilluxReaction::ZERO),
        })
    }
    /// Byte offset of the `OscilluxReaction` output.
    #[wasm_bindgen(js_name = outputPtr)]
    pub fn output_ptr(&self) -> u32 {
        &*self.output as *const OscilluxReaction as u32
    }
    /// Queues `mapper`'s last output as the hop whose analysis window ends at `mediaTimeMs`,
    /// without tracker output; returns a status.
    pub fn push(
        &mut self,
        #[wasm_bindgen(js_name = mediaTimeMs)] media_time_ms: f64,
        mapper: &Mapper,
    ) -> i32 {
        // SAFETY: the handle is live; the mapped output is owned by `mapper`; null beat.
        unsafe {
            oscillux_reaction_push(
                self.handle,
                media_time_ms,
                &*mapper.output,
                core::ptr::null(),
            )
        }
    }
    /// As `push`, with the tracker output of frame `index` of `dsp`'s last `pushExt` or
    /// `pushExtF64`; invalid after any other push.
    #[wasm_bindgen(js_name = pushWithBeat)]
    pub fn push_with_beat(
        &mut self,
        #[wasm_bindgen(js_name = mediaTimeMs)] media_time_ms: f64,
        mapper: &Mapper,
        dsp: &Dsp,
        index: u32,
    ) -> i32 {
        if index >= dsp.produced || !dsp.ext_produced {
            return INVALID;
        }
        let beat = &dsp.ext[index as usize].beat;
        // SAFETY: the handle is live; mapped and beat are distinct owned storage.
        unsafe { oscillux_reaction_push(self.handle, media_time_ms, &*mapper.output, beat) }
    }
    /// Drives the beat outputs from `clock` instead of the tracker; returns a status.
    #[wasm_bindgen(js_name = setBeatClock)]
    pub fn set_beat_clock(&mut self, clock: &BeatClock) -> i32 {
        // SAFETY: the handle is live; clock is valid for the call.
        unsafe { oscillux_reaction_set_beat_clock(self.handle, &clock.0) }
    }
    /// Returns the beat outputs to the tracker; returns a status.
    #[wasm_bindgen(js_name = clearBeatClock)]
    pub fn clear_beat_clock(&mut self) -> i32 {
        // SAFETY: the handle is live; null clears the clock.
        unsafe { oscillux_reaction_set_beat_clock(self.handle, core::ptr::null()) }
    }
    /// Writes the values seen at the photon time of a frame sampled at host media time `timeMs`
    /// to the output; returns a status.
    pub fn sample(&mut self, #[wasm_bindgen(js_name = timeMs)] time_ms: f64) -> i32 {
        // SAFETY: the handle is live; output is owned, exclusive storage.
        unsafe { oscillux_reaction_sample(self.handle, time_ms, &mut *self.output) }
    }
    /// Forgets every hop, held peak, the beat clock and the beat state; returns a status.
    pub fn reset(&mut self) -> i32 {
        // SAFETY: the handle is live until drop.
        unsafe { oscillux_reaction_reset(self.handle) }
    }
    /// Hops queued and not yet consumed.
    pub fn queued(&self) -> u32 {
        let mut queued = 0;
        // SAFETY: the handle is live; `queued` is a valid destination.
        unsafe { oscillux_reaction_queued(self.handle, &mut queued) };
        queued
    }
    /// Mapped value `index` (a `MappedValue`) from the last sample, or undefined.
    pub fn value(&self, index: u32) -> Option<f64> {
        self.output.mapped.values.get(index as usize).copied()
    }
    /// Spectrum bin `index` (0 ..= 63) from the last sample, or undefined.
    pub fn spectrum(&self, index: u32) -> Option<f32> {
        self.output.mapped.spectrum.get(index as usize).copied()
    }
    /// Beat pulse, [0, 1]; 1 at the beat's photon time.
    pub fn beat(&self) -> f64 {
        self.output.beat
    }
    /// Beat pulse of downbeats only, [0, 1].
    pub fn downbeat(&self) -> f64 {
        self.output.downbeat
    }
    /// Output beat phase, [0, 1).
    #[wasm_bindgen(js_name = beatPhase)]
    pub fn beat_phase(&self) -> f64 {
        self.output.beat_phase
    }
    /// Output bar phase, [0, 1).
    #[wasm_bindgen(js_name = barPhase)]
    pub fn bar_phase(&self) -> f64 {
        self.output.bar_phase
    }
    /// Tempo of the reference clock; 0 without one.
    #[wasm_bindgen(js_name = tempoBpm)]
    pub fn tempo_bpm(&self) -> f64 {
        self.output.tempo_bpm
    }
    /// Tracker confidence; 1 with a host clock; 0 without a reference.
    pub fn confidence(&self) -> f64 {
        self.output.confidence
    }
    /// Beats counted at output wraps.
    #[wasm_bindgen(js_name = beatCount)]
    pub fn beat_count(&self) -> f64 {
        self.output.beat_count as f64
    }
    /// Index of the current beat within the bar; 0 is the downbeat.
    #[wasm_bindgen(js_name = beatInBar)]
    pub fn beat_in_bar(&self) -> u32 {
        self.output.beat_in_bar
    }
    /// Whether a reference drives the beat outputs.
    pub fn locked(&self) -> bool {
        self.output.locked != 0
    }
}

impl Drop for ReactionSampler {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_reaction_destroy(self.handle) }
    }
}

// ==== Beat grid ==============================================================================

use oscillux::beatgrid::{
    oscillux_beatgrid_beat_count, oscillux_beatgrid_clock, oscillux_beatgrid_config_default,
    oscillux_beatgrid_config_validate, oscillux_beatgrid_copy_beats, oscillux_beatgrid_create,
    oscillux_beatgrid_destroy, oscillux_beatgrid_info, OscilluxBeatGrid, OscilluxBeatGridBeat,
    OscilluxBeatGridClock, OscilluxBeatGridConfig, OscilluxBeatGridInfo,
};

/// Beat grid analysis parameters (`OscilluxBeatGridConfig`); the constructor writes the
/// defaults.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct BeatGridConfig(OscilluxBeatGridConfig);

#[wasm_bindgen]
impl BeatGridConfig {
    #[wasm_bindgen(constructor)]
    pub fn new() -> BeatGridConfig {
        // `struct_size` already selects the released layout, as the C call requires.
        let mut config = OscilluxBeatGridConfig::default();
        // SAFETY: `config` is a valid, exclusive destination.
        unsafe { oscillux_beatgrid_config_default(&mut config) };
        BeatGridConfig(config)
    }
    /// The first member `new BeatGrid` would refuse, spelled as in oscillux.h (for example
    /// "sample_rate_hz" or "max_bpm"), or undefined when the configuration is valid.
    pub fn validate(&self) -> Option<String> {
        let mut field: *const c_char = core::ptr::null();
        // SAFETY: both pointers are valid; a non-null field is static and NUL-terminated.
        let status = unsafe { oscillux_beatgrid_config_validate(&self.0, &mut field) };
        if status == OSCILLUX_OK {
            return None;
        }
        if field.is_null() {
            return Some("config".into());
        }
        // SAFETY: see above.
        Some(
            unsafe { CStr::from_ptr(field) }
                .to_string_lossy()
                .into_owned(),
        )
    }
}

impl Default for BeatGridConfig {
    fn default() -> Self {
        Self::new()
    }
}

fields!(BeatGridConfig {
    /// PCM sample rate, Hz; 8000 ..= 384000.
    sample_rate_hz, set_sample_rate_hz, sampleRateHz: u32;
    /// Interleaved channels, averaged to mono; at least 1.
    channels, set_channels, channels: u32;
    /// Meter hint: 2 ..= 16 beats per bar, or 0 to choose 3 or 4 from the audio.
    beats_per_bar, set_beats_per_bar, beatsPerBar: u32;
    /// Slowest beat tempo considered, BPM; at least 20 and below maxBpm.
    min_bpm, set_min_bpm, minBpm: f64;
    /// Fastest beat tempo considered, BPM; at most 400.
    max_bpm, set_max_bpm, maxBpm: f64;
});

/// Offline beat and downbeat grid (`OscilluxBeatGrid`) of a whole PCM buffer. The constructor
/// runs the analysis and copies every beat into an owned array at `beatsPtr()`: `beatCount`
/// elements `beatBytes()` (24) apart, each little-endian Float64 at 0 (timeSeconds) and 8
/// (tempoBpm) and Uint32 at 16 (beatInBar) and 20 (barIndex). `clock` writes the position at a
/// media time to the getters below without allocating.
#[wasm_bindgen]
pub struct BeatGrid {
    handle: *mut OscilluxBeatGrid,
    beats: Box<[OscilluxBeatGridBeat]>,
    info: OscilluxBeatGridInfo,
    clock: OscilluxBeatGridClock,
}

#[wasm_bindgen]
impl BeatGrid {
    /// Analyses interleaved Float32 PCM, `config.channels` samples per frame. Allocates and runs
    /// the whole analysis. Throws naming the refused member, or when the length is not a whole
    /// number of frames.
    #[wasm_bindgen(constructor)]
    pub fn new(config: &BeatGridConfig, samples: &[f32]) -> Result<BeatGrid, JsError> {
        if let Some(field) = config.validate() {
            return Err(JsError::new(&format!("beat grid configuration: {field}")));
        }
        let channels = config.0.channels as usize;
        if !samples.len().is_multiple_of(channels) {
            return Err(JsError::new("samples: not a whole number of frames"));
        }
        let mut handle = null_mut();
        // SAFETY: config and handle are valid; samples holds frames * channels values.
        let status = unsafe {
            oscillux_beatgrid_create(
                &config.0,
                samples.as_ptr(),
                samples.len() / channels,
                &mut handle,
            )
        };
        if status != OSCILLUX_OK {
            return Err(refused("beat grid", status));
        }
        let mut grid = Self {
            handle,
            beats: Box::default(),
            info: OscilluxBeatGridInfo::default(),
            clock: OscilluxBeatGridClock {
                beat_index: -1,
                ..OscilluxBeatGridClock::default()
            },
        };
        let mut count = 0;
        // SAFETY: the handle is live; the destinations are valid and exclusive.
        unsafe {
            oscillux_beatgrid_beat_count(handle, &mut count);
            oscillux_beatgrid_info(handle, &mut grid.info);
        }
        let mut beats = vec![OscilluxBeatGridBeat::default(); count].into_boxed_slice();
        let mut written = 0;
        // SAFETY: `beats` holds `count` elements.
        unsafe { oscillux_beatgrid_copy_beats(handle, 0, beats.as_mut_ptr(), count, &mut written) };
        debug_assert_eq!(written, count);
        grid.beats = beats;
        Ok(grid)
    }
    /// Byte offset of the beat array.
    #[wasm_bindgen(js_name = beatsPtr)]
    pub fn beats_ptr(&self) -> u32 {
        self.beats.as_ptr() as u32
    }
    /// Bytes between beats, `sizeof(OscilluxBeatGridBeat)`.
    #[wasm_bindgen(js_name = beatBytes)]
    pub fn beat_bytes() -> u32 {
        core::mem::size_of::<OscilluxBeatGridBeat>() as u32
    }
    /// Beats in the grid.
    #[wasm_bindgen(getter = beatCount)]
    pub fn beat_count(&self) -> u32 {
        self.beats.len() as u32
    }
    /// Downbeats in the grid.
    #[wasm_bindgen(getter = barCount)]
    pub fn bar_count(&self) -> f64 {
        self.info.bar_count as f64
    }
    /// Global tempo, BPM; 0 for an empty grid.
    #[wasm_bindgen(getter = tempoBpm)]
    pub fn tempo_bpm(&self) -> f64 {
        self.info.tempo_bpm
    }
    /// Meter used: the hint, or 3 or 4 chosen from the audio; 0 for an empty grid.
    #[wasm_bindgen(getter = beatsPerBar)]
    pub fn beats_per_bar(&self) -> u32 {
        self.info.beats_per_bar
    }
    /// Periodicity of the onset envelope at the global beat period, 0 ..= 1.
    #[wasm_bindgen(getter)]
    pub fn confidence(&self) -> f64 {
        self.info.confidence
    }
    /// Length of the analysed PCM, seconds.
    #[wasm_bindgen(getter = durationSeconds)]
    pub fn duration_seconds(&self) -> f64 {
        self.info.duration_seconds
    }
    /// Writes the position at `mediaTimeSeconds` from the start of the PCM to the clock getters;
    /// returns a status. Without a position (fewer than two beats, or a non-finite time, which
    /// is refused) `beatIndex` is -1 and the other clock getters 0. Does not allocate.
    pub fn clock(
        &mut self,
        #[wasm_bindgen(js_name = mediaTimeSeconds)] media_time_seconds: f64,
    ) -> i32 {
        // SAFETY: the handle is live until drop; the clock is owned.
        unsafe { oscillux_beatgrid_clock(self.handle, media_time_seconds, &mut self.clock) }
    }
    /// Progress from the current beat to the next, [0, 1).
    #[wasm_bindgen(getter = beatPhase)]
    pub fn beat_phase(&self) -> f64 {
        self.clock.beat_phase
    }
    /// Progress through the current bar, [0, 1).
    #[wasm_bindgen(getter = barPhase)]
    pub fn bar_phase(&self) -> f64 {
        self.clock.bar_phase
    }
    /// Index of the current beat: negative before the first beat, at or above `beatCount` after
    /// the last (the grid is extrapolated at its first and last interval), -1 without a
    /// position.
    #[wasm_bindgen(getter = beatIndex)]
    pub fn beat_index(&self) -> f64 {
        self.clock.beat_index as f64
    }
    /// Position of the current beat in its bar, 0 at a downbeat.
    #[wasm_bindgen(getter = beatInBar)]
    pub fn beat_in_bar(&self) -> u32 {
        self.clock.beat_in_bar
    }
    /// Local tempo of the current beat, BPM.
    #[wasm_bindgen(getter = localTempoBpm)]
    pub fn local_tempo_bpm(&self) -> f64 {
        self.clock.tempo_bpm
    }
}

impl Drop for BeatGrid {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_beatgrid_destroy(self.handle) }
    }
}

// ==== Overlay regions (OSC-OVERLAY) ==========================================================

/// `OverlayRegions.setRegion` mode bits; `LightText` and `DarkText` are exclusive.
#[wasm_bindgen]
pub enum OverlayMode {
    /// Hold the region's luminance at or below the ceiling, for light text.
    LightText = 1,
    /// Hold the region's luminance at or above the floor, for dark text.
    DarkText = 2,
    Desaturate = 4,
    Blur = 8,
    DampMotion = 16,
    /// Hold the grid cells the region covers to the analyzer's `FlashOverlay`.
    DampFlash = 32,
}

/// Overlay presentation config (`OscilluxOverlayConfig`); the constructor writes the defaults.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct OverlayConfig(OscilluxOverlayConfig);

#[wasm_bindgen]
impl OverlayConfig {
    #[wasm_bindgen(constructor)]
    pub fn new() -> OverlayConfig {
        let mut config = OscilluxOverlayConfig::default();
        // SAFETY: `config` is a valid, exclusive destination with its struct_size set.
        unsafe { oscillux_overlay_config_default(&mut config) };
        OverlayConfig(config)
    }
    /// The user asked for reduced motion (`prefers-reduced-motion: reduce`).
    #[wasm_bindgen(getter = reducedMotion)]
    pub fn reduced_motion(&self) -> bool {
        self.0.reduced_motion != 0
    }
    #[wasm_bindgen(setter = reducedMotion)]
    pub fn set_reduced_motion(&mut self, value: bool) {
        self.0.reduced_motion = value.into();
    }
    /// The canvas composites premultiplied alpha.
    #[wasm_bindgen(getter = premultipliedAlpha)]
    pub fn premultiplied_alpha(&self) -> bool {
        self.0.premultiplied_alpha != 0
    }
    #[wasm_bindgen(setter = premultipliedAlpha)]
    pub fn set_premultiplied_alpha(&mut self, value: bool) {
        self.0.premultiplied_alpha = value.into();
    }
    /// The intensity visuals present at: `intensity`, halved under reduced motion. Throws when
    /// the config is refused.
    #[wasm_bindgen(js_name = presentationIntensity)]
    pub fn presentation_intensity(&self) -> Result<f64, JsError> {
        let mut out = 0.0;
        // SAFETY: both pointers are valid for the call.
        let status = unsafe { oscillux_overlay_presentation_intensity(&self.0, &mut out) };
        if status != OSCILLUX_OK {
            return Err(refused("overlay config", status));
        }
        Ok(out)
    }
    /// Tightens `flash` for reduced motion (at most 1 general and 1 red flash a second over 0.1
    /// of a field); never loosens it. Returns a status; a refusal leaves `flash` unchanged.
    #[wasm_bindgen(js_name = tightenFlashConfig)]
    pub fn tighten_flash_config(&self, flash: &mut FlashConfig) -> i32 {
        // SAFETY: both configs are valid and distinct.
        unsafe { oscillux_overlay_flash_config(&self.0, &mut flash.0) }
    }
}

impl Default for OverlayConfig {
    fn default() -> Self {
        Self::new()
    }
}

fields!(OverlayConfig {
    /// Levels per channel: 0 for a float target or 2 ..= 65535; default 255.
    output_levels, set_output_levels, outputLevels: u32;
    /// Drawing-buffer width in pixels.
    viewport_width, set_viewport_width, viewportWidth: f64;
    /// Drawing-buffer height in pixels.
    viewport_height, set_viewport_height, viewportHeight: f64;
    /// WCAG contrast ratio text regions guarantee, [1, 21]; default 4.5.
    contrast_ratio, set_contrast_ratio, contrastRatio: f64;
    /// Host presentation intensity before reduced motion, [0, 1].
    intensity, set_intensity, intensity: f64;
    /// Milliseconds since the previous presented frame, (0, 1000].
    frame_interval_ms, set_frame_interval_ms, frameIntervalMs: f64;
    /// Output alpha outside text regions, [0, 1].
    alpha, set_alpha, alpha: f64;
});

/// Up to `OSCILLUX_OVERLAY_MAX_REGIONS` (8) overlay regions and the packed 320-byte
/// `OverlayUniforms` block. `pack` does not allocate.
#[wasm_bindgen]
pub struct OverlayRegions {
    regions: Box<[OscilluxOverlayRegion; OVERLAY_MAX_REGIONS]>,
    count: usize,
    uniforms: Box<[u8; OVERLAY_UNIFORMS_BYTES]>,
}

const OVERLAY_MAX_REGIONS: usize = OSCILLUX_OVERLAY_MAX_REGIONS as usize;
const OVERLAY_UNIFORMS_BYTES: usize = OSCILLUX_OVERLAY_UNIFORMS_SIZE as usize;

#[wasm_bindgen]
impl OverlayRegions {
    /// No regions; the uniform block is zero.
    #[wasm_bindgen(constructor)]
    pub fn new() -> OverlayRegions {
        Self {
            regions: Box::new([OscilluxOverlayRegion::default(); OVERLAY_MAX_REGIONS]),
            count: 0,
            uniforms: Box::new([0; OVERLAY_UNIFORMS_BYTES]),
        }
    }
    /// Writes region `index` (0 ..= 7) in viewport fractions, origin top-left; `mode` is
    /// `OverlayMode` bits. Values are checked by `pack` and `FlashAnalyzer.setOverlay`.
    #[wasm_bindgen(js_name = setRegion)]
    #[allow(clippy::too_many_arguments)]
    pub fn set_region(
        &mut self,
        index: u32,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        #[wasm_bindgen(js_name = cornerRadius)] corner_radius: f64,
        feather: f64,
        strength: f64,
        mode: u32,
    ) -> i32 {
        let Some(region) = self.regions.get_mut(index as usize) else {
            return INVALID;
        };
        *region = OscilluxOverlayRegion {
            x,
            y,
            width,
            height,
            corner_radius,
            feather,
            strength,
            mode,
            reserved: 0,
        };
        OSCILLUX_OK
    }
    /// Regions in use, the first `count` of the array.
    #[wasm_bindgen(getter)]
    pub fn count(&self) -> u32 {
        self.count as u32
    }
    /// Uses the first `count` regions (0 ..= 8); returns a status.
    #[wasm_bindgen(js_name = setCount)]
    pub fn set_count(&mut self, count: u32) -> i32 {
        if count as usize > OVERLAY_MAX_REGIONS {
            return INVALID;
        }
        self.count = count as usize;
        OSCILLUX_OK
    }
    /// Packs the regions in use under `config` into the uniform block; returns a status. A
    /// refusal leaves the block unchanged.
    pub fn pack(&mut self, config: &OverlayConfig) -> i32 {
        // SAFETY: config, regions and the block are valid, distinct owned storage.
        unsafe {
            oscillux_overlay_pack(
                &config.0,
                self.regions.as_ptr(),
                self.count,
                self.uniforms.as_mut_ptr(),
                self.uniforms.len(),
            )
        }
    }
    /// Byte offset of the packed `OverlayUniforms` block.
    #[wasm_bindgen(js_name = uniformsPtr)]
    pub fn uniforms_ptr(&self) -> u32 {
        self.uniforms.as_ptr() as u32
    }
    /// Size of the block in bytes, 320.
    #[wasm_bindgen(js_name = uniformsBytes)]
    pub fn uniforms_bytes(&self) -> u32 {
        OVERLAY_UNIFORMS_BYTES as u32
    }
}

impl Default for OverlayRegions {
    fn default() -> Self {
        Self::new()
    }
}

/// Stricter flash rules for `OverlayMode.DampFlash` regions (`OscilluxFlashOverlay`); the
/// constructor writes the defaults.
#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct FlashOverlay(OscilluxFlashOverlay);

#[wasm_bindgen]
impl FlashOverlay {
    #[wasm_bindgen(constructor)]
    pub fn new() -> FlashOverlay {
        let mut overlay = OscilluxFlashOverlay::default();
        // SAFETY: `overlay` is a valid, exclusive destination with its struct_size set.
        unsafe { oscillux_flash_overlay_default(&mut overlay) };
        FlashOverlay(overlay)
    }
}

impl Default for FlashOverlay {
    fn default() -> Self {
        Self::new()
    }
}

fields!(FlashOverlay {
    /// Smallest luminance change that counts inside, (0, 0.1]; default 0.05.
    luminance_change, set_luminance_change, luminanceChange: f64;
    /// A change counts once its darker end is below this, [0.8, 1]; default 1.
    darker_limit, set_darker_limit, darkerLimit: f64;
    /// Overlay flashes a second, at most the analyzer's; default 1.
    max_flash_hz, set_max_flash_hz, maxFlashHz: f64;
    /// Fraction of overlay cells above which a frame is a transition; default 0 (one cell).
    max_area, set_max_area, maxArea: f64;
});

/// The overlay outcome `FlashAnalyzer.overlayReport` writes (`OscilluxFlashOverlayReport`).
#[wasm_bindgen]
pub struct FlashOverlayReport(OscilluxFlashOverlayReport);

#[wasm_bindgen]
impl FlashOverlayReport {
    #[wasm_bindgen(constructor)]
    pub fn new() -> FlashOverlayReport {
        FlashOverlayReport(OscilluxFlashOverlayReport {
            struct_size: FLASH_OVERLAY_REPORT_SIZE,
            active: 0,
            transition: 0,
            regions: 0,
            cells: 0,
            exceeds: 0,
            flashes_in_window: 0.0,
        })
    }
    /// An overlay is set.
    #[wasm_bindgen(getter)]
    pub fn active(&self) -> bool {
        self.0.active != 0
    }
    /// The frame holds an overlay transition.
    #[wasm_bindgen(getter)]
    pub fn transition(&self) -> bool {
        self.0.transition != 0
    }
    /// Overlay cells completing a change this frame.
    #[wasm_bindgen(getter)]
    pub fn regions(&self) -> u32 {
        self.0.regions
    }
    /// Grid cells the overlay covers.
    #[wasm_bindgen(getter)]
    pub fn cells(&self) -> u32 {
        self.0.cells
    }
    /// The overlay window holds more flashes than it allows.
    #[wasm_bindgen(getter)]
    pub fn exceeds(&self) -> bool {
        self.0.exceeds != 0
    }
    /// Overlay flashes (transitions / 2) in the last 1000 ms.
    #[wasm_bindgen(getter = flashesInWindow)]
    pub fn flashes_in_window(&self) -> f64 {
        self.0.flashes_in_window
    }
}

impl Default for FlashOverlayReport {
    fn default() -> Self {
        Self::new()
    }
}

#[wasm_bindgen]
impl FlashAnalyzer {
    /// Holds the grid cells `regions`' `DampFlash` regions cover to `overlay` from the next
    /// frame; returns a status. A refusal keeps the previous overlay. Call on layout changes.
    #[wasm_bindgen(js_name = setOverlay)]
    pub fn set_overlay(&mut self, overlay: &FlashOverlay, regions: &OverlayRegions) -> i32 {
        // SAFETY: the handle is live; the overlay and regions are valid for the call.
        unsafe {
            oscillux_flash_analyzer_set_overlay(
                self.handle,
                &overlay.0,
                regions.regions.as_ptr(),
                regions.count,
            )
        }
    }
    /// Removes the overlay; the analyzer then measures exactly as without one.
    #[wasm_bindgen(js_name = clearOverlay)]
    pub fn clear_overlay(&mut self) -> i32 {
        // SAFETY: the handle is live; a null overlay clears.
        unsafe {
            oscillux_flash_analyzer_set_overlay(
                self.handle,
                core::ptr::null(),
                core::ptr::null(),
                0,
            )
        }
    }
    /// Writes the overlay outcome of the last measured or admitted frame; returns a status.
    #[wasm_bindgen(js_name = overlayReport)]
    pub fn overlay_report(&self, out: &mut FlashOverlayReport) -> i32 {
        // SAFETY: the handle is live; `out` is a valid, exclusive destination.
        unsafe { oscillux_flash_analyzer_overlay_report(self.handle, &mut out.0) }
    }
}

// ==== CD+G (OSC-CDG) =========================================================================

/// CD+G lyric graphics decoder (`OscilluxCdg`) over a copied pack stream, with a preallocated
/// screen of colour indices (`screenPtr`, 300 x 216 bytes) and window (`rgbaPtr`, 288 x 192
/// straight-alpha RGBA8). The getters read the state of the last advance or `state` call;
/// `count` reads the last `indexCounts` call.
#[wasm_bindgen]
pub struct Cdg {
    handle: *mut OscilluxCdg,
    state: OscilluxCdgState,
    screen: Box<[u8]>,
    rgba: Box<[u8]>,
    counts: [u32; 16],
}

#[wasm_bindgen]
impl Cdg {
    /// Copies `packs` (24-byte packs; a trailing partial pack is ignored) and makes the seek
    /// checkpoints.
    #[wasm_bindgen(constructor)]
    pub fn new(packs: &[u8]) -> Result<Cdg, JsError> {
        let mut handle = null_mut();
        // SAFETY: packs and handle are valid for the call.
        let status = unsafe { oscillux_cdg_create(packs.as_ptr(), packs.len(), &mut handle) };
        if status != OSCILLUX_OK {
            return Err(refused("cdg stream", status));
        }
        let mut cdg = Self {
            handle,
            state: OscilluxCdgState {
                struct_size: core::mem::size_of::<OscilluxCdgState>() as u32,
                ..Default::default()
            },
            screen: vec![0; oscillux::cdg::SCREEN_PIXELS as usize].into_boxed_slice(),
            rgba: vec![0; oscillux::cdg::WINDOW_RGBA_BYTES as usize].into_boxed_slice(),
            counts: [0; 16],
        };
        cdg.state();
        Ok(cdg)
    }
    /// Advances or seeks to media time `seconds` (pack `floor(seconds * 300)` is the last
    /// decoded) and reads the state; returns a status. NaN is refused unchanged.
    #[wasm_bindgen(js_name = advanceToTime)]
    pub fn advance_to_time(&mut self, seconds: f64) -> i32 {
        // SAFETY: the handle is live until drop.
        let status = unsafe { oscillux_cdg_advance_to_time(self.handle, seconds) };
        if status == OSCILLUX_OK {
            self.state()
        } else {
            status
        }
    }
    /// Advances or seeks so the first `applied` packs (clamped to the stream) are decoded and
    /// reads the state; returns a status. A negative or non-integer count is refused.
    #[wasm_bindgen(js_name = advanceToPack)]
    pub fn advance_to_pack(&mut self, applied: f64) -> i32 {
        if applied.is_nan() || applied < 0.0 || applied.fract() != 0.0 {
            return INVALID;
        }
        // SAFETY: the handle is live until drop.
        let status = unsafe { oscillux_cdg_advance_to_pack(self.handle, applied as u64) };
        if status == OSCILLUX_OK {
            self.state()
        } else {
            status
        }
    }
    /// Re-reads the state at the current position; returns a status.
    pub fn state(&mut self) -> i32 {
        // SAFETY: the handle is live; the state is owned and sized for the released layout.
        unsafe { oscillux_cdg_state(self.handle, &mut self.state) }
    }
    /// Copies the screen's colour indices to `screenPtr`; returns a status.
    pub fn screen(&mut self) -> i32 {
        // SAFETY: the handle is live; the buffer is owned and exactly the screen size.
        unsafe { oscillux_cdg_screen(self.handle, self.screen.as_mut_ptr(), self.screen.len()) }
    }
    /// Writes the window under transparency key `keyMode` (`OSCILLUX_CDG_KEY_*`: 0 none,
    /// 1 transparent-colour table, 2 Memory Preset colour, 3 the index `keyIndex`, 4 every index
    /// whose bit is set in the 16-bit mask `keyIndex`) to `rgbaPtr`; returns a status. A refusal
    /// leaves the buffer unchanged.
    #[wasm_bindgen(js_name = windowRgba)]
    pub fn window_rgba(
        &mut self,
        #[wasm_bindgen(js_name = keyMode)] key_mode: u32,
        #[wasm_bindgen(js_name = keyIndex)] key_index: u32,
    ) -> i32 {
        // SAFETY: the handle is live; the buffer is owned and exactly the window size.
        unsafe {
            oscillux_cdg_window_rgba(
                self.handle,
                key_mode,
                key_index,
                self.rgba.as_mut_ptr(),
                self.rgba.len(),
            )
        }
    }
    /// Counts the pixels of each colour index in the window's `region`
    /// (`OSCILLUX_CDG_REGION_*`: 0 the whole window, 1 the outer ring one tile deep), read with
    /// `count`; returns a status. A refusal leaves the counts unchanged.
    #[wasm_bindgen(js_name = indexCounts)]
    pub fn index_counts(&mut self, region: u32) -> i32 {
        // SAFETY: the handle is live; the counts are owned and exactly 16 entries.
        unsafe { oscillux_cdg_index_counts(self.handle, region, self.counts.as_mut_ptr(), 16) }
    }
    /// Pixels of colour `index` (0..15) counted by the last `indexCounts`.
    pub fn count(&self, index: u32) -> Result<u32, JsError> {
        self.counts
            .get(index as usize)
            .copied()
            .ok_or_else(|| JsError::new("colour index"))
    }
    /// Byte offset of the 300 x 216 colour indices written by `screen`.
    #[wasm_bindgen(js_name = screenPtr)]
    pub fn screen_ptr(&self) -> u32 {
        self.screen.as_ptr() as u32
    }
    /// Byte offset of the 288 x 192 RGBA8 window written by `windowRgba`.
    #[wasm_bindgen(js_name = rgbaPtr)]
    pub fn rgba_ptr(&self) -> u32 {
        self.rgba.as_ptr() as u32
    }
    /// Packs decoded at the current position.
    #[wasm_bindgen(getter)]
    pub fn applied(&self) -> f64 {
        self.state.applied as f64
    }
    /// Whole packs in the stream.
    #[wasm_bindgen(getter = packCount)]
    pub fn pack_count(&self) -> f64 {
        self.state.pack_count as f64
    }
    /// Horizontal scroll offset, 0..5.
    #[wasm_bindgen(getter = hOffset)]
    pub fn h_offset(&self) -> u32 {
        self.state.h_offset
    }
    /// Vertical scroll offset, 0..11.
    #[wasm_bindgen(getter = vOffset)]
    pub fn v_offset(&self) -> u32 {
        self.state.v_offset
    }
    /// Screen x of the window's left edge.
    #[wasm_bindgen(getter = windowX)]
    pub fn window_x(&self) -> u32 {
        self.state.window_x
    }
    /// Screen y of the window's top edge.
    #[wasm_bindgen(getter = windowY)]
    pub fn window_y(&self) -> u32 {
        self.state.window_y
    }
    /// Most recent Memory Preset colour index.
    #[wasm_bindgen(getter = presetColour)]
    pub fn preset_colour(&self) -> u32 {
        self.state.preset_colour
    }
    /// Most recent Border Preset colour index.
    #[wasm_bindgen(getter = borderColour)]
    pub fn border_colour(&self) -> u32 {
        self.state.border_colour
    }
    /// `OSCILLUX_CDG_CHANGED_*` bits of the last advance.
    #[wasm_bindgen(getter)]
    pub fn changes(&self) -> u32 {
        self.state.changes
    }
    /// Dirty rectangle `[dirtyX0, dirtyX1) x [dirtyY0, dirtyY1)` of the last advance, screen
    /// pixels; empty when `dirtyX0 == dirtyX1`.
    #[wasm_bindgen(getter = dirtyX0)]
    pub fn dirty_x0(&self) -> u32 {
        self.state.dirty_x0
    }
    /// See `dirtyX0`.
    #[wasm_bindgen(getter = dirtyY0)]
    pub fn dirty_y0(&self) -> u32 {
        self.state.dirty_y0
    }
    /// See `dirtyX0`.
    #[wasm_bindgen(getter = dirtyX1)]
    pub fn dirty_x1(&self) -> u32 {
        self.state.dirty_x1
    }
    /// See `dirtyX0`.
    #[wasm_bindgen(getter = dirtyY1)]
    pub fn dirty_y1(&self) -> u32 {
        self.state.dirty_y1
    }
    /// Colour `index` (0..15) as `0xRGB`.
    pub fn colour(&self, index: u32) -> Result<u32, JsError> {
        self.state
            .palette
            .get(index as usize)
            .copied()
            .ok_or_else(|| JsError::new("colour index"))
    }
    /// The 6-bit transparent-colour table value of colour `index` (0..15).
    pub fn transparency(&self, index: u32) -> Result<u32, JsError> {
        self.state
            .transparent
            .get(index as usize)
            .copied()
            .ok_or_else(|| JsError::new("colour index"))
    }
}

impl Drop for Cdg {
    fn drop(&mut self) {
        // SAFETY: the handle came from create and is destroyed once.
        unsafe { oscillux_cdg_destroy(self.handle) }
    }
}
