// SPDX-License-Identifier: AGPL-3.0-only
//! Invariant 4: after warm-up, no per-frame C entry point allocates, on success or on refusal.
//!
//! Covers every per-frame export in `ffi/include/oscillux.h`: DSP segment and push (F32 and
//! F64, plain and ext, behaviour versions 1 and 2), limiter process and reset, flash analyzer
//! measure, admit, their RGB forms (under both red rules) and reset, region from linear RGB,
//! curve evaluate, governor record and reset, mapping process (plain and ext) and reset,
//! reaction push, sample, beat clock, queued and reset, packer pack, and the ABI version, release version, status string and DSP config
//! and versioned config validate queries.
//! The CD+G per-frame exports (advance, state, screen, window RGBA) are covered in `cdg_ffi`.
use oscillux::dsp::*;
use oscillux::limiter::*;
use oscillux::{
    curves::*, governor::*, mapping::*, oscillux_abi_version, oscillux_status_string,
    oscillux_version, packing::*, reaction::*, OSCILLUX_ERR_INVALID_ARGUMENT, OSCILLUX_ERR_NULL,
    OSCILLUX_ERR_PANIC, OSCILLUX_OK,
};
use oscillux_core::dsp::{DspConfig, DspFrame};
use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
    ptr::null_mut,
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

struct Handles {
    dsp: *mut OscilluxDsp,
    dsp_v2: *mut OscilluxDsp,
    limiter: *mut OscilluxLimiter,
    flash: *mut OscilluxFlashAnalyzer,
    iso: *mut OscilluxFlashAnalyzer,
    curve: *mut OscilluxCurve,
    governor: *mut OscilluxGovernor,
    mapper: *mut OscilluxMapper,
    reaction: *mut OscilluxReactionSampler,
    packer: *mut OscilluxPacker,
}
impl Drop for Handles {
    fn drop(&mut self) {
        unsafe {
            oscillux_dsp_destroy(self.dsp);
            oscillux_dsp_destroy(self.dsp_v2);
            oscillux_limiter_destroy(self.limiter);
            oscillux_flash_analyzer_destroy(self.flash);
            oscillux_flash_analyzer_destroy(self.iso);
            oscillux_curve_destroy(self.curve);
            oscillux_governor_destroy(self.governor);
            oscillux_mapping_destroy(self.mapper);
            oscillux_reaction_destroy(self.reaction);
            oscillux_packer_destroy(self.packer);
        }
    }
}
impl Handles {
    fn new() -> Self {
        let mut h = Self {
            dsp: null_mut(),
            dsp_v2: null_mut(),
            limiter: null_mut(),
            flash: null_mut(),
            iso: null_mut(),
            curve: null_mut(),
            governor: null_mut(),
            mapper: null_mut(),
            reaction: null_mut(),
            packer: null_mut(),
        };
        unsafe {
            let mut dsp = DspConfig::default();
            assert_eq!(oscillux_dsp_config_default(&mut dsp), OSCILLUX_OK);
            assert_eq!(oscillux_dsp_create(&dsp, &mut h.dsp), OSCILLUX_OK);
            let mut v2 = OscilluxDspVersionedConfig::default();
            assert_eq!(oscillux_dsp_versioned_config_default(&mut v2), OSCILLUX_OK);
            assert_eq!(v2.behavior_version, OSCILLUX_DSP_BEHAVIOR_V2);
            assert_eq!(
                oscillux_dsp_create_versioned(&v2, &mut h.dsp_v2),
                OSCILLUX_OK
            );
            let mut policy = OscilluxLimiterPolicy::default();
            assert_eq!(oscillux_limiter_policy_default(&mut policy), OSCILLUX_OK);
            assert_eq!(
                oscillux_limiter_create(&policy, &mut h.limiter),
                OSCILLUX_OK
            );
            let mut flash = OscilluxFlashConfig::default();
            assert_eq!(oscillux_flash_config_default(&mut flash), OSCILLUX_OK);
            assert_eq!(
                oscillux_flash_analyzer_create(&flash, &mut h.flash),
                OSCILLUX_OK
            );
            flash.red_rule = OSCILLUX_FLASH_RED_RULE_ISO_9241_391;
            assert_eq!(
                oscillux_flash_analyzer_create(&flash, &mut h.iso),
                OSCILLUX_OK
            );
            let mut curve = OscilluxCurveConfig::default();
            assert_eq!(oscillux_curve_config_default(&mut curve), OSCILLUX_OK);
            curve.value = 0.5;
            assert_eq!(oscillux_curve_create(&curve, &mut h.curve), OSCILLUX_OK);
            let mut governor = OscilluxGovernorConfig::default();
            assert_eq!(oscillux_governor_config_default(&mut governor), OSCILLUX_OK);
            assert_eq!(
                oscillux_governor_create(&governor, &mut h.governor),
                OSCILLUX_OK
            );
            let mut mapper = OscilluxMappingConfig::default();
            assert_eq!(oscillux_mapping_config_default(&mut mapper), OSCILLUX_OK);
            assert_eq!(oscillux_mapping_create(&mapper, &mut h.mapper), OSCILLUX_OK);
            let mut reaction = OscilluxReactionConfig::default();
            assert_eq!(
                oscillux_reaction_config_default(OSCILLUX_DSP_BEHAVIOR_V3, 48_000, &mut reaction),
                OSCILLUX_OK
            );
            reaction.capacity = 16;
            assert_eq!(
                oscillux_reaction_create(&reaction, &mut h.reaction),
                OSCILLUX_OK
            );
            let fields = [
                OscilluxUniformField {
                    source: 0,
                    source_offset: 0,
                    components: 9,
                    offset: 0,
                    stride: 4,
                },
                OscilluxUniformField {
                    source: 1,
                    source_offset: 0,
                    components: 64,
                    offset: 48,
                    stride: 4,
                },
                OscilluxUniformField {
                    source: 2,
                    source_offset: 0,
                    components: 1,
                    offset: 36,
                    stride: 4,
                },
            ];
            assert_eq!(
                oscillux_packer_create(fields.as_ptr(), fields.len(), 304, &mut h.packer),
                OSCILLUX_OK
            );
        }
        h
    }
}

