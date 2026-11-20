// SPDX-License-Identifier: AGPL-3.0-only
//! Compile the actual C header against Rust's field types, sizes, alignments and offsets, with the
//! host C compiler and with `clang --target` for 32-bit and Windows targets the host cannot run.

use oscillux::beatgrid::{
    OscilluxBeatGridBeat, OscilluxBeatGridClock, OscilluxBeatGridConfig, OscilluxBeatGridInfo,
};
use oscillux::cdg::OscilluxCdgState;
use oscillux::curves::{OscilluxCurveConfig, OscilluxCurveInput};
use oscillux::dsp::{OscilluxDspFrameExt, OscilluxDspPushResult, OscilluxDspVersionedConfig};
use oscillux::governor::{OscilluxGovernorConfig, OscilluxGovernorStats};
use oscillux::limiter::{
    OscilluxFlashColor, OscilluxFlashConfig, OscilluxFlashRegion, OscilluxFlashReport,
    OscilluxLimiterFrame, OscilluxLimiterPolicy,
};
use oscillux::limiter::{OscilluxFlashOverlay, OscilluxFlashOverlayReport};
use oscillux::mapping::{OscilluxMapped, OscilluxMappingConfig};
use oscillux::overlay::{OscilluxOverlayConfig, OscilluxOverlayRegion};
use oscillux::packing::OscilluxUniformField;
use oscillux::reaction::{OscilluxBeatClock, OscilluxReaction, OscilluxReactionConfig};
use oscillux::transition::{
    OscilluxTransitionClock, OscilluxTransitionConfig, OscilluxTransitionStatus,
};
use oscillux::window_governor::{
    OscilluxWindowGovernorConfig, OscilluxWindowGovernorResult, OscilluxWindowGovernorSample,
};
use oscillux_core::dsp::{
    Beat, Descriptors, DspConfig, DspFrame, Levels, Onset, MAX_BANDS, ONSET_GROUPS,
};
use std::fmt::Write;
use std::mem::{align_of, offset_of, size_of};
use std::path::PathBuf;
use std::process::Command;

/// A C target the header is checked for. `triple: None` is the host `cc`; any other is
/// `clang --target=<triple> -ffreestanding`, which needs only clang's builtin headers.
#[derive(Clone, Copy)]
struct Target {
    triple: Option<&'static str>,
    pointer: usize,
}

const HOST: Target = Target {
    triple: None,
    pointer: size_of::<usize>(),
};

/// Cross targets: armv7 Android and wasm32 are the 32-bit shipped ABIs; Windows is not built on
/// this host, so this is its only layout check here.
const CROSS: [Target; 4] = [
    Target {
        triple: Some("armv7-linux-androideabi21"),
        pointer: 4,
    },
    Target {
        triple: Some("wasm32-unknown-unknown"),
        pointer: 4,
    },
    Target {
        triple: Some("x86_64-pc-windows-msvc"),
        pointer: 8,
    },
    Target {
        triple: Some("aarch64-pc-windows-msvc"),
        pointer: 8,
    },
];

/// The repr(C) size and alignment of a field type on `target`. Only the pointer width differs
/// between the targets above: u64, i64 and f64 are 8-byte aligned in each of their C ABIs, and
/// clang fails the static asserts if that is wrong. On the host the model is checked against
/// rustc.
trait Field {
    fn size_align(target: Target) -> (usize, usize);
}

macro_rules! primitive {
    ($($ty:ty: $size:literal),*) => {$(
        impl Field for $ty {
            fn size_align(_: Target) -> (usize, usize) {
                ($size, $size)
            }
        }
    )*};
}
primitive!(u32: 4, f32: 4, u64: 8, i64: 8, f64: 8);

impl Field for usize {
    fn size_align(target: Target) -> (usize, usize) {
        (target.pointer, target.pointer)
    }
}

impl<T: Field, const N: usize> Field for [T; N] {
    fn size_align(target: Target) -> (usize, usize) {
        let (size, align) = T::size_align(target);
        (size * N, align)
    }
}

