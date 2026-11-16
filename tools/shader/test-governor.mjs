// SPDX-License-Identifier: AGPL-3.0-only
// Checks the host governor port (governor.mjs) against conformance/governor.
import { readFileSync } from 'node:fs';
import { Governor, GOVERNOR_DEFAULTS, validGovernorConfig } from './governor.mjs';

const load = name => JSON.parse(readFileSync(new URL(`../../conformance/governor/${name}`, import.meta.url)));
const ref = load('reference.json');
const failures = [];
const near = (a, b) => (a === null || b === null) ? a === b : Math.abs(a - b) <= ref.tolerance;
const check = (src, label, got, want) => {
  if (got.level !== want.level || !near(got.emaMs, want.emaMs) || !near(got.refreshMs, want.refreshEstimateMs))
    failures.push(`${src} ${label}: got level ${got.level} ema ${got.emaMs} refresh ${got.refreshMs}, want ${JSON.stringify(want)}`);
};

for (const c of ref.cases) {
  const g = new Governor(c.config);
  check(c.source, 'initial', g, c.initial);
  c.steps.forEach((s, i) => {
    for (let n = 0; n < s.count; n++) g.record(s.samples[n % s.samples.length]);
    check(c.source, `step ${i}`, g, s.want);
  });
  if (c.reset) { g.reset(c.reset.level); check(c.source, 'reset', g, c.reset.want); }
}
for (const c of load('validation.json').cases)
  if (validGovernorConfig({ ...GOVERNOR_DEFAULTS, ...c.config }) !== c.valid) failures.push(`validation ${c.name}`);

if (failures.length) { console.error(failures.join('\n')); process.exit(1); }
console.log(`test-governor: ${ref.cases.length} reference cases match`);
