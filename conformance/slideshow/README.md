<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Photo slideshow vectors

`vectors.json` is written by `tools/slideshow-vectors.py`, a standard-library binary64 model of
the calm photo slideshow written from this file, never from shader output.
`make slideshow-check` (part of `make gate`) runs the model with `--check`, then
`tools/shader/slideshow-check.mjs` draws `shaders/slideshow/slideshow.glsl` over the same inputs
and compares:

- WebGL2 (headless Chromium, SwiftShader), GLSL ES 3.00;
- on macOS, Metal: the GLSL 450 leg through glslangValidator and SPIRV-Cross, built by the
  device's runtime compiler and drawn into an rgba32Float target.

Both draws use the `fetch` sampling of `tools/shader/slideshow.mjs`: bilinear by hand from
`texelFetch` with clamped texel indices, and the soft tap equal to the plain tap. Hosts sample
through the hardware filter and mips (`linear`).

The same check also proves, on both GPUs, that every amplitude-0 case draws bit-identically with
loud beat inputs (beatPhase 0.25, beatsPerSlide 2) and silent ones, and on WebGL2 over a 320 x 180
sequence with hardware sampling; and it plays a worst-case loud-audio sequence through the flash
limiter model and the independent audit (below).

## Layout

- `size` 8: every image is 8 x 8, a flat list of 64 RGB pixels, row-major, **top row first**,
  linear. Pixel (i, j) is drawn at uv = ((i + 0.5) / 8, (j + 0.5) / 8), v = 0 at the top.
- `photos`: the four inputs, photo 0 and 1 the outgoing slide's primary and secondary, 2 and 3
  the incoming slide's. Values are multiples of 1/256 (exact in binary32), plus HDR spots
  (photo 0 at (5, 2), photo 2 at (2, 5)) and a black texel (photo 3 at (1, 1)).
- `cases`: 60 cases, 3 styles x p in {0, 0.25, 0.5, 0.75, 1} x 4 parameter sets. Each has
  `style`, `styleId` (dissolve 0, lightSweep 1, iris 2), the pass parameters, the two slides
  `a` and `b` (`layout` and `layoutId`: cover 0, fill 1, pair 2) and `expected`, printed at 6
  decimals. The parameter sets cover every layout on both sides:
  1. calm default: amplitude 0 with loud beat inputs, cover into cover, off-centre rects,
     zoom in then zoom out;
  2. tempo coupling at amplitude 1, one beat per slide: blurred fill into a portrait pair;
  3. still: motion 0, square frame, pair into fill, unknown (zero-area) rects;
  4. amplitude 0.5, 6.5 beats per slide: zoom out of a large rect, landscape into portrait cover.
- `tolerance` 1e-3: the largest allowed absolute difference per channel. It covers binary32
  against binary64, `sin`/`exp` precision on GPUs and the 6-decimal print; the check reports
  the measured worst difference.
- `addedLight`: the bounds asserted below and the worst values the model reached.

## Model

Shared definitions: Y = (0.2126, 0.7152, 0.0722); `mix(a, b, t) = a + (b - a) t`;
`smooth(e0, e1, x)` = s^2 (3 - 2s) with s = clamp((x - e0) / (e1 - e0), 0, 1); PI = 3.14159265.
`tap(i, uv)` is bilinear on photo i with texel centres at (n + 0.5) / 8 and indices clamped to
the edge. All vector operations are per axis.

**Path.** e = clamp(k, 0, 1); when amplitude > 0, with
c = 0.9 clamp(amplitude, 0, 1) / (2 PI max(beatsPerSlide, 1) + PI),
e += c sin(2 PI beatPhase) sin(PI e). Amplitude 0 reads neither beat input.

**Salient rect.** a = min corner, b = max corner of `rect`; zero or negative area means unknown,
then a = (0.3, 0.3), b = (0.7, 0.7). sc = clamp((a + b) / 2, 0, 1); sh = 0.6 (b - a);
s0 = clamp(sc - sh, 0, 1), s1 = clamp(sc + sh, 0, 1).

**Centre(target, hs).** lo = s1 - hs, hi = s0 + hs; c = clamp(target, min(lo, hi), max(lo, hi))
when hi >= lo, else (s0 + s1) / 2; the result is 0.5 when hs >= 0.5, else
clamp(c, min(hs, 0.5), max(1 - hs, 0.5)).

**Window(photoAspect, regionAspect, rect, contain, e, direction, motion).**
r = max(regionAspect, 1e-4) / max(photoAspect, 1e-4); full = (min(1, r), min(1, 1/r)) for cover,
(max(1, r), max(1, 1/r)) for contain; h0 = full / 2; half = max((s1 - s0) / 2, 1e-4);
m = clamp(motion, 0, 1); z = clamp(min(h0.x / half.x, h0.y / half.y), 1, 1 + 0.18 m);
h1 = h0 / z; c0 = Centre(0.5, h0); c1 = Centre(mix(c0, (s0 + s1) / 2, m), h1);
f = e when direction < 0.5, else 1 - e; the window is centre mix(c0, c1, f), half size
mix(h0, h1, f).

