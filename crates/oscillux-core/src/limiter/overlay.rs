// SPDX-License-Identifier: AGPL-3.0-only
//! Overlay regions as a stricter area for the [`FlashAnalyzer`](super::FlashAnalyzer).
//!
//! Host UI (menus, captions) sits over the visuals in the regions of an
//! [`OverlayRegion`](crate::overlay::OverlayRegion) list. Text there must stay readable, so the
//! grid cells those regions cover can be held to a stricter [`FlashOverlay`]: a smaller
//! luminance change counts, a brighter darker end counts, fewer transitions a second are
//! allowed and a single flagged cell can be a transition. Opt-in: an analyzer without an
//! overlay measures exactly as before.

use super::regions::{Channel, Ring, Tracker, MAX_REGIONS};
use super::{FlashConfig, DARKER_LIMIT, LUMINANCE_CHANGE};

/// Stricter flash rules for the grid cells overlay regions cover.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FlashOverlay {
    /// Smallest luminance change that reverses a run inside the overlay, `(0, LUMINANCE_CHANGE]`.
    pub luminance_change: f64,
    /// A run inside the overlay counts once its darker end is below this,
    /// `[DARKER_LIMIT, 1]`.
    pub darker_limit: f64,
    /// Overlay flashes per second allowed, `[0, config.max_flash_hz]`.
    pub max_flash_hz: f64,
    /// A frame is an overlay transition when more than this fraction of the overlay's cells
    /// complete a change, `[0, config.max_field_area]`; 0 makes one cell enough.
    pub max_area: f64,
}

impl FlashOverlay {
    /// Half the general change, any darker end, one flash a second, one cell.
    pub const DEFAULT: FlashOverlay = FlashOverlay {
        luminance_change: LUMINANCE_CHANGE / 2.0,
        darker_limit: 1.0,
        max_flash_hz: 1.0,
        max_area: 0.0,
    };

    /// Refuses a value outside its range, or looser than `config`.
    pub fn validate(&self, config: &FlashConfig) -> Result<(), FlashOverlayError> {
        let c = self.luminance_change;
        if !(c > 0.0 && c <= LUMINANCE_CHANGE) {
            return Err(FlashOverlayError::LuminanceChange);
        }
        if !(DARKER_LIMIT..=1.0).contains(&self.darker_limit) {
            return Err(FlashOverlayError::DarkerLimit);
        }
        if !(0.0..=config.max_flash_hz).contains(&self.max_flash_hz) {
            return Err(FlashOverlayError::MaxFlashHz);
        }
        if !(0.0..=config.max_field_area).contains(&self.max_area) {
            return Err(FlashOverlayError::MaxArea);
        }
        Ok(())
    }
}

impl Default for FlashOverlay {
    fn default() -> Self {
        Self::DEFAULT
    }
}

/// Why a [`FlashOverlay`] or its regions were refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FlashOverlayError {
    /// The luminance change was not in `(0, LUMINANCE_CHANGE]`.
    LuminanceChange,
    /// The darker limit was not in `[DARKER_LIMIT, 1]`.
    DarkerLimit,
    /// The flash rate was negative or above the analyzer config's.
    MaxFlashHz,
    /// The area was negative or above the analyzer config's field area.
    MaxArea,
    /// The overlay regions were refused by [`crate::overlay::flash_mask`].
    Regions(crate::overlay::OverlayError),
}

impl core::fmt::Display for FlashOverlayError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "invalid flash overlay: {self:?}")
    }
}
impl core::error::Error for FlashOverlayError {}

/// The overlay outcome of the frame last measured.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FlashOverlayReport {
    /// An overlay is set.
    pub active: bool,
    /// The frame holds an overlay transition.
    pub transition: bool,
    /// Overlay cells completing a change on this frame.
    pub regions: u32,
    /// Grid cells the overlay covers.
    pub cells: u32,
    /// Overlay flashes in the window ending at this frame, counted as half the transitions.
    pub flashes_in_window: f64,
    /// The overlay window holds more flashes than the overlay allows.
    pub exceeds: bool,
}

