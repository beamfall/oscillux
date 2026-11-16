// SPDX-License-Identifier: AGPL-3.0-only
//! Flash policy and its tighten-only validation.

use core::fmt;

/// Flash ceilings a host accepts. Every field may be tightened below [`Policy::DEFAULT`]; none
/// may be loosened past it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Policy {
    /// Most general flashes allowed in any one-second window.
    pub max_flash_hz: f64,
    /// Ceiling on any onset magnitude, the luminance-change proxy.
    pub max_luminance_delta: f64,
    /// Screen-area fraction at or below which a change does not count as a flash.
    pub max_flash_area: f64,
    /// Most red flashes allowed in any one-second window. Zero forbids red flashes.
    pub max_red_flashes: u32,
    /// Whether a regular strobe pattern is forbidden. Must be `true`.
    pub strobe_banned: bool,
}

/// A policy field, named as in the conformance vectors.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PolicyField {
    /// [`Policy::max_flash_hz`].
    MaxFlashHz,
    /// [`Policy::max_luminance_delta`].
    MaxLuminanceDelta,
    /// [`Policy::max_flash_area`].
    MaxFlashArea,
    /// [`Policy::max_red_flashes`].
    MaxRedFlashes,
}

/// Why a policy was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PolicyError {
    /// `strobe_banned` was false.
    StrobeNotBanned,
    /// A ceiling was zero, negative or not a number.
    NonPositive(PolicyField),
    /// A ceiling was looser than the default.
    Looser(PolicyField),
}

impl Policy {
    /// The hard maxima, and the loosest policy the limiter accepts.
    pub const DEFAULT: Policy = Policy {
        max_flash_hz: 3.0,
        max_luminance_delta: 0.8,
        max_flash_area: 0.25,
        max_red_flashes: 3,
        strobe_banned: true,
    };

    /// Refuses a policy that is looser than [`Policy::DEFAULT`] on any field, allows strobe, or
    /// has a ceiling that is not a positive number.
    pub fn validate(&self) -> Result<(), PolicyError> {
        let max = Self::DEFAULT;
        if !self.strobe_banned {
            return Err(PolicyError::StrobeNotBanned);
        }
        check_ceiling(PolicyField::MaxFlashHz, self.max_flash_hz, max.max_flash_hz)?;
        check_ceiling(
            PolicyField::MaxLuminanceDelta,
            self.max_luminance_delta,
            max.max_luminance_delta,
        )?;
        check_ceiling(
            PolicyField::MaxFlashArea,
            self.max_flash_area,
            max.max_flash_area,
        )?;
        if self.max_red_flashes > max.max_red_flashes {
            return Err(PolicyError::Looser(PolicyField::MaxRedFlashes));
        }
        Ok(())
    }
}

impl Default for Policy {
    fn default() -> Self {
        Self::DEFAULT
    }
}

fn check_ceiling(field: PolicyField, value: f64, max: f64) -> Result<(), PolicyError> {
    if value.is_nan() || value <= 0.0 {
        return Err(PolicyError::NonPositive(field));
    }
    if value > max {
        return Err(PolicyError::Looser(field));
    }
    Ok(())
}

impl PolicyField {
    /// The field's name in the conformance vectors.
    pub fn name(self) -> &'static str {
        match self {
            PolicyField::MaxFlashHz => "maxFlashHz",
            PolicyField::MaxLuminanceDelta => "maxLuminanceDelta",
            PolicyField::MaxFlashArea => "maxFlashArea",
            PolicyField::MaxRedFlashes => "maxRedFlashes",
        }
    }
}

impl fmt::Display for PolicyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PolicyError::StrobeNotBanned => write!(f, "photosensitivity: strobe must be banned"),
            PolicyError::NonPositive(field) => {
                write!(f, "photosensitivity: {} must be positive", field.name())
            }
            PolicyError::Looser(field) => {
                write!(f, "photosensitivity: {} exceeds its default", field.name())
            }
        }
    }
}

impl core::error::Error for PolicyError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_valid() {
        assert_eq!(Policy::DEFAULT.validate(), Ok(()));
    }

    #[test]
    fn red_budget_may_be_zero() {
        let policy = Policy {
            max_red_flashes: 0,
            ..Policy::DEFAULT
        };
        assert_eq!(policy.validate(), Ok(()));
    }

    #[test]
    fn looser_values_are_refused_not_clamped() {
        let cases = [
            (
                Policy {
                    max_flash_hz: 3.5,
                    ..Policy::DEFAULT
                },
                PolicyField::MaxFlashHz,
            ),
            (
                Policy {
                    max_luminance_delta: 0.81,
                    ..Policy::DEFAULT
                },
                PolicyField::MaxLuminanceDelta,
            ),
            (
                Policy {
                    max_flash_area: 0.3,
                    ..Policy::DEFAULT
                },
                PolicyField::MaxFlashArea,
            ),
            (
                Policy {
                    max_red_flashes: 4,
                    ..Policy::DEFAULT
                },
                PolicyField::MaxRedFlashes,
            ),
        ];
        for (policy, field) in cases {
            assert_eq!(policy.validate(), Err(PolicyError::Looser(field)));
            assert!(crate::limiter::Limiter::new(policy).is_err());
        }
    }

    #[test]
    fn not_a_number_is_refused() {
        let policy = Policy {
            max_luminance_delta: f64::NAN,
            ..Policy::DEFAULT
        };
        assert_eq!(
            policy.validate(),
            Err(PolicyError::NonPositive(PolicyField::MaxLuminanceDelta))
        );
    }
}
