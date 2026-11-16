// SPDX-License-Identifier: AGPL-3.0-only
//! The transition scheduler through its C entry points: the oracle vectors in
//! `conformance/transition/reference.json` reproduced exactly, refused and null arguments, the
//! struct_size rule, and invariant 4 for the per-frame calls (request, update, status, reset),
//! which allocate nothing after create, on success or on refusal.
#[allow(dead_code)]
#[path = "../../oscillux-core/tests/json/mod.rs"]
mod json;
use json::Value;
use oscillux::transition::*;
use oscillux::{OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
    ptr::{null, null_mut},
};

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

fn num(v: &Value) -> f64 {
    match v {
        Value::Str(s) => match s.as_str() {
            "NaN" => f64::NAN,
            "Infinity" => f64::INFINITY,
            "-Infinity" => f64::NEG_INFINITY,
            other => panic!("number {other}"),
        },
        v => v.num(),
    }
}

fn field<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    match v {
        Value::Obj(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
        _ => None,
    }
}

fn clock(v: &Value) -> OscilluxTransitionClock {
    let f: Vec<f64> = v.arr().iter().map(num).collect();
    OscilluxTransitionClock {
        time_seconds: f[0],
        beat_phase: f[1],
        bar_phase: f[2],
        tempo_bpm: f[3],
        confidence: f[4],
    }
}

fn create(config: &OscilluxTransitionConfig) -> (i32, *mut OscilluxTransition) {
    let mut handle = std::ptr::dangling_mut::<OscilluxTransition>();
    let status = unsafe { oscillux_transition_create(config, &mut handle) };
    (status, handle)
}

fn check(name: &str, step: usize, rc: i32, got: &OscilluxTransitionStatus, want: &Value) {
    if let Value::Str(s) = want {
        assert_eq!(s, "refused");
        assert_eq!(rc, OSCILLUX_ERR_INVALID_ARGUMENT, "{name} step {step}");
        return;
    }
    assert_eq!(rc, OSCILLUX_OK, "{name} step {step}");
    let w: Vec<f64> = want.arr().iter().map(num).collect();
    let g = [
        got.progress,
        got.request_seconds,
        got.start_seconds,
        got.end_seconds,
        f64::from(got.state),
        f64::from(got.quantise),
        f64::from(got.auto_requested),
    ];
    for (i, (g, w)) in g.iter().zip(&w).enumerate() {
        assert!(
            g.to_bits() == w.to_bits(),
            "{name} step {step} field {i}: {g:?} vs {w:?}"
        );
    }
}

#[test]
fn c_interface_matches_the_oracle_exactly() {
    let doc = json::parse(include_str!(
        "../../../conformance/transition/reference.json"
    ))
    .unwrap();
    for case in doc.get("cases").arr() {
        let name = case.get("name").str();
        let c = case.get("config");
        let config = OscilluxTransitionConfig {
            easing: num(c.get("easing")) as u32,
            beats_per_bar: num(c.get("beats_per_bar")) as u32,
            auto_advance_bars: num(c.get("auto_advance_bars")) as u32,
            duration_beats: num(c.get("duration_beats")),
            fallback_seconds: num(c.get("fallback_seconds")),
            pre_roll_seconds: num(c.get("pre_roll_seconds")),
            min_confidence: num(c.get("min_confidence")),
            ..OscilluxTransitionConfig::default()
        };
        let (rc, handle) = create(&config);
        if field(case, "create").is_some() {
            assert_eq!(rc, OSCILLUX_ERR_INVALID_ARGUMENT, "{name}");
            assert!(handle.is_null());
            continue;
        }
        assert_eq!(rc, OSCILLUX_OK, "{name}");
        for (i, step) in case.get("steps").arr().iter().enumerate() {
            let want = field(step, "want").unwrap_or(&Value::Null);
            let mut out = OscilluxTransitionStatus::default();
            unsafe {
                match step.get("op").str() {
                    "request" => {
                        let rc = oscillux_transition_request(
                            handle,
                            &clock(step.get("clock")),
                            num(step.get("quantise")) as u32,
                            num(step.get("max_wait")),
                            &mut out,
                        );
                        check(name, i, rc, &out, want);
                    }
                    "update" => {
                        let rc =
                            oscillux_transition_update(handle, &clock(step.get("clock")), &mut out);
                        check(name, i, rc, &out, want);
                    }
                    "status" => {
                        let rc =
                            oscillux_transition_status(handle, num(step.get("time")), &mut out);
                        check(name, i, rc, &out, want);
                    }
                    "reset" => assert_eq!(oscillux_transition_reset(handle), OSCILLUX_OK),
                    op => panic!("{op}"),
                }
            }
        }
        unsafe { oscillux_transition_destroy(handle) };
    }
}

