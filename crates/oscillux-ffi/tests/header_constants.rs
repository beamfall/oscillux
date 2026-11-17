// SPDX-License-Identifier: AGPL-3.0-only
//! Every `#define OSCILLUX_*` constant in `ffi/include/oscillux.h` must equal the Rust value it
//! mirrors, carry a `u` suffix exactly when that value is a `uint32_t`, and be listed here, so a
//! constant added to the header cannot go unchecked. A few behavioral checks confirm that the
//! named enumerations select what the header says they select.

use std::collections::BTreeMap;

use oscillux::cdg;
use oscillux_core::cdg as core_cdg;

use oscillux::curves::{
    oscillux_curve_create, oscillux_curve_destroy, oscillux_curve_evaluate, OscilluxCurveConfig,
    OscilluxCurveInput,
};
use oscillux::dsp::OscilluxDspFrameExt;
use oscillux::mapping::{
    oscillux_mapping_config_default, oscillux_mapping_create, oscillux_mapping_destroy,
    oscillux_mapping_process, oscillux_mapping_process_ext, OscilluxMapped,
};
use oscillux::overlay as ov;
use oscillux::packing::{
    oscillux_packer_create, oscillux_packer_destroy, oscillux_packer_pack, OscilluxUniformField,
};
use oscillux::{
    oscillux_status_string, oscillux_version, ABI_VERSION, OSCILLUX_ERR_INVALID_ARGUMENT,
    OSCILLUX_ERR_NULL, OSCILLUX_ERR_PANIC, OSCILLUX_OK, VERSION, VERSION_MAJOR, VERSION_MINOR,
    VERSION_PATCH,
};
use oscillux_core::dsp::{
    DspFrame, BEAT_LATENCY_V1_MS, BEAT_LATENCY_V2_MS, BEAT_LATENCY_V3_MS, BEAT_LATENCY_V4_MS,
    DSP_BEHAVIOR_V1, DSP_BEHAVIOR_V2, DSP_BEHAVIOR_V3, DSP_BEHAVIOR_V4, FLAG_GAP,
    FLAG_INPUT_REPLACED, FLAG_STALLED, MAX_BANDS, MAX_BEATS_PER_BAR, ONSET_GROUPS,
};
use oscillux_core::transition;
use oscillux_core::{curves, mapping, packing, reaction};
use std::ffi::CStr;

const HEADER: &str = include_str!("../../../ffi/include/oscillux.h");

/// Defines that are include guards or macros rather than values.
const NOT_VALUES: [&str; 2] = ["OSCILLUX_H", "OSCILLUX_API"];

/// A Rust constant and whether its C counterpart is unsigned.
trait Mirrored: Copy {
    const UNSIGNED: bool;
    fn as_i64(self) -> i64;
}
impl Mirrored for u32 {
    const UNSIGNED: bool = true;
    fn as_i64(self) -> i64 {
        self.into()
    }
}
impl Mirrored for i32 {
    const UNSIGNED: bool = false;
    fn as_i64(self) -> i64 {
        self.into()
    }
}
impl Mirrored for usize {
    const UNSIGNED: bool = false;
    fn as_i64(self) -> i64 {
        self.try_into().unwrap()
    }
}

fn expected<T: Mirrored>(name: &'static str, value: T) -> (&'static str, i64, bool) {
    (name, value.as_i64(), T::UNSIGNED)
}

/// Every `#define OSCILLUX_*` value-bearing line: name to value text.
fn header_defines() -> BTreeMap<&'static str, &'static str> {
    let mut defines = BTreeMap::new();
    for line in HEADER.lines() {
        let mut words = line.split_whitespace();
        if words.next() != Some("#define") {
            continue;
        }
        let name = words.next().expect("define name");
        if !name.starts_with("OSCILLUX_") || NOT_VALUES.contains(&name) {
            continue;
        }
        let value = words
            .next()
            .unwrap_or_else(|| panic!("{name} has no value"));
        assert!(
            defines.insert(name, value).is_none(),
            "{name} defined twice"
        );
    }
    defines
}

fn parse(text: &str) -> (i64, bool) {
    let inner = text.trim_start_matches('(').trim_end_matches(')');
    let (digits, unsigned) = match inner.strip_suffix('u') {
        Some(digits) => (digits, true),
        None => (inner, false),
    };
    (digits.parse().expect("integer define"), unsigned)
}

