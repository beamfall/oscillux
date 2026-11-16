// SPDX-License-Identifier: AGPL-3.0-only
//! Flash measurement from per-region luminance and color: the WCAG 2.3.1 general flash rule
//! and a selectable red flash rule (WCAG 2.0 saturated red, or the ISO 9241-391 chromaticity
//! rule of WCAG 2.2) over a grid of regions, with a sliding window that stands in for a
//! 10-degree field.
//!
//! The model is specified in `conformance/limiter/README.md` ("Region flash analyzer").

use super::overlay::{FlashOverlay, FlashOverlayError, FlashOverlayReport, OverlayState};
use super::{MAX_CREDITED_GAP_MS, WINDOW_MS};
use crate::overlay::{flash_mask, OverlayRegion};

/// Most regions along either grid axis.
pub const MAX_GRID: u32 = 16;

/// Most regions in a grid.
pub(super) const MAX_REGIONS: usize = (MAX_GRID * MAX_GRID) as usize;

/// Screen-level transitions a window holds before it saturates. A saturated window still
/// reports more transitions than any valid config allows.
const RING_CAPACITY: usize = 256;

/// Relative-luminance change at or above which a change is one half of a general flash.
pub const LUMINANCE_CHANGE: f64 = 0.1;

/// A general-flash change counts only while its darker image is below this relative luminance.
pub const DARKER_LIMIT: f64 = 0.8;

/// Saturated-red change above which a change is one half of a red flash: a change of 20 in
/// `(R - G - B) * 320`, normalized by 320.
pub const RED_CHANGE: f64 = 0.0625;

/// `R / (R + G + B)` at or above which a color is a saturated red.
pub const RED_SATURATION: f64 = 0.8;

/// CIE 1976 UCS (u', v') distance above which a change to or from a saturated red is one half
/// of a red flash under [`RedRule::Iso9241_391`].
pub const RED_CHROMATICITY_CHANGE: f64 = 0.2;

/// One region's measurement for one frame.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RegionSample {
    /// Mean relative luminance of the region, `0..=1`.
    pub luminance: f64,
    /// Saturated-red level, `0..=1`: `(R - G) - B` of the region's mean linear color when
    /// `R / (R + G + B)` is at least [`RED_SATURATION`], and 0 otherwise.
    pub red: f64,
}

impl RegionSample {
    /// Measures a region from its mean linear (not sRGB-encoded) color, each channel `0..=1`.
    pub fn from_linear_rgb(r: f64, g: f64, b: f64) -> Result<RegionSample, RegionError> {
        let color = RegionColor { r, g, b };
        if !color.is_valid() {
            return Err(RegionError::InvalidSample);
        }
        Ok(color.sample())
    }

    fn is_valid(&self) -> bool {
        [self.luminance, self.red]
            .iter()
            .all(|v| v.is_finite() && (0.0..=1.0).contains(v))
    }
}

/// One region's mean linear (not sRGB-encoded) color for one frame, each channel `0..=1`: the
/// input of [`FlashAnalyzer::measure_rgb`] and [`FlashAnalyzer::admit_rgb`].
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RegionColor {
    /// Linear red, `0..=1`.
    pub r: f64,
    /// Linear green, `0..=1`.
    pub g: f64,
    /// Linear blue, `0..=1`.
    pub b: f64,
}

impl RegionColor {
    fn is_valid(&self) -> bool {
        [self.r, self.g, self.b]
            .iter()
            .all(|v| v.is_finite() && (0.0..=1.0).contains(v))
    }

    /// Luminance and WCAG 2.0 saturated-red level of a valid color.
    fn sample(&self) -> RegionSample {
        let (r, g, b) = (self.r, self.g, self.b);
        let luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b).min(1.0);
        let sum = r + g + b;
        let red = if sum > 0.0 && r / sum >= RED_SATURATION {
            (r - g) - b
        } else {
            0.0
        };
        RegionSample { luminance, red }
    }

    /// CIE 1976 UCS chromaticity of a valid color, with the linear-sRGB-to-XYZ matrix of the
    /// WCAG 2.2 Understanding page for 2.3.1. A color whose `X + 15Y + 3Z` is 0 (black) has none.
    fn chromaticity(&self) -> Chromaticity {
        let (r, g, b) = (self.r, self.g, self.b);
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b;
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b;
        let d = x + 15.0 * y + 3.0 * z;
        if d == 0.0 {
            return Chromaticity::BLACK;
        }
        Chromaticity {
            u: 4.0 * x / d,
            v: 9.0 * y / d,
            black: false,
            saturated: r / ((r + g) + b) >= RED_SATURATION,
        }
    }
}

