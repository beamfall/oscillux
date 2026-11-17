// SPDX-License-Identifier: AGPL-3.0-only
// Checks the reference host's palette tour (palette-tour.mjs) against conformance/palette-tour.
import { readFileSync } from 'node:fs';
import { paletteTour, TOUR_COUNT, TOUR_SECONDS, VIVID_SATURATION, VIVID_VIBRANCE } from './palette-tour.mjs';

const ref = JSON.parse(readFileSync(new URL('../../conformance/palette-tour/vectors.json', import.meta.url)));
const failures = [];
if (TOUR_COUNT !== ref.tourCount || TOUR_SECONDS !== ref.tourSeconds) failures.push('tour constants');
if (VIVID_SATURATION !== ref.vividPresent.saturation || VIVID_VIBRANCE !== ref.vividPresent.vibrance)
  failures.push('vivid present defaults');
for (const c of ref.cases) {
  const [x, y, z, w] = paletteTour(c.timeSeconds, c.offset);
  if (x !== -1 || y !== 0 || w !== 0 || Math.abs(z - c.want[2]) > ref.tolerance)
    failures.push(`${c.timeSeconds}, ${c.offset}: got ${[x, y, z, w]}, want ${c.want}`);
}
if (failures.length) { console.error(failures.join('\n')); process.exit(1); }
console.log(`test-palette-tour: ${ref.cases.length} cases match`);
