<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Shader toolchain

`tools/shader/` turns one portable GLSL body per visual into the shaders each host
backend compiles: GLSL ES 3.00 (WebGL2/GLES), Vulkan GLSL 450, and, through SPIR-V,
Metal Shading Language and HLSL Shader Model 5.0 (D3D11). It also checks the native
outputs with the pinned compilers, validates declarative pass lists, and renders
visuals headlessly, once or on every change. The host owns the visuals; it passes
them in as a manifest, and nothing in this tool names a product, catalog or palette.

## Inputs

### Body

Each visual defines one function:

```glsl
vec3 visual(vec2 uv, VisualUniforms u)
```

`uv` is in [0,1]² with the origin at the top left on every target. The wrapper
supplies these to the body:

| Name | Meaning |
|---|---|
| `IMG(uv)` / `IMGSIZE` | the image input, a `vec4` sample / its size in texels |
| `PREV(uv)` | the previous frame, a `vec4` sample |
| `feedbackTrail(col, uv, decay, zoom, rotAmt)` | blend `col` over the warped previous frame; `decay` is per 60 Hz frame and scaled by `u.dt` so trail persistence holds at any frame rate |

The returned colour is linear and may exceed 1. The wrapper grades it with
`suppressGreenCast`, or with `sanitizeColor` alone when the visual takes an image
input, so an image's real greens are kept.

### Prelude

The prelude is host GLSL included before every body. It must define:

- `struct VisualUniforms { ... };`, closed by `};` and a newline, with exactly the
  members of the uniform schema (below), in order. The 450 targets drop this
  declaration and emit their own after the uniform block, so the two must agree;
- `mat2 rot2(float)`;
- `vec3 sanitizeColor(vec3)`;
- `vec3 suppressGreenCast(vec3)`.

It must compile as both GLSL ES 3.00 and GLSL 450. Anything else it defines is
shared helper code for the bodies. `examples/shader/prelude.glsl` is a minimal
prelude.

### Manifest

```json
{
  "prelude": "prelude.glsl",
  "visuals": [{
    "id": "spectrum-rings",
    "body": "visuals/spectrum-rings.glsl",
    "targets": ["web", "vulkan", "msl", "hlsl"],
    "imageInput": false,
    "header": "// spectrum-rings - example",
    "palette": [-1, 0, 0.6, 0],
    "params": [{"uniform": "param0", "id": "trail-zoom", "label": "Trail Zoom",
                "labelKey": "visual.spectrum-rings.trail-zoom", "min": 0, "max": 1,
                "default": 0.7, "step": 0.01, "curve": "linear", "group": "shape"}],
    "tunables": ["trailDecay", "accent", "palette"],
    "trailDecay": 0.82
  }]
}
```

Paths are relative to the manifest. `id` matches `[a-z0-9][a-z0-9-]*` and names the
Metal and HLSL entry point `frag_<id with - as _>`. `targets` is a non-empty subset of
`web`, `vulkan`, `msl` and `hlsl`. `header` is one `//` comment line (or empty) placed above
generated Metal and HLSL. Unknown keys are rejected.

