// SPDX-License-Identifier: AGPL-3.0-only
// Checks that every original finishes through osOffRed (shaders/originals/common.glsl), that the
// GLSL is the form emulated here, and that osOffRed keeps reds off saturated red through the vivid
// present (shaders/present/present.glsl), emulated in double precision:
// - the presented red share stays under the limiter's 0.8 saturated-red share;
// - the conservative byte checker (OpenSpec change limiter-red-expire-black, design.md section 3)
//   finds no redSat byte triple for any dither noise, grain factor or regime, at CI density: the
//   grid and 20,000 random colours per grain. It proves one input at a time and does not bound the
//   colours between samples; its own positive control is the Codex round 1 repro at the round 1
//   parameters;
// - NaN and infinity inputs, and two colours that meet the share returned bit for bit in float32.
import { readFileSync } from 'node:fs';
import { VIVID_SATURATION, VIVID_VIBRANCE } from './palette-tour.mjs';
import { redSat } from './limiter-model.mjs';

const root = new URL('../../shaders/originals/', import.meta.url);
const failures = [];
const fail = m => failures.push(m);

// The emulated form, with the constants of the GLSL.
const M0 = 0.006, MF = 0.012, M2 = 0.05, SHARE = 0.55;
const common = readFileSync(new URL('common.glsl', root), 'utf8');
const glsl = String.raw`const float OS_GREY_BELOW = 0\.006;[^\n]*
const float OS_RED_FROM = 0\.012;[^\n]*
const float OS_RED_FULL = 0\.05;[^\n]*
vec3 osOffRed\(vec3 c\) \{
    c = mix\(c, vec3\(0\.0\), notEqual\(c, c\)\);[^\n]*
    c = clamp\(c, vec3\(0\.0\), vec3\(16\.0\)\);
    float s = c\.g \+ c\.b, t = 0\.55 \* c\.r;[^\n]*
    if \(s < t\) c \+= vec3\(0\.0, 0\.5 \* \(t - s\), 0\.5 \* \(t - s\)\);[^\n]*
    float m = max\(c\.r, max\(c\.g, c\.b\)\);
    if \(m < OS_GREY_BELOW\) return vec3\(luma\(c\)\);[^\n]*
    float p = max\(c\.g, c\.b\);
    if \(c\.r > p && m < OS_RED_FULL\) \{[^\n]*
        float w = clamp\(\(m - OS_RED_FROM\) / \(OS_RED_FULL - OS_RED_FROM\), 0\.0, 1\.0\);
        c\.r = w <= 0\.0 \? p : p \+ w \* \(c\.r - p\);[^\n]*
    \}
    return c;
\}`;
if (!new RegExp(glsl).test(common)) fail('common.glsl: osOffRed is not the form this test emulates');

