// SPDX-License-Identifier: AGPL-3.0-only
//! The beat grid C interface: defaults and validation, refusals, results identical to the core
//! grid, and no allocation in the queries.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::ptr::{null, null_mut};

use oscillux::beatgrid::*;
use oscillux::{OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL, OSCILLUX_OK};
use oscillux_core::beatgrid::{BeatGrid, BeatGridConfig};

/// Counts allocations made by the current thread while armed.
struct CountingAlloc;

thread_local! {
    static ARMED: Cell<bool> = const { Cell::new(false) };
    static COUNT: Cell<usize> = const { Cell::new(0) };
}

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if ARMED.with(Cell::get) {
            COUNT.with(|c| c.set(c.get() + 1));
        }
        System.alloc(layout)
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }
}

#[global_allocator]
static GLOBAL: CountingAlloc = CountingAlloc;

fn allocations(body: impl FnOnce()) -> usize {
    COUNT.with(|c| c.set(0));
    ARMED.with(|a| a.set(true));
    body();
    ARMED.with(|a| a.set(false));
    COUNT.with(Cell::get)
}

const RATE: u32 = 44_100;
const CHANNELS: u32 = 2;
const SECONDS: f64 = 20.0;

/// Interleaved stereo clicks at 120 BPM in 4/4, the downbeat higher and louder.
fn clicks() -> Vec<f32> {
    let frames = (SECONDS * f64::from(RATE)) as usize;
    let beat = (0.5 * f64::from(RATE)) as usize;
    let click = (0.03 * f64::from(RATE)) as usize;
    let mut pcm = vec![0.0f32; frames * CHANNELS as usize];
    for (index, start) in (0..frames).step_by(beat).enumerate() {
        let (freq, amp) = if index % 4 == 0 {
            (2000.0, 0.8)
        } else {
            (1000.0, 0.5)
        };
        for n in 0..click.min(frames - start) {
            let t = n as f64 / f64::from(RATE);
            let v = amp * (-t / 0.008).exp() * (2.0 * std::f64::consts::PI * freq * t).sin();
            for ch in 0..CHANNELS as usize {
                pcm[(start + n) * CHANNELS as usize + ch] = v as f32;
            }
        }
    }
    pcm
}

fn default_config() -> OscilluxBeatGridConfig {
    let mut config = OscilluxBeatGridConfig {
        struct_size: std::mem::size_of::<OscilluxBeatGridConfig>() as u32,
        sample_rate_hz: 0,
        channels: 0,
        beats_per_bar: 0,
        min_bpm: 0.0,
        max_bpm: 0.0,
    };
    assert_eq!(
        unsafe { oscillux_beatgrid_config_default(&mut config) },
        OSCILLUX_OK
    );
    config
}

fn validate(config: &OscilluxBeatGridConfig) -> (i32, Option<String>) {
    let mut field: *const c_char = c"sentinel".as_ptr();
    let status = unsafe { oscillux_beatgrid_config_validate(config, &mut field) };
    let name = (!field.is_null()).then(|| {
        unsafe { CStr::from_ptr(field) }
            .to_str()
            .unwrap()
            .to_owned()
    });
    (status, name)
}

/// Creates a grid; the caller destroys it.
fn create(config: &OscilluxBeatGridConfig, pcm: &[f32]) -> *mut OscilluxBeatGrid {
    let mut grid = null_mut();
    let frames = pcm.len() / config.channels as usize;
    let status = unsafe { oscillux_beatgrid_create(config, pcm.as_ptr(), frames, &mut grid) };
    assert_eq!(status, OSCILLUX_OK);
    assert!(!grid.is_null());
    grid
}

fn clock(grid: *const OscilluxBeatGrid, t: f64) -> (i32, OscilluxBeatGridClock) {
    let mut out = OscilluxBeatGridClock {
        beat_phase: 7.0,
        bar_phase: 7.0,
        tempo_bpm: 7.0,
        beat_index: 7,
        beat_in_bar: 7,
        reserved: 7,
    };
    let status = unsafe { oscillux_beatgrid_clock(grid, t, &mut out) };
    (status, out)
}

const NO_POSITION: OscilluxBeatGridClock = OscilluxBeatGridClock {
    beat_phase: 0.0,
    bar_phase: 0.0,
    tempo_bpm: 0.0,
    beat_index: -1,
    beat_in_bar: 0,
    reserved: 0,
};

