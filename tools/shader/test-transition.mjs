// SPDX-License-Identifier: AGPL-3.0-only
// Checks the web host's transition scheduler port (hosts/web/transition.js)
// against conformance/transition/reference.json. Every value must match exactly.
import { readFileSync } from 'node:fs';
import { TransitionScheduler } from '../../hosts/web/transition.js';

const ref = JSON.parse(readFileSync(new URL('../../conformance/transition/reference.json', import.meta.url)));
const num = v => (v === 'NaN' ? NaN : v === 'Infinity' ? Infinity : v === '-Infinity' ? -Infinity : v);
const clock = a => ({ timeSeconds: num(a[0]), beatPhase: num(a[1]), barPhase: num(a[2]), tempoBpm: num(a[3]), confidence: num(a[4]) });
const failures = [];
let steps = 0;
if (ref.tolerance !== 0) failures.push(`tolerance ${ref.tolerance}, expected 0`);
for (const c of ref.cases) {
  const k = c.config;
  const config = { easing: k.easing, beatsPerBar: k.beats_per_bar, autoAdvanceBars: k.auto_advance_bars,
    durationBeats: num(k.duration_beats), fallbackSeconds: num(k.fallback_seconds),
    preRollSeconds: num(k.pre_roll_seconds), minConfidence: num(k.min_confidence) };
  let s;
  try { s = new TransitionScheduler(config); } catch { s = null; }
  if (c.create) { if (s) failures.push(`${c.name}: must be refused at creation`); continue; }
  if (!s) { failures.push(`${c.name}: refused at creation`); continue; }
  c.steps.forEach((step, i) => {
    const out = TransitionScheduler.status();
    let ok = true;
    if (step.op === 'request') ok = s.request(clock(step.clock), step.quantise, num(step.max_wait), out);
    else if (step.op === 'update') ok = s.update(clock(step.clock), out);
    else if (step.op === 'status') ok = s.status(num(step.time), out);
    else if (step.op === 'reset') { s.reset(); steps++; return; }
    else failures.push(`${c.name} step ${i}: op ${step.op}`);
    steps++;
    if (step.want === 'refused') { if (ok) failures.push(`${c.name} step ${i}: must be refused`); return; }
    if (!ok) { failures.push(`${c.name} step ${i}: refused`); return; }
    const got = [out.progress, out.requestSeconds, out.startSeconds, out.endSeconds, out.state, out.quantise, out.autoRequested];
    step.want.forEach((w, f) => {
      if (!Object.is(got[f], num(w))) failures.push(`${c.name} step ${i} field ${ref.status_fields[f]}: got ${got[f]}, want ${w}`);
    });
  });
}
if (failures.length) { console.error(failures.slice(0, 40).join('\n')); process.exit(1); }
console.log(`test-transition: ${ref.cases.length} cases (${steps} steps) match exactly`);