/// The analyzer's overlay state: its own trackers on the overlay channel, which follow every
/// region on every committed frame so setting an overlay later starts from the image shown.
#[derive(Clone, Debug)]
pub(super) struct OverlayState {
    rules: Option<(FlashOverlay, Channel)>,
    mask: [bool; MAX_REGIONS],
    cells: u32,
    trackers: [Tracker; MAX_REGIONS],
    ring: Ring,
    flags: [bool; MAX_REGIONS],
    report: FlashOverlayReport,
}

impl OverlayState {
    pub(super) const EMPTY: OverlayState = OverlayState {
        rules: None,
        mask: [false; MAX_REGIONS],
        cells: 0,
        trackers: [Tracker::EMPTY; MAX_REGIONS],
        ring: Ring::EMPTY,
        flags: [false; MAX_REGIONS],
        report: FlashOverlayReport {
            active: false,
            transition: false,
            regions: 0,
            cells: 0,
            flashes_in_window: 0.0,
            exceeds: false,
        },
    };

    pub(super) fn set(&mut self, overlay: FlashOverlay, mask: &[bool]) {
        let channel = Channel {
            change: overlay.luminance_change,
            inclusive: true,
            darker_limit: overlay.darker_limit,
        };
        self.rules = Some((overlay, channel));
        self.mask = [false; MAX_REGIONS];
        self.mask[..mask.len()].copy_from_slice(mask);
        self.cells = mask.iter().filter(|&&m| m).count() as u32;
    }

    pub(super) fn clear(&mut self) {
        self.rules = None;
        self.mask = [false; MAX_REGIONS];
        self.cells = 0;
    }

    pub(super) fn report(&self) -> FlashOverlayReport {
        self.report
    }

    pub(super) fn baseline(&mut self, i: usize, luminance: f64) {
        self.trackers[i] = Tracker::baseline(luminance);
    }

    pub(super) fn rebase(&mut self, from_ms: f64, to_ms: f64) {
        self.ring.rebase(from_ms, to_ms);
    }

    pub(super) fn trim(&mut self, now_ms: f64) {
        self.ring.trim(now_ms);
    }

    /// Flags region `i` for this frame from its luminance, without committing.
    pub(super) fn flag(&mut self, i: usize, luminance: f64) {
        self.flags[i] = match &self.rules {
            Some((_, channel)) if self.mask[i] => self.trackers[i].step(luminance, channel).1,
            _ => false,
        };
    }

    /// Whether this frame's flags make an overlay transition.
    pub(super) fn is_transition(&self) -> bool {
        let Some((overlay, _)) = &self.rules else {
            return false;
        };
        let flagged = self.flags.iter().filter(|&&f| f).count() as f64;
        flagged > overlay.max_area * self.cells as f64
    }

    /// Whether committing a frame with `transition` keeps the overlay window within its rate.
    pub(super) fn admits(&self, transition: bool) -> bool {
        match &self.rules {
            Some((overlay, _)) if transition => {
                (self.ring.len() + 1) as f64 <= 2.0 * overlay.max_flash_hz
            }
            _ => true,
        }
    }

    /// Commits region `i`'s luminance into its tracker.
    pub(super) fn commit(&mut self, i: usize, luminance: f64) {
        let channel = match &self.rules {
            Some((_, channel)) => *channel,
            None => Channel {
                change: FlashOverlay::DEFAULT.luminance_change,
                inclusive: true,
                darker_limit: FlashOverlay::DEFAULT.darker_limit,
            },
        };
        self.trackers[i] = self.trackers[i].step(luminance, &channel).0;
    }

    /// Records the frame's overlay outcome; pushes its transition when committed.
    pub(super) fn finish(&mut self, time_ms: f64, transition: bool, committed: bool) {
        if committed && transition {
            self.ring.push(time_ms);
        }
        let len = self.ring.len() as f64;
        self.report = match &self.rules {
            Some((overlay, _)) => FlashOverlayReport {
                active: true,
                transition,
                regions: self.flags.iter().filter(|&&f| f).count() as u32,
                cells: self.cells,
                flashes_in_window: len / 2.0,
                exceeds: len > 2.0 * overlay.max_flash_hz,
            },
            None => FlashOverlayReport {
                flashes_in_window: len / 2.0,
                ..FlashOverlayReport::default()
            },
        };
    }
}
