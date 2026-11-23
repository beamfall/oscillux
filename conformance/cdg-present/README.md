<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# CD+G presentation conformance

These vectors specify `oscillux_core::cdg::present` (`Presenter`, `background_index`) and the
`oscillux-cdg-render` command built on it. `tools/cdg-present-vectors.py` is an independent model
of this text. It decodes with the model in `tools/cdg-vectors.py` and writes `*.expect` here. The
Rust tests replay every line, natively and on wasm32. Inputs are the synthetic streams in
`conformance/cdg/`. No commercial karaoke data may be added.

Every value below is an integer, and every division rounds toward negative infinity (Python
`//`) unless it says otherwise. `x / 255 rounded` is
`div255(x) = (x + 128 + ((x + 128) >> 8)) >> 8`.

## Inputs per frame

`present(decoder, millis)` reads the decoder's 300 x 216 screen, its 16 colours (12-bit `0xRGB`),
its Memory Preset colour and its window origin `(6 + h_offset, 12 + v_offset)`. The window is the
288 x 192 indices from that origin. `millis` is media time; it drives the stage easing and the
backdrop's drift.

## Background index

Count each colour index over the edge ring: window pixels with `x < 6` or `x >= 282` or `y < 12`
or `y >= 180` (8928 pixels). If `count[preset] * 2 >= 8928` the background is the preset colour.
Otherwise it is the index with the highest count, the lowest index on a tie.

## Backdrop indices

An index belongs to the backdrop when it is the background index or when `count[i] * 4 >= 8928`
over the same edge ring. Backdrop indices are never drawn as graphics and never cast a shadow.

## Rank

The background ranks 0. Any other index `i` ranks `16 * d + i + 1`, where `d` is the sum over R, G
and B of the squared difference of the 4-bit levels of `colour[i]` and `colour[background]`.

## Scale2x

The window (288 x 192) doubles to 576 x 384. For pixel `P` at `(x, y)`, with neighbours clamped at
the window edge: `A` above, `B` right, `C` left, `D` below and the diagonals `UL`, `UR`, `DL`, `DR`.
`take(Q, G)` is true when `G != P` or `rank(Q) > rank(P)`. The 2 x 2 output is:

| Output | Value |
|---|---|
| top-left | `A` if `C == A` and `C != D` and `A != B` and `take(A, UL)`, else `P` |
| top-right | `B` if `A == B` and `A != C` and `B != D` and `take(B, UR)`, else `P` |
| bottom-left | `C` if `D == C` and `D != B` and `C != A` and `take(C, DL)`, else `P` |
| bottom-right | `D` if `B == D` and `B != A` and `D != C` and `take(D, DR)`, else `P` |

## Layers

Every index present in the doubled window that is not a backdrop index is a layer, ordered by
rank, lowest first. Layer `L` with index `i` has a 576 x 384 mask: 255 where the doubled pixel is
not a backdrop index and its rank is at least `rank(i)`, else 0. Each mask is blurred once with
the kernel `[1, 4, 1]` on each axis. First, each row: `h[x] = m[x-1] + 4 * m[x] + m[x+1]`, with
coordinates clamped to the row. Then each column: `m'[y] = (h[y-1] + 4 * h[y] + h[y+1] + 18) // 36`,
with coordinates clamped to the column.

## Colours

Each index `i` has an 8-bit colour `rgb(i) = (level * 17, ...)` of `colour[i]`, and
- `lum(c) = (54 * r^2 + 183 * g^2 + 19 * b^2) >> 8` for an 8-bit colour `c = (r, g, b)`.
- `contrast(a, b) = (max(a, b) + 3251) * 1024 // (min(a, b) + 3251)` for two `lum` values.
- `TARGET = 3584` (a contrast ratio of 3.5).

With `stage` the 8.8 background colour `(level * 17) << 8` of `colour[background]` (not the
eased stage) and `base`, `light`, `warm` and `lighten` as in Backdrop:
- For each of the 8 corners `(wl, ww, v)` with `wl` in `{0, 36000}`, `ww` in `{0, 30000}` and
  `v` in `{65536, 35536}`: `p = base`, then for `(colour, w)` in `(light, wl)` and `(warm, ww)`,
  each channel `p += ((colour - p) * w) >> 16`; then each channel
  `min(max((p * v) >> 16, 0), 65280) >> 8`.
- `dark = lum(lo)` and `bright = lum(hi)`, with `lo` and `hi` the per-channel minimum and maximum
  of those 8 colours.
- `worst(l) = 1024` when `dark <= l <= bright`, else
  `min(contrast(l, dark), contrast(l, bright))`; `i` is *stage-legible* when
  `worst(lum(rgb(i))) >= TARGET`.

