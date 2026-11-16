// SPDX-License-Identifier: AGPL-3.0-only
// CD+G lyrics over the visual (OSC-CDG): a decoder from the Oscillux wasm module, advanced to
// the audio's media time each stepped frame, and its 288 x 192 window uploaded to the present
// pass's layer texture (shaders/cdg/cdg-layer.glsl) only when it changed. The transparency key
// is host data: `auto` by default, which keys the colours of the window's edge (autoMask).

// The decoder's key modes, plus `auto`, which this host turns into a mask on every upload.
export const CDG_KEYS = Object.freeze({ none: 0, table: 1, preset: 2, index: 3, mask: 4, auto: -1 });
// The auto rule (hosts/README.md): the edge's commonest index, plus each next commonest that
// covers at least 1/AUTO_SHARE of the edge, AUTO_MAX indices at most.
export const AUTO_SHARE = 8, AUTO_MAX = 3;
const WINDOW_W = 288, WINDOW_H = 192;
// CD+G is 300 packs a second.
const PACKS_PER_SECOND = 300;

/** A key option ('auto', 'none', 'table', 'preset', 'index:N' with N 0..15 or 'mask:HHHH', a
 * 16-bit hex mask) as [mode, index]; anything else is auto. */
export function parseCdgKey(text) {
  const m = /^index:(\d{1,2})$/.exec(text ?? '');
  if (m && +m[1] < 16) return [CDG_KEYS.index, +m[1]];
  const k = /^mask:([0-9a-f]{1,4})$/i.exec(text ?? '');
  if (k) return [CDG_KEYS.mask, parseInt(k[1], 16)];
  return [CDG_KEYS[text] ?? CDG_KEYS.auto, 0];
}

/** The auto key's mask for 16 per-index pixel counts of the window's edge ring. */
export function autoMask(counts) {
  const total = counts.reduce((a, b) => a + b, 0);
  const order = [...counts.keys()].sort((a, b) => counts[b] - counts[a] || a - b);
  let mask = 1 << order[0];
  for (const i of order.slice(1, AUTO_MAX)) if (counts[i] > 0 && counts[i] * AUTO_SHARE >= total) mask |= 1 << i;
  return mask;
}

/** Packs decoded at media time `ms`, as the decoder counts them: pack floor(ms * 0.3) is the
 * last one applied. */
export function packsAt(ms, packCount) {
  return Math.min(packCount, Math.max(0, Math.floor(ms / 1000 * PACKS_PER_SECOND) + 1));
}

export class CdgLayer {
  constructor(gl, m) {
    this.gl = gl;
    this.m = m;
    this.cdg = null;
    this.name = null;
    this.key = [CDG_KEYS.auto, 0];
    // the decoder key of the last upload: `key`, or the mask `auto` chose
    this.uploaded = null;
    this.lastApplied = -1;
    this.restore();
  }

  /** Makes the layer texture, again after a context loss; the next update uploads the window. */
  restore() {
    const gl = this.gl;
    this.dirty = true;
    const t = this.texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, WINDOW_W, WINDOW_H, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    // the layer reads whole texels (texelFetch); the filters only keep the texture complete
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  }

  get loaded() { return this.cdg !== null; }

  /** Replaces the stream with `bytes` (a .cdg file); throws on a refused stream. */
  load(bytes, name) {
    const cdg = new this.m.Cdg(new Uint8Array(bytes));
    this.cdg?.free();
    this.cdg = cdg;
    this.name = name;
    this.dirty = true;
    this.lastApplied = -1;
  }

  setKey(key) {
    this.key = key;
    this.dirty = true;
  }

  /** Drops the stream: the present pass goes back to the visual alone. */
  clear() {
    this.cdg?.free();
    this.cdg = null;
    this.name = null;
  }

  /** Advances to media time `ms` (null holds the current position) and uploads the window if
   * it changed; returns the packs applied, or null without a stream. An advance to the time
   * already shown applies nothing, so a held position uploads nothing. */
  update(ms) {
    const c = this.cdg;
    if (!c) return null;
    let advanced = false;
    if (ms !== null && Number.isFinite(ms)) {
      advanced = c.advanceToTime(Math.max(ms, 0) / 1000) >= 0;
      if (!advanced) console.warn('cdg: advance refused');
    }
    const applied = c.applied;
    // the change bits describe the last advance, so they count only after one
    if (this.dirty || (advanced && (c.changes !== 0 || applied < this.lastApplied))) {
      const key = this.resolveKey();
      if (c.windowRgba(key[0], key[1]) >= 0) {
        this.uploaded = key;
        const px = new Uint8Array(this.m.wasmMemory().buffer, c.rgbaPtr(), WINDOW_W * WINDOW_H * 4);
        const gl = this.gl;
        gl.bindTexture(gl.TEXTURE_2D, this.texture);
        gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, WINDOW_W, WINDOW_H, gl.RGBA, gl.UNSIGNED_BYTE, px);
        this.dirty = false;
      }
    }
    this.lastApplied = applied;
    return applied;
  }

  /** The decoder key for the window as it stands: `key`, or for `auto` the mask of its edge. */
  resolveKey() {
    if (this.key[0] !== CDG_KEYS.auto) return this.key;
    const c = this.cdg;
    if (c.indexCounts(1) < 0) return [CDG_KEYS.preset, 0];
    return [CDG_KEYS.mask, autoMask(Array.from({ length: 16 }, (_, i) => c.count(i)))];
  }
}
