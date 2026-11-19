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

// The most cells a run of `len` pixels touches along an axis of `n` pixels split into `cells`
// cells of SUB sub-blocks each (sub-block of pixel x: floor((cells SUB (x + 1) - 1) / n)).
function span(len, n, cells) {
  const cellOf = x => Math.floor(Math.floor((cells * SUB * (x + 1) - 1) / n) / SUB);
  let most = 1;
  for (let s = 0; s + len <= n; s++) most = Math.max(most, cellOf(s + len - 1) - cellOf(s) + 1);
  return most;
}

/** The window the limiter uses for a geometry on a W x H frame: the field is fwPx x fhPx pixels
 * (as the auditor rounds it), the window the fewest whole cells that contain the field wherever it
 * is placed, and the area limit a quarter of the field's pixels (a window is over it when its
 * changed pixels are strictly more). */
export function windowOf(geometry, W, H) {
  const g = typeof geometry === 'string' ? GEOMETRY[geometry] : geometry;
  if (!g) throw new Error(`unknown geometry ${geometry}`);
  if (!(W > 0 && H > 0)) throw new Error('windowOf: frame size required');
  const fwPx = Math.max(1, Math.min(W, Math.round(g.fw * W)));
  const fhPx = Math.max(1, Math.min(H, Math.round(g.fh * H)));
  return { cols: span(fwPx, W, GRID_X), rows: span(fhPx, H, GRID_Y), fwPx, fhPx, limit: Math.floor((fwPx * fhPx) / 4) };
}