Over the 288 x 192 window, each pair of different indices that are right or down neighbours is
one boundary. A boundary between a backdrop index and a graphics index `a` (not a backdrop index)
adds 1 to `back[a]`. A boundary between graphics indices `a` and `b` with
`contrast(lum(rgb(a)), lum(rgb(b))) >= TARGET` adds 1 to `held[a][b]` and to `held[b][a]`.

The presenter keeps a set of *protected* indices. It is emptied when the background index or any
of the 16 colours differs from the previous `present` call's, and is empty for a new presenter.
Each call then adds every `i` with some stage-legible `j` where `held[i][j] > 0` and
`held[i][j] * 3 >= back[i]`.

The drawn colour of `i` is `rgb(i)`, except when `back[i] > 0`, `i` is not stage-legible and not
protected. Then it is `fix(rgb(i))`: for `k = 1..16` in order, try the white mix
`v + (255 - v) * k // 16` then the black mix `v * (16 - k) // 16` per channel, and take the first
with `worst(lum(c)) >= TARGET`. If none reaches it, take the candidate with the highest `worst`, starting
from `rgb(i)` and replacing it only on a strictly higher value.

## Shadow mask

Ink is any index that is not a backdrop index and has `(rank - 1) >> 4 >= 12` (`d >= 12`). Take a
296 x 200 mask of zeros. Set the window pixel `(x, y)` to 255 at `(x + 4, y + 4)` when that pixel
is ink. Then blur twice. Each pass:
- Rows: `h[x] = m[x-1] + m[x] + m[x+1]` for `1 <= x <= 294`, and 0 at `x = 0` and `x = 295`.
- Columns: `m[y] = (h[y-1] + h[y] + h[y+1] + 4) // 9` for `1 <= y <= 198`, and 0 at `y = 0` and
  `y = 199`.

## Geometry and taps

The frame is `W` x `H`, each 1..8192. If `2W >= 3H`:
- `rw = ceil(3H / 2)`, `rh = H`.
- `rx = (W - rw) // 2`, `ry = 0`.

Otherwise:
- `rw = W`, `rh = max(2W // 3, 1)`.
- `rx = 0`, `ry = (H - rh) // 2`.

A tap for frame cell `t` on an axis with rectangle start `s`, span `n` (`rw` or `rh`), source size
`S`, last readable index `M`, shift `k` and feather `f`:
- `d = t - s`.
- `pos = clamp(((2d + 1) * S * 65536) // (2n) - 32768 + k, 0, M * 65536)`.
- `i0 = pos >> 16`, `i1 = min(i0 + 1, M)`, `frac = (pos & 0xFFFF) >> 8`.
- `edge`:
  - 0 when `d < 0` or `d >= n`.
  - Otherwise 256 when `f == 0`.
  - Otherwise `min((2e + 1) * 128 // f, 256)`, where `e = min(d, n - 1 - d)`.

There are two sets of taps:
- **Graphics:** `S` is 576 across and 384 down, `M = S - 1`, `k = 0`. The feather is
  `rw * 6 // 288` across and `rh * 12 // 192` down.
- **Shadow:** `S` is 288 across and 192 down, `M` is 295 across and 199 down (the padded
  mask), `k = 4 * 65536 - 65536`, feather 0. A shadow tap whose `edge` is 0 becomes
  `i0 = i1 = 0`, `frac = 0`, so cells outside the rectangle read the mask's zero corner.

Bilinear: `top = v[y0][x0] * (256 - fx) + v[y0][x1] * fx`, likewise `bottom` on row `y1`. The
result is `top * (256 - fy) + bottom * fy`.

## Stage

The target is the background colour in 8.8: each 4-bit level `c` becomes `(c * 17) << 8`.

Easing keeps `from`, `to`, `start`, `last` and the current `stage`. On each frame:
- **First frame, or `millis < last`:** set `from = to = target` and `start = millis`.
- **Otherwise, if `target != to`:** set `from = stage`, `to = target` and `start = millis`.

Then `t = clamp(millis - start, 0, 300)`, and for each channel
`stage = from + (to - from) * t / 300`, where `/` truncates toward zero. Finally `last = millis`.

## Backdrop

The backdrop is drawn per frame from the `stage` (8.8, three channels) and `millis`. Below, `/`
on these non-negative values is integer division, and `>>` is an arithmetic shift.

- `lighten(v, k) = v + (65280 - v) * k / 1024`.
- `base[c] = stage[c] * 230 / 1024 + 1536`.
- `light[c] = lighten(stage[c], 180)`.
- `warm[c] = lighten((stage[c] + stage[(c + 2) % 3]) / 2, 80)`.
- `drift(t, P)`: `u = t mod P` (the non-negative remainder),
  `tri = abs(2 * u * 65536 / P - 65536)` (here `/` truncates toward zero), and the result is
  `(((tri * tri) >> 16) * (196608 - 2 * tri)) >> 16`, a smoothstep from 0 to 65536.

