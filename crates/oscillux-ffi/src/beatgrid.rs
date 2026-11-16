// SPDX-License-Identifier: AGPL-3.0-only
//! C interface to the offline beat grid. The beat grid section of `ffi/include/oscillux.h`
//! declares these functions and mirrors the structs field for field.
//!
//! [`oscillux_beatgrid_create`] analyses a whole PCM buffer and allocates, so it belongs off the
//! frame path. The queries take a `const` handle and do not allocate; [`oscillux_beatgrid_clock`]
//! is the per-frame one.

use core::ffi::{c_char, CStr};
use core::mem::size_of;

use oscillux_core::beatgrid::{BeatClock, BeatGrid, BeatGridConfig, BeatGridError, GridBeat};

use crate::{guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};

/// Opaque beat grid handle: the analysed grid of one PCM buffer.
pub struct OscilluxBeatGrid {
    grid: BeatGrid,
}

/// Beat grid analysis parameters, size-checked by `struct_size`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscilluxBeatGridConfig {
    /// `size_of::<OscilluxBeatGridConfig>()`, the only released size.
    pub struct_size: u32,
    /// Sample rate of the PCM, Hz, 8000 ..= 384000; default 44100.
    pub sample_rate_hz: u32,
    /// Interleaved channels, at least 1, averaged to mono; default 2.
    pub channels: u32,
    /// Meter hint: 2 ..= 16 beats per bar, or 0 to choose 3 or 4 from the audio; default 0.
    pub beats_per_bar: u32,
    /// Slowest beat tempo considered, BPM, 20 ..< 400; default 40.
    pub min_bpm: f64,
    /// Fastest beat tempo considered, BPM, above `min_bpm` and at most 400; default 240.
    pub max_bpm: f64,
}

const CONFIG_SIZE: u32 = size_of::<OscilluxBeatGridConfig>() as u32;

impl Default for OscilluxBeatGridConfig {
    fn default() -> Self {
        let core = BeatGridConfig::default();
        OscilluxBeatGridConfig {
            struct_size: CONFIG_SIZE,
            sample_rate_hz: core.sample_rate_hz,
            channels: core.channels,
            beats_per_bar: core.beats_per_bar,
            min_bpm: core.min_bpm,
            max_bpm: core.max_bpm,
        }
    }
}

impl OscilluxBeatGridConfig {
    fn core(&self) -> BeatGridConfig {
        BeatGridConfig {
            sample_rate_hz: self.sample_rate_hz,
            channels: self.channels,
            min_bpm: self.min_bpm,
            max_bpm: self.max_bpm,
            beats_per_bar: self.beats_per_bar,
            reserved: 0,
        }
    }
}

/// Summary of a grid, from [`oscillux_beatgrid_info`].
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct OscilluxBeatGridInfo {
    /// Beats in the grid.
    pub beat_count: u64,
    /// Downbeats in the grid.
    pub bar_count: u64,
    /// Global tempo, BPM; 0 for an empty grid.
    pub tempo_bpm: f64,
    /// Periodicity of the onset envelope at the global beat period, 0 ..= 1.
    pub confidence: f64,
    /// Length of the analysed PCM, seconds.
    pub duration_seconds: f64,
    /// Meter used: the hint, or the one chosen from the audio; 0 for an empty grid.
    pub beats_per_bar: u32,
    /// Always 0.
    pub reserved: u32,
}

/// One beat, as [`oscillux_beatgrid_copy_beats`] writes it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct OscilluxBeatGridBeat {
    /// Beat time from the start of the PCM, seconds.
    pub time_seconds: f64,
    /// Local tempo from the neighbouring beat intervals, BPM.
    pub tempo_bpm: f64,
    /// Position in the bar, 0 at the downbeat.
    pub beat_in_bar: u32,
    /// Bar counter: 0 for the first (possibly partial) bar, incremented at every later downbeat.
    pub bar_index: u32,
}

impl From<&GridBeat> for OscilluxBeatGridBeat {
    fn from(beat: &GridBeat) -> Self {
        OscilluxBeatGridBeat {
            time_seconds: beat.time_s,
            tempo_bpm: beat.tempo_bpm,
            beat_in_bar: beat.beat_in_bar,
            bar_index: beat.bar_index,
        }
    }
}

/// Musical position at one media time, from [`oscillux_beatgrid_clock`].
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct OscilluxBeatGridClock {
    /// Progress from the current beat to the next, in `[0, 1)`.
    pub beat_phase: f64,
    /// Progress through the current bar, in `[0, 1)`.
    pub bar_phase: f64,
    /// Local tempo of the current beat, BPM; 0 without a position.
    pub tempo_bpm: f64,
    /// Index of the current beat, extrapolated before the first and after the last; −1 without a
    /// position.
    pub beat_index: i64,
    /// Position of the current beat in its bar, 0 at the downbeat.
    pub beat_in_bar: u32,
    /// Always 0.
    pub reserved: u32,
}