/// Which definition of a red flash a [`FlashAnalyzer`] applies.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum RedRule {
    /// WCAG 2.0 (Harding and Binnie): a change of more than 20 in `(R - G - B) * 320`
    /// (negatives taken as 0) where `R / (R + G + B)` is at least 0.8. Measured from
    /// [`RegionSample::red`], so both input paths apply it.
    #[default]
    Wcag20 = 0,
    /// WCAG 2.2 note 3, after ISO 9241-391: a change to or from a state with
    /// `R / (R + G + B)` at least 0.8 whose states differ by more than 0.2 in the CIE 1976 UCS
    /// (u', v') diagram. Needs chromaticity, so only the `_rgb` input path accepts frames.
    Iso9241_391 = 1,
}

impl RedRule {
    /// The rule a C `red_rule` value names.
    pub fn from_u32(value: u32) -> Result<RedRule, FlashConfigError> {
        match value {
            0 => Ok(RedRule::Wcag20),
            1 => Ok(RedRule::Iso9241_391),
            _ => Err(FlashConfigError::RedRule),
        }
    }
}

/// Grid, viewing geometry and flash ceilings for a [`FlashAnalyzer`].
///
/// The grid and the field are measurements of the host's output, not ceilings. The three
/// ceilings may be tightened below [`FlashConfig::DEFAULT`] but never loosened.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FlashConfig {
    /// Fraction of the viewport width a 10-degree visual field covers, `(0, 1]`.
    pub field_width: f64,
    /// Fraction of the viewport height a 10-degree visual field covers, `(0, 1]`.
    pub field_height: f64,
    /// Fraction of a field at or below which concurrent flashing is not a flash, `(0, 0.25]`.
    pub max_field_area: f64,
    /// Most general flashes allowed in any one-second window, `(0, 3]`.
    pub max_flash_hz: f64,
    /// Regions per row, `1..=MAX_GRID`.
    pub columns: u32,
    /// Regions per column, `1..=MAX_GRID`.
    pub rows: u32,
    /// Most red flashes allowed in any one-second window, `0..=3`.
    pub max_red_flashes: u32,
    /// The red flash definition; [`RedRule::Wcag20`] by default.
    pub red_rule: RedRule,
}

/// Why a [`FlashConfig`] was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FlashConfigError {
    /// `columns` or `rows` was outside `1..=MAX_GRID`.
    Grid,
    /// `field_width` or `field_height` was not a number in `(0, 1]`.
    Field,
    /// `max_field_area` was not a number in `(0, 0.25]`.
    FieldArea,
    /// `max_flash_hz` was not a number in `(0, 3]`.
    FlashHz,
    /// `max_red_flashes` was above 3.
    RedFlashes,
    /// A red rule value named no [`RedRule`] (only [`RedRule::from_u32`] refuses).
    RedRule,
}

impl core::fmt::Display for FlashConfigError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "invalid flash analyzer config: {self:?}")
    }
}
impl core::error::Error for FlashConfigError {}

impl FlashConfig {
    /// A 16 by 16 grid, the WCAG 341 by 256 pixel field on a 1024 by 768 screen (a third of
    /// each axis), and the loosest ceilings.
    pub const DEFAULT: FlashConfig = FlashConfig {
        field_width: 1.0 / 3.0,
        field_height: 1.0 / 3.0,
        max_field_area: 0.25,
        max_flash_hz: 3.0,
        columns: MAX_GRID,
        rows: MAX_GRID,
        max_red_flashes: 3,
        red_rule: RedRule::Wcag20,
    };