/// One host frame through every per-frame export, including refused inputs.
/// Returns the analysis frames produced so the caller can check work was done.
unsafe fn frame(
    h: &Handles,
    i: usize,
    pcm32: &[f32],
    pcm64: &[f64],
    scratch: &mut Scratch,
) -> usize {
    let Scratch {
        frames,
        ext,
        result,
        mapped,
        reaction,
        bytes,
        stats,
        flash: report,
        flash_refused,
    } = scratch;
    let mut produced = 0;

    // DSP, both behaviour versions: a new segment every so often, then F32 and F64 pushes.
    for dsp in [h.dsp, h.dsp_v2] {
        if i % 7 == 0 {
            let t = i as f64 * 10.0;
            assert_eq!(
                oscillux_dsp_begin_segment(dsp, t, (i % 2) as u32),
                OSCILLUX_OK
            );
        }
        assert_eq!(
            oscillux_dsp_push_f32(
                dsp,
                pcm32.as_ptr(),
                pcm32.len() / 2,
                2,
                frames.as_mut_ptr(),
                frames.len(),
                result
            ),
            OSCILLUX_OK
        );
        produced += result.produced;
        assert_eq!(
            oscillux_dsp_push_f64(
                dsp,
                pcm64.as_ptr(),
                pcm64.len(),
                1,
                frames.as_mut_ptr(),
                frames.len(),
                result
            ),
            OSCILLUX_OK
        );
        produced += result.produced;
        assert_eq!(
            oscillux_dsp_push_ext_f32(
                dsp,
                pcm32.as_ptr(),
                pcm32.len() / 2,
                2,
                frames.as_mut_ptr(),
                ext.as_mut_ptr(),
                frames.len(),
                result
            ),
            OSCILLUX_OK
        );
        produced += result.produced;
        assert_eq!(
            oscillux_dsp_push_ext_f64(
                dsp,
                pcm64.as_ptr(),
                pcm64.len(),
                1,
                frames.as_mut_ptr(),
                ext.as_mut_ptr(),
                frames.len(),
                result
            ),
            OSCILLUX_OK
        );
        produced += result.produced;
    }
    // A refused ext array: a nonzero reserved in a later element.
    ext[3].reserved = 1;
    assert_eq!(
        oscillux_dsp_push_ext_f32(
            h.dsp,
            pcm32.as_ptr(),
            1,
            2,
            frames.as_mut_ptr(),
            ext.as_mut_ptr(),
            frames.len(),
            result
        ),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    ext[3].reserved = 0;
    // Refused DSP calls: null handle, null result, bad channel count, overflowing length.
    let p = pcm32.as_ptr();
    let o = frames.as_mut_ptr();
    let n = frames.len();
    assert_eq!(
        oscillux_dsp_push_f32(null_mut(), p, 1, 1, o, n, result),
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        oscillux_dsp_push_f32(h.dsp, p, 1, 1, o, n, null_mut()),
        OSCILLUX_ERR_NULL
    );
    assert_eq!(
        oscillux_dsp_push_f32(h.dsp, p, 0, 0, o, n, result),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert_eq!(
        oscillux_dsp_push_f32(h.dsp, p, usize::MAX, 2, o, n, result),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert_eq!(
        oscillux_dsp_begin_segment(null_mut(), 0.0, 0),
        OSCILLUX_ERR_NULL
    );

    // Limiter: valid frame (time advances), a refused frame, and a periodic reset.
    let input = OscilluxLimiterFrame {
        time_ms: i as f64 * 16.0,
        broadband: if i % 3 == 0 { 0.95 } else { 0.1 },
        area: 0.5,
        red: if i % 5 == 0 { 0.9 } else { 0.0 },
        ..Default::default()
    };
    let mut limited = OscilluxLimiterFrame::default();
    assert_eq!(
        oscillux_limiter_process(h.limiter, &input, &mut limited),
        OSCILLUX_OK
    );
    let bad = OscilluxLimiterFrame {
        broadband: f64::NAN,
        ..input
    };
    assert_eq!(
        oscillux_limiter_process(h.limiter, &bad, &mut limited),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    if i % 50 == 49 {
        assert_eq!(oscillux_limiter_reset(h.limiter), OSCILLUX_OK);
    }

    // Flash analyzer: a full 16 x 16 grid flashing every frame, measured and admitted on two
    // timelines of the same handle, refused input, and a periodic reset.
    let mut region = OscilluxFlashRegion::default();
    let level = if i % 2 == 0 { 0.5 } else { 0.0 };
    assert_eq!(
        oscillux_flash_region_from_linear_rgb(level, 0.0, 0.0, &mut region),
        OSCILLUX_OK
    );
    assert_eq!(
        oscillux_flash_region_from_linear_rgb(f64::NAN, 0.0, 0.0, &mut region),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    let regions = [region; 256];
    let time = i as f64 * 16.0;
    let call = if i % 3 == 0 {
        oscillux_flash_analyzer_measure
    } else {
        oscillux_flash_analyzer_admit
    };
    assert_eq!(
        call(h.flash, time, regions.as_ptr(), regions.len(), report),
        OSCILLUX_OK
    );
    *flash_refused += usize::from(report.admitted == 0);
    assert_eq!(
        oscillux_flash_analyzer_admit(h.flash, time, regions.as_ptr(), 255, report),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert_eq!(
        oscillux_flash_analyzer_measure(h.flash, f64::NAN, regions.as_ptr(), 256, report),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    // The RGB forms: the WCAG 2.0 handle sometimes, and an ISO 9241-391 handle whose regions
    // alternate saturated red and blue, which refuses the sample path.
    let color = if i % 2 == 0 {
        OscilluxFlashColor {
            r: 0.25,
            g: 0.0,
            b: 0.0,
        }
    } else {
        OscilluxFlashColor {
            r: 0.0,
            g: 0.0,
            b: 0.25,
        }
    };
    let colors = [color; 256];
    if i % 5 == 0 {
        assert_eq!(
            oscillux_flash_analyzer_measure_rgb(h.flash, time, colors.as_ptr(), 256, report),
            OSCILLUX_OK
        );
    }
    let call_rgb = if i % 3 == 0 {
        oscillux_flash_analyzer_measure_rgb
    } else {
        oscillux_flash_analyzer_admit_rgb
    };
    assert_eq!(
        call_rgb(h.iso, time, colors.as_ptr(), colors.len(), report),
        OSCILLUX_OK
    );
    *flash_refused += usize::from(report.admitted == 0);
    assert_eq!(
        oscillux_flash_analyzer_admit(h.iso, time, regions.as_ptr(), 256, report),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert_eq!(
        oscillux_flash_analyzer_admit_rgb(h.iso, time, colors.as_ptr(), 255, report),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    if i % 50 == 49 {
        assert_eq!(oscillux_flash_analyzer_reset(h.flash), OSCILLUX_OK);
        assert_eq!(oscillux_flash_analyzer_reset(h.iso), OSCILLUX_OK);
    }

    // Curve, governor, mapping, packing.
    let mut value = 0.0;
    assert_eq!(
        oscillux_curve_evaluate(h.curve, &OscilluxCurveInput::default(), &mut value),
        OSCILLUX_OK
    );
    let bad_input = OscilluxCurveInput {
        elapsed_seconds: f64::INFINITY,
        ..Default::default()
    };
    assert_eq!(
        oscillux_curve_evaluate(h.curve, &bad_input, &mut value),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert_eq!(
        oscillux_governor_record(h.governor, 16.7, stats),
        OSCILLUX_OK
    );
    assert_eq!(
        oscillux_governor_record(h.governor, f64::NAN, stats),
        OSCILLUX_OK
    );
    let analysed = if produced > 0 {
        frames[0]
    } else {
        DspFrame::ZERO
    };
    assert_eq!(
        oscillux_mapping_process(h.mapper, &analysed, 0, mapped),
        OSCILLUX_OK
    );
    assert_eq!(
        oscillux_mapping_process(h.mapper, &analysed, 2, mapped),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert_eq!(
        oscillux_mapping_process_ext(h.mapper, &analysed, &ext[0], 0, mapped),
        OSCILLUX_OK
    );
    let mut bad = ext[0];
    bad.struct_size = 8;
    assert_eq!(
        oscillux_mapping_process_ext(h.mapper, &analysed, &bad, 0, mapped),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    // `analysed` may come from a later plain push than `ext[0]`; the relative source then
    // refuses the band count mismatch, still without allocating.
    let relative = if ext[0].levels.band_count == analysed.band_count {
        OSCILLUX_OK
    } else {
        OSCILLUX_ERR_INVALID_ARGUMENT
    };
    assert_eq!(
        oscillux_mapping_set_level_source(h.mapper, OSCILLUX_MAPPING_LEVELS_RELATIVE),
        OSCILLUX_OK
    );
    assert_eq!(
        oscillux_mapping_process_ext(h.mapper, &analysed, &ext[0], 0, mapped),
        relative
    );
    assert_eq!(
        oscillux_mapping_set_level_source(h.mapper, OSCILLUX_MAPPING_LEVELS_ABSOLUTE),
        OSCILLUX_OK
    );
    // Reaction: one hop per frame, a refused hop, a sample and a refused sample, a full queue
    // now and then, and a host clock on alternate stretches.
    let media = i as f64 * 10.0;
    let beat = ext[0].beat;
    assert_eq!(
        oscillux_reaction_push(h.reaction, media, mapped, &beat),
        OSCILLUX_OK
    );
    assert_eq!(
        oscillux_reaction_push(h.reaction, f64::NAN, mapped, null_mut()),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    if i % 23 == 22 {
        let mut queued = 0;
        while oscillux_reaction_push(h.reaction, media, mapped, null_mut()) == OSCILLUX_OK {}
        assert_eq!(
            oscillux_reaction_queued(h.reaction, &mut queued),
            OSCILLUX_OK
        );
        assert_eq!(queued, 16);
    }
    let clock = OscilluxBeatClock {
        media_time_ms: media,
        tempo_bpm: 120.0,
        beat_phase: 0.25,
        bar_phase: 0.5,
        beat_index: i as i64,
        beats_per_bar: 4,
        reserved: 0,
    };
    let use_clock = if i % 200 < 100 {
        &clock as *const _
    } else {
        std::ptr::null()
    };
    assert_eq!(
        oscillux_reaction_set_beat_clock(h.reaction, use_clock),
        OSCILLUX_OK
    );
    assert_eq!(
        oscillux_reaction_sample(h.reaction, media + 20.0, reaction),
        OSCILLUX_OK
    );
    assert_eq!(
        oscillux_reaction_sample(h.reaction, f64::INFINITY, reaction),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    if i % 97 == 96 {
        assert_eq!(oscillux_reaction_reset(h.reaction), OSCILLUX_OK);
    }
    assert_eq!(
        oscillux_packer_pack(h.packer, mapped, &value, 1, bytes.as_mut_ptr(), bytes.len()),
        OSCILLUX_OK
    );
    assert_eq!(
        oscillux_packer_pack(
            h.packer,
            mapped,
            &f64::NAN,
            1,
            bytes.as_mut_ptr(),
            bytes.len()
        ),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    if i % 19 == 18 {
        assert_eq!(oscillux_governor_reset(h.governor, 1), OSCILLUX_OK);
        assert_eq!(oscillux_mapping_reset(h.mapper), OSCILLUX_OK);
    }
    assert_eq!(oscillux_abi_version(), 1);
    assert_eq!(oscillux_version(), oscillux::VERSION);
    for status in [
        OSCILLUX_OK,
        OSCILLUX_ERR_NULL,
        OSCILLUX_ERR_INVALID_ARGUMENT,
        OSCILLUX_ERR_PANIC,
        i as i32,
    ] {
        assert!(!oscillux_status_string(status).is_null());
    }
    let mut config = DspConfig::default();
    let mut field = std::ptr::null();
    assert_eq!(
        oscillux_dsp_config_validate(&config, &mut field),
        OSCILLUX_OK
    );
    config.hop_samples = 0;
    assert_eq!(
        oscillux_dsp_config_validate(&config, &mut field),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert!(!field.is_null());
    let mut versioned = OscilluxDspVersionedConfig::default();
    assert_eq!(
        oscillux_dsp_versioned_config_validate(&versioned, &mut field),
        OSCILLUX_OK
    );
    versioned.behavior_version = 0;
    assert_eq!(
        oscillux_dsp_versioned_config_validate(&versioned, &mut field),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert!(!field.is_null());
    versioned.behavior_version = OSCILLUX_DSP_BEHAVIOR_V2;
    versioned.reserved = 1;
    assert_eq!(
        oscillux_dsp_versioned_config_validate(&versioned, &mut field),
        OSCILLUX_ERR_INVALID_ARGUMENT
    );
    assert!(!field.is_null());
    produced
}

struct Scratch {
    frames: Vec<DspFrame>,
    ext: Vec<OscilluxDspFrameExt>,
    result: OscilluxDspPushResult,
    mapped: OscilluxMapped,
    reaction: OscilluxReaction,
    bytes: [u8; 304],
    stats: OscilluxGovernorStats,
    flash: OscilluxFlashReport,
    flash_refused: usize,
}

#[test]
fn every_per_frame_c_entry_point_is_allocation_free_after_warm_up() {
    let h = Handles::new();
    // 10 ms of 48 kHz stereo F32 and mono F64 per host frame.
    let pcm32: Vec<f32> = (0..960).map(|i| ((i % 89) as f32 - 44.0) / 64.0).collect();
    let pcm64: Vec<f64> = (0..480).map(|i| ((i % 53) as f64 - 26.0) / 32.0).collect();
    let mut scratch = Scratch {
        frames: vec![DspFrame::ZERO; 8],
        ext: vec![OscilluxDspFrameExt::default(); 8],
        result: OscilluxDspPushResult::default(),
        mapped: OscilluxMapped::ZERO,
        reaction: OscilluxReaction::ZERO,
        bytes: [0; 304],
        stats: OscilluxGovernorStats {
            ema_ms: 0.0,
            refresh_ms: 0.0,
            level: 0,
            has_ema: 0,
        },
        flash: OscilluxFlashReport::default(),
        flash_refused: 0,
    };
    // Warm-up: fill the analysis window and touch every path once.
    for i in 0..10 {
        unsafe { frame(&h, i, &pcm32, &pcm64, &mut scratch) };
    }
    ARMED.with(|v| v.set(true));
    let mut produced = 0;
    for i in 10..3000 {
        produced += unsafe { frame(&h, i, &pcm32, &pcm64, &mut scratch) };
    }
    ARMED.with(|v| v.set(false));
    assert_eq!(ALLOCS.with(Cell::get), 0, "a per-frame call allocated");
    assert!(produced > 1000, "DSP produced only {produced} frames");
    assert!(
        scratch.flash_refused > 500,
        "flash admit refused only {} frames",
        scratch.flash_refused
    );
}
