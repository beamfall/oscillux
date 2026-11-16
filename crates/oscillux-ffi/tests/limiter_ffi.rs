// SPDX-License-Identifier: AGPL-3.0-only
//! C ABI lifecycle, validation and allocation contract.

use oscillux::limiter::*;
use oscillux::{OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use oscillux_core::limiter::{Frame, Limiter, Policy};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::ptr::{null, null_mut};

struct CountingAlloc;
thread_local! {
    static ARMED: Cell<bool> = const { Cell::new(false) };
    static COUNT: Cell<usize> = const { Cell::new(0) };
}
unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if ARMED.with(Cell::get) {
            COUNT.with(|n| n.set(n.get() + 1));
        }
        System.alloc(layout)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }
}
#[global_allocator]
static GLOBAL: CountingAlloc = CountingAlloc;

struct Handle(*mut OscilluxLimiter);
impl Handle {
    fn new(policy: &OscilluxLimiterPolicy) -> Self {
        let mut handle = null_mut();
        assert_eq!(
            unsafe { oscillux_limiter_create(policy, &mut handle) },
            OSCILLUX_OK
        );
        Self(handle)
    }
}
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { oscillux_limiter_destroy(self.0) }
    }
}
fn frame(time_ms: f64) -> Frame {
    Frame {
        time_ms,
        broadband: 1.0,
        low: 0.9,
        mid: 0.9,
        high: 0.9,
        red: 1.0,
        area: 1.0,
    }
}

#[test]
fn process_matches_core_in_place_and_reset_is_allocation_free() {
    let mut policy = OscilluxLimiterPolicy::default();
    assert_eq!(
        unsafe { oscillux_limiter_policy_default(&mut policy) },
        OSCILLUX_OK
    );
    let handle = Handle::new(&policy);
    let mut core = Limiter::new(Policy::DEFAULT).unwrap();
    COUNT.with(|n| n.set(0));
    ARMED.with(|n| n.set(true));
    for i in 0..2000 {
        let mut input = frame(i as f64 * 17.0);
        let expected = core.process(input).unwrap();
        let ptr = &mut input as *mut Frame;
        assert_eq!(
            unsafe { oscillux_limiter_process(handle.0, ptr, ptr) },
            OSCILLUX_OK
        );
        assert_eq!(input, expected);
    }
    assert_eq!(unsafe { oscillux_limiter_reset(handle.0) }, OSCILLUX_OK);
    core.reset();
    let input = frame(0.0);
    let mut output = Frame::default();
    assert_eq!(
        unsafe { oscillux_limiter_process(handle.0, &input, &mut output) },
        OSCILLUX_OK
    );
    ARMED.with(|n| n.set(false));
    assert_eq!(COUNT.with(Cell::get), 0);
    assert_eq!(output, core.process(input).unwrap());
}