#[test]
fn every_header_constant_matches_its_rust_value() {
    let expected = [
        expected("OSCILLUX_ABI_VERSION", ABI_VERSION),
        expected("OSCILLUX_VERSION_MAJOR", VERSION_MAJOR),
        expected("OSCILLUX_VERSION_MINOR", VERSION_MINOR),
        expected("OSCILLUX_VERSION_PATCH", VERSION_PATCH),
        expected("OSCILLUX_VERSION", VERSION),
        expected("OSCILLUX_OK", OSCILLUX_OK),
        expected("OSCILLUX_ERR_NULL", OSCILLUX_ERR_NULL),
        expected(
            "OSCILLUX_ERR_INVALID_ARGUMENT",
            OSCILLUX_ERR_INVALID_ARGUMENT,
        ),
        expected("OSCILLUX_ERR_PANIC", OSCILLUX_ERR_PANIC),
        expected("OSCILLUX_DSP_MAX_BANDS", MAX_BANDS),
        expected("OSCILLUX_DSP_ONSET_GROUPS", ONSET_GROUPS),
        expected("OSCILLUX_DSP_FLAG_GAP", FLAG_GAP),
        expected("OSCILLUX_DSP_FLAG_STALLED", FLAG_STALLED),
        expected("OSCILLUX_DSP_FLAG_INPUT_REPLACED", FLAG_INPUT_REPLACED),
        expected("OSCILLUX_DSP_BEHAVIOR_V1", DSP_BEHAVIOR_V1),
        expected("OSCILLUX_DSP_BEHAVIOR_V2", DSP_BEHAVIOR_V2),
        expected("OSCILLUX_DSP_BEHAVIOR_V3", DSP_BEHAVIOR_V3),
        expected("OSCILLUX_DSP_BEHAVIOR_V4", DSP_BEHAVIOR_V4),
        expected("OSCILLUX_DSP_BEAT_LATENCY_V1_MS", BEAT_LATENCY_V1_MS),
        expected("OSCILLUX_DSP_BEAT_LATENCY_V2_MS", BEAT_LATENCY_V2_MS),
        expected("OSCILLUX_DSP_BEAT_LATENCY_V3_MS", BEAT_LATENCY_V3_MS),
        expected("OSCILLUX_DSP_BEAT_LATENCY_V4_MS", BEAT_LATENCY_V4_MS),
        expected("OSCILLUX_FLASH_MAX_GRID", oscillux_core::limiter::MAX_GRID),
        expected(
            "OSCILLUX_FLASH_RED_RULE_WCAG20",
            oscillux_core::limiter::RedRule::Wcag20 as u32,
        ),
        expected(
            "OSCILLUX_FLASH_RED_RULE_ISO_9241_391",
            oscillux_core::limiter::RedRule::Iso9241_391 as u32,
        ),
        // Palette tour (CORE-2369).
        expected(
            "OSCILLUX_PALETTE_TOUR_COUNT",
            oscillux::palette::OSCILLUX_PALETTE_TOUR_COUNT,
        ),
        expected(
            "OSCILLUX_PALETTE_TOUR_SECONDS",
            oscillux::palette::OSCILLUX_PALETTE_TOUR_SECONDS,
        ),
        // Overlay regions (OSC-OVERLAY).
        expected(
            "OSCILLUX_OVERLAY_MAX_REGIONS",
            ov::OSCILLUX_OVERLAY_MAX_REGIONS,
        ),
        expected(
            "OSCILLUX_OVERLAY_UNIFORMS_SIZE",
            ov::OSCILLUX_OVERLAY_UNIFORMS_SIZE,
        ),
        expected(
            "OSCILLUX_OVERLAY_MODE_LIGHT_TEXT",
            ov::OSCILLUX_OVERLAY_MODE_LIGHT_TEXT,
        ),
        expected(
            "OSCILLUX_OVERLAY_MODE_DARK_TEXT",
            ov::OSCILLUX_OVERLAY_MODE_DARK_TEXT,
        ),
        expected(
            "OSCILLUX_OVERLAY_MODE_DESATURATE",
            ov::OSCILLUX_OVERLAY_MODE_DESATURATE,
        ),
        expected("OSCILLUX_OVERLAY_MODE_BLUR", ov::OSCILLUX_OVERLAY_MODE_BLUR),
        expected(
            "OSCILLUX_OVERLAY_MODE_DAMP_MOTION",
            ov::OSCILLUX_OVERLAY_MODE_DAMP_MOTION,
        ),
        expected(
            "OSCILLUX_OVERLAY_MODE_DAMP_FLASH",
            ov::OSCILLUX_OVERLAY_MODE_DAMP_FLASH,
        ),
        expected("OSCILLUX_CURVE_KIND_CONSTANT", curves::KIND_CONSTANT),
        expected("OSCILLUX_CURVE_KIND_EASING", curves::KIND_EASING),
        expected("OSCILLUX_CURVE_KIND_ENVELOPE", curves::KIND_ENVELOPE),
        expected("OSCILLUX_CURVE_KIND_LFO", curves::KIND_LFO),
        expected("OSCILLUX_CURVE_UNIT_UNSPECIFIED", curves::UNIT_UNSPECIFIED),
        expected("OSCILLUX_CURVE_UNIT_SECONDS", curves::UNIT_SECONDS),
        expected("OSCILLUX_CURVE_UNIT_BEATS", curves::UNIT_BEATS),
        expected("OSCILLUX_CURVE_EASING_LINEAR", curves::EASING_LINEAR),
        expected("OSCILLUX_CURVE_EASING_IN", curves::EASING_IN),
        expected("OSCILLUX_CURVE_EASING_OUT", curves::EASING_OUT),
        expected("OSCILLUX_CURVE_EASING_IN_OUT", curves::EASING_IN_OUT),
        expected("OSCILLUX_CURVE_SHAPE_SINE", curves::SHAPE_SINE),
        expected("OSCILLUX_CURVE_SHAPE_TRIANGLE", curves::SHAPE_TRIANGLE),
        expected("OSCILLUX_CURVE_SHAPE_SQUARE", curves::SHAPE_SQUARE),
        expected("OSCILLUX_CURVE_FLAG_VALUE", curves::VALUE),
        expected("OSCILLUX_CURVE_FLAG_FROM", curves::FROM),
        expected("OSCILLUX_CURVE_FLAG_TO", curves::TO),
        expected("OSCILLUX_CURVE_FLAG_MIN", curves::MIN),
        expected("OSCILLUX_CURVE_FLAG_MAX", curves::MAX),
        expected("OSCILLUX_CURVE_FLAG_WRAP", curves::WRAP),
        expected("OSCILLUX_MAPPED_VALUE_COUNT", mapping::VALUE_COUNT),
        expected("OSCILLUX_MAPPED_SPECTRUM_BINS", mapping::SPECTRUM_BINS),
        expected("OSCILLUX_MAPPING_GROUPS", mapping::GROUPS),
        expected("OSCILLUX_MAPPING_LEVELS_ABSOLUTE", mapping::LEVELS_ABSOLUTE),
        expected("OSCILLUX_MAPPING_LEVELS_RELATIVE", mapping::LEVELS_RELATIVE),
        expected("OSCILLUX_MAPPED_AMPLITUDE", mapping::AMPLITUDE),
        expected("OSCILLUX_MAPPED_LEVEL", mapping::LEVEL),
        expected("OSCILLUX_MAPPED_BASS", mapping::BASS),
        expected("OSCILLUX_MAPPED_MID", mapping::MID),
        expected("OSCILLUX_MAPPED_TREBLE", mapping::TREBLE),
        expected("OSCILLUX_MAPPED_ONSET", mapping::ONSET),
        expected("OSCILLUX_MAPPED_BASS_IMPACT", mapping::BASS_IMPACT),
        expected("OSCILLUX_MAPPED_FLUX", mapping::FLUX),
        expected("OSCILLUX_MAPPED_CENTROID", mapping::CENTROID),
        expected("OSCILLUX_FIELD_SOURCE_MAPPED", packing::SOURCE_MAPPED),
        expected("OSCILLUX_FIELD_SOURCE_SPECTRUM", packing::SOURCE_SPECTRUM),
        expected("OSCILLUX_FIELD_SOURCE_HOST", packing::SOURCE_HOST),
        expected("OSCILLUX_PACKER_MAX_FIELDS", packing::MAX_FIELDS),
        expected("OSCILLUX_PACKER_MAX_COMPONENTS", packing::MAX_COMPONENTS),
        // Transition scheduler.
        expected(
            "OSCILLUX_TRANSITION_QUANTISE_NONE",
            transition::QUANTISE_NONE,
        ),
        expected(
            "OSCILLUX_TRANSITION_QUANTISE_BEAT",
            transition::QUANTISE_BEAT,
        ),
        expected("OSCILLUX_TRANSITION_QUANTISE_BAR", transition::QUANTISE_BAR),
        expected("OSCILLUX_TRANSITION_STATE_IDLE", transition::STATE_IDLE),
        expected(
            "OSCILLUX_TRANSITION_STATE_PRE_ROLL",
            transition::STATE_PRE_ROLL,
        ),
        expected(
            "OSCILLUX_TRANSITION_STATE_WAITING",
            transition::STATE_WAITING,
        ),
        expected(
            "OSCILLUX_TRANSITION_STATE_BLENDING",
            transition::STATE_BLENDING,
        ),
        expected("OSCILLUX_TRANSITION_STATE_DONE", transition::STATE_DONE),
        expected(
            "OSCILLUX_TRANSITION_EASING_LINEAR",
            transition::EASING_LINEAR,
        ),
        expected(
            "OSCILLUX_TRANSITION_EASING_SMOOTHSTEP",
            transition::EASING_SMOOTHSTEP,
        ),
        expected("OSCILLUX_REACTION_MAX_CAPACITY", reaction::MAX_CAPACITY),
        expected("OSCILLUX_REACTION_MAX_BEATS_PER_BAR", MAX_BEATS_PER_BAR),
        // CD+G (OSC-CDG).
        expected("OSCILLUX_CDG_PACK_SIZE", cdg::PACK_SIZE),
        expected("OSCILLUX_CDG_PACKS_PER_SECOND", cdg::PACKS_PER_SECOND),
        expected("OSCILLUX_CDG_SCREEN_WIDTH", cdg::SCREEN_WIDTH),
        expected("OSCILLUX_CDG_SCREEN_HEIGHT", cdg::SCREEN_HEIGHT),
        expected("OSCILLUX_CDG_SCREEN_PIXELS", cdg::SCREEN_PIXELS),
        expected("OSCILLUX_CDG_WINDOW_WIDTH", cdg::WINDOW_WIDTH),
        expected("OSCILLUX_CDG_WINDOW_HEIGHT", cdg::WINDOW_HEIGHT),
        expected("OSCILLUX_CDG_WINDOW_RGBA_BYTES", cdg::WINDOW_RGBA_BYTES),
        expected("OSCILLUX_CDG_KEY_NONE", cdg::KEY_NONE),
        expected(
            "OSCILLUX_CDG_KEY_TRANSPARENT_TABLE",
            cdg::KEY_TRANSPARENT_TABLE,
        ),
        expected("OSCILLUX_CDG_KEY_PRESET_COLOUR", cdg::KEY_PRESET_COLOUR),
        expected("OSCILLUX_CDG_KEY_INDEX", cdg::KEY_INDEX),
        expected("OSCILLUX_CDG_KEY_MASK", cdg::KEY_MASK),
        expected("OSCILLUX_CDG_REGION_WINDOW", cdg::REGION_WINDOW),
        expected("OSCILLUX_CDG_REGION_EDGE", cdg::REGION_EDGE),
        expected("OSCILLUX_CDG_EDGE_PIXELS", cdg::EDGE_PIXELS),
        expected("OSCILLUX_CDG_INDEX_COUNT", cdg::INDEX_COUNT),
        expected("OSCILLUX_CDG_CHANGED_SCREEN", core_cdg::CHANGED_SCREEN),
        expected("OSCILLUX_CDG_CHANGED_PALETTE", core_cdg::CHANGED_PALETTE),
        expected(
            "OSCILLUX_CDG_CHANGED_TRANSPARENCY",
            core_cdg::CHANGED_TRANSPARENCY,
        ),
        expected("OSCILLUX_CDG_CHANGED_SCROLL", core_cdg::CHANGED_SCROLL),
        expected("OSCILLUX_CDG_CHANGED_PRESETS", core_cdg::CHANGED_PRESETS),
    ];
    let mut unchecked = header_defines();
    for (name, value, unsigned) in expected {
        let text = unchecked
            .remove(name)
            .unwrap_or_else(|| panic!("{name} missing from header"));
        assert_eq!(parse(text), (value, unsigned), "{name} = {text}");
    }
    assert!(
        unchecked.is_empty(),
        "header constants without a Rust mirror in this test: {unchecked:?}"
    );
}