impl Field for Onset {
    fn size_align(target: Target) -> (usize, usize) {
        let (_, size, align) = repr_c(&[f64::size_align(target); 4]);
        (size, align)
    }
}

impl Field for Descriptors {
    fn size_align(target: Target) -> (usize, usize) {
        let (_, size, align) = repr_c(&[f64::size_align(target); 6]);
        (size, align)
    }
}

impl Field for Beat {
    fn size_align(target: Target) -> (usize, usize) {
        let (u, d) = (u32::size_align(target), f64::size_align(target));
        let (_, size, align) = repr_c(&[d, d, d, d, u, u, u, u]);
        (size, align)
    }
}

impl Field for Levels {
    fn size_align(target: Target) -> (usize, usize) {
        let u = u32::size_align(target);
        let groups = <[f64; ONSET_GROUPS]>::size_align(target);
        let bands = <[f64; MAX_BANDS]>::size_align(target);
        let (_, size, align) = repr_c(&[u, u, groups, groups, bands]);
        (size, align)
    }
}

/// `OscilluxMapped` embedded in `OscilluxReaction`; its own `layout!` checks its members.
impl Field for OscilluxMapped {
    fn size_align(target: Target) -> (usize, usize) {
        let values = <[f64; 9]>::size_align(target);
        let spectrum = <[f32; 64]>::size_align(target);
        let (_, size, align) = repr_c(&[values, spectrum]);
        (size, align)
    }
}

/// `OscilluxDspConfig` embedded in `OscilluxDspVersionedConfig`; its own `layout!` checks these
/// members against the header, and the host model check catches any drift from rustc.
impl Field for DspConfig {
    fn size_align(target: Target) -> (usize, usize) {
        let (u, d) = (u32::size_align(target), f64::size_align(target));
        let groups = <[[u32; 2]; ONSET_GROUPS]>::size_align(target);
        let (_, size, align) = repr_c(&[u, u, u, u, d, d, d, d, d, d, d, d, d, d, groups, u]);
        (size, align)
    }
}

/// Field offsets, size and alignment of a repr(C) struct with the given field layouts.
fn repr_c(fields: &[(usize, usize)]) -> (Vec<usize>, usize, usize) {
    let (mut offsets, mut end, mut align) = (Vec::new(), 0usize, 1usize);
    for &(size, field_align) in fields {
        let offset = end.next_multiple_of(field_align);
        offsets.push(offset);
        end = offset + size;
        align = align.max(field_align);
    }
    (offsets, end.next_multiple_of(align), align)
}

struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn layout_assertions(target: Target) -> String {
    let mut code = String::new();
    writeln!(
        code,
        "_Static_assert(sizeof(void *) == {}, \"pointer width\");",
        target.pointer
    )
    .unwrap();
    macro_rules! layout {
        ($rust:ident, $c:literal, {$($field:ident: $ty:ty => $pointer:literal),* $(,)?}) => {{
            let _: fn(&$rust) = |value| {
                let $rust { $($field: _,)* } = value;
            };
            let fields = [$(<$ty as Field>::size_align(target)),*];
            let (offsets, size, align) = repr_c(&fields);
            if target.triple.is_none() {
                // The model must reproduce rustc's layout wherever rustc's layout is observable.
                assert_eq!((size, align), (size_of::<$rust>(), align_of::<$rust>()), "{} model", $c);
                assert_eq!(offsets, [$(offset_of!($rust, $field)),*], "{} offsets model", $c);
                assert_eq!(fields.map(|f| f.0), [$(size_of::<$ty>()),*], "{} field sizes model", $c);
            }
            writeln!(code, "_Static_assert(sizeof({}) == {}, \"size\");", $c, size).unwrap();
            writeln!(code, "_Static_assert(_Alignof({}) == {}, \"alignment\");", $c, align).unwrap();
            let mut index = 0;
            $(
                // A Rust field-type change must update the C expectation as well.
                let _: fn(&$rust) -> &$ty = |value| &value.$field;
                let field = stringify!($field);
                writeln!(code, "_Static_assert(offsetof({}, {}) == {}, \"offset {}\");",
                    $c, field, offsets[index], field).unwrap();
                writeln!(code, "_Static_assert(sizeof((({}*)0)->{}) == {}, \"field size {}\");",
                    $c, field, fields[index].0, field).unwrap();
                writeln!(code, "_Static_assert(_Generic(&(({}*)0)->{}, {}: 1, default: 0), \"field type {}\");",
                    $c, field, $pointer, field).unwrap();
                index += 1;
            )*
            let _ = index;
        }};
    }
    layout!(DspConfig, "OscilluxDspConfig", {
        sample_rate_hz: u32 => "uint32_t*",
        fft_window_samples: u32 => "uint32_t*",
        hop_samples: u32 => "uint32_t*",
        spectrum_bands: u32 => "uint32_t*",
        spectrum_min_hz: f64 => "double*",
        spectrum_max_hz: f64 => "double*",
        db_floor: f64 => "double*",
        ballistics_attack_ms: f64 => "double*",
        ballistics_release_ms: f64 => "double*",
        rms_window_ms: f64 => "double*",
        loudness_reference_lufs: f64 => "double*",
        rms_floor: f64 => "double*",
        onset_peak_decay: f64 => "double*",
        onset_peak_floor: f64 => "double*",
        onset_band_groups: [[u32; 2]; ONSET_GROUPS] => "uint32_t(*)[OSCILLUX_DSP_ONSET_GROUPS][2]",
        gap_tolerance_hops: u32 => "uint32_t*",
    });
    layout!(Onset, "OscilluxDspOnset", {
        broadband: f64 => "double*", low: f64 => "double*",
        mid: f64 => "double*", high: f64 => "double*",
    });
    layout!(DspFrame, "OscilluxDspFrame", {
        sequence: u64 => "uint64_t*", flags: u32 => "uint32_t*",
        band_count: u32 => "uint32_t*", media_time_ms: f64 => "double*",
        rms: f64 => "double*", loudness_db: f64 => "double*",
        onset: Onset => "OscilluxDspOnset*",
        spectrum: [f64; MAX_BANDS] => "double(*)[OSCILLUX_DSP_MAX_BANDS]",
    });
    layout!(OscilluxDspPushResult, "OscilluxDspPushResult", {
        consumed: usize => "size_t*", produced: usize => "size_t*",
    });
    layout!(Beat, "OscilluxDspBeat", {
        tempo_bpm: f64 => "double*", beat_phase: f64 => "double*",
        bar_phase: f64 => "double*", confidence: f64 => "double*",
        beat: u32 => "uint32_t*", downbeat: u32 => "uint32_t*",
        beat_in_bar: u32 => "uint32_t*", reserved: u32 => "uint32_t*",
    });
    layout!(Levels, "OscilluxDspLevels", {
        band_count: u32 => "uint32_t*", reserved: u32 => "uint32_t*",
        relative_groups: [f64; ONSET_GROUPS] => "double(*)[OSCILLUX_DSP_ONSET_GROUPS]",
        absolute_groups: [f64; ONSET_GROUPS] => "double(*)[OSCILLUX_DSP_ONSET_GROUPS]",
        relative_bands: [f64; MAX_BANDS] => "double(*)[OSCILLUX_DSP_MAX_BANDS]",
    });
    layout!(OscilluxDspVersionedConfig, "OscilluxDspVersionedConfig", {
        struct_size: u32 => "uint32_t*",
        config: DspConfig => "OscilluxDspConfig*",
        behavior_version: u32 => "uint32_t*",
        reserved: u32 => "uint32_t*",
    });
    layout!(Descriptors, "OscilluxDspDescriptors", {
        momentary_lufs: f64 => "double*", short_term_lufs: f64 => "double*",
        width: f64 => "double*", balance: f64 => "double*",
        centroid_hz: f64 => "double*", spectral_flux: f64 => "double*",
    });
    layout!(OscilluxDspFrameExt, "OscilluxDspFrameExt", {
        struct_size: u32 => "uint32_t*",
        reserved: u32 => "uint32_t*",
        descriptors: Descriptors => "OscilluxDspDescriptors*",
        beat: Beat => "OscilluxDspBeat*",
        levels: Levels => "OscilluxDspLevels*",
    });
    layout!(OscilluxCurveConfig, "OscilluxCurveConfig", {
        kind: u32 => "uint32_t*",
        unit: u32 => "uint32_t*",
        easing: u32 => "uint32_t*",
        shape: u32 => "uint32_t*",
        flags: u32 => "uint32_t*",
        value: f64 => "double*",
        from: f64 => "double*",
        to: f64 => "double*",
        duration: f64 => "double*",
        attack: f64 => "double*",
        release: f64 => "double*",
        release_at: f64 => "double*",
        period: f64 => "double*",
        phase: f64 => "double*",
        min: f64 => "double*",
        max: f64 => "double*",
        smoothing_seconds: f64 => "double*",
    });
    layout!(OscilluxCurveInput, "OscilluxCurveInput", {
        elapsed_seconds: f64 => "double*",
        elapsed_beats: f64 => "double*",
        beat_phase: f64 => "double*",
        delta_seconds: f64 => "double*",
        previous_value: f64 => "double*",
        has_previous: u32 => "uint32_t*",
    });
    layout!(OscilluxGovernorConfig, "OscilluxGovernorConfig", {
        target_ms: f64 => "double*",
        ema_alpha: f64 => "double*",
        pause_gap_ms: f64 => "double*",
        sample_cap_factor: f64 => "double*",
        refresh_drift: f64 => "double*",
        refresh_floor_ms: f64 => "double*",
        demote_factor: f64 => "double*",
        promote_refresh_factor: f64 => "double*",
        promote_target_factor: f64 => "double*",
        demote_frames: u32 => "uint32_t*",
        promote_frames: u32 => "uint32_t*",
        settle_frames: u32 => "uint32_t*",
        max_level: u32 => "uint32_t*",
        initial_level: u32 => "uint32_t*",
    });
    layout!(OscilluxGovernorStats, "OscilluxGovernorStats", {
        ema_ms: f64 => "double*",
        refresh_ms: f64 => "double*",
        level: u32 => "uint32_t*",
        has_ema: u32 => "uint32_t*",
    });
    layout!(OscilluxWindowGovernorConfig, "OscilluxWindowGovernorConfig", {
        struct_size: u32 => "uint32_t*",
        demote_windows: u32 => "uint32_t*",
        promote_windows: u32 => "uint32_t*",
        demote_budget_fraction: f64 => "double*",
        promote_budget_fraction: f64 => "double*",
        cooldown_s: f64 => "double*",
    });
    layout!(OscilluxWindowGovernorSample, "OscilluxWindowGovernorSample", {
        p95_ms: f64 => "double*",
        p99_ms: f64 => "double*",
        interval_ms: f64 => "double*",
        promotion_budget_ms: f64 => "double*",
        now_s: f64 => "double*",
        has_p95: u32 => "uint32_t*",
        has_p99: u32 => "uint32_t*",
        starved: u32 => "uint32_t*",
        dropping: u32 => "uint32_t*",
    });
    layout!(OscilluxWindowGovernorResult, "OscilluxWindowGovernorResult", {
        decision: u32 => "uint32_t*",
        over_budget: u32 => "uint32_t*",
        over_budget_streak: u32 => "uint32_t*",
        promotion_streak: u32 => "uint32_t*",
        stable_streak: u32 => "uint32_t*",
    });
    layout!(OscilluxMappingConfig, "OscilluxMappingConfig", {
        loudness_reference: f64 => "double*",
        db_floor: f64 => "double*",
        hop_seconds: f64 => "double*",
        release_seconds: f64 => "double*",
        centroid_floor: f64 => "double*",
        groups: [[u32; 2]; 3] => "uint32_t(*)[3][2]",
    });
    layout!(OscilluxMapped, "OscilluxMapped", {
        values: [f64; 9] => "double(*)[9]",
        spectrum: [f32; 64] => "float(*)[64]",
    });
    layout!(OscilluxReactionConfig, "OscilluxReactionConfig", {
        struct_size: u32 => "uint32_t*",
        capacity: u32 => "uint32_t*",
        output_latency_ms: f64 => "double*",
        display_latency_ms: f64 => "double*",
        render_ahead_ms: f64 => "double*",
        analysis_latency_ms: f64 => "double*",
        onset_latency_ms: f64 => "double*",
        onset_release_ms: f64 => "double*",
        bass_impact_release_ms: f64 => "double*",
        flux_release_ms: f64 => "double*",
        pulse_decay_ms: f64 => "double*",
        pulse_rise_ms: f64 => "double*",
        phase_lock_gain: f64 => "double*",
    });
    layout!(OscilluxBeatClock, "OscilluxBeatClock", {
        media_time_ms: f64 => "double*",
        tempo_bpm: f64 => "double*",
        beat_phase: f64 => "double*",
        bar_phase: f64 => "double*",
        beat_index: i64 => "int64_t*",
        beats_per_bar: u32 => "uint32_t*",
        reserved: u32 => "uint32_t*",
    });
    layout!(OscilluxReaction, "OscilluxReaction", {
        mapped: OscilluxMapped => "OscilluxMapped*",
        beat: f64 => "double*",
        downbeat: f64 => "double*",
        beat_phase: f64 => "double*",
        bar_phase: f64 => "double*",
        tempo_bpm: f64 => "double*",
        confidence: f64 => "double*",
        beat_count: i64 => "int64_t*",
        beat_in_bar: u32 => "uint32_t*",
        locked: u32 => "uint32_t*",
    });
    layout!(OscilluxUniformField, "OscilluxUniformField", {
        source: u32 => "uint32_t*",
        source_offset: u32 => "uint32_t*",
        components: u32 => "uint32_t*",
        offset: u32 => "uint32_t*",
        stride: u32 => "uint32_t*",
    });
    layout!(OscilluxLimiterPolicy, "OscilluxLimiterPolicy", {
        max_flash_hz: f64 => "double*", max_luminance_delta: f64 => "double*",
        max_flash_area: f64 => "double*", max_red_flashes: u32 => "uint32_t*",
        strobe_banned: u32 => "uint32_t*",
    });
    layout!(OscilluxLimiterFrame, "OscilluxLimiterFrame", {
        time_ms: f64 => "double*", broadband: f64 => "double*",
        low: f64 => "double*", mid: f64 => "double*", high: f64 => "double*",
        red: f64 => "double*", area: f64 => "double*",
    });
    layout!(OscilluxFlashConfig, "OscilluxFlashConfig", {
        struct_size: u32 => "uint32_t*", columns: u32 => "uint32_t*", rows: u32 => "uint32_t*",
        max_red_flashes: u32 => "uint32_t*", field_width: f64 => "double*",
        field_height: f64 => "double*", max_field_area: f64 => "double*",
        max_flash_hz: f64 => "double*", red_rule: u32 => "uint32_t*",
        reserved: u32 => "uint32_t*",
    });
    layout!(OscilluxFlashRegion, "OscilluxFlashRegion", {
        luminance: f64 => "double*", red: f64 => "double*",
    });
    layout!(OscilluxFlashColor, "OscilluxFlashColor", {
        r: f64 => "double*", g: f64 => "double*", b: f64 => "double*",
    });
    layout!(OscilluxFlashReport, "OscilluxFlashReport", {
        time_ms: f64 => "double*", flashes_in_window: f64 => "double*",
        red_flashes_in_window: f64 => "double*", admitted: u32 => "uint32_t*",
        general_transition: u32 => "uint32_t*", red_transition: u32 => "uint32_t*",
        general_regions: u32 => "uint32_t*", red_regions: u32 => "uint32_t*",
        exceeds: u32 => "uint32_t*",
    });
    // Transition scheduler.
    layout!(OscilluxTransitionConfig, "OscilluxTransitionConfig", {
        struct_size: u32 => "uint32_t*", easing: u32 => "uint32_t*",
        beats_per_bar: u32 => "uint32_t*", auto_advance_bars: u32 => "uint32_t*",
        duration_beats: f64 => "double*", fallback_seconds: f64 => "double*",
        pre_roll_seconds: f64 => "double*", min_confidence: f64 => "double*",
    });
    layout!(OscilluxTransitionClock, "OscilluxTransitionClock", {
        time_seconds: f64 => "double*", beat_phase: f64 => "double*",
        bar_phase: f64 => "double*", tempo_bpm: f64 => "double*",
        confidence: f64 => "double*",
    });
    layout!(OscilluxTransitionStatus, "OscilluxTransitionStatus", {
        progress: f64 => "double*", request_seconds: f64 => "double*",
        start_seconds: f64 => "double*", end_seconds: f64 => "double*",
        state: u32 => "uint32_t*", quantise: u32 => "uint32_t*",
        auto_requested: u32 => "uint32_t*", reserved: u32 => "uint32_t*",
    });
    layout!(OscilluxBeatGridConfig, "OscilluxBeatGridConfig", {
        struct_size: u32 => "uint32_t*", sample_rate_hz: u32 => "uint32_t*",
        channels: u32 => "uint32_t*", beats_per_bar: u32 => "uint32_t*",
        min_bpm: f64 => "double*", max_bpm: f64 => "double*",
    });
    layout!(OscilluxBeatGridInfo, "OscilluxBeatGridInfo", {
        beat_count: u64 => "uint64_t*", bar_count: u64 => "uint64_t*",
        tempo_bpm: f64 => "double*", confidence: f64 => "double*",
        duration_seconds: f64 => "double*", beats_per_bar: u32 => "uint32_t*",
        reserved: u32 => "uint32_t*",
    });
    layout!(OscilluxBeatGridBeat, "OscilluxBeatGridBeat", {
        time_seconds: f64 => "double*", tempo_bpm: f64 => "double*",
        beat_in_bar: u32 => "uint32_t*", bar_index: u32 => "uint32_t*",
    });
    layout!(OscilluxBeatGridClock, "OscilluxBeatGridClock", {
        beat_phase: f64 => "double*", bar_phase: f64 => "double*",
        tempo_bpm: f64 => "double*", beat_index: i64 => "int64_t*",
        beat_in_bar: u32 => "uint32_t*", reserved: u32 => "uint32_t*",
    });
    // Overlay regions (OSC-OVERLAY).
    layout!(OscilluxOverlayRegion, "OscilluxOverlayRegion", {
        x: f64 => "double*", y: f64 => "double*", width: f64 => "double*",
        height: f64 => "double*", corner_radius: f64 => "double*", feather: f64 => "double*",
        strength: f64 => "double*", mode: u32 => "uint32_t*", reserved: u32 => "uint32_t*",
    });
    layout!(OscilluxOverlayConfig, "OscilluxOverlayConfig", {
        struct_size: u32 => "uint32_t*", reduced_motion: u32 => "uint32_t*",
        premultiplied_alpha: u32 => "uint32_t*", output_levels: u32 => "uint32_t*",
        viewport_width: f64 => "double*", viewport_height: f64 => "double*",
        contrast_ratio: f64 => "double*", intensity: f64 => "double*",
        frame_interval_ms: f64 => "double*", alpha: f64 => "double*",
    });
    layout!(OscilluxFlashOverlay, "OscilluxFlashOverlay", {
        struct_size: u32 => "uint32_t*", reserved: u32 => "uint32_t*",
        luminance_change: f64 => "double*", darker_limit: f64 => "double*",
        max_flash_hz: f64 => "double*", max_area: f64 => "double*",
    });
    layout!(OscilluxFlashOverlayReport, "OscilluxFlashOverlayReport", {
        struct_size: u32 => "uint32_t*", active: u32 => "uint32_t*",
        transition: u32 => "uint32_t*", regions: u32 => "uint32_t*", cells: u32 => "uint32_t*",
        exceeds: u32 => "uint32_t*", flashes_in_window: f64 => "double*",
    });
    // CD+G (OSC-CDG).
    layout!(OscilluxCdgState, "OscilluxCdgState", {
        struct_size: u32 => "uint32_t*", h_offset: u32 => "uint32_t*",
        v_offset: u32 => "uint32_t*", window_x: u32 => "uint32_t*", window_y: u32 => "uint32_t*",
        preset_colour: u32 => "uint32_t*", border_colour: u32 => "uint32_t*",
        changes: u32 => "uint32_t*", dirty_x0: u32 => "uint32_t*", dirty_y0: u32 => "uint32_t*",
        dirty_x1: u32 => "uint32_t*", dirty_y1: u32 => "uint32_t*",
        palette: [u32; 16] => "uint32_t(*)[16]", transparent: [u32; 16] => "uint32_t(*)[16]",
        applied: u64 => "uint64_t*", pack_count: u64 => "uint64_t*",
    });
    code
}