impl From<BeatClock> for OscilluxBeatGridClock {
    fn from(clock: BeatClock) -> Self {
        OscilluxBeatGridClock {
            beat_phase: clock.beat_phase,
            bar_phase: clock.bar_phase,
            tempo_bpm: clock.tempo_bpm,
            beat_index: clock.beat_index,
            beat_in_bar: clock.beat_in_bar,
            reserved: 0,
        }
    }
}

/// Reads `*config` when it is not null and its `struct_size` is the released size; `Err` holds
/// the status to return otherwise.
///
/// # Safety
/// `config` must be null or valid for a read of `struct_size` and, when that matches, of the
/// whole struct.
unsafe fn read_config(
    config: *const OscilluxBeatGridConfig,
) -> Result<OscilluxBeatGridConfig, i32> {
    if config.is_null() {
        return Err(OSCILLUX_ERR_NULL);
    }
    // Only `struct_size` is known to be present until it matches; read it alone.
    if core::ptr::addr_of!((*config).struct_size).read() != CONFIG_SIZE {
        return Err(OSCILLUX_ERR_INVALID_ARGUMENT);
    }
    Ok(config.read())
}

/// Writes the default configuration. `out->struct_size` must already hold the released size.
///
/// # Safety
/// `out` must be null or valid for a read of `struct_size` and, when that matches, one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_beatgrid_config_default(out: *mut OscilluxBeatGridConfig) -> i32 {
    guard(|| {
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        // Only `struct_size` is known to be present until it matches; read it alone.
        if core::ptr::addr_of!((*out).struct_size).read() != CONFIG_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        out.write(OscilluxBeatGridConfig::default());
        OSCILLUX_OK
    })
}

/// Checks `*config` as [`oscillux_beatgrid_create`] does, without allocating. `out_field`, when
/// not null, receives `"struct_size"` or the first offending member name on
/// [`OSCILLUX_ERR_INVALID_ARGUMENT`], and null otherwise.
///
/// # Safety
/// As for [`oscillux_beatgrid_config_default`] for `config`, read only; `out_field` must be null
/// or valid for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_beatgrid_config_validate(
    config: *const OscilluxBeatGridConfig,
    out_field: *mut *const c_char,
) -> i32 {
    guard(|| {
        let (status, field) = match read_config(config) {
            Err(OSCILLUX_ERR_INVALID_ARGUMENT) => {
                (OSCILLUX_ERR_INVALID_ARGUMENT, Some(c"struct_size"))
            }
            Err(status) => (status, None),
            Ok(config) => match config.core().validate() {
                Ok(()) => (OSCILLUX_OK, None),
                Err(error) => (OSCILLUX_ERR_INVALID_ARGUMENT, Some(blamed_field(error))),
            },
        };
        if let Some(out_field) = out_field.as_mut() {
            *out_field = field.map_or(core::ptr::null(), CStr::as_ptr);
        }
        status
    })
}

/// The member a refusal names, spelled as in the header.
fn blamed_field(error: BeatGridError) -> &'static CStr {
    match error {
        BeatGridError::InvalidConfig("sample_rate_hz") => c"sample_rate_hz",
        BeatGridError::InvalidConfig("channels") => c"channels",
        BeatGridError::InvalidConfig("min_bpm") => c"min_bpm",
        BeatGridError::InvalidConfig("max_bpm") => c"max_bpm",
        BeatGridError::InvalidConfig("beats_per_bar") => c"beats_per_bar",
        // `reserved` is always passed as 0, and frames cannot leave a partial one.
        BeatGridError::InvalidConfig(_) | BeatGridError::InvalidLength => c"config",
    }
}

