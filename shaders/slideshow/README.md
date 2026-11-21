<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Photo slideshow: host-pass contract

`slideshow.glsl` is the portable source for the calm photo slideshow: each photo shown full frame
with a slow Ken Burns move aimed at a salient rect the host supplies, portrait photos paired side
by side or shown whole over a blurred fill of themselves, and three calm transitions. A host
consumes the generated legs (`slideshow/slideshow.frag` in `glsl300`, `slideshow/slideshow.metal`
in `msl`) and owns only the surface glue, photo decoding and upload, salient-rect detection, the
playlist and timing.

| id | Style | Reference (what added light is measured against) |
|---|---|---|
| 0 | Dissolve | itself: mix(A, B, p), never outside the two slides |
| 1 | Light sweep | the same soft diagonal wipe without its warm band |
| 2 | Iris | itself: a soft aperture from the incoming photo's salient centre, no rim |

| id | Layout | Use |
|---|---|---|
| 0 | Cover | the photo fills the frame, cropped about its salient rect (landscape photos) |
| 1 | Fill | the whole photo over a still, blurred, dimmed, desaturated cover crop of itself; never bars |
| 2 | Pair | two photos side by side, each covering half the frame, with a thin dark gutter (portraits) |

## The pass

- **Where.** Before bloom, tone mapping and the flash limiter. Photos and the result are linear
  HDR; the limiter sees the whole slideshow.
- **Bindings** (`tools/shader/slideshow.mjs`, the legs' source). `SlideshowBlock` at buffer 0 /
  uniform-block binding 0, 176 bytes std140, eleven `vec4`s:

  | vec4 | Fields |
  |---|---|
  | `pass0` | (p, style, aspect, motion) |
  | `pass1` | (amplitude, beatPhase, beatsPerSlide, 0) |
  | `size` | (width, height, 0, 0) of the target in pixels |
  | `slideA`, `extraA`, `rectA0`, `rectA1` | outgoing slide: (k, layout, direction, aspect0), (aspect1, 0, 0, 0), primary and secondary salient rects |
  | `slideB`, `extraB`, `rectB0`, `rectB1` | incoming slide, same fields |

  Integers (style, layout) are stored as floats. Textures 0 to 3 (`uPhoto0..3`) are the outgoing
  primary and secondary and the incoming primary and secondary photos, one sampler at 0; bind
  the primary again where a slide has no secondary. Colour 0 is the result. The fragment entry
  point is `oscillux_slideshow`. `slideshowBlock({...})` in `slideshow.mjs` packs the block from
  named fields and is the reference for a host's packer.
- **Photos** are linear (sRGB-decoded), with mipmaps and trilinear clamp-to-edge sampling: the
  blurred fill reads a mip level about a twentieth of the photo's height, and the Ken Burns
  move minifies. Without mips the fill is still correct but grainier.
- **uv** is in [0, 1]^2 with v = 0 at the top row of the frame; photo uv likewise (row 0 of the
  uploaded image at v = 0).
- **Between transitions** draw with p = 0 and the showing slide as `a` (the `b` fields are not
  read).

## Parameters

| Field | Range | Meaning |
|---|---|---|
| `p` | [0, 1] | transition progress, already eased by the host (below); 0 shows `a`, 1 shows `b` exactly |
| `style` | 0, 1, 2 | the transition |
| `aspect` | width / height | the frame |
| `motion` | [0, 1] | Ken Burns depth: at 1 the window closes to 1 / 1.18 of its size over a slide; 0 holds every photo still |
| `amplitude` | [0, 1] | tempo coupling, **default 0**; at 0 `beatPhase` and `beatsPerSlide` are not read |
| `beatPhase` | [0, 1) | position in the current beat, from the host's beat scheduler |
| `beatsPerSlide` | >= 1 | beats in the slide's whole time on screen: tempo (beats/s) x (interval + transition duration) |
| `k` | [0, 1] | the slide's Ken Burns progress, linear in its time on screen from the start of its incoming transition to the end of its outgoing one |
| `layout` | 0, 1, 2 | the slide's layout |
| `direction` | 0 or 1 | 0 zooms in toward the salient rect, 1 zooms out from it; alternate it for variety |
| `aspect0`, `aspect1` | width / height | the primary and secondary photos (aspect1 for pair only) |
| `rect0`, `rect1` | photo uv (x0, y0, x1, y1) | salient rects (a face, a subject); all zeros means unknown, which frames the middle |

The move keeps the salient rect (grown 1.2 times about its centre) in view at every k. Tempo
coupling only swings the move's pace on the beat, between 0.1 and 1.9 times its plain pace at
amplitude 1; it never reverses the move, adds no light and changes nothing at the ends of a
slide. Energy, onsets and loudness are deliberately not inputs.

## Timing (host side)

The host turns time into `p`, applying the easing once (smoothstep); the shader applies none.
Suggested durations: dissolve 1.5 s, light sweep 1.8 s, iris 1.6 s, with at least 5 s between
transition starts. `k` runs over interval + duration, so the outgoing slide keeps moving through
the transition.

**Reduce Motion.** Play the dissolve over 1.0 s with `motion = 0` and `amplitude = 0`: still
photos and a plain cross-fade.

**Layout choice** is the host's: pair two consecutive portraits when the frame is landscape,
otherwise fill a photo whose aspect differs much from the frame's, else cover.

## Added-light bound

The dissolve and the iris never leave the per-channel span of the two slides. The light sweep's
band adds at most 0.04 linear luminance per pixel over its plain wipe (guarded in the shader),
so after the ACES fitted tone map (steepest slope 1.80) at unit exposure a pixel, and so any
cell of a 16 x 9 grid, adds at most 0.072, under the limiter's 0.08 cell cap. A host that applies
more than unit exposure before its tone map scales that bound with it.

## Conformance

`conformance/slideshow/` (model `tools/slideshow-vectors.py`) holds 8 x 8 golden vectors for every
style at p in {0, 0.25, 0.5, 0.75, 1} over every layout; `make slideshow-check` compares WebGL2
and, on macOS, Metal draws of this file within the stated tolerance, proves amplitude 0 ignores
the audio inputs on both, and plays a loud-audio worst case through the flash limiter model and
audit. `tools/shader/verify.mjs` compiles the pass for both samplings.
`node tools/shader/slideshow-check.mjs --frames out.png` writes a contact sheet under loud audio,
and `--perf` times each style over each layout at 1080p on the Metal device.