#[test]
fn invalid_policies_and_null_arguments_are_refused() {
    for flag in [0, 2, u32::MAX] {
        let policy = OscilluxLimiterPolicy {
            strobe_banned: flag,
            ..Default::default()
        };
        let mut handle = null_mut();
        assert_eq!(
            unsafe { oscillux_limiter_create(&policy, &mut handle) },
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert!(handle.is_null());
    }
    let defaults = OscilluxLimiterPolicy::default();
    for policy in [
        OscilluxLimiterPolicy {
            max_flash_hz: 3.1,
            ..defaults
        },
        OscilluxLimiterPolicy {
            max_luminance_delta: 0.81,
            ..defaults
        },
        OscilluxLimiterPolicy {
            max_flash_area: 0.26,
            ..defaults
        },
        OscilluxLimiterPolicy {
            max_red_flashes: 4,
            ..defaults
        },
        OscilluxLimiterPolicy {
            max_flash_hz: f64::INFINITY,
            ..defaults
        },
        OscilluxLimiterPolicy {
            max_luminance_delta: f64::NAN,
            ..defaults
        },
    ] {
        let mut handle = null_mut();
        assert_eq!(
            unsafe { oscillux_limiter_create(&policy, &mut handle) },
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert!(handle.is_null());
    }
    assert_eq!(
        unsafe { oscillux_limiter_policy_default(null_mut()) },
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        unsafe { oscillux_limiter_reset(null_mut()) },
        OSCILLUX_ERR_NULL
    );
    let mut handle = null_mut();
    assert_eq!(
        unsafe { oscillux_limiter_create(null(), &mut handle) },
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        unsafe { oscillux_limiter_create(&defaults, null_mut()) },
        OSCILLUX_ERR_NULL
    );
    unsafe { oscillux_limiter_destroy(null_mut()) };
}

#[test]
fn rejected_frames_write_the_fail_safe_frame_and_preserve_history() {
    let handle = Handle::new(&OscilluxLimiterPolicy::default());
    let mut output = Frame::default();
    for time in [0.0, 250.0] {
        assert_eq!(
            unsafe { oscillux_limiter_process(handle.0, &frame(time), &mut output) },
            OSCILLUX_OK
        );
    }
    for invalid in [
        frame(249.0),
        frame(f64::NAN),
        Frame {
            red: 2.0,
            ..frame(5000.0)
        },
    ] {
        assert_eq!(
            unsafe { oscillux_limiter_process(handle.0, &invalid, &mut output) },
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(output.time_ms.to_bits(), invalid.time_ms.to_bits());
        assert_eq!(
            Frame {
                time_ms: 0.0,
                ..output
            },
            Frame::fail_safe(0.0)
        );
    }
    // In place, the refusal overwrites its own input.
    let mut input = frame(100.0);
    let ptr = &mut input as *mut Frame;
    assert_eq!(
        unsafe { oscillux_limiter_process(handle.0, ptr, ptr) },
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert_eq!(input, Frame::fail_safe(100.0));
    assert_eq!(
        unsafe { oscillux_limiter_process(handle.0, null(), &mut output) },
        OSCILLUX_ERR_NULL
    );
    assert!(output.time_ms.is_nan());
    assert_eq!(
        Frame {
            time_ms: 0.0,
            ..output
        },
        Frame::fail_safe(0.0)
    );
    assert_eq!(
        unsafe { oscillux_limiter_process(handle.0, &frame(5000.0), null_mut()) },
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        unsafe { oscillux_limiter_process(null_mut(), &frame(500.0), &mut output) },
        OSCILLUX_ERR_NULL
    );
    assert_eq!(output, Frame::fail_safe(500.0));
    assert_eq!(
        unsafe { oscillux_limiter_process(handle.0, &frame(500.0), &mut output) },
        OSCILLUX_OK
    );
    assert_eq!(output.broadband, 0.4);
}

#[test]
fn zero_red_budget_is_available_through_c() {
    let policy = OscilluxLimiterPolicy {
        max_red_flashes: 0,
        ..Default::default()
    };
    let handle = Handle::new(&policy);
    let mut output = Frame::default();
    assert_eq!(
        unsafe { oscillux_limiter_process(handle.0, &frame(0.0), &mut output) },
        OSCILLUX_OK
    );
    assert!(output.red < 0.8);
}

// ---- Region flash analyzer -----------------------------------------------------------------

struct Analyzer(*mut OscilluxFlashAnalyzer);
impl Analyzer {
    fn new(config: &OscilluxFlashConfig) -> Self {
        let mut handle = null_mut();
        assert_eq!(
            unsafe { oscillux_flash_analyzer_create(config, &mut handle) },
            OSCILLUX_OK
        );
        Self(handle)
    }
}
impl Drop for Analyzer {
    fn drop(&mut self) {
        unsafe { oscillux_flash_analyzer_destroy(self.0) }
    }
}

fn grid(columns: u32, rows: u32) -> OscilluxFlashConfig {
    OscilluxFlashConfig {
        columns,
        rows,
        ..OscilluxFlashConfig::default()
    }
}

fn uniform(luminance: f64) -> [OscilluxFlashRegion; 36] {
    [OscilluxFlashRegion {
        luminance,
        red: 0.0,
    }; 36]
}

/// A report that differs from every value the analyzer writes.
const GARBAGE: OscilluxFlashReport = OscilluxFlashReport {
    time_ms: -7.0,
    flashes_in_window: -7.0,
    red_flashes_in_window: -7.0,
    admitted: 7,
    general_transition: 7,
    red_transition: 7,
    general_regions: 7,
    red_regions: 7,
    exceeds: 7,
};

#[test]
fn flash_config_default_requires_a_released_struct_size() {
    assert_eq!((FLASH_CONFIG_SIZE_V1, FLASH_CONFIG_SIZE), (48, 56));
    let mut config = OscilluxFlashConfig {
        struct_size: 0,
        red_rule: 0xAA,
        reserved: 0xBB,
        ..OscilluxFlashConfig::default()
    };
    // The documented defaults, written out by hand.
    let defaults = OscilluxFlashConfig {
        struct_size: 56,
        columns: 16,
        rows: 16,
        max_red_flashes: 3,
        field_width: 1.0 / 3.0,
        field_height: 1.0 / 3.0,
        max_field_area: 0.25,
        max_flash_hz: 3.0,
        red_rule: OSCILLUX_FLASH_RED_RULE_WCAG20,
        reserved: 0,
    };
    unsafe {
        assert_eq!(oscillux_flash_config_default(null_mut()), OSCILLUX_ERR_NULL);
        for size in [0, 40, 52, 64] {
            config.struct_size = size;
            let before = config;
            assert_eq!(
                oscillux_flash_config_default(&mut config),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(config, before);
        }
        // The first released size writes only its 48 bytes.
        config.struct_size = 48;
        assert_eq!(oscillux_flash_config_default(&mut config), OSCILLUX_OK);
        assert_eq!(
            config,
            OscilluxFlashConfig {
                struct_size: 48,
                red_rule: 0xAA,
                reserved: 0xBB,
                ..defaults
            }
        );
        config.struct_size = 56;
        assert_eq!(oscillux_flash_config_default(&mut config), OSCILLUX_OK);
    }
    assert_eq!(config, defaults);
}

#[test]
fn a_first_size_config_ignores_trailing_bytes_and_applies_wcag20() {
    let config = OscilluxFlashConfig {
        struct_size: 48,
        red_rule: 99,
        reserved: 5,
        ..grid(6, 6)
    };
    let analyzer = Analyzer::new(&config);
    let iso = Analyzer::new(&OscilluxFlashConfig {
        red_rule: OSCILLUX_FLASH_RED_RULE_ISO_9241_391,
        ..grid(6, 6)
    });
    // Saturated red 0.5 against 0.25: a WCAG 2.0 red change, the same ISO chromaticity.
    let red = |r| [OscilluxFlashColor { r, g: 0.0, b: 0.0 }; 36];
    let mut report = GARBAGE;
    unsafe {
        for (i, level) in [0.5, 0.25].into_iter().enumerate() {
            let time = i as f64 * 100.0;
            for handle in [analyzer.0, iso.0] {
                assert_eq!(
                    oscillux_flash_analyzer_measure_rgb(
                        handle,
                        time,
                        red(level).as_ptr(),
                        36,
                        &mut report
                    ),
                    OSCILLUX_OK
                );
                assert_eq!(
                    report.red_transition,
                    u32::from(i == 1 && handle == analyzer.0)
                );
            }
        }
        // The sample path stays open under WCAG 2.0 and is refused under ISO 9241-391.
        assert_eq!(
            oscillux_flash_analyzer_measure(
                analyzer.0,
                200.0,
                uniform(0.0).as_ptr(),
                36,
                &mut report
            ),
            OSCILLUX_OK
        );
        report = GARBAGE;
        assert_eq!(
            oscillux_flash_analyzer_admit(iso.0, 200.0, uniform(0.0).as_ptr(), 36, &mut report),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            report,
            OscilluxFlashReport {
                time_ms: 200.0,
                ..OscilluxFlashReport::default()
            }
        );
        assert_eq!(
            oscillux_flash_analyzer_admit_rgb(iso.0, 200.0, null(), 36, &mut report),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_flash_analyzer_measure_rgb(iso.0, 200.0, red(1.5).as_ptr(), 36, &mut report),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
    }
}

#[test]
fn invalid_flash_configs_and_null_arguments_are_refused() {
    let valid = OscilluxFlashConfig::default();
    let invalid = [
        OscilluxFlashConfig {
            struct_size: 40,
            ..valid
        },
        OscilluxFlashConfig {
            struct_size: 52,
            ..valid
        },
        OscilluxFlashConfig {
            struct_size: 64,
            ..valid
        },
        OscilluxFlashConfig {
            red_rule: 2,
            ..valid
        },
        OscilluxFlashConfig {
            reserved: 1,
            ..valid
        },
        OscilluxFlashConfig {
            columns: 0,
            ..valid
        },
        OscilluxFlashConfig { rows: 17, ..valid },
        OscilluxFlashConfig {
            field_width: 0.0,
            ..valid
        },
        OscilluxFlashConfig {
            field_height: f64::NAN,
            ..valid
        },
        OscilluxFlashConfig {
            max_field_area: 0.26,
            ..valid
        },
        OscilluxFlashConfig {
            max_flash_hz: 3.5,
            ..valid
        },
        OscilluxFlashConfig {
            max_red_flashes: 4,
            ..valid
        },
    ];
    unsafe {
        for config in invalid {
            let mut handle = std::ptr::dangling_mut::<OscilluxFlashAnalyzer>();
            assert_eq!(
                oscillux_flash_analyzer_create(&config, &mut handle),
                OSCILLUX_ERR_INVALID_ARGUMENT,
                "{config:?}"
            );
            assert!(handle.is_null());
        }
        let mut handle = std::ptr::dangling_mut::<OscilluxFlashAnalyzer>();
        assert_eq!(
            oscillux_flash_analyzer_create(null(), &mut handle),
            OSCILLUX_ERR_NULL
        );
        assert!(handle.is_null());
        assert_eq!(
            oscillux_flash_analyzer_create(&valid, null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(oscillux_flash_analyzer_reset(null_mut()), OSCILLUX_ERR_NULL);
        oscillux_flash_analyzer_destroy(null_mut());
    }
}

#[test]
fn rejected_flash_frames_write_the_fail_safe_report_and_preserve_state() {
    let config = grid(6, 6);
    let analyzer = Analyzer::new(&config);
    let dark = uniform(0.0);
    let bright = uniform(0.5);
    let out_of_range = uniform(1.5);
    let mut report = GARBAGE;
    let fail_safe = |time_ms| OscilluxFlashReport {
        time_ms,
        ..OscilluxFlashReport::default()
    };
    unsafe {
        assert_eq!(
            oscillux_flash_analyzer_measure(analyzer.0, 0.0, dark.as_ptr(), 36, &mut report),
            OSCILLUX_OK
        );
        // A garbage count is refused before any slice is formed from it.
        let refused: [(f64, *const OscilluxFlashRegion, usize, i32); 7] = [
            (10.0, null(), 36, OSCILLUX_ERR_NULL),
            (10.0, bright.as_ptr(), 35, OSCILLUX_ERR_INVALID_ARGUMENT),
            (10.0, bright.as_ptr(), 37, OSCILLUX_ERR_INVALID_ARGUMENT),
            (
                10.0,
                bright.as_ptr(),
                usize::MAX,
                OSCILLUX_ERR_INVALID_ARGUMENT,
            ),
            (
                f64::INFINITY,
                bright.as_ptr(),
                36,
                OSCILLUX_ERR_INVALID_ARGUMENT,
            ),
            (-1.0, bright.as_ptr(), 36, OSCILLUX_ERR_INVALID_ARGUMENT),
            (
                10.0,
                out_of_range.as_ptr(),
                36,
                OSCILLUX_ERR_INVALID_ARGUMENT,
            ),
        ];
        for (time, regions, count, status) in refused {
            for call in [
                oscillux_flash_analyzer_measure,
                oscillux_flash_analyzer_admit,
            ] {
                report = GARBAGE;
                assert_eq!(call(analyzer.0, time, regions, count, &mut report), status);
                assert_eq!(report.to_bits(), fail_safe(time).to_bits());
                assert_eq!(
                    call(analyzer.0, time, regions, count, null_mut()),
                    OSCILLUX_ERR_NULL
                );
            }
        }
        report = GARBAGE;
        assert_eq!(
            oscillux_flash_analyzer_admit(null_mut(), 3.0, bright.as_ptr(), 36, &mut report),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(report, fail_safe(3.0));
        // State is unchanged: the bright frame still rises from the dark baseline at time 0.
        assert_eq!(
            oscillux_flash_analyzer_measure(analyzer.0, 0.0, bright.as_ptr(), 36, &mut report),
            OSCILLUX_OK
        );
        assert_eq!(report.general_transition, 1);
        assert_eq!(report.general_regions, 36);
    }
}

trait Bits {
    fn to_bits(&self) -> [u64; 9];
}
impl Bits for OscilluxFlashReport {
    fn to_bits(&self) -> [u64; 9] {
        [
            self.time_ms.to_bits(),
            self.flashes_in_window.to_bits(),
            self.red_flashes_in_window.to_bits(),
            self.admitted.into(),
            self.general_transition.into(),
            self.red_transition.into(),
            self.general_regions.into(),
            self.red_regions.into(),
            self.exceeds.into(),
        ]
    }
}

/// The full-screen 0.15 change at 10 Hz from conformance/limiter/README.md, on a 6 x 6 grid with
/// one frame per change (t = 50k, 0.15 when k is odd). Expected values are the README's hand
/// derivation, not analyzer output.
#[test]
fn full_screen_ten_hertz_through_c_matches_the_hand_derivation() {
    let config = grid(6, 6);
    let measure = Analyzer::new(&config);
    let admit = Analyzer::new(&config);
    let admitted_transitions = [
        50, 100, 150, 200, 250, 300, 1050, 1100, 1150, 1200, 1250, 1300,
    ];
    let (mut shown, mut admitted) = (0.0, Vec::with_capacity(40));
    let mut report = OscilluxFlashReport::default();
    ARMED.with(|v| v.set(true));
    for k in 0..=39u32 {
        let time = f64::from(50 * k);
        let regions = uniform(if k % 2 == 1 { 0.15 } else { 0.0 });
        unsafe {
            assert_eq!(
                oscillux_flash_analyzer_measure(measure.0, time, regions.as_ptr(), 36, &mut report),
                OSCILLUX_OK
            );
            // Transitions at 50 .. 50k; at most 20 are younger than 1000 ms.
            let held = f64::from(k.min(20));
            assert_eq!(report.general_transition, u32::from(k > 0), "k {k}");
            assert_eq!(report.general_regions, if k > 0 { 36 } else { 0 });
            assert_eq!(report.flashes_in_window, held / 2.0, "k {k}");
            assert_eq!(report.exceeds, u32::from(k >= 7), "k {k}");

            assert_eq!(
                oscillux_flash_analyzer_admit(admit.0, time, regions.as_ptr(), 36, &mut report),
                OSCILLUX_OK
            );
            assert_eq!(report.exceeds, 0, "k {k}");
            assert!(report.flashes_in_window <= 3.0);
            if report.admitted == 1 {
                if report.general_transition == 1 {
                    admitted.push(50 * k);
                }
                shown = regions[0].luminance;
            } else {
                // Refused frames are 0.15 frames over a held 0 image.
                assert_eq!((regions[0].luminance, shown), (0.15, 0.0), "k {k}");
            }
        }
    }
    ARMED.with(|v| v.set(false));
    assert_eq!(admitted, admitted_transitions);
    assert_eq!(COUNT.with(Cell::get), 0, "a per-frame flash call allocated");
}

/// Fixed-seed xorshift for reproducible inputs.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn level(&mut self) -> f64 {
        (self.next() % 9) as f64 / 8.0
    }
}

/// The C wrappers add nothing to the core analyzer, which the conformance vectors pin.
#[test]
fn c_reports_mirror_the_core_analyzer_field_for_field() {
    use oscillux_core::limiter::{FlashAnalyzer, FlashConfig};
    let config = OscilluxFlashConfig {
        max_red_flashes: 1,
        max_flash_hz: 2.0,
        ..grid(4, 3)
    };
    let c = Analyzer::new(&config);
    let mut core = FlashAnalyzer::new(FlashConfig {
        columns: 4,
        rows: 3,
        max_red_flashes: 1,
        max_flash_hz: 2.0,
        ..FlashConfig::DEFAULT
    })
    .unwrap();
    let mut rng = Rng(0x2545_f491_4f6c_dd1d);
    let mut regions = [OscilluxFlashRegion::default(); 12];
    let mut seen = [0u32; 3];
    for i in 0..2000u32 {
        for region in &mut regions {
            region.luminance = rng.level();
            region.red = if rng.next() % 2 == 0 {
                rng.level()
            } else {
                0.0
            };
        }
        if i % 97 == 96 {
            unsafe { assert_eq!(oscillux_flash_analyzer_reset(c.0), OSCILLUX_OK) };
            core.reset();
        }
        let time = f64::from(i) * 25.25;
        let admit = i % 2 == 0;
        let mut report = GARBAGE;
        let call = if admit {
            oscillux_flash_analyzer_admit
        } else {
            oscillux_flash_analyzer_measure
        };
        let want = if admit {
            core.admit(time, &regions)
        } else {
            core.measure(time, &regions)
        }
        .unwrap();
        assert_eq!(
            unsafe { call(c.0, time, regions.as_ptr(), 12, &mut report) },
            OSCILLUX_OK
        );
        assert_eq!(report, OscilluxFlashReport::from(want), "frame {i}");
        seen[0] += u32::from(want.red_transition);
        seen[1] += u32::from(!want.admitted);
        seen[2] += u32::from(want.exceeds);
    }
    assert!(seen.iter().all(|&n| n > 10), "{seen:?}");
}

#[test]
fn region_from_linear_rgb_matches_the_documented_formula() {
    let mut out = OscilluxFlashRegion::default();
    unsafe {
        assert_eq!(
            oscillux_flash_region_from_linear_rgb(1.0, 0.0, 0.0, &mut out),
            OSCILLUX_OK
        );
        assert_eq!((out.luminance, out.red), (0.2126, 1.0));
        // R / (R + G + B) = 0.75: not saturated red.
        assert_eq!(
            oscillux_flash_region_from_linear_rgb(0.75, 0.25, 0.0, &mut out),
            OSCILLUX_OK
        );
        assert_eq!(out.red, 0.0);
        let before = out;
        for (r, g, b) in [(1.5, 0.0, 0.0), (0.0, -0.25, 0.0), (0.0, 0.0, f64::NAN)] {
            assert_eq!(
                oscillux_flash_region_from_linear_rgb(r, g, b, &mut out),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(out, before);
        }
        assert_eq!(
            oscillux_flash_region_from_linear_rgb(1.0, 0.0, 0.0, null_mut()),
            OSCILLUX_ERR_NULL
        );
    }
}