    /// Refuses a grid or field out of range, or a ceiling looser than [`FlashConfig::DEFAULT`].
    pub fn validate(&self) -> Result<(), FlashConfigError> {
        let max = Self::DEFAULT;
        if !(1..=MAX_GRID).contains(&self.columns) || !(1..=MAX_GRID).contains(&self.rows) {
            return Err(FlashConfigError::Grid);
        }
        if !in_unit(self.field_width, 1.0) || !in_unit(self.field_height, 1.0) {
            return Err(FlashConfigError::Field);
        }
        if !in_unit(self.max_field_area, max.max_field_area) {
            return Err(FlashConfigError::FieldArea);
        }
        if !in_unit(self.max_flash_hz, max.max_flash_hz) {
            return Err(FlashConfigError::FlashHz);
        }
        if self.max_red_flashes > max.max_red_flashes {
            return Err(FlashConfigError::RedFlashes);
        }
        Ok(())
    }

    /// Regions along one axis of the field window: the field fraction times the regions on
    /// that axis, rounded half up, kept within `1..=regions`.
    fn window_cells(field: f64, regions: u32) -> usize {
        let cells = libm::floor(field * regions as f64 + 0.5) as usize;
        cells.clamp(1, regions as usize)
    }
}

impl Default for FlashConfig {
    fn default() -> Self {
        Self::DEFAULT
    }
}

/// `value` in `(0, max]`; NaN is refused.
fn in_unit(value: f64, max: f64) -> bool {
    value > 0.0 && value <= max
}

/// Invalid region input; rejected before the analyzer changes state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RegionError {
    /// `time_ms` was not finite.
    NonFiniteTime,
    /// `time_ms` was earlier than the previous frame's.
    DecreasingTime,
    /// The region count was not `columns * rows`.
    RegionCount,
    /// A luminance, red level or color channel was not finite or outside `[0, 1]`.
    InvalidSample,
    /// The config's [`RedRule::Iso9241_391`] needs colors: frames must come through
    /// [`FlashAnalyzer::measure_rgb`] or [`FlashAnalyzer::admit_rgb`].
    ColorRequired,
}

impl core::fmt::Display for RegionError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "invalid flash analyzer frame: {self:?}")
    }
}
impl core::error::Error for RegionError {}

/// The outcome of one frame.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FlashReport {
    /// The frame's time in milliseconds.
    pub time_ms: f64,
    /// The frame's regions now stand for what is on screen. When false the host must keep
    /// presenting the last admitted image; only [`FlashAnalyzer::admit`] refuses.
    pub admitted: bool,
    /// The frame holds a general transition: some field window has more than its area
    /// ceiling of regions completing a general-flash change.
    pub general_transition: bool,
    /// The frame holds a red transition, judged as for `general_transition`.
    pub red_transition: bool,
    /// Regions completing a general-flash change on this frame, over the whole grid.
    pub general_regions: u32,
    /// Regions completing a red-flash change on this frame, over the whole grid.
    pub red_regions: u32,
    /// General flashes in the window ending at this frame, counted as half the transitions.
    pub flashes_in_window: f64,
    /// Red flashes in the window ending at this frame, counted as half the transitions.
    pub red_flashes_in_window: f64,
    /// Either window holds more flashes than the config allows.
    pub exceeds: bool,
}

/// Direction of the run a region's tracker is following.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Trend {
    /// No change of the threshold since the last reversal: `a` and `b` are the low and high.
    Steady,
    /// A rise from `a` to the running maximum `b`.
    Rising,
    /// A fall from `a` to the running minimum `b`.
    Falling,
}

/// The pair rule for one channel.
#[derive(Clone, Copy, Debug)]
pub(super) struct Channel {
    /// Smallest change that reverses a run.
    pub(super) change: f64,
    /// Whether a change exactly equal to `change` counts.
    pub(super) inclusive: bool,
    /// A run counts once its darker end is below this.
    pub(super) darker_limit: f64,
}

const GENERAL: Channel = Channel {
    change: LUMINANCE_CHANGE,
    inclusive: true,
    darker_limit: DARKER_LIMIT,
};

const RED: Channel = Channel {
    change: RED_CHANGE,
    inclusive: false,
    darker_limit: f64::INFINITY,
};

impl Channel {
    fn is_change(&self, delta: f64) -> bool {
        if self.inclusive {
            delta >= self.change
        } else {
            delta > self.change
        }
    }
}

/// One region's progress through rises and falls on one channel.
#[derive(Clone, Copy, Debug)]
pub(super) struct Tracker {
    trend: Trend,
    a: f64,
    b: f64,
    /// The current run has been counted.
    counted: bool,
}

