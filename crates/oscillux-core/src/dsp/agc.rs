// SPDX-License-Identifier: AGPL-3.0-only
//! Optional adaptive level normaliser: band and group levels relative to their recent range.
//!
//! [`Agc`] consumes [`DspFrame`]s and returns [`Levels`]. The spectrum is already in dB, mapped
//! from `db_floor..0` to `[0, 1]`, so every range here is a range in dB. For each band and for
//! each onset band group (the mean of its bands), a running maximum jumps up to any higher level
//! at once and otherwise relaxes toward the input with the configured time constant; a running
//! minimum does the same downward. The relative level is the input's position between them. When
//! the two are closer than `min_range_db`, the window is widened to that range around their
//! midpoint, so a level that has held steady reads about 0.5 rather than amplified noise.
//!
//! A noise gate then scales each relative level by how far its running maximum sits below that
//! level's reference, a slow running maximum that also jumps up at once but relaxes with
//! `reference_time_constant_s`: by 1 while it is within `gate_db - min_range_db`, falling
//! linearly to 0 at `gate_db` below. The gate is relative, so it ignores the overall level: a
//! quiet master reads like a loud one, down to the analyser's `db_floor`. Quiet hiss after loud
//! material reads near 0 once the running maximum has relaxed onto it, until the reference too
//! has relaxed to within `gate_db` of it, instead of being stretched to mid-scale. Both maxima
//! jump up at once, so the gate opens on the first loud frame. A level that has never been
//! louder (hiss alone from the start, say) is not gated.
//!
//! It allocates nothing, ignores frame flags, and uses only IEEE double addition, subtraction,
//! multiplication, division and comparisons. `conformance/dsp/music/README.md` ("Adaptive
//! levels") specifies it, and `tools/dsp-agc-vectors.py` is the independent oracle for
//! `conformance/dsp/music/agc/`.

use super::config::{DspSettings, MAX_BANDS, ONSET_GROUPS};
use super::{DspError, DspFrame};

/// Time constants, minimum range and noise gate for an [`Agc`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AgcConfig {
    /// Seconds for the running maximum and minimum to relax most of the way (1 - 1/e) toward a
    /// steady input. Finite and positive.
    pub time_constant_s: f64,
    /// Smallest range, in dB, that is stretched to `0..1`. Finite, positive and at most
    /// `-db_floor`.
    pub min_range_db: f64,
    /// Noise gate depth, in dB below each level's reference: relative levels read 0 while the
    /// running maximum is this far or further below the reference, and full scale from
    /// `min_range_db` closer. Finite and at least `min_range_db`.
    pub gate_db: f64,
    /// Seconds for each level's reference, a slow running maximum, to relax most of the way
    /// toward a steady input. Finite and positive.
    pub reference_time_constant_s: f64,
}

impl Default for AgcConfig {
    /// 4 s and 12 dB, with a gate 36 dB below a reference that relaxes over 600 s: material up
    /// to 24 dB quieter than the loudest of the last minutes reads in full.
    fn default() -> Self {
        Self {
            time_constant_s: 4.0,
            min_range_db: 12.0,
            gate_db: 36.0,
            reference_time_constant_s: 600.0,
        }
    }
}

/// Absolute and relative levels for one frame.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Levels {
    /// Number of valid entries in `relative_bands`; the configured band count.
    pub band_count: u32,
    /// Always 0.
    pub reserved: u32,
    /// Each onset band group's absolute level, relative to its recent range, in `[0, 1]`.
    pub relative_groups: [f64; ONSET_GROUPS],
    /// Each onset band group's absolute level: the mean of its band levels, in `[0, 1]`.
    pub absolute_groups: [f64; ONSET_GROUPS],
    /// Each band's level relative to its recent range, in `[0, 1]`; entries past `band_count`
    /// are zero.
    pub relative_bands: [f64; MAX_BANDS],
}

impl Levels {
    /// All zero, for initialising caller-owned output buffers.
    pub const ZERO: Levels = Levels {
        band_count: 0,
        reserved: 0,
        relative_groups: [0.0; ONSET_GROUPS],
        absolute_groups: [0.0; ONSET_GROUPS],
        relative_bands: [0.0; MAX_BANDS],
    };
}

impl Default for Levels {
    fn default() -> Self {
        Self::ZERO
    }
}

/// A running maximum and minimum of one level, and the gate's slower reference maximum.
#[derive(Clone, Copy, Debug, Default)]
struct Range {
    hi: f64,
    lo: f64,
    reference: f64,
}

