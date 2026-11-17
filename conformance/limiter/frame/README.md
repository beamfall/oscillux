<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame flash limiter vectors

`vectors.json` is the spec for the frame flash limiter: the reference model
`tools/shader/limiter-model.mjs` (model `subblock-10deg`) and the GPU passes in
`shaders/limiter/` must reproduce every record. `make limiter-check` regenerates the vectors from
the model and compares, runs the model tests, compiles the passes and runs them on WebGL2 (and on
Metal where available) against the vectors.

## Model in brief

- The frame is box-reduced to 64 x 36 sub-blocks (16 x 9 cells of 4 x 4). Every pixel counts in
  exactly one sub-block, so a pattern down to sub-block size (a half-cell checkerboard that
  inverts, a thin bar) is measured by area at any resolution, not sampled at points. Detail finer
  than a sub-block averages inside it: an inversion that keeps every sub-block's mean constant
  registers nothing.
- Each sub-block tracks a luma code with the WCAG audit counter's step, and a red code with an
  eighth of it (512 codes, 2.5 on the 320 * (R - G - B) scale): a sub-block's mean dilutes red
  that covers only part of it (CORE-1616). The red code is the mean, over the sub-block's pixels, of the linear-light red excess R - G - B of
  saturated-red pixels (R / (R + G + B) >= 0.8 in linear light). WCAG 2.2's extra u'v' rule for
  red is not modelled. A cell
  holds 4 x 4 sub-blocks, so a phase reversal inside a cell (part rising while part falls) counts
  per sub-block instead of averaging out to no change at the cell.
- A direction is over when some window of `cols` x `rows` cells (the 10° field for the viewing
  geometry) holds more than `limit` transitioning sub-blocks, where `limit` is 25% of the field's
  area. This replaces the old 20%-of-the-whole-frame gate. Windows are aligned to cells and their
  size is rounded to whole cells, so a true 10° field that straddles windows can hold more than
  `limit` transitioning sub-blocks while every window stays at or under it.
- Luma over the limit is rationed by a token budget (at most `maxFlashHz` flashes, default 3, per
  second). Red over the limit is never admitted (the red-0 rule; WCAG 2.3.1 and ITU-R BT.1702).
- A sub-block whose transition is not admitted holds the previous output.
- A hold is feathered one sub-block outward: a pixel of a sub-block that is not held, beside a
  held one, blends toward the previous output, from 15/16 at the shared edge to nothing at the far
  edge of its own sub-block. A pixel whose input, previous output or blend is red-dominant
  (`r > g + b` in 8-bit) is not blended.

The model's header comment gives the exact arithmetic.

## Viewing geometry

A 10° visual field at viewing distance d spans 2 d tan 5° = 0.175 d. Its fraction of the screen
gives the window. Sources and dimensions are in `tools/shader/limiter-geometry.mjs`.

| Class | Reference | Screen | Distance | 10° span | Field / frame (w x h) | Window (cells) | Limit (sub-blocks) |
|---|---|---|---|---|---|---|---|
| `wcag` (default) | WCAG 2.2 SC 2.3.1: 341 x 256 px of 1024 x 768 | - | - | - | 0.333 x 0.333 | 5 x 3 | 64 |
| `desktop` | ISO 9241-303 / ANSI-HFES 100, 50-70 cm | 24 in 16:9 | 600 mm | 105.0 mm | 0.198 x 0.351 | 3 x 3 | 39.98 |
| `phone` | handheld reading distance | 6.1 in 19.5:9, landscape | 300 mm | 52.5 mm | 0.373 x 0.809 | 6 x 7 | 173.76 |
| `tv` | 10-foot UI convention | 55 in 16:9 | 3048 mm | 533.3 mm | 0.438 x 0.779 | 7 x 7 | 196.47 |

How the columns are derived:

- Window: `round(field fraction x 16)` by `round(field fraction x 9)` cells, clamped to [1, grid].
- Limit: `fround(0.25 x fw x 16 x fh x 9 x 16)`, which is 25% of the true field area in
  sub-blocks.
- A window is over when its count is strictly greater than the limit.

A host that does not know its device class uses `wcag`.

## Format

```
{ model, dt, cases: [{ name, frames, width, height, geometry, window: {cols, rows, limit},
                       signal, frameRecords: [[hold, grant, deficit, digest], ...] }] }
```

- `signal`: the synthetic frame source, rendered by `tools/shader/limiter-signals.mjs`
  (`renderSignal`). `dt` is 1/60 s and the model's default `maxFlashHz` is 3.
- `hold`: run lengths of the held mask over the 64 x 36 sub-blocks in row order, starting with a
  run of not-held sub-blocks. It is `"="` when unchanged from the previous frame.
- `grant`: the grant pass's word, admitted bits | over bits << 4. The direction bits are luma
  up 1, luma down 2, red up 4, red down 8.
- `deficit`: the luma token deficit after the frame (65025 is one full token).
- `digest`: FNV-1a 32 of the output RGBA8 bytes.

## Cases

| Case | What it pins |
|---|---|
| `steady-gradient` | no change: nothing held |
| `luma-3hz`, `luma-10hz` | full-frame flashes, rationed to 3 per second |
| `luma-10hz-small` | a strobe below the area limit passes |
| `luma-settle` | after the strobe stops, the frame settles to the input |
| `red-3hz`, `red-10hz`, `red-dark-10hz-half` | red transitions over the area are always held |
| `red-linear-saturation-10hz` | `[120,50,0]` <-> `[0,50,120]` is saturated red in linear light (not in encoded bytes) and is held |
| `red-stripes-10hz` | red over a third of every sub-block (one `[110,0,0]` column in three) is held: the block mean dilutes it, so the red step is an eighth of the pixel step (CORE-1616) |
| `tv-half-field-10hz`, `desktop-field-10hz`, `phone-field-10hz` | the 10° window per device class |
| `checker-half-cell-10hz` | a half-cell checkerboard inversion is limited |
| `odd-size-checker-10hz` | sub-block partition at a frame size not divisible by 64 x 36 |

## Commands

```sh
node tools/shader/limiter-vectors.mjs --check   # vectors == model
node tools/shader/limiter-vectors.mjs --write   # after a deliberate model change
node tools/shader/test-limiter.mjs              # model acceptance tests and pixel auditor
make limiter-check                              # all of the above, plus the GPU passes
```
