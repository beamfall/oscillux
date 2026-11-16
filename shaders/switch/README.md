<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Host switch transitions: host-pass contract

`switch.glsl` is the portable source for the four styles a host plays when it switches from one
visual to another, plus the photo-key variant. A host includes it in a full-frame pass, or
consumes its generated platform legs, and owns only the surface glue and the choice of style.

| id | Style | Reference (what added light is measured against) |
|---|---|---|
| 0 | Luma Key | the source-over dissolve mix(from, to, p) |
| 1 | Photo Key (Luma Key's `photoKey` input treatment) | the source-over dissolve mix(from, to, p) |
| 2 | Melt | the source-over dissolve mix(from, to, p) |
| 3 | Downbeat Cut + Light Leak | the plain cut: the incoming frame |
| 4 | Beat Iris | the same aperture with a hard mask and no rim |

## The pass

- **Where.** Before bloom, tone mapping and the flash limiter. Both frames, the photo and the
  result are linear HDR; the limiter still sees the whole switch.
- **Inputs.** The outgoing and incoming frames as textures at the target size, sampled with
  bilinear clamp-to-edge; the photo (Photo Key only) at any size, linear.
- **Include.** Define `OSC_SWITCH_FROM(uv)` (a `vec3` linear sample of the outgoing frame,
  clamp-to-edge) before including `switch.glsl`; Melt reads displaced texels through it. Then
  fill `TransitionInputs` with the three samples at uv and the parameters, and write
  `transition(style, uv, t)`.
- **uv** is in [0, 1]^2 with v = 0 at the top row of the frame.
- **Reference pass.** `tools/shader/switch.mjs` wraps it as a full-frame fragment shader:
  `SwitchBlock` at buffer 0 / uniform-block binding 0 (48 bytes std140:
  `switch0 = (p, beatPhase, energy, focus)`, `switch1 = (motion, aspect, style, 0)`,
  `size = (width, height, 0, 0)`), textures 0/1/2 = outgoing, incoming, photo, sampler 0,
  colour 0 = result. GLSL ES 3.00 for WebGL2; GLSL 450 through glslangValidator and SPIRV-Cross
  for Metal.

## Parameters

| Field | Range | Used by |
|---|---|---|
| `p` | [0, 1] | all: progress, already eased by the host (below) |
| `beatPhase` | [0, 1) | Beat Iris: the radius kicks at each beat (0) and relaxes |
| `energy` | [0, 1] | all emissive light (Photo Key glow, leak, rim) and Melt's drip |
| `focus` | [0, 1] | Luma/Photo Key matte contrast, Melt stagger spread, Iris edge width; 0 soft, 1 crisp |
| `motion` | [0, 1] | every displacement and pulse; 0 removes them |
| `aspect` | width / height | Melt columns, leak placement, round iris |

## Timing (host side)

The host turns time into `p`, applying the easing exactly once; the shader applies none:

| Style | Duration | Easing |
|---|---|---|
| Luma Key, Photo Key | 1.2 s | smoothstep |
| Melt | 1.2 s | smoothstep |
| Downbeat Cut + Light Leak | 0.6 s from the downbeat | linear (the leak's own envelope shapes it) |
| Beat Iris | 1.0 s | smoothstep |

**Reduce Motion.** Play Luma Key with `motion = 0` and linear `p` over 0.8 s: a plain dissolve.
`motion = 0` is valid for every style.

**Photo unavailable.** Photo Key binds a neutral dark plate (a black or near-black texture) in
place of the photo, before the next draw, whenever the photo is unavailable, restricted or its
authorisation lapses mid-switch. On the plate every pixel crosses together (a uniform lead on p)
and there is no glow; nothing from the withheld photo reaches the pass.

## Added-light bound

Each style's added light against its reference, dot(max(c - ref, 0), Y) with
Y = (0.2126, 0.7152, 0.0722), is held to at most 0.04 per pixel by `oscSwitchGuard`, which
scales the whole difference so hue holds. The ACES fitted tone map's steepest slope is 1.80, so
at unit exposure a pixel, and therefore any cell of a 16 x 9 grid, adds at most 0.072 luminance
after tone mapping, under the 0.08 cell cap. A host that applies more than unit exposure before
its tone map scales that bound with it.

## Conformance

`conformance/switch-transition/` (model `tools/switch-transition-vectors.py`) holds 8 x 8 golden
vectors at p in {0, 0.25, 0.5, 0.75, 1}; `make switch-transition-check` compares WebGL2 and, on
macOS, Metal draws of this file within the stated tolerance. `tools/shader/verify.mjs` compiles
the pass for both samplings. `node tools/shader/switch-transition-check.mjs --strip out.png`
draws a contact strip, and `--perf` times each style at 1080p on the Metal device.
