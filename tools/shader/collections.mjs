// SPDX-License-Identifier: AGPL-3.0-only
// The reference hosts' curated visual collections (hosts/collections.json): an
// ordered list of collections, each an id, a label, a labelKey, an ordered
// list of visual ids and optionally the switch transitions to use between them
// (`transitions`, transition ids). A host may offer a collection as a playlist
// or a picker filter. This is reference-host data, not part of the core: a product host
// brings its own.
import { readFileSync } from 'node:fs';

export const COLLECTIONS_PATH = 'hosts/collections.json';

export function loadCollections(path = COLLECTIONS_PATH) {
  const c = JSON.parse(readFileSync(path, 'utf8'));
  if (!Array.isArray(c.collections)) throw new Error(`${path}: collections must be an array`);
  for (const e of c.collections) {
    for (const key of ['id', 'label', 'labelKey']) {
      if (typeof e?.[key] !== 'string' || e[key] === '') throw new Error(`${path}: every collection needs a string ${key}`);
    }
    if (!Array.isArray(e.visuals) || e.visuals.length === 0) throw new Error(`${path}: collection "${e.id}" needs a non-empty visuals array`);
    if (e.transitions !== undefined && (!Array.isArray(e.transitions) || e.transitions.length === 0)) {
      throw new Error(`${path}: collection "${e.id}": transitions, when given, must be a non-empty array`);
    }
  }
  return c.collections;
}

// Throws when two collections share an id, a collection's labelKey is not
// collection.<id>, or a collection repeats a visual or transition or names one
// that is not among `visuals` or `transitions`, so the file cannot drift from
// the bundled set.
export function checkCollections(collections, visuals, transitions = []) {
  const known = new Set(transitions.map(t => t.id));
  const ids = new Set(visuals.map(v => v.id));
  const seen = new Set();
  for (const c of collections) {
    if (seen.has(c.id)) throw new Error(`collection "${c.id}" is listed more than once`);
    seen.add(c.id);
    if (c.labelKey !== `collection.${c.id}`) throw new Error(`collection "${c.id}": labelKey must be collection.${c.id}`);
    const dup = c.visuals.find((id, i) => c.visuals.indexOf(id) !== i);
    if (dup) throw new Error(`collection "${c.id}" lists "${dup}" more than once`);
    const missing = c.visuals.filter(id => !ids.has(id));
    if (missing.length) throw new Error(`collection "${c.id}" lists visuals that are not bundled: ${missing.join(', ')}`);
    const trans = c.transitions ?? [];
    const dupT = trans.find((id, i) => trans.indexOf(id) !== i);
    if (dupT) throw new Error(`collection "${c.id}" lists transition "${dupT}" more than once`);
    const unknown = trans.filter(id => !known.has(id));
    if (unknown.length) throw new Error(`collection "${c.id}" lists transitions that are not bundled: ${unknown.join(', ')}`);
  }
  return collections;
}
