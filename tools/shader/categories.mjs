// SPDX-License-Identifier: AGPL-3.0-only
// The reference hosts' visual categories (hosts/categories.json): an ordered
// list of types, an ordered list of intensities, and per visual id its
// [type, intensity]. The hosts filter their visual picker by both. This is
// reference-host data, not part of the core: a product host brings its own.
import { readFileSync } from 'node:fs';

export const CATEGORIES_PATH = 'hosts/categories.json';

export function loadCategories(path = CATEGORIES_PATH) {
  const c = JSON.parse(readFileSync(path, 'utf8'));
  for (const key of ['types', 'intensities']) {
    if (!Array.isArray(c[key]) || c[key].length === 0) throw new Error(`${path}: ${key} must be a non-empty array`);
    for (const e of c[key]) {
      if (typeof e?.id !== 'string' || typeof e?.label !== 'string') throw new Error(`${path}: every ${key} entry needs a string id and label`);
    }
  }
  if (typeof c.visuals !== 'object' || c.visuals === null) throw new Error(`${path}: visuals must be an object`);
  return c;
}

// Sets `type` and `intensity` on every visual from `categories`. Throws when a
// visual has no category, names an unknown type or intensity, or the file
// lists an id that is not among `visuals`, so the file cannot drift from the set.
export function categorize(visuals, categories) {
  const types = new Set(categories.types.map(t => t.id));
  const intensities = new Set(categories.intensities.map(i => i.id));
  const ids = new Set(visuals.map(v => v.id));
  const stale = Object.keys(categories.visuals).filter(id => !ids.has(id));
  if (stale.length) throw new Error(`categories list visuals that are not bundled: ${stale.join(', ')}`);
  for (const v of visuals) {
    const entry = categories.visuals[v.id];
    if (!entry) throw new Error(`visual "${v.id}" has no category`);
    const [type, intensity] = entry;
    if (!types.has(type)) throw new Error(`visual "${v.id}": unknown type "${type}"`);
    if (!intensities.has(intensity)) throw new Error(`visual "${v.id}": unknown intensity "${intensity}"`);
    v.type = type;
    v.intensity = intensity;
  }
  return visuals;
}
