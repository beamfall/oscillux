<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Frame flash limiter vectors

`vectors.json` is the spec for the frame flash limiter: the reference model
`tools/shader/limiter-model.mjs` (model `pixel-10deg`) and the GPU passes in
`shaders/limiter/` must reproduce every record. `make limiter-check` regenerates the vectors from
the model and compares, runs the model tests, compiles the passes and runs them on WebGL2 (and on
Metal where available) against the vectors.

## Model in brief

- Every pixel carries the pixel auditor's trackers (WCAG 2.2 SC 2.3.1 general flash): a luma
  tracker with a step of 0.1 relative luminance whose darker side is below 0.8, and a red tracker
  with a step of 20 on WCAG's 320 * max(0, R - G - B) scale for saturated red (R / (R + G + B) >=
  0.8 in linear light). A tracker fires when the pixel has moved a full step from its low or high
  mark, so a change spread over many frames counts once it adds up. WCAG 2.2's extra u'v' rule
  for red is not modelled.
- The area of a direction is the number of pixels whose tracker fires now or fired within the
  coverage interval (1/15 s, in 16.7 ms units). The frame is reduced to 64 x 36 sub-blocks (16 x 9
  cells of 4 x 4) only to sum those counts; the counts are exact, so a change over any share of a
  sub-block, a fine pattern that inverts, or a thin bar is measured at any resolution (CORE-2515,
  CORE-2543, Codex round 7).
- Every direction is over when some window of `cols` x `rows` cells holds more than `limit`
  pixels that fire in any channel and direction now or within the coverage interval (the combined
  area, Codex rounds 12 and 13). The window is the fewest whole cells that contain the 10° field for the viewing geometry
  wherever the field sits, and `limit` is a quarter of the field's pixels, so a field the auditor
  would count over its limit is always inside one window that is over.
- Luma over the limit is rationed by a token budget (at most `maxFlashHz` flashes, default 3, per
  second). When both luma directions are over in one frame, the grant admits the pair only once the
  token has also stood unspent for a refill period, and leaves two tokens of deficit (CORE-2515).
  Red over the limit also needs its own token, refilled at an eighth of the luma rate, and a
  pixel asking both is granted only when both are ready (Codex round 13): at most one
  large-area red transition in any 1 s window, so no red flash (ITU-R BT.1702), and a held red
  change catches up instead of freezing (CORE-2382).
- A pixel whose trackers would fire on the input in a direction the grant did not admit holds
  the previous output. Every other pixel shows the input exactly; nothing blends
  around a hold (CORE-2543). Every pixel's trackers then step on the output, so they hold the
  auditor's state of what was shown.

The shared shader header (`shaders/limiter/common.glsl`) and the model's header comment give the
exact arithmetic: luma step 3275 codes with the darker side below 26215, red step 15.

## Viewing geometry

A 10° visual field at viewing distance d spans 2 d tan 5° = 0.175 d. Its fraction of the screen
gives the window. Sources and dimensions are in `tools/shader/limiter-geometry.mjs`.

| Class | Reference | Screen | Distance | 10° span | Field / frame (w x h) | Window at 1920 x 1080 (cells) | Limit at 1920 x 1080 (pixels) |
|---|---|---|---|---|---|---|---|
| `wcag` (default) | WCAG 2.2 SC 2.3.1: 341 x 256 px of 1024 x 768 | - | - | - | 0.333 x 0.333 | 7 x 4 | 57600 |
| `desktop` | ISO 9241-303 / ANSI-HFES 100, 50-70 cm | 24 in 16:9 | 600 mm | 105.0 mm | 0.198 x 0.351 | 5 x 5 | 35910 |
| `phone` | handheld reading distance | 6.1 in 19.5:9, landscape | 300 mm | 52.5 mm | 0.373 x 0.809 | 7 x 9 | 156267 |
| `tv` | 10-foot UI convention | 55 in 16:9 | 3048 mm | 533.3 mm | 0.438 x 0.779 | 8 x 8 | 176820 |

How the columns are derived (`windowOf(geometry, width, height)`):

- Field: `fwPx = round(fw x width)` by `fhPx = round(fh x height)` pixels, clamped to the frame.
- Window: per axis, the fewest whole cells that contain a span of the field's pixels at every
  offset, clamped to the grid.
- Limit: `floor(fwPx x fhPx / 4)`, a quarter of the field's pixels.
- A window is over when its count is strictly greater than the limit.

A host that does not know its device class uses `wcag`.

## Format

```
{ model, dt, cases: [{ name, frames, width, height, geometry, window: {cols, rows, limit},
                       signal, frameRecords: [[hold, grant, deficit, digest, track], ...] }] }
```

- `width`, `height`: from 64 x 36 to 8192 x 8192; the model refuses other sizes
  (`shaders/limiter/README.md`, "Frame size").
- `signal`: the synthetic frame source, rendered by `tools/shader/limiter-signals.mjs`
  (`renderSignal`). `dt` is 1/60 s and the model's default `maxFlashHz` is 3.
- `window`: `windowOf(geometry, width, height)`.
- `hold`: run lengths of the held mask over the 64 x 36 sub-blocks in row order (a sub-block is
  set when one of its pixels is held), starting with a run of not-held sub-blocks. It is `"="` when unchanged from the previous frame.
- `grant`: the grant pass's word, admitted bits | over bits << 4. The direction bits are luma
  up 1, luma down 2, red up 4, red down 8.
- `deficit`: the luma token deficit after the frame (65025 is one full token; a paired grant leaves two).
- `digest`: FNV-1a 32 of the output RGBA8 bytes.
- `track`: FNV-1a 32 of the tracker state after the frame, RGBA16UI per pixel as little-endian
  bytes (`shaders/limiter/README.md`).

## Cases

| Case | What it pins |
|---|---|
| `steady-gradient` | no change: nothing held |
| `luma-3hz`, `luma-10hz` | full-frame flashes, rationed to 3 per second |
| `luma-10hz-small` | a strobe below the area limit passes |
| `luma-settle` | after the strobe stops, the frame settles to the input |
| `red-3hz`, `red-10hz`, `red-dark-10hz-half` | large-area red transitions are rationed to at most one in any 1 s window (`red-3hz` admits one, the rest are held) |
| `red-linear-saturation-10hz` | `[120,50,0]` <-> `[0,50,120]` is saturated red in linear light (not in encoded bytes) and is held |
| `red-stripes-10hz` | red over a third of every sub-block (one `[110,0,0]` column in three) is held (CORE-1616) |
| `tv-half-field-10hz`, `desktop-field-10hz`, `phone-field-10hz` | the 10° window per device class |
| `checker-half-cell-10hz` | a half-cell checkerboard inversion is limited |
| `tv-half-field-10hz-orange-drift` | a drifting background beside a held strobe shows the input (CORE-2413, CORE-2543) |
| `odd-size-checker-10hz` | sub-block partition at a frame size not divisible by 64 x 36 |
| `fine-checker-10hz` | a 4 px checkerboard inversion at 640 x 360 is limited |

## Commands

```sh
node tools/shader/limiter-vectors.mjs --check   # vectors == model
node tools/shader/limiter-vectors.mjs --write   # after a deliberate model change
node tools/shader/test-limiter.mjs              # model acceptance tests and pixel auditor
make limiter-check                              # all of the above, plus the GPU passes
```
