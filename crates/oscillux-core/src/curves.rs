// SPDX-License-Identifier: AGPL-3.0-only
//! Typed constant, easing, envelope and LFO curves; TypeScript rounding semantics.

/// Flag: [`Curve::value`] is present.
pub const VALUE: u32 = 1;
/// Flag: [`Curve::from`] is present.
pub const FROM: u32 = 2;
/// Flag: [`Curve::to`] is present.
pub const TO: u32 = 4;
/// Flag: [`Curve::min`] is present.
pub const MIN: u32 = 8;
/// Flag: [`Curve::max`] is present.
pub const MAX: u32 = 16;
/// Flag: with [`MIN`] and [`MAX`], wrap into `[min, max)` instead of clamping.
pub const WRAP: u32 = 32;

/// Kind: the constant [`Curve::value`].
pub const KIND_CONSTANT: u32 = 0;
/// Kind: from [`Curve::from`] to [`Curve::to`] over [`Curve::duration`].
pub const KIND_EASING: u32 = 1;
/// Kind: linear attack, hold and linear release.
pub const KIND_ENVELOPE: u32 = 2;
/// Kind: a periodic shape between [`Curve::min`] and [`Curve::max`].
pub const KIND_LFO: u32 = 3;
/// Unit: none; only for [`KIND_CONSTANT`].
pub const UNIT_UNSPECIFIED: u32 = 0;
/// Unit: curve times are seconds and read [`CurveInput::elapsed_seconds`].
pub const UNIT_SECONDS: u32 = 1;
/// Unit: curve times are beats and read [`CurveInput::elapsed_beats`].
pub const UNIT_BEATS: u32 = 2;
/// Easing: linear.
pub const EASING_LINEAR: u32 = 0;
/// Easing: quadratic ease-in.
pub const EASING_IN: u32 = 1;
/// Easing: quadratic ease-out.
pub const EASING_OUT: u32 = 2;
/// Easing: quadratic ease-in-out.
pub const EASING_IN_OUT: u32 = 3;
/// LFO shape: sine.
pub const SHAPE_SINE: u32 = 0;
/// LFO shape: triangle.
pub const SHAPE_TRIANGLE: u32 = 1;
/// LFO shape: square, high for the first half cycle.
pub const SHAPE_SQUARE: u32 = 2;

/// A typed curve; `ffi/include/oscillux.h` documents each field's unit and range. Times are in
/// curve units: seconds or beats, per [`Curve::unit`].
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Curve {
    /// `KIND_*`.
    pub kind: u32,
    /// `UNIT_*`.
    pub unit: u32,
    /// `EASING_*`, for [`KIND_EASING`].
    pub easing: u32,
    /// `SHAPE_*`, for [`KIND_LFO`].
    pub shape: u32,
    /// Bitmask of [`VALUE`], [`FROM`], [`TO`], [`MIN`], [`MAX`] and [`WRAP`].
    pub flags: u32,
    /// Constant output, or envelope peak (1 without [`VALUE`]).
    pub value: f64,
    /// Easing start value.
    pub from: f64,
    /// Easing end value.
    pub to: f64,
    /// Easing length in curve units.
    pub duration: f64,
    /// Envelope rise time in curve units.
    pub attack: f64,
    /// Envelope fall time in curve units.
    pub release: f64,
    /// Envelope release start in curve units; 0 never releases.
    pub release_at: f64,
    /// LFO cycle length in curve units.
    pub period: f64,
    /// LFO phase offset in cycles.
    pub phase: f64,
    /// Lower bound with [`MIN`]; LFO low value.
    pub min: f64,
    /// Upper bound with [`MAX`]; LFO high value.
    pub max: f64,
    /// Exponential smoothing time constant in seconds; 0 disables.
    pub smoothing_seconds: f64,
}

impl Default for Curve {
    fn default() -> Self {
        Self {
            kind: KIND_CONSTANT,
            unit: UNIT_UNSPECIFIED,
            easing: EASING_LINEAR,
            shape: SHAPE_SINE,
            flags: VALUE,
            value: 0.0,
            from: 0.0,
            to: 0.0,
            duration: 0.0,
            attack: 0.0,
            release: 0.0,
            release_at: 0.0,
            period: 0.0,
            phase: 0.0,
            min: 0.0,
            max: 0.0,
            smoothing_seconds: 0.0,
        }
    }
}

/// The clock and history for one evaluation.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CurveInput {
    /// Seconds since the curve started.
    pub elapsed_seconds: f64,
    /// Beats since the curve started.
    pub elapsed_beats: f64,
    /// Cycles added to the LFO phase when the unit is beats.
    pub beat_phase: f64,
    /// Seconds since the previous evaluation.
    pub delta_seconds: f64,
    /// The previous output, read when `has_previous` is 1.
    pub previous_value: f64,
    /// 0 or 1.
    pub has_previous: u32,
}

/// A curve or its input was out of range, or the result was not finite.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CurveError;