/// The header's release version is the Cargo package version, with no pre-release or build
/// suffix, and `oscillux_version()` packs it as the "Versions" section says.
#[test]
fn header_version_is_the_cargo_package_version() {
    let defines = header_defines();
    let part = |name| parse(defines[name]).0;
    let (major, minor, patch) = (
        part("OSCILLUX_VERSION_MAJOR"),
        part("OSCILLUX_VERSION_MINOR"),
        part("OSCILLUX_VERSION_PATCH"),
    );
    assert_eq!(
        format!("{major}.{minor}.{patch}"),
        env!("CARGO_PKG_VERSION"),
        "update the OSCILLUX_VERSION_* defines with the Cargo.toml version"
    );
    assert!(minor <= 0xff && patch <= 0xff && major <= 0xffff);
    let packed = (major << 16) | (minor << 8) | patch;
    assert_eq!(part("OSCILLUX_VERSION"), packed);
    assert_eq!(i64::from(oscillux_version()), packed);
}

#[test]
fn array_sizes_name_the_constants() {
    let mapped = OscilluxMapped {
        values: [0.0; mapping::VALUE_COUNT],
        spectrum: [0.0; mapping::SPECTRUM_BINS],
    };
    assert_eq!(mapped, oscillux_core::mapping::Mapped::ZERO);
    for field in [
        "double values[OSCILLUX_MAPPED_VALUE_COUNT];",
        "float spectrum[OSCILLUX_MAPPED_SPECTRUM_BINS];",
        "uint32_t groups[OSCILLUX_MAPPING_GROUPS][2];",
        "double spectrum[OSCILLUX_DSP_MAX_BANDS];",
        "uint32_t onset_band_groups[OSCILLUX_DSP_ONSET_GROUPS][2];",
    ] {
        assert!(HEADER.contains(field), "{field}");
    }
}

