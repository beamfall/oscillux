// SPDX-License-Identifier: AGPL-3.0-only
// A standard-library model of the present pass's colour path (CORE-0108), for the hue and banding
// checks: the v1 per-channel ACES and the v2 hue-preserving tone map, the exact sRGB encode, the
// integer hash and the triangular dither that shaders/present/present.glsl uses. It has no
// regions, damping or layer: the checks drive the pass with none. tools/shader/present-v2-check.mjs
// renders the same inputs through the real shader on a GPU and compares them with this model.

export const LUMA = [0.2126, 0.7152, 0.0722];

/** The v2 limits test-present-v2.mjs and present-v2-check.mjs hold the pass to. */
export const LIMITS = Object.freeze({
  hueFloat: 0.01, // degrees, before the output grid
  hueCodes: 2, // degrees, on 8-bit codes spanning at least 32 codes
  bandStep: 0.1, // codes, the dithered 16-column mean against the ideal
  bandRun: 32, // px, the longest run of one code along a dithered row
  chainMs: 1.5, // ms, bloom chain and present at 1920x1080 on a Metal GPU
});
const lum = c => LUMA[0] * c[0] + LUMA[1] * c[1] + LUMA[2] * c[2];
const clamp01 = v => Math.min(Math.max(v, 0), 1);

/** The ACES fit both versions use (Narkowicz), clamped to [0, 1]. */
export const aces = v => clamp01((v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14));

/** v1: ACES on each channel. */
export const tonemapV1 = x => x.map(aces);

/**
 * v2: ACES on luminance, the colour scaled to the mapped luminance; where a channel would pass 1
 * the colour moves toward the grey of that luminance until it fits. Both steps keep the HSV hue
 * of the linear colour, and greys map as in v1.
 */
export function tonemapV2(x) {
  const l = lum(x);
  if (l <= 1e-6) return x.map(v => v * (0.03 / 0.14));
  const t = aces(l);
  let c = x.map(v => v * (t / l));
  const m = Math.max(...c);
  if (m > 1) c = c.map(v => t + (v - t) * ((1 - t) / (m - t)));
  return c.map(clamp01);
}

/** v rounded to the nearest IEEE half (normal range), as an RGBA16F upload stores it. */
export function roundHalf(v) {
  if (v === 0 || !Number.isFinite(v)) return v;
  const step = 2 ** (Math.max(Math.floor(Math.log2(Math.abs(v))), -14) - 10);
  return Math.round(v / step) * step;
}

/** The exact piecewise sRGB encode. */
export const srgbEncode = s => (s <= 0.0031308 ? s * 12.92 : 1.055 * s ** (1 / 2.4) - 0.055);
export const srgbDecode = e => (e <= 0.04045 ? e / 12.92 : ((e + 0.055) / 1.055) ** 2.4);

/** The pass's xorshift-multiply mixer (presentMix) on an unsigned 32-bit integer. */
export function presentMix(h) {
  h = (h ^ (h >>> 16)) >>> 0;
  h = Math.imul(h, 0xa7d471db) >>> 0;
  h = (h ^ (h >>> 14)) >>> 0;
  h = Math.imul(h, 0x76a997d3) >>> 0;
  return (h ^ (h >>> 16)) >>> 0;
}

/** The pass's presentHash on unsigned 32-bit integers: the inputs chained into one key, then
 * one remix per output word. */
export function presentHash(x, y, z) {
  const k = presentMix((presentMix((presentMix((x ^ 0xed81fd3a) >>> 0) ^ y) >>> 0) ^ z) >>> 0);
  return [presentMix((k ^ 0x6294a626) >>> 0), presentMix((k ^ 0xbe633942) >>> 0), presentMix((k ^ 0xa97a7369) >>> 0)];
}

/** The top 24 bits as a float in [0, 1). */
export const unit = h => (h >>> 8) / 16777216;

/** Triangular noise in (-1, 1) for pixel (x, y) on frame, rectangular noise in [-1/2, 1/2) from
 * the same hash, and the grain noise (triangular, from a second hash). */
export function presentNoise(x, y, frame) {
  const h = presentHash(x, y, frame);
  const g = presentHash(x, y, (frame ^ 0x9e3779b9) >>> 0);
  return { dither: unit(h[0]) + unit(h[1]) - 1, rect: unit(h[0]) - 0.5, grain: unit(g[0]) + unit(g[1]) - 1 };
}

/**
 * One output pixel from x, the linear colour that reaches the tone map (no grade, no regions).
 * Returns the encoded value per channel: a float when levels is 0, otherwise the code on the
 * levels grid (v1 and undithered v2 round to nearest, as a fixed-point target does).
 */
