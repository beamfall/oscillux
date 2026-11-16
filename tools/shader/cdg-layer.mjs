// SPDX-License-Identifier: AGPL-3.0-only
// The CD+G lyric layer for the present pass (OSC-CDG): shaders/cdg/cdg-composite.glsl reading
// the present layer texture, then shaders/cdg/cdg-layer.glsl. bundle-hosts.mjs bundles the
// present pass with it as `presentCdg`, and cdg-check.mjs compiles it for both legs.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const CDG = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'shaders', 'cdg');

/** Floats of the PresentLayerBlock the CD+G layer reads: size, place and halo. */
export const CDG_LAYER_BLOCK_FLOATS = 12;

/** The layer source for presentGLSL300({ layer }) and presentMSL({ layer }). */
export function cdgPresentLayer() {
  return ['#define OSC_CDG_FETCH(cell) PRESENT_LAYER_FETCH(cell)',
    readFileSync(join(CDG, 'cdg-composite.glsl'), 'utf8'),
    readFileSync(join(CDG, 'cdg-layer.glsl'), 'utf8')].join('\n');
}
