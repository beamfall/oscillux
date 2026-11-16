// SPDX-License-Identifier: AGPL-3.0-only
// Import the reference visual set from a beamfall-visual-shaders checkout.
//
//   node tools/shader/import-visuals.mjs <source checkout> [--out DIR] [--check]
//
// Reads catalog.json and catalog.parts/*.json. Writes DIR/visuals/<id>.glsl and
// DIR/manifest.json (default DIR: shaders). DIR/library.glsl, the shared visual library
// used as the prelude, is locally owned (LOCALLY_OWNED below): never written or checked. Header
// comments that name a product, a tier or a sibling source file are dropped, so
// the set is host data with no product policy (AGENTS.md invariant 1). Any
// such name left outside a header fails the import. With --check, nothing is
// written and the exit status is 1 when DIR differs from what would be written.
// Param controls and tunables come from param-controls.mjs, using the catalog's labels. An entry
// with name, blurb, tier, input, overlay and calm keeps them as the manifest's catalog fields, with
// imageCapable when set and the labels of params it does not read as unreadParamLabels;
// catalogOrder is catalog.json's order, then catalog.parts/*.json by file name.
import { readFileSync, readdirSync, mkdirSync, writeFileSync, existsSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { visualControls } from './param-controls.mjs';
import { CATALOG_KEYS, POST_KEYS } from './manifest.mjs';

const SPDX = '// SPDX-License-Identifier: AGPL-3.0-only\n';
const DROP = /beamfall|apple-ui|\.metal\b|Shaders\/|keep in sync|hand-sync|^\/\/\s*Portable (?:port|body)/i;
const TIER = /(?:\s+[—/-])?\s+(?:Flagship|Lite|Standard)\b/;
const HERITAGE = /Web-heritage\s+"[^"]*"\s+upgraded[.:]?\s*/;
export const FORBIDDEN = /beamfall|flagship|heritage|\.metal\b|Apple TV/i;

// Files Oscillux owns, which the import never writes and --check never compares. library.glsl
// carries Oscillux's own hashes, which replaced third-party ones for licence provenance
// (THIRD-PARTY-NOTICES.md), and local uniforms: an upstream copy would bring the old hashes back.
export const LOCALLY_OWNED = new Set(['library.glsl']);

const LIBRARY_HEADER = `${SPDX}// Shared visual library: the prelude for the reference visual set
// (docs/shader-toolchain.md). Compiles as GLSL ES 3.00 and GLSL 450.
//
// Portable-subset rules for visual bodies:
//   - texture reads only through the IMG(uv) / PREV(uv) macros the wrapper defines
//   - two-argument arctangent is atan2_(y, x), never atan(y, x)
//   - no raw texture() calls and no derivatives beyond fwidth()
//   - visuals output linear HDR and never tonemap
`;