impl Tracker {
    pub(super) const EMPTY: Tracker = Tracker {
        trend: Trend::Steady,
        a: 0.0,
        b: 0.0,
        counted: false,
    };

    pub(super) fn baseline(v: f64) -> Tracker {
        Tracker {
            a: v,
            b: v,
            ..Self::EMPTY
        }
    }

    fn run(trend: Trend, from: f64, to: f64) -> Tracker {
        Tracker {
            trend,
            a: from,
            b: to,
            counted: false,
        }
    }

    /// The tracker after value `v`, and whether this frame completes a counted change: the
    /// first frame of a run of at least the channel's change whose darker end is below its
    /// limit. Each run counts at most once, so counted changes alternate in direction.
    pub(super) fn step(self, v: f64, ch: &Channel) -> (Tracker, bool) {
        let mut next = match self.trend {
            Trend::Steady if ch.is_change(v - self.a) => Self::run(Trend::Rising, self.a, v),
            Trend::Steady if ch.is_change(self.b - v) => Self::run(Trend::Falling, self.b, v),
            Trend::Steady => Tracker {
                a: self.a.min(v),
                b: self.b.max(v),
                ..self
            },
            Trend::Rising if v >= self.b => Tracker { b: v, ..self },
            Trend::Rising if ch.is_change(self.b - v) => Self::run(Trend::Falling, self.b, v),
            Trend::Falling if v <= self.b => Tracker { b: v, ..self },
            Trend::Falling if ch.is_change(v - self.b) => Self::run(Trend::Rising, self.b, v),
            Trend::Rising | Trend::Falling => self,
        };
        let darker = match next.trend {
            Trend::Steady => return (next, false),
            Trend::Rising => next.a,
            Trend::Falling => next.b,
        };
        let counts = !next.counted && darker < ch.darker_limit;
        next.counted |= counts;
        (next, counts)
    }
}

/// A color's position in the CIE 1976 UCS diagram.
#[derive(Clone, Copy, Debug)]
struct Chromaticity {
    u: f64,
    v: f64,
    /// Black has no chromaticity; `u` and `v` are meaningless.
    black: bool,
    /// `R / (R + G + B)` is at least [`RED_SATURATION`].
    saturated: bool,
}

impl Chromaticity {
    const BLACK: Chromaticity = Chromaticity {
        u: 0.0,
        v: 0.0,
        black: true,
        saturated: false,
    };
}

/// The bounding box of a set of chromaticities.
#[derive(Clone, Copy, Debug)]
struct Bounds {
    u0: f64,
    u1: f64,
    v0: f64,
    v1: f64,
    empty: bool,
}

impl Bounds {
    const EMPTY: Bounds = Bounds {
        u0: f64::INFINITY,
        u1: f64::NEG_INFINITY,
        v0: f64::INFINITY,
        v1: f64::NEG_INFINITY,
        empty: true,
    };

    fn add(self, c: &Chromaticity) -> Bounds {
        Bounds {
            u0: self.u0.min(c.u),
            u1: self.u1.max(c.u),
            v0: self.v0.min(c.v),
            v1: self.v1.max(c.v),
            empty: false,
        }
    }

    /// Whether the box corner farthest from `c` is more than [`RED_CHROMATICITY_CHANGE`] from
    /// it. Every point of the box is no farther, so this never misses a member that is.
    fn farther(&self, c: &Chromaticity) -> bool {
        if self.empty {
            return false;
        }
        let du = libm::fabs(c.u - self.u0).max(libm::fabs(c.u - self.u1));
        let dv = libm::fabs(c.v - self.v0).max(libm::fabs(c.v - self.v1));
        libm::sqrt(du * du + dv * dv) > RED_CHROMATICITY_CHANGE
    }
}

/// One region's progress under [`RedRule::Iso9241_391`]: the states shown since its last
/// counted change (or its first frame), kept as bounding boxes of all chromatic states and of
/// the saturated ones, and whether black was among them.
#[derive(Clone, Copy, Debug)]
struct ChromaTracker {
    all: Bounds,
    saturated: Bounds,
    black: bool,
}

impl ChromaTracker {
    const EMPTY: ChromaTracker = ChromaTracker {
        all: Bounds::EMPTY,
        saturated: Bounds::EMPTY,
        black: false,
    };

