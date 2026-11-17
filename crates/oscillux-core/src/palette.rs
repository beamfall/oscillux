// SPDX-License-Identifier: AGPL-3.0-only
//! The vivid colour mode: a deterministic tour of the sixteen vivid palettes that
//! `osPalVisual` (`shaders/originals/common.glsl`) reads when `palette.x < 0`, and the
//! present-pass saturation and vibrance that mode uses. Hosts choose whether to tour.

/// Number of vivid palettes the tour visits.
pub const TOUR_COUNT: u32 = 16;
/// Seconds the tour spends on each palette.
pub const TOUR_SECONDS: u32 = 6;
/// Present-pass saturation of the vivid mode; the manifest mode uses 1.
pub const VIVID_SATURATION: f64 = 1.35;
/// Present-pass vibrance of the vivid mode (extra saturation for dull colours, scaled by
/// `(1 - chroma)^2`); the manifest mode uses 0.
pub const VIVID_VIBRANCE: f64 = 1.2;

/// The `palette` uniform at `time_seconds`: `[-1, 0, z, 0]`, where `z` is
/// `time_seconds / TOUR_SECONDS + offset` wrapped into `[0, TOUR_COUNT)`. `offset` (any sign)
/// staggers visuals across the tour; hosts pass the visual's manifest palette index. Both
/// arguments must be finite.
#[must_use]
pub fn tour(time_seconds: f64, offset: f64) -> [f64; 4] {
    let count = f64::from(TOUR_COUNT);
    let z = ((time_seconds / f64::from(TOUR_SECONDS) + offset) % count + count) % count;
    [-1.0, 0.0, z, 0.0]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_both_ways() {
        assert_eq!(tour(0.0, -3.0), [-1.0, 0.0, 13.0, 0.0]);
        assert_eq!(tour(96.0, 0.0)[2], 0.0);
        assert_eq!(tour(9.0, 2.0)[2], 3.5);
        assert_eq!(tour(-6.0, 0.0)[2], 15.0);
    }

    #[test]
    fn stays_below_count() {
        let z = tour(-1e-15, 0.0)[2];
        assert!((0.0..16.0).contains(&z), "{z}");
    }
}
