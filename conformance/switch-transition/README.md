<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Switch-transition vectors

`vectors.json` is written by `tools/switch-transition-vectors.py`, a standard-library binary64
model of the host switch transitions written from this file, never from shader output.
`make switch-transition-check` (part of `make gate`) runs the model with `--check`, then
`tools/shader/switch-transition-check.mjs` draws `shaders/switch/switch.glsl` over the same
inputs and compares:

- WebGL2 (headless Chromium, SwiftShader), GLSL ES 3.00;
- on macOS, Metal: the GLSL 450 leg through glslangValidator and SPIRV-Cross, built by the
  device's runtime compiler and drawn into an rgba32Float target.

Both draws use the `fetch` sampling of `tools/shader/switch.mjs`: bilinear by hand from
`texelFetch` with clamped texel indices, so the result does not depend on a GPU's fixed-point
filter weights. Hosts sample through the hardware filter (`linear`).

## Layout

- `size` 8: every image is 8 x 8, a flat list of 64 RGB pixels, row-major, **top row first**,
  linear. Pixel (i, j) is drawn at uv = ((i + 0.5) / 8, (j + 0.5) / 8), v = 0 at the top.
- `from`, `to`, `photo`: the inputs. Values are multiples of 1/256 (exact in binary32), plus HDR
  spots: `from` (2, 5) = (3, 2.5, 1.5), `to` (6, 1) = (4, 3.5, 2), and `to` (1, 6) = 0.
- `cases`: 75 cases, 5 styles x p in {0, 0.25, 0.5, 0.75, 1} x 3 parameter sets
  (A: beatPhase 0.25, energy 0.75, focus 0.5, motion 1, aspect 1.75; B: A with motion 0;
  C: beatPhase 0.875, energy 0, focus 1, motion 0.5, aspect 1). Each has `style`, `styleId`
  (lumaKey 0, photoKey 1, melt 2, downbeatCutLightLeak 3, beatIris 4), the parameters and
  `expected`, printed at 6 decimals.
- `tolerance` 1e-3: the largest allowed absolute difference per channel. It covers binary32
  against binary64, `sin`/`exp` precision on GPUs and the 6-decimal print; the check reports
  the measured worst difference.
- `addedLight`: the bounds asserted below and the worst values the model reached.

## Model

Shared definitions: Y = (0.2126, 0.7152, 0.0722); `mix(a, b, t) = a + (b - a) t`;
`smooth(e0, e1, x)` = s^2 (3 - 2s) with s = clamp((x - e0) / (e1 - e0), 0, 1); PI = 3.14159265.
`from`, `to` and `photo` are the inputs sampled at uv.

**Guard.** d = c - ref; added = dot(max(d, 0), Y). If added > 0.04 the result is
ref + d (0.04 / added), else c. Every style returns guard(c, ref).

**Key.** y = max(dot(c, Y), 0); k = y / (y + 0.18); key = clamp(0.5 + (k - 0.5)(1 + 3 focus), 0, 1).

**Luma Key / Photo Key.** k = key of `from` (Luma) or `photo` (Photo);
m = clamp(p + motion 0.6 (0.5 - k) sin(PI p), 0, 1); ref = mix(from, to, p);
c = mix(from, to, m). Photo Key adds, per channel, max(photo, 0) / (1 + max(photo, 0)) x
4 m (1 - m) motion (0.06 + 0.06 energy). With motion 0 both are the plain dissolve.

**Melt.** x = u aspect; delay = 0.5 + 0.25 sin(11x + 1.3) + 0.15 sin(23x + 4.1) + 0.1 sin(41x + 2.2);
order = mix(delay, 0.55 delay + 0.45 v, motion); spread = 0.8 + 1.2 focus;
q = clamp(p (1 + spread) - order spread, 0, 1); sag = motion (0.08 + 0.06 energy) q^2;
outgoing = bilinear `from` at (u, v - sag) (texel centres at (i + 0.5) / 8, clamp-to-edge);
c = mix(outgoing, to, q^2 (3 - 2q)); ref = mix(from, to, p).

**Downbeat Cut + Light Leak.** env = smooth(0, 0.06, p)(1 - p)^2; dx = u aspect -
(0.15 + 0.5 motion p) aspect; dy = v - 0.2; glow = exp(-(dx^2 + dy^2) / 0.18);
streak = exp(-(dy + 0.35 dx)^2 / 0.012); warm = (1, 0.62, 0.34) / dot((1, 0.62, 0.34), Y);
c = to + warm (0.7 glow + 0.3 streak) env (0.026 + 0.012 energy); ref = to.

**Beat Iris.** d = |((u - 0.5) aspect, v - 0.5)|; rMax = 0.5 sqrt(aspect^2 + 1);
w = 0.04 - 0.034 focus; win = sin(PI p); kick = 1 - beatPhase;
r = mix(-w, rMax + w, p) + motion (0.02 + 0.02 energy) kick^2 win;
mask = 1 - smooth(r - w, r + w, d); ref = mix(from, to, mask); e = (d - r) / (2w + 0.01);
rim = (1, 0.9, 0.78) / dot((1, 0.9, 0.78), Y); c = ref + rim exp(-e^2) win (0.026 + 0.012 energy).

## Assertions

Before writing, the model asserts on every pixel of every case:

- added light against the style's reference is at most 0.04 (linear);
- after the ACES fitted tone map x (2.51x + 0.03) / (x (2.43x + 0.59) + 0.14), clamped to
  [0, 1], at unit exposure, the pixel adds at most 0.08 luminance, and so does the case mean;
- p = 0 shows `from` (Downbeat Cut shows `to`: the cut is on the boundary) and p = 1 shows `to`;
- Luma Key and Photo Key with motion 0 equal mix(from, to, p).

## Regenerate

```sh
python3 -I tools/switch-transition-vectors.py          # rewrite vectors.json
python3 -I tools/switch-transition-vectors.py --check  # exit 1 if it would change
make switch-transition-check
```

Change the model, this file and `shaders/switch/switch.glsl` together; the output is
byte-identical across runs.