**Cover(i, q, regionAspect).** The cover window at e; tap(i, centre + (q - 0.5) 2 half).

**Fill(i, q).** The contain window at e gives puv = centre + (q - 0.5) 2 half and the pixel size
px = 2 half / size; coverage = product over axes of clamp(min(puv, 1 - puv) / px + 0.5, 0, 1).
The backdrop is the cover window at e = 0, direction 0, motion 0, sampled with a 3 x 3 tent
(weights (2 - |x|)(2 - |y|) / 16) at steps 0.05 (1 / photoAspect, 1); then
back = mix(dot(back, Y), back, 0.7) 0.42. The result is mix(back, tap(i, puv), coverage).

**Layer(slide, first).** e = Path(slide.k). Cover: Cover(first, uv, aspect). Fill:
Fill(first, uv) with region aspect `aspect`. Pair: hw = 0.5 - 0.006, region aspect aspect hw;
u < hw draws Cover(first, (u / hw, v)) with aspect0 and rect0; u > 1 - hw draws
Cover(first + 1, ((u - (1 - hw)) / hw, v)) with aspect1 and rect1; between them 0.003 grey.

**Transition.** p = clamp(p, 0, 1); p <= 0 shows Layer(a, 0) and p >= 1 Layer(b, 2) exactly.
Otherwise A = Layer(a, 0), B = Layer(b, 2) and:

- **Dissolve:** mix(A, B, p).
- **Light sweep:** x = (u aspect + 0.4 v) / (aspect + 0.4); w = 0.14; s = mix(-w, 1 + w, p);
  ref = mix(A, B, 1 - smooth(s - w, s + w, x)); e = (x - s) / (0.7 w);
  tint = (1, 0.95, 0.86) / dot((1, 0.95, 0.86), Y);
  c = ref + tint 0.035 exp(-e^2) 4 p (1 - p); d = c - ref; added = dot(max(d, 0), Y); if
  added > 0.04 the result is ref + d (0.04 / added), else c.
- **Iris:** f = (0.5, 0.5), or for a cover incoming slide the salient centre's position in the
  frame: clamp(0.5 + (sc - centre) / (2 half), 0, 1) with B's cover window at Path(b.k) (sc = 0.5
  for an unknown rect). ar = (aspect, 1); rMax = |max(f, 1 - f) ar|; w = 0.08;
  r = mix(-w, rMax + w, p); d = |(uv - f) ar|; the result is mix(A, B, 1 - smooth(r - w, r + w, d)).

## Assertions

Before writing, the model asserts on every pixel of every case:

- the light sweep adds at most 0.04 linear luminance over its plain wipe and, after the ACES
  fitted tone map x (2.51x + 0.03) / (x (2.43x + 0.59) + 0.14) at unit exposure, at most 0.08
  luminance, and so does the case mean;
- the dissolve and the iris stay within the per-channel span of A and B (they add no light);
- the transition formula itself meets A at p = 0 and B at p = 1 (not only the endpoint shortcut);
- with amplitude 0, the output equals the same case with beatPhase 0 and beatsPerSlide 1;
- with motion 0, a slide draws the same at every k.

It also asserts that the path at amplitude 1 strictly increases over a whole slide
(k = t / T, beatPhase = frac(beatsPerSlide k)) for beatsPerSlide in {1, 2, 6.5, 24, 180} and ends
at 1.

## Flash sequence

`slideshow-check.mjs` plays six slides at 5 s intervals (black, white, a 16-texel checker,
saturated red stripes, a pair and a fill, every style at its suggested duration) with tempo
coupling at amplitude 1 and 180 BPM, at 60 fps and 160 x 90, through the ACES fitted tone map
and sRGB encode, and runs the bytes through the limiter model (`limiter-model.mjs`) and the
audit (`limiter-audit.mjs`). The audit counts every 0.1 step of a pixel's luminance, so a
dissolve from black to white, or any wipe between such slides, counts many transitions on the
input; the limiter paces them, and its output must make at most six large-area luminance and one
red transition in any one second (the bounds `test-limiter.mjs` holds the limiter to).

It then plays each slide alone, from 1 s after its start to 1 s before its successor's, with and
without tempo coupling. Coupling must make no large-area transition on a slide that makes none
without it. The red stripes, panned, make some on their own (24 per second without coupling and
28 with, as the faster half of the pace swing moves edges faster); the limiter paces those.

## Regenerate

```sh
python3 -I tools/slideshow-vectors.py          # rewrite vectors.json
python3 -I tools/slideshow-vectors.py --check  # exit 1 if it would change
make slideshow-check
```

Change the model, this file and `shaders/slideshow/slideshow.glsl` together; the output is
byte-identical across runs.
