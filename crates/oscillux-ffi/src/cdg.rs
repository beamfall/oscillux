// SPDX-License-Identifier: AGPL-3.0-only
//! CD+G lyric graphics: a loaded pack stream decoded to the indexed screen, its colour table,
//! scroll offsets and dirty rectangle, and an RGBA8 window under a host-chosen transparency key.
//! `oscillux_cdg_create` copies the stream and makes every allocation; the other functions do
//! not allocate, lock or do I/O.
use crate::{
    buffers, guard, guard_void, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK,
};
use oscillux_core::cdg::{self, Decoder, Key, Region};

/// Opaque CD+G decoder handle.
pub struct OscilluxCdg {
    inner: Decoder,
}

/// `OSCILLUX_CDG_PACK_SIZE`: bytes per pack.
pub const PACK_SIZE: u32 = cdg::PACK_SIZE as u32;
/// `OSCILLUX_CDG_PACKS_PER_SECOND`: the stream rate.
pub const PACKS_PER_SECOND: u32 = cdg::PACKS_PER_SECOND;
/// `OSCILLUX_CDG_SCREEN_WIDTH`.
pub const SCREEN_WIDTH: u32 = cdg::SCREEN_WIDTH as u32;
/// `OSCILLUX_CDG_SCREEN_HEIGHT`.
pub const SCREEN_HEIGHT: u32 = cdg::SCREEN_HEIGHT as u32;
/// `OSCILLUX_CDG_SCREEN_PIXELS`: the `oscillux_cdg_screen` length.
pub const SCREEN_PIXELS: u32 = cdg::SCREEN_PIXELS as u32;
/// `OSCILLUX_CDG_WINDOW_WIDTH`.
pub const WINDOW_WIDTH: u32 = cdg::WINDOW_WIDTH as u32;
/// `OSCILLUX_CDG_WINDOW_HEIGHT`.
pub const WINDOW_HEIGHT: u32 = cdg::WINDOW_HEIGHT as u32;
/// `OSCILLUX_CDG_WINDOW_RGBA_BYTES`: the `oscillux_cdg_window_rgba` length.
pub const WINDOW_RGBA_BYTES: u32 = cdg::WINDOW_RGBA_BYTES as u32;

/// `OSCILLUX_CDG_KEY_NONE`: every pixel opaque.
pub const KEY_NONE: u32 = 0;
/// `OSCILLUX_CDG_KEY_TRANSPARENT_TABLE`: alpha from the stream's transparent-colour table.
pub const KEY_TRANSPARENT_TABLE: u32 = 1;
/// `OSCILLUX_CDG_KEY_PRESET_COLOUR`: the most recent Memory Preset colour is transparent.
pub const KEY_PRESET_COLOUR: u32 = 2;
/// `OSCILLUX_CDG_KEY_INDEX`: the colour index `key_index` is transparent.
pub const KEY_INDEX: u32 = 3;
/// `OSCILLUX_CDG_KEY_MASK`: every colour index `i` with bit `1 << i` of `key_index` set is
/// transparent.
pub const KEY_MASK: u32 = 4;

/// `OSCILLUX_CDG_REGION_WINDOW`: count the whole visible window.
pub const REGION_WINDOW: u32 = 0;
/// `OSCILLUX_CDG_REGION_EDGE`: count the window's outer ring one tile deep.
pub const REGION_EDGE: u32 = 1;
/// `OSCILLUX_CDG_EDGE_PIXELS`: pixels in `OSCILLUX_CDG_REGION_EDGE`.
pub const EDGE_PIXELS: u32 = cdg::EDGE_PIXELS as u32;
/// `OSCILLUX_CDG_INDEX_COUNT`: entries written by `oscillux_cdg_index_counts`.
pub const INDEX_COUNT: u32 = 16;

