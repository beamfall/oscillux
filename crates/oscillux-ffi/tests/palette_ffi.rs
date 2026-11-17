// SPDX-License-Identifier: AGPL-3.0-only
//! The palette tour through its C entry points: `conformance/palette-tour/vectors.json` within its
//! tolerance, the vivid present defaults, refused and null arguments that leave the output
//! untouched, and invariant 4 (neither export allocates, on success or on refusal).
#[allow(dead_code)]
#[path = "../../oscillux-core/tests/json/mod.rs"]
mod json;
use oscillux::palette::*;
use oscillux::{OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
    ptr::null_mut,
};

/// Counts every allocation made by the armed thread.
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

fn armed<T>(body: impl FnOnce() -> T) -> (T, usize) {
    ALLOCS.with(|n| n.set(0));
    ARMED.with(|a| a.set(true));
    let out = body();
    ARMED.with(|a| a.set(false));
    (out, ALLOCS.with(Cell::get))
}

#[test]
fn tour_matches_the_vectors() {
    let doc = json::parse(include_str!(
        "../../../conformance/palette-tour/vectors.json"
    ))
    .unwrap();
    let tolerance = doc.get("tolerance").num();
    assert_eq!(
        doc.get("tourCount").num(),
        f64::from(OSCILLUX_PALETTE_TOUR_COUNT)
    );
    assert_eq!(
        doc.get("tourSeconds").num(),
        f64::from(OSCILLUX_PALETTE_TOUR_SECONDS)
    );
    let cases = doc.get("cases").arr();
    assert!(cases.len() >= 15);
    for case in cases {
        let (t, offset) = (case.get("timeSeconds").num(), case.get("offset").num());
        let mut out = [9.0; 4];
        let (status, allocs) =
            armed(|| unsafe { oscillux_palette_tour(t, offset, out.as_mut_ptr()) });
        assert_eq!((status, allocs), (OSCILLUX_OK, 0), "{t} {offset}");
        for (g, w) in out.iter().zip(case.get("want").arr()) {
            assert!(
                (g - w.num()).abs() <= tolerance,
                "{t} {offset}: got {out:?}"
            );
        }
        assert!(out[2] >= 0.0 && out[2] < f64::from(OSCILLUX_PALETTE_TOUR_COUNT));
    }

    let mut vivid = [0.0; 2];
    let (status, allocs) = armed(|| unsafe { oscillux_palette_vivid_present(vivid.as_mut_ptr()) });
    assert_eq!((status, allocs), (OSCILLUX_OK, 0));
    let want = doc.get("vividPresent");
    assert_eq!(
        vivid,
        [want.get("saturation").num(), want.get("vibrance").num()]
    );
}

#[test]
fn refusals_leave_the_output_untouched() {
    for (t, offset) in [
        (f64::NAN, 0.0),
        (0.0, f64::NAN),
        (f64::INFINITY, 0.0),
        (0.0, f64::NEG_INFINITY),
    ] {
        let mut out = [9.0; 4];
        let (status, allocs) =
            armed(|| unsafe { oscillux_palette_tour(t, offset, out.as_mut_ptr()) });
        assert_eq!(
            (status, allocs, out),
            (OSCILLUX_ERR_INVALID_ARGUMENT, 0, [9.0; 4])
        );
    }
    let (status, allocs) = armed(|| unsafe { oscillux_palette_tour(1.0, 0.0, null_mut()) });
    assert_eq!((status, allocs), (OSCILLUX_ERR_NULL, 0));
    let (status, allocs) = armed(|| unsafe { oscillux_palette_vivid_present(null_mut()) });
    assert_eq!((status, allocs), (OSCILLUX_ERR_NULL, 0));
}
