// SPDX-License-Identifier: AGPL-3.0-only
//! The CD+G C API (OSC-CDG): it mirrors the core decoder, refuses bad arguments without writing,
//! and its per-frame entry points (advance, state, screen, window RGBA) never allocate.

use oscillux::cdg::*;
use oscillux::{OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use oscillux_core::cdg::{self as core_cdg, Decoder, Key, Region};
use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
    mem::size_of,
    ptr::{null, null_mut},
};

/// Counts every allocation, reallocation and zeroed allocation made by the armed thread.
struct Allocator;
thread_local! {
    static ARMED: Cell<bool> = const { Cell::new(false) };
    static ALLOCS: Cell<usize> = const { Cell::new(0) };
}
fn count() {
    if ARMED.with(Cell::get) {
        ALLOCS.with(|n| n.set(n.get() + 1));
    }
}
unsafe impl GlobalAlloc for Allocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        count();
        System.alloc(layout)
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        count();
        System.alloc_zeroed(layout)
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        count();
        System.realloc(ptr, layout, new_size)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }
}
#[global_allocator]
static ALLOCATOR: Allocator = Allocator;

fn armed<R>(f: impl FnOnce() -> R) -> (R, usize) {
    ALLOCS.with(|n| n.set(0));
    ARMED.with(|a| a.set(true));
    let r = f();
    ARMED.with(|a| a.set(false));
    (r, ALLOCS.with(Cell::get))
}

const MIXED: &[u8] = include_bytes!("../../../conformance/cdg/mixed.cdg");
const SCREEN: usize = SCREEN_PIXELS as usize;
const RGBA: usize = WINDOW_RGBA_BYTES as usize;

fn create(packs: &[u8]) -> *mut OscilluxCdg {
    let mut handle = null_mut();
    assert_eq!(
        unsafe { oscillux_cdg_create(packs.as_ptr(), packs.len(), &mut handle) },
        OSCILLUX_OK
    );
    assert!(!handle.is_null());
    handle
}

fn state(handle: *const OscilluxCdg) -> OscilluxCdgState {
    let mut out = OscilluxCdgState {
        struct_size: size_of::<OscilluxCdgState>() as u32,
        ..Default::default()
    };
    assert_eq!(unsafe { oscillux_cdg_state(handle, &mut out) }, OSCILLUX_OK);
    out
}

#[test]
fn the_c_api_mirrors_the_core_decoder() {
    let handle = create(MIXED);
    let mut core = Decoder::new(MIXED);
    let mut screen = vec![0u8; SCREEN];
    let (mut a, mut b) = (vec![0u8; RGBA], vec![0u8; RGBA]);
    // Forward, backward and through checkpoints, by pack and by time.
    for target in [0u64, 1, 17, 1500, 3000, 400, 2999, u64::MAX] {
        assert_eq!(
            unsafe { oscillux_cdg_advance_to_pack(handle, target) },
            OSCILLUX_OK
        );
        core.advance_to(target);
        let s = state(handle);
        let c = core.state();
        assert_eq!(s.applied, core.applied());
        assert_eq!(s.pack_count, 3000);
        assert_eq!(
            (s.h_offset, s.v_offset),
            (c.h_offset.into(), c.v_offset.into())
        );
        assert_eq!((s.window_x, s.window_y), (6 + s.h_offset, 12 + s.v_offset));
        assert_eq!(s.preset_colour, u32::from(c.preset));
        assert_eq!(s.border_colour, u32::from(c.border));
        assert_eq!(s.changes, core.changes());
        assert_eq!(
            [s.dirty_x0, s.dirty_y0, s.dirty_x1, s.dirty_y1],
            core.dirty().map(u32::from)
        );
        assert_eq!(s.palette, c.palette.map(u32::from));
        assert_eq!(s.transparent, c.transparent.map(u32::from));
        assert_eq!(
            unsafe { oscillux_cdg_screen(handle, screen.as_mut_ptr(), SCREEN) },
            OSCILLUX_OK
        );
        assert_eq!(&screen[..], &c.screen[..]);
        for (mode, index, key) in [
            (KEY_NONE, 99, Key::None),
            (KEY_TRANSPARENT_TABLE, 0, Key::TransparentTable),
            (KEY_PRESET_COLOUR, 0, Key::PresetColour),
            (KEY_INDEX, 7, Key::Index(7)),
            (KEY_MASK, 0x8081, Key::Mask(0x8081)),
            (KEY_MASK, 0xFFFF, Key::Mask(0xFFFF)),
        ] {
            let status =
                unsafe { oscillux_cdg_window_rgba(handle, mode, index, a.as_mut_ptr(), RGBA) };
            assert_eq!(status, OSCILLUX_OK);
            core.window_rgba(key, &mut b).unwrap();
            assert_eq!(a, b, "key mode {mode}");
        }
        for (code, region, total) in [
            (REGION_WINDOW, Region::Window, WINDOW_WIDTH * WINDOW_HEIGHT),
            (REGION_EDGE, Region::Edge, EDGE_PIXELS),
        ] {
            let mut counts = [0u32; 16];
            let mut want = [0u32; 16];
            let status =
                unsafe { oscillux_cdg_index_counts(handle, code, counts.as_mut_ptr(), 16) };
            assert_eq!(status, OSCILLUX_OK);
            core.index_counts(region, &mut want);
            assert_eq!(counts, want, "region {code}");
            assert_eq!(counts.iter().sum::<u32>(), total);
        }
    }
    // Media time: pack floor(t * 300) is the last one applied.
    for (seconds, applied) in [(-1.0, 0u64), (0.0, 1), (1.0, 301), (5.0, 1501), (1e9, 3000)] {
        assert_eq!(
            unsafe { oscillux_cdg_advance_to_time(handle, seconds) },
            OSCILLUX_OK
        );
        assert_eq!(state(handle).applied, applied, "t = {seconds}");
    }
    unsafe { oscillux_cdg_destroy(handle) };
}