#[test]
fn defaults_match_the_core_and_validation_names_the_member() {
    let config = default_config();
    let core = BeatGridConfig::default();
    assert_eq!(config.struct_size, 32);
    assert_eq!(
        (config.sample_rate_hz, config.channels, config.beats_per_bar),
        (core.sample_rate_hz, core.channels, core.beats_per_bar)
    );
    assert_eq!(
        (config.min_bpm.to_bits(), config.max_bpm.to_bits()),
        (core.min_bpm.to_bits(), core.max_bpm.to_bits())
    );
    assert_eq!(validate(&config), (OSCILLUX_OK, None));

    let mut unsized_config = config;
    unsized_config.struct_size = 24;
    assert_eq!(
        unsafe { oscillux_beatgrid_config_default(&mut unsized_config) },
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert_eq!(
        unsized_config.struct_size, 24,
        "a refused default writes nothing"
    );
    assert_eq!(
        unsafe { oscillux_beatgrid_config_default(null_mut()) },
        OSCILLUX_ERR_NULL
    );

    let bad = |edit: fn(&mut OscilluxBeatGridConfig)| {
        let mut c = config;
        edit(&mut c);
        validate(&c)
    };
    let refused = |name: &str| (OSCILLUX_ERR_INVALID_ARGUMENT, Some(name.to_owned()));
    assert_eq!(bad(|c| c.struct_size = 33), refused("struct_size"));
    assert_eq!(bad(|c| c.sample_rate_hz = 7_999), refused("sample_rate_hz"));
    assert_eq!(
        bad(|c| c.sample_rate_hz = 384_001),
        refused("sample_rate_hz")
    );
    assert_eq!(bad(|c| c.channels = 0), refused("channels"));
    assert_eq!(bad(|c| c.beats_per_bar = 1), refused("beats_per_bar"));
    assert_eq!(bad(|c| c.beats_per_bar = 17), refused("beats_per_bar"));
    assert_eq!(bad(|c| c.min_bpm = 19.0), refused("min_bpm"));
    assert_eq!(bad(|c| c.min_bpm = f64::NAN), refused("min_bpm"));
    assert_eq!(bad(|c| c.max_bpm = 401.0), refused("max_bpm"));
    assert_eq!(bad(|c| c.max_bpm = c.min_bpm), refused("max_bpm"));
    assert_eq!(bad(|c| c.sample_rate_hz = 8_000).0, OSCILLUX_OK);
    assert_eq!(bad(|c| c.beats_per_bar = 16).0, OSCILLUX_OK);

    let mut field: *const c_char = c"sentinel".as_ptr();
    assert_eq!(
        unsafe { oscillux_beatgrid_config_validate(null(), &mut field) },
        OSCILLUX_ERR_NULL
    );
    assert!(field.is_null());
    assert_eq!(
        unsafe { oscillux_beatgrid_config_validate(&config, null_mut()) },
        OSCILLUX_OK
    );
}

#[test]
fn the_grid_is_the_core_grid() {
    let pcm = clicks();
    let config = default_config();
    let grid = create(&config, &pcm);
    let core = BeatGrid::analyse(&BeatGridConfig::default(), &pcm).unwrap();

    let mut count = usize::MAX;
    assert_eq!(
        unsafe { oscillux_beatgrid_beat_count(grid, &mut count) },
        OSCILLUX_OK
    );
    assert_eq!(count, core.beats().len());
    assert!(count >= 30, "{count} beats in 20 s of 120 BPM clicks");

    let mut info = OscilluxBeatGridInfo::default();
    assert_eq!(
        unsafe { oscillux_beatgrid_info(grid, &mut info) },
        OSCILLUX_OK
    );
    let want = core.info();
    assert_eq!(
        (info.beat_count, info.bar_count, info.beats_per_bar),
        (
            want.beat_count as u64,
            want.bar_count as u64,
            want.beats_per_bar
        )
    );
    assert_eq!(
        [info.tempo_bpm, info.confidence, info.duration_seconds].map(f64::to_bits),
        [want.tempo_bpm, want.confidence, want.duration_s].map(f64::to_bits)
    );
    assert!((info.tempo_bpm - 120.0).abs() < 1.0, "{}", info.tempo_bpm);
    assert_eq!(info.beats_per_bar, 4);

    // Copied in uneven chunks, the beats are the core's, bit for bit.
    let mut beats = Vec::new();
    let mut chunk = [OscilluxBeatGridBeat::default(); 7];
    loop {
        let mut written = usize::MAX;
        let status = unsafe {
            oscillux_beatgrid_copy_beats(
                grid,
                beats.len(),
                chunk.as_mut_ptr(),
                chunk.len(),
                &mut written,
            )
        };
        assert_eq!(status, OSCILLUX_OK);
        beats.extend_from_slice(&chunk[..written]);
        if written < chunk.len() {
            break;
        }
    }
    assert_eq!(beats.len(), count);
    for (got, want) in beats.iter().zip(core.beats()) {
        assert_eq!(got.time_seconds.to_bits(), want.time_s.to_bits());
        assert_eq!(got.tempo_bpm.to_bits(), want.tempo_bpm.to_bits());
        assert_eq!(
            (got.beat_in_bar, got.bar_index),
            (want.beat_in_bar, want.bar_index)
        );
    }

    // The clock is the core's, before, inside and after the grid.
    let mut t = -1.5;
    while t < SECONDS + 1.5 {
        let (status, got) = clock(grid, t);
        let want = core.clock(t);
        assert_eq!(status, OSCILLUX_OK, "t = {t}");
        assert_eq!(
            [got.beat_phase, got.bar_phase, got.tempo_bpm].map(f64::to_bits),
            [want.beat_phase, want.bar_phase, want.tempo_bpm].map(f64::to_bits),
            "t = {t}"
        );
        assert_eq!(
            (got.beat_index, got.beat_in_bar, got.reserved),
            (want.beat_index, want.beat_in_bar, 0),
            "t = {t}"
        );
        t += 0.0137;
    }
    let (_, at_first) = clock(grid, beats[0].time_seconds);
    assert_eq!((at_first.beat_index, at_first.beat_phase), (0, 0.0));
    let (_, before) = clock(grid, beats[0].time_seconds - 1e-3);
    assert_eq!(before.beat_index, -1);

    unsafe { oscillux_beatgrid_destroy(grid) };
}

#[test]
fn refusals_leave_no_handle_and_name_the_problem() {
    let pcm = clicks();
    let config = default_config();
    let frames = pcm.len() / 2;
    let mut grid: *mut OscilluxBeatGrid = std::ptr::NonNull::dangling().as_ptr();

    assert_eq!(
        unsafe { oscillux_beatgrid_create(&config, pcm.as_ptr(), frames, null_mut()) },
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        unsafe { oscillux_beatgrid_create(null(), pcm.as_ptr(), frames, &mut grid) },
        OSCILLUX_ERR_NULL
    );
    assert!(grid.is_null(), "a refused create writes a null handle");
    let mut bad = config;
    bad.struct_size = 0;
    grid = std::ptr::NonNull::dangling().as_ptr();
    assert_eq!(
        unsafe { oscillux_beatgrid_create(&bad, pcm.as_ptr(), frames, &mut grid) },
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert!(grid.is_null());
    bad = config;
    bad.channels = 0;
    assert_eq!(
        unsafe { oscillux_beatgrid_create(&bad, pcm.as_ptr(), frames, &mut grid) },
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert_eq!(
        unsafe { oscillux_beatgrid_create(&config, null(), frames, &mut grid) },
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        unsafe { oscillux_beatgrid_create(&config, pcm.as_ptr(), usize::MAX, &mut grid) },
        OSCILLUX_ERR_INVALID_ARGUMENT,
        "frames times channels overflows"
    );
    assert_eq!(
        unsafe { oscillux_beatgrid_create(&config, pcm.as_ptr(), usize::MAX / 2, &mut grid) },
        OSCILLUX_ERR_INVALID_ARGUMENT,
        "more samples than an allocation can hold"
    );
    assert!(grid.is_null());

    // No samples: an empty grid with no position.
    assert_eq!(
        unsafe { oscillux_beatgrid_create(&config, null(), 0, &mut grid) },
        OSCILLUX_OK
    );
    let mut count = usize::MAX;
    assert_eq!(
        unsafe { oscillux_beatgrid_beat_count(grid, &mut count) },
        OSCILLUX_OK
    );
    assert_eq!(count, 0);
    assert_eq!(clock(grid, 1.0), (OSCILLUX_OK, NO_POSITION));
    let mut written = usize::MAX;
    assert_eq!(
        unsafe { oscillux_beatgrid_copy_beats(grid, 0, null_mut(), 0, &mut written) },
        OSCILLUX_OK
    );
    assert_eq!(written, 0);
    unsafe { oscillux_beatgrid_destroy(grid) };

    let grid = create(&config, &pcm);
    unsafe { oscillux_beatgrid_beat_count(grid, &mut count) };
    let mut chunk = [OscilluxBeatGridBeat::default(); 4];
    let copy = |first: usize, out: *mut OscilluxBeatGridBeat, capacity: usize| {
        let mut written = usize::MAX;
        let status =
            unsafe { oscillux_beatgrid_copy_beats(grid, first, out, capacity, &mut written) };
        (status, written)
    };
    assert_eq!(copy(count, chunk.as_mut_ptr(), 4), (OSCILLUX_OK, 0));
    assert_eq!(
        copy(count - 1, chunk.as_mut_ptr(), 4),
        (OSCILLUX_OK, 1),
        "clipped to the beat count"
    );
    assert_eq!(
        copy(count + 1, chunk.as_mut_ptr(), 4),
        (OSCILLUX_ERR_INVALID_ARGUMENT, 0)
    );
    assert_eq!(copy(0, null_mut(), 4), (OSCILLUX_ERR_NULL, 0));
    assert_eq!(copy(0, null_mut(), 0), (OSCILLUX_OK, 0));
    assert_eq!(
        copy(0, chunk.as_mut_ptr(), usize::MAX),
        (OSCILLUX_ERR_INVALID_ARGUMENT, 0)
    );
    assert_eq!(
        unsafe { oscillux_beatgrid_copy_beats(grid, 0, chunk.as_mut_ptr(), 4, null_mut()) },
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        unsafe { oscillux_beatgrid_copy_beats(null(), 0, chunk.as_mut_ptr(), 4, &mut written) },
        OSCILLUX_ERR_NULL
    );

    for t in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert_eq!(clock(grid, t), (OSCILLUX_ERR_INVALID_ARGUMENT, NO_POSITION));
    }
    let mut out = NO_POSITION;
    assert_eq!(
        unsafe { oscillux_beatgrid_clock(null(), 1.0, &mut out) },
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        unsafe { oscillux_beatgrid_clock(grid, 1.0, null_mut()) },
        OSCILLUX_ERR_NULL
    );
    let mut info = OscilluxBeatGridInfo::default();
    assert_eq!(
        unsafe { oscillux_beatgrid_info(null(), &mut info) },
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        unsafe { oscillux_beatgrid_info(grid, null_mut()) },
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        unsafe { oscillux_beatgrid_beat_count(null(), &mut count) },
        OSCILLUX_ERR_NULL
    );
    unsafe { oscillux_beatgrid_destroy(grid) };
    unsafe { oscillux_beatgrid_destroy(null_mut()) };
}

#[test]
fn queries_do_not_allocate_and_the_handle_is_shareable() {
    fn shareable<T: Send + Sync>() {}
    shareable::<OscilluxBeatGrid>();

    let pcm = clicks();
    let grid = create(&default_config(), &pcm);
    let mut chunk = [OscilluxBeatGridBeat::default(); 16];
    let made = allocations(|| {
        let mut t = -1.0;
        while t < SECONDS + 1.0 {
            let (status, _) = clock(grid, t);
            assert_eq!(status, OSCILLUX_OK);
            t += 1.0 / 60.0;
        }
        let mut info = OscilluxBeatGridInfo::default();
        let mut count = 0;
        let mut written = 0;
        unsafe {
            oscillux_beatgrid_info(grid, &mut info);
            oscillux_beatgrid_beat_count(grid, &mut count);
            oscillux_beatgrid_copy_beats(grid, 0, chunk.as_mut_ptr(), chunk.len(), &mut written);
        }
        let _ = clock(grid, f64::NAN);
    });
    assert_eq!(made, 0, "the queries allocated");
    unsafe { oscillux_beatgrid_destroy(grid) };
}