fn evaluate(config: OscilluxCurveConfig, input: OscilluxCurveInput) -> f64 {
    let mut curve = std::ptr::null_mut();
    assert_eq!(
        unsafe { oscillux_curve_create(&config, &mut curve) },
        OSCILLUX_OK
    );
    let mut out = f64::NAN;
    let status = unsafe { oscillux_curve_evaluate(curve, &input, &mut out) };
    unsafe { oscillux_curve_destroy(curve) };
    assert_eq!(status, OSCILLUX_OK);
    out
}

#[test]
fn curve_enumerations_select_what_the_header_says() {
    let input = OscilluxCurveInput {
        elapsed_seconds: 0.25,
        elapsed_beats: 1.0,
        ..OscilluxCurveInput::default()
    };
    let easing = OscilluxCurveConfig {
        kind: curves::KIND_EASING,
        unit: curves::UNIT_BEATS,
        easing: curves::EASING_IN,
        flags: curves::FROM | curves::TO,
        from: 0.0,
        to: 1.0,
        duration: 2.0,
        ..OscilluxCurveConfig::default()
    };
    // Beats read elapsed_beats (1 of 2); ease-in squares the progress.
    assert_eq!(evaluate(easing, input), 0.25);
    let seconds = OscilluxCurveConfig {
        unit: curves::UNIT_SECONDS,
        easing: curves::EASING_LINEAR,
        ..easing
    };
    assert_eq!(evaluate(seconds, input), 0.125);
    let square = OscilluxCurveConfig {
        kind: curves::KIND_LFO,
        unit: curves::UNIT_SECONDS,
        shape: curves::SHAPE_SQUARE,
        flags: curves::MIN | curves::MAX,
        min: -1.0,
        max: 1.0,
        period: 1.0,
        ..OscilluxCurveConfig::default()
    };
    assert_eq!(evaluate(square, input), 1.0);
    let late = OscilluxCurveInput {
        elapsed_seconds: 0.75,
        ..input
    };
    assert_eq!(evaluate(square, late), -1.0);
}

