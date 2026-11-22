// SPDX-License-Identifier: AGPL-3.0-only
//! Invariant 4 for the CD+G decoder: after `Decoder::new`, advancing per frame, seeking anywhere
//! (forward, backward, through checkpoints), reading the state and writing RGBA never allocate.

use oscillux_core::cdg::present::Presenter;
use oscillux_core::cdg::{Decoder, Key, Region, PACK_SIZE, WINDOW_RGBA_BYTES};
use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
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

#[test]
fn advancing_seeking_and_reading_do_not_allocate() {
    let stream = include_bytes!("../../../conformance/cdg/mixed.cdg");
    // Twenty copies: a 60 000-pack stream with many checkpoints.
    let long: Vec<u8> = stream
        .iter()
        .copied()
        .cycle()
        .take(stream.len() * 20)
        .collect();
    assert_eq!(long.len() % PACK_SIZE, 0);
    let mut d = Decoder::new(&long);
    assert!(d.checkpoint_count() > 2);
    let mut rgba = vec![0u8; WINDOW_RGBA_BYTES];
    let keys = [
        Key::None,
        Key::TransparentTable,
        Key::PresetColour,
        Key::Index(3),
        Key::Index(16),
        Key::Mask(0x8001),
    ];
    let mut counts = [0u32; 16];
    let (checksum, allocs) = armed(|| {
        let mut checksum = 0u64;
        // Per-frame playback at 60 fps for 30 s, then seeks both ways and past the end.
        for frame in 0..1800u32 {
            d.advance_to_time(frame as f64 / 60.0).unwrap();
            checksum += d.dirty()[2] as u64 + d.changes() as u64;
        }
        for target in [59_000u64, 10, 31_337, 31_000, 0, 60_000, u64::MAX, 45_123] {
            d.advance_to(target);
            for key in keys {
                let _ = d.window_rgba(key, &mut rgba);
                checksum += rgba[rgba.len() / 2] as u64;
            }
            checksum += d.state().screen[1000] as u64;
            for region in [Region::Window, Region::Edge] {
                d.index_counts(region, &mut counts);
                checksum += counts[0] as u64;
            }
        }
        let _ = d.advance_to_time(f64::NAN);
        let _ = d.window_rgba(Key::None, &mut rgba[4..]);
        checksum
    });
    assert_eq!(allocs, 0, "allocations after create");
    assert!(checksum > 0);
}

#[test]
fn presenting_does_not_allocate() {
    let stream = include_bytes!("../../../conformance/cdg/karaoke-blue.cdg");
    let mut d = Decoder::new(stream);
    let mut p = Presenter::new(320, 180).unwrap();
    let packs = (stream.len() / PACK_SIZE) as u64;
    let (checksum, allocs) = armed(|| {
        let mut checksum = 0u64;
        for frame in 0..120u64 {
            d.advance_to(frame * packs / 100);
            checksum += p.present(&d, frame as i64 * 33)[1000] as u64;
        }
        d.advance_to(10);
        checksum += p.present(&d, 5)[0] as u64;
        checksum
    });
    assert_eq!(allocs, 0, "allocations after create");
    assert!(checksum > 0);
}
