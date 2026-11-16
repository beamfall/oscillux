// SPDX-License-Identifier: AGPL-3.0-only
//! The overlay C interface (OSC-OVERLAY): refusals, the analyzer overlay through C against the
//! core analyzer, and invariant 4 for the overlay exports (none allocates, on success or on
//! refusal, including `oscillux_flash_analyzer_set_overlay`).

use oscillux::limiter::*;
use oscillux::overlay::*;
use oscillux::{OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use oscillux_core::limiter::{
    FlashAnalyzer, FlashConfig, FlashOverlay, FlashOverlayReport, RegionSample,
};
use oscillux_core::overlay::{pack, OverlayConfig, OVERLAY_UNIFORMS_SIZE};
use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
    ptr::{null, null_mut},
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

const CAPTION: OscilluxOverlayRegion = OscilluxOverlayRegion {
    x: 0.1,
    y: 0.8,
    width: 0.8,
    height: 0.15,
    corner_radius: 0.02,
    feather: 0.01,
    strength: 1.0,
    mode: OSCILLUX_OVERLAY_MODE_LIGHT_TEXT | OSCILLUX_OVERLAY_MODE_DAMP_FLASH,
    reserved: 0,
};

fn grid_config() -> OscilluxFlashConfig {
    OscilluxFlashConfig {
        columns: 6,
        rows: 6,
        ..OscilluxFlashConfig::default()
    }
}

/// The bottom-row cells flicker by 0.07 every frame, under the general 0.1 change.
fn frame(i: usize) -> [RegionSample; 36] {
    let mut s = [RegionSample {
        luminance: 0.3,
        red: 0.0,
    }; 36];
    for cell in &mut s[30..] {
        cell.luminance = if i % 2 == 0 { 0.3 } else { 0.37 };
    }
    s
}

#[test]
fn analyzer_overlay_through_c_matches_core() {
    let mut analyzer: *mut OscilluxFlashAnalyzer = null_mut();
    let config = grid_config();
    unsafe {
        assert_eq!(
            oscillux_flash_analyzer_create(&config, &mut analyzer),
            OSCILLUX_OK
        );
        let mut overlay = OscilluxFlashOverlay {
            struct_size: FLASH_OVERLAY_SIZE,
            ..OscilluxFlashOverlay::default()
        };
        assert_eq!(oscillux_flash_overlay_default(&mut overlay), OSCILLUX_OK);
        assert_eq!(
            oscillux_flash_analyzer_set_overlay(analyzer, &overlay, &CAPTION, 1),
            OSCILLUX_OK
        );
        let mut core = FlashAnalyzer::new(FlashConfig {
            columns: 6,
            rows: 6,
            ..FlashConfig::DEFAULT
        })
        .unwrap();
        core.set_overlay(&FlashOverlay::DEFAULT, &[CAPTION])
            .unwrap();
        let mut report = OscilluxFlashReport::fail_safe(0.0);
        let mut o = OscilluxFlashOverlayReport {
            struct_size: FLASH_OVERLAY_REPORT_SIZE,
            ..OscilluxFlashOverlayReport::from(FlashOverlayReport::default())
        };
        let mut refused = 0;
        let mut transitions = 0;
        for i in 0..90 {
            let t = i as f64 * 1000.0 / 60.0;
            let s = frame(i);
            let ((status, rs), allocs) = armed(|| {
                let a = oscillux_flash_analyzer_admit(analyzer, t, s.as_ptr(), 36, &mut report);
                let b = oscillux_flash_analyzer_overlay_report(analyzer, &mut o);
                (a, b)
            });
            assert_eq!(
                (status, rs, allocs),
                (OSCILLUX_OK, OSCILLUX_OK, 0),
                "frame {i}"
            );
            let want = core.admit(t, &s).unwrap();
            assert_eq!(OscilluxFlashReport::from(want), report, "frame {i}");
            assert_eq!(OscilluxFlashOverlayReport::from(core.overlay_report()), o);
            refused += usize::from(report.admitted == 0);
            transitions += o.transition as usize;
            assert!(o.flashes_in_window <= 1.0, "frame {i}");
        }
        assert_eq!(o.active, 1);
        assert!(o.cells > 0);
        assert!(
            refused > 0 && transitions > 0,
            "the stricter overlay refused frames"
        );
        // Null clears; a refusal keeps the overlay.
        let loose = OscilluxFlashOverlay {
            max_flash_hz: 4.0,
            ..overlay
        };
        let (bad, allocs) =
            armed(|| oscillux_flash_analyzer_set_overlay(analyzer, &loose, &CAPTION, 1));
        assert_eq!((bad, allocs), (OSCILLUX_ERR_INVALID_ARGUMENT, 0));
        let reserved = OscilluxFlashOverlay {
            reserved: 1,
            ..overlay
        };
        let bad = oscillux_flash_analyzer_set_overlay(analyzer, &reserved, &CAPTION, 1);
        assert_eq!(bad, OSCILLUX_ERR_INVALID_ARGUMENT);
        let bad = oscillux_flash_analyzer_set_overlay(analyzer, &overlay, null(), 1);
        assert_eq!(bad, OSCILLUX_ERR_NULL);
        let bad = oscillux_flash_analyzer_set_overlay(analyzer, &overlay, &CAPTION, 9);
        assert_eq!(bad, OSCILLUX_ERR_INVALID_ARGUMENT);
        oscillux_flash_analyzer_measure(analyzer, 2000.0, frame(0).as_ptr(), 36, &mut report);
        oscillux_flash_analyzer_overlay_report(analyzer, &mut o);
        assert_eq!(o.active, 1);
        assert_eq!(
            oscillux_flash_analyzer_set_overlay(analyzer, null(), null(), 0),
            OSCILLUX_OK
        );
        oscillux_flash_analyzer_measure(analyzer, 2020.0, frame(1).as_ptr(), 36, &mut report);
        oscillux_flash_analyzer_overlay_report(analyzer, &mut o);
        assert_eq!(o.active, 0);
        let mut short = OscilluxFlashOverlayReport {
            struct_size: 8,
            ..o
        };
        assert_eq!(
            oscillux_flash_analyzer_overlay_report(analyzer, &mut short),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            oscillux_flash_analyzer_overlay_report(null(), &mut o),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_flash_analyzer_set_overlay(null_mut(), &overlay, &CAPTION, 1),
            OSCILLUX_ERR_NULL
        );
        oscillux_flash_analyzer_destroy(analyzer);
    }
}

#[test]
fn overlay_exports_refuse_and_never_allocate() {
    let config = OscilluxOverlayConfig::default();
    let mut out = [0u8; OVERLAY_UNIFORMS_SIZE];
    let (status, allocs) = armed(|| unsafe {
        oscillux_overlay_pack(&config, &CAPTION, 1, out.as_mut_ptr(), out.len())
    });
    assert_eq!((status, allocs), (OSCILLUX_OK, 0));
    let mut want = [0u8; OVERLAY_UNIFORMS_SIZE];
    pack(&OverlayConfig::DEFAULT, &[CAPTION], &mut want).unwrap();
    assert_eq!(out, want);

    let empty = unsafe { oscillux_overlay_pack(&config, null(), 0, out.as_mut_ptr(), out.len()) };
    assert_eq!(empty, OSCILLUX_OK);
    let refusals: [(OscilluxOverlayConfig, i32); 6] = [
        (
            OscilluxOverlayConfig {
                struct_size: 4,
                ..config
            },
            OSCILLUX_ERR_INVALID_ARGUMENT,
        ),
        (
            OscilluxOverlayConfig {
                reduced_motion: 2,
                ..config
            },
            OSCILLUX_ERR_INVALID_ARGUMENT,
        ),
        (
            OscilluxOverlayConfig {
                premultiplied_alpha: 9,
                ..config
            },
            OSCILLUX_ERR_INVALID_ARGUMENT,
        ),
        (
            OscilluxOverlayConfig {
                contrast_ratio: 22.0,
                ..config
            },
            OSCILLUX_ERR_INVALID_ARGUMENT,
        ),
        (
            OscilluxOverlayConfig {
                viewport_width: f64::NAN,
                ..config
            },
            OSCILLUX_ERR_INVALID_ARGUMENT,
        ),
        (
            OscilluxOverlayConfig {
                output_levels: 1,
                ..config
            },
            OSCILLUX_ERR_INVALID_ARGUMENT,
        ),
    ];
    for (bad, want_status) in refusals {
        let mut sentinel = [0xa5u8; OVERLAY_UNIFORMS_SIZE];
        let (status, allocs) = armed(|| unsafe {
            oscillux_overlay_pack(&bad, &CAPTION, 1, sentinel.as_mut_ptr(), sentinel.len())
        });
        assert_eq!((status, allocs), (want_status, 0), "{bad:?}");
        assert!(sentinel.iter().all(|&b| b == 0xa5));
    }
    let bad_region = OscilluxOverlayRegion {
        mode: OSCILLUX_OVERLAY_MODE_LIGHT_TEXT | OSCILLUX_OVERLAY_MODE_DARK_TEXT,
        ..CAPTION
    };
    unsafe {
        assert_eq!(
            oscillux_overlay_pack(&config, &bad_region, 1, out.as_mut_ptr(), out.len()),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            oscillux_overlay_pack(null(), &CAPTION, 1, out.as_mut_ptr(), out.len()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_overlay_pack(&config, &CAPTION, 1, null_mut(), 320),
            OSCILLUX_ERR_NULL
        );
        let mut d = OscilluxOverlayConfig {
            struct_size: 0,
            ..config
        };
        assert_eq!(
            oscillux_overlay_config_default(&mut d),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            oscillux_overlay_config_default(null_mut()),
            OSCILLUX_ERR_NULL
        );
    }

    // Reduced motion: intensity halves and the flash config tightens, at either released size.
    let reduced = OscilluxOverlayConfig {
        reduced_motion: 1,
        ..config
    };
    let mut intensity = 0.0;
    let (status, allocs) =
        armed(|| unsafe { oscillux_overlay_presentation_intensity(&reduced, &mut intensity) });
    assert_eq!((status, allocs, intensity), (OSCILLUX_OK, 0, 0.5));
    let mut flash = OscilluxFlashConfig::default();
    let (status, allocs) = armed(|| unsafe { oscillux_overlay_flash_config(&reduced, &mut flash) });
    assert_eq!((status, allocs), (OSCILLUX_OK, 0));
    assert_eq!(
        (
            flash.max_flash_hz,
            flash.max_field_area,
            flash.max_red_flashes
        ),
        (1.0, 0.1, 1)
    );
    let mut v1 = OscilluxFlashConfig {
        struct_size: FLASH_CONFIG_SIZE_V1,
        red_rule: 77,
        reserved: 77,
        ..OscilluxFlashConfig::default()
    };
    assert_eq!(
        unsafe { oscillux_overlay_flash_config(&reduced, &mut v1) },
        OSCILLUX_OK
    );
    assert_eq!(
        (v1.max_flash_hz, v1.red_rule, v1.reserved),
        (1.0, 77, 77),
        "v1 tail untouched"
    );
    let mut unchanged = OscilluxFlashConfig::default();
    assert_eq!(
        unsafe { oscillux_overlay_flash_config(&config, &mut unchanged) },
        OSCILLUX_OK
    );
    assert_eq!(unchanged, OscilluxFlashConfig::default());
    let mut invalid = OscilluxFlashConfig {
        max_flash_hz: 9.0,
        ..OscilluxFlashConfig::default()
    };
    let before = invalid;
    assert_eq!(
        unsafe { oscillux_overlay_flash_config(&reduced, &mut invalid) },
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert_eq!(invalid, before);
}