    fn with(self, c: &Chromaticity) -> ChromaTracker {
        if c.black {
            return ChromaTracker {
                black: true,
                ..self
            };
        }
        ChromaTracker {
            all: self.all.add(c),
            saturated: if c.saturated {
                self.saturated.add(c)
            } else {
                self.saturated
            },
            black: self.black,
        }
    }

    /// The tracker after state `c`, and whether reaching `c` completes a counted change: some
    /// state since the last one differs from `c` by more than [`RED_CHROMATICITY_CHANGE`] and
    /// one of the two is a saturated red. Black against a saturated red always counts. A
    /// counted change restarts the set at `c`, so each change counts once.
    fn step(self, c: &Chromaticity) -> (ChromaTracker, bool) {
        let counts = if c.black {
            !self.saturated.empty
        } else if c.saturated {
            self.black || self.all.farther(c)
        } else {
            self.saturated.farther(c)
        };
        if counts {
            (Self::EMPTY.with(c), true)
        } else {
            (self.with(c), false)
        }
    }
}

/// Times of the screen-level transitions in the current window, oldest first.
#[derive(Clone, Copy, Debug)]
pub(super) struct Ring {
    times: [f64; RING_CAPACITY],
    start: usize,
    len: usize,
}

impl Ring {
    pub(super) const EMPTY: Ring = Ring {
        times: [0.0; RING_CAPACITY],
        start: 0,
        len: 0,
    };

    pub(super) fn len(&self) -> usize {
        self.len
    }

    fn oldest(&self) -> f64 {
        self.times[self.start]
    }

    /// Drops transitions at least one window older than `now_ms`.
    pub(super) fn trim(&mut self, now_ms: f64) {
        while self.len > 0 && now_ms - self.oldest() >= WINDOW_MS {
            self.start = (self.start + 1) % RING_CAPACITY;
            self.len -= 1;
        }
    }

    /// Moves every transition from the timeline ending at `from_ms` to the one ending at
    /// `to_ms`, keeping its age.
    pub(super) fn rebase(&mut self, from_ms: f64, to_ms: f64) {
        for i in 0..self.len {
            let t = &mut self.times[(self.start + i) % RING_CAPACITY];
            *t = to_ms - (from_ms - *t);
        }
    }

    /// Appends a transition, dropping the oldest when full.
    pub(super) fn push(&mut self, now_ms: f64) {
        if self.len == RING_CAPACITY {
            self.start = (self.start + 1) % RING_CAPACITY;
            self.len -= 1;
        }
        self.times[(self.start + self.len) % RING_CAPACITY] = now_ms;
        self.len += 1;
    }
}

/// Measures flashes from per-region relative luminance and red, and optionally refuses frames
/// that would put too many flashes in a window.
///
/// Each region tracks rises and falls of its own luminance and red level. A region completes
/// a general-flash change on the first frame of a run of at least [`LUMINANCE_CHANGE`] whose
/// darker end is below [`DARKER_LIMIT`]. Under [`RedRule::Wcag20`] it completes a red change
/// on the first frame of a run of more than [`RED_CHANGE`]; under [`RedRule::Iso9241_391`] on
/// a frame whose color differs by more than [`RED_CHROMATICITY_CHANGE`] in (u', v') from a
/// state shown since its last red change, one of the two a saturated red. A frame is a screen-level transition when, in some window of the grid
/// the size of a 10-degree field, more than `max_field_area` of the window's regions complete
/// a change on that frame. Two transitions make one flash; more than `2 * max_flash_hz`
/// general or `2 * max_red_flashes` red transitions in a one-second window exceed the config.
///
/// Timestamps follow the [`Limiter`](super::Limiter) rules: a forward gap above
/// [`MAX_CREDITED_GAP_MS`], and the first frame after [`FlashAnalyzer::reset`], credit no
/// elapsed time. The measure and admit functions do not allocate.
#[derive(Clone, Debug)]
pub struct FlashAnalyzer {
    config: FlashConfig,
    window_columns: usize,
    window_rows: usize,
    /// More flashing regions than this in a field window is a flash.
    area_limit: f64,
    general: [Tracker; MAX_REGIONS],
    red: [Tracker; MAX_REGIONS],
    chroma: [ChromaTracker; MAX_REGIONS],
    general_ring: Ring,
    red_ring: Ring,
    previous_time: Option<f64>,
    /// The next frame starts a new timeline: set by reset.
    discontinuity: bool,
    /// Stricter rules for overlay cells (OSC-OVERLAY); inert until set.
    overlay: OverlayState,
}

