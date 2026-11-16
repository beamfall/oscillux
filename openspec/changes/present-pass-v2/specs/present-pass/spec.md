<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Present pass

## ADDED Requirements

### Requirement: Hue-preserving tone map

The present pass SHALL tone map linear light on luminance and SHALL keep the HSV hue of every
colour. A colour that would pass 1 in any channel SHALL move toward the grey of its mapped
luminance until it fits. Greys SHALL map exactly as the per-channel ACES fit maps them.

#### Scenario: Saturated ramp

- **WHEN** the saturated-colour ramp (24 hues, saturation 1 and 0.75, exposures 2^-4 to 2^4) is
  presented to 8-bit codes without dither
- **THEN** the max hue error over entries whose codes span at least 32 codes is at most 2 degrees

### Requirement: Dithered fixed-point output

On a fixed-point output, the pass SHALL add triangular dither of `post0.w` codes before
quantising, from an integer hash of the pixel and the frame seed. Within one code of either end
the dither SHALL be rectangular. Codes 0 and the top code SHALL stay exact. Text-region pixels
SHALL round toward their contrast bound instead of dithering.

#### Scenario: Dark gradient

- **WHEN** a linear 0 to 0.032 gradient across 1920 columns is presented with dither 1
- **THEN** no row holds one code for more than 32 px, and no 16-column mean is more than 0.1 code
  from the ideal

#### Scenario: Black and white

- **WHEN** black and clipped white are presented with dither 1
- **THEN** every channel is code 0 or the top code

### Requirement: Post effects and reduced motion

The pass SHALL add `post0.x` times the bloom chain's L0 in linear light before the grade. It
SHALL apply radial chromatic aberration of `post0.y` and multiplicative grain of `post0.z`
without trigonometric hashing. Under reduced motion the grain SHALL be 0, and hosts SHALL upload
trail decay 0.

#### Scenario: Reduced motion

- **WHEN** the packed overlay block has reduced motion set
- **THEN** the pass adds no grain, whatever `post0.z` holds

### Requirement: Pass order and budget

The present pass SHALL run before the flash limiter, which stays the last stage before output.
The bloom chain and present pass together SHALL take at most 1.5 ms of GPU time at 1920x1080 on
a Metal GPU.

#### Scenario: Timing

- **WHEN** `make present-v2-gpu` times the chain over 200 iterations after 20 warm-up iterations
- **THEN** the median command-buffer GPU time is at most 1.5 ms