fn compiles(scratch: &Scratch, target: Target, header: &str, assertions: &str) -> bool {
    let source = scratch.0.join("layout.c");
    std::fs::write(&source, format!("{header}\n{assertions}")).unwrap();
    let mut command = match target.triple {
        None => Command::new("cc"),
        Some(triple) => {
            let mut clang = Command::new("clang");
            clang
                .arg(format!("--target={triple}"))
                .arg("-ffreestanding");
            clang
        }
    };
    let output = command
        .args(["-std=c11", "-Werror", "-fsyntax-only"])
        .arg(source)
        .output()
        .expect("C compiler (cc, and clang for cross targets) required for ABI layout test");
    if !output.status.success() {
        eprintln!(
            "{}: {}",
            target.triple.unwrap_or("host cc"),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    output.status.success()
}

#[test]
fn header_layout_matches_rust_and_rejects_drift() {
    let scratch =
        Scratch(std::env::temp_dir().join(format!("oscillux-layout-{}", std::process::id())));
    std::fs::create_dir(&scratch.0).unwrap();
    let header = include_str!("../../../ffi/include/oscillux.h");
    // Host first: it validates the layout model that the cross targets rely on.
    for target in std::iter::once(HOST).chain(CROSS) {
        let name = target.triple.unwrap_or("host cc");
        let assertions = layout_assertions(target);
        assert!(
            compiles(&scratch, target, header, &assertions),
            "{name}: header layout/type mismatch"
        );
        for mutated in [
            header.replace("uint64_t sequence", "double sequence"),
            header.replace("double rms;", "float rms;"),
            header.replace("size_t consumed;", "ptrdiff_t consumed;"),
            header.replace("uint32_t flags;", "uint64_t flags;"),
            header.replace(
                "double spectrum[OSCILLUX_DSP_MAX_BANDS]",
                "double spectrum[OSCILLUX_DSP_MAX_BANDS + 1]",
            ),
        ] {
            assert!(
                !compiles(&scratch, target, &mutated, &assertions),
                "{name}: ABI drift was not detected"
            );
        }
    }
}

#[test]
fn layout_model_differs_on_32_bit_targets() {
    // The cross-target assertions are not a copy of the host numbers.
    let host = layout_assertions(HOST);
    for target in CROSS.iter().filter(|t| t.pointer == 4) {
        let cross = layout_assertions(*target);
        assert!(
            cross.contains("sizeof(OscilluxDspPushResult) == 8"),
            "{cross}"
        );
        assert_ne!(host, cross);
    }
}
