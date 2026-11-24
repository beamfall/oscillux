// SPDX-License-Identifier: AGPL-3.0-only
// The manifest loader requires each catalog visual's measured safety block (CORE-3417) and refuses
// a missing block, an unknown or missing key and an out-of-range value.
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { loadManifest } from './manifest.mjs';

const path = fileURLToPath(new URL('../../shaders/manifest.json', import.meta.url));
const doc = JSON.parse(readFileSync(path, 'utf8'));
const failures = [];

const loaded = loadManifest(path);
for (const v of loaded.visuals) {
  if (!v.catalog?.safety) failures.push(`${v.id}: loaded without safety`);
}

const scratch = path.replace(/manifest\.json$/, `.test-safety-${process.pid}.json`);
const refused = (name, mutate) => {
  const copy = structuredClone(doc);
  mutate(copy.visuals[0].safety, copy.visuals[0]);
  writeFileSync(scratch, JSON.stringify(copy));
  try {
    loadManifest(scratch);
    failures.push(`${name}: loaded`);
  } catch {
    // refused, as required
  } finally {
    rmSync(scratch, { force: true });
  }
};
refused('missing block', (_, v) => { delete v.safety; });
refused('missing maxRedFlashHz', s => { delete s.maxRedFlashHz; });
refused('unknown key', s => { s.patternSafe = true; });
refused('negative flash', s => { s.maxFlashHz = -1; });
refused('red flash over 30', s => { s.maxRedFlashHz = 31; });
refused('luminance over 1', s => { s.maxLuminanceDelta = 1.5; });
refused('unknown zone', s => { s.textSafeZone = 'left'; });

if (failures.length) {
  console.error(failures.join('\n'));
  process.exit(1);
}
console.log(`test-safety: ${loaded.visuals.length} visuals carry safety; 7 invalid blocks refused`);