#[test]
fn mapped_indices_and_field_sources_select_what_the_header_says() {
    let mut config = std::mem::MaybeUninit::uninit();
    assert_eq!(
        unsafe { oscillux_mapping_config_default(config.as_mut_ptr()) },
        OSCILLUX_OK
    );
    let mut mapper = std::ptr::null_mut();
    assert_eq!(
        unsafe { oscillux_mapping_create(config.as_ptr(), &mut mapper) },
        OSCILLUX_OK
    );
    let mut frame = DspFrame::ZERO;
    frame.onset.broadband = 0.5;
    frame.onset.low = 0.25;
    let mut mapped = oscillux_core::mapping::Mapped::ZERO;
    let status = unsafe { oscillux_mapping_process(mapper, &frame, 0, &mut mapped) };
    assert_eq!(status, OSCILLUX_OK);
    assert_eq!(mapped.values[mapping::ONSET], 0.5);
    // Without descriptors FLUX keeps the onset proxy; with them it reads the spectral flux.
    assert_eq!(mapped.values[mapping::FLUX], 0.5);
    assert_eq!(mapped.values[mapping::BASS_IMPACT], 0.25);
    assert_eq!(mapped.values[mapping::AMPLITUDE], 0.0);
    let mut ext = OscilluxDspFrameExt::default();
    ext.descriptors.spectral_flux = 0.75;
    let status = unsafe { oscillux_mapping_process_ext(mapper, &frame, &ext, 0, &mut mapped) };
    unsafe { oscillux_mapping_destroy(mapper) };
    assert_eq!(status, OSCILLUX_OK);
    assert_eq!(mapped.values[mapping::ONSET], 0.5);
    assert_eq!(mapped.values[mapping::FLUX], 0.75);

    mapped.values[mapping::CENTROID] = 2.0;
    mapped.spectrum[3] = 4.0;
    let fields = [
        (packing::SOURCE_MAPPED, mapping::CENTROID as u32, 2.0f32),
        (packing::SOURCE_SPECTRUM, 3, 4.0),
        (packing::SOURCE_HOST, 1, 8.0),
    ];
    for (source, source_offset, want) in fields {
        let field = OscilluxUniformField {
            source,
            source_offset,
            components: 1,
            offset: 0,
            stride: 4,
        };
        let mut packer = std::ptr::null_mut();
        assert_eq!(
            unsafe { oscillux_packer_create(&field, 1, 4, &mut packer) },
            OSCILLUX_OK
        );
        let host = [0.0, 8.0];
        let mut out = [0u8; 4];
        let status =
            unsafe { oscillux_packer_pack(packer, &mapped, host.as_ptr(), 2, out.as_mut_ptr(), 4) };
        unsafe { oscillux_packer_destroy(packer) };
        assert_eq!(status, OSCILLUX_OK);
        assert_eq!(f32::from_le_bytes(out), want, "source {source}");
    }
}