// The controls are read against DIR's own library when it exists, else the upstream one.
export function importVisuals(src, out = 'shaders') {
  const parts = readdirSync(join(src, 'catalog.parts')).filter(f => f.endsWith('.json')).sort();
  const entries = JSON.parse(readFileSync(join(src, 'catalog.json'), 'utf8')).visuals.concat(parts.flatMap(f => {
    const doc = JSON.parse(readFileSync(join(src, 'catalog.parts', f), 'utf8'));
    return Array.isArray(doc) ? doc : doc.visuals;
  }));
  const catalogOrder = entries.map(e => e.id);
  entries.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  const files = new Map();
  const localLibrary = join(out, 'library.glsl');
  const library = existsSync(localLibrary) ? readFileSync(localLibrary, 'utf8')
    : LIBRARY_HEADER + stripHeader(readFileSync(join(src, 'shared', 'visual_shared.glsl'), 'utf8'), 'library', true);
  const visuals = entries.map(e => {
    const body = readFileSync(join(src, 'visuals', `${e.id}.glsl`), 'utf8');
    files.set(`visuals/${e.id}.glsl`, SPDX + stripHeader(body, e.id, false));
    const { params, tunables } = visualControls(e.id, library, files.get(`visuals/${e.id}.glsl`),
      e.params.map(p => ({ label: p.label, default: p.def })));
    const header = `// ${e.name}: ${e.blurb}`;
    check(header, `${e.id} header`);
    const listed = CATALOG_KEYS.every(k => e[k] !== undefined);
    const unread = Object.fromEntries(e.params.slice(0, 3).flatMap((p, i) =>
      params.some(c => c.uniform === `param${i}`) ? [] : [[`param${i}`, p.label]]));
    return {
      id: e.id,
      body: `visuals/${e.id}.glsl`,
      targets: ['web', 'vulkan', 'msl', 'hlsl'],
      imageInput: /\bimage\b/.test(e.input),
      header,
      ...(listed ? Object.fromEntries(CATALOG_KEYS.map(k => [k, e[k]])) : {}),
      ...(listed && e.imageCapable !== undefined ? { imageCapable: e.imageCapable } : {}),
      ...(listed && Object.keys(unread).length ? { unreadParamLabels: unread } : {}),
      palette: [e.palette.index, 0, e.palette.phase, 0],
      ...(params.length ? { params } : {}),
      ...(tunables.length ? { tunables } : {}),
      trailDecay: e.postFX?.trailDecay ?? 0.82,
      ...(e.postFX && POST_KEYS.every(k => k in e.postFX) ? { post: Object.fromEntries(POST_KEYS.map(k => [k, e.postFX[k]])) } : {}),
    };
  });
  files.set('manifest.json', JSON.stringify({ prelude: 'library.glsl', visuals, catalogOrder }, null, 2) + '\n');
  return files;
}

// Rewrite the leading // comment block; the rest of the file must already be clean.
// The library's header is replaced whole (dropAll).
function stripHeader(text, at, dropAll) {
  const lines = text.replace(/Apple TV friendly/g, 'light on low-power GPUs').split('\n');
  let n = 0;
  while (n < lines.length && /^\s*\/\//.test(lines[n])) n++;
  const head = dropAll ? [] : lines.slice(0, n).flatMap(line => {
    if (DROP.test(line)) return [];
    const out = line.replace(TIER, '').replace(HERITAGE, '');
    return /^\/\/\s*$/.test(out) && !/^\/\/\s*$/.test(line) ? [] : [out];
  });
  const rest = lines.slice(n).join('\n');
  const result = [...head, rest].join('\n');
  check(result, at);
  return result;
}

function check(text, at) {
  const m = text.match(FORBIDDEN);
  if (m) throw new Error(`${at}: product or tier name left after import: ${JSON.stringify(m[0])}`);
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: { out: { type: 'string', default: 'shaders' }, check: { type: 'boolean', default: false } },
  });
  if (positionals.length !== 1) {
    console.error('usage: import-visuals.mjs <source checkout> [--out DIR] [--check]');
    process.exit(2);
  }
  const out = resolve(values.out);
  const files = importVisuals(resolve(positionals[0]), out);
  let stale = 0;
  for (const [name, text] of files) {
    const path = join(out, name);
    if (values.check) {
      if (!existsSync(path) || readFileSync(path, 'utf8') !== text) { console.error(`stale: ${name}`); stale++; }
    } else {
      mkdirSync(join(path, '..'), { recursive: true });
      writeFileSync(path, text);
    }
  }
  if (values.check) {
    const visualsDir = join(out, 'visuals');
    for (const f of existsSync(visualsDir) ? readdirSync(visualsDir) : []) {
      if (!files.has(`visuals/${f}`)) { console.error(`orphan: visuals/${f}`); stale++; }
    }
  }
  console.log(`${files.size - 1} visuals ${values.check ? (stale ? `${stale} files stale` : 'match') : `written to ${out}`}`);
  process.exit(stale ? 1 : 0);
}