/// Regions completing a change on one frame, row-major.
type Flags = [bool; MAX_REGIONS];

/// One frame's regions, from either input path.
#[derive(Clone, Copy)]
enum Regions<'a> {
    Samples(&'a [RegionSample]),
    Colors(&'a [RegionColor]),
}

impl Regions<'_> {
    fn len(&self) -> usize {
        match self {
            Regions::Samples(s) => s.len(),
            Regions::Colors(c) => c.len(),
        }
    }

    fn is_valid(&self) -> bool {
        match self {
            Regions::Samples(s) => s.iter().all(RegionSample::is_valid),
            Regions::Colors(c) => c.iter().all(RegionColor::is_valid),
        }
    }

    fn sample(&self, i: usize) -> RegionSample {
        match self {
            Regions::Samples(s) => s[i],
            Regions::Colors(c) => c[i].sample(),
        }
    }

    fn chromaticity(&self, i: usize) -> Chromaticity {
        match self {
            Regions::Samples(_) => Chromaticity::BLACK,
            Regions::Colors(c) => c[i].chromaticity(),
        }
    }
}

impl FlashAnalyzer {
    /// Creates an analyzer, refusing a config that [`FlashConfig::validate`] refuses.
    pub fn new(config: FlashConfig) -> Result<Self, FlashConfigError> {
        config.validate()?;
        let window_columns = FlashConfig::window_cells(config.field_width, config.columns);
        let window_rows = FlashConfig::window_cells(config.field_height, config.rows);
        Ok(FlashAnalyzer {
            config,
            window_columns,
            window_rows,
            area_limit: config.max_field_area * (window_columns * window_rows) as f64,
            general: [Tracker::EMPTY; MAX_REGIONS],
            red: [Tracker::EMPTY; MAX_REGIONS],
            chroma: [ChromaTracker::EMPTY; MAX_REGIONS],
            general_ring: Ring::EMPTY,
            red_ring: Ring::EMPTY,
            previous_time: None,
            discontinuity: false,
            overlay: OverlayState::EMPTY,
        })
    }

    /// The config this analyzer applies.
    pub fn config(&self) -> &FlashConfig {
        &self.config
    }

    /// Regions per field window along each axis: `(columns, rows)`.
    pub fn window(&self) -> (u32, u32) {
        (self.window_columns as u32, self.window_rows as u32)
    }

    /// Starts a new timeline: the next frame may carry any finite timestamp. Transitions keep
    /// their age and each region keeps the image it last showed.
    pub fn reset(&mut self) {
        self.discontinuity = self.previous_time.is_some();
    }

    /// Measures one frame and always commits it as shown. Refused with
    /// [`RegionError::ColorRequired`] under [`RedRule::Iso9241_391`].
    pub fn measure(
        &mut self,
        time_ms: f64,
        regions: &[RegionSample],
    ) -> Result<FlashReport, RegionError> {
        self.frame(time_ms, Regions::Samples(regions), false)
    }

    /// [`FlashAnalyzer::measure`] from each region's mean linear color, under either red rule.
    /// Under [`RedRule::Wcag20`] it gives the same reports as measuring
    /// [`RegionSample::from_linear_rgb`] of each color.
    pub fn measure_rgb(
        &mut self,
        time_ms: f64,
        regions: &[RegionColor],
    ) -> Result<FlashReport, RegionError> {
        self.frame(time_ms, Regions::Colors(regions), false)
    }

    /// Measures one frame and commits it only if the windows stay within the config. A refused
    /// frame keeps every region's tracker state and every unexpired transition, so the next
    /// frame is compared with the last admitted image, which the host must keep presenting.
    /// Its time still counts: it becomes the previous frame time for the gap rule, it ends a
    /// pending discontinuity, and transitions 1000 ms old at that time leave the windows.
    ///
    /// Refused with [`RegionError::ColorRequired`] under [`RedRule::Iso9241_391`].
    pub fn admit(
        &mut self,
        time_ms: f64,
        regions: &[RegionSample],
    ) -> Result<FlashReport, RegionError> {
        self.frame(time_ms, Regions::Samples(regions), true)
    }