/// The decoder state at the current position. `struct_size` must be
/// `sizeof(OscilluxCdgState)` before the call; every other member is written.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct OscilluxCdgState {
    /// `sizeof(OscilluxCdgState)`, set by the caller.
    pub struct_size: u32,
    /// Horizontal scroll offset, 0..=5.
    pub h_offset: u32,
    /// Vertical scroll offset, 0..=11.
    pub v_offset: u32,
    /// Screen x of the window's left edge: `6 + h_offset`.
    pub window_x: u32,
    /// Screen y of the window's top edge: `12 + v_offset`.
    pub window_y: u32,
    /// Most recent Memory Preset colour index.
    pub preset_colour: u32,
    /// Most recent Border Preset colour index.
    pub border_colour: u32,
    /// `OSCILLUX_CDG_CHANGED_*` bits describing the last advance.
    pub changes: u32,
    /// Dirty rectangle `[x0, x1) x [y0, y1)` in screen pixels for the last advance; empty when
    /// `dirty_x0 == dirty_x1`.
    pub dirty_x0: u32,
    /// See `dirty_x0`.
    pub dirty_y0: u32,
    /// See `dirty_x0`.
    pub dirty_x1: u32,
    /// See `dirty_x0`.
    pub dirty_y1: u32,
    /// Colour table as `0xRGB`, 4 bits per channel.
    pub palette: [u32; 16],
    /// Transparent-colour table: the 6-bit value given to each colour index.
    pub transparent: [u32; 16],
    /// Packs decoded at the current position.
    pub applied: u64,
    /// Whole packs in the stream.
    pub pack_count: u64,
}

const STATE_SIZE: u32 = core::mem::size_of::<OscilluxCdgState>() as u32;

/// Copies `len` bytes of packs (a trailing partial pack is ignored) and decodes them once to
/// make the seek checkpoints. `len` may be zero.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_cdg_create(
    packs: *const u8,
    len: usize,
    out: *mut *mut OscilluxCdg,
) -> i32 {
    guard(|| {
        let Some(out) = out.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        *out = core::ptr::null_mut();
        let packs = match buffers::input(packs, len) {
            Ok(packs) => packs,
            Err(code) => return code,
        };
        let inner = Decoder::new(packs);
        *out = Box::into_raw(Box::new(OscilluxCdg { inner }));
        OSCILLUX_OK
    })
}

/// Frees a live handle once; null is ignored.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_cdg_destroy(handle: *mut OscilluxCdg) {
    guard_void(|| {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    })
}

