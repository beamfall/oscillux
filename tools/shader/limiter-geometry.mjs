// SPDX-License-Identifier: AGPL-3.0-only
// Reference viewing geometry per device class for the frame flash limiter's 10° flash area
// (conformance/limiter/frame/README.md, "Viewing geometry"). A 10° visual field at viewing
// distance d spans 2 d tan(5°); fw and fh are that span over the screen's width and height,
// capped at the whole frame. WCAG 2.x defines the area on a 1024 x 768 screen as 341 x 256 pixels
// (a third by a third); that is the default when a host does not know its device class.

const SPAN = 2 * Math.tan((5 * Math.PI) / 180);

function physical(label, diagonalIn, aspectW, aspectH, distanceMm, source) {
  const diag = diagonalIn * 25.4;
  const k = diag / Math.hypot(aspectW, aspectH);
  const screenMm = [aspectW * k, aspectH * k];
  const spanMm = SPAN * distanceMm;
  return { label, diagonalIn, aspect: `${aspectW}:${aspectH}`, screenMm, distanceMm, spanMm, source,
    fw: Math.min(1, spanMm / screenMm[0]), fh: Math.min(1, spanMm / screenMm[1]) };
}

export const GEOMETRY = Object.freeze({
  wcag: { label: 'WCAG 2.x reference (341 x 256 of 1024 x 768)', fw: 1 / 3, fh: 1 / 3,
    source: 'WCAG 2.2 Understanding SC 2.3.1, "general flash and red flash thresholds"' },
  desktop: physical('Desktop monitor', 24, 16, 9, 600, 'ISO 9241-303 / ANSI-HFES 100 desktop viewing distance (50-70 cm)'),
  phone: physical('Phone, landscape', 6.1, 19.5, 9, 300, 'Handheld reading distance (about 30 cm)'),
  tv: physical('Living-room TV', 55, 16, 9, 3048, '10-foot user interface convention (3.048 m)'),
});

export const GRID_X = 16, GRID_Y = 9, SUB = 4;

/** The window (whole cells) and area limit (sub-blocks) the limiter uses for a geometry. */
export function windowOf(geometry) {
  const g = typeof geometry === 'string' ? GEOMETRY[geometry] : geometry;
  if (!g) throw new Error(`unknown geometry ${geometry}`);
  const fieldX = g.fw * GRID_X, fieldY = g.fh * GRID_Y;
  return {
    cols: Math.min(GRID_X, Math.max(1, Math.round(fieldX))),
    rows: Math.min(GRID_Y, Math.max(1, Math.round(fieldY))),
    // 25% of the field's true area, in sub-blocks; a window is over it when strictly greater.
    limit: Math.fround(0.25 * fieldX * fieldY * SUB * SUB),
  };
}