    /// [`FlashAnalyzer::admit`] from each region's mean linear color, under either red rule.
    pub fn admit_rgb(
        &mut self,
        time_ms: f64,
        regions: &[RegionColor],
    ) -> Result<FlashReport, RegionError> {
        self.frame(time_ms, Regions::Colors(regions), true)
    }

    fn frame(
        &mut self,
        time_ms: f64,
        regions: Regions<'_>,
        refuse: bool,
    ) -> Result<FlashReport, RegionError> {
        self.validate(time_ms, regions)?;
        let iso = self.config.red_rule == RedRule::Iso9241_391;
        let Some(previous) = self.previous_time else {
            for i in 0..regions.len() {
                let sample = regions.sample(i);
                self.general[i] = Tracker::baseline(sample.luminance);
                self.red[i] = Tracker::baseline(sample.red);
                self.overlay.baseline(i, sample.luminance);
                if iso {
                    self.chroma[i] = ChromaTracker::EMPTY.with(&regions.chromaticity(i));
                }
            }
            self.previous_time = Some(time_ms);
            self.overlay.finish(time_ms, false, true);
            return Ok(FlashReport {
                time_ms,
                admitted: true,
                ..FlashReport::default()
            });
        };
        if self.discontinuity || time_ms - previous > MAX_CREDITED_GAP_MS {
            self.general_ring.rebase(previous, time_ms);
            self.red_ring.rebase(previous, time_ms);
            self.overlay.rebase(previous, time_ms);
        }
        self.discontinuity = false;
        self.previous_time = Some(time_ms);
        self.general_ring.trim(time_ms);
        self.red_ring.trim(time_ms);
        self.overlay.trim(time_ms);

        let mut general_flags: Flags = [false; MAX_REGIONS];
        let mut red_flags: Flags = [false; MAX_REGIONS];
        for i in 0..regions.len() {
            let sample = regions.sample(i);
            general_flags[i] = self.general[i].step(sample.luminance, &GENERAL).1;
            self.overlay.flag(i, sample.luminance);
            red_flags[i] = if iso {
                self.chroma[i].step(&regions.chromaticity(i)).1
            } else {
                self.red[i].step(sample.red, &RED).1
            };
        }
        let general_transition = self.is_transition(&general_flags);
        let red_transition = self.is_transition(&red_flags);
        let overlay_transition = self.overlay.is_transition();
        let general_limit = 2.0 * self.config.max_flash_hz;
        let red_limit = 2.0 * self.config.max_red_flashes as f64;
        let admitted = !refuse
            || ((!general_transition || (self.general_ring.len + 1) as f64 <= general_limit)
                && (!red_transition || (self.red_ring.len + 1) as f64 <= red_limit)
                && self.overlay.admits(overlay_transition));
        if admitted {
            for i in 0..regions.len() {
                let sample = regions.sample(i);
                self.general[i] = self.general[i].step(sample.luminance, &GENERAL).0;
                self.overlay.commit(i, sample.luminance);
                if iso {
                    self.chroma[i] = self.chroma[i].step(&regions.chromaticity(i)).0;
                } else {
                    self.red[i] = self.red[i].step(sample.red, &RED).0;
                }
            }
            if general_transition {
                self.general_ring.push(time_ms);
            }
            if red_transition {
                self.red_ring.push(time_ms);
            }
        }
        self.overlay.finish(time_ms, overlay_transition, admitted);
        let general = self.general_ring.len as f64;
        let red = self.red_ring.len as f64;
        Ok(FlashReport {
            time_ms,
            admitted,
            general_transition,
            red_transition,
            general_regions: count(&general_flags),
            red_regions: count(&red_flags),
            flashes_in_window: general / 2.0,
            red_flashes_in_window: red / 2.0,
            exceeds: general > general_limit || red > red_limit,
        })
    }