/// Advances or seeks to media time `seconds`: pack `floor(seconds * 300)` and all before it are
/// decoded (none for negative times; clamped to the stream). NaN is refused unchanged.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_cdg_advance_to_time(
    handle: *mut OscilluxCdg,
    seconds: f64,
) -> i32 {
    guard(|| {
        let Some(handle) = handle.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        match handle.inner.advance_to_time(seconds) {
            Ok(()) => OSCILLUX_OK,
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Advances or seeks so the first `applied` packs (clamped to the stream) are decoded.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_cdg_advance_to_pack(
    handle: *mut OscilluxCdg,
    applied: u64,
) -> i32 {
    guard(|| {
        let Some(handle) = handle.as_mut() else {
            return OSCILLUX_ERR_NULL;
        };
        handle.inner.advance_to(applied);
        OSCILLUX_OK
    })
}

/// Writes the state at the current position. `out->struct_size` must already be
/// `sizeof(OscilluxCdgState)`; otherwise nothing is written.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// `out` must be valid for a read of `struct_size` and, when that matches, one write.
#[no_mangle]
pub unsafe extern "C" fn oscillux_cdg_state(
    handle: *const OscilluxCdg,
    out: *mut OscilluxCdgState,
) -> i32 {
    guard(|| {
        let Some(handle) = handle.as_ref() else {
            return OSCILLUX_ERR_NULL;
        };
        if out.is_null() {
            return OSCILLUX_ERR_NULL;
        }
        // Only `struct_size` is known to be present until it matches; read it alone.
        if core::ptr::addr_of!((*out).struct_size).read() != STATE_SIZE {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        let d = &handle.inner;
        let s = d.state();
        let (x, y) = s.window_origin();
        let [x0, y0, x1, y1] = d.dirty().map(u32::from);
        out.write(OscilluxCdgState {
            struct_size: STATE_SIZE,
            h_offset: s.h_offset.into(),
            v_offset: s.v_offset.into(),
            window_x: x as u32,
            window_y: y as u32,
            preset_colour: s.preset.into(),
            border_colour: s.border.into(),
            changes: d.changes(),
            dirty_x0: x0,
            dirty_y0: y0,
            dirty_x1: x1,
            dirty_y1: y1,
            palette: s.palette.map(u32::from),
            transparent: s.transparent.map(u32::from),
            applied: d.applied(),
            pack_count: d.pack_count(),
        });
        OSCILLUX_OK
    })
}

/// Copies the 300 x 216 screen of colour indices, rows top to bottom; `len` must be
/// `OSCILLUX_CDG_SCREEN_PIXELS`. A refusal writes nothing.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_cdg_screen(
    handle: *const OscilluxCdg,
    out: *mut u8,
    len: usize,
) -> i32 {
    guard(|| {
        let Some(handle) = handle.as_ref() else {
            return OSCILLUX_ERR_NULL;
        };
        let out = match buffers::output(out, len) {
            Ok(out) => out,
            Err(code) => return code,
        };
        if out.len() != cdg::SCREEN_PIXELS {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        }
        out.copy_from_slice(&handle.inner.state().screen);
        OSCILLUX_OK
    })
}

/// Writes the visible 288 x 192 window as straight-alpha RGBA8 (each 4-bit channel `c` as
/// `c * 17`); `len` must be `OSCILLUX_CDG_WINDOW_RGBA_BYTES`. `key_mode` is an
/// `OSCILLUX_CDG_KEY_*` value; `key_index` is read only for `OSCILLUX_CDG_KEY_INDEX` (an index,
/// 0..=15) and `OSCILLUX_CDG_KEY_MASK` (a 16-bit mask, 0..=0xFFFF). A refusal writes nothing.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_cdg_window_rgba(
    handle: *const OscilluxCdg,
    key_mode: u32,
    key_index: u32,
    out: *mut u8,
    len: usize,
) -> i32 {
    guard(|| {
        let Some(handle) = handle.as_ref() else {
            return OSCILLUX_ERR_NULL;
        };
        let key = match key_mode {
            KEY_NONE => Key::None,
            KEY_TRANSPARENT_TABLE => Key::TransparentTable,
            KEY_PRESET_COLOUR => Key::PresetColour,
            KEY_INDEX if key_index <= 15 => Key::Index(key_index as u8),
            KEY_MASK if key_index <= 0xFFFF => Key::Mask(key_index as u16),
            _ => return OSCILLUX_ERR_INVALID_ARGUMENT,
        };
        let out = match buffers::output(out, len) {
            Ok(out) => out,
            Err(code) => return code,
        };
        match handle.inner.window_rgba(key, out) {
            Ok(()) => OSCILLUX_OK,
            Err(_) => OSCILLUX_ERR_INVALID_ARGUMENT,
        }
    })
}

/// Writes into `out[i]` how many pixels of the visible window's `region` (an
/// `OSCILLUX_CDG_REGION_*` value) hold colour index `i`; `len` must be
/// `OSCILLUX_CDG_INDEX_COUNT`. A host chooses an automatic key from it (the dominant edge index
/// is usually the background). A refusal writes nothing.
///
/// # Safety
/// Pointers must be null or valid and aligned for the declared objects/buffers.
/// Writable storage and live handles must be exclusive and disjoint from all other arguments.
#[no_mangle]
pub unsafe extern "C" fn oscillux_cdg_index_counts(
    handle: *const OscilluxCdg,
    region: u32,
    out: *mut u32,
    len: usize,
) -> i32 {
    guard(|| {
        let Some(handle) = handle.as_ref() else {
            return OSCILLUX_ERR_NULL;
        };
        let region = match region {
            REGION_WINDOW => Region::Window,
            REGION_EDGE => Region::Edge,
            _ => return OSCILLUX_ERR_INVALID_ARGUMENT,
        };
        let out = match buffers::output(out, len) {
            Ok(out) => out,
            Err(code) => return code,
        };
        let Ok(out) = <&mut [u32; 16]>::try_from(out) else {
            return OSCILLUX_ERR_INVALID_ARGUMENT;
        };
        handle.inner.index_counts(region, out);
        OSCILLUX_OK
    })
}