export function presentPixel(x, { version = 2, levels = 255, dither = 0, grain = 0, px = 0, py = 0, frame = 0 } = {}) {
  let c = version === 1 ? tonemapV1(x) : tonemapV2(x);
  const n = version === 1 ? { dither: 0, rect: 0, grain: 0 } : presentNoise(px, py, frame);
  if (grain > 0) c = c.map(v => clamp01(v * (1 + grain * n.grain)));
  const e = c.map(srgbEncode);
  if (!(levels > 0)) return e;
  // Triangular noise in the interior; within one code of either end, rectangular noise, which
  // never leaves the range, keeps pure black and white exact and stays unbiased; within 1/1024
  // code of an end, that end (as the pass does, against GPU encode error at 1.0).
  return e.map(v => {
    const q = v * levels;
    if (q < 1 / 1024 || q > levels - 1 / 1024) return q < 1 ? 0 : levels;
    const r = q < 1 || q > levels - 1 ? n.rect : n.dither;
    return Math.min(Math.max(Math.floor(q + 0.5 + dither * r), 0), levels);
  });
}

// ---------- Metrics ----------

/** HSV hue in degrees of a linear colour, or null when it has no chroma. */
export function hue([r, g, b]) {
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
  if (!(d > 0)) return null;
  let h;
  if (mx === r) h = ((g - b) / d) % 6;
  else if (mx === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  return (h * 60 + 360) % 360;
}

const hueDiff = (a, b) => { const d = Math.abs(a - b) % 360; return d > 180 ? 360 - d : d; };

/** A fully saturated colour of HSV hue h (degrees) at value 1 and saturation s. */
export function hsv(h, s = 1) {
  const f = k => { const t = (k + h / 60) % 6; return 1 - s * Math.max(0, Math.min(t, 4 - t, 1)); };
  return [f(5), f(3), f(1)];
}

/** The saturated-colour ramp: hues every 15 degrees at saturation 1 and 0.75, exposures 2^-4 to
 * 2^4 in half stops. */
export function hueRamp() {
  const out = [];
  for (const s of [1, 0.75]) {
    for (let h = 0; h < 360; h += 15) {
      for (let st = -8; st <= 8; st++) out.push({ hue: h, sat: s, x: hsv(h, s).map(v => v * 2 ** (st / 2)) });
    }
  }
  return out;
}

/**
 * Max hue error in degrees over the ramp, from outputs (encoded floats, or codes when levels > 0)
 * one per ramp entry. A float output counts when its linear chroma (max - min) is at least 0.02;
 * a code output when its codes span at least minCodes, so the error is the tone map's, not the
 * output grid's (one code on a 32-code span moves the hue under 2 degrees).
 */
export function hueError(ramp, outputs, { levels = 0, minCodes = 32 } = {}) {
  let max = 0, mean = 0, n = 0, worst = null;
  ramp.forEach((r, i) => {
    const o = outputs[i];
    if (levels > 0 && Math.max(...o) - Math.min(...o) < minCodes) return;
    const lin = o.map(v => srgbDecode(levels > 0 ? v / levels : v));
    if (!(levels > 0) && Math.max(...lin) - Math.min(...lin) < 0.02) return;
    const e = hueDiff(hue(lin), hue(r.x));
    mean += e; n++;
    if (e > max) { max = e; worst = { hue: r.hue, sat: r.sat, x: r.x, out: o }; }
  });
  return { max, mean: n ? mean / n : 0, counted: n, of: ramp.length, worst };
}

/** The dark gradient: linear scene light 0 to top across width columns, the same on every row. */
export const GRADIENT = Object.freeze({ width: 1920, rows: 64, top: 0.032 });
export const gradientValue = (col, width = GRADIENT.width, top = GRADIENT.top) => (top * (col + 0.5)) / width;

/**
 * Banding of a grey gradient's codes (rows of width codes): the longest run of one code along a
 * row, the distinct codes, and the visible step, the largest error in codes of the 16-column
 * mean (over all rows) against the ideal encoded value, away from the 16 columns at each end.
 */
export function banding(rows, ideal, levels = 255) {
  const width = rows[0].length;
  let maxRun = 0;
  const codes = new Set();
  for (const row of rows) {
    let run = 1;
    for (let i = 1; i < width; i++) {
      run = row[i] === row[i - 1] ? run + 1 : 1;
      if (run > maxRun) maxRun = run;
    }
    for (const v of row) codes.add(v);
  }
  const colMean = Array.from({ length: width }, (_, i) => rows.reduce((s, r) => s + r[i], 0) / rows.length);
  let localStep = 0;
  const W = 16;
  for (let i = W; i + W <= width - W; i++) {
    let m = 0, id = 0;
    for (let j = i; j < i + W; j++) { m += colMean[j]; id += ideal[j] * levels; }
    localStep = Math.max(localStep, Math.abs(m - id) / W);
  }
  return { maxRun, distinct: codes.size, localStep };
}

/** The gradient through the model: rows of codes and the ideal encoded value per column. */
export function gradientModel({ version, dither = 0, frame = 0, levels = 255 } = {}) {
  const { width, rows: n } = GRADIENT;
  const ideal = Array.from({ length: width }, (_, i) => srgbEncode(tonemapV2([gradientValue(i), gradientValue(i), gradientValue(i)])[0]));
  const rows = [];
  for (let y = 0; y < n; y++) {
    const row = new Array(width);
    for (let i = 0; i < width; i++) {
      const v = gradientValue(i);
      row[i] = presentPixel([v, v, v], { version, dither, levels, px: i, py: y, frame })[0];
    }
    rows.push(row);
  }
  return { rows, ideal };
}