#[test]
fn status_strings_are_static_and_cover_unknown_values() {
    let text = |status| unsafe { CStr::from_ptr(oscillux_status_string(status)) };
    assert_eq!(text(OSCILLUX_OK), c"ok");
    assert_eq!(text(OSCILLUX_ERR_NULL), c"null pointer argument");
    assert_eq!(text(OSCILLUX_ERR_INVALID_ARGUMENT), c"invalid argument");
    assert_eq!(
        text(OSCILLUX_ERR_PANIC),
        c"internal panic; destroy the handle"
    );
    for unknown in [1, -4, i32::MIN, i32::MAX] {
        assert_eq!(text(unknown), c"unknown status");
    }
    // The same pointer every time: the strings are static, never allocated per call.
    assert_eq!(
        oscillux_status_string(OSCILLUX_OK),
        oscillux_status_string(OSCILLUX_OK)
    );
}

/// The header's threading section: every handle may move between threads, and the handles whose
/// per-frame call takes a `const` pointer (curve evaluate, packer pack) may be shared.
#[test]
fn handle_thread_safety_matches_the_threading_section() {
    fn movable<T: Send>() {}
    fn shareable<T: Sync>() {}
    movable::<oscillux::dsp::OscilluxDsp>();
    movable::<oscillux::limiter::OscilluxLimiter>();
    movable::<oscillux::limiter::OscilluxFlashAnalyzer>();
    movable::<oscillux::curves::OscilluxCurve>();
    movable::<oscillux::governor::OscilluxGovernor>();
    movable::<oscillux::mapping::OscilluxMapper>();
    movable::<oscillux::packing::OscilluxPacker>();
    shareable::<oscillux::curves::OscilluxCurve>();
    shareable::<oscillux::packing::OscilluxPacker>();
}