const manifest = JSON.parse(readFileSync(new URL('manifest.json', root), 'utf8'));
const finish = 'vec3 visual(vec2 uv, VisualUniforms u) { return osOffRed(osBody(uv, u)); }';
for (const v of manifest.visuals) {
  const src = readFileSync(new URL(v.body, root), 'utf8');
  const visuals = src.match(/\bvec3\s+visual\s*\(/g) ?? [];
  if (visuals.length !== 1 || !src.includes(finish)) fail(`${v.id}: visual() does not return osOffRed(osBody(uv, u))`);
  if ((src.match(/\bvec3\s+osBody\s*\(/g) ?? []).length !== 1) fail(`${v.id}: needs exactly one osBody`);
}

const LUMA = [0.2126, 0.7152, 0.0722];
const lum = c => c[0] * LUMA[0] + c[1] * LUMA[1] + c[2] * LUMA[2];
// osOffRed with arithmetic `op` per operation: identity for double, Math.fround for float32.
const offRed = (op, P = { M0, MF, M2 }) => c => {
  let [r, g, b] = c.map(x => (x !== x ? 0 : Math.min(Math.max(x, 0), 16)));
  const s = op(g + b), t = op(op(SHARE) * r);
  if (s < t) { const h = op(op(0.5) * op(t - s)); g = op(g + h); b = op(b + h); }
  const m = Math.max(r, g, b);
  if (m < P.M0) { const l = op(lum([r, g, b])); return [l, l, l]; }
  const p = Math.max(g, b);
  if (r > p && m < P.M2) {
    const w = Math.min(Math.max(op(op(m - op(P.MF)) / op(op(P.M2) - op(P.MF))), 0), 1);
    r = w <= 0 ? p : op(p + op(w * op(r - p)));
  }
  return [r, g, b];
};
const osOffRed = offRed(x => x);
const osOffRed32 = offRed(Math.fround);

// The per-pixel present path: suppressGreenCast (the wrapper), the vivid grade and the tone map.
const suppress = c => {
  const rb = Math.max(c[0], c[2]), l = (c[0] + c[1] + c[2]) * 0.3333333;
  const ex = Math.max(0, c[1] - Math.max(rb * 1.08, l * 0.78));
  return [c[0] + ex * 0.34, c[1] - ex * 0.78, c[2] + ex * 0.86];
};
const aces = v => Math.min(Math.max((v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14), 0), 1);
const present = x => {
  const l = lum(x), mx = Math.max(...x), mn = Math.min(...x);
  const chroma = mx > 1e-4 ? Math.min(Math.max((mx - mn) / mx, 0), 1) : 1;
  const k = VIVID_SATURATION + VIVID_VIBRANCE * (1 - chroma) ** 2;
  x = x.map(v => Math.max(l + (v - l) * k, 0));
  const lx = lum(x);
  if (lx <= 1e-6) return x.map(v => v * (0.03 / 0.14));
  const t = aces(lx);
  let c = x.map(v => v * (t / lx));
  const m = Math.max(...c);
  if (m > 1) c = c.map(v => t + (v - t) * ((1 - t) / (m - t)));
  return c.map(v => Math.min(Math.max(v, 0), 1));
};

// Red from dim to HDR, green and blue from none to equal to red in each split.
let worst = 0, at = null;
for (const r of [0.02, 0.05, 0.1, 0.2, 0.4, 0.7, 1, 1.5, 2.5, 4, 8, 16]) {
  for (let q = 0; q <= 1.0001; q += 0.01) {
    for (const split of [0, 0.25, 0.5, 0.75, 1]) {
      const c = present(osOffRed([r, r * q * split, r * q * (1 - split)]));
      const sum = c[0] + c[1] + c[2];
      if (sum <= 0) continue;
      const share = c[0] / sum;
      if (share > worst) { worst = share; at = [r, q, split]; }
    }
  }
}
if (!(worst < 0.78)) fail(`presented red share ${worst.toFixed(4)} at r, (g+b)/r, split = ${at}: want < 0.78`);

// The conservative byte checker. For display-linear c after present, grain amplitude g (split in
// `slices`) and dither amplitude A (0: none), it returns a redSat triple the present could write,
// or null. redSat is monotone (true stays true as red rises or green or blue falls), so red is
// taken at the top of its code interval and green and blue at the bottom, over every regime the
// interval reaches (snap under 1/1024, rectangular under one code, triangular above). The shared
// noise rect = u1 - 0.5, tri = rect + (u2 - 0.5) is enumerated cell by cell: the cell walls are
// rect = const, tri = const and tri = rect +- 0.5.
const L = 255, E = 1 / 1024;
const enc = s => (s <= 0.0031308 ? s * 12.92 : 1.055 * Math.pow(s, 1 / 2.4) - 0.055);
const regimes = (lo, hi) => {
  const r = [];
  if (lo < E) r.push('z');
  if (hi > L - E) r.push('w');
  if (hi >= E && lo < 1) r.push('rl');
  if (hi >= 1 && lo <= L - 1) r.push('t');
  if (hi > L - 1 && lo <= L - E) r.push('rh');
  return r;
};
const code = (reg, q, A, rect, tri) => (reg === 'z' ? 0 : reg === 'w' ? L
  : Math.min(Math.max(Math.floor(q + 0.5 + A * (reg === 't' ? tri : rect)), 0), L));
const mids = (arr, lo, hi) => {
  const s = [...new Set([lo, hi, ...arr.filter(x => x > lo && x < hi)])].sort((x, y) => x - y);
  const m = [];
  for (let i = 0; i + 1 < s.length; i++) m.push((s[i] + s[i + 1]) / 2);
  return m;
};
function sliceSat(c, s0, s1, A) {
  const qlo = c.map(v => enc(Math.min(v * s0, 1)) * L), qhi = c.map(v => enc(Math.min(v * s1, 1)) * L);
  const reg = [0, 1, 2].map(i => regimes(qlo[i], qhi[i]));
  const q = [qhi[0], qlo[1], qlo[2]];
  if (A === 0) {
    const k = [Math.min(Math.ceil(q[0]), L), Math.floor(q[1]), Math.floor(q[2])];
    return redSat(...k) ? k : null;
  }
  const bp = [];
  for (const v of q) for (let j = Math.floor(v + 0.5 - A) - 1; j <= Math.ceil(v + 0.5 + A) + 1; j++) bp.push((j - v - 0.5) / A);
  for (const rect of mids([...bp, ...bp.map(t => t - 0.5), ...bp.map(t => t + 0.5)], -0.5, 0.5)) {
    for (const tri of mids(bp, Math.max(-1, rect - 0.5), Math.min(1, rect + 0.5))) {
      const k = [
        Math.max(...reg[0].map(r => code(r, q[0], A, rect, tri))),
        Math.min(...reg[1].map(r => code(r, q[1], A, rect, tri))),
        Math.min(...reg[2].map(r => code(r, q[2], A, rect, tri))),
      ];
      if (redSat(...k)) return k;
    }
  }
  return null;
}
function satTriple(c, g, A, slices) {
  if (c[0] === c[1] || c[0] === c[2]) return null; // red equal to a partner stays equal (structural)
  for (let i = 0; i < (g > 0 ? slices : 1); i++) {
    const k = sliceSat(c, 1 - g + (2 * g * i) / slices, 1 - g + (2 * g * (i + 1)) / slices, A);
    if (k) return k;
  }
  return null;
}
const SLICES = 8;
let checked = 0;
const bytesFail = [];
const check = (c, grains, dithers) => {
  const d = present(suppress(osOffRed(c)));
  for (const g of grains) for (const A of dithers) {
    checked++;
    const k = satTriple(d, g, A, SLICES);
    if (k && bytesFail.length < 5) bytesFail.push(`(${c.map(v => v.toPrecision(4))}) grain ${g} dither ${A}: (${k})`);
  }
};
// The grid: max channel at 201 log steps from 1e-4 to 16, the others at every 1/32 of it.
for (let i = 0; i <= 200; i++) {
  const m = 1e-4 * Math.pow(16 / 1e-4, i / 200);
  for (let a = 0; a <= 32; a++) for (let b = 0; b <= 32; b++) for (const mc of [0, 1, 2]) {
    const c = [0, 0, 0], o = [0, 1, 2].filter(x => x !== mc);
    c[mc] = m; c[o[0]] = (m * a) / 32; c[o[1]] = (m * b) / 32;
    check(c, [0], [1, 0.5, 0]);
  }
}
// 20,000 random colours per grain, partners the max times u^2 (toward the red-dominant side).
let seed = 12345;
const rnd = () => {
  seed = (seed + 0x6d2b79f5) >>> 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const random = (lo, hi) => {
  const m = lo * Math.pow(hi / lo, rnd()), mc = Math.floor(rnd() * 3), c = [0, 0, 0];
  const o = [0, 1, 2].filter(x => x !== mc);
  c[mc] = m; c[o[0]] = m * rnd() ** 2; c[o[1]] = m * rnd() ** 2;
  return c;
};
for (let i = 0; i < 20000; i++) check(random(1e-4, 16), [0], [1, 0.5, 0]);
for (const g of [0.1, 0.25]) for (let i = 0; i < 20000; i++) check(random(5e-4, 0.08), [g], [1, 0.5]);
if (bytesFail.length) fail(`byte checker: redSat triples\n  ${bytesFail.join('\n  ')}`);

// Positive control: the round 1 parameters fail at grain 0.1 near m = 0.025 with (27, 9, 0).
const round1 = offRed(x => x, { M0: 0.005, MF: 0.008, M2: 0.025 });
const repro = satTriple(present(suppress(round1([0.0252, 0.0067, 0.0015]))), 0.1, 1, SLICES);
if (String(repro) !== '27,9,0') fail(`byte checker misses the round 1 repro: got ${repro}, want 27,9,0`);
if (satTriple(present(suppress(osOffRed([0.0252, 0.0067, 0.0015]))), 0.1, 1, SLICES))
  fail('the round 1 repro is still redSat with the chosen parameters');

// Single colours (spec scenarios). f32: float32 rounding of each component.
const f32 = c => c.map(Math.fround);
const same = (a, b) => a.length === b.length && a.every((x, i) => Object.is(x, b[i]));
const close = (a, b) => a.every((x, i) => Math.abs(x - b[i]) < 1e-9);
const cases = [
  ['pure red', [1, 0, 0], [1, 0.275, 0.275]],
  ['NaN green', [0.1, NaN, 0], [0.1, 0.0275, 0.0275]],
  ['all NaN', [NaN, NaN, NaN], [0, 0, 0]],
  ['infinite red', [Infinity, 0, 0], [16, 4.4, 4.4]],
  ['negative infinity', [-Infinity, 0.2, 0.1], [0, 0.2, 0.1]],
  ['red 0.01', [0.01, 0, 0], [0.00275, 0.00275, 0.00275]],
  ['dim green', [0, 0.007, 0], [0, 0.007, 0]],
];
for (const [name, c, want] of cases) {
  const got = osOffRed(c);
  if (!close(got, want)) fail(`${name}: osOffRed(${c}) = ${got}, want ${want}`);
}
const grey = osOffRed([0.001, 0, 0]);
if (!(grey[0] === grey[1] && grey[1] === grey[2])) fail(`red 0.001: osOffRed = ${grey}, want an exact grey`);
for (const c of [[0.05, 0.014, 0.014], [0.75, 0.4125, 2 ** -26]].map(f32)) {
  const got = osOffRed32(c);
  if (!same(got, c)) fail(`float32 (${c}): osOffRed = (${got}), want it unchanged bit for bit`);
}

if (failures.length) { console.error(failures.join('\n')); process.exit(1); }
console.log(`test-originals-red: ${manifest.visuals.length} originals finish through osOffRed; worst presented red share ${worst.toFixed(4)}; byte checker: 0 redSat over ${checked} sampled inputs, round 1 repro found`);