    /// Holds the grid cells `regions` cover ([`crate::overlay::flash_mask`]) to the stricter
    /// `overlay` from the next frame on, replacing any overlay set before. A frame with an
    /// overlay transition that would put more than `2 * overlay.max_flash_hz` overlay
    /// transitions in the window is refused by [`FlashAnalyzer::admit`]. Region trackers and
    /// unexpired overlay transitions carry over. Does not allocate.
    pub fn set_overlay(
        &mut self,
        overlay: &FlashOverlay,
        regions: &[OverlayRegion],
    ) -> Result<(), FlashOverlayError> {
        overlay.validate(&self.config)?;
        let cells = (self.config.columns * self.config.rows) as usize;
        let mut mask = [false; MAX_REGIONS];
        flash_mask(
            regions,
            self.config.columns,
            self.config.rows,
            &mut mask[..cells],
        )
        .map_err(FlashOverlayError::Regions)?;
        self.overlay.set(*overlay, &mask[..cells]);
        Ok(())
    }

    /// Removes the overlay: the analyzer measures as if none had been set.
    pub fn clear_overlay(&mut self) {
        self.overlay.clear();
    }

    /// The overlay outcome of the frame last measured or admitted.
    pub fn overlay_report(&self) -> FlashOverlayReport {
        self.overlay.report()
    }

    fn validate(&self, time_ms: f64, regions: Regions<'_>) -> Result<(), RegionError> {
        if self.config.red_rule == RedRule::Iso9241_391 && matches!(regions, Regions::Samples(_)) {
            return Err(RegionError::ColorRequired);
        }
        if !time_ms.is_finite() {
            return Err(RegionError::NonFiniteTime);
        }
        let continuous_from = self.previous_time.filter(|_| !self.discontinuity);
        if continuous_from.is_some_and(|time| time_ms < time) {
            return Err(RegionError::DecreasingTime);
        }
        if regions.len() != (self.config.columns * self.config.rows) as usize {
            return Err(RegionError::RegionCount);
        }
        if !regions.is_valid() {
            return Err(RegionError::InvalidSample);
        }
        Ok(())
    }

    /// Whether some field window holds more than its area ceiling of flagged regions.
    fn is_transition(&self, flags: &Flags) -> bool {
        let columns = self.config.columns as usize;
        let rows = self.config.rows as usize;
        // sums[y][x]: flagged regions above and left of (x, y), exclusive.
        let mut sums = [[0u16; MAX_GRID as usize + 1]; MAX_GRID as usize + 1];
        for y in 0..rows {
            for x in 0..columns {
                sums[y + 1][x + 1] = sums[y][x + 1] + sums[y + 1][x] - sums[y][x]
                    + u16::from(flags[y * columns + x]);
            }
        }
        let (w, h) = (self.window_columns, self.window_rows);
        (0..=rows - h).any(|y| {
            (0..=columns - w).any(|x| {
                let n = sums[y + h][x + w] + sums[y][x] - sums[y][x + w] - sums[y + h][x];
                f64::from(n) > self.area_limit
            })
        })
    }
}

fn count(flags: &Flags) -> u32 {
    flags.iter().filter(|&&f| f).count() as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_is_valid_and_windows_snap_to_cells() {
        assert_eq!(FlashConfig::DEFAULT.validate(), Ok(()));
        let analyzer = FlashAnalyzer::new(FlashConfig::DEFAULT).unwrap();
        assert_eq!(analyzer.window(), (5, 5));
        let six = FlashConfig {
            columns: 6,
            rows: 6,
            ..FlashConfig::DEFAULT
        };
        assert_eq!(FlashAnalyzer::new(six).unwrap().window(), (2, 2));
        let tiny = FlashConfig {
            field_width: 0.01,
            field_height: 1.0,
            ..six
        };
        assert_eq!(FlashAnalyzer::new(tiny).unwrap().window(), (1, 6));
    }

    #[test]
    fn ring_saturates_at_capacity_and_keeps_the_newest() {
        let mut ring = Ring::EMPTY;
        for i in 0..(RING_CAPACITY + 10) {
            ring.push(i as f64);
        }
        assert_eq!(ring.len, RING_CAPACITY);
        assert_eq!(ring.oldest(), 10.0);
    }

    #[test]
    fn red_tracker_needs_more_than_the_change() {
        let t = Tracker::baseline(0.0);
        assert!(!t.step(0.0625, &RED).1);
        assert!(t.step(0.0625 + 1.0 / 1024.0, &RED).1);
    }
}
