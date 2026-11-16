// SPDX-License-Identifier: AGPL-3.0-only
// Deterministic RGBA8 test signals for the frame flash limiter (conformance/limiter/frame/).
// renderSignal uses only integer arithmetic and Math.floor, so a browser page that is handed its
// source text (Function.prototype.toString) draws exactly the bytes Node draws. Rows are top first.
//
// Specs (colours are 8-bit display values [r, g, b]; rect and size are frame fractions):
//   { kind: 'solid', color }
//   { kind: 'gradient' }                      static horizontal/vertical ramp
//   { kind: 'square', hz, on, off, bg?, rect?, until?, after? }
//       rect (default the whole frame) shows `on` in the first half period and `off` in the second,
//       at 60 frames a second; from frame `until` on it shows `after` ('on' or 'off').
//   { kind: 'checker', hz, size: [w, h], on, off }
//       a checkerboard of w x h squares whose phase inverts every half period.
//   { kind: 'stripes', hz, every, width, on, off, bg }
//       one-pixel-column stripes: columns with x % every < width show `on` in the first half
//       period and `off` in the second; the rest show `bg`. Unlike `checker`, nothing in a
//       sub-block moves the other way, so its mean moves by the stripes' share of the change.

export function renderSignal(spec, t, W, H, out) {
  const fill = (x0, y0, x1, y1, c) => {
    for (let y = y0; y < y1; y++) {
      for (let x = x0, i = (y * W + x0) * 4; x < x1; x++, i += 4) {
        out[i] = c[0]; out[i + 1] = c[1]; out[i + 2] = c[2]; out[i + 3] = 255;
      }
    }
  };
  // Half periods elapsed at frame t, at 60 frames a second.
  const halves = hz => Math.floor((2 * hz * t) / 60);
  if (spec.kind === 'solid') {
    fill(0, 0, W, H, spec.color);
  } else if (spec.kind === 'gradient') {
    for (let y = 0; y < H; y++) {
      for (let x = 0, i = y * W * 4; x < W; x++, i += 4) {
        out[i] = Math.floor((x * 255) / (W - 1)); out[i + 1] = Math.floor((y * 255) / (H - 1));
        out[i + 2] = 128; out[i + 3] = 255;
      }
    }
  } else if (spec.kind === 'square') {
    const r = spec.rect || [0, 0, 1, 1];
    let on = halves(spec.hz) % 2 === 0;
    if (spec.until !== undefined && t >= spec.until) on = spec.after === 'on';
    if (spec.rect) fill(0, 0, W, H, spec.bg || [0, 0, 0]);
    fill(Math.floor(r[0] * W), Math.floor(r[1] * H), Math.floor(r[2] * W), Math.floor(r[3] * H), on ? spec.on : spec.off);
  } else if (spec.kind === 'checker') {
    const sw = Math.max(1, Math.floor(spec.size[0] * W)), sh = Math.max(1, Math.floor(spec.size[1] * H));
    const phase = halves(spec.hz) % 2;
    for (let y = 0; y < H; y++) {
      const row = Math.floor(y / sh);
      for (let x = 0, i = y * W * 4; x < W; x++, i += 4) {
        const c = (Math.floor(x / sw) + row + phase) % 2 === 0 ? spec.on : spec.off;
        out[i] = c[0]; out[i + 1] = c[1]; out[i + 2] = c[2]; out[i + 3] = 255;
      }
    }
  } else if (spec.kind === 'stripes') {
    const c = halves(spec.hz) % 2 === 0 ? spec.on : spec.off;
    for (let y = 0; y < H; y++) {
      for (let x = 0, i = y * W * 4; x < W; x++, i += 4) {
        const k = x % spec.every < spec.width ? c : spec.bg;
        out[i] = k[0]; out[i + 1] = k[1]; out[i + 2] = k[2]; out[i + 3] = 255;
      }
    }
  } else {
    throw new Error(`renderSignal: unknown kind ${spec.kind}`);
  }
  return out;
}