/// Validates `*config`, analyses `sample_frames` frames of interleaved float PCM at `samples`
/// and writes the grid handle to `*out_grid`, null on failure. Allocates and runs the whole
/// analysis; keep it off the frame path. Non-finite samples are read as silence, and audio
/// without a detectable pulse gives an empty grid.
///
/// # Safety
/// As for [`oscillux_beatgrid_config_validate`] for `config`; `samples` must be valid for
/// `sample_frames * channels` reads (null when that is 0); `out_grid` must be null or valid
/// for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_beatgrid_create(
    config: *const OscilluxBeatGridConfig,
    samples: *const f32,
    sample_frames: usize,
    out_grid: *mut *mut OscilluxBeatGrid,
) -> i32 {
    guard(|| {
        let Some(out_grid) = out_grid.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out_grid = core::ptr::null_mut();
        let config = match read_config(config) {
            Ok(config) => config.core(),
            Err(status) => return status,
        };
        if config.validate().is_err() {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let Some(count) = sample_frames.checked_mul(config.channels as usize) else {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        };
        if count > isize::MAX as usize / size_of::<f32>() {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let input: &[f32] = match (count, samples.is_null()) {
            (0, _) => &[],
            (_, true) => return OSCILLUX_ERR_NULL,
            _ => core::slice::from_raw_parts(samples, count),
        };
        match BeatGrid::analyse(&config, input) {
            Ok(grid) => {
                *out_grid = Box::into_raw(Box::new(OscilluxBeatGrid { grid }));
                OSCILLUX_OK
            }
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Frees a grid. Null is ignored.
///
/// # Safety
/// `grid` must be null or a handle from [`oscillux_beatgrid_create`] not yet destroyed.
#[no_mangle]
pub unsafe extern "C" fn oscillux_beatgrid_destroy(grid: *mut OscilluxBeatGrid) {
    guard_void(|| {
        if !grid.is_null() {
            drop(Box::from_raw(grid));
        }
    })
}

/// Writes the number of beats to `*out_count`.
///
/// # Safety
/// `grid` must be null or a live handle; `out_count` must be null or valid for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_beatgrid_beat_count(
    grid: *const OscilluxBeatGrid,
    out_count: *mut usize,
) -> i32 {
    guard(|| match (grid.as_ref(), out_count.as_mut()) {
        (Some(grid), Some(out_count)) => {
            *out_count = grid.grid.beats().len();
            OSCILLUX_OK
        }
        _ => OSCILLUX_ERR_NULL,
    })
}

/// Writes the grid summary to `*out`.
///
/// # Safety
/// `grid` must be null or a live handle; `out` must be null or valid for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_beatgrid_info(
    grid: *const OscilluxBeatGrid,
    out: *mut OscilluxBeatGridInfo,
) -> i32 {
    guard(|| match (grid.as_ref(), out.as_mut()) {
        (Some(grid), Some(out)) => {
            let info = grid.grid.info();
            *out = OscilluxBeatGridInfo {
                beat_count: info.beat_count as u64,
                bar_count: info.bar_count as u64,
                tempo_bpm: info.tempo_bpm,
                confidence: info.confidence,
                duration_seconds: info.duration_s,
                beats_per_bar: info.beats_per_bar,
                reserved: 0,
            };
            OSCILLUX_OK
        }
        _ => OSCILLUX_ERR_NULL,
    })
}

/// Copies beats `first ..` into `out`, at most `capacity` of them, and writes how many to
/// `*out_written`. `first` equal to the beat count copies none; a larger `first` is refused with
/// [`OSCILLUX_ERR_INVALID_ARGUMENT`] and writes 0. Does not allocate.
///
/// # Safety
/// `grid` must be null or a live handle; `out` must be valid for `capacity` writes (null when
/// `capacity` is 0); `out_written` must be null or valid for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_beatgrid_copy_beats(
    grid: *const OscilluxBeatGrid,
    first: usize,
    out: *mut OscilluxBeatGridBeat,
    capacity: usize,
    out_written: *mut usize,
) -> i32 {
    guard(|| {
        let (Some(grid), Some(out_written)) = (grid.as_ref(), out_written.as_mut()) else {
            return OSCILLUX_ERR_NULL;
        };
        *out_written = 0;
        if capacity > isize::MAX as usize / size_of::<OscilluxBeatGridBeat>() {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let output: &mut [OscilluxBeatGridBeat] = match (capacity, out.is_null()) {
            (0, _) => &mut [],
            (_, true) => return OSCILLUX_ERR_NULL,
            _ => core::slice::from_raw_parts_mut(out, capacity),
        };
        let Some(beats) = grid.grid.beats().get(first..) else {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        };
        let written = beats.len().min(capacity);
        for (slot, beat) in output.iter_mut().zip(&beats[..written]) {
            *slot = beat.into();
        }
        *out_written = written;
        OSCILLUX_OK
    })
}

/// Writes the musical position at `media_time_seconds` from the start of the PCM to `*out`. Does
/// not allocate. A grid with fewer than two beats writes the clock without a position
/// (`beat_index` −1, other members 0) and returns OK; a non-finite time writes the same and
/// returns [`OSCILLUX_ERR_INVALID_ARGUMENT`].
///
/// # Safety
/// `grid` must be null or a live handle; `out` must be null or valid for one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_beatgrid_clock(
    grid: *const OscilluxBeatGrid,
    media_time_seconds: f64,
    out: *mut OscilluxBeatGridClock,
) -> i32 {
    guard(|| match (grid.as_ref(), out.as_mut()) {
        (Some(grid), Some(out)) => {
            *out = grid.grid.clock(media_time_seconds).into();
            if media_time_seconds.is_finite() {
                OSCILLUX_OK
            } else {
                OSCILLUX_ERR_INVALID_ARGUMENT
            }
        }
        _ => OSCILLUX_ERR_NULL,
    })
}