`params` lists one control for each of `param0`, `param1` and `param2` that the visual reads
(in its body, or through a prelude function or a prelude or body `#define` it uses). A read is
a member access on `u`, on any name declared `VisualUniforms` (a helper's argument, a copy) or
on a function-like macro's parameter; the check over-reads rather than misses. A param the
visual reads without a control, a control for a param it does not read and two controls for one
param are all rejected, so `make shader-test` and `tools/shader/bundle-hosts.mjs` refuse such a
visual.
Each control has:

| Key | Meaning |
|---|---|
| `uniform` | `param0`, `param1` or `param2` |
| `id` | `[a-z0-9][a-z0-9-]*`, unique in the visual; the key in a preset's `params` |
| `label` | trimmed, non-empty English label |
| `labelKey` | exactly `visual.<visual id>.<id>`, the host's localisation key |
| `min`, `max` | `0 <= min < max <= 1` (params are normalised) |
| `default` | in `[min, max]`; the value the hosts write when no preset sets it |
| `step` | `0 < step <= max - min` |
| `curve` | `linear` (the only curve so far) |
| `group` | `shape`, `motion`, `color`, `detail` or `reaction` |

A param the visual does not read is written as 0.5. `tunables` lists exactly the host
uniforms among `sensitivity`, `trailDecay`, `accent`, `motion` and `palette` that the visual
reads, so a host shows only controls that change it; listing one it does not read, or omitting
one it reads, is rejected. `palette` is `[index, 0, phase, 0]` with an integer index in
`[-1, 31]` (-1 is the originals' free mode) and a phase in `[0, 32]`, so every manifest default
is also a valid preset value. `trailDecay` is in `[0, 0.96]`; `feedbackTrail` clamps its decay to
0.90, so for a body that passes `u.trailDecay` through it, values above 0.90 look the same.

`post` is the visual's optional post tuning, data for a host's post chain (it reaches no visual
uniform and no preset). When present it has exactly these keys; without it a visual takes the
defaults, which turn every effect off. The reference set (`shaders/manifest.json`) gives every
visual its own values; the originals take the defaults.

| Key | Range | Default | Meaning |
|---|---|---|---|
| `bloomStrength` | 0 to 2 | 0 | bloom gain (the present pass's `post0.x`) |
| `bloomThreshold` | 0 to 4 | 1 | linear-light level above which a pixel blooms |
| `chroma` | 0 to 0.05 | 0 | radial chromatic aberration, the corner offset as a fraction of the distance to the centre (`post0.y`) |
| `vignette` | 0 to 1 | 0 | edge darkening strength |
| `grain` | 0 to 0.25 | 0 | film-grain amplitude (`post0.z`; 0 under reduced motion) |

The present pass's bloom prefilter still uses a fixed threshold of 1 and the pass has no
vignette, so `bloomThreshold` and `vignette` are for hosts with their own post chain until the
pass reads them. `bundle-hosts.mjs` copies `post` into each bundled visual.

The catalog fields are data a host lists a visual with, passed through to the release legs'
`catalog.json` and reaching no shader. `name`, `blurb`, `tier`, `input`, `overlay` and `calm` come
together or not at all: `name`, `blurb` and `input` are one-line trimmed strings, `tier` is
`lite`, `standard` or `flagship` (the GPU cost class), `overlay` and `calm` are booleans, and
`input` names `image` exactly when `imageInput` is true. With them, `imageCapable` is an optional
boolean (default false), and every param uniform needs a label: a control carries its own, and
`unreadParamLabels` (an object keyed by `param0` to `param2`, labels as for controls) gives one
for each param the body does not read, for hosts that list all three. The optional top-level
`catalogOrder` lists every visual id once, in the order a catalog shows them; without it the
order is the manifest's. The reference set carries the fields for all 61 visuals, in the order
of the imported catalog (its `catalog.json`, then `catalog.parts/*.json` by file name). The
fields do not change any emitted shader byte.

`tools/shader/import-visuals.mjs` generates the controls of the imported visuals from the
catalog labels and the bodies (`tools/shader/param-controls.mjs`): a label's slug is the id,
the range is 0 to 1 with the current value as the default, the step is 1 / |b - a| when the body
quantises the param as `int(mix(a, b, u.paramN))` or `int(floor(mix(a, b, u.paramN)))` with
integer `a` and `b` (0.01 otherwise), and the
group comes from the label's words.

### Presets

A preset is the JSON a host saves for one visual's tuning. `tools/shader/preset.mjs` validates,
migrates and clamps it, and has no imports, so the web host loads it as is.

```json
{ "schemaVersion": 1, "visual": "spectrum-rings", "params": { "trail-zoom": 0.6 },
  "sensitivity": 1.2, "accent": [0.15, 0.9, 0.72, 1], "motion": [0, 0, 0, 0],
  "palette": { "index": -1, "phase": 0.6 }, "trailDecay": 0.8,
  "mapping": { "levelSource": "absolute", "releaseSeconds": 0.2, "dbFloor": -60 } }
```

Only `schemaVersion` and `visual` are required. A missing field takes the visual's default
(`defaultPreset`): the control defaults, sensitivity 1, accent (0.15, 0.9, 0.72, 1), motion 0,
the manifest palette and trail decay, and the core's default mapping. `resolvePreset` refuses,
with a path and a code:

- text over 64 KiB or that is not JSON, and a value that is not an object;
- a `schemaVersion` that is not a non-negative integer or is newer than 1;
- an unknown visual, an unknown key at any level, or a param id the visual has no control for;
- a number field that is not a number or is not finite, a palette index that is not an
  integer, and a `levelSource` other than `absolute` or `relative`.

It clamps finite numbers and reports each clamped path:

| Field | Range |
|---|---|
| `params.<id>` | the control's `[min, max]` |
| `sensitivity` | 0 to 2 |
| `accent` | 0 to 1 per component |
| `motion` | angle -π to π; offsets and depth -0.25 to 0.25 |
| `palette.index`, `palette.phase` | -1 to 31; 0 to 32 |
| `trailDecay` | 0 to 0.96 |
| `mapping.releaseSeconds`, `mapping.dbFloor` | 0.02 to 2 s; -96 to -12 dB |

Migration runs one version at a time. Version 0 is the bundle's positional form,
`{ "schemaVersion": 0, "visual": id, "params": [p0, p1, p2] }`: each value moves to the control
of that uniform, and a value for a uniform the visual does not read is dropped. A new schema
version adds a migration step and keeps every older one.

`presetUniforms` returns only `sensitivity`, `param0` to `param2`, `accent`, `motion`,
`palette` and `trailDecay`. The host writes the time, audio, `presentation0`, `presentation1`
and `safeRect` uniforms itself, so no preset reaches the flash limiter's or the overlay's
inputs. `presetMapping` returns the mapping fields the host applies to the core: `releaseSeconds`
and `dbFloor` are `MappingConfig` fields (`release_seconds`, `db_floor`), and `levelSource` goes
through `oscillux_mapping_set_level_source`.
`conformance/presets/` holds the vectors and the adversarial set that `make shader-test`
checks. Modulation routings are not part of version 1 (OSC-TUNE-MODULATION).

## Outputs and uniform layout

| Target | Uniforms | Image | Previous frame |
|---|---|---|---|
| `web` (GLSL ES 3.00) | `uniform VisualUniforms u` | `uImage` | `uPrev` |
| `vulkan` (GLSL 450) | `VisualUniformBlock`, set 0 binding 0 (std140) | binding 1 | binding 2 |
| `msl` (Metal) | `[[buffer(0)]]` | `[[texture(0)]]` | `[[texture(1)]]`, `[[sampler(0)]]` |
| `hlsl` (SM 5.0) | `cbuffer VisualUniformBlock : register(b0)` | `register(t0)` | `register(t1)`, `register(s0)` |

`vertex.web.vert` is the shared fullscreen vertex shader for GLSL ES hosts; draw one
triangle with clip-space positions (-1,-1), (3,-1), (-1,3) at attribute location 0.
`glsl2msl.mjs` checks the reflected bindings and the emitted entry-point signature
for every Metal and HLSL shader, and fails on any difference. For HLSL it also checks
the stage IO (`float2 vUV : TEXCOORD0`, `float4 outColor : SV_Target0`) and that every
cbuffer member's `packoffset` equals its std140 offset in the uniform schema.

The `msl` and `hlsl` targets both start from the same GLSL 450 input with separate
textures and one sampler, so `<id>.hlsl.frag` is identical to `<id>.msl.frag`. The
goldens in `conformance/shader/examples` are those inputs; the Metal and HLSL text
depends on the SPIRV-Cross build and is produced by `emit.mjs --msl --hlsl`.

### Uniform schema

`conformance/packing/visual-uniforms.schema.json` is the one source for the
`VisualUniforms` layout. Each member has a GLSL type (`float`, `vec2`, `vec4`, or a
`vec4` array with `count`) and a source: a mapped value (`scalar`, by index into
`Mapped::values`), the mapped spectrum (`spectrum`), or `host`. Host values take
consecutive host-array indices in declaration order. Those types have the same
offsets under std140 and Metal; the schema rejects types where the two differ.

`tools/shader/uniforms.mjs` derives the offsets and Packer fields from the schema
and writes two files: `crates/oscillux-core/src/packing/visual_uniforms.rs`
(`FIELDS`, `BLOCK_SIZE`, `HOST_VALUES`) and `conformance/packing/visual-uniforms.json`
(members with offsets, fields, and one block packed with `DataView`). After a schema
change, run `node tools/shader/uniforms.mjs --write`, edit the host prelude to match,
then run `node tools/shader/test-wrap.mjs --update`. `wrap.mjs` emits the 450
`VisualUniformBlock` members, the 450 `struct VisualUniforms` and `loadUniforms()`
from the schema, one member per line, so only the prelude's copy is hand-written.
`make shader-test` fails when either generated file is stale, or when the prelude's
or an emitted `VisualUniformBlock`, `struct VisualUniforms` or `loadUniforms()`
differs from the schema; `make test` fails when the Rust `Packer` with `FIELDS` does
not reproduce the vector's bytes.

## Pass lists

A pass list declares how one frame is rendered: the offscreen targets, and the passes
that read and write them in order. `conformance/passes/pass-list.schema.json` (JSON
Schema draft-07) defines it, and `tools/shader/passes.mjs` validates it.

```json
{
  "version": 1,
  "targets": [{ "id": "scene", "format": "rgba16f", "feedback": true }],
  "passes": [
    { "id": "scene", "shader": { "visual": "spectrum-rings" },
      "inputs": { "image": "image", "prev": "scene.previous" }, "output": "scene" },
    { "id": "tonemap", "shader": { "post": "tonemap" },
      "inputs": { "source": "scene" }, "output": "screen" }
  ]
}
```

- **Targets** have a `format` (`rgba8`, `rgba16f`, `rgba32f`), a `scale` relative to the
  output surface (0 < scale <= 1, default 1), a sampling `filter` (`linear` or
  `nearest`; reads clamp to edge) and a `clear` colour (default `[0, 0, 0, 1]`). A
  `feedback` target is double-buffered: `<id>.previous` reads its contents at the end
  of the previous frame. `screen` (the host's output surface) and `image` (the host's
  image input) are reserved names.
- **Passes** run in list order. `shader` is `{"visual": id}`, a manifest visual wrapped
  by this toolchain, whose slots are exactly `image` and `prev` (`IMG` and `PREV`); or
  `{"post": name}`, a post-process shader the host supplies under that name, with
  slots of its choosing. `inputs` maps each slot to `image`, `<target>` (its contents
  so far this frame) or `<target>.previous`. `output` is a target or `screen`. `blend`
  is `replace` (default), `add`, `alpha`, `premultiplied` or `max`.
- **Uniforms**: every pass sees the `VisualUniforms` block. `uniforms` sets per-pass
  values for host-sourced members by their schema name, a number for `float` and an
  array for `vec2` and `vec4`. Audio-sourced and array members cannot be set.

`passes.mjs` also rejects what the schema cannot express: duplicate ids, unknown or
reserved targets, a read before any pass writes the target this frame, a pass reading
the target it writes (read `<id>.previous` instead), `.previous` on a target without
`feedback`, a target never written or never read, no pass writing `screen`, and
uniform names, sources or sizes that do not match the uniform schema. With
`--manifest`, each visual must be in that manifest. The JSON Schema interpreter in
`passes.mjs` implements only the keywords the schema uses and refuses any other.
`conformance/passes/examples` holds the feedback ping-pong of `render.mjs`
(`feedback-tonemap.json`) and bloom over it (`bloom-feedback.json`).

**Boundary.** Oscillux defines and validates pass lists; it does not execute them.
Allocating targets, binding inputs, blending and presenting stay with each host
renderer (ADR-0228 D2); a shared host renderer is the subject of SPIKE-D-1 (sokol_gfx). The
`render.mjs` preview runs its own fixed feedback and tonemap pipeline; `watch.mjs`
validates a pass list but does not render from it.

## Present pass

`shaders/present/present.glsl` is the last shader a host runs before its output, and the flash
limiter comes after it: present, then limiter, then output. Present v2 (CORE-0108) applies the
ACES fit to luminance and scales the colour to match; a colour that would pass 1 moves toward its
grey until it fits, so the HSV hue holds (v1 mapped each channel). It then encodes sRGB and, on an
8-bit output, adds one code of triangular dither from the pass's own integer hash (`presentHash`,
the library's xorshift-multiply mixer) of (pixel, frame seed). Within one code of black or white
the dither is rectangular, and within 1/1024 code it snaps to the end, so pure black and white
stay exact.

The 368-byte block ends in `post0` (bloom, aberration, grain, dither in codes) and `post1.x` (the
frame seed). Bloom reads the scene at texture 4, and the pass reads it only when `post0.x > 0`.
`shaders/present/bloom.glsl` builds that texture in three stages: a prefilter (soft threshold 1,
knee 0.5, Karis-weighted 13-tap) into L0 at half size, four 13-tap downsamples to L4, then four
9-tap tent upsamples additively blended back into L0. `PRESENT_BLOOM_GRAPH` in `tools/shader/present.mjs` gives the
graph. Reduced motion turns grain off and uploads `trailDecay` 0. Hosts leave bloom, aberration and
grain at 0 for now.

`tools/shader/present-model.mjs` is a standard-library model of the colour path.
`make present-v2-check` (in `make gate`) runs `test-present-v2.mjs` on the model and the shader
source. It then runs `present-v2-check.mjs`, which renders a saturated-colour ramp, a dark
gradient and the black and white ends through the real pass on Metal. That check requires the GPU to
be at most 1 code from the model, a hue error of at most 2 degrees on codes, a banding step of at most 0.1
codes and runs of at most 32 px. Without a Metal device it prints a skip. `make present-v2-gpu`
adds timing at 1920x1080 and writes contact sheets to `out/present-v2`.

## Commands

| Command | Needs | Does |
|---|---|---|
| `node tools/shader/emit.mjs <manifest> [--out DIR] [--msl] [--hlsl]` | node; with `--msl` or `--hlsl`, glslangValidator and spirv-cross | writes the shaders and prints their sha256s |
| `make shader-test` (in `make gate`) | node | example set against `conformance/shader/examples`, the uniform schema checks, manifest and prelude rejection, the pass-list examples and rejections, and a `watch.mjs --once --no-render` run |
| `make shader-verify [SHADER_MANIFEST=…]` | pinned glslangValidator and spirv-cross, Xcode; optionally FXC or DXC | validates every `vulkan` shader, compiles every `msl` shader with `xcrun metal`, and checks every `hlsl` shader (below) |
| `node tools/shader/passes.mjs <pass-list>... [--manifest M]` (in `make gate` through `test-passes.mjs`) | node | validates pass lists; exits 1 on the first invalid one |
| `make shader-watch [SHADER_MANIFEST=…] [WATCH_ARGS=…]` (dev only, not in `make gate`) | as `shader-render` | `watch.mjs`, below |
| `make shader-render [SHADER_MANIFEST=…] [RENDER_ARGS=…]` | Playwright Chromium (`npm --prefix tools/shader exec -- playwright install chromium`); Xcode for the Metal part | renders every `web` visual under WebGL2 and writes PNGs and `stats.json` to `out/shader-renders` |
| `node tools/shader/import-visuals.mjs <beamfall-visual-shaders checkout> [--check]` | node | copies the upstream visual bodies and the manifest, catalog fields and `catalogOrder` included, into `shaders/`, cleaning the header comments; with `--check`, reports any difference instead of writing. `library.glsl` is locally owned (Oscillux's own hashes and uniforms), so it is neither written nor checked. Upstream no longer carries the bodies, so `shaders/` is now edited here |
| `node tools/shader/bundle-legs.mjs <msl\|glsl300\|android-gles> <checkout> <out-dir> <tag> <40-hex rev>` | node; spirv-cross for `msl` | writes one release shader leg of the checkout's `shaders/manifest.json` with a sha256 `index.json`: `msl` (every visual as Metal, present, bloom, limiter and switch passes) and `glsl300` (the same as GLSL ES 3.00, with `vertex.web.vert`) each with `catalog.json`; `android-gles` writes `AndroidGlesShaders.kt`, below |
| `make host-bundle` / `host-web` / `host-mac` / `host-ios` (not in `make gate`) | as `shader-verify`; Xcode and XcodeGen for the app | builds `out/hosts/visuals.json` from `HOST_MANIFEST` with the categories in `hosts/categories.json` and the curated sets in `hosts/collections.json`, and runs the reference hosts; see `hosts/README.md` |

`catalog.json` in the `msl` and `glsl300` legs is `{schemaVersion: 1, release, rev, license,
visuals}`, the visuals in `catalogOrder`, each with `id`, the catalog fields, `params` (all three
as `{key, label, def}`, `def` being the default the host packs), `postFX` (`post` plus
`trailDecay`, keyed `bloomStrength`, `bloomThreshold`, `trailDecay`, `chroma`, `vignette`,
`grain`), `imageCapable`, `imageInput`, `palette` (`{index, phase}`) and `controls` (the
manifest's param controls). Every visual needs the catalog fields, or the leg is not written.

The `android-gles` leg's `AndroidGlesShaders.kt` (`tools/shader/android-gles-contract.mjs`) is
the Android GLES contract 1.0.0 consumed as `com.beamfall.kit.visuals.AndroidGlesShaders`: the
same visuals and fields as typed Kotlin, every fragment as `wrapGLSL300` output with
`VERTEX_300`, eleven text probes, and two length-prefixed payloads (catalog and source) with
SHA-256 digests over their domain, a zero byte and the payload, so a consumer can check what it
embeds. Line 2 names the release tag and rev. The package, object, domains, payload layout and
probes are fixed: changing any is a new contract version. `make shader-test` runs
`test-android-gles.mjs`, which pins the reference set's payload digests.

`render.mjs` takes `--frames N` (default 96), `--only id1,id2`, `--img artwork.png`
and `--out DIR` (default `out/shader-renders` under the repository root). It flags
compile failures, blank frames (under 1% lit) and whiteouts (solid clipped white over
0.25% of the frame). On macOS it compiles every `msl` visual. With `--frames 1` it
also renders each `msl` visual that has a `web` target through Metal
(`metal-smoke.swift`), from the same uniforms. It fails when the mean absolute
per-pixel luma difference from the tonemapped WebGL frame exceeds 0.40, or when under
1% of the Metal frame is lit. An `msl`-only visual is compiled but not diffed. With
`CI` set, a diff skipped for lack of a Metal device fails, as does a `--frames 1` run
in which no diff ran.

`watch.mjs <manifest> [--passes FILE] [--once] [--no-render]` plus the `render.mjs`
options is the live preview. Each iteration reloads the manifest and prelude, wraps
every visual for its `web` and `vulkan` targets and the SPIR-V inputs, validates the
pass list against the manifest, then runs `render.mjs`. It re-runs 150 ms after the
last change under the manifest's directory or to the pass list, one iteration at a
time. SIGINT (Ctrl-C), SIGTERM or SIGHUP, in watch or `--once` mode, sends SIGTERM to
a running `render.mjs`, waits for it to exit (SIGKILL after 3 s), then exits with 128 plus
the signal number. Edits to `tools/shader` itself need a restart. `--once` runs one iteration and exits with its status (0 ok, 1 invalid input,
else `render.mjs`'s code); `--no-render` skips `render.mjs` and needs no browser.

For each `hlsl` visual, `verify.mjs` checks the ABI and cbuffer packing, parses the
HLSL with glslangValidator's HLSL front end (`-D`; this is not a D3D compiler), and
then compiles it with a D3D compiler when one is configured: `OSCILLUX_FXC` (FXC,
`/T ps_5_0`), else `OSCILLUX_DXC` (DXC, `-T ps_6_0 -HV 2018`), else the first `fxc`,
`fxc.exe`, `dxc` or `dxc.exe` on `PATH`. Without one it prints
`HLSL compiler validation: SKIPPED`, never PASS, and with `CI` set it exits 1.
DXC has no SM 5 back end: it promotes the SM 5.0 source to `ps_6_0` and emits DXIL, so a
DXC pass shows the HLSL compiles for D3D12, not that FXC accepts it for `ps_5_0`.

For the example manifest, `make shader-verify` passes `--hlsl-goldens
conformance/shader/examples`, and each emitted HLSL must equal `<id>.hlsl` there byte for
byte. The gate does not run SPIRV-Cross; `make shader-test` checks those goldens' ABI and
packing only. After a deliberate change, regenerate them on the pinned toolchain with
`node tools/shader/emit.mjs examples/shader/manifest.json --hlsl --out conformance/shader/examples`.

After changing the wrapper or the example set, run
`node tools/shader/test-wrap.mjs --update` and review the golden diff.

## Pins

| Tool | Pin |
|---|---|
| glslangValidator | 16.6.0 |
| SPIRV-Cross | build timestamp 2026-07-06T12:43:32 (Homebrew 1.4.357.0) |
| Playwright | 1.61.1 (`tools/shader/package-lock.json`) |

`verify.mjs` refuses to run on other compiler versions; `emit.mjs --msl` warns and
continues, and the header it writes then names a version that was not used.
`tools/shader/provision.mjs` installs the pinned compilers from source through a
pinned homebrew/core revision. It changes the global Homebrew install, so run it
only on disposable CI hosts.

## Provenance

Ported from beamfall-visual-shaders under the owner's 2026-10-20 relicensing
decision. The reference catalog in `shaders/`
(61 visuals and `library.glsl`) was imported from beamfall-visual-shaders c3145a4 under the
same decision. `make shader-test` checks that
every catalog visual wraps for all four targets and carries no host or product names.