There are two glows, each `(colour, x range, y range, radius, strength, Px, Py)`:
1. `(light, [18, 34], [20, 40], 75, 36000, 23000, 31000)`.
2. `(warm, [66, 84], [60, 82], 65, 30000, 27000, 37000)`.

For a glow, with `L = max(W, H)`:
- `cx = W * (x0 + (x1 - x0) * drift(millis, Px) / 65536) / 100`.
- `cy = H * (y0 + (y1 - y0) * drift((millis mod Py) + Px / 3, Py) / 65536) / 100`.
- `r = max(L * radius / 100, 1)` and `inv = 2^32 / (r * r)`.

The backdrop at `(x, y)`, with `hw = W / 2`, `hh = H / 2` and `corner = max(hw^2 + hh^2, 1)`:
1. `c = base`.
2. For each glow in order: `d2 = (x - cx)^2 + (y - cy)^2`, `q = 65536 - min((d2 * inv) >> 16,
   65536)`, `a = (((q * q) >> 16) * strength) >> 16`. For each channel
   `c += ((colour - c) * a) >> 16`.
3. `v = 65536 - 30000 * ((x - hw)^2 + (y - hh)^2) / corner`. Each channel becomes
   `clamp((c * v) >> 16, 0, 65280)`.

The frame's row `y` evaluates that only at the sample columns `0, 8, 16, ...` and `W - 1`.
Between neighbouring samples `x0 < x1` with values `a` and `b`, column `x0 + t` (`0 < t < x1 - x0`)
is `(a * (x1 - x0 - t) + b * t + (x1 - x0) // 2) // (x1 - x0)` per channel.

## Pixel

For frame pixel `(x, y)`:

1. **Shadow.** `m = bilinear(shadow mask, shadow taps) >> 16`, and `keep = 255 - div255(m * 110)`.
2. **Graphics.** Start from `g = (0, 0, 0, 0)`, premultiplied RGBA. If `edge = ex * ey` is non-zero,
   for each layer in order:
   - `v = bilinear(layer mask, graphics taps) >> 8`.
   - If all four mask taps are 0, stop. Later layers are empty there too.
   - If this is not the last layer and its mask taps equal the next layer's at every tap with
     non-zero bilinear weight, skip it. None of its own index lies under the blur there, so it
     would only fringe the next layer. A tap's weight is zero when its axis fraction puts all the
     weight on the other tap: the second column's taps when `fx = 0`, the second row's when
     `fy = 0`.
   - `cov = clamp((((v - 171 * 256) * ramp) >> 16) + 128, 0, 255)`, with
     `ramp = max(rw * 256 // 150, 388)` and an arithmetic shift. 388 is the least ramp that takes a
     full mask (`v = 255 * 256`) to `cov = 255`.
   - If `cov > 0`, then for each channel `g = div255(p * cov + g * (255 - cov))`. Here `p` is the
     layer's drawn colour (Colours) with alpha 255. All four channels, alpha included, use this.

   Then each channel becomes `g = (g * edge + 32768) >> 16`.
3. **Output.** For R, G and B:
   - `s = min((backdrop + BAYER[y % 4][x % 4] * 16 + 8) >> 8, 255)`.
   - `out = min(g + div255(div255(s * keep) * (255 - g_alpha)), 255)`.

   Alpha is 255. `BAYER` is the rows `0 8 2 10`, `12 4 14 6`, `3 11 1 9` and `15 7 13 5`.

## Vector format

`NAME.expect` covers the stream `conformance/cdg/NAME.cdg`. It starts with `bg` lines, then one
or more `size` blocks. Lines starting with `#` are comments and are ignored.

```
bg PACKS INDEX BACKDROP
size W H
frame PACKS MILLIS SHA256
```

- **`bg`:** one sequential decoder for all `bg` lines, in ascending `PACKS`. After advancing it to
  `PACKS` applied packs, `INDEX` is the background index (decimal) and `BACKDROP` the backdrop
  indices as a 4-digit lowercase hex bit mask (bit `i` set for index `i`).
- **`size`:** a fresh presenter of `W` x `H` and a fresh decoder. For each `frame` line, in order,
  the test:
  1. Advances the decoder to `PACKS` applied packs, seeking back first if it is already past them.
  2. Calls `present(decoder, MILLIS)`.
  3. Compares the lowercase hex SHA-256 of the RGBA8 frame, rows top to bottom.
