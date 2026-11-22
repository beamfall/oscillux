#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
// Verifies the red chromaticity codes and thresholds of limiter-model.mjs over every 8-bit colour
// (openspec/changes/limiter-red-uv-chromaticity/design.md, sections 2 to 4): the codes' error
// against the IEC 61966-2-1 matrix and the matrix from the sRGB primaries and D65, the 32-bit
// intermediate bound, the saturated test against float64, the vertex codes, every threshold's
// derivation, the far and very-far tests against the hull of the saturated codes, and the box
// cell ranges. Runs in `make limiter-check`, about a minute.
//   node tools/shader/limiter-uv-check.mjs
import {
  LIN24_LUT, UV_D, UV_FN, UV_FU0, UV_FV0, UV_R, UV_SNU, UV_SNV, UV_SU0, UV_SV0, UV_T, UV_TF, UV_TH, UV_TVF,
  UV_VERTS, UV_X, UV_Y, uvCode, uvFar, uvSat, uvVeryFar,
} from './limiter-model.mjs';

const Q = 16384, E = 2.5e-4, EV = 1.5e-4;
const fail = [];
const check = (ok, what) => { if (!ok) fail.push(what); };
const lin = k => { const c = k / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
const LF = Float64Array.from({ length: 256 }, (_, k) => lin(k));
for (let k = 0; k < 256; k++) check(LIN24_LUT[k] === Math.round(lin(k) * 2 ** 24), `LIN24_LUT[${k}]`);
const IEC = [[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]];
function fromPrimaries() {
  const xy = [[0.64, 0.33], [0.30, 0.60], [0.15, 0.06]], w = [0.3127, 0.3290];
  const P = xy.map(([x, y]) => [x / y, 1, (1 - x - y) / y]);
  const W = [w[0] / w[1], 1, (1 - w[0] - w[1]) / w[1]];
  const A = [0, 1, 2].map(r => [0, 1, 2].map(c => P[c][r]));
  const det = m => m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
    m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
  const d = det(A), s = [0, 1, 2].map(i => det(A.map((row, r) => row.map((v, c) => (c === i ? W[r] : v)))) / d);
  return [0, 1, 2].map(r => [0, 1, 2].map(c => A[r][c] * s[c]));
}
const MATS = [IEC, fromPrimaries()];
const rnd = v => Math.round(v * Q);
check(UV_X.join() === IEC[0].map(rnd).join() && UV_Y.join() === IEC[1].map(rnd).join(), 'UV_X, UV_Y');
check(UV_D.join() === [0, 1, 2].map(i => rnd(IEC[0][i] + 15 * IEC[1][i] + 3 * IEC[2][i])).join(), 'UV_D');
function uvF(M, R, G, B) {
  const X = M[0][0] * R + M[0][1] * G + M[0][2] * B, Y = M[1][0] * R + M[1][1] * G + M[1][2] * B;
  const D = X + 15 * Y + 3 * (M[2][0] * R + M[2][1] * G + M[2][2] * B);
  return [4 * X / D, 9 * Y / D];
}
// The vertex codes and their error.
const VERTS = [[1, 0, 0], [0.8, 0.2, 0], [0.8, 0, 0.2]];
let ev = 0;
VERTS.forEach((p, i) => {
  check(UV_VERTS[i].join() === uvF(IEC, ...p).map(rnd).join(), `UV_VERTS[${i}]`);
  for (const M of MATS) { const f = uvF(M, ...p); ev = Math.max(ev, Math.hypot(UV_VERTS[i][0] / Q - f[0], UV_VERTS[i][1] / Q - f[1])); }
});
check(ev <= EV, `vertex error ${ev} > ${EV}`);
// Every colour: the intermediate bound, the code error and the saturated test.
let big = 0, e = 0, eAt = null, satMiss = 0, satOver = 0, umin = Q, umax = 0, vmin = Q, vmax = 0;
const L24 = LIN24_LUT;
for (let r = 0; r < 256; r++) for (let g = 0; g < 256; g++) for (let b = 0; b < 256; b++) {
  const s = L24[r] + L24[g] + L24[b];
  if (s === 0) continue;
  let k = 0;
  while ((s >> k) >= 262144) k++;
  const cr = L24[r] >> k, cg = L24[g] >> k, cb = L24[b] >> k, s2 = cr + cg + cb;
  const n = [cr, cg, cb].map(c => c * Q);
  const nr = Math.floor(n[0] / s2), ng = Math.floor(n[1] / s2), nb = Math.floor(n[2] / s2);
  const X = UV_X[0] * nr + UV_X[1] * ng + UV_X[2] * nb, Y = UV_Y[0] * nr + UV_Y[1] * ng + UV_Y[2] * nb;
  const D = UV_D[0] * nr + UV_D[1] * ng + UV_D[2] * nb;
  big = Math.max(big, ...n, X * 4, Y * 9, D);
  const c = uvCode(r, g, b), u = c >> 14, v = c & 16383;
  umin = Math.min(umin, u); umax = Math.max(umax, u); vmin = Math.min(vmin, v); vmax = Math.max(vmax, v);
  for (const M of MATS) {
    const f = uvF(M, LF[r], LF[g], LF[b]), d = Math.hypot(u / Q - f[0], v / Q - f[1]);
    if (d > e) { e = d; eAt = [r, g, b]; }
  }
  const ratio = LF[r] / (LF[r] + LF[g] + LF[b]), sat = uvSat(r, g, b);
  if (ratio >= 0.8 && !sat) satMiss++;
  if (sat && ratio < 0.8 - 1e-12) satOver++;
}
check(big < 2 ** 32, `intermediate ${big} >= 2^32`);
check(e <= E, `code error ${e} at ${eAt} > ${E}`);
check(satMiss === 0 && satOver === 0, `saturated test: ${satMiss} missed, ${satOver} below 0.8`);
check(umin >= UV_FU0 && vmin >= UV_FV0 && ((umax - UV_FU0) >> 6) < UV_FN && ((vmax - UV_FV0) >> 6) < UV_FN, 'FB cell range');
// The thresholds (design.md, section 3).
const T = Math.floor(((0.2 - 2 * E) * Q) ** 2), sT = Math.sqrt(T) / Q;
const TH = Math.ceil((0.2 + 2 * E) * Q) ** 2, sTH = Math.sqrt(TH) / Q;
const TF = Math.floor(((sT - E - EV - 1 / Q) * Q) ** 2);
const L = Math.max(...[[0, 1], [0, 2], [1, 2]].map(([i, j]) => Math.hypot(UV_VERTS[i][0] - UV_VERTS[j][0], UV_VERTS[i][1] - UV_VERTS[j][1]) / Q));
const TVF = Math.ceil(((Math.sqrt((sTH + E + 1 / Q) ** 2 + (L / 2) ** 2) + EV) * Q) ** 2);
check(T === UV_T && TH === UV_TH && TF === UV_TF && TVF === UV_TVF, `thresholds ${JSON.stringify({ T, TH, TF, TVF })}`);
// The clip half-width (section 13): a code more than UV_R from p on either axis is more than TH away.
check(UV_R * UV_R === UV_TH, `UV_R ${UV_R}`);
// The hull of the saturated codes and the SB cell range.
const seen = new Set(), pts = [];
for (let r = 0; r < 256; r++) for (let g = 0; g < 256; g++) for (let b = 0; b < 256; b++) {
  if (!uvSat(r, g, b)) continue;
  const c = uvCode(r, g, b);
  if (!seen.has(c)) { seen.add(c); pts.push([c >> 14, c & 16383]); }
}
for (const [u, v] of pts) {
  check(u >= UV_SU0 && v >= UV_SV0 && ((u - UV_SU0) >> 3) < UV_SNU && ((v - UV_SV0) >> 3) < UV_SNV, 'SB cell range');
  check(!uvFar((u << 14) | v), 'a saturated code is far');
}
pts.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
const cross = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
const lo = [], hi = [];
for (const p of pts) { while (lo.length >= 2 && cross(lo.at(-2), lo.at(-1), p) <= 0) lo.pop(); lo.push(p); }
for (const p of pts.slice().reverse()) { while (hi.length >= 2 && cross(hi.at(-2), hi.at(-1), p) <= 0) hi.pop(); hi.push(p); }
const hull = lo.slice(0, -1).concat(hi.slice(0, -1));
const d2 = (a, b) => (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2;
function segD2(p, a, b) {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)));
  return (p[0] - a[0] - t * dx) ** 2 + (p[1] - a[1] - t * dy) ** 2;
}
const inside = p => hull.every((h, i) => cross(h, hull[(i + 1) % hull.length], p) >= 0);
// Every distinct code: a code possibly more than a step from some saturated code is far; a very-far
// code is definitely more than 0.2 from every saturated code.
let farBad = 0, vfBad = 0, vfN = 0, farN = 0;
const done = new Uint8Array(Q * Q / 8);
for (let r = 0; r < 256; r++) for (let g = 0; g < 256; g++) for (let b = 0; b < 256; b++) {
  const c = uvCode(r, g, b);
  if (c < 0 || done[c >> 3] & (1 << (c & 7))) continue;
  done[c >> 3] |= 1 << (c & 7);
  const p = [c >> 14, c & 16383];
  const far = uvFar(c);
  if (far) farN++;
  if (!far && hull.some(h => d2(p, h) > T)) farBad++;
  if (uvVeryFar(c)) {
    vfN++;
    const mn = inside(p) ? 0 : Math.min(...hull.map((h, i) => segD2(p, h, hull[(i + 1) % hull.length])));
    if (!(mn > TH)) vfBad++;
  }
}
check(farBad === 0 && vfBad === 0, `far ${farBad}, very far ${vfBad}`);
const facts = { e: +e.toPrecision(5), eAt, ev: +ev.toPrecision(5), big, saturated: pts.length, hull: hull.length, far: farN, veryFar: vfN, u: [umin, umax], v: [vmin, vmax] };
if (fail.length) {
  console.error(`FAIL limiter u'v' check: ${fail.slice(0, 10).join('; ')}${fail.length > 10 ? ` (+${fail.length - 10})` : ''}`);
  console.error(JSON.stringify(facts));
  process.exit(1);
}
console.log(`ok   limiter u'v' codes and thresholds: ${JSON.stringify(facts)}`);