#[test]
fn bad_arguments_are_refused_without_writing() {
    unsafe {
        let mut handle = std::ptr::dangling_mut::<OscilluxCdg>();
        assert_eq!(
            oscillux_cdg_create(null(), 24, &mut handle),
            OSCILLUX_ERR_NULL
        );
        assert!(handle.is_null(), "create nulls *out first");
        assert_eq!(
            oscillux_cdg_create(null(), 0, null_mut()),
            OSCILLUX_ERR_NULL
        );
        // An empty stream and a trailing partial pack are accepted.
        assert_eq!(oscillux_cdg_create(null(), 0, &mut handle), OSCILLUX_OK);
        assert_eq!(state(handle).pack_count, 0);
        oscillux_cdg_destroy(handle);
        let handle = create(&MIXED[..24 * 10 + 5]);
        assert_eq!(state(handle).pack_count, 10);
        oscillux_cdg_destroy(null_mut());

        let mut s = OscilluxCdgState::default();
        assert_eq!(
            oscillux_cdg_advance_to_time(null_mut(), 0.0),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_cdg_advance_to_pack(null_mut(), 0),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(oscillux_cdg_state(null(), &mut s), OSCILLUX_ERR_NULL);
        assert_eq!(oscillux_cdg_state(handle, null_mut()), OSCILLUX_ERR_NULL);
        assert_eq!(
            oscillux_cdg_screen(null(), null_mut(), 0),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_cdg_window_rgba(null(), KEY_NONE, 0, null_mut(), 0),
            OSCILLUX_ERR_NULL
        );

        oscillux_cdg_advance_to_pack(handle, 5);
        assert_eq!(
            oscillux_cdg_advance_to_time(handle, f64::NAN),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(state(handle).applied, 5, "NaN changes nothing");

        // A struct_size other than the released size writes nothing.
        for size in [0, size_of::<OscilluxCdgState>() as u32 - 8, u32::MAX] {
            s = OscilluxCdgState {
                struct_size: size,
                applied: 77,
                ..Default::default()
            };
            assert_eq!(
                oscillux_cdg_state(handle, &mut s),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!((s.struct_size, s.applied), (size, 77));
        }

        let mut screen = vec![0xAAu8; SCREEN + 1];
        for len in [0, SCREEN - 1, SCREEN + 1] {
            assert_eq!(
                oscillux_cdg_screen(handle, screen.as_mut_ptr(), len),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
        }
        assert_eq!(
            oscillux_cdg_screen(handle, null_mut(), SCREEN),
            OSCILLUX_ERR_NULL
        );
        assert!(screen.iter().all(|&b| b == 0xAA));

        let mut rgba = vec![0xAAu8; RGBA + 4];
        for (mode, index, len) in [
            (KEY_NONE, 0, RGBA - 4),
            (KEY_NONE, 0, RGBA + 4),
            (KEY_INDEX, 16, RGBA),
            (KEY_INDEX, u32::MAX, RGBA),
            (KEY_MASK, 0x1_0000, RGBA),
            (KEY_MASK, u32::MAX, RGBA),
            (5, 0, RGBA),
            (u32::MAX, 0, RGBA),
        ] {
            assert_eq!(
                oscillux_cdg_window_rgba(handle, mode, index, rgba.as_mut_ptr(), len),
                OSCILLUX_ERR_INVALID_ARGUMENT,
                "mode {mode} index {index} len {len}"
            );
        }
        assert_eq!(
            oscillux_cdg_window_rgba(handle, KEY_NONE, 0, null_mut(), RGBA),
            OSCILLUX_ERR_NULL
        );
        assert!(rgba.iter().all(|&b| b == 0xAA));

        let mut counts = [0xAAAA_AAAAu32; 17];
        assert_eq!(
            oscillux_cdg_index_counts(null(), REGION_EDGE, counts.as_mut_ptr(), 16),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_cdg_index_counts(handle, REGION_EDGE, null_mut(), 16),
            OSCILLUX_ERR_NULL
        );
        for (region, len) in [
            (REGION_EDGE, 0),
            (REGION_EDGE, 15),
            (REGION_WINDOW, 17),
            (2, 16),
        ] {
            assert_eq!(
                oscillux_cdg_index_counts(handle, region, counts.as_mut_ptr(), len),
                OSCILLUX_ERR_INVALID_ARGUMENT,
                "region {region} len {len}"
            );
        }
        assert!(counts.iter().all(|&n| n == 0xAAAA_AAAA));
        oscillux_cdg_destroy(handle);
    }
    assert_eq!(SCREEN, core_cdg::SCREEN_PIXELS);
    assert_eq!(EDGE_PIXELS as usize, core_cdg::EDGE_PIXELS);
    assert_eq!(RGBA, core_cdg::WINDOW_RGBA_BYTES);
}

#[test]
fn per_frame_entry_points_do_not_allocate() {
    let long: Vec<u8> = MIXED
        .iter()
        .copied()
        .cycle()
        .take(MIXED.len() * 20)
        .collect();
    let handle = create(&long);
    let mut screen = vec![0u8; SCREEN];
    let mut rgba = vec![0u8; RGBA];
    let mut s = OscilluxCdgState {
        struct_size: size_of::<OscilluxCdgState>() as u32,
        ..Default::default()
    };
    let (checksum, allocs) = armed(|| unsafe {
        let mut checksum = 0u64;
        for frame in 0..1800u32 {
            oscillux_cdg_advance_to_time(handle, frame as f64 / 60.0);
            oscillux_cdg_state(handle, &mut s);
            checksum += u64::from(s.changes) + s.applied;
        }
        for target in [59_000u64, 10, 31_337, 0, u64::MAX] {
            oscillux_cdg_advance_to_pack(handle, target);
            oscillux_cdg_screen(handle, screen.as_mut_ptr(), SCREEN);
            for mode in [
                KEY_NONE,
                KEY_TRANSPARENT_TABLE,
                KEY_PRESET_COLOUR,
                KEY_INDEX,
                KEY_MASK,
                9,
            ] {
                oscillux_cdg_window_rgba(handle, mode, 3, rgba.as_mut_ptr(), RGBA);
                checksum += u64::from(rgba[RGBA / 2]);
            }
            let mut counts = [0u32; 16];
            for region in [REGION_WINDOW, REGION_EDGE, 7] {
                oscillux_cdg_index_counts(handle, region, counts.as_mut_ptr(), 16);
                checksum += u64::from(counts[0]);
            }
            checksum += u64::from(screen[SCREEN / 3]);
        }
        oscillux_cdg_advance_to_time(handle, f64::NAN);
        oscillux_cdg_screen(handle, screen.as_mut_ptr(), 3);
        oscillux_cdg_window_rgba(handle, KEY_INDEX, 99, rgba.as_mut_ptr(), RGBA);
        checksum
    });
    assert_eq!(allocs, 0, "allocations on the per-frame path");
    assert!(checksum > 0);
    unsafe { oscillux_cdg_destroy(handle) };
}