#[test]
fn struct_size_nulls_and_refusals() {
    unsafe {
        let mut config = OscilluxTransitionConfig {
            struct_size: TRANSITION_CONFIG_SIZE,
            easing: 9,
            ..OscilluxTransitionConfig::default()
        };
        assert_eq!(oscillux_transition_config_default(&mut config), OSCILLUX_OK);
        assert_eq!(config, OscilluxTransitionConfig::default());
        assert_eq!(TRANSITION_CONFIG_SIZE, 48);
        for size in [0, 4, 40, 47, 49, 56] {
            let mut sized = OscilluxTransitionConfig {
                struct_size: size,
                ..OscilluxTransitionConfig::default()
            };
            assert_eq!(
                oscillux_transition_config_default(&mut sized),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(create(&sized).0, OSCILLUX_ERR_INVALID_ARGUMENT);
            assert!(create(&sized).1.is_null());
        }
        assert_eq!(
            oscillux_transition_config_default(null_mut()),
            OSCILLUX_ERR_NULL
        );
        let mut handle = std::ptr::dangling_mut::<OscilluxTransition>();
        assert_eq!(
            oscillux_transition_create(null(), &mut handle),
            OSCILLUX_ERR_NULL
        );
        assert!(handle.is_null());
        assert_eq!(
            oscillux_transition_create(&config, null_mut()),
            OSCILLUX_ERR_NULL
        );
        let (rc, h) = create(&config);
        assert_eq!(rc, OSCILLUX_OK);
        let c = OscilluxTransitionClock::default();
        let mut out = OscilluxTransitionStatus::default();
        assert_eq!(
            oscillux_transition_request(null_mut(), &c, 0, 0.0, &mut out),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_transition_request(h, null(), 0, 0.0, &mut out),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_transition_request(h, &c, 0, 0.0, null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_transition_update(null_mut(), &c, &mut out),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_transition_update(h, null(), &mut out),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_transition_update(h, &c, null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_transition_status(null(), 0.0, &mut out),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(
            oscillux_transition_status(h, 0.0, null_mut()),
            OSCILLUX_ERR_NULL
        );
        assert_eq!(oscillux_transition_reset(null_mut()), OSCILLUX_ERR_NULL);
        // A refused request leaves *out unwritten.
        let sentinel = OscilluxTransitionStatus {
            progress: 7.0,
            ..OscilluxTransitionStatus::default()
        };
        out = sentinel;
        assert_eq!(
            oscillux_transition_request(h, &c, 3, 0.0, &mut out),
            OSCILLUX_ERR_INVALID_ARGUMENT
        );
        assert_eq!(out, sentinel);
        oscillux_transition_destroy(h);
        oscillux_transition_destroy(null_mut());
    }
}

#[test]
fn per_frame_calls_do_not_allocate() {
    let config = OscilluxTransitionConfig {
        auto_advance_bars: 1,
        ..OscilluxTransitionConfig::default()
    };
    let (rc, h) = create(&config);
    assert_eq!(rc, OSCILLUX_OK);
    let mut out = OscilluxTransitionStatus::default();
    let mut autos = 0;
    ARMED.with(|v| v.set(true));
    for i in 0..6000u32 {
        let t = f64::from(i) / 60.0;
        let beats = t * 2.1;
        let c = OscilluxTransitionClock {
            time_seconds: t,
            beat_phase: beats - beats.floor(),
            bar_phase: beats / 4.0 - (beats / 4.0).floor(),
            tempo_bpm: 126.0,
            confidence: if i % 900 < 450 { 0.9 } else { 0.1 },
        };
        unsafe {
            assert_eq!(oscillux_transition_update(h, &c, &mut out), OSCILLUX_OK);
            autos += out.auto_requested;
            if i % 500 == 7 {
                assert_eq!(
                    oscillux_transition_request(h, &c, 2, 2.0, &mut out),
                    OSCILLUX_OK
                );
            }
            let bad = OscilluxTransitionClock {
                time_seconds: f64::NAN,
                ..c
            };
            assert_eq!(
                oscillux_transition_update(h, &bad, &mut out),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(
                oscillux_transition_request(h, &c, 1, -1.0, &mut out),
                OSCILLUX_ERR_INVALID_ARGUMENT
            );
            assert_eq!(
                oscillux_transition_status(h, t + 0.5, &mut out),
                OSCILLUX_OK
            );
            if i % 2999 == 2998 {
                assert_eq!(oscillux_transition_reset(h), OSCILLUX_OK);
            }
        }
    }
    ARMED.with(|v| v.set(false));
    assert_eq!(
        ALLOCS.with(Cell::get),
        0,
        "a per-frame transition call allocated"
    );
    assert!(autos > 10, "auto-advance issued only {autos} requests");
    unsafe { oscillux_transition_destroy(h) };
}
