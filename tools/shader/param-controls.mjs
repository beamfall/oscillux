// SPDX-License-Identifier: AGPL-3.0-only
// Manifest param controls and tunables (manifest.mjs) for a visual body, from a label and a
// default per param uniform. import-visuals.mjs writes the imported set's entries with it.
// The step is 1 / (b - a) where the body rounds mix(a, b, u.paramN) to an integer, else 0.01;
// the group is a keyword match on the label. Hand-written entries may set any field.
import { PARAM_UNIFORMS, TUNABLES, uniformReads } from './manifest.mjs';

const GROUPS = [
  ['motion', /speed|spin|sway|drift|flow|flight|scroll|rotat|orbit|wander|warp|swirl|turbulen|wobble|tempo/i],
  ['reaction', /pulse|punch|bass|reactiv|response|gain|burst|kick|swell|impact|beat|jitter/i],
  ['color', /colou?r|hue|glow|bright|heat|spectra|prism|shine|tint|warm|fire|neon|emission|ink|saturat|light|corona|flare/i],
  ['detail', /detail|sparkle|grain|noise|fuzz|fine|texture|sharp|rough|ripple|fracture|spark|dust|streak/i],
];

// slots[i] = { label, default } for PARAM_UNIFORMS[i]; slots the body does not read are dropped.
export function visualControls(visualId, prelude, body, slots) {
  const reads = uniformReads(prelude, body);
  const ids = new Set();
  const params = PARAM_UNIFORMS.flatMap((uniform, i) => {
    if (!reads.has(uniform)) return [];
    const { label, default: value } = slots[i];
    let id = label.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
    if (ids.has(id)) id = `${id}-${i}`;
    ids.add(id);
    const span = discreteSpan(body, uniform);
    return [{
      id, uniform, label, labelKey: `visual.${visualId}.${id}`, min: 0, max: 1, default: value,
      step: span ? Math.round(1e6 / span) / 1e6 : 0.01, curve: 'linear',
      group: GROUPS.find(([, re]) => re.test(label))?.[0] ?? 'shape',
    }];
  });
  return { params, tunables: TUNABLES.filter(t => reads.has(t)) };
}

function discreteSpan(body, uniform) {
  const m = new RegExp(`int\\(\\s*(?:floor\\(\\s*)?mix\\(\\s*(-?[\\d.]+)\\s*,\\s*(-?[\\d.]+)\\s*,\\s*u\\.${uniform}\\s*\\)`).exec(body);
  if (!m || !Number.isInteger(Number(m[1])) || !Number.isInteger(Number(m[2]))) return 0;
  return Math.abs(Number(m[2]) - Number(m[1]));
}