impl Curve {
    /// Checks every field.
    pub fn validate(&self) -> Result<(), CurveError> {
        let finite = [
            self.value,
            self.from,
            self.to,
            self.duration,
            self.attack,
            self.release,
            self.release_at,
            self.period,
            self.phase,
            self.min,
            self.max,
            self.smoothing_seconds,
        ]
        .iter()
        .all(|v| v.is_finite());
        let bounded = self.flags & (MIN | MAX) == MIN | MAX;
        if !finite
            || self.kind > KIND_LFO
            || self.unit > UNIT_BEATS
            || self.flags & !63 != 0
            || self.smoothing_seconds < 0.0
            || (bounded && (self.min > self.max || !(self.max - self.min).is_finite()))
        {
            return Err(CurveError);
        }
        let valid = match self.kind {
            KIND_CONSTANT => self.flags & VALUE != 0,
            KIND_EASING => {
                self.flags & (FROM | TO) == FROM | TO
                    && self.duration > 0.0
                    && self.easing <= EASING_IN_OUT
                    && self.unit != UNIT_UNSPECIFIED
                    && (self.to - self.from).is_finite()
            }
            KIND_ENVELOPE => {
                self.attack >= 0.0 && self.release > 0.0 && self.unit != UNIT_UNSPECIFIED
            }
            KIND_LFO => {
                self.period > 0.0
                    && bounded
                    && self.unit != UNIT_UNSPECIFIED
                    && self.shape <= SHAPE_SQUARE
            }
            _ => false,
        };
        if valid {
            Ok(())
        } else {
            Err(CurveError)
        }
    }

    /// The value at `input`, rounded half-up to 6 decimal places.
    pub fn evaluate(&self, input: &CurveInput) -> Result<f64, CurveError> {
        self.validate()?;
        if input.has_previous > 1
            || ![
                input.elapsed_seconds,
                input.elapsed_beats,
                input.beat_phase,
                input.delta_seconds,
                input.previous_value,
            ]
            .iter()
            .all(|v| v.is_finite())
        {
            return Err(CurveError);
        }
        let time = if self.unit == UNIT_BEATS {
            input.elapsed_beats
        } else {
            input.elapsed_seconds
        };
        let raw = match self.kind {
            KIND_CONSTANT => self.value,
            KIND_EASING => {
                self.from
                    + (self.to - self.from)
                        * ease(self.easing, (time / self.duration).clamp(0.0, 1.0))
            }
            KIND_ENVELOPE => {
                let peak = if self.flags & VALUE != 0 {
                    self.value
                } else {
                    1.0
                };
                if self.attack > 0.0 && time < self.attack {
                    peak * time / self.attack
                } else if self.release_at > 0.0 && time > self.release_at {
                    peak * (1.0 - (time - self.release_at) / self.release).max(0.0)
                } else {
                    peak
                }
            }
            _ => {
                let cycles = time / self.period
                    + self.phase
                    + if self.unit == UNIT_BEATS {
                        input.beat_phase
                    } else {
                        0.0
                    };
                if !cycles.is_finite() {
                    return Err(CurveError);
                }
                self.min + (self.max - self.min) * wave(self.shape, cycles)
            }
        };
        if !raw.is_finite() {
            return Err(CurveError);
        }
        let mut value = raw;
        if self.flags & (MIN | MAX) == MIN | MAX {
            if self.flags & WRAP != 0 && self.max > self.min {
                let span = self.max - self.min;
                value = libm::fmod(value - self.min, span);
                if value < 0.0 {
                    value += span;
                }
                value += self.min;
            } else {
                // Not `f64::clamp`: validation already ordered the bounds, and its
                // panic would link float formatting into the wasm build.
                if value < self.min {
                    value = self.min;
                } else if value > self.max {
                    value = self.max;
                }
            }
        }
        if self.smoothing_seconds > 0.0 && input.has_previous == 1 && input.delta_seconds > 0.0 {
            let alpha = 1.0 - libm::exp(-input.delta_seconds / self.smoothing_seconds);
            value = input.previous_value + alpha * (value - input.previous_value);
        }
        js_round6(value)
    }
}

fn ease(kind: u32, t: f64) -> f64 {
    match kind {
        EASING_IN => t * t,
        EASING_OUT => 1.0 - (1.0 - t) * (1.0 - t),
        EASING_IN_OUT if t < 0.5 => 2.0 * t * t,
        EASING_IN_OUT => 1.0 - libm::pow(-2.0 * t + 2.0, 2.0) / 2.0,
        _ => t,
    }
}
fn wave(shape: u32, cycles: f64) -> f64 {
    let phase = cycles - libm::floor(cycles);
    match shape {
        SHAPE_TRIANGLE => 1.0 - (2.0 * phase - 1.0).abs(),
        SHAPE_SQUARE => {
            if phase < 0.5 {
                1.0
            } else {
                0.0
            }
        }
        _ => (libm::sin(2.0 * core::f64::consts::PI * phase) + 1.0) / 2.0,
    }
}
fn js_round6(value: f64) -> Result<f64, CurveError> {
    let scaled = value * 1_000_000.0;
    if !scaled.is_finite() {
        return Err(CurveError);
    }
    let floor = libm::floor(scaled);
    let rounded = if scaled - floor >= 0.5 {
        floor + 1.0
    } else {
        floor
    };
    Ok(if rounded == 0.0 && value.is_sign_negative() {
        -0.0
    } else {
        rounded / 1_000_000.0
    })
}
