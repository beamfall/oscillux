// SPDX-License-Identifier: AGPL-3.0-only
// Host colour mode "vivid": a deterministic tour of the free-mode palette.
// With palette.x < 0 the originals' osPalVisual (shaders/originals/common.glsl)
// cross-fades vivid palettes floor(z) and floor(z) + 1 (mod 16). The tour loops
// through all sixteen, one palette every TOUR_SECONDS. hosts/apple/Sources/
// PaletteTour.swift is a port of this file.
export const TOUR_COUNT = 16;
export const TOUR_SECONDS = 6;
// Pre-tone-map saturation the vivid present pass applies; manifest mode uses 1.
export const VIVID_SATURATION = 1.35;
// Extra vivid saturation for dull colours, scaled by (1 - chroma)^2.
export const VIVID_VIBRANCE = 1.2;

// offset staggers visuals across the tour (any sign; z is wrapped into
// [0, TOUR_COUNT)); the hosts pass the manifest palette index so each visual
// starts somewhere different.
export function paletteTour(time, offset) {
  const z = (((time / TOUR_SECONDS + offset) % TOUR_COUNT) + TOUR_COUNT) % TOUR_COUNT;
  return [-1, 0, z, 0];
}