impl Range {
    fn follow(&mut self, x: f64, k: f64, kr: f64) {
        self.reference = if x > self.reference {
            x
        } else {
            self.reference + kr * (x - self.reference)
        };
        self.hi = if x > self.hi {
            x
        } else {
            self.hi + k * (x - self.hi)
        };
        self.lo = if x < self.lo {
            x
        } else {
            self.lo + k * (x - self.lo)
        };
    }

    fn read(&self, x: f64, floor: f64, gate: f64) -> f64 {
        let mut span = self.hi - self.lo;
        let base = if span >= floor {
            self.lo
        } else {
            span = floor;
            positive((self.hi + self.lo - span) / 2.0)
        };
        unit((x - base) / span) * unit((self.hi - self.reference + gate) / floor)
    }
}

/// `v` if it is above 0, else +0.
fn positive(v: f64) -> f64 {
    if v > 0.0 {
        v
    } else {
        0.0
    }
}

/// `v` limited to `[+0, 1]`; NaN reads as 0.
fn unit(v: f64) -> f64 {
    if v < 1.0 {
        positive(v)
    } else {
        1.0
    }
}

/// Finite inputs are limited to `[0, 1]`; anything else reads as 0.
fn clean(v: f64) -> f64 {
    if v.is_finite() {
        unit(v)
    } else {
        0.0
    }
}

/// The adaptive level normaliser; see the module documentation.
#[derive(Clone, Debug)]
pub struct Agc {
    k: f64,
    kr: f64,
    floor: f64,
    gate: f64,
    bands: usize,
    groups: [[u32; 2]; ONSET_GROUPS],
    band_ranges: [Range; MAX_BANDS],
    group_ranges: [Range; ONSET_GROUPS],
    primed: bool,
}

impl Agc {
    /// A normaliser for frames produced with `settings`, using its onset band groups.
    pub fn new(settings: &DspSettings, agc: AgcConfig) -> Result<Self, DspError> {
        settings.validate()?;
        let cfg = &settings.config;
        if !(agc.time_constant_s.is_finite() && agc.time_constant_s > 0.0) {
            return Err(DspError::InvalidConfig("time_constant_s"));
        }
        if !(agc.min_range_db.is_finite()
            && agc.min_range_db > 0.0
            && agc.min_range_db <= -cfg.db_floor)
        {
            return Err(DspError::InvalidConfig("min_range_db"));
        }
        if !(agc.gate_db.is_finite() && agc.gate_db >= agc.min_range_db) {
            return Err(DspError::InvalidConfig("gate_db"));
        }
        if !(agc.reference_time_constant_s.is_finite() && agc.reference_time_constant_s > 0.0) {
            return Err(DspError::InvalidConfig("reference_time_constant_s"));
        }
        let h = cfg.hop_samples as f64 / cfg.sample_rate_hz as f64;
        Ok(Self {
            k: h / (agc.time_constant_s + h),
            kr: h / (agc.reference_time_constant_s + h),
            floor: agc.min_range_db / -cfg.db_floor,
            gate: agc.gate_db / -cfg.db_floor,
            bands: cfg.spectrum_bands as usize,
            groups: cfg.onset_band_groups,
            band_ranges: [Range::default(); MAX_BANDS],
            group_ranges: [Range::default(); ONSET_GROUPS],
            primed: false,
        })
    }

    /// Forgets every range, as after [`Agc::new`].
    pub fn reset(&mut self) {
        self.primed = false;
    }

    /// Consumes the next analysis frame.
    pub fn update(&mut self, frame: &DspFrame) -> Levels {
        let mut out = Levels {
            band_count: self.bands as u32,
            ..Levels::ZERO
        };
        let mut levels = [0.0; MAX_BANDS];
        for (level, &v) in levels[..self.bands].iter_mut().zip(&frame.spectrum) {
            *level = clean(v);
        }
        for (absolute, [first, last]) in out.absolute_groups.iter_mut().zip(self.groups) {
            let mut total = 0.0;
            for &v in &levels[first as usize..=last as usize] {
                total += v;
            }
            *absolute = total / f64::from(last - first + 1);
        }
        let (k, kr, floor, gate, primed) = (self.k, self.kr, self.floor, self.gate, self.primed);
        let pairs = self.band_ranges[..self.bands]
            .iter_mut()
            .zip(&levels[..self.bands])
            .zip(&mut out.relative_bands)
            .chain(
                self.group_ranges
                    .iter_mut()
                    .zip(&out.absolute_groups)
                    .zip(&mut out.relative_groups),
            );
        for ((range, &x), relative) in pairs {
            if primed {
                range.follow(x, k, kr);
            } else {
                *range = Range {
                    hi: x,
                    lo: x,
                    reference: x,
                };
            }
            *relative = range.read(x, floor, gate);
        }
        self.primed = true;
        out
    }
}
